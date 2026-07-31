// ─────────────────────────────────────────────────────────────
// Ops console
// Staff-only. Loads after app.js and reuses its nui/esc/toast helpers.
//
// Two rules this file follows without exception:
//
//  1. NO alert() / confirm() / prompt(). FiveM's CEF has no working
//     implementation of any of them — calling one hangs the browser and the
//     whole panel dies. Destructive actions use an arm-then-confirm button
//     instead, which needs no dialog at all.
//  2. Every class is ad-* prefixed. This shares one document with the
//     dashboard and the HUD; an unprefixed class collided across
//     stylesheets in cipher-drugs and silently broke button layout.
// ─────────────────────────────────────────────────────────────
const AdminConsole = (() => {
    const adState = { tab: 'overview', playerCid: null, fleetFilter: 'all', searchTimer: null };

    const body = () => document.querySelector('#admin-body');

    function money(v) { return '$' + Number(v || 0).toLocaleString(); }

    function when(ts) {
        if (!ts) return '';
        const d = new Date(Number(ts) * 1000);
        return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
            + ' ' + d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
    }

    // Arm-then-confirm. First click re-labels and starts a 4s window; a
    // second click inside that window commits. Replaces confirm() entirely.
    function arm(btn, label, onConfirm) {
        btn.onclick = async () => {
            if (btn.dataset.armed !== 'true') {
                btn.dataset.armed = 'true';
                btn.dataset.oldLabel = btn.textContent;
                btn.textContent = 'Confirm?';
                btn.classList.add('ad-armed');
                setTimeout(() => {
                    if (!btn.isConnected) return;
                    btn.dataset.armed = 'false';
                    btn.textContent = btn.dataset.oldLabel || label;
                    btn.classList.remove('ad-armed');
                }, 4000);
                return;
            }
            btn.dataset.armed = 'false';
            btn.classList.remove('ad-armed');
            await onConfirm();
        };
    }

    function open() {
        document.querySelector('#admin-overlay').classList.remove('hidden');
        switchAdTab(adState.tab);
    }

    function close() {
        nui('closeAdmin');
        document.querySelector('#admin-overlay').classList.add('hidden');
    }

    function switchAdTab(tab) {
        adState.tab = tab;
        document.querySelectorAll('#ad-tabs .ad-tab').forEach((el) =>
            el.classList.toggle('active', el.dataset.adtab === tab));

        if (tab === 'overview') renderOverview();
        else if (tab === 'players') renderPlayers();
        else if (tab === 'fleet') renderFleet();
        else if (tab === 'companies') renderCompanies();
        else if (tab === 'control') renderControl();
        else if (tab === 'logs') renderLogs();
    }

    // ── Overview ─────────────────────────────────────────────
    async function renderOverview() {
        body().innerHTML = '<div class="empty-state">Loading...</div>';
        const d = await nui('adminOverview');
        if (!d) { body().innerHTML = '<div class="empty-state">Could not load server stats.</div>'; return; }

        const cards = [
            ['Drivers', d.drivers], ['Deliveries', d.deliveries], ['Total Paid Out', money(d.earned)],
            ['Active Jobs', d.activeJobs], ['Runs (24h)', d.recentRuns], ['Paid (24h)', money(d.recentPaid)],
            ['Vehicles Owned', d.vehicles], ['Out On Dispatch', d.dispatched],
            ['Avg Condition', d.avgCondition + '%'], ['Companies', d.companies],
            ['Company Treasuries', money(d.treasury)], ['Highest Rank', d.topLevel],
        ].map(([label, value]) =>
            `<div class="ad-stat"><div class="ad-stat-label">${esc(label)}</div><div class="ad-stat-value">${esc(value)}</div></div>`
        ).join('');

        const top = (d.topEarners || []).map((r, i) => `
            <div class="ad-row">
                <div class="ad-rank">#${i + 1}</div>
                <div class="ad-row-main">${esc(r.name || 'Unknown')}</div>
                <div class="ad-row-meta">Lvl ${r.level} &middot; ${r.total_completed} runs</div>
                <div class="ad-row-value">${money(r.total_earned)}</div>
            </div>`).join('');

        body().innerHTML = `
            <div class="ad-stat-grid">${cards}</div>
            <div class="ad-heading">Top Earners</div>
            ${top || '<div class="empty-state sm">No drivers yet.</div>'}`;
    }

    // ── Players ──────────────────────────────────────────────
    async function renderPlayers() {
        body().innerHTML = `
            <div class="ad-search-bar">
                <input class="ad-input" id="ad-player-search" placeholder="Search name or citizen id… (2+ characters)">
            </div>
            <div id="ad-online-strip"></div>
            <div id="ad-player-results"></div>
            <div id="ad-player-detail"></div>`;

        const input = document.querySelector('#ad-player-search');
        input.oninput = () => {
            clearTimeout(adState.searchTimer);
            // Debounced: this hits the database on every keystroke otherwise.
            adState.searchTimer = setTimeout(() => runSearch(input.value), 250);
        };

        const roster = await nui('adminOnlineRoster');
        const strip = document.querySelector('#ad-online-strip');
        if (roster && roster.length) {
            strip.innerHTML = `<div class="ad-heading">Online Now (${roster.length})</div>
                <div class="ad-chips">${roster.map((p) =>
                    `<span class="ad-chip-btn" data-cid="${esc(p.citizenid)}">${esc(p.name)}</span>`).join('')}</div>`;
            strip.querySelectorAll('.ad-chip-btn').forEach((el) => {
                el.onclick = () => showPlayer(el.dataset.cid);
            });
        } else {
            strip.innerHTML = '<div class="ad-heading">Online Now</div><div class="empty-state sm">Nobody online.</div>';
        }

        if (adState.playerCid) showPlayer(adState.playerCid);
    }

    async function runSearch(query) {
        const results = document.querySelector('#ad-player-results');
        if (!results) return;
        if (!query || query.trim().length < 2) { results.innerHTML = ''; return; }

        const rows = await nui('adminSearchPlayers', { query });
        if (!rows || !rows.length) {
            results.innerHTML = '<div class="empty-state sm">No matching drivers.</div>';
            return;
        }

        results.innerHTML = `<div class="ad-heading">Results</div>` + rows.map((r) => `
            <div class="ad-row ad-clickable" data-cid="${esc(r.citizenid)}">
                <div class="ad-dot ${r.online ? 'on' : ''}"></div>
                <div class="ad-row-main">${esc(r.name || r.citizenid)}</div>
                <div class="ad-row-meta">Lvl ${r.level} &middot; ${r.total_completed} runs &middot; rating ${r.rating}</div>
                <div class="ad-row-value">${money(r.total_earned)}</div>
            </div>`).join('');

        results.querySelectorAll('.ad-clickable').forEach((el) => {
            el.onclick = () => showPlayer(el.dataset.cid);
        });
    }

    async function showPlayer(cid) {
        adState.playerCid = cid;
        const panel = document.querySelector('#ad-player-detail');
        if (!panel) return;
        panel.innerHTML = '<div class="empty-state sm">Loading driver…</div>';

        const d = await nui('adminPlayerDetail', { citizenid: cid });
        if (!d || !d.stats) {
            panel.innerHTML = '<div class="empty-state sm">No trucking record for that player.</div>';
            return;
        }

        const s = d.stats;
        const vehicles = (d.vehicles || []).map((v) => `
            <div class="ad-row">
                <div class="ad-row-main">${esc(v.label || v.model)}</div>
                <div class="ad-row-meta">${esc(v.kind)} &middot; ${v.condition}%${v.company_id ? ' &middot; company' : ''}${v.dispatch_ready_at ? ' &middot; dispatched' : ''}</div>
            </div>`).join('') || '<div class="empty-state sm">No vehicles owned.</div>';

        const recent = (d.recent || []).map((r) => `
            <div class="ad-row">
                <div class="ad-row-main">${esc(r.label)}</div>
                <div class="ad-row-meta">${when(r.ts)} &middot; rating ${r.trip_rating}</div>
                <div class="ad-row-value">${money(r.driver_cut)}</div>
            </div>`).join('') || '<div class="empty-state sm">No deliveries logged.</div>';

        panel.innerHTML = `
            <div class="ad-detail">
                <div class="ad-detail-head">
                    <div>
                        <div class="ad-detail-name">${esc(s.name || cid)}</div>
                        <div class="ad-detail-sub">${esc(cid)}${d.company ? ' &middot; ' + esc(d.company.name) : ''}</div>
                    </div>
                    <div class="ad-detail-stats">
                        <span>Lvl ${s.level}</span><span>${s.xp} XP</span>
                        <span>${s.total_completed} runs</span><span>rating ${s.rating}</span>
                    </div>
                </div>

                <div class="ad-card-grid">
                    <div class="ad-card">
                        <div class="ad-card-title">Progression</div>
                        <div class="ad-field-row">
                            <input class="ad-input" id="ad-lvl" type="number" min="1" max="99" value="${s.level}">
                            <button class="ad-btn" id="ad-set-level">Set Level</button>
                        </div>
                        <div class="ad-field-row">
                            <input class="ad-input" id="ad-xp" type="number" placeholder="e.g. 250 or -100">
                            <button class="ad-btn" id="ad-add-xp">Add XP</button>
                        </div>
                    </div>
                    <div class="ad-card">
                        <div class="ad-card-title">Grant</div>
                        <div class="ad-field-row">
                            <input class="ad-input" id="ad-cash" type="number" min="1" placeholder="Amount">
                            <button class="ad-btn" id="ad-give-cash">Give Cash</button>
                        </div>
                        <div class="ad-note">Player must be online to receive money.</div>
                    </div>
                    <div class="ad-card">
                        <div class="ad-card-title">Moderation</div>
                        <div class="ad-field-row">
                            <button class="ad-btn" id="ad-reset-rating">Reset Driver Rating</button>
                        </div>
                        <div class="ad-field-row">
                            <button class="ad-btn ad-danger" id="ad-clear-job">Clear Active Delivery</button>
                        </div>
                        <div class="ad-note">Clearing a delivery deletes their rig and pays nothing.</div>
                    </div>
                </div>

                <div class="ad-heading">Vehicles</div>${vehicles}
                <div class="ad-heading">Recent Deliveries</div>${recent}
            </div>`;

        const act = async (endpoint, payload, okMsg) => {
            const res = await nui(endpoint, payload);
            if (res && res.ok) { toast(okMsg, 'success'); showPlayer(cid); }
            else toast((res && res.message) || 'Action failed.', 'error');
        };

        document.querySelector('#ad-set-level').onclick = () =>
            act('adminSetLevel', { citizenid: cid, level: Number(document.querySelector('#ad-lvl').value) }, 'Level set.');
        document.querySelector('#ad-add-xp').onclick = () =>
            act('adminAddXp', { citizenid: cid, amount: Number(document.querySelector('#ad-xp').value) }, 'XP adjusted.');
        document.querySelector('#ad-give-cash').onclick = () =>
            act('adminGiveCash', { citizenid: cid, amount: Number(document.querySelector('#ad-cash').value) }, 'Cash granted.');
        document.querySelector('#ad-reset-rating').onclick = () =>
            act('adminResetRating', { citizenid: cid }, 'Rating reset.');

        arm(document.querySelector('#ad-clear-job'), 'Clear Active Delivery', () =>
            act('adminClearJob', { citizenid: cid }, 'Active delivery cleared.'));
    }

    // ── Fleet ────────────────────────────────────────────────
    async function renderFleet() {
        body().innerHTML = `
            <div class="ad-filters">
                ${['all', 'damaged', 'dispatched'].map((f) =>
                    `<span class="ad-filter ${adState.fleetFilter === f ? 'active' : ''}" data-f="${f}">${f}</span>`).join('')}
            </div>
            <div id="ad-fleet-list"><div class="empty-state sm">Loading…</div></div>`;

        document.querySelectorAll('.ad-filter').forEach((el) => {
            el.onclick = () => { adState.fleetFilter = el.dataset.f; renderFleet(); };
        });

        const rows = await nui('adminListFleet', { filter: adState.fleetFilter });
        const list = document.querySelector('#ad-fleet-list');
        if (!rows || !rows.length) { list.innerHTML = '<div class="empty-state sm">No vehicles match.</div>'; return; }

        list.innerHTML = rows.map((v) => `
            <div class="ad-row">
                <div class="ad-row-main">${esc(v.label || v.model)} <span class="ad-muted">#${v.id}</span></div>
                <div class="ad-row-meta">
                    ${esc(v.ownerName)}${v.companyName ? ' &middot; ' + esc(v.companyName) : ''}
                    &middot; ${esc(v.kind)} &middot; ${v.condition}%${v.dispatch_ready_at ? ' &middot; on dispatch' : ''}
                </div>
                <div class="ad-row-actions">
                    <button class="ad-btn sm ad-fix" data-id="${v.id}" ${v.condition >= 100 ? 'disabled' : ''}>Repair</button>
                    <button class="ad-btn sm ad-undispatch" data-id="${v.id}" ${v.dispatch_ready_at ? '' : 'disabled'}>Recall</button>
                    <button class="ad-btn sm ad-danger ad-del" data-id="${v.id}">Delete</button>
                </div>
            </div>`).join('');

        const act = async (endpoint, id, okMsg) => {
            const res = await nui(endpoint, { ownedId: Number(id) });
            if (res && res.ok) { toast(okMsg, 'success'); renderFleet(); }
            else toast((res && res.message) || 'Action failed.', 'error');
        };

        list.querySelectorAll('.ad-fix').forEach((b) =>
            b.onclick = () => act('adminRepairVehicle', b.dataset.id, 'Repaired.'));
        list.querySelectorAll('.ad-undispatch').forEach((b) =>
            b.onclick = () => act('adminClearDispatch', b.dataset.id, 'Dispatch cleared.'));
        list.querySelectorAll('.ad-del').forEach((b) =>
            arm(b, 'Delete', () => act('adminDeleteVehicle', b.dataset.id, 'Vehicle deleted.')));
    }

    // ── Companies ────────────────────────────────────────────
    async function renderCompanies() {
        body().innerHTML = '<div class="empty-state">Loading...</div>';
        const rows = await nui('adminListCompanies');
        if (!rows || !rows.length) {
            body().innerHTML = '<div class="empty-state">No companies founded yet.</div>';
            return;
        }

        body().innerHTML = rows.map((r) => `
            <div class="ad-row">
                <div class="ad-row-main">${esc(r.label)} <span class="ad-muted">#${r.id}</span></div>
                <div class="ad-row-meta">
                    Owner: ${esc(r.ownerName)} &middot; ${r.memberCount} members &middot;
                    ${r.reputation} rep &middot; ${r.total_deliveries} deliveries &middot; ${r.perk_points} perk pts
                </div>
                <div class="ad-row-actions">
                    <input class="ad-input sm ad-treasury" data-id="${r.id}" type="number" min="0" value="${r.bank}">
                    <button class="ad-btn sm ad-set-treasury" data-id="${r.id}">Set Treasury</button>
                    <button class="ad-btn sm ad-danger ad-disband" data-id="${r.id}">Force Disband</button>
                </div>
            </div>`).join('');

        body().querySelectorAll('.ad-set-treasury').forEach((b) => {
            b.onclick = async () => {
                const input = body().querySelector(`.ad-treasury[data-id="${b.dataset.id}"]`);
                const res = await nui('adminSetTreasury', { companyId: Number(b.dataset.id), amount: Number(input.value) });
                if (res && res.ok) { toast('Treasury updated.', 'success'); renderCompanies(); }
                else toast((res && res.message) || 'Could not update treasury.', 'error');
            };
        });

        body().querySelectorAll('.ad-disband').forEach((b) => {
            arm(b, 'Force Disband', async () => {
                const res = await nui('adminDisbandCompany', { companyId: Number(b.dataset.id) });
                if (res && res.ok) { toast('Company disbanded.', 'success'); renderCompanies(); }
                else toast((res && res.message) || 'Could not disband.', 'error');
            });
        });
    }

    // ── Control ──────────────────────────────────────────────
    // Live-tunable settings. Anything not overridden still tracks config.lua
    // and is badged accordingly, so it's always obvious which values the
    // panel owns and which the file still does.
    async function renderControl() {
        body().innerHTML = '<div class="empty-state">Loading...</div>';
        const groups = await nui('adminSettings');
        if (!groups || !groups.length) {
            body().innerHTML = '<div class="empty-state">No tunable settings available.</div>';
            return;
        }

        body().innerHTML = `
            <div class="ad-note ad-note-top">
                Changes apply immediately and persist across restarts. Anything left as
                <span class="ad-badge">config</span> still reads from <code>config.lua</code>;
                Reset returns an overridden value to it.
            </div>` + groups.map((g) => `
            <div class="ad-heading">${esc(g.group)}</div>
            <div class="ad-settings">
                ${g.items.map((it) => `
                    <div class="ad-setting">
                        <div class="ad-setting-info">
                            <div class="ad-setting-label">
                                ${esc(it.label)}
                                <span class="ad-badge ${it.overridden ? 'custom' : ''}">${it.overridden ? 'custom' : 'config'}</span>
                            </div>
                            ${it.help ? `<div class="ad-setting-help">${esc(it.help)}</div>` : ''}
                        </div>
                        <div class="ad-setting-control">
                            ${it.type === 'bool'
                                ? `<button class="ad-toggle ${it.value ? 'on' : ''}" data-key="${esc(it.key)}" data-val="${it.value ? '1' : '0'}">
                                       ${it.value ? 'ON' : 'OFF'}
                                   </button>`
                                : `<span class="ad-affix">${esc(it.prefix || '')}</span>
                                   <input class="ad-input sm ad-setting-input" data-key="${esc(it.key)}"
                                          type="number" value="${it.value}"
                                          ${it.min != null ? `min="${it.min}"` : ''}
                                          ${it.max != null ? `max="${it.max}"` : ''}
                                          step="${it.step || 1}">
                                   <span class="ad-affix">${esc(it.suffix || '')}</span>`}
                            <button class="ad-btn sm ad-reset-setting" data-key="${esc(it.key)}" ${it.overridden ? '' : 'disabled'}>Reset</button>
                        </div>
                    </div>`).join('')}
            </div>`).join('');

        const save = async (key, value) => {
            const res = await nui('adminSetSetting', { key, value });
            if (res && res.ok) { toast('Setting saved.', 'success'); renderControl(); }
            else toast((res && res.message) || 'Could not save setting.', 'error');
        };

        // Commit on blur and on Enter rather than per-keystroke — a change
        // event per digit would write "1", "12", "125" to the database while
        // someone types 1250.
        body().querySelectorAll('.ad-setting-input').forEach((input) => {
            input.onchange = () => save(input.dataset.key, Number(input.value));
            input.onkeydown = (e) => { if (e.key === 'Enter') input.blur(); };
        });

        body().querySelectorAll('.ad-toggle').forEach((btn) => {
            btn.onclick = () => save(btn.dataset.key, btn.dataset.val === '1' ? 'false' : 'true');
        });

        body().querySelectorAll('.ad-reset-setting').forEach((btn) => {
            btn.onclick = async () => {
                const res = await nui('adminResetSetting', { key: btn.dataset.key });
                if (res && res.ok) { toast('Reset to config default.', 'success'); renderControl(); }
                else toast((res && res.message) || 'Could not reset.', 'error');
            };
        });
    }

    // ── Logs ─────────────────────────────────────────────────
    async function renderLogs() {
        body().innerHTML = '<div class="empty-state">Loading...</div>';
        const rows = await nui('adminRecentDeliveries');
        if (!rows || !rows.length) {
            body().innerHTML = '<div class="empty-state">No deliveries logged yet.</div>';
            return;
        }

        body().innerHTML = `<div class="ad-heading">Recent Deliveries</div>` + rows.map((r) => `
            <div class="ad-row">
                <div class="ad-row-main">${esc(r.driver_name)}</div>
                <div class="ad-row-meta">
                    ${esc(r.label)} &middot; ${when(r.ts)} &middot; rating ${r.trip_rating}
                    ${r.spoiled ? ' &middot; <span class="ad-warn">SPOILED</span>' : ''}
                </div>
                <div class="ad-row-value">${money(r.driver_cut)}</div>
            </div>`).join('');
    }

    // ── Bindings ─────────────────────────────────────────────
    document.querySelectorAll('#ad-tabs .ad-tab').forEach((el) => {
        el.onclick = () => switchAdTab(el.dataset.adtab);
    });
    document.querySelector('#admin-close-btn').onclick = close;

    return { open, close, isOpen: () => !document.querySelector('#admin-overlay').classList.contains('hidden') };
})();
