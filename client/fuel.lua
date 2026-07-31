-- ─────────────────────────────────────────────────────────────
-- Fuel & maintenance (client)
--
-- The client owns the burn calculation because it's the only side that
-- knows distance covered, whether a trailer is hitched, and whether the
-- engine is idling. It reports the result to the server, which clamps it
-- and only ever accepts a value LOWER than what it already has — so this
-- being client-driven can't be turned into free fuel.
--
-- Distance is measured by sampling the truck's position, not by reading
-- the speedometer and integrating: sampling stays accurate through lag
-- spikes and teleports in a way that speed × time does not.
-- ─────────────────────────────────────────────────────────────

Fuel = {
    active = false,
    level = 100,
    ownedId = nil,
    drivenKm = 0,
}

local cfgCache = nil
local lastPos = nil
local lastReport = 0
local lastIdleCheck = 0
local warnedLow = false
local warnedEmpty = false
local stationBlips = {}

local function cfg()
    return cfgCache
end

-- ── Setup ────────────────────────────────────────────────────
CreateThread(function()
    cfgCache = lib.callback.await('cipher-trucking:server:getMaintenanceConfig', false)
    if not cfgCache or not cfgCache.enabled then return end

    for _, s in ipairs(cfgCache.stations or {}) do
        local blip = AddBlipForCoord(s.coords.x, s.coords.y, s.coords.z)
        SetBlipSprite(blip, 361)      -- fuel pump
        SetBlipColour(blip, 21)
        SetBlipScale(blip, 0.55)
        SetBlipAsShortRange(blip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(s.label or 'Fuel')
        EndTextCommandSetBlipName(blip)
        stationBlips[#stationBlips + 1] = blip
    end

    -- One box zone per station. Registered once at startup rather than
    -- created and destroyed per job, since the pumps don't move.
    for i, s in ipairs(cfgCache.stations or {}) do
        exports.ox_target:addBoxZone({
            coords = s.coords,
            size = vec3(cfgCache.stationRadius or 6.0, cfgCache.stationRadius or 6.0, 4.0),
            debug = Config.Debug,
            options = {
                {
                    name = ('cipher_trucking_fuel_%d'):format(i),
                    icon = 'fa-solid fa-gas-pump',
                    label = 'Refuel Truck',
                    distance = 3.5,
                    -- Only offered while you're actually in the job truck;
                    -- this resource has no business refuelling anything else.
                    canInteract = function()
                        return Fuel.active and IsPedInVehicle(PlayerPedId(), truckEntity or 0, false)
                    end,
                    onSelect = function() Fuel.OpenRefuel() end,
                },
            },
        })
    end
end)

-- ── Run lifecycle ────────────────────────────────────────────
function Fuel.Begin(payload)
    if not cfg() or not cfg().enabled or not payload.maintenance then return end
    Fuel.active = true
    Fuel.level = payload.startFuel or 100
    Fuel.ownedId = payload.ownedTruckId
    Fuel.drivenKm = 0
    lastPos = nil
    warnedLow, warnedEmpty = false, false
end

function Fuel.Stop()
    if Fuel.active and Fuel.ownedId then
        TriggerServerEvent('cipher-trucking:server:reportFuel', Fuel.ownedId, Fuel.level)
    end
    Fuel.active = false
    Fuel.ownedId = nil
    lastPos = nil
end

function Fuel.OpenRefuel()
    if not Fuel.active then return end

    local price = cfg().pricePerPercent or 0
    local missing = math.max(0, 100 - Fuel.level)
    if missing <= 0 then
        lib.notify({ description = 'The tank is already full.', type = 'inform' })
        return
    end

    -- The free depot truck has no owned row, so there's nothing to bill and
    -- nothing to persist — it just fills.
    local costFull = Fuel.ownedId and math.ceil(missing * price) or 0

    local options = {
        { title = ('Fill the tank (%d%%)'):format(missing),
          description = costFull > 0 and ('$%d'):format(costFull) or 'Free — depot truck',
          icon = 'gas-pump', args = 100 },
    }
    if Fuel.level < 50 then
        local half = math.max(0, 50 - Fuel.level)
        options[#options + 1] = {
            title = 'Half tank (50%)',
            description = Fuel.ownedId and ('$%d'):format(math.ceil(half * price)) or 'Free — depot truck',
            icon = 'gas-pump', args = 50,
        }
    end

    lib.registerContext({
        id = 'cipher_trucking_refuel',
        title = ('Refuel — currently %d%%'):format(math.floor(Fuel.level)),
        options = (function()
            local out = {}
            for _, o in ipairs(options) do
                out[#out + 1] = {
                    title = o.title, description = o.description, icon = o.icon,
                    onSelect = function()
                        local ok, result = lib.callback.await(
                            'cipher-trucking:server:refuelVehicle', false, Fuel.ownedId, o.args)
                        if not ok then
                            lib.notify({ description = result or 'Could not refuel.', type = 'error' })
                            return
                        end
                        Fuel.level = (type(result) == 'table' and result.fuel) or o.args
                        warnedLow, warnedEmpty = false, false
                        lib.notify({ description = ('Refuelled to %d%%.'):format(Fuel.level), type = 'success' })
                    end,
                }
            end
            return out
        end)(),
    })
    lib.showContext('cipher_trucking_refuel')
end

-- ── Burn loop ────────────────────────────────────────────────
CreateThread(function()
    while true do
        Wait(1000)

        if not Fuel.active or not cfg() or not cfg().enabled then goto continue end
        if not truckEntity or not DoesEntityExist(truckEntity) then goto continue end

        local pos = GetEntityCoords(truckEntity)

        if lastPos then
            local metres = #(pos - lastPos)
            -- Ignore implausible jumps: a teleport, a respawn or a warp
            -- would otherwise drain the tank in one tick.
            if metres < 400 then
                local km = metres / 1000
                Fuel.drivenKm = Fuel.drivenKm + km

                local burn = km * (cfg().burnPerKm or 0)
                if trailerEntity and DoesEntityExist(trailerEntity) then
                    burn = burn * (cfg().loadedMult or 1)
                end
                Fuel.level = math.max(0, Fuel.level - burn)
            end
        end
        lastPos = pos

        -- Idle burn, charged only while stationary with the engine running,
        -- so parking up at a stop still costs a little.
        if GetIsVehicleEngineRunning(truckEntity) and GetEntitySpeed(truckEntity) < 1.0 then
            Fuel.level = math.max(0, Fuel.level - ((cfg().idleBurnPerMinute or 0) / 60))
        end

        Fuel.ApplyPenalties()
        Fuel.Warn()

        -- Persisted every 15s rather than every tick — often enough that a
        -- crash loses almost nothing, rare enough not to hammer the DB.
        if Fuel.ownedId and (GetGameTimer() - lastReport) > 15000 then
            lastReport = GetGameTimer()
            TriggerServerEvent('cipher-trucking:server:reportFuel', Fuel.ownedId, Fuel.level)
        end

        ::continue::
    end
end)

-- Wear penalties are applied client-side because they're all handling
-- effects. The authoritative wear VALUES still live on the server; this
-- only reads what it was told at spawn.
Fuel.wear = {}

function Fuel.ApplyPenalties()
    local pen = cfg() and cfg().penalties
    if not pen or not truckEntity or not DoesEntityExist(truckEntity) then return end

    if Fuel.level <= 0 then
        SetVehicleEngineOn(truckEntity, false, true, true)
        SetVehicleUndriveable(truckEntity, true)
    else
        SetVehicleUndriveable(truckEntity, false)
    end

    if (Fuel.wear.tyres or 100) < (pen.tyresGripBelow or 0) then
        SetVehicleReduceGrip(truckEntity, true)
    end

    if (Fuel.wear.oil or 100) < (pen.oilEngineDrainBelow or 0) and GetEntitySpeed(truckEntity) > 2.0 then
        local health = GetVehicleEngineHealth(truckEntity)
        SetVehicleEngineHealth(truckEntity, math.max(200.0, health - ((pen.oilEngineDrainPerMinute or 0) / 60)))
    end
end

function Fuel.Warn()
    local low = cfg().lowWarnPct or 20

    if Fuel.level <= 0 and not warnedEmpty then
        warnedEmpty = true
        lib.notify({ title = 'Out of fuel',
            description = 'The engine has cut out. Find a fuel station.', type = 'error', duration = 8000 })
    elseif Fuel.level > 0 and Fuel.level <= low and not warnedLow then
        warnedLow = true
        lib.notify({ title = 'Low fuel',
            description = ('Tank at %d%% — find a station.'):format(math.floor(Fuel.level)), type = 'warning' })
    elseif Fuel.level > low then
        warnedLow = false
    end
end

RegisterNetEvent('cipher-trucking:client:setWear', function(wear)
    Fuel.wear = wear or {}
end)
