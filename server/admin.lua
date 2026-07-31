-- ─────────────────────────────────────────────────────────────
-- Admin ops console
-- Staff-only oversight for the whole resource: server-wide stats, player
-- management, fleet administration, company oversight, a live settings
-- layer, and a delivery log feed.
--
-- Mirrors cipher's admin tablet and cipher-drugs' ops console. Every
-- callback re-checks the ACE server-side through guarded() — the client
-- opening the panel proves nothing, and a player who forges the NUI message
-- still gets rejected at every single action.
-- ─────────────────────────────────────────────────────────────
Admin = {}

local function isAdmin(src)
    return IsPlayerAceAllowed(src, Config.Trucking.AdminAce)
end

-- One place enforces the permission check, so a callback added later can't
-- accidentally ship unguarded. Returns (false, err) on rejection, matching
-- this resource's (ok, message) convention rather than cipher's {ok, error}.
local function guarded(handler)
    return function(src, ...)
        if not isAdmin(src) then return false, 'not authorized' end
        return handler(src, ...)
    end
end

-- Admin actions are the ones most worth having a trail of, so every write
-- below logs through here.
local function auditLog(src, action, detail)
    print(('^3[cipher-trucking:admin]^0 %s (%s) -> %s%s'):format(
        Framework.GetName(src) or 'unknown', src, action,
        detail and (' :: ' .. detail) or ''))
end

-- ── Overview ─────────────────────────────────────────────────
function Admin.Overview()
    if not WaitForDB() then return nil end

    -- tonumber() on every aggregate: oxmysql returns SUM()/AVG() as strings,
    -- and the NUI does arithmetic on these.
    local stats = MySQL.single.await([[
        SELECT COUNT(*) AS drivers,
               COALESCE(SUM(total_completed), 0) AS deliveries,
               COALESCE(SUM(total_earned), 0) AS earned,
               COALESCE(MAX(level), 1) AS top_level
        FROM cipher_trucking_stats
    ]]) or {}

    local recent = MySQL.single.await([[
        SELECT COUNT(*) AS runs, COALESCE(SUM(final_payout), 0) AS paid
        FROM cipher_trucking_deliveries
        WHERE completed_at >= DATE_SUB(NOW(), INTERVAL 24 HOUR)
    ]]) or {}

    local fleet = MySQL.single.await([[
        SELECT COUNT(*) AS vehicles,
               COALESCE(SUM(CASE WHEN dispatch_ready_at IS NOT NULL THEN 1 ELSE 0 END), 0) AS dispatched,
               COALESCE(AVG(`condition`), 100) AS avg_condition
        FROM cipher_trucking_owned
    ]]) or {}

    local companies = MySQL.single.await([[
        SELECT COUNT(*) AS total, COALESCE(SUM(bank), 0) AS treasury
        FROM cipher_trucking_companies
    ]]) or {}

    local top = MySQL.query.await([[
        SELECT name, level, total_completed, total_earned
        FROM cipher_trucking_stats ORDER BY total_earned DESC LIMIT 5
    ]]) or {}

    return {
        drivers = tonumber(stats.drivers) or 0,
        deliveries = tonumber(stats.deliveries) or 0,
        earned = tonumber(stats.earned) or 0,
        topLevel = tonumber(stats.top_level) or 1,
        recentRuns = tonumber(recent.runs) or 0,
        recentPaid = tonumber(recent.paid) or 0,
        vehicles = tonumber(fleet.vehicles) or 0,
        dispatched = tonumber(fleet.dispatched) or 0,
        avgCondition = math.floor(tonumber(fleet.avg_condition) or 100),
        companies = tonumber(companies.total) or 0,
        treasury = tonumber(companies.treasury) or 0,
        activeJobs = ActiveJobCount and ActiveJobCount() or 0,
        topEarners = top,
    }
end

-- ── Players ──────────────────────────────────────────────────
-- Fuzzy across citizenid AND display name, because staff searching for a
-- player almost never have the citizenid to hand.
function Admin.SearchPlayers(query)
    if not WaitForDB() then return {} end

    query = tostring(query or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if #query < 2 then return {} end

    local like = '%' .. query .. '%'
    local rows = MySQL.query.await([[
        SELECT citizenid, name, level, xp, total_completed, total_earned, rating_sum
        FROM cipher_trucking_stats
        WHERE citizenid LIKE ? OR name LIKE ?
        ORDER BY total_earned DESC LIMIT 12
    ]], { like, like }) or {}

    local online = {}
    for _, p in ipairs(GetPlayers()) do
        local cid = Framework.GetCitizenId(tonumber(p))
        if cid then online[cid] = tonumber(p) end
    end

    for _, r in ipairs(rows) do
        r.online = online[r.citizenid] ~= nil
        r.source = online[r.citizenid]
        r.rating = (r.total_completed or 0) > 0
            and math.floor((r.rating_sum or 0) / r.total_completed) or 100
    end
    return rows
end

-- Everyone connected who has a character loaded, for click-to-manage
-- without typing a search.
function Admin.OnlineRoster()
    local list = {}
    for _, p in ipairs(GetPlayers()) do
        local src = tonumber(p)
        local cid = Framework.GetCitizenId(src)
        if cid then
            list[#list + 1] = { citizenid = cid, name = Framework.GetName(src) or cid, source = src }
        end
    end
    table.sort(list, function(a, b) return (a.name or '') < (b.name or '') end)
    return list
end

function Admin.PlayerDetail(cid)
    if not WaitForDB() then return nil end

    local stats = MySQL.single.await('SELECT * FROM cipher_trucking_stats WHERE citizenid = ?', { cid })
    if not stats then return nil end

    stats.rating = (stats.total_completed or 0) > 0
        and math.floor((stats.rating_sum or 0) / stats.total_completed) or 100

    local vehicles = MySQL.query.await(
        'SELECT id, kind, model, label, `condition`, company_id, dispatch_ready_at FROM cipher_trucking_owned WHERE citizenid = ? ORDER BY id',
        { cid }) or {}

    local recent = MySQL.query.await([[
        SELECT label, driver_cut, trip_rating, UNIX_TIMESTAMP(completed_at) AS ts
        FROM cipher_trucking_deliveries WHERE citizenid = ? ORDER BY id DESC LIMIT 8
    ]], { cid }) or {}
    for _, r in ipairs(recent) do r.ts = tonumber(r.ts) or 0 end

    local company = Company.GetByCitizen(cid)

    return {
        stats = stats,
        vehicles = vehicles,
        recent = recent,
        company = company and { id = company.id, name = company.label } or nil,
    }
end

function Admin.SetLevel(cid, level)
    level = math.max(1, math.min(#Config.TruckingLevels, tonumber(level) or 1))

    -- XP is snapped to the new level's threshold rather than left alone.
    -- Otherwise the next delivery recomputes the level from stale XP and
    -- silently undoes the change, which looks like the panel not working.
    local xpNeeded = 0
    for _, def in ipairs(Config.TruckingLevels) do
        if def.level == level then xpNeeded = def.xpNeeded end
    end

    MySQL.update('UPDATE cipher_trucking_stats SET level = ?, xp = ? WHERE citizenid = ?', { level, xpNeeded, cid })
    return true, level
end

function Admin.AddXp(cid, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount == 0 then return false, 'Nothing to add.' end

    local row = MySQL.single.await('SELECT xp FROM cipher_trucking_stats WHERE citizenid = ?', { cid })
    if not row then return false, 'No trucking record for that player.' end

    local newXp = math.max(0, (row.xp or 0) + amount)
    local level = 1
    for _, def in ipairs(Config.TruckingLevels) do
        if newXp >= def.xpNeeded then level = def.level end
    end

    MySQL.update('UPDATE cipher_trucking_stats SET xp = ?, level = ? WHERE citizenid = ?', { newXp, level, cid })
    return true, { xp = newXp, level = level }
end

-- Sets the running average back to a clean 100 by rewriting rating_sum to
-- match total_completed, rather than zeroing both and losing the delivery
-- count along with it.
function Admin.ResetRating(cid)
    MySQL.update('UPDATE cipher_trucking_stats SET rating_sum = total_completed * 100 WHERE citizenid = ?', { cid })
    return true
end

function Admin.GiveCash(src, targetCid, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return false, 'Amount must be positive.' end

    local targetSrc = nil
    for _, p in ipairs(GetPlayers()) do
        if Framework.GetCitizenId(tonumber(p)) == targetCid then targetSrc = tonumber(p) break end
    end
    if not targetSrc then return false, 'That player must be online to receive money.' end

    Framework.AddMoney(targetSrc, Config.Trucking.payoutAccount, amount, 'cipher-trucking:admin')
    Framework.Notify(targetSrc, ('An admin granted you $%d.'):format(amount), 'success')
    return true
end

-- ── Fleet ────────────────────────────────────────────────────
function Admin.ListFleet(filter)
    if not WaitForDB() then return {} end

    local rows
    if filter == 'dispatched' then
        rows = MySQL.query.await(
            'SELECT * FROM cipher_trucking_owned WHERE dispatch_ready_at IS NOT NULL ORDER BY id DESC LIMIT 60')
    elseif filter == 'damaged' then
        rows = MySQL.query.await(
            'SELECT * FROM cipher_trucking_owned WHERE `condition` < 100 ORDER BY `condition` ASC LIMIT 60')
    else
        rows = MySQL.query.await('SELECT * FROM cipher_trucking_owned ORDER BY id DESC LIMIT 60')
    end
    rows = rows or {}

    for _, r in ipairs(rows) do
        r.ownerName = Framework.GetNameByCitizenId(r.citizenid) or r.citizenid
        local company = r.company_id and Company.Get(r.company_id) or nil
        r.companyName = company and company.label or nil
    end
    return rows
end

function Admin.RepairVehicle(ownedId)
    MySQL.update('UPDATE cipher_trucking_owned SET `condition` = 100 WHERE id = ?', { ownedId })
    return true
end

function Admin.ClearDispatch(ownedId)
    MySQL.update([[
        UPDATE cipher_trucking_owned
        SET dispatch_ready_at = NULL, dispatch_contract_id = NULL, dispatch_payout = NULL
        WHERE id = ?
    ]], { ownedId })
    return true
end

function Admin.DeleteVehicle(ownedId)
    MySQL.update('DELETE FROM cipher_trucking_owned WHERE id = ?', { ownedId })
    return true
end

-- ── Companies ────────────────────────────────────────────────
function Admin.ListCompanies()
    if not WaitForDB() then return {} end
    local rows = MySQL.query.await(
        'SELECT id, name, label, owner, bank, reputation, perk_points, total_deliveries FROM cipher_trucking_companies ORDER BY label') or {}
    for _, row in ipairs(rows) do
        row.ownerName = Framework.GetNameByCitizenId(row.owner) or row.owner
        row.memberCount = MySQL.scalar.await('SELECT COUNT(*) FROM cipher_trucking_company_members WHERE company_id = ?', { row.id }) or 0
    end
    return rows
end

function Admin.SetTreasury(companyId, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount < 0 then return false, 'Cannot be negative.' end

    companyId = tonumber(companyId)
    MySQL.update('UPDATE cipher_trucking_companies SET bank = ? WHERE id = ?', { amount, companyId })

    -- Keep the in-memory company cache in step; it's the source of truth for
    -- live permission and balance checks until the next reload.
    local company = Company.Get(companyId)
    if company then company.bank = amount end
    return true
end

function Admin.DisbandCompany(companyId)
    Company.DisbandById(tonumber(companyId))
    return true
end

-- ── Logs ─────────────────────────────────────────────────────
function Admin.RecentDeliveries()
    if not WaitForDB() then return {} end

    local rows = MySQL.query.await([[
        SELECT d.label, d.final_payout, d.driver_cut, d.trip_rating, d.spoiled,
               d.citizenid, s.name AS driver_name,
               UNIX_TIMESTAMP(d.completed_at) AS ts
        FROM cipher_trucking_deliveries d
        LEFT JOIN cipher_trucking_stats s ON s.citizenid = d.citizenid
        ORDER BY d.id DESC LIMIT 50
    ]]) or {}

    for _, r in ipairs(rows) do
        r.ts = tonumber(r.ts) or 0
        r.spoiled = (tonumber(r.spoiled) or 0) == 1
        r.driver_name = r.driver_name or r.citizenid
    end
    return rows
end

-- ── NUI-facing callbacks ─────────────────────────────────────
lib.callback.register('cipher-trucking:server:adminOverview', guarded(function()
    return Admin.Overview()
end))

lib.callback.register('cipher-trucking:server:adminSearchPlayers', guarded(function(src, query)
    return Admin.SearchPlayers(query)
end))

lib.callback.register('cipher-trucking:server:adminOnlineRoster', guarded(function()
    return Admin.OnlineRoster()
end))

lib.callback.register('cipher-trucking:server:adminPlayerDetail', guarded(function(src, cid)
    return Admin.PlayerDetail(cid)
end))

lib.callback.register('cipher-trucking:server:adminSetLevel', guarded(function(src, cid, level)
    auditLog(src, 'setLevel', ('%s -> %s'):format(cid, level))
    return Admin.SetLevel(cid, level)
end))

lib.callback.register('cipher-trucking:server:adminAddXp', guarded(function(src, cid, amount)
    auditLog(src, 'addXp', ('%s %+d'):format(cid, tonumber(amount) or 0))
    return Admin.AddXp(cid, amount)
end))

lib.callback.register('cipher-trucking:server:adminResetRating', guarded(function(src, cid)
    auditLog(src, 'resetRating', cid)
    return Admin.ResetRating(cid)
end))

lib.callback.register('cipher-trucking:server:adminGiveCash', guarded(function(src, cid, amount)
    auditLog(src, 'giveCash', ('%s $%s'):format(cid, tostring(amount)))
    return Admin.GiveCash(src, cid, amount)
end))

lib.callback.register('cipher-trucking:server:adminClearJob', guarded(function(src, cid)
    auditLog(src, 'clearJob', cid)
    if not ClearActiveJobFor then return false, 'Job control unavailable.' end
    return ClearActiveJobFor(cid)
end))

lib.callback.register('cipher-trucking:server:adminListFleet', guarded(function(src, filter)
    return Admin.ListFleet(filter)
end))

lib.callback.register('cipher-trucking:server:adminRepairVehicle', guarded(function(src, ownedId)
    auditLog(src, 'repairVehicle', tostring(ownedId))
    return Admin.RepairVehicle(ownedId)
end))

lib.callback.register('cipher-trucking:server:adminClearDispatch', guarded(function(src, ownedId)
    auditLog(src, 'clearDispatch', tostring(ownedId))
    return Admin.ClearDispatch(ownedId)
end))

lib.callback.register('cipher-trucking:server:adminDeleteVehicle', guarded(function(src, ownedId)
    auditLog(src, 'deleteVehicle', tostring(ownedId))
    return Admin.DeleteVehicle(ownedId)
end))

lib.callback.register('cipher-trucking:server:adminListCompanies', guarded(function()
    return Admin.ListCompanies()
end))

lib.callback.register('cipher-trucking:server:adminSetTreasury', guarded(function(src, companyId, amount)
    auditLog(src, 'setTreasury', ('#%s -> $%s'):format(tostring(companyId), tostring(amount)))
    return Admin.SetTreasury(companyId, amount)
end))

lib.callback.register('cipher-trucking:server:adminDisbandCompany', guarded(function(src, companyId)
    auditLog(src, 'disbandCompany', ('#%s'):format(tostring(companyId)))
    return Admin.DisbandCompany(companyId)
end))

lib.callback.register('cipher-trucking:server:adminSettings', guarded(function()
    return Settings.AdminList()
end))

lib.callback.register('cipher-trucking:server:adminSetSetting', guarded(function(src, key, value)
    auditLog(src, 'setSetting', ('%s = %s'):format(tostring(key), tostring(value)))
    return Settings.Set(key, value)
end))

lib.callback.register('cipher-trucking:server:adminResetSetting', guarded(function(src, key)
    auditLog(src, 'resetSetting', tostring(key))
    return Settings.Reset(key)
end))

lib.callback.register('cipher-trucking:server:adminRecentDeliveries', guarded(function()
    return Admin.RecentDeliveries()
end))

-- ── Boot self-check ──────────────────────────────────────────
-- Names any server file that didn't load. This exists because cipher-drugs
-- burned a testing session on symptoms — unknown-column errors, dead
-- buttons, a nil global — that all traced back to one cause: files synced
-- to the host individually, and two never made it. Every symptom pointed
-- somewhere other than the actual problem.
--
-- Checking globals is enough: each server file defines exactly one, so a
-- missing global means a missing file, and naming it turns a multi-hour
-- hunt into one line of console output.
CreateThread(function()
    Wait(2000)

    local expected = {
        { global = 'DBLoaded',  file = 'server/db.lua' },
        { global = 'Settings',  file = 'server/settings.lua' },
        { global = 'Company',   file = 'server/company.lua' },
        { global = 'Framework', file = 'bridge/framework.lua' },
        { global = 'Config',    file = 'config.lua' },
    }

    local missing = {}
    for _, e in ipairs(expected) do
        if _G[e.global] == nil then missing[#missing + 1] = e.file end
    end

    if #missing > 0 then
        print('^1[cipher-trucking] ─────────────────────────────────────────^0')
        print('^1[cipher-trucking] STARTUP INCOMPLETE — these files did not load:^0')
        for _, f in ipairs(missing) do print(('^1[cipher-trucking]   • %s^0'):format(f)) end
        print('^1[cipher-trucking] Re-upload the ENTIRE resource folder, not just changed files.^0')
        print('^1[cipher-trucking] ─────────────────────────────────────────^0')
    elseif Config.Debug then
        print('^2[cipher-trucking]^0 boot self-check passed — all server files loaded')
    end
end)

RegisterCommand(Config.Trucking.AdminCommand, function(src)
    if src == 0 then return end -- console
    if not isAdmin(src) then
        Framework.Notify(src, 'You are not authorized to use this.', 'error')
        return
    end
    TriggerClientEvent('cipher-trucking:client:openAdmin', src)
end, false)
