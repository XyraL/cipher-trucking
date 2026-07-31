# Cipher — Trucking (v1.5)

A civilian delivery-job resource for **QBox (qbx_core)** and **QBCore (qb-core)**.
Open the depot computer for a full dashboard — browse contracts (including
rotating bonus-payout ones), track your career and driver rating, check
personal and company leaderboards, buy/upgrade/paint trucks and trailers,
spend a company's perk points, and found or run (or disband) a trucking
company — then hitch a trailer, drive the rig to the delivery point(s), and
bring the truck back to the depot for cash + XP. Fully standalone — no
dependency on any other Cipher script.

## Requirements
- `ox_lib`
- `ox_target` (hard dependency in this version — no fallback)
- `oxmysql`
- Either `qbx_core` **or** `qb-core` — the bridge auto-detects which.
- A vehicle-keys resource if your server runs one (most do) — see
  `Config.Trucking.KeysResource` below. Without this, the spawned truck's
  engine won't start even though the vehicle itself isn't locked.

## Install
1. Drop the `cipher-trucking` folder into your `resources`.
2. **No SQL import needed.** Every table creates and migrates itself on first
   start (`server/db.lua`). Upgrading from an earlier version is the same
   process — drop the folder in and restart; any missing columns are added
   automatically. Watch the console for
   `[cipher-trucking] database ready — N tables verified`.
3. Add `ensure cipher-trucking` to your `server.cfg` (after ox_lib, ox_target,
   oxmysql, your framework, and your keys resource if you run one).
4. Set `Config.Trucking.KeysResource` to match your server's keys system
   (defaults to `'qbx'` for the standard QBox recipe's `qbx_vehiclekeys`).
5. Grant the admin ACE for the oversight panel (see Admin panel below), e.g.:
   ```
   add_ace group.admin cipher-trucking.admin allow
   add_principal identifier.fivem:1234 group.admin
   ```
6. Tune the rest of `config.lua` — see the callout below before you go live.

> **Updating an existing install:** always re-upload the **whole** folder, not
> just the files you think changed. A partial upload is the single most
> confusing failure mode there is — it surfaces as unrelated-looking errors
> elsewhere. The resource runs a self-check 2 seconds after boot and will
> name any server file that failed to load.

## ⚠️ Before going live
- Every `model` in `Config.Trucking.Shop` (trucks **and** trailers) is a
  **placeholder** — verify each one spawns correctly on your build before
  going live.
- The depot computer, truck spawn/return spots, trailer spawn spots, and all
  starter contract destinations (Docks / Airport / Movie Set / Vinewood) are
  confirmed ground-level and safe to use as-is. Add, remove, or edit entries
  in `Config.Trucking.Contracts` and `Config.Trucking.HotContracts.pool`
  freely — they're just a starting set.

## What's wired

### Dashboard (NUI)
`ox_target` on the depot computer opens a full custom dashboard, styled to
match the rest of the Cipher lineup:
- **Contracts** — every contract is shown, including ones you can't take yet
  (grayed out with the reason — rank or a missing specialized trailer)
  rather than hidden. Rotating **hot contracts** (bonus payout, see below)
  show with a red badge and a live countdown; multi-stop contracts show a
  stop-count chip. A cargo-type filter and payout/XP/rank sort sit above the
  board — both are pure client-side, no extra server round-trip when you
  change them.
- **Career** — rank/title, XP progress bar to the next rank, total
  deliveries, total cash earned, driver rating (see below), and an
  achievement badge grid (`Config.TruckingAchievements`) computed live from
  your stats.
- **Route Map** — a hand-drawn vector map of Los Santos (no image assets, so
  it scales cleanly and follows the theme). Contract pins with hover
  tooltips, a dashed route line from the depot with distance and ETA,
  scroll-zoom and drag-pan, and a live "you are here" marker. During a run it
  switches to tracking that job: solid route, delivered legs dimmed, next
  stop pulsing.
- **Active Delivery** — read-only status of your current contract (stage,
  stop progress on multi-stop routes, payout preview). Status mirror only —
  it doesn't drive the physical steps below.
- **Analytics** — earnings over the last `Config.Trucking.analyticsDays`
  days, a driver-rating trend line, distance and time driven, and your most
  profitable contracts. Charts are hand-built SVG; no charting library, so
  the resource keeps zero external dependencies.
- **Receipts** — a per-delivery history itemising exactly how each payout was
  reached: base, truck bonus, hot bonus, multi-stop bonus, rating modifier,
  spoilage, and the company split if one applied.
- **Leaderboard** — a Drivers/Companies toggle: top
  `Config.Trucking.leaderboardLimit` players by deliveries completed, or top
  `Config.Trucking.Company.leaderboardLimit` companies by reputation.
- **Garage** — buy/select/repair your own trucks *and* trailers, buy
  performance upgrades and cosmetic paint per truck, service worn components,
  and passively dispatch an idle truck to run a contract on its own.
- **Company** — found a company (or get invited into one) and manage ranks,
  treasury, roster, a company-owned fleet, and the perk tree.
- **Settings** — per-player display preferences stored locally: sound
  effects, boot animation, interface animations, metric/imperial units and
  which tab the terminal opens on.

### Fuel & maintenance
Optional (`Config.Trucking.Maintenance.enabled`), and expressed as 0-100
percentages so every gauge shares the scale of the existing condition bar.

- **Fuel** applies to every truck including the free depot one, which always
  starts full — a fuel gauge that only appears once you've bought something
  teaches the mechanic at the worst possible moment. Owned trucks keep
  whatever is left in the tank and refuel at the stations shown on the map.
  Burn scales with distance, rises while hauling a trailer, and idling costs
  something too.
- **Wear** (tyres, brakes, oil) applies to owned trucks only, following the
  same rule the existing condition system already used — the free truck is
  the safety net that always works. Worn tyres cut grip, worn brakes make
  collisions cost more condition, low oil slowly drains engine health.
  Service costs scale with how worn a part actually is.

### Admin ops console
`/truckingadmin` (ACE-gated) opens a six-tab staff panel: server overview and
top earners, player management (set level, grant XP, reset rating, give cash,
clear a stuck job), fleet administration, company oversight, a **Control** tab
exposing ~20 economy knobs that persist to the database and take effect
immediately — no config edit, no restart — and a recent-deliveries log.

Settings are an override layer: a value only exists in the database once an
admin changes it, so anything untouched keeps tracking `config.lua`, and
"Reset" genuinely hands control back to the file.

### Delivery loop, fully server-authoritative
1. **Hookup** — truck and trailer spawn at a least-recently-used slot from
   their 4-point pools (your selected truck/trailer models if you have them
   active, otherwise the free depot pair). Back the truck up to the trailer
   — compatible pairs (like `hauler` + `trailers2`) auto-hitch via the
   game's own physics, no interaction needed. The client just watches for
   that to happen and reports it; the server independently confirms the
   hitch actually took before letting you proceed.
2. **Enroute** — drive the rig to the contract's destination. Multi-stop
   contracts (`stops` array instead of a single `destination`) keep the
   trailer hitched and just move the target to the next stop after each
   delivery — it only despawns once every stop is done.
3. **Deliver** — a `[E] Deliver Cargo` prompt shows once you're at the
   destination *with the trailer actually in the zone* (not just the
   truck). The server independently re-checks both vehicles' real
   positions before accepting it. On the final stop, the trailer is
   deleted — cargo delivered, its job is done.
4. **Return** — only the truck drives back to any depot spot now (the
   trailer's already gone). A `[E] Return Truck` prompt shows once you're
   there; the server confirms the truck's real position, pays out, and
   despawns it.

Hookup uses the game's own auto-hitch detection; deliver/return use a
walk-up `[E]` prompt (`lib.showTextUI`) with a ground marker, not an
`ox_target` menu — the dashboard is the depot terminal, not a replacement
for actually driving.

### Driving HUD
A small corner widget (current stage, live distance to the next waypoint,
stop progress on multi-stop routes) visible while actually driving, whether
or not the full dashboard is open — it's a separate always-mounted overlay
that never captures mouse/keyboard focus (`pointer-events: none`), computed
entirely client-side from the same state already driving the map blip, no
extra server calls.

### Hot contracts
`Config.Trucking.HotContracts` rotates `activeCount` bonus-payout contracts
in from `pool` every `rotateMinutes`, computed lazily (checked whenever the
board is opened, not on a server timer) so the schedule survives restarts.
`payoutBonusPct` stacks with a truck's own bonus and the multi-stop bonus.

### Trailer variety
Trailers are functional, not cosmetic. The free depot trailer only covers
`cargoType = 'general'` contracts; refrigerated/construction contracts need
a matching owned+selected trailer from `Config.Trucking.Shop`, or they show
locked on the board even at the right rank. Refrigerated cargo also has a
`spoilTimeSeconds` soft time limit — deliver late and the payout is halved
rather than the contract failing outright.

### Truck & trailer ownership
- The free depot pair always works for general-cargo contracts — owning
  upgrades from the Garage is optional, never required.
- Each shop truck adds `payoutBonusPct` on top of a contract's base payout
  when it's your active selection.
- Owned vehicles take real damage: collisions during a delivery lower
  condition (`Config.Trucking.conditionLossRate`), tracked from actual
  in-game vehicle health, not a fake timer. A vehicle at 0% condition can't
  be selected/dispatched until repaired (`Config.Trucking.repairCostPerPoint`).
- Owned trucks/trailers are stored by this script alone
  (`cipher_trucking_owned`) — no dependency on qb-garage, ox-garage, or any
  other garage resource.

### Driver rating
A running average (0-100), separate from XP/level, tracking how clean your
driving is — tracked on **every** delivery regardless of which truck you're
using (unlike condition loss above, which is owned-truck only). Damage taken
on a trip costs rating points (`Config.Trucking.ratingDamageDivisor`); your
average going *into* a delivery (not that delivery's own result) grants a
small payout bonus at `ratingBonusThreshold` or a penalty at
`ratingPenaltyThreshold`.

### Performance upgrades
Bought per-truck from the Garage/Fleet card (not a separate shop catalog
entry) — engine, brakes, transmission, and suspension, each with several
levels (`Config.Trucking.PerformanceUpgrades`), cost scaling with the level
being bought. Applied via `SetVehicleMod` whenever that truck spawns.
Trailers never get these.

### Truck liveries
Cosmetic only, no gameplay effect. A curated paint palette
(`Config.Trucking.PaintColors`) applied via `SetVehicleColours` whenever
that truck spawns, bought per-truck from the same Garage/Fleet card as
performance upgrades for a flat `Config.Trucking.paintCost`. Trucks only.

### Passive / idle dispatch
An owned truck that isn't currently selected or in use can be **dispatched**
from the Garage (personal trucks) or Company Fleet tab (company trucks) to
autonomously run a contract for `Config.Trucking.Company.passiveDispatchMinutes`
of real time, paying `passiveDispatchPayoutPct` of the normal payout once
**collected** — less than driving it yourself, since nobody's actually doing
the work. Computed lazily from a stored ready-at timestamp, so it survives
restarts without a server timer. Capped at
`Config.Trucking.Company.maxConcurrentDispatches` per owner.

### Companies
Player-founded (pay `Config.Trucking.Company.foundingCost` at the depot to
become Owner) — unlike this codebase's gang system, which is admin-seeded,
a trucking company is meant to be started by players. Ranks/permissions,
a treasury with a transaction ledger, invite/kick/promote membership, and
tiered reputation all follow the same server-authoritative patterns as
everywhere else in this resource:
- Invite people by targeting them in-world (`ox_target`, "Invite to
  Company") — needs the `invite` permission, gated server-side.
- Any member can **drive** a company truck; buying, repairing, or
  dispatching one needs the `manage_vehicles` permission.
- Delivering with a company truck splits the payout between the driver and
  the company treasury (`Config.Trucking.Company.driverCutPct`, default
  30% driver / 70% company). Passive-dispatch payouts with no driver
  involved go 100% to whoever owns the truck.
- Company reputation (`Config.Trucking.Company.Levels`) grows from
  company-truck deliveries and collected dispatches, awarding `perkPoints`
  on every level threshold crossed.
- **Perk tree** (`Config.Trucking.Company.PerkTree`) — three branches
  (Fleet, Logistics, Treasury), each a chain of tiers where tier N requires
  tier N-1 in that same branch already owned (structurally identical to
  `cipher`'s gang perk tree). Spent from perk points, gated by the
  `manage_perks` permission. Fleet raises max concurrent dispatch slots;
  Logistics reduces dispatch time and boosts the driver cut on
  company-truck deliveries; Treasury adds a bonus on every deposit.
- **Achievements** (`Config.Trucking.Company.Achievements`) — computed live
  from the company's own stats (deliveries, reputation, treasury), same
  pattern as the personal achievement grid.
- **Disbanding** — the Owner can disband their own company from the
  Overview tab (two-step confirm, no modal). Company-owned trucks/trailers
  are returned to whoever originally bought them, not deleted; the
  founding cost and any treasury balance are **not** refunded — it's a
  genuine sink, not an escrow.

### Admin panel
A separate, red-accented overlay for staff oversight — lists every company
(owner, treasury, reputation, member count) with a "Force Disband" button,
for cases where an Owner is gone or abusive and the normal Owner-only
disband isn't available. Gated by `Config.Trucking.AdminAce`
(`cipher-trucking.admin` by default) checked server-side on every action —
opened with `/`+`Config.Trucking.AdminCommand` (`truckingadmin` by default).
Modeled directly on `cipher`'s own admin tablet (`isAdmin`/`guarded`
pattern), minus Discord logging — this resource has no Discord integration.

### Progression & payout
- Payout is **cash** (`Config.Trucking.payoutAccount`) plus personal XP
  toward `Config.TruckingLevels` (Rookie Hauler → Master Trucker), which
  gates which contracts you can accept.
- One active delivery per player at a time (in-memory, no cooldown table —
  queue the next contract immediately after finishing one).
- Truck/trailer are always deleted on job completion, cancellation, or
  disconnect — nothing clutters the depot over time.

## Deferred to future updates
- Fuel realism (damage/condition tracking exists; fuel does not)
- Hijacking/ambush risk en route
- Convoy/co-op contracts (multiple *players* driving one job together —
  different from the company system's multiple *owned trucks*)

## Architecture note
The client only spawns visuals and reports interaction attempts; the server
owns all job/company state and re-validates positions, ownership, and
permissions (resolved server-side, never trusting client-claimed state)
before advancing any stage, paying out, or touching a treasury. The NUI
dashboard is a thin client-side layer on top of the same server callbacks —
nothing NUI-specific lives server-side. The company system
(`server/company.lua`) is a direct structural port of this codebase's `cipher`
gang system (ranks/permissions/treasury/reputation), renamed to fit trucking.
