-- ─────────────────────────────────────────────────────────────
-- Live settings
-- An override layer sitting on top of config.lua. Admins retune the
-- economy from the in-game panel and it persists — no file edit, no
-- restart, no dropping players mid-shift to change a payout.
--
-- The important property is that this is an OVERRIDE, not a replacement.
-- A key only exists in the database once someone has actually changed it;
-- everything else keeps reading config.lua. That means a server owner can
-- still edit the config file normally for anything they haven't touched
-- in-panel, and "Reset" genuinely restores config control rather than
-- writing the current value back as a new hardcoded one.
--
-- Same structure as cipher-drugs' server/settings.lua + stock.lua override
-- layers. Read through the global SGet(key, fallback).
-- ─────────────────────────────────────────────────────────────
Settings = {}

local cache = {}
local loaded = false

-- The schema is the authority on what is tunable. Set() rejects anything
-- not listed here, so a malicious or malformed NUI payload can't write junk
-- keys into the table, and every knob is guaranteed to have a type and a
-- sane range for the UI to build a control from.
--
-- `path` is where the value comes from in Config when no override exists.
-- Resolved lazily so this table can be declared before Config is populated.
local SCHEMA = {
    -- ── Economy ──
    { key = 'economy.payoutMult', label = 'Global payout multiplier', group = 'Economy',
      type = 'number', min = 0, max = 500, suffix = '%', default = 100,
      help = 'Scales every contract payout. 100 = unchanged.' },
    { key = 'economy.xpMult', label = 'Global XP multiplier', group = 'Economy',
      type = 'number', min = 0, max = 500, suffix = '%', default = 100 },
    { key = 'economy.repairCostPerPoint', label = 'Repair cost per condition point', group = 'Economy',
      type = 'number', min = 0, max = 500, prefix = '$', path = 'repairCostPerPoint' },
    { key = 'economy.paintCost', label = 'Paint job cost', group = 'Economy',
      type = 'number', min = 0, max = 100000, prefix = '$', path = 'paintCost' },

    -- ── Bonuses ──
    { key = 'bonus.multiStopPct', label = 'Multi-stop bonus', group = 'Bonuses',
      type = 'number', min = 0, max = 300, suffix = '%', path = 'multiStopBonusPct' },
    { key = 'bonus.ratingBonusPct', label = 'High-rating bonus', group = 'Bonuses',
      type = 'number', min = 0, max = 100, suffix = '%', path = 'ratingBonusPct' },
    { key = 'bonus.ratingPenaltyPct', label = 'Low-rating penalty', group = 'Bonuses',
      type = 'number', min = 0, max = 100, suffix = '%', path = 'ratingPenaltyPct' },
    { key = 'bonus.ratingBonusThreshold', label = 'Rating needed for bonus', group = 'Bonuses',
      type = 'number', min = 0, max = 100, path = 'ratingBonusThreshold' },
    { key = 'bonus.ratingPenaltyThreshold', label = 'Rating that triggers penalty', group = 'Bonuses',
      type = 'number', min = 0, max = 100, path = 'ratingPenaltyThreshold' },

    -- ── Hot contracts ──
    { key = 'hot.enabled', label = 'Hot contracts enabled', group = 'Hot Contracts', type = 'bool' },
    { key = 'hot.payoutBonusPct', label = 'Hot contract bonus', group = 'Hot Contracts',
      type = 'number', min = 0, max = 500, suffix = '%' },
    { key = 'hot.rotateMinutes', label = 'Rotation interval', group = 'Hot Contracts',
      type = 'number', min = 1, max = 720, suffix = ' min' },
    { key = 'hot.activeCount', label = 'Hot contracts active at once', group = 'Hot Contracts',
      type = 'number', min = 0, max = 10 },

    -- ── Vehicles ──
    { key = 'vehicle.conditionLossRate', label = 'Condition loss per damage point', group = 'Vehicles',
      type = 'number', min = 0, max = 5, step = 0.01, path = 'conditionLossRate' },
    { key = 'vehicle.ratingDamageDivisor', label = 'Damage per rating point lost', group = 'Vehicles',
      type = 'number', min = 1, max = 500, path = 'ratingDamageDivisor' },

    -- ── Dispatch ──
    { key = 'dispatch.payoutPct', label = 'Passive dispatch payout', group = 'Dispatch',
      type = 'number', min = 0, max = 200, suffix = '%' },
    { key = 'dispatch.minutes', label = 'Dispatch run duration', group = 'Dispatch',
      type = 'number', min = 1, max = 480, suffix = ' min' },
    { key = 'dispatch.maxConcurrent', label = 'Max concurrent dispatches', group = 'Dispatch',
      type = 'number', min = 0, max = 50 },

    -- ── Companies ──
    { key = 'company.foundingCost', label = 'Cost to found a company', group = 'Companies',
      type = 'number', min = 0, max = 10000000, prefix = '$' },
    { key = 'company.driverCutPct', label = 'Driver cut on company trucks', group = 'Companies',
      type = 'number', min = 0, max = 100, suffix = '%' },
}

local BY_KEY = {}
for _, def in ipairs(SCHEMA) do BY_KEY[def.key] = def end

-- Config defaults, resolved at call time rather than baked into SCHEMA —
-- Config is a shared_script and may not be populated when this file's
-- top-level chunk runs.
local function configDefault(key)
    local T = Config.Trucking
    local map = {
        ['economy.payoutMult'] = 100,
        ['economy.xpMult'] = 100,
        ['economy.repairCostPerPoint'] = T.repairCostPerPoint,
        ['economy.paintCost'] = T.paintCost,
        ['bonus.multiStopPct'] = T.multiStopBonusPct,
        ['bonus.ratingBonusPct'] = T.ratingBonusPct,
        ['bonus.ratingPenaltyPct'] = T.ratingPenaltyPct,
        ['bonus.ratingBonusThreshold'] = T.ratingBonusThreshold,
        ['bonus.ratingPenaltyThreshold'] = T.ratingPenaltyThreshold,
        ['hot.enabled'] = T.HotContracts and T.HotContracts.enabled,
        ['hot.payoutBonusPct'] = T.HotContracts and T.HotContracts.payoutBonusPct,
        ['hot.rotateMinutes'] = T.HotContracts and T.HotContracts.rotateMinutes,
        ['hot.activeCount'] = T.HotContracts and T.HotContracts.activeCount,
        ['vehicle.conditionLossRate'] = T.conditionLossRate,
        ['vehicle.ratingDamageDivisor'] = T.ratingDamageDivisor,
        ['dispatch.payoutPct'] = T.Company and T.Company.passiveDispatchPayoutPct,
        ['dispatch.minutes'] = T.Company and T.Company.passiveDispatchMinutes,
        ['dispatch.maxConcurrent'] = T.Company and T.Company.maxConcurrentDispatches,
        ['company.foundingCost'] = T.Company and T.Company.foundingCost,
        ['company.driverCutPct'] = T.Company and T.Company.driverCutPct,
    }
    return map[key]
end

-- Values round-trip through TEXT, so booleans and numbers both come back as
-- strings and have to be coerced against the schema's declared type.
local function coerce(def, raw)
    if def.type == 'bool' then
        return raw == true or raw == 'true' or raw == 1 or raw == '1'
    end
    return tonumber(raw)
end

function Settings.Load()
    if not WaitForDB() then return end

    local rows = MySQL.query.await('SELECT `key`, `value` FROM cipher_trucking_settings') or {}
    cache = {}
    for _, r in ipairs(rows) do
        local def = BY_KEY[r.key]
        -- Silently drop rows for keys no longer in the schema, so removing a
        -- knob in a future version doesn't resurrect a dead override.
        if def then cache[r.key] = coerce(def, r.value) end
    end
    loaded = true
end

function Settings.Get(key, fallback)
    if cache[key] ~= nil then return cache[key] end
    local d = configDefault(key)
    if d ~= nil then return d end
    return fallback
end

-- Global shorthand — this gets read at a lot of call sites and
-- `Settings.Get` at every one of them buries the actual logic.
function SGet(key, fallback)
    return Settings.Get(key, fallback)
end

function Settings.Set(key, value)
    local def = BY_KEY[key]
    if not def then return false, 'Unknown setting.' end

    local coerced = coerce(def, value)
    if def.type == 'number' then
        if not coerced then return false, 'Not a number.' end
        if def.min and coerced < def.min then return false, ('Minimum is %s.'):format(def.min) end
        if def.max and coerced > def.max then return false, ('Maximum is %s.'):format(def.max) end
    end

    cache[key] = coerced
    MySQL.query.await(
        'INSERT INTO cipher_trucking_settings (`key`, `value`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `value` = VALUES(`value`)',
        { key, tostring(coerced) })
    return true
end

-- Deleting the row (rather than writing the config value back into it) is
-- what makes this a genuine reset — the key returns to tracking config.lua.
function Settings.Reset(key)
    if not BY_KEY[key] then return false, 'Unknown setting.' end
    cache[key] = nil
    MySQL.query.await('DELETE FROM cipher_trucking_settings WHERE `key` = ?', { key })
    return true
end

function Settings.ResetAll()
    cache = {}
    MySQL.query.await('DELETE FROM cipher_trucking_settings')
    return true
end

-- Shaped for the admin Control tab: grouped, each entry carrying its
-- current value, the config default it would fall back to, and whether it's
-- currently overridden (so the UI can badge it).
function Settings.AdminList()
    local groups, order = {}, {}

    for _, def in ipairs(SCHEMA) do
        if not groups[def.group] then
            groups[def.group] = {}
            order[#order + 1] = def.group
        end

        local d = configDefault(def.key)
        if d == nil then d = def.default end

        groups[def.group][#groups[def.group] + 1] = {
            key = def.key, label = def.label, type = def.type,
            min = def.min, max = def.max, step = def.step,
            prefix = def.prefix, suffix = def.suffix, help = def.help,
            value = Settings.Get(def.key),
            default = d,
            overridden = cache[def.key] ~= nil,
        }
    end

    local out = {}
    for i, name in ipairs(order) do
        out[i] = { group = name, items = groups[name] }
    end
    return out
end

CreateThread(function()
    Settings.Load()
    if Config.Debug and loaded then
        local n = 0
        for _ in pairs(cache) do n = n + 1 end
        print(('^2[cipher-trucking]^0 settings loaded — %d override(s) active'):format(n))
    end
end)
