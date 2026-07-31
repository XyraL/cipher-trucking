Config = {}

Config.Debug = false

-- ─────────────────────────────────────────────────────────────
-- Depot
-- Job blip, the world computer used to open the contract board, and the
-- truck/trailer spawn pools. All coordinates below marked "confirmed" were
-- given by the server owner via in-game testing — trust them as-is.
-- ─────────────────────────────────────────────────────────────
Config.Trucking = {}

-- Map blip shown at the depot so players can find the job.
Config.Trucking.jobLocation = vec4(1204.8883, -3117.1033, 5.5403, 2.6878)

Config.Trucking.blip = {
    sprite = 477,
    color = 5,
    scale = 0.8,
    label = 'Trucking Depot',
}

-- ox_target zone anchored on an EXISTING world computer prop — there is no
-- entity to attach to (nothing is spawned here), so this uses a box zone
-- centered on the coords/heading below rather than addLocalEntity.
Config.Trucking.computerCoords = vec4(1209.09, -3114.97, 5.61, 75.18)
Config.Trucking.computerZoneSize = vec3(0.5, 0.5, 1.0)
Config.Trucking.computerZoneDistance = 2.0

-- Truck spawn/return spots — confirmed ground-level by user testing.
-- Used for BOTH purposes: a random slot spawns the job truck on accept,
-- and the same 4-point pool is where the rig must be parked to return it
-- and complete the job.
Config.Trucking.truckSpawns = {
    vec4(1244.4124, -3135.5105, 5.8264, 270.9522),
    vec4(1243.7046, -3142.3057, 5.8056, 271.0386),
    vec4(1244.1990, -3149.2036, 5.8209, 270.3443),
    vec4(1244.2622, -3155.7896, 5.8229, 270.6933),
}

-- Trailer spawn points — confirmed ground-level by user testing.
Config.Trucking.trailerSpawns = {
    vec4(1273.9138, -3160.4355, 6.1377, 90.7130),
    vec4(1273.3838, -3168.9919, 6.1392, 90.3086),
    vec4(1272.8040, -3174.9897, 6.1591, 89.2655),
    vec4(1272.3174, -3184.5920, 6.1424, 86.1031),
}

-- Canonical semi+trailer pair with matching hitch points. Swap freely —
-- just keep truck/trailer models that visually hitch together correctly.
Config.Trucking.truckModel = 'hauler'
Config.Trucking.trailerModel = 'trailers2'

-- How close (meters) various interactions require you to be.
Config.Trucking.hookupRadius = 6.0   -- player + truck + trailer, all near the trailer spawn
Config.Trucking.deliverRadius = 8.0  -- player + rig, near the contract destination
Config.Trucking.returnRadius = 8.0   -- rig, near a truck spawn/return spot

-- Which money account contract payouts are deposited into.
Config.Trucking.payoutAccount = 'bank'

-- Vehicle keys integration — the truck spawns unlocked with hotwiring
-- disabled, but most servers also run a separate keys system that blocks
-- the engine until a vehicle is explicitly handed to a player, even so.
-- Options:
--   'qbx'            -> qbx_vehiclekeys (the standard QBox recipe's keys
--                        resource, a separate resource from qbx_core).
--                        Applied server-side (server/main.lua) since its
--                        GiveKeys export needs the server's own resolved
--                        vehicle handle — nothing else to configure.
--   'qb-vehiclekeys' -> TriggerEvent('vehiclekeys:client:SetOwner', plate)
--   'qs-vehiclekeys' -> exports['qs-vehiclekeys']:GiveKeys(plate)
--   'custom'         -> exports['cipher-trucking']:OnGiveKeys(vehicle, plate) -- implement your own handler
--   false            -> disabled (no keys system on this server)
-- Wrapped in pcall, so a wrong/missing export never hard-errors the script —
-- flip Config.Debug on to see the real error in console if the truck still
-- won't start after picking the right option.
Config.Trucking.KeysResource = 'qbx'

-- Staff-only admin panel (company oversight — list/force-disband any
-- company). Grant in server.cfg, e.g.:
--   add_ace group.admin cipher-trucking.admin allow
--   add_principal identifier.fivem:1234 group.admin
Config.Trucking.AdminCommand = 'truckingadmin'
Config.Trucking.AdminAce = 'cipher-trucking.admin'

-- How many entries the Leaderboard tab shows.
Config.Trucking.leaderboardLimit = 10

-- Analytics tab: how many days back the earnings/distance charts cover.
Config.Trucking.analyticsDays = 14

-- Receipts tab: how many past deliveries to list. Rows are never deleted —
-- this only bounds what's fetched, so raising it later shows older runs
-- that were already recorded.
Config.Trucking.historyLimit = 40

-- Cash charged per condition point restored at the Garage's Repair action.
Config.Trucking.repairCostPerPoint = 15

-- Condition points lost per combined body+engine health point of damage an
-- owned truck takes during a delivery (GTA5 vehicle health maxes at 1000
-- per component, so losing all ~2000 combined health drains 100 condition —
-- i.e. a truck driven into the ground on one trip). Only applies to owned
-- trucks bought from the shop; the free depot truck never takes damage.
Config.Trucking.conditionLossRate = 0.05

-- ─────────────────────────────────────────────────────────────
-- Driver rating
-- A running average (0-100), separate from XP/level, tracking how clean
-- your driving is — applies to EVERY delivery regardless of which truck
-- you're using (unlike condition loss above, which is owned-truck only).
-- ratingDamageDivisor: combined body+engine health points of damage per 1
-- rating point lost on a single trip (e.g. 20 -> losing all ~2000 combined
-- health on one trip tanks that trip's score by 100, i.e. to 0).
-- Your rating average GOING INTO a delivery (not including that delivery's
-- own result) grants a small payout bonus/penalty at the thresholds below.
-- ─────────────────────────────────────────────────────────────
Config.Trucking.ratingDamageDivisor = 20
Config.Trucking.ratingBonusThreshold = 90   -- average >= this grants...
Config.Trucking.ratingBonusPct = 5          -- ...this much extra payout
Config.Trucking.ratingPenaltyThreshold = 50 -- average <= this applies...
Config.Trucking.ratingPenaltyPct = 5        -- ...this much payout reduction

-- ─────────────────────────────────────────────────────────────
-- Fuel & maintenance
--
-- Everything here is expressed as a 0-100 percentage rather than litres or
-- kilometres of tread. It keeps every gauge on the same scale as the
-- existing `condition` bar, it means one shared UI component renders all of
-- them, and it sidesteps arguing about realistic consumption figures on a
-- map where a "long haul" is about 10 km.
--
-- Set `Config.Trucking.Maintenance.enabled = false` to switch the whole
-- system off; every hook checks it and the UI hides its panels.
-- ─────────────────────────────────────────────────────────────
Config.Trucking.Maintenance = {
    enabled = true,

    Fuel = {
        -- Percent of tank burned per kilometre driven. At 2.5, a full tank
        -- covers ~40 km — roughly four long hauls — so refuelling is a real
        -- part of the loop without becoming the main thing you do.
        burnPerKm = 2.5,
        -- Multiplier applied while a trailer is hitched. Deadheading home
        -- after a drop is deliberately cheaper than the loaded leg out.
        loadedMult = 1.45,
        -- Idling still costs something, so leaving the engine running at a
        -- delivery point isn't free.
        idleBurnPerMinute = 0.4,
        pricePerPercent = 22,
        lowWarnPct = 20,
        -- The free depot truck always starts full — new drivers shouldn't
        -- meet this system before they've completed a single delivery.
        -- Owned trucks keep whatever was left in the tank.
        depotTruckStartsFull = true,
    },

    -- Owned trucks only, exactly like `condition` — the free depot truck
    -- never accumulates wear. `perKm` is percent lost per kilometre driven;
    -- `perDamagePoint` is extra wear per point of body+engine damage taken,
    -- so hard driving wears parts faster than distance alone.
    Wear = {
        { id = 'tyres',  label = 'Tyres',  perKm = 0.85, perDamagePoint = 0.004, serviceCost = 1800,
          warnAt = 25, help = 'Worn tyres reduce grip badly in corners and rain.' },
        { id = 'brakes', label = 'Brakes', perKm = 0.60, perDamagePoint = 0.005, serviceCost = 1400,
          warnAt = 25, help = 'Worn brakes make the rig take more damage in a collision.' },
        { id = 'oil',    label = 'Oil',    perKm = 0.45, perDamagePoint = 0.001, serviceCost = 900,
          warnAt = 20, help = 'Low oil slowly cooks the engine while you drive.' },
    },

    -- What actually happens when a component runs low. Kept deliberately
    -- mild: this should add texture to a delivery, not strand players or
    -- make an owned truck feel worse to drive than the free one.
    Penalties = {
        -- Below this, tyres call SetVehicleReduceGrip.
        tyresGripBelow = 25,
        -- Below this, brakes multiply condition loss from collisions.
        brakesDamageBelow = 25,
        brakesDamageMult = 1.6,
        -- Below this, oil drains engine health slowly while driving.
        oilEngineDrainBelow = 20,
        oilEngineDrainPerMinute = 12.0,
    },

    -- Refuel points. Targeted with ox_target, drawn on the Route Map, and
    -- validated by the diagnostics check. Add as many as you like — these
    -- are placed near the default depot and the two dock/airport routes.
    -- ⚠ VERIFY these sit on real forecourts on your map build before going
    -- live; they were chosen from coordinates, not from standing there.
    Stations = {
        { label = 'Depot Pumps',      coords = vec3(1208.28, -3138.51, 5.53) },
        { label = 'Elysian Fields',   coords = vec3(288.90, -1261.60, 29.29) },
        { label = 'Great Ocean Hwy',  coords = vec3(-724.10, -935.32, 19.21) },
        { label = 'Palomino Freeway', coords = vec3(1207.26, -1402.65, 35.22) },
        { label = 'Route 68',         coords = vec3(1039.95, 2671.13, 39.55) },
    },
    stationRadius = 6.0,
}

-- ─────────────────────────────────────────────────────────────
-- Performance upgrades
-- Bought incrementally per category on a specific OWNED truck (from its
-- Garage/Fleet card, not a separate shop catalog entry) — cost scales with
-- the level being bought (costPerLevel * next level). Applied via
-- SetVehicleMod when that truck spawns. Trailers never get these — no
-- engine/brakes/transmission to upgrade. modType values are standard GTA5
-- vehicle mod-type indices.
-- ─────────────────────────────────────────────────────────────
Config.Trucking.PerformanceUpgrades = {
    { id = 'engine',       label = 'Engine',       modType = 11, maxLevel = 4, costPerLevel = 3000 },
    { id = 'brakes',       label = 'Brakes',       modType = 12, maxLevel = 3, costPerLevel = 2000 },
    { id = 'transmission', label = 'Transmission', modType = 13, maxLevel = 3, costPerLevel = 2500 },
    { id = 'suspension',   label = 'Suspension',   modType = 15, maxLevel = 4, costPerLevel = 2200 },
}

-- ─────────────────────────────────────────────────────────────
-- Truck liveries
-- Cosmetic only — no gameplay effect. A curated palette (not the full raw
-- GTA5 paint index range) applied via SetVehicleColours when the truck
-- spawns. Trucks only, same as performance upgrades — trailers don't get
-- these either.
-- ─────────────────────────────────────────────────────────────
Config.Trucking.paintCost = 2500
Config.Trucking.PaintColors = {
    { id = 0,   label = 'Black' },
    { id = 1,   label = 'Carbon Black' },
    { id = 111, label = 'Race Yellow' },
    { id = 27,  label = 'Red' },
    { id = 64,  label = 'Ultra Blue' },
    { id = 141, label = 'Forest Green' },
    { id = 38,  label = 'Orange' },
    { id = 88,  label = 'White' },
    { id = 156, label = 'Graphite' },
    { id = 3,   label = 'Silver' },
}

-- ─────────────────────────────────────────────────────────────
-- Truck & trailer shop
-- Optional upgrades — the free depot truck/trailer (Config.Trucking.truckModel
-- / trailerModel) always work for `general` cargo. Buying and selecting a
-- shop truck adds payoutBonusPct on top of a contract's base payout. Shop
-- trailers are FUNCTIONAL, not cosmetic: any contract with a `cargoType`
-- other than 'general' requires you to own and select a trailer whose
-- cargoType matches (see Config.Trucking.Contracts' requiredTrailerType
-- below) — the free depot trailer only covers general freight. Model names
-- below are PLACEHOLDERS — verify with your own model-check command before
-- going live, same as the contract destinations above.
-- ─────────────────────────────────────────────────────────────
-- Deliberately different models from Config.Trucking.truckModel ('hauler')
-- so a purchased truck always looks distinct from the free depot rig.
--
-- ⚠ EVERY shop truck MUST be a tractor unit with a fifth wheel. A shop truck
-- is used for real contracts, and the whole job stalls at the hookup stage
-- if it physically can't couple to a trailer. Box trucks (mule/mule3/benson/
-- pounder) look the part but have NO hitch — they are not valid here.
-- Models must also stay unique across this table: findShopEntryByModel in
-- server/main.lua resolves an owned vehicle back to its shop entry by model
-- alone, so a duplicate would silently resolve to the wrong entry.
Config.Trucking.Shop = {
    { id = 'compact_hauler', kind = 'truck', label = 'Compact Hauler', model = 'packer',   price = 15000, payoutBonusPct = 10 },
    { id = 'heavy_hauler',   kind = 'truck', label = 'Heavy Hauler',   model = 'phantom',  price = 35000, payoutBonusPct = 20 },
    -- VERIFY BEFORE GOING LIVE: 'phantom3' (Phantom Custom) is a DLC model,
    -- not base game. Confirm it exists on your build before shipping this
    -- tier — swap in any other tractor unit if it doesn't. The two entries
    -- above are base-game tractors and need no verification.
    { id = 'elite_rig',      kind = 'truck', label = 'Elite Rig',      model = 'phantom3', price = 65000, payoutBonusPct = 35 },

    -- Trailers — cargoType must match a contract's requiredTrailerType for
    -- that contract to be selectable. VERIFY BEFORE GOING LIVE: confirm both
    -- models exist on your build and visibly couple to the shop tractors
    -- above; a trailer that won't hitch blocks every contract that requires
    -- its cargoType.
    { id = 'reefer_trailer',       kind = 'trailer', label = 'Refrigerated Trailer', model = 'trailers4', price = 20000, cargoType = 'refrigerated' },
    { id = 'flatbed_trailer',      kind = 'trailer', label = 'Flatbed Trailer',      model = 'tr2',        price = 18000, cargoType = 'construction' },
}

-- ─────────────────────────────────────────────────────────────
-- Achievements
-- Computed live from cipher_trucking_stats every time the Career tab is
-- requested — no separate "earned" tracking table needed, just a threshold
-- check. type = 'total_completed' | 'level' | 'total_earned'.
-- ─────────────────────────────────────────────────────────────
Config.TruckingAchievements = {
    { id = 'first_delivery',  label = 'First Delivery',    description = 'Complete your first delivery', type = 'total_completed', value = 1 },
    { id = 'reliable_hauler', label = 'Reliable Hauler',   description = 'Complete 10 deliveries',        type = 'total_completed', value = 10 },
    { id = 'veteran_trucker', label = 'Veteran Trucker',   description = 'Complete 50 deliveries',        type = 'total_completed', value = 50 },
    { id = 'master_trucker',  label = 'Master Trucker',    description = 'Reach the max trucking rank',   type = 'level', value = 5 },
}

-- Bonus applied on top of the normal payout when a multi-stop contract
-- (one with a `stops` array instead of a single `destination`) is fully
-- completed — every stop delivered, not just the last one.
Config.Trucking.multiStopBonusPct = 25

-- ─────────────────────────────────────────────────────────────
-- Contracts
-- minLevel gates which contracts show up on the job board for a given
-- player (see Config.TruckingLevels below). Each entry needs EITHER a
-- single `destination` (single-stop) OR a `stops` array of coords
-- (multi-stop — every stop must be delivered before the trailer despawns
-- and payout fires, with Config.Trucking.multiStopBonusPct added on top).
--
-- `requiredTrailerType`, if set, must match a Config.Trucking.Shop trailer's
-- `cargoType` the player owns and has selected — the free depot trailer
-- only covers cargoType = 'general' contracts (no requiredTrailerType).
-- `spoilTimeSeconds` (refrigerated only) — soft time limit: delivering
-- later than this doesn't fail the contract, just halves the payout.
--
-- Coordinates below are confirmed ground-level by user testing. This is
-- just a starting set — server owners can add/remove/edit entries in this
-- table freely, nothing else needs touching.
-- ─────────────────────────────────────────────────────────────
Config.Trucking.Contracts = {
    {
        id = 'general_freight_01',
        label = 'General Freight — Docks',
        cargoType = 'general',
        minLevel = 1,
        destination = vec4(-509.84, -2852.44, 5.24, 45.51),
        payout = 350,
        xp = 40,
    },
    {
        id = 'general_freight_02',
        label = 'General Freight — Airport',
        cargoType = 'general',
        minLevel = 1,
        destination = vec4(-979.5997, -2865.0774, 14.1832, 59.9426),
        payout = 400,
        xp = 45,
    },
    {
        id = 'reefer_freight_01',
        label = 'Refrigerated Goods — Movie Set',
        cargoType = 'refrigerated',
        minLevel = 2,
        requiredTrailerType = 'refrigerated',
        spoilTimeSeconds = 480, -- 8 minutes enroute before payout is halved
        destination = vec4(-1025.7351, -516.4412, 36.4587, 25.0652),
        payout = 650,
        xp = 70,
    },
    {
        id = 'construction_freight_01',
        label = 'Construction Materials — Vinewood',
        cargoType = 'construction',
        minLevel = 3,
        requiredTrailerType = 'construction',
        destination = vec4(457.0935, 224.7394, 103.3604, 339.5320),
        payout = 900,
        xp = 100,
    },
    {
        id = 'multidrop_freight_01',
        label = 'Regional Multi-Drop — Docks & Airport',
        cargoType = 'general',
        minLevel = 3,
        -- Reuses the two confirmed general-freight spots as a sequential
        -- two-stop route rather than needing brand new coordinates.
        stops = {
            vec4(-509.84, -2852.44, 5.24, 45.51),
            vec4(-979.5997, -2865.0774, 14.1832, 59.9426),
        },
        payout = 500,
        xp = 90,
    },
}

-- ─────────────────────────────────────────────────────────────
-- Hot contracts
-- A small rotating set of bonus-payout contracts shown separately on the
-- board, refreshed every rotateMinutes — same idea as cipher's boosting
-- "wanted vehicles". Picked from `pool` (same shape as Config.Trucking.Contracts,
-- `payout`/`xp` here are the BASE values before payoutBonusPct is applied).
-- Rotation is computed lazily (checked whenever the contract board is
-- requested), not on a persistent timer, so it survives resource restarts
-- without losing its schedule.
-- ─────────────────────────────────────────────────────────────
Config.Trucking.HotContracts = {
    enabled = true,
    activeCount = 2,
    rotateMinutes = 30,
    payoutBonusPct = 50,
    pool = {
        {
            id = 'hot_general_01',
            label = 'Rush Freight — Vinewood',
            cargoType = 'general',
            minLevel = 1,
            destination = vec4(457.0935, 224.7394, 103.3604, 339.5320),
            payout = 450,
            xp = 60,
        },
        {
            id = 'hot_reefer_01',
            label = 'Rush Refrigerated — Movie Set',
            cargoType = 'refrigerated',
            minLevel = 2,
            requiredTrailerType = 'refrigerated',
            spoilTimeSeconds = 420,
            destination = vec4(-1025.7351, -516.4412, 36.4587, 25.0652),
            payout = 750,
            xp = 90,
        },
        {
            id = 'hot_construction_01',
            label = 'Rush Materials — Docks',
            cargoType = 'construction',
            minLevel = 3,
            requiredTrailerType = 'construction',
            destination = vec4(-509.84, -2852.44, 5.24, 45.51),
            payout = 1000,
            xp = 120,
        },
    },
}

-- ─────────────────────────────────────────────────────────────
-- Levels
-- Personal driver progression — xp accumulates from completed deliveries,
-- level gates which contracts show up on the board (Config.Trucking.Contracts'
-- minLevel field). Same shape/lookup convention as other Cipher scripts'
-- task-rank systems.
-- ─────────────────────────────────────────────────────────────
Config.TruckingLevels = {
    { level = 1, xpNeeded = 0,    title = 'Rookie Hauler' },
    { level = 2, xpNeeded = 150,  title = 'Regional Driver' },
    { level = 3, xpNeeded = 400,  title = 'Long-Haul Trucker' },
    { level = 4, xpNeeded = 800,  title = 'Owner-Operator' },
    { level = 5, xpNeeded = 1500, title = 'Master Trucker' },
}

-- ─────────────────────────────────────────────────────────────
-- Companies
-- Player-founded (NOT admin-seeded like cipher's gangs — a trucking company
-- is a legit business, "start your own" is the whole point). Pay
-- foundingCost at the depot to found one and become its Owner. Ranks/
-- permissions/treasury/reputation all follow the exact same pattern as
-- cipher's gang system (server/company.lua), just renamed.
-- ─────────────────────────────────────────────────────────────
Config.Trucking.Company = {
    foundingCost = 25000,
    account = 'bank', -- money account foundingCost/deposits/withdrawals use

    -- Permission keys checked throughout server/company.lua.
    Permissions = {
        'invite',           -- invite new members
        'kick',             -- remove members
        'promote',          -- change member ranks
        'manage_treasury',  -- withdraw company funds (deposit needs no permission)
        'manage_vehicles',  -- buy/repair/dispatch company trucks & trailers
        'manage_perks',     -- spend the company's perk points
    },

    -- Default rank ladder applied when a company is founded. Owners can
    -- rename ranks later; this is just the starting template. Higher grade
    -- = more authority. Grade 0 is the entry rank. The founder starts at
    -- the top grade and can never be kicked/demoted (same boss-immunity
    -- rule as cipher's gangs).
    DefaultRanks = {
        [0] = { name = 'Employee', permissions = {} },
        [1] = { name = 'Manager',  permissions = { 'invite', 'manage_vehicles' } },
        [2] = { name = 'Owner',    permissions = '*' },
    },

    -- Cut of a contract's payout that goes to the driver personally when
    -- they deliver using a COMPANY-owned truck; the remainder goes to the
    -- company treasury. Payouts from personally-owned trucks are unaffected
    -- (100% to the driver, as already built). Passive-dispatch payouts (no
    -- driver involved) always go 100% to whoever owns the truck.
    driverCutPct = 30,

    -- Passive/idle dispatch: an owned truck not currently selected/in-use
    -- can be sent to autonomously run a contract for real time instead of
    -- being driven. Pays passiveDispatchPayoutPct of the contract's normal
    -- payout once collected — less than driving it yourself, since nobody's
    -- actually doing the work. Computed lazily from a stored ready-at
    -- timestamp (no server timer needed, survives restarts for free).
    passiveDispatchPayoutPct = 50,
    passiveDispatchMinutes = 20, -- how long a dispatched truck is "out" before it's ready to collect
    maxConcurrentDispatches = 3, -- per player/company, so this can't be stacked indefinitely

    -- Company reputation tiers/titles — same shape/lookup as Config.TruckingLevels,
    -- but for the company as a whole. Earned from completed company-truck
    -- deliveries and collected dispatches. perkPoints awarded once, the
    -- moment the company crosses into that level (same as cipher's
    -- Config.GangLevels).
    Levels = {
        { level = 1, repNeeded = 0,    title = 'Startup Carrier',   perkPoints = 0 },
        { level = 2, repNeeded = 500,  title = 'Regional Carrier',  perkPoints = 1 },
        { level = 3, repNeeded = 1500, title = 'National Freight',  perkPoints = 1 },
        { level = 4, repNeeded = 3500, title = 'Logistics Group',   perkPoints = 2 },
        { level = 5, repNeeded = 7000, title = 'Freight Empire',    perkPoints = 2 },
    },

    ledgerLimit = 25, -- recent transactions kept on the Treasury tab
    leaderboardLimit = 10, -- top companies shown on the Leaderboard tab's Companies view

    -- ─────────────────────────────────────────────────────────────
    -- Perk tree
    -- Permanent, company-wide modifiers bought with perk_points (never
    -- consumed, no inventory items). Three branches, each a chain of tiers —
    -- tier N requires tier N-1 in that SAME branch already owned, exactly
    -- like cipher's Config.GangPerks (vault_1 -> vault_2 -> vault_3).
    -- Gated by the 'manage_perks' permission (add it to a rank's permission
    -- list to allow buying perks from that rank — Owner has it by default
    -- via '*').
    --   fleet:      maxDispatchBonus (+N concurrent dispatch slots)
    --   logistics:  dispatchTimeReductionPct (-N% passive dispatch duration),
    --               driverCutBonusPct (+N% driver cut on company-truck jobs)
    --   treasury:   depositBonusPct (+N% added to every treasury deposit)
    -- ─────────────────────────────────────────────────────────────
    PerkTree = {
        fleet = {
            label = 'Fleet',
            tiers = {
                { id = 'fleet_1', label = 'Extra Bay', description = '+1 concurrent dispatch slot',
                  cost = 1, maxDispatchBonus = 1 },
                { id = 'fleet_2', label = 'Expanded Yard', description = '+2 more concurrent dispatch slots',
                  cost = 2, maxDispatchBonus = 2 },
            },
        },
        logistics = {
            label = 'Logistics',
            tiers = {
                { id = 'logistics_1', label = 'Route Planning', description = '-15% passive dispatch time',
                  cost = 1, dispatchTimeReductionPct = 15 },
                { id = 'logistics_2', label = 'Preferred Contracts', description = '+10% driver cut on company-truck deliveries',
                  cost = 2, driverCutBonusPct = 10 },
            },
        },
        treasury = {
            label = 'Treasury',
            tiers = {
                { id = 'treasury_1', label = 'Smart Banking', description = '+5% on every treasury deposit',
                  cost = 1, depositBonusPct = 5 },
                { id = 'treasury_2', label = 'Investment Fund', description = '+10% more on every treasury deposit',
                  cost = 2, depositBonusPct = 10 },
            },
        },
    },

    -- Computed live from cipher_trucking_companies every time the Company
    -- tab is requested — no separate "earned" tracking table, same pattern
    -- as the personal achievements above. type = 'total_deliveries' | 'level' | 'reputation' | 'bank'.
    Achievements = {
        { id = 'first_company_delivery', label = 'First Company Delivery', description = 'Complete 1 delivery with a company truck or dispatch', type = 'total_deliveries', value = 1 },
        { id = 'established_carrier',    label = 'Established Carrier',    description = 'Complete 25 company deliveries',                          type = 'total_deliveries', value = 25 },
        { id = 'freight_empire',         label = 'Freight Empire',         description = 'Reach the max company rank',                              type = 'level', value = 5 },
        { id = 'deep_pockets',           label = 'Deep Pockets',           description = 'Reach a $100,000 treasury balance',                        type = 'bank', value = 100000 },
    },
}
