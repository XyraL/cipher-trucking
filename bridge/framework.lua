-- ─────────────────────────────────────────────────────────────
-- Framework bridge
-- Auto-detects QBox (qbx_core) or QBCore (qb-core) and exposes ONE API
-- so the rest of the resource never branches on framework. ox_lib and
-- oxmysql are used directly elsewhere since both frameworks ship with them.
--
-- If a function behaves differently on your build, this file is the only
-- place you need to touch.
-- ─────────────────────────────────────────────────────────────
-- ── NUI callback dispatch fix (client only) ──────────────────
-- FiveM will not dispatch the next NUI callback while the current handler is
-- still yielding. Nearly every handler in this resource calls
-- lib.callback.await for a server round-trip, which yields — so the dashboard
-- opening four requests at once meant they ran strictly one after another,
-- each waiting out the full latency of the one before it.
--
-- The give-away was `getMapMeta` timing out at 12 seconds. That handler is
-- pure client-side: it reads Config and returns, with nothing async in it. A
-- synchronous handler can only take 12 seconds if it was never dispatched
-- until then — which is queueing, not slowness. (This is also why spamming a
-- tab "fixed" it: the retry landed after the queue had drained.)
--
-- Running each handler in its own thread lets the registration return
-- immediately, so FiveM moves straight on to the next queued callback and the
-- round-trips overlap instead of stacking. `cb` is safe to call later from
-- another thread.
--
-- Patching the registrar rather than each call site covers all of client/
-- main.lua, fuel.lua, company.lua and admin.lua, plus anything added later.
-- This file is first in client_scripts, so the override is in place before
-- anything registers.
NUI_PATCHED = false
NUI_REGISTERED = {}
NUI_TRACE = false

if not IsDuplicityVersion() then
    -- Guarded: if the runtime hasn't defined RegisterNUICallback yet, capturing
    -- nil here would make every later registration throw and silently leave the
    -- dashboard with no handlers at all — a worse failure than the one being
    -- fixed.
    if type(RegisterNUICallback) == 'function' then
        local _registerNUI = RegisterNUICallback

        RegisterNUICallback = function(name, handler)
            NUI_REGISTERED[#NUI_REGISTERED + 1] = name
            return _registerNUI(name, function(data, cb)
                -- Traced at both ends, because "the request never came back"
                -- has three completely different causes and the symptom looks
                -- identical for all of them:
                --   no IN            -> the fetch never reached the client
                --   IN but no OUT    -> the handler stalled or errored
                --   IN and OUT fast  -> the reply never reached the page
                -- Toggle with /truckingtrace.
                local t0 = GetGameTimer()
                if NUI_TRACE then
                    print(('^3[cipher-trucking]^0 NUI IN  <- %s'):format(name))
                end

                CreateThread(function()
                    handler(data, function(...)
                        if NUI_TRACE then
                            print(('^2[cipher-trucking]^0 NUI OUT -> %s (%dms)'):format(name, GetGameTimer() - t0))
                        end
                        cb(...)
                    end)
                end)
            end)
        end

        NUI_PATCHED = true
    else
        print('^1[cipher-trucking]^0 RegisterNUICallback unavailable when the bridge loaded — NUI dispatch patch skipped.')
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
