-- ─────────────────────────────────────────────────────────────
-- Diagnostics
--
-- Loads LAST in client_scripts, so by the time it runs every NUI callback in
-- the resource has had its chance to register.
--
-- This exists because the "tabs sit on Loading..." report has now survived two
-- fixes aimed at the wrong layer. Both were plausible from the logs and both
-- were wrong, because the logs only ever showed the SYMPTOM — a request that
-- never came back — and never showed which link in the chain dropped it.
--
-- /truckingdiag walks the whole chain and prints where it actually breaks:
--   NUI page -> client callback registered -> client handler runs ->
--   server callback -> database -> response back.
-- ─────────────────────────────────────────────────────────────

local function line(label, value)
    print(('^3[cipher-trucking]^0 %-28s %s'):format(label, value))
end

local function ok(v)  return v and '^2yes^0' or '^1NO^0' end

-- Boot report. Delayed so it lands after every client file has registered,
-- and prints on its own rather than needing anyone to run a command first.
CreateThread(function()
    Wait(3000)

    local count = #(NUI_REGISTERED or {})

    if count == 0 then
        print('^1[cipher-trucking] ─────────────────────────────────────────^0')
        print('^1[cipher-trucking] NO NUI CALLBACKS REGISTERED.^0')
        print('^1[cipher-trucking] Every dashboard request will time out.^0')
        print('^1[cipher-trucking] A client file failed to load — scroll up for^0')
        print('^1[cipher-trucking] the first error at resource start.^0')
        print('^1[cipher-trucking] ─────────────────────────────────────────^0')
    elseif Config.Debug then
        line('NUI callbacks registered', count)
        line('NUI dispatch patch', ok(NUI_PATCHED))
    end
end)

-- Logs every NUI request as it arrives and as it is answered. The diagnostics
-- above prove the Lua side works when called FROM Lua; this is the only thing
-- that shows what happens when the page itself asks.
RegisterCommand('truckingtrace', function()
    NUI_TRACE = not NUI_TRACE
    -- Mirror the flag into the page so both ends of a request are logged.
    SendNUIMessage({ action = 'trace', data = NUI_TRACE })
    print(('^3[cipher-trucking]^0 NUI trace %s'):format(NUI_TRACE and '^2ON^0 — open the dashboard now' or '^1OFF^0'))
    if NUI_TRACE then
        print('^3[cipher-trucking]^0 Expect a matching IN/OUT pair per request. What you see means:')
        print('^3[cipher-trucking]^0   nothing at all      the page never reached the client')
        print('^3[cipher-trucking]^0   IN with no OUT      the handler stalled')
        print('^3[cipher-trucking]^0   IN + OUT, but the   the reply never reached the page')
        print('^3[cipher-trucking]^0   page still times out')
    end
end, false)

RegisterCommand('truckingdiag', function()
    print('^3[cipher-trucking] ── diagnostics ──────────────────────────^0')

    -- 1. Client-side wiring
    line('framework detected', Framework and (Framework.name or 'NONE') or '^1bridge missing^0')
    line('NUI dispatch patch', ok(NUI_PATCHED))
    line('NUI callbacks registered', #(NUI_REGISTERED or {}))

    local wanted = { 'getMapMeta', 'getContracts', 'getActiveJob', 'getCareer' }
    local present = {}
    for _, n in ipairs(NUI_REGISTERED or {}) do present[n] = true end
    for _, n in ipairs(wanted) do
        line('  registered: ' .. n, ok(present[n]))
    end

    -- 2. Client -> server transport, timed, with nothing else in the way.
    --    A tiny callback that touches no database, so a slow result here means
    --    the transport itself, not query time.
    local t0 = GetGameTimer()
    local pong = lib.callback.await('cipher-trucking:server:diagPing', false)
    local rtt = GetGameTimer() - t0
    line('server round-trip', pong and (rtt .. 'ms') or ('^1no response after ' .. rtt .. 'ms^0'))

    -- 3. Server-side state, reported by that same ping.
    if pong then
        line('server: database ready', ok(pong.dbReady))
        line('server: database failed', pong.dbFailed and '^1YES^0' or 'no')
        line('server: settings loaded', ok(pong.settings))
    end

    -- 4. A real gated callback, to compare against the bare ping above.
    t0 = GetGameTimer()
    local contracts = lib.callback.await('cipher-trucking:server:getContracts', false)
    local ctime = GetGameTimer() - t0
    line('getContracts', contracts and (('%dms, %d rows'):format(ctime, #contracts)) or ('^1no response after ' .. ctime .. 'ms^0'))

    print('^3[cipher-trucking] ─────────────────────────────────────────^0')
    print('^3[cipher-trucking]^0 Paste the block above when reporting a loading issue.')
end, false)
