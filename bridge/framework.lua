-- ─────────────────────────────────────────────────────────────
-- Framework bridge
-- Auto-detects QBox (qbx_core) or QBCore (qb-core) and exposes ONE API
-- so the rest of the resource never branches on framework. ox_lib and
-- oxmysql are used directly elsewhere since both frameworks ship with them.
--
-- If a function behaves differently on your build, this file is the only
-- place you need to touch.
-- ─────────────────────────────────────────────────────────────
-- ── NUI callback wrapper (client only) ───────────────────────
-- Patches the registrar rather than each call site, so every NUI callback in
-- the resource gets both guarantees below, including any added later. This
-- file is first in client_scripts, so the override is in place before
-- anything registers.
--
-- 1. Each handler runs in its own thread. FiveM will not dispatch the next NUI
--    callback while the current one is still yielding, and nearly every
--    handler here yields on a server round-trip — so the dashboard opening
--    several requests at once would run them strictly one after another.
--
-- 2. A nil payload is sent as `false`. cb(nil) sends no response body at all,
--    leaving the page's fetch pending forever — not resolved, not rejected.
--    Several callbacks return nil perfectly legitimately (getActiveJob when no
--    delivery is running, which is most of the time), so any panel awaiting
--    one of those alongside other data never finished loading. `false`
--    encodes to JSON, and every consumer tests these results for truthiness,
--    so "no data" still reads as "no data".
if not IsDuplicityVersion() then
    -- Guarded: if the runtime hasn't defined RegisterNUICallback yet,
    -- capturing nil would make every later registration throw and leave the
    -- dashboard with no handlers at all.
    if type(RegisterNUICallback) == 'function' then
        local _registerNUI = RegisterNUICallback

        RegisterNUICallback = function(name, handler)
            return _registerNUI(name, function(data, cb)
                CreateThread(function()
                    handler(data, function(payload, ...)
                        if payload == nil then payload = false end
                        cb(payload, ...)
                    end)
                end)
            end)
        end
    else
        print('^1[cipher-trucking]^0 RegisterNUICallback unavailable when the bridge loaded — NUI wrapper skipped.')
    end
end

Framework = { name = nil, core = nil }

if GetResourceState('qbx_core') == 'started' then
    Framework.name = 'qbox'
elseif GetResourceState('qb-core') == 'started' then
    Framework.name = 'qbcore'
    Framework.core = exports['qb-core']:GetCoreObject()
else
    -- Defer the error so the resource still loads its UI; log loudly.
    print('^1[cipher-trucking]^0 No supported framework found. Start qbx_core or qb-core before cipher-trucking.')
end

local IS_SERVER = IsDuplicityVersion()

-- ── Player lookups ──────────────────────────────────────────
if IS_SERVER then
    -- Returns the framework player object for a server id, or nil.
    -- The nil-name guard matters: when neither framework is running we only
    -- print a warning above and keep loading, so without this every call
    -- would fall through to indexing a nil Framework.core and bury the real
    -- "start qbx_core or qb-core first" message under attempt-to-index spam.
    function Framework.GetPlayer(src)
        if Framework.name == 'qbox' then
            return exports.qbx_core:GetPlayer(src)
        elseif Framework.name == 'qbcore' then
            return Framework.core.Functions.GetPlayer(src)
        end
        return nil
    end

    -- Returns the stable character identifier (citizenid) for a source.
    function Framework.GetCitizenId(src)
        local player = Framework.GetPlayer(src)
        return player and player.PlayerData.citizenid or nil
    end

    -- Returns { firstname, lastname } for a source.
    function Framework.GetName(src)
        local player = Framework.GetPlayer(src)
        if not player then return nil end
        local ci = player.PlayerData.charinfo
        return ('%s %s'):format(ci.firstname, ci.lastname)
    end

    -- Same, but for a citizenid that may be offline (DB lookup). Both
    -- qbx_core and qb-core store charinfo as JSON on the `players` table.
    function Framework.GetNameByCitizenId(citizenid)
        local row = MySQL.single.await('SELECT charinfo FROM players WHERE citizenid = ?', { citizenid })
        if not row or not row.charinfo then return nil end
        local ci = type(row.charinfo) == 'string' and json.decode(row.charinfo) or row.charinfo
        if not ci or not ci.firstname then return nil end
        return ('%s %s'):format(ci.firstname, ci.lastname)
    end

    -- Money: account is 'cash' | 'bank'. Both frameworks share this API
    -- surface via the player object's Functions table.
    function Framework.AddMoney(src, account, amount, reason)
        local player = Framework.GetPlayer(src)
        if not player then return false end
        return player.Functions.AddMoney(account, amount, reason or 'cipher-trucking')
    end

    function Framework.RemoveMoney(src, account, amount, reason)
        local player = Framework.GetPlayer(src)
        if not player then return false end
        return player.Functions.RemoveMoney(account, amount, reason or 'cipher-trucking')
    end

    function Framework.GetMoney(src, account)
        local player = Framework.GetPlayer(src)
        if not player then return 0 end
        return player.PlayerData.money[account] or 0
    end

    -- Server-side notify (wraps ox_lib so the UI/notify look is uniform).
    function Framework.Notify(src, msg, type)
        TriggerClientEvent('ox_lib:notify', src, { description = msg, type = type or 'inform' })
    end
else
    -- ── Client ──────────────────────────────────────────────
    function Framework.GetPlayerData()
        if Framework.name == 'qbox' then
            return exports.qbx_core:GetPlayerData()
        elseif Framework.name == 'qbcore' then
            return Framework.core.Functions.GetPlayerData()
        end
        return nil
    end

    function Framework.Notify(msg, type)
        lib.notify({ description = msg, type = type or 'inform' })
    end
end

if Config and Config.Debug then
    print(('^2[cipher-trucking]^0 bridge loaded (%s) on %s'):format(
        Framework.name or 'none', IS_SERVER and 'server' or 'client'))
end
