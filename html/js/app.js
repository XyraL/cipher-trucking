const RES = 'cipher-trucking';
const $ = (s) => document.querySelector(s);
const $$ = (s) => document.querySelectorAll(s);

// Every string that reaches innerHTML has to go through this. Company names
// are free text a player types (server/company.lua only length-checks them),
// and character names come from charinfo — both would otherwise execute as
// markup inside EVERY other player's dashboard. Config-sourced labels get
// the same treatment so there's one rule instead of a judgement call per
// field.
function esc(v) {
    if (v == null) return '';
    return String(v)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

const state = {
    activeTab: 'contracts', companySubtab: 'overview', leaderboardView: 'drivers',
    contractFilter: 'all', contractSort: 'payout',
    // Map tab
    mapMeta: null, mapSelected: null, mapPlayer: null, mapContracts: [],
    booted: false,
};

// ── Preferences ──────────────────────────────────────────────
// Stored client-side in localStorage rather than on the player's character.
// These are display choices tied to the machine and the person sitting at
// it, not to a citizenid — someone who wants the sound off wants it off on
// every character. Wrapped in try/catch because some CEF configurations
// disable localStorage entirely, in which case the defaults simply apply
// for the session.
const PREF_KEY = 'cipherTrucking.prefs';

const DEFAULT_PREFS = {
    sfx: true,
    boot: true,
    units: 'metric',   // 'metric' | 'imperial'
    motion: true,      // false = reduced motion
    defaultTab: 'contracts',
};

let prefs = { ...DEFAULT_PREFS };

function loadPrefs() {
    try {
        const raw = window.localStorage.getItem(PREF_KEY);
        if (raw) prefs = { ...DEFAULT_PREFS, ...JSON.parse(raw) };
    } catch (e) {
        prefs = { ...DEFAULT_PREFS };
    }
    applyPrefs();
}

function savePrefs() {
    try {
        window.localStorage.setItem(PREF_KEY, JSON.stringify(prefs));
    } catch (e) { /* non-persistent session; the in-memory value still applies */ }
    applyPrefs();
}

function applyPrefs() {
    SFX.setMuted(!prefs.sfx);
    document.body.classList.toggle('reduced-motion', !prefs.motion);
}

// ── Sound ────────────────────────────────────────────────────
// Synthesised through WebAudio rather than shipped as audio files — the same
// approach as cipher-drugs' mixing bench. Keeps the resource asset-free and
// sidesteps FiveM's NUI audio-file quirks entirely.
const SFX = (() => {
    let ctx = null;
    let muted = false;

    function ac() {
        if (!ctx) {
            const Ctor = window.AudioContext || window.webkitAudioContext;
            if (!Ctor) return null;
            ctx = new Ctor();
        }
        // CEF can hand back a suspended context when the page loads without
        // a user gesture; resuming on first use is enough to unblock it.
        if (ctx.state === 'suspended') ctx.resume().catch(() => {});
        return ctx;
    }

    function tone(freq, dur, type = 'sine', gain = 0.05, delay = 0) {
        if (muted) return;
        const a = ac();
        if (!a) return;
        const t0 = a.currentTime + delay;
        const osc = a.createOscillator();
        const g = a.createGain();
        osc.type = type;
        osc.frequency.setValueAtTime(freq, t0);
        g.gain.setValueAtTime(0, t0);
        g.gain.linearRampToValueAtTime(gain, t0 + 0.012);
        g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
        osc.connect(g).connect(a.destination);
        osc.start(t0);
        osc.stop(t0 + dur + 0.02);
    }

    return {
        setMuted: (v) => { muted = !!v; },
        isMuted: () => muted,
        hover:   () => tone(880, 0.05, 'sine', 0.014),
        click:   () => tone(520, 0.07, 'triangle', 0.035),
        tab:     () => { tone(440, 0.08, 'triangle', 0.03); tone(660, 0.09, 'sine', 0.02, 0.04); },
        success: () => { tone(523, 0.1, 'sine', 0.04); tone(784, 0.16, 'sine', 0.035, 0.08); },
        error:   () => { tone(200, 0.16, 'sawtooth', 0.03); tone(150, 0.2, 'sawtooth', 0.025, 0.06); },
        open:    () => { tone(300, 0.12, 'sine', 0.03); tone(600, 0.18, 'sine', 0.025, 0.07); },
        boot:    (i) => tone(420 + i * 60, 0.05, 'square', 0.012),
    };
})();

// Second line of defence behind the server-side callback guard in db.lua.
// A fetch to a FiveM NUI endpoint that never gets a response will pend
// forever — there is no built-in timeout — and every caller here does
// `await nui(...)` before rendering, so one lost response leaves a panel
// showing "Loading..." for the rest of the session.
//
// Resolving null on timeout means the caller takes its normal "no data" path
// and the player sees an empty state they can retry, instead of a dead tab.
const NUI_TIMEOUT_MS = 12000;

function nui(endpoint, data = {}) {
    const request = fetch(`https://${RES}/${endpoint}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data),
    })
        .then((r) => r.json())
        .catch((err) => {
            // Logged rather than swallowed: a fetch that rejects is a
            // different fault from one that never settles, and a silent catch
            // hides that distinction.
            console.warn(`[cipher-trucking] '${endpoint}' failed:`, err);
            return null;
        });

    // The timer MUST be cleared when the request wins the race.
    // Promise.race resolves with the first settled promise but does not cancel
    // the other one, so an uncleared timer keeps running and fires its warning
    // twelve seconds later even though the request already succeeded. That
    // logged a "did not respond" line for every healthy call — one burst per
    // tab render, naming exactly the endpoints that tab had used — which read
    // as a loading fault that was never actually there.
    let timer;
    const timeout = new Promise((resolve) => {
        timer = setTimeout(() => {
            console.warn(`[cipher-trucking] '${endpoint}' did not respond within ${NUI_TIMEOUT_MS}ms`);
            resolve(null);
        }, NUI_TIMEOUT_MS);
    });

    return Promise.race([request, timeout]).finally(() => clearTimeout(timer));
}

function toast(message, type = 'info') {
    const stack = $('#toast-stack');
    const el = document.createElement('div');
    el.className = `toast ${type}`;
    el.textContent = message;
    stack.appendChild(el);
    if (type === 'success') SFX.success();
    else if (type === 'error') SFX.error();
    setTimeout(() => el.classList.add('toast-out'), 2400);
    setTimeout(() => el.remove(), 2700);
}

// Drop-in replacement for "Loading..." — same footprint, but reads as the
// panel assembling itself rather than as a stall.
function skeleton(rows = 3) {
    return `<div class="skeleton-wrap">${
        Array.from({ length: rows }, (_, i) =>
            `<div class="skeleton-row" style="animation-delay:${i * 90}ms"></div>`).join('')
    }</div>`;
}

function formatDistance(metres) {
    const m = Number(metres) || 0;
    if (prefs.units === 'imperial') {
        const feet = m * 3.28084;
        if (feet < 1000) return `${Math.round(feet)} ft`;
        return `${(m / 1609.344).toFixed(1)} mi`;
    }
    if (m < 1000) return `${Math.round(m)} m`;
    return `${(m / 1000).toFixed(1)} km`;
}

function formatDuration(seconds) {
    const s = Math.max(0, Math.floor(Number(seconds) || 0));
    if (s < 60) return `${s}s`;
    const m = Math.floor(s / 60);
    if (m < 60) return `${m}m ${s % 60}s`;
    return `${Math.floor(m / 60)}h ${m % 60}m`;
}

function formatDate(unixSeconds) {
    if (!unixSeconds) return '';
    const d = new Date(Number(unixSeconds) * 1000);
    return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
        + ' ' + d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
}

function formatCountdown(seconds) {
    if (seconds == null) return '';
    const total = Math.max(0, Math.floor(seconds));
    const m = Math.floor(total / 60);
    const s = total % 60;
    return `${m}m ${s}s`;
}

// The server sends "seconds remaining" as a snapshot. Anchoring it to a wall
// clock at render time is what lets it actually count down instead of
// freezing at whatever it was when the panel opened.
function expiryStamp(seconds) {
    return seconds == null ? '' : String(Date.now() + seconds * 1000);
}

// One interval for the whole document, started once. Every element carrying
// a data-expires attribute updates from it, so nothing has to register or
// clean up its own timer when a panel re-renders.
setInterval(() => {
    document.querySelectorAll('[data-expires]').forEach((el) => {
        const remaining = (Number(el.dataset.expires) - Date.now()) / 1000;
        if (remaining <= 0) {
            el.textContent = 'expired';
            el.classList.add('expired');
            return;
        }
        el.textContent = formatCountdown(remaining);
    });
}, 1000);

function conditionClass(cond) {
    if (cond >= 70) return 'condition-high';
    if (cond >= 35) return 'condition-mid';
    return 'condition-low';
}

// ── Boot sequence ────────────────────────────────────────────
// Plays once per session, not on every open — it's brand flavour, and
// forcing a two-second wait every time the player checks the board would
// stop being charming almost immediately.
const BOOT_LINES = [
    'CIPHER LOGISTICS TERMINAL',
    'establishing depot uplink ................ OK',
    'authenticating driver credentials ........ OK',
    'syncing contract manifest ................ OK',
    'loading route cartography ................ OK',
    'fleet telemetry online',
];

function runBootSequence() {
    return new Promise((resolve) => {
        const overlay = $('#boot-overlay');
        const lines = $('#boot-lines');
        const fill = $('#boot-bar-fill');

        overlay.classList.remove('done');
        lines.innerHTML = '';
        fill.style.width = '0%';

        let i = 0;
        const step = () => {
            if (i >= BOOT_LINES.length) {
                fill.style.width = '100%';
                setTimeout(() => {
                    overlay.classList.add('done');
                    // Matches the CSS fade-out so the panel underneath isn't
                    // revealed mid-transition.
                    setTimeout(resolve, 320);
                }, 220);
                return;
            }

            const el = document.createElement('div');
            el.className = 'boot-line';
            el.textContent = BOOT_LINES[i];
            lines.appendChild(el);
            SFX.boot(i);

            i += 1;
            fill.style.width = `${(i / BOOT_LINES.length) * 100}%`;
            setTimeout(step, i === 1 ? 260 : 130);
        };

        step();
    });
}

// ── Open / close ─────────────────────────────────────────────
async function openUI() {
    $('#app-overlay').classList.remove('hidden');
    SFX.open();

    if (!state.booted && prefs.boot) {
        state.booted = true;
        await runBootSequence();
    } else {
        state.booted = true;
        $('#boot-overlay').classList.add('done');
    }

    // First open of a session lands on the player's preferred tab; after
    // that, reopening returns you to wherever you left off.
    if (!state.landed) {
        state.landed = true;
        state.activeTab = prefs.defaultTab || 'contracts';
    }

    switchTab(state.activeTab);
    refreshDriverCard();
}

function closeUI() {
    nui('close');
    $('#app-overlay').classList.add('hidden');
}

// The ops console lives in js/admin.js, which loads after this file — hence
// the lazy lookups below rather than a direct reference at parse time.

// Push-only from Lua, no NUI callback round-trip — independent of
// SetNuiFocus/#app-overlay, so it renders whether or not the dashboard
// itself is open.
function renderHud(data) {
    const hud = $('#hud-overlay');
    if (!data) { hud.classList.add('hidden'); return; }

    hud.classList.remove('hidden');
    $('#hud-label').textContent = data.label || ''; // textContent, no escaping needed

    // Absent entirely when maintenance is off — a permanently-full gauge
    // would imply a system that isn't running.
    const fuelBox = $('#hud-fuel');
    if (data.fuel == null) {
        fuelBox.classList.add('hidden');
    } else {
        fuelBox.classList.remove('hidden');
        const pct = Math.max(0, Math.min(100, data.fuel));
        $('#hud-fuel-fill').style.width = `${pct}%`;
        $('#hud-fuel-fill').className = pct <= 10 ? 'critical' : (data.fuelLow ? 'low' : '');
        $('#hud-fuel-pct').textContent = `${Math.round(pct)}%`;
        fuelBox.classList.toggle('warning', !!data.fuelLow);
    }
    $('#hud-distance').textContent = `${data.distance.toFixed(0)}m`;
    $('#hud-stops').textContent = data.stopCount > 1 ? `Stop ${data.stopIndex} of ${data.stopCount}` : '';
}

window.addEventListener('message', (ev) => {
    const { action, data } = ev.data || {};
    if (action === 'open') openUI();
    else if (action === 'close') closeUI();
    else if (action === 'openAdmin') AdminConsole.open();
    else if (action === 'hud') renderHud(data);
    else if (action === 'mapTick') {
        state.mapPlayer = data;
        // Only the player layer is repainted, and only while the map is the
        // visible tab — this fires twice a second.
        if (state.activeTab === 'map') {
            const root = $('#map-root');
            if (root) CipherMap.updatePlayerOnly(root, data);
        }
    }
});

document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    // Admin console sits on top, so it closes first if both are open.
    if (AdminConsole.isOpen()) { AdminConsole.close(); return; }
    if (!$('#app-overlay').classList.contains('hidden')) closeUI();
});

// ── Tab routing ──────────────────────────────────────────────
const TAB_RENDERERS = {
    contracts:   () => renderContracts(),
    map:         () => renderMap(),
    career:      () => renderCareer(),
    active:      () => renderActive(),
    analytics:   () => renderAnalytics(),
    receipts:    () => renderReceipts(),
    leaderboard: () => renderLeaderboard(),
    garage:      () => renderGarage(),
    company:     () => renderCompany(),
    settings:    () => renderSettings(),
};

function switchTab(tab) {
    state.activeTab = tab;
    $$('.nav-item').forEach((i) => i.classList.toggle('active', i.dataset.tab === tab));
    $$('.tab-panel').forEach((p) => p.classList.toggle('active', p.id === `tab-${tab}`));

    const render = TAB_RENDERERS[tab];
    if (!render) return;

    // Every renderer paints a "Loading..." placeholder, then awaits, then
    // fills it in. If anything throws in between, that placeholder is what
    // the player is left looking at — and because these are async functions
    // called without await, the rejection is silent. Catching here turns any
    // such failure into a visible, retryable error state instead of a tab
    // that just never finishes.
    try {
        const result = render();
        if (result && typeof result.catch === 'function') {
            result.catch((err) => showTabError(tab, err));
        }
    } catch (err) {
        showTabError(tab, err);
    }
}

function showTabError(tab, err) {
    console.error(`[cipher-trucking] '${tab}' tab failed to render:`, err);

    const panel = $(`#tab-${tab}`);
    if (!panel) return;

    panel.innerHTML = `
        <div class="panel-header">
            <div class="panel-title">Something went wrong</div>
            <div class="panel-subtitle">This tab could not be loaded</div>
        </div>
        <div class="empty-state">
            <div style="margin-bottom:14px">The depot terminal hit an error loading this tab.</div>
            <button class="btn btn-accent" data-retry-tab="${esc(tab)}">Retry</button>
        </div>`;

    const btn = panel.querySelector('[data-retry-tab]');
    if (btn) btn.onclick = () => switchTab(tab);
}

// ── Settings ─────────────────────────────────────────────────
// Purely client-side display preferences (see loadPrefs). Nothing here
// touches gameplay or the server — economy tuning lives in the admin Control
// tab, which is a different thing for a different audience.
function renderSettings() {
    const panel = $('#tab-settings');

    const toggle = (key, label, help) => `
        <div class="pref-row">
            <div class="pref-info">
                <div class="pref-label">${esc(label)}</div>
                <div class="pref-help">${esc(help)}</div>
            </div>
            <button class="pref-toggle ${prefs[key] ? 'on' : ''}" data-pref="${key}">
                ${prefs[key] ? 'ON' : 'OFF'}
            </button>
        </div>`;

    const tabOptions = [
        ['contracts', 'Contracts'], ['map', 'Route Map'], ['active', 'Active Delivery'],
        ['career', 'Career'], ['analytics', 'Analytics'], ['garage', 'Garage'],
    ].map(([v, l]) => `<option value="${v}" ${prefs.defaultTab === v ? 'selected' : ''}>${l}</option>`).join('');

    panel.innerHTML = `
        <div class="panel-header">
            <div class="panel-title">Settings</div>
            <div class="panel-subtitle">Your terminal preferences — saved on this machine</div>
        </div>

        <div class="section-heading">Interface</div>
        ${toggle('sfx', 'Sound effects', 'Clicks, confirmations and alerts while using the terminal.')}
        ${toggle('boot', 'Boot sequence', 'Play the startup animation the first time you open the terminal each session.')}
        ${toggle('motion', 'Animations', 'Turn off to reduce movement across the whole interface.')}

        <div class="section-heading">Display</div>
        <div class="pref-row">
            <div class="pref-info">
                <div class="pref-label">Units</div>
                <div class="pref-help">How distances are shown on the map, contracts and receipts.</div>
            </div>
            <select class="input pref-select" id="pref-units" style="width:auto">
                <option value="metric" ${prefs.units === 'metric' ? 'selected' : ''}>Metric (km)</option>
                <option value="imperial" ${prefs.units === 'imperial' ? 'selected' : ''}>Imperial (mi)</option>
            </select>
        </div>
        <div class="pref-row">
            <div class="pref-info">
                <div class="pref-label">Opening tab</div>
                <div class="pref-help">Which tab the terminal lands on when you open it.</div>
            </div>
            <select class="input pref-select" id="pref-tab" style="width:auto">${tabOptions}</select>
        </div>

        <div class="section-heading">Reset</div>
        <div class="pref-row">
            <div class="pref-info">
                <div class="pref-label">Restore defaults</div>
                <div class="pref-help">Puts every preference on this page back to how it shipped.</div>
            </div>
            <button class="btn btn-danger" id="pref-reset">Restore Defaults</button>
        </div>`;

    panel.querySelectorAll('.pref-toggle').forEach((btn) => {
        btn.onclick = () => {
            prefs[btn.dataset.pref] = !prefs[btn.dataset.pref];
            savePrefs();
            SFX.click();
            renderSettings();
        };
    });

    $('#pref-units').onchange = (e) => {
        prefs.units = e.target.value;
        savePrefs();
        toast('Units updated.', 'success');
    };
    $('#pref-tab').onchange = (e) => {
        prefs.defaultTab = e.target.value;
        savePrefs();
    };
    $('#pref-reset').onclick = () => {
        prefs = { ...DEFAULT_PREFS };
        savePrefs();
        toast('Preferences restored.', 'success');
        renderSettings();
    };
}

async function refreshDriverCard() {
    const career = await nui('getCareer');
    if (!career) return;
    $('#driver-title').textContent = career.title || 'Rookie Hauler'; // textContent, no escaping needed
    $('#driver-sub').textContent = `Lvl ${career.level} · $${(career.totalEarned || 0).toLocaleString()} earned`;

    // Max rank reports no nextLevelXp — show the bar full rather than empty,
    // which would otherwise read as "no progress" at the top of the ladder.
    const pct = career.nextLevelXp
        ? Math.min(100, Math.round((career.xp / career.nextLevelXp) * 100))
        : 100;
    $('#driver-xp-fill').style.width = `${pct}%`;
}

// ── Contracts ────────────────────────────────────────────────
let allContracts = [];

const SORT_FNS = {
    payout: (a, b) => b.payout - a.payout,
    xp: (a, b) => b.xp - a.xp,
    rank: (a, b) => a.minLevel - b.minLevel,
};

async function renderContracts() {
    const panel = $('#tab-contracts');
    panel.innerHTML = `
        <div class="panel-header">
            <div class="panel-title">Delivery Contracts</div>
            <div class="panel-subtitle">Accept a contract to start a delivery</div>
        </div>
        <div class="form-row" style="margin-bottom:16px;max-width:420px">
            <div class="field">
                <label class="field-label">Cargo</label>
                <select class="input" id="contract-filter-cargo"></select>
            </div>
            <div class="field">
                <label class="field-label">Sort By</label>
                <select class="input" id="contract-sort">
                    <option value="payout">Payout</option>
                    <option value="xp">XP</option>
                    <option value="rank">Rank Required</option>
                </select>
            </div>
        </div>
        <div class="card-grid" id="contracts-grid"><div class="empty-state">Loading contracts...</div></div>`;

    // Active job comes along so the accept guard below is deciding on
    // current state rather than whatever the Map tab last cached.
    const [list, job] = await Promise.all([nui('getContracts'), nui('getActiveJob')]);
    allContracts = list || [];
    state.activeJob = job || null;

    // Filtered before use: a contract with no cargoType would otherwise reach
    // t.charAt() as undefined and throw, which aborts the rest of this
    // function — including renderContractsGrid() below — and strands the
    // "Loading contracts..." placeholder permanently.
    const cargoTypes = ['all', ...new Set(
        allContracts.map((c) => c.cargoType).filter((t) => typeof t === 'string' && t.length > 0)
    )];
    $('#contract-filter-cargo').innerHTML = cargoTypes.map((t) =>
        `<option value="${esc(t)}">${t === 'all' ? 'All Cargo' : esc(t.charAt(0).toUpperCase() + t.slice(1))}</option>`).join('');
    $('#contract-filter-cargo').value = state.contractFilter;
    $('#contract-sort').value = state.contractSort;

    $('#contract-filter-cargo').onchange = (e) => { state.contractFilter = e.target.value; renderContractsGrid(); };
    $('#contract-sort').onchange = (e) => { state.contractSort = e.target.value; renderContractsGrid(); };

    renderContractsGrid();
}

// Filters/sorts the already-fetched `allContracts` client-side — no server
// round-trip, so changing a dropdown re-renders instantly.
function renderContractsGrid() {
    const grid = $('#contracts-grid');
    if (allContracts.length === 0) {
        grid.innerHTML = '<div class="empty-state">No contracts configured.</div>';
        return;
    }

    const filtered = allContracts
        .filter((c) => state.contractFilter === 'all' || c.cargoType === state.contractFilter)
        .sort(SORT_FNS[state.contractSort] || SORT_FNS.payout);

    if (filtered.length === 0) {
        grid.innerHTML = '<div class="empty-state">No contracts match that filter.</div>';
        return;
    }

    grid.innerHTML = filtered.map((c) => {
        const badges = [];
        if (c.hot) badges.push(`<span class="chip hot">Hot &middot; <span data-expires="${expiryStamp(c.expiresInSeconds)}">${formatCountdown(c.expiresInSeconds)}</span></span>`);
        if (c.stopCount > 1) badges.push(`<span class="chip stops">${c.stopCount} stops</span>`);

        let lockReason = 'Locked';
        if (!c.levelOk) lockReason = `Locked — Rank ${c.minLevel} required`;
        else if (!c.trailerOk) lockReason = `Requires a ${esc(c.requiredTrailerType)} trailer`;

        return `
        <div class="card ${c.unlocked ? '' : 'locked'} ${c.hot ? 'hot' : ''}">
            ${badges.length ? `<div class="card-badges">${badges.join('')}</div>` : ''}
            <div class="card-title">${esc(c.label)}</div>
            <div class="card-meta">Cargo: ${esc(c.cargoType)} &middot; Min Rank ${c.minLevel}</div>
            <div class="card-row">
                <span class="card-stat money">$${c.payout}</span>
                <span class="card-stat xp">+${c.xp} XP</span>
            </div>
            <div class="card-row">
                ${state.activeJob
                    ? '<button class="btn btn-block" disabled>Delivery in progress</button>'
                    : c.unlocked
                        ? `<button class="btn btn-accent btn-block accept-btn" data-id="${c.id}">Accept Contract</button>`
                        : `<button class="btn btn-block" disabled>${lockReason}</button>`}
            </div>
        </div>`;
    }).join('');

    $$('.accept-btn').forEach((btn) => {
        btn.onclick = async () => {
            if (state.activeJob) {
                toast('Finish your current delivery first.', 'error');
                return;
            }
            btn.disabled = true;
            btn.textContent = 'Accepting...';
            const res = await nui('acceptContract', { contractId: btn.dataset.id });
            if (res && res.ok) {
                toast('Contract accepted — head to the depot.', 'success');
                closeUI();
            } else {
                toast((res && res.message) || 'Could not accept contract.', 'error');
                btn.disabled = false;
                btn.textContent = 'Accept Contract';
            }
        };
    });
}

// ── Route Map ────────────────────────────────────────────────
// Reads the same getContracts payload the Contracts tab does, so the pins
// and the cards can never disagree about what's on the board.
async function renderMap() {
    const panel = $('#tab-map');
    panel.innerHTML = `
        <div class="panel-header">
            <div class="panel-title">Route Map</div>
            <div class="panel-subtitle">Plan a run — select a contract to plot its route from the depot</div>
        </div>
        <div id="map-layout">
            <div id="map-root">${CipherMap.baseMarkup()}</div>
            <aside id="map-side">${skeleton(4)}</aside>
        </div>`;

    // The map meta (depot, spawn bays) is static config — fetched once per
    // session and cached on state rather than re-requested per tab visit.
    const [contracts, meta, job] = await Promise.all([
        nui('getContracts'),
        state.mapMeta ? Promise.resolve(state.mapMeta) : nui('getMapMeta'),
        nui('getActiveJob'),
    ]);

    state.mapMeta = meta || state.mapMeta;
    state.mapContracts = contracts || [];
    state.activeJob = job || null;

    // Default the selection to the best-paying contract the player can
    // actually run, so the map opens with a useful route already drawn.
    if (!state.mapSelected || !state.mapContracts.some((c) => c.id === state.mapSelected)) {
        const best = state.mapContracts
            .filter((c) => c.unlocked)
            .sort((a, b) => b.payout - a.payout)[0];
        state.mapSelected = best ? best.id : (state.mapContracts[0] && state.mapContracts[0].id) || null;
    }

    paintMap();
}

function paintMap() {
    const root = $('#map-root');
    if (!root) return;

    CipherMap.update(root, {
        contracts: state.mapContracts,
        selectedId: state.mapSelected,
        depot: state.mapMeta && state.mapMeta.depot,
        player: state.mapPlayer,
        activeJob: state.activeJob,
        stations: state.mapMeta && state.mapMeta.stations,
        onSelect: (id) => {
            state.mapSelected = id;
            SFX.click();
            paintMap();
        },
    });

    renderMapSidebar();
}

function renderMapSidebar() {
    const side = $('#map-side');
    if (!side) return;

    const list = state.mapContracts.map((c) => {
        const cls = [
            'map-list-item',
            c.id === state.mapSelected ? 'active' : '',
            c.unlocked ? '' : 'locked',
            c.hot ? 'hot' : '',
        ].filter(Boolean).join(' ');

        return `
        <div class="${cls}" data-id="${esc(c.id)}">
            <div class="map-list-top">
                <span class="map-list-label">${esc(c.label)}</span>
                ${c.hot ? '<span class="chip hot sm">HOT</span>' : ''}
            </div>
            <div class="map-list-meta">
                <span>$${Number(c.payout).toLocaleString()}</span>
                <span>${formatDistance(c.distance)}</span>
                <span>${c.stopCount > 1 ? `${c.stopCount} stops` : '1 stop'}</span>
            </div>
        </div>`;
    }).join('');

    const sel = state.mapContracts.find((c) => c.id === state.mapSelected);
    const job = state.activeJob;

    // An in-progress run takes the top slot — while you're mid-delivery,
    // where you're going next matters more than what you might take on next.
    const activeBlock = job ? `
        <div class="map-side-block active-run">
            <div class="map-side-heading">Run In Progress</div>
            <div class="map-detail-title">${esc(job.label)}</div>
            <div class="run-stage">${esc({
                hookup: 'Hitch the trailer at the depot',
                enroute: `Delivering — stop ${job.stopIndex} of ${job.stopCount}`,
                return: 'Return the truck to the depot',
            }[job.stage] || job.stage)}</div>
            <div class="map-detail-grid">
                <div><span class="mdl">Payout</span><span class="mdv money">$${Number(job.payout || 0).toLocaleString()}</span></div>
                <div><span class="mdl">Stops</span><span class="mdv">${job.stopIndex}/${job.stopCount}</span></div>
            </div>
        </div>` : '';

    side.innerHTML = `
        ${activeBlock}
        <div class="map-side-block">
            <div class="map-side-heading">${job ? 'Browse Contracts' : 'Selected Route'}</div>
            ${sel ? mapDetailMarkup(sel) : '<div class="empty-state sm">No contract selected.</div>'}
        </div>
        <div class="map-side-block grow">
            <div class="map-side-heading">All Contracts</div>
            <div class="map-list">${list || '<div class="empty-state sm">No contracts configured.</div>'}</div>
        </div>`;

    side.querySelectorAll('.map-list-item').forEach((el) => {
        el.onclick = () => {
            state.mapSelected = el.dataset.id;
            SFX.click();
            paintMap();
        };
        el.onmouseenter = () => SFX.hover();
    });

    const accept = $('#map-accept-btn');
    if (accept) {
        accept.onclick = async () => {
            accept.disabled = true;
            accept.textContent = 'Accepting...';
            const res = await nui('acceptContract', { contractId: state.mapSelected });
            if (res && res.ok) {
                toast('Contract accepted — head to the depot.', 'success');
                closeUI();
            } else {
                toast((res && res.message) || 'Could not accept contract.', 'error');
                accept.disabled = false;
                accept.textContent = 'Accept Contract';
            }
        };
    }
}

function mapDetailMarkup(c) {
    // Rough drive-time estimate from the straight-line route length. A
    // loaded rig averages well under the speed limit, so this deliberately
    // lowballs — it's a planning hint, not a promise.
    const etaSeconds = (Number(c.distance) || 0) / 14;

    let lockNote = '';
    if (!c.levelOk) lockNote = `<div class="map-lock">Requires Rank ${c.minLevel}</div>`;
    else if (!c.trailerOk) lockNote = `<div class="map-lock">Requires a ${esc(c.requiredTrailerType)} trailer</div>`;

    return `
        <div class="map-detail">
            <div class="map-detail-title">${esc(c.label)}</div>
            <div class="map-detail-grid">
                <div><span class="mdl">Payout</span><span class="mdv money">$${Number(c.payout).toLocaleString()}</span></div>
                <div><span class="mdl">XP</span><span class="mdv">+${c.xp}</span></div>
                <div><span class="mdl">Route</span><span class="mdv">${formatDistance(c.distance)}</span></div>
                <div><span class="mdl">Est. Time</span><span class="mdv">${formatDuration(etaSeconds)}</span></div>
                <div><span class="mdl">Stops</span><span class="mdv">${c.stopCount}</span></div>
                <div><span class="mdl">Cargo</span><span class="mdv">${esc(c.cargoType)}</span></div>
            </div>
            ${c.spoilTimeSeconds ? `<div class="map-warn">Perishable — deliver within ${formatDuration(c.spoilTimeSeconds)} or payout halves</div>` : ''}
            ${lockNote}
            ${state.activeJob
                // The server refuses a second contract anyway; disabling here
                // means the button never invites a click it can't honour.
                ? '<button class="btn btn-block" disabled>Finish your current run first</button>'
                : c.unlocked
                    ? '<button class="btn btn-accent btn-block" id="map-accept-btn">Accept Contract</button>'
                    : '<button class="btn btn-block" disabled>Locked</button>'}
        </div>`;
}

// ── Career ───────────────────────────────────────────────────
async function renderCareer() {
    const panel = $('#tab-career');
    panel.innerHTML = `
        <div class="panel-header">
            <div class="panel-title">Career</div>
            <div class="panel-subtitle">Your trucking rank and progress</div>
        </div>
        <div id="career-body"><div class="empty-state">Loading...</div></div>`;

    const career = await nui('getCareer');
    const body = $('#career-body');
    if (!career) {
        body.innerHTML = '<div class="empty-state">No character loaded.</div>';
        return;
    }

    const nextXp = career.nextLevelXp;
    const pct = nextXp ? Math.min(100, Math.round((career.xp / nextXp) * 100)) : 100;

    body.innerHTML = `
        <div class="stat-grid">
            <div class="stat-card"><div class="stat-label">Rank</div><div class="stat-value">${esc(career.title)}</div></div>
            <div class="stat-card"><div class="stat-label">Level</div><div class="stat-value">${career.level}</div></div>
            <div class="stat-card"><div class="stat-label">Deliveries</div><div class="stat-value">${career.totalCompleted}</div></div>
            <div class="stat-card"><div class="stat-label">Total Earned</div><div class="stat-value">$${career.totalEarned.toLocaleString()}</div></div>
            <div class="stat-card"><div class="stat-label">Driver Rating</div><div class="stat-value">${career.rating}/100</div></div>
        </div>
        <div class="card" style="margin-bottom:22px">
            <div class="card-meta">${career.xp} XP ${nextXp ? `/ ${nextXp} XP to next rank` : '(max rank)'}</div>
            <div class="progress-track"><div class="progress-fill" style="width:${pct}%"></div></div>
        </div>
        <div class="section-heading">Achievements</div>
        <div class="badge-grid">
            ${career.achievements.map((a) => `
                <div class="badge ${a.earned ? 'earned' : ''}">
                    <div class="badge-icon">${a.earned ? '🏆' : '🔒'}</div>
                    <div>
                        <div class="badge-label">${esc(a.label)}</div>
                        <div class="badge-desc">${esc(a.description)}</div>
                    </div>
                </div>`).join('')}
        </div>`;
}

// ── Active delivery ──────────────────────────────────────────
const STAGE_ORDER = ['hookup', 'enroute', 'return'];
const STAGE_LABELS = { hookup: 'Hookup', enroute: 'Enroute', return: 'Return' };

async function renderActive() {
    const panel = $('#tab-active');
    panel.innerHTML = `
        <div class="panel-header">
            <div class="panel-title">Active Delivery</div>
            <div class="panel-subtitle">Live status of your current contract</div>
        </div>
        <div id="active-body"><div class="empty-state">Loading...</div></div>`;

    const job = await nui('getActiveJob');
    const body = $('#active-body');
    if (!job) {
        body.innerHTML = '<div class="empty-state">No active delivery — accept a contract from the Contracts tab.</div>';
        return;
    }

    const currentIdx = STAGE_ORDER.indexOf(job.stage);
    const stopLine = job.stopCount > 1 ? `<div class="card-meta">Stop ${job.stopIndex} of ${job.stopCount}</div>` : '';
    body.innerHTML = `
        <div class="status-card">
            <div class="card-title">${esc(job.label)}</div>
            ${stopLine}
            <div class="card-meta">Payout on completion: $${job.payout || 0}</div>
            <div class="stage-track">
                ${STAGE_ORDER.map((s, i) => `
                    <div class="stage-step ${i < currentIdx ? 'done' : ''} ${i === currentIdx ? 'current' : ''}">${STAGE_LABELS[s]}</div>
                `).join('')}
            </div>
        </div>`;
}

// ── Analytics ────────────────────────────────────────────────
// Charts are hand-built SVG. A charting library would be the only external
// dependency in the whole resource, and these are simple enough shapes that
// it would cost far more than it saved.

// Fills gaps so the axis is continuous — a day with no deliveries has to
// render as a zero, not vanish and silently compress the timeline.
function fillDailySeries(daily, days) {
    const byDay = {};
    (daily || []).forEach((d) => { byDay[d.day] = d; });

    const out = [];
    for (let i = days - 1; i >= 0; i--) {
        const dt = new Date();
        dt.setHours(0, 0, 0, 0);
        dt.setDate(dt.getDate() - i);
        // Local-midnight ISO date, matching MySQL's DATE() output format.
        const key = `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, '0')}-${String(dt.getDate()).padStart(2, '0')}`;
        const row = byDay[key];
        out.push({
            day: key,
            short: dt.toLocaleDateString(undefined, { month: 'numeric', day: 'numeric' }),
            earned: row ? row.earned : 0,
            deliveries: row ? row.deliveries : 0,
        });
    }
    return out;
}

function barChart(series, { height = 150 } = {}) {
    if (!series.length) return '<div class="empty-state sm">No data yet.</div>';

    const max = Math.max(1, ...series.map((s) => s.earned));
    const barW = 100 / series.length;

    const bars = series.map((s, i) => {
        const h = (s.earned / max) * 100;
        const x = i * barW;
        return `
        <g class="chart-bar-g">
            <rect class="chart-bar-track" x="${x + barW * 0.15}" y="0" width="${barW * 0.7}" height="100"/>
            <rect class="chart-bar" x="${x + barW * 0.15}" y="${100 - h}" width="${barW * 0.7}" height="${h}">
                <title>${s.short}: $${s.earned.toLocaleString()} over ${s.deliveries} deliveries</title>
            </rect>
        </g>`;
    }).join('');

    const labels = series.map((s, i) => {
        // Only every other tick on a crowded axis, or they overlap.
        if (series.length > 8 && i % 2 !== 0) return '';
        return `<span class="chart-x-label" style="left:${(i + 0.5) * barW}%">${s.short}</span>`;
    }).join('');

    return `
        <div class="chart-wrap" style="height:${height}px">
            <svg class="chart-svg" viewBox="0 0 100 100" preserveAspectRatio="none">${bars}</svg>
            <div class="chart-max">$${max.toLocaleString()}</div>
        </div>
        <div class="chart-x-axis">${labels}</div>`;
}

function sparkline(values, { height = 80 } = {}) {
    if (!values || values.length < 2) return '<div class="empty-state sm">Not enough deliveries yet.</div>';

    // Auto-scaled to the data, NOT to a fixed 0-100. Driver ratings cluster
    // in the 70-100 band in practice, and a fixed axis flattened the whole
    // series into a featureless slab at the top of the chart — the exact
    // thing the trend is supposed to reveal was invisible.
    const lo = Math.min(...values);
    const hi = Math.max(...values);

    let min = Math.max(0, lo - 5);
    let max = Math.min(100, hi + 5);

    // A dead-flat series would otherwise produce a zero-height range and a
    // divide-by-zero; give it a band to sit in the middle of.
    if (max - min < 12) {
        const mid = (max + min) / 2;
        min = Math.max(0, mid - 6);
        max = Math.min(100, mid + 6);
        if (max - min < 12) { min = Math.max(0, max - 12); }
    }

    const span = max - min;
    const step = 100 / (values.length - 1);
    const pts = values.map((v, i) => {
        const y = 100 - ((v - min) / span) * 100;
        return `${(i * step).toFixed(2)},${y.toFixed(2)}`;
    });

    // Closed copy of the same path, dropped to the baseline, for the fill.
    const area = `0,100 ${pts.join(' ')} 100,100`;

    const first = values[0];
    const last = values[values.length - 1];
    const delta = last - first;

    return `
        <div class="chart-wrap" style="height:${height}px">
            <svg class="chart-svg" viewBox="0 0 100 100" preserveAspectRatio="none">
                <polygon class="spark-area" points="${area}"/>
                <polyline class="spark-line" points="${pts.join(' ')}"/>
            </svg>
            <div class="chart-max">${Math.round(max)}</div>
            <div class="chart-min">${Math.round(min)}</div>
        </div>
        <div class="spark-legend">
            <span>Now <strong>${last}</strong>/100</span>
            <span class="${delta >= 0 ? 'up' : 'down'}">${delta >= 0 ? '▲' : '▼'} ${Math.abs(delta)} over ${values.length} runs</span>
            <span>Best ${hi} &middot; Worst ${lo}</span>
        </div>`;
}

async function renderAnalytics() {
    const panel = $('#tab-analytics');
    panel.innerHTML = `
        <div class="panel-header">
            <div class="panel-title">Analytics</div>
            <div class="panel-subtitle">Your hauling performance over time</div>
        </div>
        <div id="analytics-body">${skeleton(4)}</div>`;

    const data = await nui('getAnalytics');
    const body = $('#analytics-body');
    if (!data) {
        body.innerHTML = '<div class="empty-state">No character loaded.</div>';
        return;
    }

    const t = data.totals;
    if (t.deliveries === 0) {
        body.innerHTML = '<div class="empty-state">No deliveries logged yet — complete a contract and your stats will appear here.</div>';
        return;
    }

    const series = fillDailySeries(data.daily, data.days || 14);
    const avgPerRun = Math.round(t.earned / Math.max(1, t.deliveries));

    const contractRows = (data.byContract || []).map((r) => {
        const share = Math.round((r.earned / Math.max(1, t.earned)) * 100);
        return `
        <div class="route-row">
            <div class="route-row-top">
                <span class="route-label">${esc(r.label)}</span>
                <span class="route-earned">$${Number(r.earned).toLocaleString()}</span>
            </div>
            <div class="route-bar-track"><div class="route-bar" style="width:${share}%"></div></div>
            <div class="route-meta">${r.runs} run${r.runs === 1 ? '' : 's'} &middot; avg rating ${r.avg_rating}/100 &middot; ${share}% of earnings</div>
        </div>`;
    }).join('');

    body.innerHTML = `
        <div class="stat-grid">
            <div class="stat-card"><div class="stat-label">Deliveries</div><div class="stat-value">${t.deliveries}</div></div>
            <div class="stat-card"><div class="stat-label">Total Earned</div><div class="stat-value">$${t.earned.toLocaleString()}</div></div>
            <div class="stat-card"><div class="stat-label">Avg / Run</div><div class="stat-value">$${avgPerRun.toLocaleString()}</div></div>
            <div class="stat-card"><div class="stat-label">Distance</div><div class="stat-value">${formatDistance(t.distance)}</div></div>
            <div class="stat-card"><div class="stat-label">Time Driven</div><div class="stat-value">${formatDuration(t.seconds)}</div></div>
            <div class="stat-card"><div class="stat-label">Avg Rating</div><div class="stat-value">${t.avgRating}/100</div></div>
        </div>

        <div class="section-heading">Earnings — last ${data.days} days</div>
        ${barChart(series)}

        <div class="section-heading">Driver rating trend — last ${(data.ratingTrend || []).length} runs</div>
        ${sparkline(data.ratingTrend)}

        <div class="section-heading">Most profitable contracts</div>
        <div class="route-list">${contractRows || '<div class="empty-state sm">No data yet.</div>'}</div>

        ${t.spoiled > 0
            ? `<div class="analytics-note">${t.spoiled} load${t.spoiled === 1 ? '' : 's'} spoiled in transit — perishable cargo pays half if delivered late.</div>`
            : ''}`;
}

// ── Receipts ─────────────────────────────────────────────────
// Each row itemises how its payout was reached. The point is that a player
// can audit the number instead of taking it on trust.
async function renderReceipts() {
    const panel = $('#tab-receipts');
    panel.innerHTML = `
        <div class="panel-header">
            <div class="panel-title">Contract Receipts</div>
            <div class="panel-subtitle">Every completed delivery, itemised</div>
        </div>
        <div id="receipts-body">${skeleton(5)}</div>`;

    const rows = await nui('getHistory');
    const body = $('#receipts-body');

    if (!rows || rows.length === 0) {
        body.innerHTML = '<div class="empty-state">No deliveries logged yet.</div>';
        return;
    }

    body.innerHTML = rows.map((r) => {
        const lines = [];
        const base = Number(r.base_payout) || 0;

        const addLine = (label, pct) => {
            if (!pct) return;
            const amount = Math.round(base * (pct / 100));
            lines.push(`
                <div class="receipt-line ${pct < 0 ? 'neg' : 'pos'}">
                    <span>${label}</span>
                    <span>${pct > 0 ? '+' : ''}${pct}% &middot; ${pct > 0 ? '+' : '-'}$${Math.abs(amount).toLocaleString()}</span>
                </div>`);
        };

        addLine('Truck bonus', r.truck_bonus_pct);
        addLine('Hot contract', r.hot_bonus_pct);
        addLine('Multi-stop', r.multistop_bonus_pct);
        addLine(r.rating_bonus_pct >= 0 ? 'Driver rating bonus' : 'Driver rating penalty', r.rating_bonus_pct);

        if (r.spoiled) {
            lines.push(`
                <div class="receipt-line neg">
                    <span>Cargo spoiled</span>
                    <span>&minus;50%</span>
                </div>`);
        }

        const split = Number(r.company_cut) > 0
            ? `<div class="receipt-line split">
                   <span>Company treasury cut</span>
                   <span>&minus;$${Number(r.company_cut).toLocaleString()}</span>
               </div>`
            : '';

        return `
        <div class="receipt">
            <div class="receipt-head">
                <div>
                    <div class="receipt-title">${esc(r.label)}</div>
                    <div class="receipt-sub">${formatDate(r.completed_ts)} &middot; ${esc(r.cargo_type)} &middot; ${formatDistance(r.distance_m)} &middot; ${formatDuration(r.duration_seconds)}</div>
                </div>
                <div class="receipt-total">
                    <div class="receipt-total-value">+$${Number(r.driver_cut).toLocaleString()}</div>
                    <div class="receipt-total-label">paid to you</div>
                </div>
            </div>
            <div class="receipt-body">
                <div class="receipt-line base">
                    <span>Base payout</span>
                    <span>$${base.toLocaleString()}</span>
                </div>
                ${lines.join('')}
                <div class="receipt-line subtotal">
                    <span>Contract total</span>
                    <span>$${Number(r.final_payout).toLocaleString()}</span>
                </div>
                ${split}
            </div>
            <div class="receipt-foot">
                <span class="receipt-chip">Trip rating ${r.trip_rating}/100</span>
                <span class="receipt-chip">${r.stop_count} stop${r.stop_count === 1 ? '' : 's'}</span>
                <span class="receipt-chip">+${r.xp} XP</span>
            </div>
        </div>`;
    }).join('');
}

// ── Leaderboard ──────────────────────────────────────────────
async function renderLeaderboard() {
    const panel = $('#tab-leaderboard');
    panel.innerHTML = `
        <div class="panel-header">
            <div class="panel-title">Leaderboard</div>
            <div class="panel-subtitle">Top truckers and top companies</div>
        </div>
        <div class="subtabs" style="margin-bottom:16px">
            <div class="subtab ${state.leaderboardView === 'drivers' ? 'active' : ''}" data-view="drivers">Drivers</div>
            <div class="subtab ${state.leaderboardView === 'companies' ? 'active' : ''}" data-view="companies">Companies</div>
        </div>
        <div id="leaderboard-body"><div class="empty-state">Loading...</div></div>`;

    // Scoped to this panel. Every tab-panel keeps its rendered markup in the
    // DOM after you switch away (only `.active` toggles visibility), so a
    // bare `$$('.subtab')` here would also rebind the Company tab's subtabs
    // — clicking one would then set leaderboardView to undefined and yank
    // the user's view across tabs. Same reason renderCompany scopes its own.
    $$('#tab-leaderboard .subtab').forEach((el) => {
        el.onclick = () => { state.leaderboardView = el.dataset.view; renderLeaderboard(); };
    });

    const body = $('#leaderboard-body');

    if (state.leaderboardView === 'companies') {
        const rows = await nui('getCompanyLeaderboard');
        if (!rows || rows.length === 0) {
            body.innerHTML = '<div class="empty-state">No companies founded yet.</div>';
            return;
        }
        body.innerHTML = rows.map((r, i) => `
            <div class="leaderboard-row">
                <div class="leaderboard-rank">#${i + 1}</div>
                <div class="leaderboard-name">${esc(r.label) || 'Unknown'}</div>
                <div class="leaderboard-meta">${r.reputation} reputation &middot; $${Number(r.bank).toLocaleString()} treasury</div>
            </div>`).join('');
        return;
    }

    const rows = await nui('getLeaderboard');
    if (!rows || rows.length === 0) {
        body.innerHTML = '<div class="empty-state">No deliveries completed yet.</div>';
        return;
    }

    body.innerHTML = rows.map((r, i) => `
        <div class="leaderboard-row">
            <div class="leaderboard-rank">#${i + 1}</div>
            <div class="leaderboard-name">${esc(r.name) || 'Unknown'}</div>
            <div class="leaderboard-meta">Lvl ${r.level} &middot; ${r.total_completed} deliveries &middot; $${Number(r.total_earned).toLocaleString()}</div>
        </div>`).join('');
}

// ── Garage (personal trucks + trailers) ───────────────────────
// Performance upgrades — shared between the personal Garage and the
// Company Fleet view, since both list trucks from the same underlying
// cipher_trucking_owned table. `o.upgrades` is a raw JSON string from the
// server (id -> level); `defs` is Config.Trucking.PerformanceUpgrades as
// returned by getGarage.
function performanceHtml(o, defs, btnClass) {
    if (!defs || !defs.length) return '';
    let levels = {};
    try { levels = JSON.parse(o.upgrades || '{}') || {}; } catch (e) { levels = {}; }

    const rows = defs.map((d) => {
        const level = levels[d.id] || 0;
        const maxed = level >= d.maxLevel;
        const cost = d.costPerLevel * (level + 1);
        return `<div class="upgrade-row">
            <span class="upgrade-label">${esc(d.label)} <span class="upgrade-level">${level}/${d.maxLevel}</span></span>
            <button class="btn btn-sm ${maxed ? '' : 'btn-accent'} ${btnClass}" data-id="${o.id}" data-upgrade="${d.id}" ${maxed ? 'disabled' : ''}>
                ${maxed ? 'Max' : `+$${cost.toLocaleString()}`}
            </button>
        </div>`;
    }).join('');

    return `<div class="upgrade-section"><div class="upgrade-heading">Performance</div>${rows}</div>`;
}

// Fuel + wear gauges for an owned truck. `m` is the server-decoded `maint`
// object (see Maintenance.Read); `cfgM` is getGarage's `maintenance` block
// carrying the component definitions. Shared by the Garage and Company
// Fleet views so both render identically from identical data.
function maintenanceHtml(o, cfgM, btnClass) {
    if (!cfgM || !cfgM.enabled || o.kind === 'trailer') return '';

    const m = o.maint || {};
    const fuel = Math.max(0, Math.min(100, m.fuel == null ? 100 : m.fuel));
    const lowFuel = fuel <= (cfgM.lowWarnPct || 20);

    const rows = (cfgM.wear || []).map((w) => {
        const val = Math.max(0, Math.min(100, m[w.id] == null ? 100 : m[w.id]));
        const worn = val < (w.warnAt || 25);
        // Cost scales with wear, matching Maintenance.Service server-side.
        const cost = Math.ceil(w.serviceCost * ((100 - val) / 100));
        return `
        <div class="maint-row">
            <div class="maint-head">
                <span class="maint-label ${worn ? 'worn' : ''}" title="${esc(w.help || '')}">${esc(w.label)}</span>
                <span class="maint-val">${Math.round(val)}%</span>
            </div>
            <div class="progress-track sm">
                <div class="progress-fill ${conditionClass(val)}" style="width:${val}%"></div>
            </div>
            <button class="btn btn-sm ${worn ? 'btn-accent' : ''} ${btnClass}"
                data-id="${o.id}" data-component="${esc(w.id)}" ${val >= 100 ? 'disabled' : ''}>
                ${val >= 100 ? 'OK' : `Service $${cost.toLocaleString()}`}
            </button>
        </div>`;
    }).join('');

    const anyWorn = (cfgM.wear || []).some((w) => (m[w.id] == null ? 100 : m[w.id]) < 100);

    return `
    <div class="maint-section">
        <div class="upgrade-heading">Fuel &amp; Maintenance</div>
        <div class="maint-row">
            <div class="maint-head">
                <span class="maint-label ${lowFuel ? 'worn' : ''}">Fuel</span>
                <span class="maint-val">${Math.round(fuel)}%</span>
            </div>
            <div class="progress-track sm">
                <div class="progress-fill ${lowFuel ? 'condition-low' : 'fuel-fill'}" style="width:${fuel}%"></div>
            </div>
            <span class="maint-note">Refuel at a station</span>
        </div>
        ${rows}
        ${anyWorn ? `<button class="btn btn-block btn-sm ${btnClass}" data-id="${o.id}" data-component="all">Full Service</button>` : ''}
    </div>`;
}

// Cosmetic-only paint job — shared between the personal Garage and Company
// Fleet views, same as performanceHtml above. `colors` is
// Config.Trucking.PaintColors and `cost` is Config.Trucking.paintCost, both
// as returned by getGarage.
function paintHtml(o, colors, cost, selectPrefix, btnClass) {
    if (!colors || !colors.length) return '';
    let current = {};
    try { current = JSON.parse(o.livery || '{}') || {}; } catch (e) { current = {}; }

    const options = (selected) => colors.map((c) =>
        `<option value="${c.id}" ${c.id === selected ? 'selected' : ''}>${esc(c.label)}</option>`).join('');

    return `<div class="paint-section">
        <div class="upgrade-heading">Paint</div>
        <div class="paint-row">
            <label>Primary</label>
            <select class="input ${selectPrefix}-primary" data-id="${o.id}">${options(current.primary)}</select>
        </div>
        <div class="paint-row">
            <label>Secondary</label>
            <select class="input ${selectPrefix}-secondary" data-id="${o.id}">${options(current.secondary)}</select>
        </div>
        <button class="btn btn-accent btn-sm ${btnClass}" data-id="${o.id}">Apply Paint ($${Number(cost || 0).toLocaleString()})</button>
    </div>`;
}

function dispatchSectionHtml(o, dispatchable, selectPrefix, dispatchClass, collectClass) {
    if (o.dispatch_ready_at) {
        const ready = Date.now() >= o.dispatch_ready_at;
        return `<div class="card-row">
            <span class="card-meta" style="margin:0">${ready ? 'Ready to collect!' : 'Out on a run...'}</span>
            <button class="btn ${ready ? 'btn-accent' : ''} ${collectClass}" data-id="${o.id}" ${ready ? '' : 'disabled'}>Collect</button>
        </div>`;
    }
    if (dispatchable.length === 0) return '';
    return `<div class="card-row">
        <select class="input ${selectPrefix}" data-id="${o.id}" style="flex:1;margin-right:8px">
            ${dispatchable.map((c) => `<option value="${esc(c.id)}">${esc(c.label)} ($${c.payout})</option>`).join('')}
        </select>
        <button class="btn ${dispatchClass}" data-id="${o.id}">Dispatch</button>
    </div>`;
}

async function renderGarage() {
    const panel = $('#tab-garage');
    panel.innerHTML = `
        <div class="panel-header">
            <div class="panel-title">Garage</div>
            <div class="panel-subtitle">Owned trucks add a payout bonus; specialized trailers unlock specialized cargo</div>
        </div>
        <div id="garage-body"><div class="empty-state">Loading...</div></div>`;

    const [data, contracts] = await Promise.all([nui('getGarage'), nui('getContracts')]);
    const body = $('#garage-body');
    if (!data) {
        body.innerHTML = '<div class="empty-state">No character loaded.</div>';
        return;
    }

    const dispatchable = (contracts || []).filter((c) => c.unlocked && !c.hot);
    const owned = data.owned || [];
    const trucks = owned.filter((o) => o.kind !== 'trailer');
    const trailers = owned.filter((o) => o.kind === 'trailer');

    const truckCard = (o) => `
        <div class="card">
            <div class="card-title">${esc(o.label)}</div>
            <div class="card-meta">Condition: ${o.condition}%</div>
            <div class="progress-track"><div class="progress-fill ${conditionClass(o.condition)}" style="width:${o.condition}%"></div></div>
            <div class="card-row">
                <button class="btn ${data.selectedTruck === o.id ? 'btn-signal' : ''} select-truck-btn" data-id="${o.id}" ${o.dispatch_ready_at ? 'disabled' : ''}>
                    ${data.selectedTruck === o.id ? 'Active' : 'Set Active'}
                </button>
                <button class="btn btn-danger repair-btn" data-id="${o.id}" ${o.condition >= 100 ? 'disabled' : ''}>Repair</button>
            </div>
            ${maintenanceHtml(o, data.maintenance, 'service-btn')}
            ${performanceHtml(o, data.performanceUpgrades, 'upgrade-btn')}
            ${paintHtml(o, data.paintColors, data.paintCost, 'paint-select', 'paint-btn')}
            ${dispatchSectionHtml(o, dispatchable, 'dispatch-select', 'dispatch-btn', 'collect-btn')}
        </div>`;

    const trailerCard = (o) => `
        <div class="card">
            <div class="card-title">${esc(o.label)}</div>
            <div class="card-meta">Condition: ${o.condition}%</div>
            <div class="progress-track"><div class="progress-fill ${conditionClass(o.condition)}" style="width:${o.condition}%"></div></div>
            <div class="card-row">
                <button class="btn ${data.selectedTrailer === o.id ? 'btn-signal' : ''} select-trailer-btn" data-id="${o.id}">
                    ${data.selectedTrailer === o.id ? 'Active' : 'Set Active'}
                </button>
                <button class="btn btn-danger repair-btn" data-id="${o.id}" ${o.condition >= 100 ? 'disabled' : ''}>Repair</button>
            </div>
        </div>`;

    const trucksHtml = trucks.length === 0
        ? '<div class="empty-state">You don’t own any trucks yet — buy one below.</div>'
        : `<div class="card-grid">${trucks.map(truckCard).join('')}</div>`;
    const trailersHtml = trailers.length === 0
        ? '<div class="empty-state">You don’t own any trailers yet — buy one below.</div>'
        : `<div class="card-grid">${trailers.map(trailerCard).join('')}</div>`;

    const shop = data.shop || [];
    const shopTrucks = shop.filter((s) => s.kind !== 'trailer');
    const shopTrailers = shop.filter((s) => s.kind === 'trailer');

    const shopTruckHtml = `<div class="card-grid">${shopTrucks.map((s) => `
        <div class="card">
            <div class="card-title">${esc(s.label)}</div>
            <div class="card-meta">+${s.payoutBonusPct}% payout bonus</div>
            <div class="card-row">
                <span class="card-stat money">$${s.price.toLocaleString()}</span>
                <button class="btn btn-accent buy-btn" data-id="${s.id}" ${data.cash < s.price ? 'disabled' : ''}>Buy</button>
            </div>
        </div>`).join('')}</div>`;

    const shopTrailerHtml = `<div class="card-grid">${shopTrailers.map((s) => `
        <div class="card">
            <div class="card-title">${esc(s.label)}</div>
            <div class="card-meta">Unlocks ${esc(s.cargoType)} cargo</div>
            <div class="card-row">
                <span class="card-stat money">$${s.price.toLocaleString()}</span>
                <button class="btn btn-accent buy-btn" data-id="${s.id}" ${data.cash < s.price ? 'disabled' : ''}>Buy</button>
            </div>
        </div>`).join('')}</div>`;

    body.innerHTML = `
        <div class="section-heading">My Trucks</div>
        ${trucksHtml}
        <div class="section-heading">My Trailers</div>
        ${trailersHtml}
        <div class="section-heading">Truck Shop</div>
        ${shopTruckHtml}
        <div class="section-heading">Trailer Shop</div>
        ${shopTrailerHtml}`;

    $$('.select-truck-btn').forEach((btn) => {
        btn.onclick = async () => {
            const res = await nui('selectTruck', { ownedId: Number(btn.dataset.id) });
            if (res && res.ok) { toast('Active truck updated.', 'success'); renderGarage(); }
            else toast((res && res.message) || 'Could not select truck.', 'error');
        };
    });
    $$('.select-trailer-btn').forEach((btn) => {
        btn.onclick = async () => {
            const res = await nui('selectTrailer', { ownedId: Number(btn.dataset.id) });
            if (res && res.ok) { toast('Active trailer updated.', 'success'); renderGarage(); }
            else toast((res && res.message) || 'Could not select trailer.', 'error');
        };
    });
    $$('.repair-btn').forEach((btn) => {
        btn.onclick = async () => {
            const res = await nui('repairVehicle', { ownedId: Number(btn.dataset.id) });
            if (res && res.ok) { toast('Repaired.', 'success'); renderGarage(); }
            else toast((res && res.message) || 'Could not repair.', 'error');
        };
    });
    $$('.upgrade-btn').forEach((btn) => {
        btn.onclick = async () => {
            const res = await nui('upgradeVehicle', { ownedId: Number(btn.dataset.id), upgradeId: btn.dataset.upgrade });
            if (res && res.ok) { toast('Upgraded.', 'success'); renderGarage(); }
            else toast((res && res.message) || 'Could not upgrade.', 'error');
        };
    });
    $$('.service-btn').forEach((btn) => {
        btn.onclick = async () => {
            const res = await nui('serviceVehicle', {
                ownedId: Number(btn.dataset.id), componentId: btn.dataset.component,
            });
            if (res && res.ok) { SFX.confirm(); toast('Serviced.', 'success'); renderGarage(); }
            else toast((res && res.message) || 'Could not service.', 'error');
        };
    });
    $$('.paint-btn').forEach((btn) => {
        btn.onclick = async () => {
            const id = btn.dataset.id;
            const primary = document.querySelector(`.paint-select-primary[data-id="${id}"]`);
            const secondary = document.querySelector(`.paint-select-secondary[data-id="${id}"]`);
            const res = await nui('paintVehicle', {
                ownedId: Number(id),
                primaryId: Number(primary.value),
                secondaryId: Number(secondary.value),
            });
            if (res && res.ok) { toast('Truck repainted.', 'success'); renderGarage(); }
            else toast((res && res.message) || 'Could not paint truck.', 'error');
        };
    });
    $$('.buy-btn').forEach((btn) => {
        btn.onclick = async () => {
            const res = await nui('buyVehicle', { shopId: btn.dataset.id });
            if (res && res.ok) { toast('Purchased.', 'success'); renderGarage(); }
            else toast((res && res.message) || 'Could not buy.', 'error');
        };
    });
    $$('.dispatch-btn').forEach((btn) => {
        btn.onclick = async () => {
            const select = document.querySelector(`.dispatch-select[data-id="${btn.dataset.id}"]`);
            const contractId = select ? select.value : null;
            if (!contractId) return;
            const res = await nui('dispatchVehicle', { ownedId: Number(btn.dataset.id), contractId });
            if (res && res.ok) { toast('Truck dispatched.', 'success'); renderGarage(); }
            else toast((res && res.message) || 'Could not dispatch.', 'error');
        };
    });
    $$('.collect-btn').forEach((btn) => {
        btn.onclick = async () => {
            const res = await nui('collectVehicle', { ownedId: Number(btn.dataset.id) });
            if (res && res.ok) { toast('Collected.', 'success'); renderGarage(); }
            else toast((res && res.message) || 'Could not collect.', 'error');
        };
    });
}

// ── Company ──────────────────────────────────────────────────
async function renderCompany() {
    const panel = $('#tab-company');
    panel.innerHTML = `
        <div class="panel-header">
            <div class="panel-title">Company</div>
            <div class="panel-subtitle">Found or manage a trucking company</div>
        </div>
        <div id="company-body"><div class="empty-state">Loading...</div></div>`;

    const company = await nui('getCompany');
    const body = $('#company-body');

    // `level` and `roster` are always present on a real snapshot. Treating a
    // truthy-but-incomplete payload as "no company" keeps a partial response
    // (server error swallowed by safeCall, a malformed cb) rendering the
    // found-a-company state instead of throwing on company.level.title and
    // leaving the tab permanently blank.
    if (company && (!company.level || !company.roster)) {
        body.innerHTML = '<div class="empty-state">Company data could not be loaded — try reopening the terminal.</div>';
        return;
    }

    if (!company) {
        body.innerHTML = `
            <div class="empty-state">
                <div style="margin-bottom:14px">You're not in a company yet. Get invited by an existing member, or found your own.</div>
                <div class="form-row" style="max-width:380px;margin:0 auto;text-align:left">
                    <div class="field">
                        <label class="field-label">Company Name</label>
                        <input type="text" class="input" id="found-name-input" placeholder="e.g. Apex Freight Co.">
                    </div>
                    <button class="btn btn-accent" id="found-btn">Found</button>
                </div>
            </div>`;
        $('#found-btn').onclick = async () => {
            const name = $('#found-name-input').value.trim();
            if (!name) return;
            const res = await nui('foundCompany', { name });
            if (res && res.ok) { toast('Company founded.', 'success'); renderCompany(); }
            else toast((res && res.message) || 'Could not found company.', 'error');
        };
        return;
    }

    body.innerHTML = `
        <div class="stat-grid">
            <div class="stat-card"><div class="stat-label">Company</div><div class="stat-value" style="font-size:15px">${esc(company.name)}</div></div>
            <div class="stat-card"><div class="stat-label">Level</div><div class="stat-value" style="font-size:15px">${esc(company.level.title)}</div></div>
            <div class="stat-card"><div class="stat-label">Treasury</div><div class="stat-value">$${Number(company.bank).toLocaleString()}</div></div>
            <div class="stat-card"><div class="stat-label">Your Rank</div><div class="stat-value" style="font-size:15px">${esc(company.myRankName)}</div></div>
        </div>
        <div class="subtabs">
            <div class="subtab ${state.companySubtab === 'overview' ? 'active' : ''}" data-subtab="overview">Overview</div>
            <div class="subtab ${state.companySubtab === 'roster' ? 'active' : ''}" data-subtab="roster">Roster</div>
            <div class="subtab ${state.companySubtab === 'treasury' ? 'active' : ''}" data-subtab="treasury">Treasury</div>
            <div class="subtab ${state.companySubtab === 'fleet' ? 'active' : ''}" data-subtab="fleet">Fleet</div>
            <div class="subtab ${state.companySubtab === 'perks' ? 'active' : ''}" data-subtab="perks">Perks</div>
        </div>
        <div id="company-subtab-body"><div class="empty-state">Loading...</div></div>`;

    // Scoped — see renderLeaderboard's matching comment.
    $$('#tab-company .subtab').forEach((el) => {
        el.onclick = () => { state.companySubtab = el.dataset.subtab; renderCompany(); };
    });

    const subtabBody = $('#company-subtab-body');
    if (state.companySubtab === 'overview') renderCompanyOverview(subtabBody, company);
    else if (state.companySubtab === 'roster') renderCompanyRoster(subtabBody, company);
    else if (state.companySubtab === 'treasury') await renderCompanyTreasury(subtabBody, company);
    else if (state.companySubtab === 'fleet') await renderCompanyFleet(subtabBody, company);
    else if (state.companySubtab === 'perks') renderCompanyPerks(subtabBody, company);
}

function renderCompanyOverview(el, company) {
    const achievements = company.achievements || [];

    el.innerHTML = `
        <div class="card" style="margin-bottom:22px">
            <div class="card-title">${esc(company.level.title)}</div>
            <div class="card-meta">${company.reputation} reputation &middot; ${company.totalDeliveries || 0} company deliveries</div>
            <div class="card-meta">Contracts delivered with a company truck split payout between the driver and the treasury — see the Fleet tab to put a truck to work.</div>
        </div>
        <div class="section-heading">Achievements</div>
        <div class="badge-grid">
            ${achievements.map((a) => `
                <div class="badge ${a.earned ? 'earned' : ''}">
                    <div class="badge-icon">${a.earned ? '🏆' : '🔒'}</div>
                    <div>
                        <div class="badge-label">${esc(a.label)}</div>
                        <div class="badge-desc">${esc(a.description)}</div>
                    </div>
                </div>`).join('')}
        </div>
        ${company.isOwner ? `
            <div class="danger-zone">
                <div class="section-heading">Danger Zone</div>
                <div class="card-meta" style="margin-bottom:10px">Disbanding permanently deletes the company, its ranks, roster, treasury, and perks. Company-owned trucks/trailers are returned to whoever originally bought them.</div>
                <button class="btn btn-danger disband-btn" id="disband-btn">Disband Company</button>
            </div>` : ''}`;

    const disbandBtn = $('#disband-btn');
    if (disbandBtn) {
        disbandBtn.onclick = async () => {
            if (disbandBtn.dataset.armed !== 'true') {
                disbandBtn.dataset.armed = 'true';
                disbandBtn.textContent = 'Click again to confirm';
                setTimeout(() => { disbandBtn.dataset.armed = 'false'; disbandBtn.textContent = 'Disband Company'; }, 4000);
                return;
            }
            const res = await nui('disbandCompany');
            if (res && res.ok) { toast('Company disbanded.', 'success'); renderCompany(); }
            else toast((res && res.message) || 'Could not disband company.', 'error');
        };
    }
}

function renderCompanyRoster(el, company) {
    const rows = company.roster.map((m) => `
        <div class="roster-row">
            <div class="online-dot ${m.online ? 'online' : ''}"></div>
            <div class="roster-name">${esc(m.name)}${m.isOwner ? ' &middot; Owner' : ''}</div>
            <div class="roster-rank">${esc(m.rankName)}</div>
            ${(!m.isOwner && company.permissions.promote) ? `
                <select class="input rank-select" data-cid="${esc(m.citizenid)}" style="width:auto">
                    ${company.ranks.map((r) => `<option value="${r.grade}" ${r.grade === m.grade ? 'selected' : ''}>${esc(r.name)}</option>`).join('')}
                </select>` : ''}
            ${(!m.isOwner && company.permissions.kick) ? `<button class="btn btn-danger btn-sm kick-btn" data-cid="${esc(m.citizenid)}">Kick</button>` : ''}
        </div>`).join('');

    el.innerHTML = `
        <div class="section-heading">Members (${company.roster.length})</div>
        ${rows}
        ${company.permissions.invite ? '<div class="empty-state" style="margin-top:12px">You can invite people — target a nearby player in-world and select "Invite to Company".</div>' : ''}`;

    $$('.kick-btn').forEach((btn) => {
        btn.onclick = async () => {
            const res = await nui('companyKick', { citizenid: btn.dataset.cid });
            if (res && res.ok) { toast('Member kicked.', 'success'); renderCompany(); }
            else toast((res && res.message) || 'Could not kick.', 'error');
        };
    });
    $$('.rank-select').forEach((sel) => {
        sel.onchange = async () => {
            const res = await nui('companySetGrade', { citizenid: sel.dataset.cid, grade: Number(sel.value) });
            if (res && res.ok) { toast('Rank updated.', 'success'); renderCompany(); }
            else toast((res && res.message) || 'Could not update rank.', 'error');
        };
    });
}

async function renderCompanyTreasury(el, company) {
    el.innerHTML = `
        <div class="form-row" style="margin-bottom:20px;max-width:420px">
            <div class="field">
                <label class="field-label">Amount</label>
                <input type="number" class="input" id="treasury-amount" min="1" placeholder="0">
            </div>
            <button class="btn btn-accent" id="deposit-btn">Deposit</button>
            ${company.permissions.manage_treasury ? '<button class="btn btn-danger" id="withdraw-btn">Withdraw</button>' : ''}
        </div>
        <div class="section-heading">Recent Transactions</div>
        <div id="ledger-list"><div class="empty-state">Loading...</div></div>`;

    $('#deposit-btn').onclick = async () => {
        const amount = Number($('#treasury-amount').value);
        if (!amount || amount <= 0) return;
        const res = await nui('companyDeposit', { amount });
        if (res && res.ok) { toast('Deposited.', 'success'); renderCompany(); }
        else toast((res && res.message) || 'Could not deposit.', 'error');
    };
    const withdrawBtn = $('#withdraw-btn');
    if (withdrawBtn) {
        withdrawBtn.onclick = async () => {
            const amount = Number($('#treasury-amount').value);
            if (!amount || amount <= 0) return;
            const res = await nui('companyWithdraw', { amount });
            if (res && res.ok) { toast('Withdrawn.', 'success'); renderCompany(); }
            else toast((res && res.message) || 'Could not withdraw.', 'error');
        };
    }

    const ledger = await nui('companyGetLedger');
    const list = $('#ledger-list');
    if (!ledger || ledger.length === 0) {
        list.innerHTML = '<div class="empty-state">No transactions yet.</div>';
        return;
    }
    const positiveKinds = ['deposit', 'income'];
    list.innerHTML = ledger.map((t) => `
        <div class="ledger-row">
            <div class="ledger-kind">${esc(t.kind)}</div>
            <div class="ledger-name">${esc(t.name) || 'System'}</div>
            <div class="ledger-amount ${positiveKinds.includes(t.kind) ? 'positive' : 'negative'}">
                ${positiveKinds.includes(t.kind) ? '+' : '-'}$${Number(t.amount).toLocaleString()}
            </div>
        </div>`).join('');
}

function renderCompanyPerks(el, company) {
    const canBuy = company.permissions.manage_perks;
    const tree = company.perkTree || {};
    const owned = company.ownedPerks || {};

    const branchesHtml = Object.keys(tree).map((key) => {
        const branch = tree[key];
        const tiersHtml = branch.tiers.map((t, i) => {
            const isOwned = !!owned[t.id];
            const prevOwned = i === 0 || owned[branch.tiers[i - 1].id];
            const buyable = canBuy && !isOwned && prevOwned && company.perkPoints >= t.cost;

            let stateClass = 'locked';
            if (isOwned) stateClass = 'owned';
            else if (prevOwned) stateClass = 'available';

            return `<div class="perk-tier ${stateClass}">
                <div class="perk-tier-label">${esc(t.label)}</div>
                <div class="perk-tier-desc">${esc(t.description)}</div>
                ${isOwned
                    ? '<div class="perk-tier-cost owned">Owned</div>'
                    : `<button class="btn btn-sm ${buyable ? 'btn-accent' : ''} buy-perk-btn" data-id="${esc(t.id)}" ${buyable ? '' : 'disabled'}>
                        Unlock &middot; ${t.cost} pt
                       </button>`}
            </div>`;
        }).join('');

        return `<div class="perk-branch">
            <div class="perk-branch-label">${esc(branch.label)}</div>
            ${tiersHtml}
        </div>`;
    }).join('');

    el.innerHTML = `
        <div class="card-meta" style="margin-bottom:14px">Perk Points available: <strong>${company.perkPoints}</strong></div>
        <div class="perk-tree">${branchesHtml}</div>
        ${canBuy ? '' : '<div class="empty-state" style="margin-top:12px">Only members with the manage_perks permission can spend perk points.</div>'}`;

    $$('.buy-perk-btn').forEach((btn) => {
        btn.onclick = async () => {
            const res = await nui('companyBuyPerk', { perkId: btn.dataset.id });
            if (res && res.ok) { toast('Perk unlocked.', 'success'); renderCompany(); }
            else toast((res && res.message) || 'Could not unlock perk.', 'error');
        };
    });
}

async function renderCompanyFleet(el, company) {
    el.innerHTML = '<div class="empty-state">Loading...</div>';
    const [contracts, garage] = await Promise.all([nui('getContracts'), nui('getGarage')]);
    const dispatchable = (contracts || []).filter((c) => c.unlocked && !c.hot);
    const shop = (garage && garage.shop) || [];

    const fleet = company.fleet || [];
    const trucks = fleet.filter((o) => o.kind !== 'trailer');
    const trailers = fleet.filter((o) => o.kind === 'trailer');
    const canManage = company.permissions.manage_vehicles;

    const truckCard = (o) => `
        <div class="card">
            <div class="card-title">${esc(o.label)}</div>
            <div class="card-meta">Condition: ${o.condition}%</div>
            <div class="progress-track"><div class="progress-fill ${conditionClass(o.condition)}" style="width:${o.condition}%"></div></div>
            ${canManage ? `
                <div class="card-row">
                    <button class="btn btn-danger repair-fleet-btn" data-id="${o.id}" ${o.condition >= 100 ? 'disabled' : ''}>Repair</button>
                </div>
                ${maintenanceHtml(o, garage && garage.maintenance, 'service-fleet-btn')}
                ${performanceHtml(o, garage && garage.performanceUpgrades, 'upgrade-fleet-btn')}
                ${paintHtml(o, garage && garage.paintColors, garage && garage.paintCost, 'paint-fleet-select', 'paint-fleet-btn')}
                ${dispatchSectionHtml(o, dispatchable, 'dispatch-fleet-select', 'dispatch-fleet-btn', 'collect-fleet-btn')}
            ` : ''}
        </div>`;

    const trailerCard = (o) => `
        <div class="card">
            <div class="card-title">${esc(o.label)}</div>
            <div class="card-meta">Condition: ${o.condition}%</div>
            <div class="progress-track"><div class="progress-fill ${conditionClass(o.condition)}" style="width:${o.condition}%"></div></div>
            ${canManage ? `
                <div class="card-row">
                    <button class="btn btn-danger repair-fleet-btn" data-id="${o.id}" ${o.condition >= 100 ? 'disabled' : ''}>Repair</button>
                </div>` : ''}
        </div>`;

    const shopHtml = canManage
        ? `<div class="card-grid">${shop.map((s) => `
            <div class="card">
                <div class="card-title">${esc(s.label)}</div>
                <div class="card-meta">${s.kind === 'trailer' ? `Unlocks ${esc(s.cargoType)} cargo` : `+${s.payoutBonusPct}% payout bonus`}</div>
                <div class="card-row">
                    <span class="card-stat money">$${s.price.toLocaleString()}</span>
                    <button class="btn btn-accent buy-fleet-btn" data-id="${s.id}" ${company.bank < s.price ? 'disabled' : ''}>Buy for Company</button>
                </div>
            </div>`).join('')}</div>`
        : '<div class="empty-state">Only Managers/Owners can buy company vehicles.</div>';

    el.innerHTML = `
        <div class="section-heading">Company Trucks</div>
        ${trucks.length ? `<div class="card-grid">${trucks.map(truckCard).join('')}</div>` : '<div class="empty-state">No company trucks yet.</div>'}
        <div class="section-heading">Company Trailers</div>
        ${trailers.length ? `<div class="card-grid">${trailers.map(trailerCard).join('')}</div>` : '<div class="empty-state">No company trailers yet.</div>'}
        <div class="section-heading">Fleet Shop</div>
        ${shopHtml}`;

    $$('.repair-fleet-btn').forEach((btn) => {
        btn.onclick = async () => {
            const res = await nui('repairVehicle', { ownedId: Number(btn.dataset.id) });
            if (res && res.ok) { toast('Repaired.', 'success'); renderCompany(); }
            else toast((res && res.message) || 'Could not repair.', 'error');
        };
    });
    $$('.service-fleet-btn').forEach((btn) => {
        btn.onclick = async () => {
            const res = await nui('serviceVehicle', {
                ownedId: Number(btn.dataset.id), componentId: btn.dataset.component,
            });
            if (res && res.ok) { SFX.confirm(); toast('Serviced.', 'success'); renderCompany(); }
            else toast((res && res.message) || 'Could not service.', 'error');
        };
    });
    $$('.upgrade-fleet-btn').forEach((btn) => {
        btn.onclick = async () => {
            const res = await nui('upgradeVehicle', { ownedId: Number(btn.dataset.id), upgradeId: btn.dataset.upgrade });
            if (res && res.ok) { toast('Upgraded.', 'success'); renderCompany(); }
            else toast((res && res.message) || 'Could not upgrade.', 'error');
        };
    });
    $$('.paint-fleet-btn').forEach((btn) => {
        btn.onclick = async () => {
            const id = btn.dataset.id;
            const primary = document.querySelector(`.paint-fleet-select-primary[data-id="${id}"]`);
            const secondary = document.querySelector(`.paint-fleet-select-secondary[data-id="${id}"]`);
            const res = await nui('paintVehicle', {
                ownedId: Number(id),
                primaryId: Number(primary.value),
                secondaryId: Number(secondary.value),
            });
            if (res && res.ok) { toast('Truck repainted.', 'success'); renderCompany(); }
            else toast((res && res.message) || 'Could not paint truck.', 'error');
        };
    });
    $$('.dispatch-fleet-btn').forEach((btn) => {
        btn.onclick = async () => {
            const select = document.querySelector(`.dispatch-fleet-select[data-id="${btn.dataset.id}"]`);
            const contractId = select ? select.value : null;
            if (!contractId) return;
            const res = await nui('dispatchVehicle', { ownedId: Number(btn.dataset.id), contractId });
            if (res && res.ok) { toast('Truck dispatched.', 'success'); renderCompany(); }
            else toast((res && res.message) || 'Could not dispatch.', 'error');
        };
    });
    $$('.collect-fleet-btn').forEach((btn) => {
        btn.onclick = async () => {
            const res = await nui('collectVehicle', { ownedId: Number(btn.dataset.id) });
            if (res && res.ok) { toast('Collected.', 'success'); renderCompany(); }
            else toast((res && res.message) || 'Could not collect.', 'error');
        };
    });
    $$('.buy-fleet-btn').forEach((btn) => {
        btn.onclick = async () => {
            const res = await nui('companyBuyVehicle', { shopId: btn.dataset.id });
            if (res && res.ok) { toast('Purchased for company.', 'success'); renderCompany(); }
            else toast((res && res.message) || 'Could not buy.', 'error');
        };
    });
}

// ── Static bindings ──────────────────────────────────────────
$$('.nav-item').forEach((item) => {
    item.onclick = () => { SFX.tab(); switchTab(item.dataset.tab); };
    item.onmouseenter = () => SFX.hover();
});
$('#close-btn').onclick = closeUI;

loadPrefs();
