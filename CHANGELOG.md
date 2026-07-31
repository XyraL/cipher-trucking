# Changelog

All notable changes to **Cipher — Trucking**.

## [2.0.1] — 2026-07-31

### Fixed
- **Tabs took seconds to load, or only loaded after clicking twice.** FiveM
  does not dispatch the next NUI callback while the current handler is still
  yielding, and nearly every handler here yields on a server round-trip. With
  the dashboard opening four requests at once, they ran strictly one after
  another instead of overlapping.

  The give-away was `getMapMeta` timing out — a handler that only reads config
  and returns, with nothing async in it. A synchronous handler can only take
  twelve seconds if it was never dispatched until then. Each handler now runs
  in its own thread so the registration returns immediately and the requests
  overlap.

## [2.0.0] — 2026-07-31

First public release.

### Core
- Civilian delivery-job resource for **QBox** or **QBCore** — the framework
  bridge auto-detects which you run.
- **Self-provisioning database.** All nine tables create and migrate
  themselves on first start; there is no SQL file to import and no upgrade
  step. Column migrations use `SHOW COLUMNS` rather than
  `INFORMATION_SCHEMA`, which silently returns nothing without schema
  privileges and would skip the migration while appearing to succeed.
- Fully server-authoritative delivery loop — vehicle positions are resolved
  and checked server-side, never trusted from the client.

### Dashboard
Ten tabs: Contracts, Route Map, Active Delivery, Career, Analytics, Receipts,
Leaderboard, Garage, Company and Settings.

- **Route Map** — hand-authored vector map of Los Santos with contract pins,
  route lines, distance and ETA, zoom and pan, and live tracking of the run
  in progress. No image assets and no mapping library.
- **Analytics** — earnings history, driver-rating trend, distance and time
  driven, most profitable contracts. Charts are hand-built SVG.
- **Receipts** — itemised per-delivery payout breakdown showing every
  modifier that was applied.
- **Settings** — per-player sound, animation, units and opening-tab
  preferences.
- Boot sequence, synthesised WebAudio interface sounds (no audio files), and
  a driving HUD with a fuel gauge.

### Gameplay
- Rotating hot contracts, multi-stop routes, specialised trailer cargo types
  with a soft spoilage penalty on refrigerated loads.
- Truck and trailer ownership with condition, repair, performance upgrades
  and paint.
- **Fuel and maintenance** — fuel burn scaled by distance, load and idling,
  refuel stations on the map, and tyre/brake/oil wear with servicing. Wear
  applies to owned trucks only; the free depot truck stays friction-free.
- Driver rating from damage taken, feeding a payout bonus or penalty.
- Companies — founding, ranks and permissions, treasury with a ledger, a
  reputation tier ladder, a perk tree and a shared fleet.
- Passive dispatch: send an idle truck to run a contract on its own.

### Admin
- Six-tab ops console behind an ACE permission (`/truckingadmin`).
- Live economy tuning — around 20 knobs persisted to the database, applied
  immediately, layered as overrides so untouched values keep tracking
  `config.lua`.

### Fixed before release
- **Tabs could hang on "Loading..." forever.** A Lua error inside any
  `lib.callback.register` handler meant the callback never responded, so the
  client's `lib.callback.await` never returned and the NUI `fetch` never
  settled. `server/company.lua` had a local guard for its own callbacks; the
  other 21 had none. The registrar is now patched centrally so every callback
  always responds, `nui()` has a request timeout, and a failed tab render
  shows a retry button instead of a stranded placeholder.
- A cross-tab JavaScript binding collision meant clicking a Leaderboard
  sub-tab could hijack the Company tab.
- No HTML escaping anywhere in the dashboard, despite company names being
  free text typed by players.
- Founding a company raced its own database writes and could leave the
  founder with no rank and no permissions.
- `mule3` was listed as a shop truck — a box truck with no fifth wheel, so it
  could never hitch a trailer and dead-ended the job.
- The hitch watcher retried a rejecting server call every 500ms, producing an
  endless stream of error notifications.
- Depot return required the exact spawn bay rather than any of the four.
- Driver stats were missing `rating_sum` on first creation.
