-- ─────────────────────────────────────────────────────────────
-- State
-- One active delivery per client. truckEntity/trailerEntity are the two
-- spawned vehicles. promptGen tags each drive-up-and-press-E prompt thread
-- (deliver/return) so a stale one stops itself once superseded or cancelled
-- instead of needing a zone handle to tear down.
-- ─────────────────────────────────────────────────────────────
local truckEntity, trailerEntity = nil, nil
local currentJob = nil
local currentStopIndex = 1
local jobBlip, depotBlip = nil, nil
local promptGen = 0

-- Pushed to the always-mounted #hud-overlay (html/index.html) via
-- SendNUIMessage — a peripheral corner widget visible while driving,
-- independent of SetNuiFocus/the main dashboard being open at all.
-- target = nil means "no active job", hides the HUD.
local hudState = { target = nil, label = nil, stopIndex = nil, stopCount = nil }

-- Forward declarations so closures created earlier in the file can
-- reference functions defined further down.
local openJobBoard, acceptContract
local spawnTruck, spawnTrailer
local watchForHitch, doHookup
local setupDeliverZone, doDeliver
local setupReturnZone, doReturn
local clearTruck, clearTrailer, stopPrompt, setJobBlip, asVec3

function asVec3(v)
    return vec3(v.x, v.y, v.z)
end

-- ── Clear helpers ────────────────────────────────────────────
function clearTruck()
    if truckEntity and DoesEntityExist(truckEntity) then DeleteEntity(truckEntity) end
    truckEntity = nil
end

function clearTrailer()
    if trailerEntity and DoesEntityExist(trailerEntity) then DeleteEntity(trailerEntity) end
    trailerEntity = nil
end

-- Stops any active deliver/return prompt thread — bumping the generation
-- number is enough, the thread checks it and exits + hides the text UI on
-- its own next tick.
function stopPrompt()
    promptGen = promptGen + 1
    lib.hideTextUI()
end

-- Ground marker — a flat amber cylinder matching the Cipher accent color,
-- sized to roughly match the interaction radius so the boundary is visible.
local function drawGroundMarker(coords, radius)
    DrawMarker(1, coords.x, coords.y, coords.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        radius * 2.0, radius * 2.0, 1.0, 245, 165, 36, 110, false, false, 2, false, nil, nil, false)
end

-- Drive-up-and-press-E prompt (same lib.showTextUI + key-poll pattern used
-- elsewhere in the Cipher scripts). `extraCheck`, if given, must also pass
-- for the prompt to show — used to require the trailer specifically be in
-- the delivery zone too, not just the player/truck. Draws a ground marker
-- at `coords` the whole time this is active, regardless of `extraCheck`, so
-- the spot is visible before you're actually eligible to interact.
local function startPrompt(coords, radius, label, onPress, extraCheck)
    promptGen = promptGen + 1
    local myGen = promptGen
    CreateThread(function()
        local shown = false
        while promptGen == myGen do
            Wait(0)
            drawGroundMarker(coords, radius)

            local ped = PlayerPedId()
            local near = #(GetEntityCoords(ped) - coords) <= radius
            if near and (not extraCheck or extraCheck()) then
                if not shown then lib.showTextUI(('[E] %s'):format(label)); shown = true end
                if IsControlJustReleased(0, 38) then onPress() end
            elseif shown then
                lib.hideTextUI()
                shown = false
            end
        end
        if shown then lib.hideTextUI() end
    end)
end

-- Separate marker (not tied to startPrompt/promptGen) for the trailer spawn
-- during the hookup stage, since hitching is auto-detected rather than an
-- [E] prompt — this just shows where to back up to.
local hookupMarkerGen = 0

local function stopHookupMarker()
    hookupMarkerGen = hookupMarkerGen + 1
end

local function startHookupMarker(coords, radius)
    hookupMarkerGen = hookupMarkerGen + 1
    local myGen = hookupMarkerGen
    CreateThread(function()
        while hookupMarkerGen == myGen do
            Wait(0)
            drawGroundMarker(coords, radius)
        end
    end)
end

-- Every call site already passes exactly what the driving HUD needs
-- (a target coord + a human label), so the HUD piggybacks on this instead
-- of needing its own set of hooks at every stage transition.
function setJobBlip(coords, label)
    if jobBlip then RemoveBlip(jobBlip) end
    jobBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(jobBlip, Config.Trucking.blip.sprite)
    SetBlipColour(jobBlip, Config.Trucking.blip.color)
    SetBlipScale(jobBlip, Config.Trucking.blip.scale)
    SetBlipAsShortRange(jobBlip, true)
    SetBlipRoute(jobBlip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(jobBlip)

    hudState.target = coords
    hudState.label = label
    hudState.stopIndex = (currentJob and currentJob.stops) and currentStopIndex or nil
    hudState.stopCount = (currentJob and currentJob.stops) and #currentJob.stops or nil
end

-- ── Vehicle spawning ─────────────────────────────────────────
local function loadModel(model)
    local hash = joaat(model)
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then
        return nil
    end
    lib.requestModel(hash)
    return hash
end

-- Performance upgrades are stored server-side as a JSON string
-- (Config.Trucking.PerformanceUpgrades id -> level); applied here via
-- SetVehicleMod right after the truck spawns. Only owned trucks carry any —
-- the free depot truck's upgradesJson argument is always nil/empty. Stored
-- levels are 1-based (1 = first tier bought); SetVehicleMod's own levels
-- are 0-based, hence the -1.
local function applyPerformanceUpgrades(veh, upgradesJson)
    if not upgradesJson or upgradesJson == '' or upgradesJson == '{}' then return end

    local ok, upgrades = pcall(json.decode, upgradesJson)
    if not ok or type(upgrades) ~= 'table' then return end

    SetVehicleModKit(veh, 0)
    for _, def in ipairs(Config.Trucking.PerformanceUpgrades) do
        local level = upgrades[def.id]
        if level and level > 0 then
            SetVehicleMod(veh, def.modType, level - 1, false)
        end
    end
end

-- Cosmetic-only paint job, stored server-side as JSON {primary, secondary}
-- (Config.Trucking.PaintColors indices). No gameplay effect.
local function applyLivery(veh, liveryJson)
    if not liveryJson or liveryJson == '' or liveryJson == '{}' then return end

    local ok, livery = pcall(json.decode, liveryJson)
    if not ok or type(livery) ~= 'table' then return end
    if not livery.primary or not livery.secondary then return end

    SetVehicleColours(veh, livery.primary, livery.secondary)
end

function spawnTruck(coords, modelOverride, upgradesJson, liveryJson)
    local hash = loadModel(modelOverride or Config.Trucking.truckModel)
    if not hash then
        lib.notify({ description = 'Truck model failed to load — check Config.Trucking.truckModel.', type = 'error' })
        return nil
    end

    local veh = CreateVehicle(hash, coords.x, coords.y, coords.z, coords.w, true, false)
    SetEntityAsMissionEntity(veh, true, true)
    SetVehicleOnGroundProperly(veh)
    SetVehicleNeedsToBeHotwired(veh, false)
    SetModelAsNoLongerNeeded(hash)
    applyPerformanceUpgrades(veh, upgradesJson)
    applyLivery(veh, liveryJson)
    return veh
end

-- Some frameworks/keys resources require a vehicle to be explicitly
-- "given" to a player before the engine will start, even though the truck
-- spawns unlocked and hotwire-disabled — see Config.Trucking.KeysResource.
-- Wrapped in pcall so a wrong/missing export never hard-errors the script;
-- with Config.Debug on, a failure prints the real error to help pin down
-- the exact export your server's keys resource actually expects.
-- 'qbx' is deliberately NOT handled here — qbx_vehiclekeys' GiveKeys export
-- is server-side and needs the server's own resolved vehicle handle, so
-- that case is wired into server/main.lua's registerTruck callback instead.
function giveVehicleKeys(vehicle)
    local resource = Config.Trucking.KeysResource
    if not resource or resource == false or resource == 'qbx' then return end

    local plate = GetVehicleNumberPlateText(vehicle)
    local ok, err

    if resource == 'qb-vehiclekeys' then
        ok, err = pcall(function() TriggerEvent('vehiclekeys:client:SetOwner', plate) end)
    elseif resource == 'qs-vehiclekeys' then
        ok, err = pcall(function() exports['qs-vehiclekeys']:GiveKeys(plate) end)
    elseif resource == 'custom' then
        ok, err = pcall(function() exports['cipher-trucking']:OnGiveKeys(vehicle, plate) end)
    else
        return
    end

    if not ok and Config.Debug then
        print(('^1[cipher-trucking]^0 giveVehicleKeys failed for resource "%s": %s'):format(resource, tostring(err)))
    end
end

function spawnTrailer(coords, modelOverride)
    local hash = loadModel(modelOverride or Config.Trucking.trailerModel)
    if not hash then
        lib.notify({ description = 'Trailer model failed to load — check Config.Trucking.trailerModel.', type = 'error' })
        return nil
    end

    local veh = CreateVehicle(hash, coords.x, coords.y, coords.z, coords.w, true, false)
    SetEntityAsMissionEntity(veh, true, true)
    SetVehicleOnGroundProperly(veh)
    SetModelAsNoLongerNeeded(hash)
    return veh
end

-- ── Job flow ─────────────────────────────────────────────────
-- Opening the depot computer just opens the NUI dashboard now — the
-- Contracts tab drives acceptance, and an active job never blocks opening
-- it (the Active Delivery tab shows status; the server still refuses a
-- second contract while one is in progress).
-- Tracked so the map-tick thread below knows whether anyone is looking at
-- the dashboard — there's no point streaming player coordinates into a
-- closed UI.
local uiOpen = false

function openJobBoard()
    uiOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open' })
end

-- Does the real work of accepting a contract: server round-trip, then
-- spawning the truck (the player's selected owned truck model if the
-- server sent one back, otherwise the free depot truck) + trailer. Returns
-- true/false so the NUI callback can report success back to the dashboard.
function acceptContract(contractId)
    local ok, payload = lib.callback.await('cipher-trucking:server:acceptContract', false, contractId)
    if not ok then
        lib.notify({ description = payload or 'Could not accept that contract.', type = 'error' })
        return false
    end

    currentJob = payload
    currentStopIndex = 1

    local truckModel = payload.truckOverride and payload.truckOverride.model or nil
    local truckUpgrades = payload.truckOverride and payload.truckOverride.upgrades or nil
    local truckLivery = payload.truckOverride and payload.truckOverride.livery or nil
    truckEntity = spawnTruck(payload.truckSpawn, truckModel, truckUpgrades, truckLivery)
    if not truckEntity then currentJob = nil return false end
    giveVehicleKeys(truckEntity)
    local truckNetId = NetworkGetNetworkIdFromEntity(truckEntity)
    lib.callback.await('cipher-trucking:server:registerTruck', false, truckNetId)

    local trailerModel = payload.trailerOverride and payload.trailerOverride.model or nil
    trailerEntity = spawnTrailer(payload.trailerSpawn, trailerModel)
    if not trailerEntity then clearTruck() currentJob = nil return false end
    local trailerNetId = NetworkGetNetworkIdFromEntity(trailerEntity)
    lib.callback.await('cipher-trucking:server:registerTrailer', false, trailerNetId)

    -- Started after both vehicles exist — the burn loop reads truckEntity
    -- and trailerEntity directly.
    if Fuel then Fuel.Begin(payload) end

    watchForHitch()
    startHookupMarker(asVec3(payload.trailerSpawn), Config.Trucking.hookupRadius)
    setJobBlip(asVec3(payload.trailerSpawn), 'Back up to the trailer to hitch it')
    lib.notify({ description = ('Contract accepted: %s'):format(payload.label), type = 'success' })
    return true
end

-- Compatible truck/trailer pairs (like hauler + trailers2) auto-hitch via
-- the game's own physics when backed up close enough — no manual
-- AttachVehicleToTrailer call needed (and forcing one on top of the game's
-- own hitching caused erratic behavior). This just polls for the game
-- having done it, then reports it to the server.
function watchForHitch()
    CreateThread(function()
        -- The server also requires the trailer to still be near its spawn
        -- point, so a player who hitches up and drives off before the job
        -- registers keeps polling as "attached" while the server keeps
        -- refusing. Without a backoff that's a rejected callback — and an
        -- error toast — every 500ms for as long as the job lives. Retry on
        -- a slow cadence instead, so the hookup still completes if they
        -- reverse back into the bay.
        local nextAttemptAt = 0
        while currentJob and truckEntity and DoesEntityExist(truckEntity)
            and trailerEntity and DoesEntityExist(trailerEntity) do
            Wait(500)
            -- IS_VEHICLE_ATTACHED_TO_TRAILER has no Lua wrapper on this
            -- build — call it by hash instead (see server/main.lua's
            -- trailerAttached for why GET_VEHICLE_TRAILER_VEHICLE isn't
            -- used here). The server independently re-confirms this and
            -- that it's specifically our trailer before advancing the job.
            local attached = Citizen.InvokeNative(0xE7CF3C4F9F489F0C, truckEntity) and true or false
            if attached and GetGameTimer() >= nextAttemptAt then
                if doHookup() then return end
                nextAttemptAt = GetGameTimer() + 5000
            end
        end
    end)
end

function doHookup()
    local ok, err = lib.callback.await('cipher-trucking:server:doHookup', false)
    if not ok then
        lib.notify({ description = err or 'Could not hitch the trailer.', type = 'error' })
        return false
    end

    stopHookupMarker()
    setupDeliverZone()
    local label = #currentJob.stops > 1 and ('Deliver Cargo (Stop 1/%d)'):format(#currentJob.stops) or 'Deliver Cargo'
    setJobBlip(asVec3(currentJob.stops[currentStopIndex]), label)
    lib.notify({ description = 'Trailer hitched — head to the delivery point.', type = 'success' })
    return true
end

local deliverBusy = false

-- Targets whichever stop is current (currentStopIndex) — for single-stop
-- contracts that's always the only entry.
function setupDeliverZone()
    local stop = asVec3(currentJob.stops[currentStopIndex])
    startPrompt(stop, Config.Trucking.deliverRadius, 'Deliver Cargo', doDeliver, function()
        -- Requires the TRAILER (not just the player/truck) to actually be
        -- in the zone, so you can't just drive the truck through and hit E.
        return trailerEntity and DoesEntityExist(trailerEntity)
            and #(GetEntityCoords(trailerEntity) - stop) <= Config.Trucking.deliverRadius
    end)
end

function doDeliver()
    if deliverBusy then return end
    deliverBusy = true
    local ok, result = lib.callback.await('cipher-trucking:server:doDeliver', false)
    deliverBusy = false
    if not ok then
        lib.notify({ description = result or 'Could not deliver here.', type = 'error' })
        return
    end

    if result and not result.isFinalStop then
        -- More stops on this route — trailer stays hitched, move on to the
        -- next one instead of wrapping up the job.
        currentStopIndex = result.stopIndex
        stopPrompt()
        setupDeliverZone()
        setJobBlip(asVec3(currentJob.stops[currentStopIndex]),
            ('Deliver Cargo (Stop %d/%d)'):format(currentStopIndex, result.stopCount))
        lib.notify({ description = ('Stop delivered — %d of %d done.'):format(currentStopIndex - 1, result.stopCount), type = 'success' })
        return
    end

    stopPrompt()
    -- Cargo's delivered — the trailer's done its job, only the truck drives
    -- back to the depot. Server already deleted it authoritatively; this
    -- just clears the local reference/handles the case it's already gone.
    clearTrailer()
    setupReturnZone()
    setJobBlip(asVec3(currentJob.truckSpawn), 'Return the Truck')
    lib.notify({ description = 'Delivered — bring the truck back to the depot.', type = 'success' })
end

local returnBusy = false

function setupReturnZone()
    startPrompt(asVec3(currentJob.truckSpawn), Config.Trucking.returnRadius, 'Return Truck', doReturn)
end

function doReturn()
    if returnBusy then return end
    returnBusy = true
    local ok, err = lib.callback.await('cipher-trucking:server:doReturn', false)
    returnBusy = false
    if not ok then
        lib.notify({ description = err or 'Could not return here.', type = 'error' })
        return
    end
    stopPrompt()
    -- server fires cipher-trucking:client:cleanupVehicles on success, which
    -- tears everything down — nothing else to do here.
end

RegisterNetEvent('cipher-trucking:client:cleanupVehicles', function()
    -- Flushed before the vehicles go away, so the last few percent of the
    -- tank is persisted rather than lost with the entity.
    if Fuel then Fuel.Stop() end

    clearTruck()
    clearTrailer()
    stopPrompt()
    stopHookupMarker()
    if jobBlip then RemoveBlip(jobBlip); jobBlip = nil end
    hudState.target = nil
    currentJob = nil
    currentStopIndex = 1
end)

-- Defined here rather than in fuel.lua because the HUD thread below runs
-- from resource start, before fuel.lua has necessarily fetched its config.
function cipherFuelLow()
    if not Fuel or not Fuel.active then return false end
    local warn = Config.Trucking.Maintenance
        and Config.Trucking.Maintenance.Fuel
        and Config.Trucking.Maintenance.Fuel.lowWarnPct or 20
    return Fuel.level <= warn
end

-- ── Driving HUD ──────────────────────────────────────────────
-- One persistent thread from resource start (not per-job) — cheap no-op
-- whenever hudState.target is nil. Independent of SetNuiFocus/#app-overlay
-- entirely, so it stays visible while the player is actually driving with
-- the dashboard closed.
CreateThread(function()
    local shown = false
    while true do
        Wait(250)
        if hudState.target then
            local distance = #(GetEntityCoords(PlayerPedId()) - hudState.target)
            SendNUIMessage({
                action = 'hud',
                data = {
                    label = hudState.label,
                    distance = distance,
                    stopIndex = hudState.stopIndex,
                    stopCount = hudState.stopCount,
                    -- nil when maintenance is disabled, which hides the
                    -- gauge rather than showing a permanently full tank.
                    fuel = (Fuel and Fuel.active) and Fuel.level or nil,
                    fuelLow = (Fuel and Fuel.active and cipherFuelLow()) or false,
                },
            })
            shown = true
        elseif shown then
            SendNUIMessage({ action = 'hud', data = nil })
            shown = false
        end
    end
end)

-- ── NUI callbacks ────────────────────────────────────────────
-- Thin proxies to the matching server lib.callback — the dashboard talks to
-- Lua, Lua talks to the server, nothing NUI-specific lives server-side.
RegisterNUICallback('close', function(_, cb)
    uiOpen = false
    SetNuiFocus(false, false)
    cb({})
end)

-- Static world geometry the Map tab projects onto its canvas. Served from
-- the client's own Config copy — it's a shared_script, so a server round
-- trip here would buy nothing.
RegisterNUICallback('getMapMeta', function(_, cb)
    local truckSpawns = {}
    for i, s in ipairs(Config.Trucking.truckSpawns) do
        truckSpawns[i] = { x = s.x, y = s.y, z = s.z }
    end
    local trailerSpawns = {}
    for i, s in ipairs(Config.Trucking.trailerSpawns) do
        trailerSpawns[i] = { x = s.x, y = s.y, z = s.z }
    end

    -- Fuel stations, flattened the same way — vec3 userdata doesn't survive
    -- JSON encoding to the NUI. Empty when maintenance is disabled, which
    -- simply renders no station markers.
    local stations = {}
    local mCfg = Config.Trucking.Maintenance
    if mCfg and mCfg.enabled then
        for i, s in ipairs(mCfg.Stations or {}) do
            stations[i] = { label = s.label, coords = { x = s.coords.x, y = s.coords.y, z = s.coords.z } }
        end
    end

    cb({
        depot = {
            x = Config.Trucking.jobLocation.x,
            y = Config.Trucking.jobLocation.y,
            z = Config.Trucking.jobLocation.z,
            label = Config.Trucking.blip.label,
        },
        truckSpawns = truckSpawns,
        trailerSpawns = trailerSpawns,
        stations = stations,
    })
end)

RegisterNUICallback('getAnalytics', function(_, cb)
    cb(lib.callback.await('cipher-trucking:server:getAnalytics', false))
end)

RegisterNUICallback('getHistory', function(_, cb)
    cb(lib.callback.await('cipher-trucking:server:getHistory', false) or {})
end)

-- Streams the player's own position to the Map tab so the "you are here"
-- marker and the live route line track in real time. Only runs while the
-- dashboard is actually open, and at a deliberately lazy 500ms — the map is
-- a planning surface, not a minimap, so smoothness isn't worth the traffic.
CreateThread(function()
    while true do
        if uiOpen then
            local coords = GetEntityCoords(PlayerPedId())
            SendNUIMessage({
                action = 'mapTick',
                data = {
                    x = coords.x, y = coords.y,
                    heading = GetEntityHeading(PlayerPedId()),
                    inVehicle = IsPedInAnyVehicle(PlayerPedId(), false),
                },
            })
            Wait(500)
        else
            Wait(1000)
        end
    end
end)

RegisterNUICallback('getContracts', function(_, cb)
    cb(lib.callback.await('cipher-trucking:server:getContracts', false) or {})
end)

RegisterNUICallback('acceptContract', function(data, cb)
    local ok = acceptContract(data.contractId)
    cb({ ok = ok })
end)

RegisterNUICallback('getCareer', function(_, cb)
    cb(lib.callback.await('cipher-trucking:server:getCareer', false))
end)

RegisterNUICallback('getActiveJob', function(_, cb)
    cb(lib.callback.await('cipher-trucking:server:getActiveJob', false))
end)

RegisterNUICallback('getLeaderboard', function(_, cb)
    cb(lib.callback.await('cipher-trucking:server:getLeaderboard', false) or {})
end)

RegisterNUICallback('getGarage', function(_, cb)
    cb(lib.callback.await('cipher-trucking:server:getGarage', false))
end)

RegisterNUICallback('buyVehicle', function(data, cb)
    local ok, err = lib.callback.await('cipher-trucking:server:buyVehicle', false, data.shopId)
    cb({ ok = ok, message = err })
end)

RegisterNUICallback('selectTruck', function(data, cb)
    local ok, err = lib.callback.await('cipher-trucking:server:selectTruck', false, data.ownedId)
    cb({ ok = ok, message = err })
end)

RegisterNUICallback('selectTrailer', function(data, cb)
    local ok, err = lib.callback.await('cipher-trucking:server:selectTrailer', false, data.ownedId)
    cb({ ok = ok, message = err })
end)

RegisterNUICallback('repairVehicle', function(data, cb)
    local ok, err = lib.callback.await('cipher-trucking:server:repairVehicle', false, data.ownedId)
    cb({ ok = ok, message = err })
end)

RegisterNUICallback('dispatchVehicle', function(data, cb)
    local ok, err = lib.callback.await('cipher-trucking:server:dispatchVehicle', false, data.ownedId, data.contractId)
    cb({ ok = ok, message = err })
end)

RegisterNUICallback('collectVehicle', function(data, cb)
    local ok, err = lib.callback.await('cipher-trucking:server:collectVehicle', false, data.ownedId)
    cb({ ok = ok, message = err })
end)

RegisterNUICallback('upgradeVehicle', function(data, cb)
    local ok, err = lib.callback.await('cipher-trucking:server:upgradeVehicle', false, data.ownedId, data.upgradeId)
    cb({ ok = ok, message = err })
end)

RegisterNUICallback('getCompanyLeaderboard', function(_, cb)
    cb(lib.callback.await('cipher-trucking:server:getCompanyLeaderboard', false) or {})
end)

-- ── Company NUI callbacks ────────────────────────────────────
RegisterNUICallback('getCompany', function(_, cb)
    if Config.Debug then print('^3[cipher-trucking]^0 getCompany: NUI request received, awaiting server...') end
    local startedAt = GetGameTimer()
    local result = lib.callback.await('cipher-trucking:server:getCompany', false)
    if Config.Debug then print(('^3[cipher-trucking]^0 getCompany: server responded after %dms'):format(GetGameTimer() - startedAt)) end
    cb(result)
end)

RegisterNUICallback('foundCompany', function(data, cb)
    local ok, err = lib.callback.await('cipher-trucking:server:foundCompany', false, data.name)
    cb({ ok = ok, message = err })
end)

RegisterNUICallback('companyKick', function(data, cb)
    local ok, err = lib.callback.await('cipher-trucking:server:companyKick', false, data.citizenid)
    cb({ ok = ok, message = err })
end)

RegisterNUICallback('companySetGrade', function(data, cb)
    local ok, err = lib.callback.await('cipher-trucking:server:companySetGrade', false, data.citizenid, data.grade)
    cb({ ok = ok, message = err })
end)

RegisterNUICallback('companyDeposit', function(data, cb)
    local ok, result = lib.callback.await('cipher-trucking:server:companyDeposit', false, data.amount)
    cb({ ok = ok, balance = ok and result or nil, message = (not ok) and result or nil })
end)

RegisterNUICallback('companyWithdraw', function(data, cb)
    local ok, result = lib.callback.await('cipher-trucking:server:companyWithdraw', false, data.amount)
    cb({ ok = ok, balance = ok and result or nil, message = (not ok) and result or nil })
end)

RegisterNUICallback('companyGetLedger', function(_, cb)
    cb(lib.callback.await('cipher-trucking:server:companyGetLedger', false) or {})
end)

RegisterNUICallback('companyBuyVehicle', function(data, cb)
    local ok, err = lib.callback.await('cipher-trucking:server:companyBuyVehicle', false, data.shopId)
    cb({ ok = ok, message = err })
end)

RegisterNUICallback('companyBuyPerk', function(data, cb)
    local ok, err = lib.callback.await('cipher-trucking:server:companyBuyPerk', false, data.perkId)
    cb({ ok = ok, message = err })
end)

RegisterNUICallback('disbandCompany', function(_, cb)
    local ok, err = lib.callback.await('cipher-trucking:server:disbandCompany', false)
    cb({ ok = ok, message = err })
end)

RegisterNUICallback('serviceVehicle', function(data, cb)
    local ok, err = lib.callback.await('cipher-trucking:server:serviceVehicle', false, data.ownedId, data.componentId)
    cb({ ok = ok, message = err })
end)

RegisterNUICallback('paintVehicle', function(data, cb)
    local ok, err = lib.callback.await('cipher-trucking:server:paintVehicle', false, data.ownedId, data.primaryId, data.secondaryId)
    cb({ ok = ok, message = err })
end)

-- ── Depot setup ──────────────────────────────────────────────
CreateThread(function()
    exports.ox_target:addBoxZone({
        coords = asVec3(Config.Trucking.computerCoords),
        size = Config.Trucking.computerZoneSize,
        rotation = Config.Trucking.computerCoords.w,
        debug = Config.Debug,
        options = {
            {
                name = 'cipher_trucking_computer',
                icon = 'fa-solid fa-computer',
                label = 'Delivery Contracts',
                distance = Config.Trucking.computerZoneDistance,
                onSelect = openJobBoard,
            },
        },
    })

    depotBlip = AddBlipForCoord(Config.Trucking.jobLocation.x, Config.Trucking.jobLocation.y, Config.Trucking.jobLocation.z)
    SetBlipSprite(depotBlip, Config.Trucking.blip.sprite)
    SetBlipColour(depotBlip, Config.Trucking.blip.color)
    SetBlipScale(depotBlip, Config.Trucking.blip.scale)
    SetBlipAsShortRange(depotBlip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(Config.Trucking.blip.label)
    EndTextCommandSetBlipName(depotBlip)
end)
