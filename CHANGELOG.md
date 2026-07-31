# Changelog

All notable changes to **Cipher — Trucking**.

## [2.1.1] — 2026-07-31

### Removed
- The temporary diagnostics added in 2.0.2 and 2.0.3 (`/truckingdiag`,
  `/truckingtrace`, `client/diag.lua`, the `diagPing` callback and the
  page-side request tracing). They existed to locate the loading bug fixed in
  2.1.0 and have no reason to ship now that it's found.

The NUI wrapper they helped identify stays, and now carries both guarantees in
one place: every handler runs in its own thread, and a nil payload is sent as
`false` so a response is never dropped.

## [2.1.0] — 2026-07-31

### Fixed
- **Tabs stuck on "Loading..." — the actual root cause.** `cb(nil)` sends no
  response body, so the page's fetch never settles: not resolved, not
  rejected, pending forever. `getActiveJob` returns nil whenever you have no
  delivery running — which is most of the time — and both the Contracts and
  Route Map tabs await it alongside their own data via `Promise.all`, which
  never resolves if one member never settles. `getCareer` and `getAnalytics`
  could do the same.

  Every NUI response now substitutes `false` for a nil payload. It encodes to
  JSON, and every consumer already tests these results for truthiness, so
  "no data" still reads as "no data".

## [2.0.4] — 2026-07-31

### Fixed
- **"did not respond within 12000ms" was logged for requests that had already
  succeeded.** The timeout added in 2.0.0 raced a `setTimeout` against the
  request, but `Promise.race` does not cancel the loser — so the timer kept
  running and fired its warning twelve seconds later regardless of the
  outcome. Every healthy call produced one, arriving as a burst per tab
  render and naming exactly the endpoints that tab had used, which read as a
  loading fault that was not there. The timer is now cleared when the race
  settles. A genuinely unanswered request still warns, once.

## [2.0.3] — 2026-07-31

### Added
- `/truckingtrace` — logs both ends of every NUI request
  (`page SENT -> client IN -> client OUT -> page GOT`) so a dropped request
  can be traced to the hop that lost it.
- The page-side fetch `.catch()` now logs instead of silently returning null.
  A fetch that rejects is a different fault from one that never settles.

## [2.0.2] — 2026-07-31

### Added
- **`/truckingdiag`** — walks the whole request chain and prints where it
  breaks: which NUI callbacks registered, whether the dispatch patch
  installed, a timed server round-trip that touches no database, the server's
  database state, and a timed real query for comparison. Run it and paste the
  output when reporting a loading problem.
- A startup warning that fires if **no** NUI callbacks registered, which means
  a client file failed to load and every dashboard request will time out. That
  condition previously produced no message at all — only the symptom.

### Fixed
- The NUI dispatch patch now checks that `RegisterNUICallback` exists before
  wrapping it. Capturing it too early would have left every later registration
  throwing, and the dashboard with no handlers at all — a worse failure than
  the one being fixed.

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
