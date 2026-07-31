-- ─────────────────────────────────────────────────────────────
-- Companies
-- Player-founded (see Config.Trucking.Company.foundingCost), structurally
-- parallel to cipher's gang system (server/gangs.lua + bank.lua +
-- notoriety.lua in the `cipher` resource) — ranks/permissions, a treasury
-- with a ledger, invite/kick/promote membership, tiered reputation. Same
-- patterns, renamed, kept in one file since this system is smaller.
-- ─────────────────────────────────────────────────────────────
Company = {}

-- Debug-only timing wrapper — prints how long `fn` took so a slow-but-
-- successful call (which pcall alone would never surface, since nothing
-- throws) shows up in console instead of just being silently slow.
local function timed(label, fn, ...)
    if not Config.Debug then return fn(...) end
    local startedAt = GetGameTimer()
    local result = { fn(...) }
    print(('^3[cipher-trucking]^0 %s took %dms'):format(label, GetGameTimer() - startedAt))
    return table.unpack(result)
end

local cache = {}            -- [companyId] = { id, name, label, owner, bank, reputation, ranks, members }
local citizenToCompany = {} -- [citizenid] = companyId
local pendingInvites = {}   -- [targetSrc] = { companyId, from, company }

-- ── Loaders ──────────────────────────────────────────────────
local function loadRanks(companyId)
    local rows = MySQL.query.await('SELECT * FROM cipher_trucking_company_ranks WHERE company_id = ?', { companyId })
    local ranks = {}
    for _, r in ipairs(rows or {}) do
        local perms = r.permissions
        if perms ~= '*' then
            perms = json.decode(perms)
        end
        ranks[r.grade] = { name = r.name, permissions = perms }
    end
    return ranks
end

local function loadMembers(companyId)
    local rows = MySQL.query.await('SELECT * FROM cipher_trucking_company_members WHERE company_id = ?', { companyId })
    local members = {}
    for _, m in ipairs(rows or {}) do
        members[m.citizenid] = m
    end
    return members
end

local function loadCompany(companyId)
    local row = MySQL.single.await('SELECT * FROM cipher_trucking_companies WHERE id = ?', { companyId })
    if not row then return nil end
    row.ranks = loadRanks(companyId)
    row.members = loadMembers(companyId)
    cache[companyId] = row
    for cid in pairs(row.members) do
        citizenToCompany[cid] = companyId
    end
    return row
end

-- ── Lookups ──────────────────────────────────────────────────
function Company.Get(companyId)
    if not companyId then return nil end
    if cache[companyId] then return cache[companyId] end
    if not WaitForDB() then return nil end
    return loadCompany(companyId)
end

function Company.GetByCitizen(cid)
    if not cid then return nil end
    local companyId = citizenToCompany[cid]
    if companyId and cache[companyId] then return cache[companyId] end

    -- Every company read funnels through here on a cache miss — one gate
    -- covers the whole subsystem.
    if not WaitForDB() then return nil end

    local row = timed('GetByCitizen membership lookup', MySQL.single.await,
        'SELECT company_id FROM cipher_trucking_company_members WHERE citizenid = ?', { cid })
    if row then return loadCompany(row.company_id) end
    return nil
end

function Company.GetBySource(src)
    return Company.GetByCitizen(Framework.GetCitizenId(src))
end

-- ── Permissions ──────────────────────────────────────────────
local function gradeHasPerm(company, grade, perm)
    local rank = company.ranks[grade]
    if not rank then return false end
    if rank.permissions == '*' then return true end
    for _, p in ipairs(rank.permissions) do
        if p == perm then return true end
    end
    return false
end

function Company.HasPerm(src, perm)
    local cid = Framework.GetCitizenId(src)
    if not cid then return false end
    local company = Company.GetByCitizen(cid)
    if not company then return false end
    local member = company.members[cid]
    if not member then return false end
    return gradeHasPerm(company, member.grade, perm)
end

-- ── Founding ─────────────────────────────────────────────────
function Company.Found(src, name)
    name = tostring(name or ''):match('^%s*(.-)%s*$')
    if #name < 3 or #name > 40 then return false, 'Company name must be 3-40 characters.' end

    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'No character loaded.' end
    if Company.GetByCitizen(cid) then return false, 'You are already in a company.' end

    local existing = MySQL.single.await('SELECT id FROM cipher_trucking_companies WHERE name = ?', { name })
    if existing then return false, 'That company name is taken.' end

    local cfg = Config.Trucking.Company
    local foundingCost = SGet('company.foundingCost', cfg.foundingCost)
    if Framework.GetMoney(src, cfg.account) < foundingCost then
        return false, ('Founding a company costs $%d.'):format(foundingCost)
    end
    local paid = Framework.RemoveMoney(src, cfg.account, foundingCost, 'cipher-trucking:foundCompany')
    if not paid then return false, 'Payment failed.' end

    local companyId = MySQL.insert.await(
        'INSERT INTO cipher_trucking_companies (name, label, owner) VALUES (?, ?, ?)',
        { name, name, cid })

    local topGrade = 0
    for grade in pairs(cfg.DefaultRanks) do
        if grade > topGrade then topGrade = grade end
    end
    -- .await, NOT fire-and-forget: loadCompany() below immediately reads
    -- these rows back. A non-awaited insert isn't guaranteed to have hit the
    -- database by then (they can land on different pool connections), and
    -- losing that race caches a company with an EMPTY rank list and roster —
    -- the founder ends up with no rank, no permissions, and an empty Roster
    -- tab until something else forces a reload. Same reason AcceptInvite
    -- below awaits its insert.
    for grade, def in pairs(cfg.DefaultRanks) do
        local perms = def.permissions == '*' and '*' or json.encode(def.permissions)
        MySQL.insert.await('INSERT INTO cipher_trucking_company_ranks (company_id, grade, name, permissions) VALUES (?, ?, ?, ?)',
            { companyId, grade, def.name, perms })
    end

    MySQL.insert.await('INSERT INTO cipher_trucking_company_members (company_id, citizenid, name, grade) VALUES (?, ?, ?, ?)',
        { companyId, cid, Framework.GetName(src) or cid, topGrade })

    loadCompany(companyId)
    Framework.Notify(src, ('Founded %s — you are the Owner.'):format(name), 'success')
    return true, companyId
end

-- ── Membership ───────────────────────────────────────────────
function Company.Invite(src, targetSrc)
    if not Company.HasPerm(src, 'invite') then return false, 'No permission.' end
    local company = Company.GetBySource(src)
    if not company then return false, 'No company.' end

    targetSrc = tonumber(targetSrc)
    local targetCid = targetSrc and Framework.GetCitizenId(targetSrc)
    if not targetCid then return false, 'Target is not available.' end
    if Company.GetByCitizen(targetCid) then return false, 'That player is already in a company.' end

    pendingInvites[targetSrc] = { companyId = company.id, from = Framework.GetName(src), company = company.label }
    TriggerClientEvent('cipher-trucking:client:companyInvite', targetSrc,
        { company = company.label, from = pendingInvites[targetSrc].from })
    Framework.Notify(src, 'Invite sent.', 'success')
    return true
end

function Company.AcceptInvite(src)
    local invite = pendingInvites[src]
    if not invite then return false, 'No pending invite.' end
    pendingInvites[src] = nil

    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'No character loaded.' end
    if Company.GetByCitizen(cid) then return false, 'You are already in a company.' end

    -- Awaited for the same reason as Company.Found — loadCompany reads this
    -- row straight back, and losing the race leaves the joiner missing from
    -- the cached roster.
    MySQL.insert.await('INSERT INTO cipher_trucking_company_members (company_id, citizenid, name, grade) VALUES (?, ?, ?, 0)',
        { invite.companyId, cid, Framework.GetName(src) or cid })

    loadCompany(invite.companyId)
    Framework.Notify(src, ('You joined %s.'):format(invite.company or ''), 'success')
    return true
end

function Company.Kick(src, targetCid)
    if not Company.HasPerm(src, 'kick') then return false, 'No permission.' end
    local company = Company.GetBySource(src)
    if not company or not company.members[targetCid] then return false, 'Not a member.' end
    if company.owner == targetCid then return false, 'Cannot kick the Owner.' end

    -- Scoped to this company as well as the citizenid — the membership table
    -- keys on citizenid alone, so an unscoped write here would be trusting
    -- that invariant to hold rather than enforcing it.
    MySQL.update('DELETE FROM cipher_trucking_company_members WHERE citizenid = ? AND company_id = ?',
        { targetCid, company.id })
    company.members[targetCid] = nil
    citizenToCompany[targetCid] = nil
    return true
end

function Company.SetGrade(src, targetCid, grade)
    if not Company.HasPerm(src, 'promote') then return false, 'No permission.' end
    local company = Company.GetBySource(src)
    if not company or not company.members[targetCid] then return false, 'Not a member.' end
    if not company.ranks[grade] then return false, 'Invalid rank.' end
    if company.owner == targetCid then return false, "Cannot change the Owner's rank." end

    MySQL.update('UPDATE cipher_trucking_company_members SET grade = ? WHERE citizenid = ? AND company_id = ?',
        { grade, targetCid, company.id })
    company.members[targetCid].grade = grade
    return true
end

-- ── Treasury ─────────────────────────────────────────────────
local function logLedger(companyId, src, kind, amount)
    MySQL.insert('INSERT INTO cipher_trucking_company_ledger (company_id, citizenid, name, kind, amount) VALUES (?, ?, ?, ?, ?)',
        { companyId, src and Framework.GetCitizenId(src) or '', src and Framework.GetName(src) or 'System', kind, amount })
end

function Company.Deposit(src, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return false, 'Invalid amount.' end
    local company = Company.GetBySource(src)
    if not company then return false, 'No company.' end
    if Framework.GetMoney(src, Config.Trucking.Company.account) < amount then return false, 'Not enough money.' end

    Framework.RemoveMoney(src, Config.Trucking.Company.account, amount, 'cipher-trucking:companyDeposit')

    -- Treasury perk branch: deposits go in for a bonus over what was paid in.
    local mods = Company.ModifiersFor(company.id)
    local credited = amount + math.floor(amount * (mods.depositBonusPct / 100))

    company.bank = company.bank + credited
    MySQL.update('UPDATE cipher_trucking_companies SET bank = bank + ? WHERE id = ?', { credited, company.id })
    logLedger(company.id, src, 'deposit', credited)
    return true, company.bank
end

function Company.Withdraw(src, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return false, 'Invalid amount.' end
    if not Company.HasPerm(src, 'manage_treasury') then return false, 'No permission.' end
    local company = Company.GetBySource(src)
    if not company then return false, 'No company.' end
    if company.bank < amount then return false, 'Treasury balance too low.' end

    company.bank = company.bank - amount
    MySQL.update('UPDATE cipher_trucking_companies SET bank = bank - ? WHERE id = ?', { amount, company.id })
    Framework.AddMoney(src, Config.Trucking.Company.account, amount, 'cipher-trucking:companyWithdraw')
    logLedger(company.id, src, 'withdraw', amount)
    return true, company.bank
end

-- No player context — used for a company's cut of a contract payout, or a
-- passive-dispatch collection paid into the treasury.
function Company.CreditTreasury(companyId, amount, reason)
    local company = Company.Get(companyId)
    if not company then return end
    company.bank = company.bank + amount
    MySQL.update('UPDATE cipher_trucking_companies SET bank = bank + ? WHERE id = ?', { amount, companyId })
    MySQL.insert('INSERT INTO cipher_trucking_company_ledger (company_id, citizenid, name, kind, amount) VALUES (?, ?, ?, ?, ?)',
        { companyId, '', reason or 'income', 'income', amount })
end

function Company.GetLedger(companyId)
    return MySQL.query.await(
        'SELECT name, kind, amount, created_at FROM cipher_trucking_company_ledger WHERE company_id = ? ORDER BY id DESC LIMIT ?',
        { companyId, Config.Trucking.Company.ledgerLimit }) or {}
end

-- ── Reputation / leveling ────────────────────────────────────
function Company.LevelFor(reputation)
    local best = Config.Trucking.Company.Levels[1]
    for _, def in ipairs(Config.Trucking.Company.Levels) do
        if reputation >= def.repNeeded then best = def end
    end
    return best
end

-- Awards perk_points for EVERY level threshold crossed between the old and
-- new reputation (not just the final level landed on) — same logic shape
-- as cipher's gang notoriety perk-point award.
function Company.AddReputation(companyId, amount)
    local company = Company.Get(companyId)
    if not company then return end

    local oldLevel = Company.LevelFor(company.reputation).level
    company.reputation = math.max(0, company.reputation + amount)
    local newLevel = Company.LevelFor(company.reputation).level

    local perkPointsGained = 0
    if newLevel > oldLevel then
        for _, def in ipairs(Config.Trucking.Company.Levels) do
            if def.level > oldLevel and def.level <= newLevel then
                perkPointsGained = perkPointsGained + (def.perkPoints or 0)
            end
        end
    end

    company.perk_points = (company.perk_points or 0) + perkPointsGained
    MySQL.update('UPDATE cipher_trucking_companies SET reputation = ?, perk_points = perk_points + ? WHERE id = ?',
        { company.reputation, perkPointsGained, companyId })
end

-- ── Perk tree ────────────────────────────────────────────────
local function findPerkTier(perkId)
    for branchId, branch in pairs(Config.Trucking.Company.PerkTree) do
        for i, tier in ipairs(branch.tiers) do
            if tier.id == perkId then return branchId, branch, tier, i end
        end
    end
    return nil
end

local function ownedPerkIds(companyId)
    local rows = MySQL.query.await('SELECT perk_id FROM cipher_trucking_company_perks WHERE company_id = ?', { companyId }) or {}
    local owned = {}
    for _, r in ipairs(rows) do owned[r.perk_id] = true end
    return owned
end

-- Aggregates effect fields from every perk this company owns into a flat
-- modifiers table — callers just read the field they care about (0 if
-- nothing owned adds it), same "read the field where it's used" style as
-- the perk tree config itself.
function Company.ModifiersFor(companyId)
    local mods = { maxDispatchBonus = 0, dispatchTimeReductionPct = 0, driverCutBonusPct = 0, depositBonusPct = 0 }
    if not companyId then return mods end

    local owned = ownedPerkIds(companyId)
    for _, branch in pairs(Config.Trucking.Company.PerkTree) do
        for _, tier in ipairs(branch.tiers) do
            if owned[tier.id] then
                for _, field in ipairs({ 'maxDispatchBonus', 'dispatchTimeReductionPct', 'driverCutBonusPct', 'depositBonusPct' }) do
                    if tier[field] then mods[field] = mods[field] + tier[field] end
                end
            end
        end
    end
    return mods
end

function Company.BuyPerk(src, perkId)
    if not Company.HasPerm(src, 'manage_perks') then return false, 'No permission.' end
    local company = Company.GetBySource(src)
    if not company then return false, 'No company.' end

    local branchId, branch, tier, tierIndex = findPerkTier(perkId)
    if not tier then return false, 'Unknown perk.' end

    local owned = ownedPerkIds(company.id)
    if owned[perkId] then return false, 'Already owned.' end
    if tierIndex > 1 and not owned[branch.tiers[tierIndex - 1].id] then
        return false, ('Requires %s first.'):format(branch.tiers[tierIndex - 1].label)
    end
    if (company.perk_points or 0) < tier.cost then return false, 'Not enough perk points.' end

    company.perk_points = company.perk_points - tier.cost
    MySQL.update('UPDATE cipher_trucking_companies SET perk_points = perk_points - ? WHERE id = ?', { tier.cost, company.id })
    MySQL.insert('INSERT INTO cipher_trucking_company_perks (company_id, perk_id) VALUES (?, ?)', { company.id, perkId })

    Framework.Notify(src, ('Unlocked %s.'):format(tier.label), 'success')
    return true
end

-- ── Fleet ────────────────────────────────────────────────────
function Company.ListFleet(companyId)
    local rows = MySQL.query.await(
        'SELECT * FROM cipher_trucking_owned WHERE company_id = ? ORDER BY purchased_at ASC', { companyId }) or {}

    -- Decoded here for the same reason as the personal garage — the Fleet
    -- view renders the identical gauges and should read the identical shape.
    if Maintenance and Maintenance.Enabled() then
        for _, row in ipairs(rows) do row.maint = Maintenance.Read(row) end
    end
    return rows
end

local function findShopEntry(shopId)
    for _, s in ipairs(Config.Trucking.Shop) do
        if s.id == shopId then return s end
    end
    return nil
end

function Company.BuyVehicle(src, shopId)
    if not Company.HasPerm(src, 'manage_vehicles') then return false, 'No permission.' end
    local company = Company.GetBySource(src)
    if not company then return false, 'No company.' end

    local shopDef = findShopEntry(shopId)
    if not shopDef then return false, 'That is not for sale.' end
    if company.bank < shopDef.price then return false, 'Company treasury too low.' end

    company.bank = company.bank - shopDef.price
    MySQL.update('UPDATE cipher_trucking_companies SET bank = bank - ? WHERE id = ?', { shopDef.price, company.id })
    logLedger(company.id, src, 'purchase', shopDef.price)

    local cid = Framework.GetCitizenId(src)
    MySQL.insert(
        'INSERT INTO cipher_trucking_owned (citizenid, company_id, kind, model, label, `condition`) VALUES (?, ?, ?, ?, ?, 100)',
        { cid, company.id, shopDef.kind or 'truck', shopDef.model, shopDef.label })

    Framework.Notify(src, ('Company purchased %s.'):format(shopDef.label), 'success')
    return true
end

-- ── Passive / idle dispatch ──────────────────────────────────
-- Shared by personal trucks (company_id NULL) and company trucks alike —
-- only branches on ownership/permission checks and which balance collects
-- pay into. Computed lazily from a stored ready-at timestamp, no server
-- timer involved, so it survives restarts.
function Company.Dispatch(src, ownedId, contractId)
    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'No character loaded.' end

    local owned = MySQL.single.await('SELECT * FROM cipher_trucking_owned WHERE id = ?', { ownedId })
    if not owned then return false, 'Vehicle not found.' end
    if owned.kind ~= 'truck' then return false, 'Only trucks can be dispatched.' end
    if owned.dispatch_ready_at then return false, 'Already out on a run.' end
    if owned.condition <= 0 then return false, 'That truck needs repairs first.' end

    if owned.company_id then
        if not Company.HasPerm(src, 'manage_vehicles') then return false, 'No permission.' end
        local company = Company.GetBySource(src)
        if not company or company.id ~= owned.company_id then return false, "Not your company's vehicle." end
    elseif owned.citizenid ~= cid then
        return false, 'You do not own that truck.'
    end

    -- Fleet/Logistics perk branches only apply to company-owned trucks —
    -- personal trucks always use the flat config values.
    local mods = owned.company_id and Company.ModifiersFor(owned.company_id) or { maxDispatchBonus = 0, dispatchTimeReductionPct = 0 }

    local ownerClause = owned.company_id and 'company_id = ?' or 'citizenid = ? AND company_id IS NULL'
    local ownerParam = owned.company_id or cid
    local activeCount = MySQL.scalar.await(
        ('SELECT COUNT(*) FROM cipher_trucking_owned WHERE %s AND dispatch_ready_at IS NOT NULL'):format(ownerClause),
        { ownerParam })
    if (activeCount or 0) >= (SGet('dispatch.maxConcurrent', Config.Trucking.Company.maxConcurrentDispatches) + mods.maxDispatchBonus) then
        return false, 'Too many trucks already out on runs.'
    end

    local def = nil
    for _, c in ipairs(Config.Trucking.Contracts) do
        if c.id == contractId then def = c break end
    end
    if not def then return false, 'Contract not found.' end

    local payout = math.floor(def.payout * (SGet('dispatch.payoutPct', Config.Trucking.Company.passiveDispatchPayoutPct) / 100))
    local minutes = SGet('dispatch.minutes', Config.Trucking.Company.passiveDispatchMinutes)
        * (1 - mods.dispatchTimeReductionPct / 100)
    local readyAt = (os.time() * 1000) + math.floor(minutes * 60000)

    MySQL.update(
        'UPDATE cipher_trucking_owned SET dispatch_ready_at = ?, dispatch_contract_id = ?, dispatch_payout = ? WHERE id = ?',
        { readyAt, def.id, payout, ownedId })

    Framework.Notify(src, ('%s dispatched — ready in %d minutes.'):format(owned.label, math.floor(minutes)), 'success')
    return true
end

function Company.Collect(src, ownedId)
    local cid = Framework.GetCitizenId(src)
    if not cid then return false, 'No character loaded.' end

    local owned = MySQL.single.await('SELECT * FROM cipher_trucking_owned WHERE id = ?', { ownedId })
    if not owned then return false, 'Vehicle not found.' end
    if not owned.dispatch_ready_at then return false, 'That truck is not out on a run.' end

    if owned.company_id then
        if not Company.HasPerm(src, 'manage_vehicles') then return false, 'No permission.' end
    elseif owned.citizenid ~= cid then
        return false, 'You do not own that truck.'
    end

    if (os.time() * 1000) < owned.dispatch_ready_at then
        return false, 'Not back yet.'
    end

    local payout = owned.dispatch_payout or 0

    MySQL.update(
        'UPDATE cipher_trucking_owned SET dispatch_ready_at = NULL, dispatch_contract_id = NULL, dispatch_payout = NULL WHERE id = ?',
        { ownedId })

    if owned.company_id then
        Company.CreditTreasury(owned.company_id, payout, 'dispatch:' .. (owned.dispatch_contract_id or ''))
        Company.AddReputation(owned.company_id, 10)
        MySQL.update('UPDATE cipher_trucking_companies SET total_deliveries = total_deliveries + 1 WHERE id = ?', { owned.company_id })
    else
        Framework.AddMoney(src, Config.Trucking.payoutAccount, payout, 'cipher-trucking:dispatch')
    end

    Framework.Notify(src, ('Collected $%d from the dispatch run.'):format(payout), 'success')
    return true, payout
end

-- ── Achievements ─────────────────────────────────────────────
-- Live-computed against the company's own stats every time it's requested
-- — no separate "earned" tracking table, same pattern as
-- truckingAchievementsFor in server/main.lua.
function Company.AchievementsFor(company)
    local list = {}
    for _, def in ipairs(Config.Trucking.Company.Achievements) do
        local progress = company.total_deliveries or 0
        if def.type == 'level' then
            progress = Company.LevelFor(company.reputation).level
        elseif def.type == 'reputation' then
            progress = company.reputation
        elseif def.type == 'bank' then
            progress = company.bank
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

-- ── Dissolution ──────────────────────────────────────────────
-- Company-owned vehicles survive dissolution — reverted to personal
-- ownership under whichever citizenid originally bought them, not deleted.
-- Treasury cash is not refunded to anyone (the founding cost is a genuine
-- sink, not an escrow). Deletion of the company row cascades
-- ranks/members/ledger/perks via their existing foreign keys.
-- Global on the Company table (not local) so server/admin.lua's
-- force-disband can call the exact same logic on any company by id.
function Company.DisbandById(companyId)
    MySQL.update('UPDATE cipher_trucking_owned SET company_id = NULL WHERE company_id = ?', { companyId })
    MySQL.update('DELETE FROM cipher_trucking_companies WHERE id = ?', { companyId })

    for cid, id in pairs(citizenToCompany) do
        if id == companyId then citizenToCompany[cid] = nil end
    end
    cache[companyId] = nil
end

function Company.Disband(src)
    local company = Company.GetBySource(src)
    if not company then return false, 'No company.' end
    local cid = Framework.GetCitizenId(src)
    if company.owner ~= cid then return false, 'Only the Owner can disband the company.' end

    Company.DisbandById(company.id)
    Framework.Notify(src, ('%s has been disbanded.'):format(company.label), 'success')
    return true
end

-- ── Snapshot (for the NUI Company tab) ───────────────────────
local function onlineCitizenIds()
    local online = {}
    for _, p in ipairs(GetPlayers()) do
        local cid = Framework.GetCitizenId(tonumber(p))
        if cid then online[cid] = true end
    end
    return online
end

function Company.GetSnapshot(src)
    local company = Company.GetBySource(src)
    if not company then return nil end

    local myCid = Framework.GetCitizenId(src)
    local online = onlineCitizenIds()

    local roster = {}
    for cid, m in pairs(company.members) do
        roster[#roster + 1] = {
            citizenid = cid,
            name = m.name,
            grade = m.grade,
            rankName = company.ranks[m.grade] and company.ranks[m.grade].name or ('Grade ' .. m.grade),
            isOwner = company.owner == cid,
            online = online[cid] == true,
        }
    end
    table.sort(roster, function(a, b) return a.grade > b.grade end)

    local ranks = {}
    for grade, r in pairs(company.ranks) do
        ranks[#ranks + 1] = { grade = grade, name = r.name }
    end
    table.sort(ranks, function(a, b) return a.grade > b.grade end)

    local myGrade = company.members[myCid] and company.members[myCid].grade or 0
    local levelDef = Company.LevelFor(company.reputation)

    -- Resolved once against the company/grade we already hold. Calling
    -- Company.HasPerm six times below would redo Framework.GetCitizenId +
    -- Company.GetByCitizen on every single one — and GetByCitizen falls
    -- through to a DB query whenever the cache misses, so that's up to six
    -- redundant round-trips inside one snapshot.
    local function myPerm(perm)
        return gradeHasPerm(company, myGrade, perm)
    end

    return {
        id = company.id,
        name = company.label,
        bank = company.bank,
        reputation = company.reputation,
        level = levelDef,
        perkPoints = company.perk_points or 0,
        ownedPerks = ownedPerkIds(company.id),
        modifiers = Company.ModifiersFor(company.id),
        perkTree = Config.Trucking.Company.PerkTree,
        totalDeliveries = company.total_deliveries or 0,
        achievements = Company.AchievementsFor(company),
        myGrade = myGrade,
        myRankName = company.ranks[myGrade] and company.ranks[myGrade].name or '',
        isOwner = company.owner == myCid,
        roster = roster,
        ranks = ranks,
        fleet = Company.ListFleet(company.id),
        permissions = {
            invite = myPerm('invite'),
            kick = myPerm('kick'),
            promote = myPerm('promote'),
            manage_treasury = myPerm('manage_treasury'),
            manage_vehicles = myPerm('manage_vehicles'),
            manage_perks = myPerm('manage_perks'),
        },
    }
end

-- ── NUI-facing callbacks ─────────────────────────────────────
-- Every callback below is wrapped in pcall via safeCall. Without this, an
-- unhandled Lua error partway through one of these (e.g. a bad DB row) can
-- prevent the callback from ever calling cb() client-side — from the NUI's
-- perspective that's indistinguishable from the request just never coming
-- back, i.e. permanent "Loading...". This guarantees a response always
-- goes out, and logs what actually broke.
local function safeCall(label, fn, ...)
    local startedAt = GetGameTimer()
    local results = { pcall(fn, ...) }
    local ok = results[1]

    if Config.Debug then
        print(('^3[cipher-trucking]^0 %s total: %dms'):format(label, GetGameTimer() - startedAt))
    end

    if not ok then
        if Config.Debug then
            print(('^1[cipher-trucking]^0 %s error: %s'):format(label, tostring(results[2])))
        else
            print(('^1[cipher-trucking]^0 %s failed — enable Config.Debug for the full error.'):format(label))
        end
        return nil
    end
    return table.unpack(results, 2)
end

lib.callback.register('cipher-trucking:server:getCompany', function(src)
    return safeCall('getCompany', Company.GetSnapshot, src)
end)

lib.callback.register('cipher-trucking:server:foundCompany', function(src, name)
    return safeCall('foundCompany', Company.Found, src, name)
end)

lib.callback.register('cipher-trucking:server:companyInvite', function(src, targetSrc)
    return safeCall('companyInvite', Company.Invite, src, targetSrc)
end)

lib.callback.register('cipher-trucking:server:companyAcceptInvite', function(src)
    return safeCall('companyAcceptInvite', Company.AcceptInvite, src)
end)

lib.callback.register('cipher-trucking:server:companyKick', function(src, targetCid)
    return safeCall('companyKick', Company.Kick, src, targetCid)
end)

lib.callback.register('cipher-trucking:server:companySetGrade', function(src, targetCid, grade)
    return safeCall('companySetGrade', Company.SetGrade, src, targetCid, tonumber(grade))
end)

lib.callback.register('cipher-trucking:server:companyDeposit', function(src, amount)
    return safeCall('companyDeposit', Company.Deposit, src, amount)
end)

lib.callback.register('cipher-trucking:server:companyWithdraw', function(src, amount)
    return safeCall('companyWithdraw', Company.Withdraw, src, amount)
end)

lib.callback.register('cipher-trucking:server:companyGetLedger', function(src)
    return safeCall('companyGetLedger', function()
        local company = Company.GetBySource(src)
        if not company then return {} end
        return Company.GetLedger(company.id)
    end)
end)

lib.callback.register('cipher-trucking:server:companyBuyVehicle', function(src, shopId)
    return safeCall('companyBuyVehicle', Company.BuyVehicle, src, shopId)
end)

lib.callback.register('cipher-trucking:server:companyBuyPerk', function(src, perkId)
    return safeCall('companyBuyPerk', Company.BuyPerk, src, perkId)
end)

lib.callback.register('cipher-trucking:server:getCompanyLeaderboard', function(src)
    return safeCall('getCompanyLeaderboard', function()
        if not WaitForDB() then return {} end
        return MySQL.query.await(
            'SELECT label, reputation, bank FROM cipher_trucking_companies ORDER BY reputation DESC LIMIT ?',
            { Config.Trucking.Company.leaderboardLimit }) or {}
    end)
end)

lib.callback.register('cipher-trucking:server:disbandCompany', function(src)
    return safeCall('disbandCompany', Company.Disband, src)
end)

-- Cosmetic-only paint job — personal trucks pay from your own cash, company
-- trucks pay from the treasury and need manage_vehicles, same ownership
-- shape as repairVehicle/upgradeVehicle in server/main.lua.
lib.callback.register('cipher-trucking:server:paintVehicle', function(src, ownedId, primaryId, secondaryId)
    return safeCall('paintVehicle', function()
        local cid = Framework.GetCitizenId(src)
        if not cid then return false, 'No character loaded.' end

        local function validColor(id)
            for _, c in ipairs(Config.Trucking.PaintColors) do
                if c.id == id then return true end
            end
            return false
        end
        if not validColor(primaryId) or not validColor(secondaryId) then return false, 'Invalid color.' end

        local owned = MySQL.single.await('SELECT * FROM cipher_trucking_owned WHERE id = ?', { ownedId })
        if not owned then return false, 'Vehicle not found.' end
        if owned.kind ~= 'truck' then return false, 'Only trucks can be painted.' end

        local cost = SGet('economy.paintCost', Config.Trucking.paintCost)

        if owned.company_id then
            if not Company.HasPerm(src, 'manage_vehicles') then return false, 'No permission.' end
            local company = Company.GetBySource(src)
            if not company or company.id ~= owned.company_id then return false, "Not your company's vehicle." end
            if company.bank < cost then return false, ('Costs $%d — treasury too low.'):format(cost) end
            company.bank = company.bank - cost
            MySQL.update('UPDATE cipher_trucking_companies SET bank = bank - ? WHERE id = ?', { cost, company.id })
        else
            if owned.citizenid ~= cid then return false, 'You do not own that truck.' end
            if Framework.GetMoney(src, Config.Trucking.payoutAccount) < cost then
                return false, ('Costs $%d — not enough money.'):format(cost)
            end
            local ok = Framework.RemoveMoney(src, Config.Trucking.payoutAccount, cost, 'cipher-trucking:paintVehicle')
            if not ok then return false, 'Payment failed.' end
        end

        MySQL.update('UPDATE cipher_trucking_owned SET livery = ? WHERE id = ?',
            { json.encode({ primary = primaryId, secondary = secondaryId }), ownedId })

        Framework.Notify(src, 'Truck repainted.', 'success')
        return true
    end)
end)

-- Shared dispatch/collect callbacks — used for BOTH personal and company
-- trucks, since Company.Dispatch/Collect already branches on ownership.
lib.callback.register('cipher-trucking:server:dispatchVehicle', function(src, ownedId, contractId)
    return safeCall('dispatchVehicle', Company.Dispatch, src, ownedId, contractId)
end)

lib.callback.register('cipher-trucking:server:collectVehicle', function(src, ownedId)
    return safeCall('collectVehicle', Company.Collect, src, ownedId)
end)

AddEventHandler('playerDropped', function()
    pendingInvites[source] = nil
end)
