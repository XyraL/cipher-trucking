-- ─────────────────────────────────────────────────────────────
-- Self-provisioning schema
-- Every table this resource uses creates and migrates itself on boot. There
-- is no SQL file to import and no upgrade step for server owners to
-- remember — dropping a new version in and restarting is the whole process.
--
-- This exists because the sibling `cipher-drugs` resource lost a testing
-- session to exactly the failure this prevents: an owner syncing files to a
-- host, the database still holding a previous version's schema, and every
-- query failing with column errors that pointed nowhere near the real cause.
-- A hand-maintained .sql file drifts from the code the moment anyone forgets
-- to update it. This file cannot drift, because it IS the schema.
--
-- Design rules carried over from that incident:
--   * SHOW COLUMNS wrapped in pcall, never INFORMATION_SCHEMA — the latter
--     silently returns nothing when the connection lacks schema privileges,
--     which reads as "column already present" and skips the migration.
--   * Failures print loudly and set DBFailed rather than pretending success.
--   * Nothing ever waits on this unboundedly. WaitForDB takes a timeout, so
--     a stalled boot degrades into a clear error instead of a callback that
--     never returns and a UI stuck on "Loading..." forever.
-- ─────────────────────────────────────────────────────────────

-- ── Callback safety net ──────────────────────────────────────
-- Wraps EVERY lib.callback.register in this resource so a handler that
-- errors still sends a response.
--
-- Without it the failure is invisible and total: an unhandled Lua error part
-- way through a callback means cb() is never called, so the client's
-- lib.callback.await never returns, so the NUI's fetch never settles, so the
-- panel sits on "Loading..." forever with nothing in the console to explain
-- it. The player sees a dead tab and there is no thread to pull.
--
-- server/company.lua already had a local `safeCall` doing this for its own 16
-- callbacks, added after that exact symptom on the Company tab. It was never
-- extended to the other 21 — which is why the Contracts tab could hang the
-- same way. Patching the registrar instead of each call site means every
-- callback is covered, including any added later.
--
-- Done here because db.lua is the first server file in fxmanifest, so the
-- override is in place before anything registers.
do
    local _register = lib.callback.register

    lib.callback.register = function(name, fn)
        return _register(name, function(src, ...)
            local results = { pcall(fn, src, ...) }

            if not results[1] then
                print(('^1[cipher-trucking]^0 callback "%s" errored — returning nil so the UI does not hang.\n  %s')
                    :format(name, tostring(results[2])))
                return nil
            end

            return table.unpack(results, 2)
        end)
    end
end

DBReady = false
DBFailed = false

-- Presence marker. server/admin.lua's boot self-check looks for this to
-- catch a partial file upload — the failure mode where an owner copies some
-- new files to their host but not others, and the resource half-works in
-- ways that look like unrelated bugs.
DBLoaded = true

local function log(msg)
    print(('^3[cipher-trucking]^0 %s'):format(msg))
end

local function logError(msg)
    print(('^1[cipher-trucking]^0 %s'):format(msg))
end

-- ── Schema ───────────────────────────────────────────────────
-- Order matters: cipher_trucking_companies must exist before the four
-- tables that carry a foreign key onto it.
--
-- JSON columns are deliberately NULLable with no DEFAULT. A DEFAULT on a
-- LONGTEXT needs MySQL 8.0.13+ and isn't portable to older MariaDB builds,
-- and every reader already coalesces (`owned.upgrades or '{}'` in Lua,
-- `o.upgrades || '{}'` in the NUI), so nothing gains from the default.
local TABLES = {
    {
        name = 'cipher_trucking_stats',
        sql = [[
            CREATE TABLE IF NOT EXISTS `cipher_trucking_stats` (
                `citizenid`       VARCHAR(64)  NOT NULL,
                `name`            VARCHAR(96)  NOT NULL DEFAULT '',
                `xp`              INT          NOT NULL DEFAULT 0,
                `level`           INT          NOT NULL DEFAULT 1,
                `total_completed` INT          NOT NULL DEFAULT 0,
                `total_earned`    INT          NOT NULL DEFAULT 0,
                `rating_sum`      INT          NOT NULL DEFAULT 0,
                PRIMARY KEY (`citizenid`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    },
    {
        name = 'cipher_trucking_companies',
        sql = [[
            CREATE TABLE IF NOT EXISTS `cipher_trucking_companies` (
                `id`               INT UNSIGNED NOT NULL AUTO_INCREMENT,
                `name`             VARCHAR(64)  NOT NULL,
                `label`            VARCHAR(64)  NOT NULL,
                `owner`            VARCHAR(64)  NOT NULL,
                `bank`             BIGINT       NOT NULL DEFAULT 0,
                `reputation`       INT          NOT NULL DEFAULT 0,
                `perk_points`      INT          NOT NULL DEFAULT 0,
                `total_deliveries` INT          NOT NULL DEFAULT 0,
                `created_at`       TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                UNIQUE KEY `idx_name` (`name`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    },
    {
        name = 'cipher_trucking_owned',
        sql = [[
            CREATE TABLE IF NOT EXISTS `cipher_trucking_owned` (
                `id`                   INT UNSIGNED NOT NULL AUTO_INCREMENT,
                `citizenid`            VARCHAR(64)  NOT NULL,
                `company_id`           INT UNSIGNED NULL,
                `kind`                 VARCHAR(16)  NOT NULL DEFAULT 'truck',
                `model`                VARCHAR(64)  NOT NULL,
                `label`                VARCHAR(96)  NOT NULL DEFAULT '',
                `condition`            TINYINT      NOT NULL DEFAULT 100,
                `dispatch_ready_at`    BIGINT       NULL,
                `dispatch_contract_id` VARCHAR(64)  NULL,
                `dispatch_payout`      INT          NULL,
                `upgrades`             LONGTEXT     NULL,
                `livery`               LONGTEXT     NULL,
                -- JSON {fuel, tyres, brakes, oil, odometer}. One column
                -- rather than five, so adding a wear component later is a
                -- config change instead of another migration.
                `maintenance`          LONGTEXT     NULL,
                `purchased_at`         TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_citizen` (`citizenid`),
                KEY `idx_company` (`company_id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    },
    {
        name = 'cipher_trucking_deliveries',
        sql = [[
            CREATE TABLE IF NOT EXISTS `cipher_trucking_deliveries` (
                `id`                  INT UNSIGNED NOT NULL AUTO_INCREMENT,
                `citizenid`           VARCHAR(64)  NOT NULL,
                `contract_id`         VARCHAR(64)  NOT NULL,
                `label`               VARCHAR(128) NOT NULL DEFAULT '',
                `cargo_type`          VARCHAR(32)  NOT NULL DEFAULT '',
                `base_payout`         INT          NOT NULL DEFAULT 0,
                `final_payout`        INT          NOT NULL DEFAULT 0,
                `driver_cut`          INT          NOT NULL DEFAULT 0,
                `company_cut`         INT          NOT NULL DEFAULT 0,
                `company_id`          INT UNSIGNED NULL,
                `truck_bonus_pct`     INT          NOT NULL DEFAULT 0,
                `hot_bonus_pct`       INT          NOT NULL DEFAULT 0,
                `multistop_bonus_pct` INT          NOT NULL DEFAULT 0,
                `rating_bonus_pct`    INT          NOT NULL DEFAULT 0,
                `spoiled`             TINYINT      NOT NULL DEFAULT 0,
                `trip_rating`         INT          NOT NULL DEFAULT 100,
                `stop_count`          INT          NOT NULL DEFAULT 1,
                `xp`                  INT          NOT NULL DEFAULT 0,
                `distance_m`          INT          NOT NULL DEFAULT 0,
                `duration_seconds`    INT          NOT NULL DEFAULT 0,
                `completed_at`        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_citizen` (`citizenid`),
                KEY `idx_citizen_time` (`citizenid`, `completed_at`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    },
    {
        -- Admin overrides for tunable Config values. A key is only present
        -- once an admin has changed it; anything absent keeps tracking
        -- config.lua, so editing the config file still works normally for
        -- everything nobody has touched in-panel.
        name = 'cipher_trucking_settings',
        sql = [[
            CREATE TABLE IF NOT EXISTS `cipher_trucking_settings` (
                `key`        VARCHAR(64) NOT NULL,
                `value`      TEXT        NOT NULL,
                `updated_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`key`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    },
    {
        name = 'cipher_trucking_company_ranks',
        sql = [[
            CREATE TABLE IF NOT EXISTS `cipher_trucking_company_ranks` (
                `company_id`  INT UNSIGNED NOT NULL,
                `grade`       INT          NOT NULL,
                `name`        VARCHAR(48)  NOT NULL,
                `permissions` LONGTEXT     NOT NULL,
                PRIMARY KEY (`company_id`, `grade`),
                CONSTRAINT `fk_company_ranks_company` FOREIGN KEY (`company_id`)
                    REFERENCES `cipher_trucking_companies` (`id`) ON DELETE CASCADE
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    },
    {
        name = 'cipher_trucking_company_members',
        sql = [[
            CREATE TABLE IF NOT EXISTS `cipher_trucking_company_members` (
                `company_id` INT UNSIGNED NOT NULL,
                `citizenid`  VARCHAR(64)  NOT NULL,
                `name`       VARCHAR(96)  NOT NULL DEFAULT '',
                `grade`      INT          NOT NULL DEFAULT 0,
                `joined_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
                `last_seen`  BIGINT       NOT NULL DEFAULT 0,
                PRIMARY KEY (`citizenid`),
                KEY `idx_company` (`company_id`),
                CONSTRAINT `fk_company_members_company` FOREIGN KEY (`company_id`)
                    REFERENCES `cipher_trucking_companies` (`id`) ON DELETE CASCADE
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    },
    {
        name = 'cipher_trucking_company_perks',
        sql = [[
            CREATE TABLE IF NOT EXISTS `cipher_trucking_company_perks` (
                `company_id` INT UNSIGNED NOT NULL,
                `perk_id`    VARCHAR(48)  NOT NULL,
                `bought_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`company_id`, `perk_id`),
                CONSTRAINT `fk_company_perks_company` FOREIGN KEY (`company_id`)
                    REFERENCES `cipher_trucking_companies` (`id`) ON DELETE CASCADE
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    },
    {
        name = 'cipher_trucking_company_ledger',
        sql = [[
            CREATE TABLE IF NOT EXISTS `cipher_trucking_company_ledger` (
                `id`         INT UNSIGNED NOT NULL AUTO_INCREMENT,
                `company_id` INT UNSIGNED NOT NULL,
                `citizenid`  VARCHAR(64)  NOT NULL DEFAULT '',
                `name`       VARCHAR(96)  NOT NULL DEFAULT '',
                `kind`       VARCHAR(16)  NOT NULL,
                `amount`     BIGINT       NOT NULL,
                `created_at` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_company` (`company_id`),
                CONSTRAINT `fk_company_ledger_company` FOREIGN KEY (`company_id`)
                    REFERENCES `cipher_trucking_companies` (`id`) ON DELETE CASCADE
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        ]],
    },
}

-- ── Column migrations ────────────────────────────────────────
-- Only relevant to databases created by an OLDER version of this resource;
-- a fresh install already has every column from the CREATE TABLE above and
-- these all no-op. `ADD COLUMN IF NOT EXISTS` is deliberately NOT used —
-- it needs MySQL 8.0.29+ / MariaDB 10.5+, and silently erroring on older
-- builds is exactly the kind of half-migration this file exists to avoid.
local MIGRATIONS = {
    { table = 'cipher_trucking_stats', column = 'rating_sum',
      sql = 'ALTER TABLE `cipher_trucking_stats` ADD COLUMN `rating_sum` INT NOT NULL DEFAULT 0' },

    { table = 'cipher_trucking_owned', column = 'company_id',
      sql = 'ALTER TABLE `cipher_trucking_owned` ADD COLUMN `company_id` INT UNSIGNED NULL' },
    { table = 'cipher_trucking_owned', column = 'kind',
      sql = 'ALTER TABLE `cipher_trucking_owned` ADD COLUMN `kind` VARCHAR(16) NOT NULL DEFAULT \'truck\'' },
    { table = 'cipher_trucking_owned', column = 'dispatch_ready_at',
      sql = 'ALTER TABLE `cipher_trucking_owned` ADD COLUMN `dispatch_ready_at` BIGINT NULL' },
    { table = 'cipher_trucking_owned', column = 'dispatch_contract_id',
      sql = 'ALTER TABLE `cipher_trucking_owned` ADD COLUMN `dispatch_contract_id` VARCHAR(64) NULL' },
    { table = 'cipher_trucking_owned', column = 'dispatch_payout',
      sql = 'ALTER TABLE `cipher_trucking_owned` ADD COLUMN `dispatch_payout` INT NULL' },
    { table = 'cipher_trucking_owned', column = 'upgrades',
      sql = 'ALTER TABLE `cipher_trucking_owned` ADD COLUMN `upgrades` LONGTEXT NULL' },
    { table = 'cipher_trucking_owned', column = 'livery',
      sql = 'ALTER TABLE `cipher_trucking_owned` ADD COLUMN `livery` LONGTEXT NULL' },
    { table = 'cipher_trucking_owned', column = 'maintenance',
      sql = 'ALTER TABLE `cipher_trucking_owned` ADD COLUMN `maintenance` LONGTEXT NULL' },

    { table = 'cipher_trucking_companies', column = 'perk_points',
      sql = 'ALTER TABLE `cipher_trucking_companies` ADD COLUMN `perk_points` INT NOT NULL DEFAULT 0' },
    { table = 'cipher_trucking_companies', column = 'total_deliveries',
      sql = 'ALTER TABLE `cipher_trucking_companies` ADD COLUMN `total_deliveries` INT NOT NULL DEFAULT 0' },
}

-- Returns true / false / nil, where nil means "couldn't determine". A nil
-- result skips the migration rather than blindly running it — re-adding an
-- existing column is a hard error, and guessing wrong would abort the boot.
local function columnExists(tableName, column)
    local ok, result = pcall(function()
        return MySQL.query.await(('SHOW COLUMNS FROM `%s` LIKE ?'):format(tableName), { column })
    end)
    if not ok then return nil end
    if type(result) ~= 'table' then return nil end
    return #result > 0
end

local function runMigrations()
    local applied = 0
    for _, m in ipairs(MIGRATIONS) do
        local exists = columnExists(m.table, m.column)
        if exists == false then
            local ok, err = pcall(function() MySQL.query.await(m.sql) end)
            if ok then
                applied = applied + 1
                log(('migrated: added %s.%s'):format(m.table, m.column))
            else
                logError(('migration FAILED for %s.%s — %s'):format(m.table, m.column, tostring(err)))
            end
        elseif exists == nil then
            logError(('could not inspect %s.%s — skipping its migration. If you see column errors later, add it by hand.')
                :format(m.table, m.column))
        end
    end
    return applied
end

-- ── Boot ─────────────────────────────────────────────────────
CreateThread(function()
    -- oxmysql starting after this resource is normal and not an error; it
    -- just means the first queries have to wait for it.
    local waited = 0
    while GetResourceState('oxmysql') ~= 'started' do
        Wait(200)
        waited = waited + 200
        if waited >= 30000 then
            DBFailed = true
            logError('oxmysql never started — cipher-trucking cannot run. Check your server.cfg ensure order.')
            return
        end
    end

    -- oxmysql reports 'started' slightly before it will actually accept
    -- queries; one cheap round-trip confirms the connection is live.
    local connected = false
    for _ = 1, 25 do
        local ok = pcall(function() MySQL.scalar.await('SELECT 1') end)
        if ok then connected = true break end
        Wait(400)
    end

    if not connected then
        DBFailed = true
        logError('could not reach the database after 10s. cipher-trucking will not function until this is fixed.')
        return
    end

    local created = 0
    for _, t in ipairs(TABLES) do
        local ok, err = pcall(function() MySQL.query.await(t.sql) end)
        if not ok then
            DBFailed = true
            logError(('FAILED creating `%s` — %s'):format(t.name, tostring(err)))
            logError('Schema setup aborted. Nothing will work until this is resolved — the error above is the cause.')
            return
        end
        created = created + 1
    end

    local migrated = runMigrations()

    DBReady = true
    log(('database ready — %d tables verified%s')
        :format(created, migrated > 0 and (', %d column(s) migrated'):format(migrated) or ''))
end)

-- ── Gate ─────────────────────────────────────────────────────
-- BOUNDED, always. cipher-drugs shipped an unbounded `while not DBReady do`
-- and a single missing file turned every affected callback into a permanent
-- hang — the NUI just sat on "Loading..." with nothing in the console. A
-- timeout converts that into a visible failure instead of a mystery.
function WaitForDB(timeoutMs)
    if DBReady then return true end
    if DBFailed then return false end

    local waited = 0
    local limit = timeoutMs or 10000
    while not DBReady and not DBFailed and waited < limit do
        Wait(50)
        waited = waited + 50
    end

    if not DBReady then
        logError(('a query was made before the database finished setting up (waited %dms). Returning empty data.')
            :format(waited))
    end
    return DBReady
end
