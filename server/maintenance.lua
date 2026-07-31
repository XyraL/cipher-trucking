-- ─────────────────────────────────────────────────────────────
-- Fuel & maintenance
--
-- Two systems that look similar but deliberately behave differently:
--
--   FUEL applies to every truck, including the free depot one, because a
--   fuel gauge that only appears once you've bought something teaches the
--   mechanic at the worst possible moment. The depot truck simply starts
--   full every time (Config...Fuel.depotTruckStartsFull), so a new driver
--   never has to think about it, while an owned truck keeps whatever was
--   left in the tank and has to be filled.
--
--   WEAR (tyres/brakes/oil) applies to OWNED trucks only — the same rule
--   the existing `condition` column already follows. The free truck is the
--   safety net that always works; loading it with running costs would take
--   that away from exactly the players who need it.
--
-- All values are 0-100 percentages. See the config block for why.
-- ─────────────────────────────────────────────────────────────
Maintenance = {}

local function cfg()
    return Config.Trucking.Maintenance
end

function Maintenance.Enabled()
    local c = cfg()
    return c and c.enabled == true
end

local function defaults()
    local m = { fuel = 100, odometer = 0 }
    for _, w in ipairs(cfg().Wear or {}) do m[w.id] = 100 end
    return m
end

local function clampPct(v)
    return math.max(0, math.min(100, v))
end

-- Merged over defaults so a row written before a new wear component existed
-- reads back with that component at full rather than nil.
function Maintenance.Read(row)
    local m = defaults()
    if not row or not row.maintenance then return m end

    local ok, stored = pcall(json.decode, row.maintenance)
    if not ok or type(stored) ~= 'table' then return m end

    for k, v in pairs(stored) do
        if type(v) == 'number' then m[k] = v end
    end
    return m
end

function Maintenance.Load(ownedId)
    if not ownedId then return defaults() end
    local row = MySQL.single.await('SELECT maintenance FROM cipher_trucking_owned WHERE id = ?', { ownedId })
    return Maintenance.Read(row)
end

function Maintenance.Save(ownedId, m)
    if not ownedId then return end
    MySQL.update('UPDATE cipher_trucking_owned SET maintenance = ? WHERE id = ?', { json.encode(m), ownedId })
end

-- ── Consumption ──────────────────────────────────────────────
-- Called once when a job completes, with the distance the client actually
-- reported driving. Wear is only applied to owned trucks; fuel is returned
-- for every truck so the caller can decide whether it's worth persisting.
--
-- `damage` is the same body+engine delta the condition system uses, so a
-- driver who bounces off three walls wears parts faster than one who
-- covered the same distance cleanly.
function Maintenance.ApplyTrip(ownedId, km, damage)
    if not Maintenance.Enabled() then return nil end

    local m = Maintenance.Load(ownedId)
    local c = cfg()

    m.odometer = (m.odometer or 0) + km

    if ownedId then
        for _, w in ipairs(c.Wear or {}) do
            local loss = (km * w.perKm) + (math.max(0, damage or 0) * w.perDamagePoint)
            m[w.id] = clampPct((m[w.id] or 100) - loss)
        end
        Maintenance.Save(ownedId, m)
    end

    return m
end

-- Fuel is written back on its own rather than as part of ApplyTrip: the
-- client is the only thing that knows the real burn (idling, the loaded
-- multiplier, distance actually covered) and it reports that continuously
-- during a run, not just at the end.
function Maintenance.SetFuel(ownedId, fuel)
    if not ownedId or not Maintenance.Enabled() then return end
    local m = Maintenance.Load(ownedId)
    m.fuel = clampPct(fuel)
    Maintenance.Save(ownedId, m)
end

-- ── Services ─────────────────────────────────────────────────
local function wearDef(id)
    for _, w in ipairs(cfg().Wear or {}) do
        if w.id == id then return w end
    end
    return nil
end

-- Ownership/permission shape deliberately mirrors repairVehicle and
-- upgradeVehicle in server/main.lua — personal vehicles pay from your own
-- cash, company vehicles from the treasury with manage_vehicles.
local function chargeFor(src, cid, owned, cost, reason)
    if owned.company_id then
        if not Company.HasPerm(src, 'manage_vehicles') then return false, 'No permission.' end
        local company = Company.GetBySource(src)
        if not company or company.id ~= owned.company_id then return false, "Not your company's vehicle." end
        if company.bank < cost then return false, ('Costs $%d — treasury too low.'):format(cost) end
        company.bank = company.bank - cost
        MySQL.update('UPDATE cipher_trucking_companies SET bank = bank - ? WHERE id = ?', { cost, company.id })
        return true
    end

    if owned.citizenid ~= cid then return false, 'You do not own that vehicle.' end
    if Framework.GetMoney(src, Config.Trucking.payoutAccount) < cost then
        return false, ('Costs $%d — not enough money.'):format(cost)
    end
    if not Framework.RemoveMoney(src, Config.Trucking.payoutAccount, cost, reason) then
        return false, 'Payment failed.'
    end
    return true
end

function Maintenance.Service(src, ownedId, componentId)
    if not Maintenance.Enabled() then return false, 'Maintenance is disabled.' end

    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'No character loaded.' end

    local def = wearDef(componentId)
    if not def then return false, 'Unknown component.' end

    local owned = MySQL.single.await('SELECT * FROM cipher_trucking_owned WHERE id = ?', { ownedId })
    if not owned then return false, 'Vehicle not found.' end
    if owned.kind ~= 'truck' then return false, 'Only trucks need servicing.' end

    local m = Maintenance.Read(owned)
    if (m[componentId] or 100) >= 100 then return false, ('%s are already in good order.'):format(def.label) end

    -- Cost scales with how worn the part is, so topping up a nearly-fresh
    -- component isn't the same price as replacing a destroyed one.
    local worn = 100 - (m[componentId] or 100)
    local cost = math.ceil(def.serviceCost * (worn / 100))

    local ok, err = chargeFor(src, cid, owned, cost, 'cipher-trucking:service')
    if not ok then return false, err end

    m[componentId] = 100
    Maintenance.Save(ownedId, m)

    Framework.Notify(src, ('%s serviced for $%d.'):format(def.label, cost), 'success')
    return true
end

function Maintenance.ServiceAll(src, ownedId)
    if not Maintenance.Enabled() then return false, 'Maintenance is disabled.' end

    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'No character loaded.' end

    local owned = MySQL.single.await('SELECT * FROM cipher_trucking_owned WHERE id = ?', { ownedId })
    if not owned then return false, 'Vehicle not found.' end
    if owned.kind ~= 'truck' then return false, 'Only trucks need servicing.' end

    local m = Maintenance.Read(owned)

    local cost = 0
    for _, w in ipairs(cfg().Wear or {}) do
        cost = cost + math.ceil(w.serviceCost * ((100 - (m[w.id] or 100)) / 100))
    end
    if cost <= 0 then return false, 'Nothing needs servicing.' end

    local ok, err = chargeFor(src, cid, owned, cost, 'cipher-trucking:serviceAll')
    if not ok then return false, err end

    for _, w in ipairs(cfg().Wear or {}) do m[w.id] = 100 end
    Maintenance.Save(ownedId, m)

    Framework.Notify(src, ('Full service completed for $%d.'):format(cost), 'success')
    return true
end

-- Refuelling is charged per percentage point, so a splash-and-dash costs
-- proportionally less than filling from empty.
function Maintenance.Refuel(src, ownedId, toPct)
    if not Maintenance.Enabled() then return false, 'Maintenance is disabled.' end

    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'No character loaded.' end

    local c = cfg()
    toPct = clampPct(tonumber(toPct) or 100)

    -- The free depot truck has no owned row to bill against or write back
    -- to; it refuels for free, matching depotTruckStartsFull.
    if not ownedId then
        return true, { charged = 0, fuel = toPct }
    end

    local owned = MySQL.single.await('SELECT * FROM cipher_trucking_owned WHERE id = ?', { ownedId })
    if not owned then return false, 'Vehicle not found.' end

    local m = Maintenance.Read(owned)
    local current = m.fuel or 0
    if toPct <= current then return false, 'Tank is already fuller than that.' end

    local cost = math.ceil((toPct - current) * c.Fuel.pricePerPercent)

    local ok, err = chargeFor(src, cid, owned, cost, 'cipher-trucking:refuel')
    if not ok then return false, err end

    m.fuel = toPct
    Maintenance.Save(ownedId, m)

    Framework.Notify(src, ('Refuelled to %d%% for $%d.'):format(toPct, cost), 'success')
    return true, { charged = cost, fuel = toPct }
end

-- ── Callbacks ────────────────────────────────────────────────
lib.callback.register('cipher-trucking:server:getMaintenanceConfig', function()
    if not Maintenance.Enabled() then return { enabled = false } end
    local c = cfg()
    return {
        enabled = true,
        wear = c.Wear,
        stations = c.Stations,
        stationRadius = c.stationRadius,
        pricePerPercent = c.Fuel.pricePerPercent,
        lowWarnPct = c.Fuel.lowWarnPct,
        burnPerKm = c.Fuel.burnPerKm,
        loadedMult = c.Fuel.loadedMult,
        idleBurnPerMinute = c.Fuel.idleBurnPerMinute,
        penalties = c.Penalties,
    }
end)

lib.callback.register('cipher-trucking:server:serviceVehicle', function(src, ownedId, componentId)
    if componentId == 'all' then return Maintenance.ServiceAll(src, ownedId) end
    return Maintenance.Service(src, ownedId, componentId)
end)

lib.callback.register('cipher-trucking:server:refuelVehicle', function(src, ownedId, toPct)
    return Maintenance.Refuel(src, ownedId, toPct)
end)

-- Continuous fuel reporting from the client during a run. The client owns
-- the burn calculation because only it knows distance, throttle and whether
-- a trailer is attached — but the value is clamped and can only ever go
-- DOWN through this path, so a modified client can't refill its own tank
-- for free by reporting 100.
RegisterNetEvent('cipher-trucking:server:reportFuel', function(ownedId, fuel)
    local src = source
    if not Maintenance.Enabled() or not ownedId then return end

    local cid = Framework.GetCitizenId(src)
    if not cid then return end

    local owned = MySQL.single.await('SELECT * FROM cipher_trucking_owned WHERE id = ?', { ownedId })
    if not owned then return end
    if owned.company_id then
        local company = Company.GetBySource(src)
        if not company or company.id ~= owned.company_id then return end
    elseif owned.citizenid ~= cid then
        return
    end

    local m = Maintenance.Read(owned)
    local reported = clampPct(tonumber(fuel) or 0)
    if reported >= (m.fuel or 100) then return end

    m.fuel = reported
    Maintenance.Save(ownedId, m)
end)
