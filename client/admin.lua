-- ─────────────────────────────────────────────────────────────
-- Admin panel client relay
-- Opened via /Config.Trucking.AdminCommand, which server/admin.lua
-- permission-checks before this event ever fires. Nothing here decides who
-- is allowed in — it just opens the NUI when told to, and every callback
-- below is re-checked server-side anyway. A player who forges these NUI
-- messages reaches a guarded() handler and gets rejected.
-- ─────────────────────────────────────────────────────────────
RegisterNetEvent('cipher-trucking:client:openAdmin', function()
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'openAdmin' })
end)

RegisterNUICallback('closeAdmin', function(_, cb)
    SetNuiFocus(false, false)
    cb({})
end)

-- Thin proxies. Each one names its server counterpart directly so the
-- mapping stays greppable in both directions.
local RELAY = {
    adminOverview         = 'cipher-trucking:server:adminOverview',
    adminOnlineRoster     = 'cipher-trucking:server:adminOnlineRoster',
    adminListCompanies    = 'cipher-trucking:server:adminListCompanies',
    adminSettings         = 'cipher-trucking:server:adminSettings',
    adminRecentDeliveries = 'cipher-trucking:server:adminRecentDeliveries',
}

for nuiName, callbackName in pairs(RELAY) do
    RegisterNUICallback(nuiName, function(_, cb)
        cb(lib.callback.await(callbackName, false) or {})
    end)
end

RegisterNUICallback('adminSearchPlayers', function(data, cb)
    cb(lib.callback.await('cipher-trucking:server:adminSearchPlayers', false, data.query) or {})
end)

RegisterNUICallback('adminPlayerDetail', function(data, cb)
    cb(lib.callback.await('cipher-trucking:server:adminPlayerDetail', false, data.citizenid))
end)

RegisterNUICallback('adminListFleet', function(data, cb)
    cb(lib.callback.await('cipher-trucking:server:adminListFleet', false, data.filter) or {})
end)

-- Write actions all share the (ok, message) response shape.
local function action(nuiName, callbackName, argFn)
    RegisterNUICallback(nuiName, function(data, cb)
        local ok, message = lib.callback.await(callbackName, false, table.unpack(argFn(data)))
        cb({ ok = ok, message = message })
    end)
end

action('adminSetLevel',      'cipher-trucking:server:adminSetLevel',      function(d) return { d.citizenid, d.level } end)
action('adminAddXp',         'cipher-trucking:server:adminAddXp',         function(d) return { d.citizenid, d.amount } end)
action('adminResetRating',   'cipher-trucking:server:adminResetRating',   function(d) return { d.citizenid } end)
action('adminGiveCash',      'cipher-trucking:server:adminGiveCash',      function(d) return { d.citizenid, d.amount } end)
action('adminClearJob',      'cipher-trucking:server:adminClearJob',      function(d) return { d.citizenid } end)
action('adminRepairVehicle', 'cipher-trucking:server:adminRepairVehicle', function(d) return { d.ownedId } end)
action('adminClearDispatch', 'cipher-trucking:server:adminClearDispatch', function(d) return { d.ownedId } end)
action('adminDeleteVehicle', 'cipher-trucking:server:adminDeleteVehicle', function(d) return { d.ownedId } end)
action('adminSetTreasury',   'cipher-trucking:server:adminSetTreasury',   function(d) return { d.companyId, d.amount } end)
action('adminDisbandCompany','cipher-trucking:server:adminDisbandCompany',function(d) return { d.companyId } end)
action('adminSetSetting',    'cipher-trucking:server:adminSetSetting',    function(d) return { d.key, d.value } end)
action('adminResetSetting',  'cipher-trucking:server:adminResetSetting',  function(d) return { d.key } end)
