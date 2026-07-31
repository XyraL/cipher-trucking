-- ─────────────────────────────────────────────────────────────
-- Job state
-- One active delivery per player, in-memory only (no DB persistence for
-- in-progress jobs — matching the pattern used elsewhere in this codebase
-- for personal task/job loops). job shape:
--   { contractId, stage, truckSpawn, trailerSpawn, stops, stopIndex,
--     truckNetId, trailerNetId, startedAt, ownedTruckId, payoutBonusPct,
--     hotBonusPct, companyId, baselineHealth, spoiled }
-- stage progresses: 'hookup' -> 'enroute' -> 'return' -> (completed, cleared)
-- `stops` is every contract's destination(s) normalized to a list (single-
-- stop contracts just have one entry) — `stopIndex` tracks progress through
-- it, only advancing to 'return' once every stop is delivered.
-- ─────────────────────────────────────────────────────────────
local active = {}

-- Which owned truck/trailer (cipher_trucking_owned.id) a player has selected
-- to use on their next contract instead of the free depot truck/trailer.
-- Transient, in-memory only — resets on reconnect, same as `active`.
local selectedTruck = {}
local selectedTrailer = {}

-- Currently rotated-in hot contracts + when they last rotated — see
-- ensureHotRotation(). Declared here (rather than next to that function) so
-- findContract() below can close over it regardless of definition order.
local hotContracts, hotRotatedAt = {}, 0

-- ── Geometry helpers ────────────────────────────────────────
local function asVec3(v)
    return vec3(v.x, v.y, v.z)
end

local function dist(a, b)
    return #(asVec3(a) - asVec3(b))
end

-- Resolves job.truckNetId server-side and checks its REAL position against
-- coords — never trusts a client-claimed position. Same anti-cheat shape
-- used for the trailer below.
local function truckNear(job, coords, radius)
    if not job or not job.truckNetId then return false end
    local veh = NetworkGetEntityFromNetworkId(job.truckNetId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return false end
    return dist(GetEntityCoords(veh), coords) <= (radius or 6.0)
end

local function trailerNear(job, coords, radius)
    if not job or not job.trailerNetId then return false end
    local veh = NetworkGetEntityFromNetworkId(job.trailerNetId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return false end
    return dist(GetEntityCoords(veh), coords) <= (radius or 6.0)
end

-- Confirms the trailer is close enough to THIS job's truck to count as
-- hitched.
--
-- No native check here — IS_VEHICLE_ATTACHED_TO_TRAILER and
-- GET_VEHICLE_TRAILER_VEHICLE both lack Lua wrappers on this build, and
-- even calling the bool-only one by hash server-side didn't reflect the
-- client's own hitch state (attachment is client-driven physics that isn't
-- reliably queryable server-side the same way). Pure proximity instead —
-- not meant to resist a determined cheater parking an unhitched trailer
-- nearby, just a sanity check that both vehicles are actually together.
local function trailerAttached(job)
    if not job or not job.truckNetId or not job.trailerNetId then return false end
    local truck = NetworkGetEntityFromNetworkId(job.truckNetId)
    local trailer = NetworkGetEntityFromNetworkId(job.trailerNetId)
    if not truck or truck == 0 or not DoesEntityExist(truck) then return false end
    if not trailer or trailer == 0 or not DoesEntityExist(trailer) then return false end

    local gap = dist(GetEntityCoords(truck), GetEntityCoords(trailer))
    if Config.Debug then
        print(('^3[cipher-trucking]^0 truck-trailer distance: %.2f'):format(gap))
    end
    return gap <= 20.0
end

-- ── Spawn-point selection ───────────────────────────────────
-- Only 4 slots exist in each pool and this is meant for live multiplayer
-- use, so pick the least-recently-used slot instead of pure random to
-- spread jobs out rather than stacking rigs on top of each other.
local lastUsedTruckSpawn = {}
local lastUsedTrailerSpawn = {}

local function pickSpawn(pool, lastUsed)
    local bestIdx, bestTime = 1, math.huge
    for i = 1, #pool do
        local t = lastUsed[i] or 0
        if t < bestTime then
            bestIdx, bestTime = i, t
        end
    end
    lastUsed[bestIdx] = GetGameTimer()
    return pool[bestIdx]
end

-- qbx_vehiclekeys' GiveKeys export is server-side and needs the server's
-- own resolved vehicle handle (not the client's local one) plus the
-- player's source — this is the only KeysResource option handled here
-- rather than client-side, see client/main.lua's giveVehicleKeys.
local function giveVehicleKeysServer(src, veh)
    if Config.Trucking.KeysResource ~= 'qbx' then return end

    local ok, err = pcall(function() exports.qbx_vehiclekeys:GiveKeys(src, veh, false) end)
    if not ok and Config.Debug then
        print(('^1[cipher-trucking]^0 giveVehicleKeys (qbx_vehiclekeys) failed: %s'):format(tostring(err)))
    end
end

-- ── Stats / progression ─────────────────────────────────────
-- The returned table must mirror EVERY column callers read off it (see
-- rewardPlayer / getCareer / truckingAchievementsFor) — rating_sum included,
-- or a brand new driver's first delivery indexes a nil. INSERT IGNORE +
-- .await so two near-simultaneous calls for the same fresh character can't
-- both miss the SELECT and race a duplicate-key insert.
local function ensureStats(cid, name)
    -- Chokepoint: nearly every read path in this file runs through here, so
    -- one gate covers them all. A player interacting inside the first second
    -- of a restart would otherwise query tables that don't exist yet.
    if not WaitForDB() then
        return { citizenid = cid, name = name or '',
                 xp = 0, level = 1, total_completed = 0, total_earned = 0, rating_sum = 0 }
    end

    local row = MySQL.single.await('SELECT * FROM cipher_trucking_stats WHERE citizenid = ?', { cid })
    if row then return row end
    MySQL.insert.await('INSERT IGNORE INTO cipher_trucking_stats (citizenid, name) VALUES (?, ?)', { cid, name or '' })
    return {
        citizenid = cid, name = name or '',
        xp = 0, level = 1, total_completed = 0, total_earned = 0, rating_sum = 0,
    }
end

local function truckingLevelForXp(xp)
    local level = 1
    for _, def in ipairs(Config.TruckingLevels) do
        if xp >= def.xpNeeded then level = def.level end
    end
    return level
end

local function levelDefFor(level)
    for _, def in ipairs(Config.TruckingLevels) do
        if def.level == level then return def end
    end
    return Config.TruckingLevels[1]
end

-- Searches both the regular pool and whichever hot contracts are currently
-- rotated in — returns (def, isHot).
local function findContract(contractId)
    for _, c in ipairs(Config.Trucking.Contracts) do
        if c.id == contractId then return c, false end
    end
    for _, c in ipairs(hotContracts) do
        if c.id == contractId then return c, true end
    end
    return nil, false
end

-- Every contract normalizes to an ordered stop list — single-`destination`
-- contracts just have one stop — so the job state machine has one code
-- path instead of branching on single vs. multi-stop.
local function contractStops(def)
    if def.stops and #def.stops > 0 then return def.stops end
    return { def.destination }
end

-- Straight-line length of the whole run: trailer pickup, every stop in
-- order, then back to the depot. Not road distance (nothing here pathfinds),
-- so treat it as a comparative figure — it drives the Map tab's route
-- readout and the distance column on the delivery log, both of which only
-- need contracts to rank sensibly against each other.
local function routeDistanceFor(def, trailerSpawn, depot)
    local stops = contractStops(def)
    local total, prev = 0, trailerSpawn or depot
    for _, stop in ipairs(stops) do
        if prev then total = total + dist(prev, stop) end
        prev = stop
    end
    if prev and depot then total = total + dist(prev, depot) end
    return total
end

-- ── Hot contracts ─────────────────────────────────────────────
-- Rotation is computed lazily (checked whenever the contract board is
-- requested) rather than on a persistent timer, so it survives resource
-- restarts without losing its schedule.
local function ensureHotRotation()
    local cfg = Config.Trucking.HotContracts
    if not cfg then hotContracts = {} return end
    -- Read live so an admin toggling this in the Control tab takes effect on
    -- the next board request rather than at the next restart.
    if not SGet('hot.enabled', cfg.enabled) then hotContracts = {} return end

    local rotateMinutes = SGet('hot.rotateMinutes', cfg.rotateMinutes)
    local now = os.time()
    if #hotContracts > 0 and (now - hotRotatedAt) < (rotateMinutes * 60) then return end

    hotRotatedAt = now
    local pool = {}
    for i, c in ipairs(cfg.pool) do pool[i] = c end
    for i = #pool, 2, -1 do
        local j = math.random(i)
        pool[i], pool[j] = pool[j], pool[i]
    end

    hotContracts = {}
    for i = 1, math.min(SGet('hot.activeCount', cfg.activeCount), #pool) do
        hotContracts[i] = pool[i]
    end
end

local function hotExpiresInSeconds()
    local cfg = Config.Trucking.HotContracts
    local rotateMinutes = SGet('hot.rotateMinutes', cfg and cfg.rotateMinutes or 30)
    return math.max(0, (rotateMinutes * 60) - (os.time() - hotRotatedAt))
end

-- ── Truck/trailer shop / garage ────────────────────────────────
local function findShopEntry(shopId)
    for _, s in ipairs(Config.Trucking.Shop) do
        if s.id == shopId then return s end
    end
    return nil
end

-- Owned vehicles don't store which shop entry they came from, only their
-- model — fine as long as shop models stay unique, which the default
-- config keeps true.
local function findShopEntryByModel(model)
    for _, s in ipairs(Config.Trucking.Shop) do
        if s.model == model then return s end
    end
    return nil
end

-- Resolves an owned truck/trailer USABLE by this player right now — either
-- personally owned, or company-owned by their own company (any member can
-- drive company vehicles; buying/dispatching/repairing them needs
-- manage_vehicles, checked separately at those call sites).
local function getUsableVehicle(src, cid, ownedId, kind)
    if not ownedId then return nil end
    local row = MySQL.single.await('SELECT * FROM cipher_trucking_owned WHERE id = ? AND kind = ?', { ownedId, kind })
    if not row then return nil end
    if row.company_id then
        local company = Company.GetBySource(src)
        if not company or company.id ~= row.company_id then return nil end
        return row
    end
    if row.citizenid == cid then return row end
    return nil
end

-- Live-computed against current stats every time it's requested — no
-- separate "earned" tracking table, same pattern as cipher's boosting
-- achievements.
local function truckingAchievementsFor(stats)
    local list = {}
    for _, def in ipairs(Config.TruckingAchievements) do
        local progress = stats.total_completed
        if def.type == 'level' then
            progress = stats.level
        elseif def.type == 'total_earned' then
            progress = stats.total_earned
        end
        list[#list + 1] = {
            id = def.id,
            label = def.label,
            description = def.description,
            earned = progress >= def.value,
        }
    end
    return list
end

-- ── Driver rating ────────────────────────────────────────────
-- This trip's 0-100 cleanliness score, from damage taken on whichever
-- truck was used (free depot truck included, unlike condition-loss
-- tracking which is owned-truck only). Falls back to a clean 100 if there's
-- no baseline to compare against (shouldn't normally happen).
local function tripRatingScore(job)
    if not job or not job.truckNetId or not job.baselineHealth then return 100 end
    local veh = NetworkGetEntityFromNetworkId(job.truckNetId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return 100 end

    local currentHealth = GetVehicleBodyHealth(veh) + GetVehicleEngineHealth(veh)
    local damage = math.max(0, job.baselineHealth - currentHealth)
    local score = 100 - math.floor(damage / SGet('vehicle.ratingDamageDivisor', Config.Trucking.ratingDamageDivisor))
    return math.max(0, math.min(100, score))
end

-- ── Reward / completion ─────────────────────────────────────
local function rewardPlayer(src, def, job)
    local cid = Framework.GetCitizenId(src)
    if not cid then return end
    local stats = ensureStats(cid, Framework.GetName(src))

    -- Driver rating average GOING INTO this delivery (not including this
    -- trip's own result, which is only added to rating_sum below) — a
    -- fresh driver with no completed deliveries starts neutral at 100.
    local ratingAvg = stats.total_completed > 0 and (stats.rating_sum / stats.total_completed) or 100

    -- Truck payoutBonusPct, hot-contract bonus, multi-stop bonus, and the
    -- rating bonus/penalty all stack additively, then apply once. Each part
    -- is also kept separately so the delivery log (and the Receipts tab
    -- reading it) can show the player how the number was actually reached.
    local truckBonusPct = job and job.payoutBonusPct or 0
    local hotBonusPct = job and job.hotBonusPct or 0
    local multiStopBonusPct = 0
    local ratingBonusPct = 0

    if job and job.stops and #job.stops > 1 then
        multiStopBonusPct = SGet('bonus.multiStopPct', Config.Trucking.multiStopBonusPct) or 0
    end
    if ratingAvg >= SGet('bonus.ratingBonusThreshold', Config.Trucking.ratingBonusThreshold) then
        ratingBonusPct = SGet('bonus.ratingBonusPct', Config.Trucking.ratingBonusPct)
    elseif ratingAvg <= SGet('bonus.ratingPenaltyThreshold', Config.Trucking.ratingPenaltyThreshold) then
        ratingBonusPct = -SGet('bonus.ratingPenaltyPct', Config.Trucking.ratingPenaltyPct)
    end

    local bonusPct = truckBonusPct + hotBonusPct + multiStopBonusPct + ratingBonusPct

    local payout = def.payout
    if bonusPct ~= 0 then
        payout = math.max(0, math.floor(payout * (1 + bonusPct / 100)))
    end
    -- Global multiplier applies last, on top of every per-contract bonus, so
    -- an admin scaling the whole economy doesn't have to reason about how it
    -- interacts with each individual modifier.
    local payoutMult = SGet('economy.payoutMult', 100)
    if payoutMult ~= 100 then
        payout = math.max(0, math.floor(payout * (payoutMult / 100)))
    end
    -- Reefer cargo delivered past its spoilTimeSeconds — a soft penalty
    -- (halved payout), not a hard failure.
    if job and job.spoiled then
        payout = math.floor(payout * 0.5)
    end

    local xpMult = SGet('economy.xpMult', 100)
    local xpGain = math.max(0, math.floor((def.xp or 0) * (xpMult / 100)))
    local newXp = stats.xp + xpGain
    local newLevel = truckingLevelForXp(newXp)
    local leveledUp = newLevel > stats.level
    local tripScore = tripRatingScore(job)

    MySQL.update(
        'UPDATE cipher_trucking_stats SET xp = ?, level = ?, total_completed = total_completed + 1, total_earned = total_earned + ?, rating_sum = rating_sum + ?, name = ? WHERE citizenid = ?',
        { newXp, newLevel, payout, tripScore, Framework.GetName(src) or cid, cid })

    local driverCut, companyCut = payout, 0

    if job and job.companyId then
        -- Delivered with a company truck — split between the driver and the
        -- company treasury instead of paying the driver in full. Logistics
        -- perk branch can raise the driver's cut of that split.
        local mods = Company.ModifiersFor(job.companyId)
        local driverCutPct = math.min(100,
            SGet('company.driverCutPct', Config.Trucking.Company.driverCutPct) + (mods.driverCutBonusPct or 0))
        driverCut = math.floor(payout * (driverCutPct / 100))
        companyCut = payout - driverCut
        Framework.AddMoney(src, Config.Trucking.payoutAccount, driverCut, 'cipher-trucking:delivery')
        Company.CreditTreasury(job.companyId, companyCut, 'delivery:' .. def.id)
        Company.AddReputation(job.companyId, 15)
        MySQL.update('UPDATE cipher_trucking_companies SET total_deliveries = total_deliveries + 1 WHERE id = ?', { job.companyId })
        Framework.Notify(src,
            ('Delivery complete — +$%d (company kept $%d), +%d XP.'):format(driverCut, companyCut, xpGain), 'success')
    else
        Framework.AddMoney(src, Config.Trucking.payoutAccount, payout, 'cipher-trucking:delivery')
        Framework.Notify(src, ('Delivery complete — +$%d, +%d XP.'):format(payout, xpGain), 'success')
    end

    -- Fire-and-forget on purpose: this is a reporting row, and nothing below
    -- reads it back. A slow insert must never delay paying the player out.
    MySQL.insert([[
        INSERT INTO cipher_trucking_deliveries
            (citizenid, contract_id, label, cargo_type, base_payout, final_payout,
             driver_cut, company_cut, company_id, truck_bonus_pct, hot_bonus_pct,
             multistop_bonus_pct, rating_bonus_pct, spoiled, trip_rating,
             stop_count, xp, distance_m, duration_seconds)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        cid, def.id, def.label or def.id, def.cargoType or '',
        def.payout, payout, driverCut, companyCut, job and job.companyId or nil,
        truckBonusPct, hotBonusPct, multiStopBonusPct, ratingBonusPct,
        (job and job.spoiled) and 1 or 0, tripScore,
        (job and job.stops) and #job.stops or 1, xpGain,
        math.floor((job and job.routeDistance) or 0),
        (job and job.startedAt) and (os.time() - job.startedAt) or 0,
    })

    if leveledUp then
        local lvl = levelDefFor(newLevel)
        Framework.Notify(src, ('Rank up! You are now a %s.'):format(lvl.title), 'success')
    end
end

-- Only applies to owned trucks (job.ownedTruckId set) — the free depot
-- truck never takes tracked damage. Reads the truck's actual current
-- health server-side, same anti-cheat spirit as the position checks above.
local function applyOwnedTruckDamage(job)
    if not job.ownedTruckId or not job.truckNetId or not job.baselineHealth then return end
    local veh = NetworkGetEntityFromNetworkId(job.truckNetId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end

    local currentHealth = GetVehicleBodyHealth(veh) + GetVehicleEngineHealth(veh)
    local damage = job.baselineHealth - currentHealth
    if damage <= 0 then return end

    local rate = SGet('vehicle.conditionLossRate', Config.Trucking.conditionLossRate)

    -- Worn brakes mean collisions hurt more — the one wear component that
    -- feeds back into the condition system rather than standing alone.
    if Maintenance and Maintenance.Enabled() and job.ownedTruckId then
        local pen = Config.Trucking.Maintenance.Penalties
        local m = Maintenance.Load(job.ownedTruckId)
        if (m.brakes or 100) < (pen.brakesDamageBelow or 0) then
            rate = rate * (pen.brakesDamageMult or 1)
        end
    end

    local conditionLoss = math.floor(damage * rate)
    if conditionLoss <= 0 then return end

    MySQL.update('UPDATE cipher_trucking_owned SET `condition` = GREATEST(0, `condition` - ?) WHERE id = ?',
        { conditionLoss, job.ownedTruckId })
end

-- Damage taken across the whole trip, in body+engine health points. Read
-- before the vehicle is cleaned up, and shared by condition loss, driver
-- rating and component wear so all three agree on what "a rough trip" means.
local function tripDamage(job)
    if not job or not job.truckNetId or not job.baselineHealth then return 0 end
    local veh = NetworkGetEntityFromNetworkId(job.truckNetId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return 0 end
    return math.max(0, job.baselineHealth - (GetVehicleBodyHealth(veh) + GetVehicleEngineHealth(veh)))
end

local function completeJob(src, job)
    active[src] = nil

    -- Wear is computed BEFORE the cleanup event, since resolving the
    -- vehicle's health needs the entity to still exist.
    local damage = tripDamage(job)
    if Maintenance and Maintenance.Enabled() then
        -- job.drivenKm is reported by the client during the run; fall back
        -- to the planned route length if it never arrived.
        local km = job.drivenKm or ((job.routeDistance or 0) / 1000)
        Maintenance.ApplyTrip(job.ownedTruckId, km, damage)
    end

    TriggerClientEvent('cipher-trucking:client:cleanupVehicles', src, job.truckNetId, job.trailerNetId)

    applyOwnedTruckDamage(job)

    local def = findContract(job.contractId)
    if def then rewardPlayer(src, def, job) end
end

-- Resolves the currently-selected trailer's cargoType (nil if none
-- selected, or it's gone) — used to gate specialized contracts.
local function selectedTrailerCargoType(src, cid)
    local ownedId = selectedTrailer[src]
    if not ownedId then return nil end
    -- Sits directly in the getContracts path, so an ungated query here on a
    -- cold start took the whole Contracts tab down with it.
    if not WaitForDB() then return nil end
    local owned = MySQL.single.await('SELECT model FROM cipher_trucking_owned WHERE id = ? AND citizenid = ? AND kind = ?',
        { ownedId, cid, 'trailer' })
    if not owned then
        selectedTrailer[src] = nil
        return nil
    end
    local shopDef = findShopEntryByModel(owned.model)
    return shopDef and shopDef.cargoType or nil
end

-- ── Callbacks ────────────────────────────────────────────────
lib.callback.register('cipher-trucking:server:getContracts', function(src)
    local cid = Framework.GetCitizenId(src)
    if not cid then return {} end
    local stats = ensureStats(cid, Framework.GetName(src))
    local trailerType = selectedTrailerCargoType(src, cid)

    ensureHotRotation()

    -- Every contract is returned (not just unlocked ones) so the dashboard
    -- can show locked entries grayed out with the reason (rank or trailer),
    -- rather than hiding them outright.
    -- The Map tab draws from this same payload rather than its own callback,
    -- so pins and cards can never disagree about what's on the board.
    local depot = Config.Trucking.jobLocation
    local list = {}
    local function addEntry(c, hot)
        local levelOk = stats.level >= c.minLevel
        local trailerOk = not c.requiredTrailerType or trailerType == c.requiredTrailerType
        local stops = contractStops(c)

        -- Flattened to plain {x,y,z} — vec4 userdata does not survive the
        -- trip through the NUI's JSON encoding intact.
        local stopCoords = {}
        for i, s in ipairs(stops) do
            stopCoords[i] = { x = s.x, y = s.y, z = s.z }
        end

        list[#list + 1] = {
            id = c.id,
            label = c.label,
            cargoType = c.cargoType,
            minLevel = c.minLevel,
            payout = c.payout,
            xp = c.xp,
            requiredTrailerType = c.requiredTrailerType,
            stopCount = #stops,
            stops = stopCoords,
            distance = math.floor(routeDistanceFor(c, nil, depot)),
            spoilTimeSeconds = c.spoilTimeSeconds,
            hot = hot,
            expiresInSeconds = hot and hotExpiresInSeconds() or nil,
            levelOk = levelOk,
            trailerOk = trailerOk,
            unlocked = levelOk and trailerOk,
        }
    end

    for _, c in ipairs(Config.Trucking.Contracts) do addEntry(c, false) end
    for _, c in ipairs(hotContracts) do addEntry(c, true) end

    return list
end)

lib.callback.register('cipher-trucking:server:acceptContract', function(src, contractId)
    if active[src] then return false, 'You already have an active delivery.' end

    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'No character loaded.' end
    local stats = ensureStats(cid, Framework.GetName(src))

    local def, isHot = findContract(contractId)
    if not def then return false, 'Contract not found.' end
    if stats.level < def.minLevel then return false, 'You are not ranked high enough for this contract.' end

    -- If the player has an owned truck selected, use it instead of the free
    -- depot truck — validated fresh here rather than trusting the earlier
    -- selectTruck check, in case its condition/dispatch status changed.
    local ownedTruckId, truckOverride, payoutBonusPct, companyId = nil, nil, nil, nil
    local selectedTruckId = selectedTruck[src]
    if selectedTruckId then
        local owned = getUsableVehicle(src, cid, selectedTruckId, 'truck')
        if not owned then
            selectedTruck[src] = nil
        elseif owned.condition <= 0 then
            return false, 'Your selected truck needs repairs first.'
        elseif owned.dispatch_ready_at then
            return false, 'Your selected truck is out on a dispatch run.'
        else
            local shopDef = findShopEntryByModel(owned.model)
            ownedTruckId = owned.id
            payoutBonusPct = shopDef and shopDef.payoutBonusPct or 0
            -- upgrades/livery are the raw JSON strings from the DB columns —
            -- the client parses them itself before applying SetVehicleMod/
            -- SetVehicleColours, no need to decode server-side just to
            -- re-encode.
            truckOverride = { model = owned.model, label = owned.label, upgrades = owned.upgrades, livery = owned.livery }
            companyId = owned.company_id
        end
    end

    -- Specialized cargo requires an owned+selected trailer whose cargoType
    -- matches — the free depot trailer only covers 'general'. A selected
    -- trailer is used even for general cargo if you have one (cosmetic
    -- upgrade, no functional requirement in that case).
    local trailerOverride = nil
    local selectedTrailerId = selectedTrailer[src]
    if def.requiredTrailerType then
        if not selectedTrailerId then
            return false, ('Requires a %s trailer — select one in the Garage.'):format(def.requiredTrailerType)
        end
        local ownedTrailer = getUsableVehicle(src, cid, selectedTrailerId, 'trailer')
        if not ownedTrailer then
            selectedTrailer[src] = nil
            return false, 'Your selected trailer is no longer available.'
        end
        local shopDef = findShopEntryByModel(ownedTrailer.model)
        if not shopDef or shopDef.cargoType ~= def.requiredTrailerType then
            return false, ('Requires a %s trailer.'):format(def.requiredTrailerType)
        end
        trailerOverride = { model = ownedTrailer.model, label = ownedTrailer.label }
    elseif selectedTrailerId then
        local ownedTrailer = getUsableVehicle(src, cid, selectedTrailerId, 'trailer')
        if ownedTrailer then
            trailerOverride = { model = ownedTrailer.model, label = ownedTrailer.label }
        end
    end

    local truckSpawn = pickSpawn(Config.Trucking.truckSpawns, lastUsedTruckSpawn)
    local trailerSpawn = pickSpawn(Config.Trucking.trailerSpawns, lastUsedTrailerSpawn)
    local stops = contractStops(def)

    active[src] = {
        contractId = def.id,
        stage = 'hookup',
        truckSpawn = truckSpawn,
        trailerSpawn = trailerSpawn,
        stops = stops,
        stopIndex = 1,
        truckNetId = nil,
        trailerNetId = nil,
        startedAt = os.time(),
        ownedTruckId = ownedTruckId,
        payoutBonusPct = payoutBonusPct,
        hotBonusPct = isHot and SGet('hot.payoutBonusPct', Config.Trucking.HotContracts.payoutBonusPct) or 0,
        companyId = companyId,
        baselineHealth = nil,
        spoiled = false,
        routeDistance = routeDistanceFor(def, trailerSpawn, truckSpawn),
    }

    -- Starting fuel: an owned truck carries over whatever was left in it,
    -- while the free depot truck always starts full so a new driver never
    -- meets the fuel system before completing a single delivery.
    local startFuel = 100
    if Maintenance and Maintenance.Enabled() and ownedTruckId then
        startFuel = Maintenance.Load(ownedTruckId).fuel or 100
    end

    return true, {
        contractId = def.id,
        label = def.label,
        cargoType = def.cargoType,
        truckSpawn = truckSpawn,
        trailerSpawn = trailerSpawn,
        stops = stops,
        truckOverride = truckOverride,
        trailerOverride = trailerOverride,
        ownedTruckId = ownedTruckId,
        startFuel = startFuel,
        maintenance = (Maintenance and Maintenance.Enabled()) or false,
    }
end)

lib.callback.register('cipher-trucking:server:registerTruck', function(src, netId)
    local job = active[src]
    if not job or job.stage ~= 'hookup' then return false end
    job.truckNetId = netId

    -- The client calls this the instant it spawns the truck, which can
    -- race the server actually having the networked entity resolved yet —
    -- NetworkGetEntityFromNetworkId can briefly return 0 right after
    -- creation. Retry a few times instead of silently giving up (which
    -- was skipping the keys grant below intermittently).
    local veh = nil
    for _ = 1, 10 do
        local ent = NetworkGetEntityFromNetworkId(netId)
        if ent and ent ~= 0 and DoesEntityExist(ent) then veh = ent break end
        Wait(100)
    end

    if veh then
        -- Captured for EVERY job now, not just owned trucks — driver rating
        -- (server/main.lua's rewardPlayer) needs a baseline for the free
        -- depot truck too. Condition-loss tracking (applyOwnedTruckDamage)
        -- still only applies this to owned trucks.
        job.baselineHealth = GetVehicleBodyHealth(veh) + GetVehicleEngineHealth(veh)
        giveVehicleKeysServer(src, veh)
    elseif Config.Debug then
        print('^1[cipher-trucking]^0 registerTruck: could not resolve truck entity from netId in time')
    end

    return true
end)

lib.callback.register('cipher-trucking:server:registerTrailer', function(src, netId)
    local job = active[src]
    if not job or job.stage ~= 'hookup' then return false end
    job.trailerNetId = netId
    return true
end)

lib.callback.register('cipher-trucking:server:doHookup', function(src)
    local job = active[src]
    if not job or job.stage ~= 'hookup' then return false, 'No hookup in progress.' end

    -- No player-ped distance check, and no truck-vs-trailerSpawn distance
    -- check either — both compare against the TRAILER's own spawn point,
    -- which doesn't account for the truck's own length. A hitched hauler's
    -- cab can easily sit 10+ meters from the trailer's spawn coords even
    -- when properly coupled. trailerAttached() below already confirms the
    -- truck is genuinely hitched AND within 15m of the trailer, which is
    -- the check that actually matters here.
    if not trailerNear(job, job.trailerSpawn, Config.Trucking.hookupRadius) then
        return false, 'The trailer needs to be here.'
    end
    if not trailerAttached(job) then
        return false, 'The trailer is not hitched.'
    end

    job.stage = 'enroute'
    return true
end)

lib.callback.register('cipher-trucking:server:doDeliver', function(src)
    local job = active[src]
    if not job or job.stage ~= 'enroute' then return false, 'No delivery in progress.' end

    local stop = job.stops[job.stopIndex]
    if not stop then return false, 'No stop to deliver to.' end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false, 'Invalid player.' end

    if dist(GetEntityCoords(ped), stop) > Config.Trucking.deliverRadius then
        return false, 'Get to the delivery point.'
    end
    if not truckNear(job, stop, Config.Trucking.deliverRadius) then
        return false, 'The rig needs to be here too.'
    end
    -- The TRAILER itself has to be in the zone, not just the truck — stops
    -- someone driving the truck through and hitting E without actually
    -- bringing the cargo.
    if not trailerNear(job, stop, Config.Trucking.deliverRadius) then
        return false, 'Bring the trailer into the delivery zone.'
    end

    local isFinalStop = job.stopIndex >= #job.stops

    if not isFinalStop then
        -- More stops on this route — trailer stays hitched, stage stays
        -- 'enroute', just move the target to the next stop.
        job.stopIndex = job.stopIndex + 1
        return true, { isFinalStop = false, stopIndex = job.stopIndex, stopCount = #job.stops }
    end

    -- Final stop — check reefer spoilage against the whole trip's elapsed
    -- time, then the trailer's job is done, only the truck drives back.
    -- Deleted here (authoritative, not just left to the client) so it's
    -- gone even if the client's own cleanup gets skipped somehow.
    local def = findContract(job.contractId)
    if def and def.spoilTimeSeconds and (os.time() - job.startedAt) > def.spoilTimeSeconds then
        job.spoiled = true
        Framework.Notify(src, 'The cargo spoiled en route — payout will be reduced.', 'error')
    end

    if job.trailerNetId then
        local trailer = NetworkGetEntityFromNetworkId(job.trailerNetId)
        if trailer and trailer ~= 0 and DoesEntityExist(trailer) then DeleteEntity(trailer) end
    end

    job.stage = 'return'
    return true, { isFinalStop = true, stopIndex = job.stopIndex, stopCount = #job.stops }
end)

lib.callback.register('cipher-trucking:server:doReturn', function(src)
    local job = active[src]
    if not job or job.stage ~= 'return' then return false, 'No return in progress.' end

    -- Trailer's already gone by this stage (deleted on delivery) — only the
    -- truck needs to come home. ANY of the depot bays counts, not just the
    -- one this job spawned in: they're all the same depot, and requiring the
    -- original slot meant a player who found it occupied on return had
    -- nowhere legal to park.
    local parked = false
    for _, spawn in ipairs(Config.Trucking.truckSpawns) do
        if truckNear(job, spawn, Config.Trucking.returnRadius) then parked = true break end
    end
    if not parked then
        return false, 'Park the truck at the depot.'
    end

    completeJob(src, job)
    return true
end)

-- ── NUI dashboard callbacks ──────────────────────────────────
lib.callback.register('cipher-trucking:server:getCareer', function(src)
    local cid = Framework.GetCitizenId(src)
    if not cid then return nil end
    local stats = ensureStats(cid, Framework.GetName(src))

    local nextLevelXp = nil
    for _, def in ipairs(Config.TruckingLevels) do
        if def.level == stats.level + 1 then nextLevelXp = def.xpNeeded end
    end

    return {
        xp = stats.xp,
        level = stats.level,
        title = levelDefFor(stats.level).title,
        nextLevelXp = nextLevelXp,
        totalCompleted = stats.total_completed,
        totalEarned = stats.total_earned,
        rating = stats.total_completed > 0 and math.floor(stats.rating_sum / stats.total_completed) or 100,
        achievements = truckingAchievementsFor(stats),
    }
end)

lib.callback.register('cipher-trucking:server:getActiveJob', function(src)
    local job = active[src]
    if not job then return nil end
    local def = findContract(job.contractId)

    -- Coordinates come along so the Map tab can plot the run in progress
    -- rather than only the planning view. Flattened to plain {x,y,z}: vec4
    -- userdata doesn't survive JSON encoding to the NUI.
    local stops = {}
    for i, s in ipairs(job.stops or {}) do
        stops[i] = { x = s.x, y = s.y, z = s.z }
    end

    return {
        stage = job.stage,
        contractId = job.contractId,
        label = def and def.label or job.contractId,
        stopIndex = job.stopIndex,
        stopCount = job.stops and #job.stops or 1,
        payout = def and def.payout or nil,
        stops = stops,
        trailerSpawn = job.trailerSpawn and
            { x = job.trailerSpawn.x, y = job.trailerSpawn.y, z = job.trailerSpawn.z } or nil,
        truckSpawn = job.truckSpawn and
            { x = job.truckSpawn.x, y = job.truckSpawn.y, z = job.truckSpawn.z } or nil,
        startedAt = job.startedAt,
        spoilTimeSeconds = def and def.spoilTimeSeconds or nil,
    }
end)

-- ── Analytics ────────────────────────────────────────────────
-- Everything here is derived from cipher_trucking_deliveries. A player with
-- no rows yet gets zeroed structures rather than nil, so the NUI renders
-- empty axes instead of an error state.
--
-- NOTE: every aggregate is wrapped in tonumber(). oxmysql hands SUM()/AVG()
-- back as STRINGS, and comparing or arithmetic-ing those against numbers
-- throws — the same trap that bit cipher-drugs' getPhoneHome.
lib.callback.register('cipher-trucking:server:getAnalytics', function(src)
    local cid = Framework.GetCitizenId(src)
    if not cid then return nil end
    if not WaitForDB() then return nil end

    local days = Config.Trucking.analyticsDays or 14

    -- Earnings per day, oldest first. Grouped in SQL by date so days with no
    -- deliveries simply don't come back; the NUI fills those gaps itself
    -- rather than this building a sparse calendar server-side.
    local daily = MySQL.query.await([[
        SELECT DATE(completed_at) AS day,
               SUM(driver_cut) AS earned,
               COUNT(*) AS deliveries,
               SUM(distance_m) AS distance
        FROM cipher_trucking_deliveries
        WHERE citizenid = ? AND completed_at >= DATE_SUB(CURDATE(), INTERVAL ? DAY)
        GROUP BY DATE(completed_at)
        ORDER BY day ASC
    ]], { cid, days }) or {}

    for _, row in ipairs(daily) do
        row.day = tostring(row.day):sub(1, 10)
        row.earned = tonumber(row.earned) or 0
        row.deliveries = tonumber(row.deliveries) or 0
        row.distance = tonumber(row.distance) or 0
    end

    local totals = MySQL.single.await([[
        SELECT COUNT(*) AS deliveries,
               COALESCE(SUM(driver_cut), 0) AS earned,
               COALESCE(SUM(distance_m), 0) AS distance,
               COALESCE(AVG(trip_rating), 100) AS avg_rating,
               COALESCE(SUM(duration_seconds), 0) AS seconds,
               COALESCE(SUM(spoiled), 0) AS spoiled
        FROM cipher_trucking_deliveries WHERE citizenid = ?
    ]], { cid }) or {}

    -- Which contracts this driver actually runs, by total take.
    local byContract = MySQL.query.await([[
        SELECT label, COUNT(*) AS runs, SUM(driver_cut) AS earned,
               COALESCE(AVG(trip_rating), 100) AS avg_rating
        FROM cipher_trucking_deliveries
        WHERE citizenid = ?
        GROUP BY contract_id, label
        ORDER BY earned DESC
        LIMIT 6
    ]], { cid }) or {}

    for _, row in ipairs(byContract) do
        row.runs = tonumber(row.runs) or 0
        row.earned = tonumber(row.earned) or 0
        row.avg_rating = math.floor(tonumber(row.avg_rating) or 100)
    end

    -- Oldest-first so the sparkline reads left to right; the SQL has to sort
    -- newest-first to apply LIMIT, hence the reverse.
    local ratingRows = MySQL.query.await([[
        SELECT trip_rating FROM cipher_trucking_deliveries
        WHERE citizenid = ? ORDER BY id DESC LIMIT 20
    ]], { cid }) or {}

    local ratingTrend = {}
    for i = #ratingRows, 1, -1 do
        ratingTrend[#ratingTrend + 1] = tonumber(ratingRows[i].trip_rating) or 100
    end

    return {
        days = days,
        daily = daily,
        byContract = byContract,
        ratingTrend = ratingTrend,
        totals = {
            deliveries = tonumber(totals.deliveries) or 0,
            earned = tonumber(totals.earned) or 0,
            distance = tonumber(totals.distance) or 0,
            avgRating = math.floor(tonumber(totals.avg_rating) or 100),
            seconds = tonumber(totals.seconds) or 0,
            spoiled = tonumber(totals.spoiled) or 0,
        },
    }
end)

-- ── Contract receipts ────────────────────────────────────────
-- The raw rows, newest first. Every payout modifier is returned separately
-- so the NUI can itemise how the final number was reached instead of just
-- restating it.
lib.callback.register('cipher-trucking:server:getHistory', function(src)
    local cid = Framework.GetCitizenId(src)
    if not cid then return {} end
    if not WaitForDB() then return {} end

    local rows = MySQL.query.await([[
        SELECT id, contract_id, label, cargo_type, base_payout, final_payout,
               driver_cut, company_cut, company_id, truck_bonus_pct, hot_bonus_pct,
               multistop_bonus_pct, rating_bonus_pct, spoiled, trip_rating,
               stop_count, xp, distance_m, duration_seconds,
               UNIX_TIMESTAMP(completed_at) AS completed_ts
        FROM cipher_trucking_deliveries
        WHERE citizenid = ? ORDER BY id DESC LIMIT ?
    ]], { cid, Config.Trucking.historyLimit or 40 }) or {}

    for _, r in ipairs(rows) do
        r.completed_ts = tonumber(r.completed_ts) or 0
        r.spoiled = (tonumber(r.spoiled) or 0) == 1
    end

    return rows
end)

lib.callback.register('cipher-trucking:server:getLeaderboard', function(src)
    if not WaitForDB() then return {} end
    local rows = MySQL.query.await(
        'SELECT name, level, total_completed, total_earned FROM cipher_trucking_stats ORDER BY total_completed DESC LIMIT ?',
        { Config.Trucking.leaderboardLimit })
    return rows or {}
end)

-- Personal garage only (company_id IS NULL) — company-owned vehicles are
-- listed via the Company tab's getCompany snapshot (Company.ListFleet).
lib.callback.register('cipher-trucking:server:getGarage', function(src)
    local cid = Framework.GetCitizenId(src)
    if not cid then
        return { owned = {}, shop = Config.Trucking.Shop, cash = 0, selectedTruck = nil, selectedTrailer = nil,
            performanceUpgrades = Config.Trucking.PerformanceUpgrades, paintColors = Config.Trucking.PaintColors,
            paintCost = SGet('economy.paintCost', Config.Trucking.paintCost) }
    end

    if not WaitForDB() then
        return { owned = {}, shop = Config.Trucking.Shop, cash = 0, selectedTruck = nil, selectedTrailer = nil,
            performanceUpgrades = Config.Trucking.PerformanceUpgrades, paintColors = Config.Trucking.PaintColors,
            paintCost = SGet('economy.paintCost', Config.Trucking.paintCost) }
    end

    local owned = MySQL.query.await(
        'SELECT * FROM cipher_trucking_owned WHERE citizenid = ? AND company_id IS NULL ORDER BY purchased_at ASC', { cid }) or {}

    -- Decoded server-side into a `maint` field rather than shipping the raw
    -- JSON string: the NUI renders these as gauges in three separate places
    -- and parsing the same blob in each of them invites them to disagree.
    if Maintenance and Maintenance.Enabled() then
        for _, row in ipairs(owned) do row.maint = Maintenance.Read(row) end
    end

    return {
        owned = owned,
        shop = Config.Trucking.Shop,
        cash = Framework.GetMoney(src, Config.Trucking.payoutAccount),
        selectedTruck = selectedTruck[src],
        selectedTrailer = selectedTrailer[src],
        -- Catalog for the Garage/Fleet "Performance" section — id/label/
        -- modType/maxLevel/costPerLevel, no per-truck data (that's on each
        -- owned row's own `upgrades` JSON string).
        performanceUpgrades = Config.Trucking.PerformanceUpgrades,
        -- Curated palette for the "Paint" section — id/label only.
        paintColors = Config.Trucking.PaintColors,
        paintCost = SGet('economy.paintCost', Config.Trucking.paintCost),
        -- Wear component definitions (label/warnAt/serviceCost/help) so the
        -- Garage renders a gauge per component without hardcoding them.
        maintenance = (Maintenance and Maintenance.Enabled()) and {
            enabled = true,
            wear = Config.Trucking.Maintenance.Wear,
            pricePerPercent = Config.Trucking.Maintenance.Fuel.pricePerPercent,
            lowWarnPct = Config.Trucking.Maintenance.Fuel.lowWarnPct,
        } or { enabled = false },
    }
end)

-- Generic — buys either a truck or a trailer depending on the shop entry's
-- `kind`, always personal (company purchases go through Company.BuyVehicle).
lib.callback.register('cipher-trucking:server:buyVehicle', function(src, shopId)
    local shopDef = findShopEntry(shopId)
    if not shopDef then return false, 'That is not for sale.' end

    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'No character loaded.' end

    if Framework.GetMoney(src, Config.Trucking.payoutAccount) < shopDef.price then
        return false, 'Not enough money.'
    end

    local ok = Framework.RemoveMoney(src, Config.Trucking.payoutAccount, shopDef.price, 'cipher-trucking:buyVehicle')
    if not ok then return false, 'Payment failed.' end

    MySQL.insert('INSERT INTO cipher_trucking_owned (citizenid, kind, model, label, `condition`) VALUES (?, ?, ?, ?, 100)',
        { cid, shopDef.kind or 'truck', shopDef.model, shopDef.label })

    Framework.Notify(src, ('Purchased %s.'):format(shopDef.label), 'success')
    return true
end)

lib.callback.register('cipher-trucking:server:selectTruck', function(src, ownedId)
    if not ownedId then
        selectedTruck[src] = nil
        return true
    end

    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'No character loaded.' end

    local owned = getUsableVehicle(src, cid, ownedId, 'truck')
    if not owned then return false, 'That truck is not available to you.' end
    if owned.condition <= 0 then return false, 'That truck needs repairs first.' end
    if owned.dispatch_ready_at then return false, 'That truck is out on a dispatch run.' end

    selectedTruck[src] = ownedId
    return true
end)

lib.callback.register('cipher-trucking:server:selectTrailer', function(src, ownedId)
    if not ownedId then
        selectedTrailer[src] = nil
        return true
    end

    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'No character loaded.' end

    local owned = getUsableVehicle(src, cid, ownedId, 'trailer')
    if not owned then return false, 'That trailer is not available to you.' end
    if owned.condition <= 0 then return false, 'That trailer needs repairs first.' end

    selectedTrailer[src] = ownedId
    return true
end)

-- Generic — repairs either a truck or a trailer. Personal vehicles are paid
-- from your own cash; company vehicles are paid from the company treasury
-- and need the manage_vehicles permission.
lib.callback.register('cipher-trucking:server:repairVehicle', function(src, ownedId)
    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'No character loaded.' end

    local owned = MySQL.single.await('SELECT * FROM cipher_trucking_owned WHERE id = ?', { ownedId })
    if not owned then return false, 'Vehicle not found.' end
    if owned.condition >= 100 then return false, 'Already in perfect condition.' end

    local cost = math.ceil((100 - owned.condition) * SGet('economy.repairCostPerPoint', Config.Trucking.repairCostPerPoint))

    if owned.company_id then
        if not Company.HasPerm(src, 'manage_vehicles') then return false, 'No permission.' end
        local company = Company.GetBySource(src)
        if not company or company.id ~= owned.company_id then return false, "Not your company's vehicle." end
        if company.bank < cost then return false, ('Repair costs $%d — treasury too low.'):format(cost) end
        company.bank = company.bank - cost
        MySQL.update('UPDATE cipher_trucking_companies SET bank = bank - ? WHERE id = ?', { cost, company.id })
    else
        if owned.citizenid ~= cid then return false, 'You do not own that vehicle.' end
        if Framework.GetMoney(src, Config.Trucking.payoutAccount) < cost then
            return false, ('Repair costs $%d — not enough money.'):format(cost)
        end
        local ok = Framework.RemoveMoney(src, Config.Trucking.payoutAccount, cost, 'cipher-trucking:repairVehicle')
        if not ok then return false, 'Payment failed.' end
    end

    MySQL.update('UPDATE cipher_trucking_owned SET `condition` = 100 WHERE id = ?', { ownedId })
    Framework.Notify(src, ('Repaired for $%d.'):format(cost), 'success')
    return true
end)

-- Performance upgrades — per-truck, JSON-stored, bought incrementally per
-- category (cost scales with the level being bought). Personal trucks pay
-- from your own cash; company trucks pay from the treasury and need
-- manage_vehicles. Trailers never get these (no engine/brakes/etc).
lib.callback.register('cipher-trucking:server:upgradeVehicle', function(src, ownedId, upgradeId)
    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'No character loaded.' end

    local upgradeDef = nil
    for _, u in ipairs(Config.Trucking.PerformanceUpgrades) do
        if u.id == upgradeId then upgradeDef = u break end
    end
    if not upgradeDef then return false, 'Unknown upgrade.' end

    local owned = MySQL.single.await('SELECT * FROM cipher_trucking_owned WHERE id = ?', { ownedId })
    if not owned then return false, 'Vehicle not found.' end
    if owned.kind ~= 'truck' then return false, 'Only trucks can be upgraded.' end

    if owned.company_id then
        if not Company.HasPerm(src, 'manage_vehicles') then return false, 'No permission.' end
        local company = Company.GetBySource(src)
        if not company or company.id ~= owned.company_id then return false, "Not your company's vehicle." end
    elseif owned.citizenid ~= cid then
        return false, 'You do not own that truck.'
    end

    local upgrades = json.decode(owned.upgrades or '{}') or {}
    local currentLevel = upgrades[upgradeId] or 0
    if currentLevel >= upgradeDef.maxLevel then return false, 'Already at max level.' end

    local nextLevel = currentLevel + 1
    local cost = upgradeDef.costPerLevel * nextLevel

    if owned.company_id then
        local company = Company.GetBySource(src)
        if company.bank < cost then return false, ('Costs $%d — treasury too low.'):format(cost) end
        company.bank = company.bank - cost
        MySQL.update('UPDATE cipher_trucking_companies SET bank = bank - ? WHERE id = ?', { cost, company.id })
    else
        if Framework.GetMoney(src, Config.Trucking.payoutAccount) < cost then
            return false, ('Costs $%d — not enough money.'):format(cost)
        end
        local ok = Framework.RemoveMoney(src, Config.Trucking.payoutAccount, cost, 'cipher-trucking:upgradeVehicle')
        if not ok then return false, 'Payment failed.' end
    end

    upgrades[upgradeId] = nextLevel
    MySQL.update('UPDATE cipher_trucking_owned SET upgrades = ? WHERE id = ?', { json.encode(upgrades), ownedId })

    Framework.Notify(src, ('%s upgraded to level %d.'):format(upgradeDef.label, nextLevel), 'success')
    return true
end)

-- ── Admin job control ────────────────────────────────────────
-- Globals rather than locals: server/admin.lua drives these, and `active`
-- is deliberately file-local so nothing else can reach in and mutate it
-- directly. These two functions are the entire sanctioned surface.

function ActiveJobCount()
    local n = 0
    for _ in pairs(active) do n = n + 1 end
    return n
end

-- Frees a player stuck mid-delivery — a truck despawned by a cleanup script,
-- a trailer lost to a crash, any state where the client can no longer
-- complete the run but the server still refuses a new contract. Deletes
-- their vehicles and drops the job WITHOUT paying out.
function ClearActiveJobFor(cid)
    for src, job in pairs(active) do
        if Framework.GetCitizenId(src) == cid then
            active[src] = nil

            for _, netId in ipairs({ job.truckNetId, job.trailerNetId }) do
                if netId then
                    local ent = NetworkGetEntityFromNetworkId(netId)
                    if ent and ent ~= 0 and DoesEntityExist(ent) then DeleteEntity(ent) end
                end
            end

            TriggerClientEvent('cipher-trucking:client:cleanupVehicles', src)
            Framework.Notify(src, 'An admin cleared your active delivery.', 'inform')
            return true
        end
    end
    return false, 'That player has no active delivery.'
end

-- ── Cleanup ──────────────────────────────────────────────────
AddEventHandler('playerDropped', function()
    local src = source
    selectedTruck[src] = nil
    selectedTrailer[src] = nil

    local job = active[src]
    if not job then return end
    active[src] = nil

    if job.truckNetId then
        local truck = NetworkGetEntityFromNetworkId(job.truckNetId)
        if truck and truck ~= 0 and DoesEntityExist(truck) then DeleteEntity(truck) end
    end
    if job.trailerNetId then
        local trailer = NetworkGetEntityFromNetworkId(job.trailerNetId)
        if trailer and trailer ~= 0 and DoesEntityExist(trailer) then DeleteEntity(trailer) end
    end
end)
