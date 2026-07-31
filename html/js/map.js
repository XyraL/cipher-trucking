// ─────────────────────────────────────────────────────────────
// Route Map
// A hand-authored, stylized vector rendering of the Los Santos basin —
// deliberately NOT a screenshot of the game map. Reasons: it ships as pure
// SVG (no image asset in the repo, nothing to keep in sync with a game
// update), it scales to any panel size without resampling, and it can be
// coloured from the same CSS custom properties as the rest of the dashboard
// so the map reads as part of the UI rather than pasted into it.
//
// The land outline is an approximation tuned so the real contract
// coordinates in config.lua land in visually plausible districts — the port
// contracts sit on the southern shoreline, the airport to their west,
// Vinewood up north. It is a planning diagram, not a survey.
// ─────────────────────────────────────────────────────────────
const CipherMap = (() => {
    // World rectangle this map covers. Everything cipher-trucking ships
    // sits inside the Los Santos basin, so the projection is bounded to the
    // city rather than the full -4000..8000 world — otherwise every pin
    // would cluster into one corner of a mostly-empty canvas.
    const BOUNDS = { minX: -2400, maxX: 1800, minY: -3800, maxY: 1400 };

    // SVG user units. Chosen so 1 unit == 10 game metres, which makes the
    // projection maths trivial to eyeball when adjusting the artwork.
    const W = 420;
    const H = 520;

    // GTA's Y axis increases northward; SVG's increases downward. The Y term
    // is therefore inverted, not just scaled.
    function project(x, y) {
        return {
            x: ((x - BOUNDS.minX) / (BOUNDS.maxX - BOUNDS.minX)) * W,
            y: ((BOUNDS.maxY - y) / (BOUNDS.maxY - BOUNDS.minY)) * H,
        };
    }

    function escAttr(v) {
        if (v == null) return '';
        return String(v).replace(/&/g, '&amp;').replace(/</g, '&lt;')
            .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }

    // Coastline. West edge runs down the Pacific side, bulges out around
    // Vespucci, then the southern shore sweeps east past the airport to the
    // port. North of the frame is inland, so the path simply closes along
    // the top.
    const LAND_PATH = [
        'M 55,0', 'L 420,0', 'L 420,452',
        'L 398,460', 'L 372,472', 'L 348,466', 'L 322,458',
        'L 298,452', 'L 274,459', 'L 250,451', 'L 226,447',
        'L 202,452', 'L 178,446', 'L 154,453', 'L 132,444',
        'L 118,424', 'L 108,398', 'L 101,368', 'L 96,338',
        'L 104,308', 'L 114,278', 'L 110,248', 'L 100,216',
        'L 89,184', 'L 77,150', 'L 68,114', 'L 61,74', 'L 55,36', 'Z',
    ].join(' ');

    // Elysian-style port island off the southern shore, kept separate from
    // the mainland path so it reads as an island.
    const ISLAND_PATH = 'M 336,478 L 366,474 L 384,486 L 372,500 L 344,498 Z';

    const HIGHWAYS = [
        // Great Ocean Highway, hugging the west coast.
        '78,108 98,206 112,286 122,364 146,442',
        // Southern cross-town route, airport out to the port.
        '146,442 202,424 252,404 274,344',
        // Del Perro / Downtown spine running north.
        '274,344 268,262 258,192 272,112',
        // Eastern freeway.
        '362,458 342,382 332,302 342,212 356,122',
        // East-west connector.
        '252,404 332,392',
    ];

    const DISTRICTS = [
        { x: 270, y: 78, name: 'VINEWOOD' },
        { x: 358, y: 52, name: 'TONGVA' },
        { x: 250, y: 212, name: 'DOWNTOWN' },
        { x: 350, y: 190, name: 'MIRROR PARK' },
        { x: 124, y: 292, name: 'VESPUCCI' },
        { x: 322, y: 282, name: 'LA MESA' },
        { x: 136, y: 418, name: 'LSIA' },
        { x: 292, y: 432, name: 'PORT' },
    ];

    function baseMarkup() {
        const grid = [];
        for (let gx = 0; gx <= W; gx += 30) {
            grid.push(`<line x1="${gx}" y1="0" x2="${gx}" y2="${H}" class="map-grid-line"/>`);
        }
        for (let gy = 0; gy <= H; gy += 30) {
            grid.push(`<line x1="0" y1="${gy}" x2="${W}" y2="${gy}" class="map-grid-line"/>`);
        }

        const highways = HIGHWAYS.map((pts) =>
            `<polyline points="${pts}" class="map-highway"/>`).join('');

        const districts = DISTRICTS.map((d) =>
            `<text x="${d.x}" y="${d.y}" class="map-district">${d.name}</text>`).join('');

        return `
        <svg id="map-svg" viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMid meet">
            <defs>
                <linearGradient id="map-land-grad" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stop-color="#232833"/>
                    <stop offset="100%" stop-color="#1a1e26"/>
                </linearGradient>
                <filter id="map-pin-glow" x="-80%" y="-80%" width="260%" height="260%">
                    <feGaussianBlur stdDeviation="2.6" result="b"/>
                    <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
                </filter>
                <filter id="map-route-glow" x="-30%" y="-30%" width="160%" height="160%">
                    <feGaussianBlur stdDeviation="1.8" result="b"/>
                    <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
                </filter>
            </defs>

            <rect x="0" y="0" width="${W}" height="${H}" class="map-ocean"/>
            <g class="map-grid">${grid.join('')}</g>

            <path d="${LAND_PATH}" class="map-land"/>
            <path d="${ISLAND_PATH}" class="map-land"/>
            <path d="${LAND_PATH}" class="map-coast"/>
            <path d="${ISLAND_PATH}" class="map-coast"/>

            <g class="map-highways">${highways}</g>
            <g class="map-districts">${districts}</g>

            <g id="map-routes"></g>
            <g id="map-pins"></g>
            <g id="map-player"></g>
        </svg>
        <div id="map-tooltip" class="hidden"></div>
        <div id="map-zoom">
            <button class="map-zoom-btn" data-zoom="in">+</button>
            <button class="map-zoom-btn" data-zoom="out">&minus;</button>
            <button class="map-zoom-btn" data-zoom="reset">&#9678;</button>
        </div>`;
    }

    // ── Zoom / pan ───────────────────────────────────────────
    // Implemented by moving the viewBox rather than a CSS transform, so
    // stroke widths and font sizes scale with the artwork instead of the
    // whole thing turning into a blurry enlargement.
    const view = { x: 0, y: 0, w: W, h: H };
    const MIN_W = W / 6;   // deepest zoom
    const MAX_W = W;       // fully zoomed out

    function applyView(svg) {
        svg.setAttribute('viewBox', `${view.x} ${view.y} ${view.w} ${view.h}`);
    }

    function clampView() {
        view.w = Math.max(MIN_W, Math.min(MAX_W, view.w));
        view.h = view.w * (H / W);
        // Keep the viewport inside the artwork so you can't pan into a void.
        view.x = Math.max(0, Math.min(W - view.w, view.x));
        view.y = Math.max(0, Math.min(H - view.h, view.y));
    }

    function zoomAt(svg, factor, cx, cy) {
        const prevW = view.w;
        view.w = Math.max(MIN_W, Math.min(MAX_W, view.w * factor));
        view.h = view.w * (H / W);
        // Anchor the zoom on the cursor: keep whatever was under it in place.
        const ratio = 1 - view.w / prevW;
        view.x += (cx - view.x) * ratio;
        view.y += (cy - view.y) * ratio;
        clampView();
        applyView(svg);
    }

    function resetView(svg) {
        view.x = 0; view.y = 0; view.w = W; view.h = H;
        applyView(svg);
    }

    // Converts a mouse position on the rendered SVG into artwork
    // coordinates, accounting for the letterboxing that preserveAspectRatio
    // introduces when the panel isn't the same aspect as the viewBox.
    function toArtwork(svg, clientX, clientY) {
        const r = svg.getBoundingClientRect();
        const scale = Math.min(r.width / view.w, r.height / view.h);
        const offX = (r.width - view.w * scale) / 2;
        const offY = (r.height - view.h * scale) / 2;
        return {
            x: view.x + (clientX - r.left - offX) / scale,
            y: view.y + (clientY - r.top - offY) / scale,
        };
    }

    function bindViewControls(root) {
        const svg = root.querySelector('#map-svg');
        if (!svg || svg.dataset.viewBound === 'true') return;
        svg.dataset.viewBound = 'true';

        svg.addEventListener('wheel', (e) => {
            e.preventDefault();
            const p = toArtwork(svg, e.clientX, e.clientY);
            zoomAt(svg, e.deltaY > 0 ? 1.18 : 0.85, p.x, p.y);
        }, { passive: false });

        let dragging = false, last = null;
        svg.addEventListener('mousedown', (e) => {
            dragging = true;
            last = { x: e.clientX, y: e.clientY };
            svg.classList.add('dragging');
        });
        window.addEventListener('mouseup', () => {
            dragging = false;
            svg.classList.remove('dragging');
        });
        svg.addEventListener('mousemove', (e) => {
            if (!dragging || !last) return;
            const r = svg.getBoundingClientRect();
            const scale = Math.min(r.width / view.w, r.height / view.h);
            view.x -= (e.clientX - last.x) / scale;
            view.y -= (e.clientY - last.y) / scale;
            last = { x: e.clientX, y: e.clientY };
            clampView();
            applyView(svg);
        });

        root.querySelectorAll('.map-zoom-btn').forEach((btn) => {
            btn.onclick = () => {
                const mode = btn.dataset.zoom;
                if (mode === 'reset') return resetView(svg);
                zoomAt(svg, mode === 'in' ? 0.7 : 1.4, view.x + view.w / 2, view.y + view.h / 2);
            };
        });

        applyView(svg);
    }

    // ── Dynamic layers ───────────────────────────────────────
    // Routes and pins are rebuilt wholesale on every update rather than
    // diffed. The board is at most a couple of dozen nodes, and a full
    // rebuild removes any chance of a stale pin surviving a state change.

    function routeMarkup(contract, depot) {
        if (!contract || !contract.stops || !contract.stops.length) return '';

        const points = [];
        if (depot) points.push(project(depot.x, depot.y));
        contract.stops.forEach((s) => points.push(project(s.x, s.y)));
        if (depot) points.push(project(depot.x, depot.y));

        const d = points.map((p, i) =>
            `${i === 0 ? 'M' : 'L'} ${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(' ');

        // Two stacked strokes: a soft wide halo under a crisp dashed line.
        return `
            <path d="${d}" class="map-route-halo"/>
            <path d="${d}" class="map-route"/>`;
    }

    function pinMarkup(contract, index, selected) {
        if (!contract.stops || !contract.stops.length) return '';

        return contract.stops.map((stop, si) => {
            const p = project(stop.x, stop.y);
            const cls = [
                'map-pin',
                contract.hot ? 'hot' : '',
                contract.unlocked ? '' : 'locked',
                selected ? 'selected' : '',
            ].filter(Boolean).join(' ');

            // Multi-stop contracts number their pins so the running order is
            // readable straight off the map.
            const badge = contract.stops.length > 1
                ? `<text x="${p.x}" y="${p.y + 1.4}" class="map-pin-index">${si + 1}</text>`
                : '';

            return `
            <g class="${cls}" data-contract="${escAttr(contract.id)}" transform="translate(0,0)">
                <circle cx="${p.x}" cy="${p.y}" r="9" class="map-pin-hit"/>
                <circle cx="${p.x}" cy="${p.y}" r="5.2" class="map-pin-ring"/>
                <circle cx="${p.x}" cy="${p.y}" r="2.4" class="map-pin-core"/>
                ${badge}
            </g>`;
        }).join('');
    }

    // ── Active job overlay ───────────────────────────────────
    // Drawn on top of the planning view with its own visual language: a
    // solid line rather than the dashed planning route, segments already
    // driven dimmed out, and the stop you're currently heading for pulsing.
    // The point is that a glance tells you where you are in the run.
    function activeRouteMarkup(job, depot) {
        if (!job || !job.stops || !job.stops.length) return '';

        const nodes = [];
        if (job.trailerSpawn) nodes.push({ p: project(job.trailerSpawn.x, job.trailerSpawn.y), kind: 'start' });
        job.stops.forEach((s, i) => nodes.push({ p: project(s.x, s.y), kind: 'stop', index: i }));
        const home = job.truckSpawn || depot;
        if (home) nodes.push({ p: project(home.x, home.y), kind: 'end' });

        // stopIndex is 1-based; anything before it is delivered.
        const doneThrough = Math.max(0, (job.stopIndex || 1) - 1);

        let segments = '';
        for (let i = 0; i < nodes.length - 1; i++) {
            const a = nodes[i].p, b = nodes[i + 1].p;
            // A segment counts as travelled once its destination stop is
            // behind us; the leg home only lights up on the return stage.
            const nextNode = nodes[i + 1];
            let done = false;
            if (nextNode.kind === 'stop') done = nextNode.index < doneThrough;
            else if (nextNode.kind === 'end') done = job.stage === 'return';

            segments += `<path d="M ${a.x.toFixed(1)},${a.y.toFixed(1)} L ${b.x.toFixed(1)},${b.y.toFixed(1)}"
                class="map-active-seg ${done ? 'done' : ''}"/>`;
        }
        return segments;
    }

    function activeStopsMarkup(job) {
        if (!job || !job.stops || !job.stops.length) return '';
        const currentIdx = (job.stopIndex || 1) - 1;

        return job.stops.map((s, i) => {
            const p = project(s.x, s.y);
            let cls = 'pending';
            if (i < currentIdx) cls = 'done';
            else if (i === currentIdx && job.stage !== 'return') cls = 'current';

            return `
            <g class="map-active-stop ${cls}">
                ${cls === 'current' ? `<circle cx="${p.x}" cy="${p.y}" r="7" class="map-active-pulse"/>` : ''}
                <circle cx="${p.x}" cy="${p.y}" r="5.4" class="map-active-ring"/>
                <text x="${p.x}" y="${p.y + 1.9}" class="map-active-index">${cls === 'done' ? '✓' : i + 1}</text>
            </g>`;
        }).join('');
    }

    // Fuel stations. Deliberately understated — a small ringed dot rather
    // than a numbered pin, so they read as map furniture you can find when
    // you need them instead of competing with the contract pins.
    function stationMarkup(stations) {
        if (!stations || !stations.length) return '';
        return stations.map((s) => {
            const c = s.coords || s;
            const p = project(c.x, c.y);
            return `
            <g class="map-station" data-station="${escAttr(s.label || 'Fuel')}">
                <circle cx="${p.x}" cy="${p.y}" r="4.2" class="map-station-ring"/>
                <text x="${p.x}" y="${p.y + 1.6}" class="map-station-icon">⛽</text>
            </g>`;
        }).join('');
    }

    function depotMarkup(depot) {
        if (!depot) return '';
        const p = project(depot.x, depot.y);
        return `
        <g class="map-depot">
            <rect x="${p.x - 5}" y="${p.y - 5}" width="10" height="10" class="map-depot-box"/>
            <circle cx="${p.x}" cy="${p.y}" r="1.8" class="map-depot-core"/>
            <text x="${p.x}" y="${p.y - 9}" class="map-depot-label">DEPOT</text>
        </g>`;
    }

    function playerMarkup(player) {
        if (!player) return '';
        const p = project(player.x, player.y);
        // Heading is clockwise-from-north in game; the triangle is drawn
        // pointing up, so the rotation maps across directly.
        return `
        <g class="map-player-marker" transform="translate(${p.x.toFixed(1)},${p.y.toFixed(1)})">
            <circle r="10" class="map-player-pulse"/>
            <g transform="rotate(${(player.heading || 0).toFixed(0)})">
                <path d="M 0,-5.5 L 3.6,4 L 0,2 L -3.6,4 Z" class="map-player-arrow"/>
            </g>
        </g>`;
    }

    // `state` = { contracts, selectedId, depot, player, activeJob, onSelect }
    function update(root, state) {
        const svg = root.querySelector('#map-svg');
        if (!svg) return;

        const routes = svg.querySelector('#map-routes');
        const pins = svg.querySelector('#map-pins');
        const playerLayer = svg.querySelector('#map-player');

        const selected = (state.contracts || []).find((c) => c.id === state.selectedId);
        const job = state.activeJob;

        // While a run is live its route takes over — drawing the planning
        // route underneath it as well would just be two overlapping lines
        // saying different things.
        routes.innerHTML = job
            ? activeRouteMarkup(job, state.depot)
            : routeMarkup(selected, state.depot);

        pins.innerHTML = stationMarkup(state.stations)
            + depotMarkup(state.depot)
            + (state.contracts || []).map((c, i) => pinMarkup(c, i, c.id === state.selectedId)).join('')
            + activeStopsMarkup(job);

        playerLayer.innerHTML = playerMarkup(state.player);

        bindViewControls(root);
        bindTooltips(root, state);

        if (typeof state.onSelect === 'function') {
            pins.querySelectorAll('.map-pin').forEach((el) => {
                el.onclick = () => state.onSelect(el.dataset.contract);
            });
        }
    }

    function bindTooltips(root, state) {
        const tip = root.querySelector('#map-tooltip');
        if (!tip) return;

        const byId = {};
        (state.contracts || []).forEach((c) => { byId[c.id] = c; });

        root.querySelectorAll('.map-pin').forEach((el) => {
            el.onmouseenter = (e) => {
                const c = byId[el.dataset.contract];
                if (!c) return;
                const bits = [
                    `<strong>${escAttr(c.label)}</strong>`,
                    `$${Number(c.payout).toLocaleString()} · +${c.xp} XP`,
                    c.stopCount > 1 ? `${c.stopCount} stops` : '1 stop',
                ];
                if (!c.unlocked) {
                    bits.push(!c.levelOk
                        ? `<em>Locked — Rank ${c.minLevel}</em>`
                        : `<em>Needs a ${escAttr(c.requiredTrailerType)} trailer</em>`);
                }
                tip.innerHTML = bits.join('<br>');
                tip.classList.remove('hidden');
                moveTip(root, tip, e);
            };
            el.onmousemove = (e) => moveTip(root, tip, e);
            el.onmouseleave = () => tip.classList.add('hidden');
        });
    }

    // Positioned relative to the map panel, and flipped to the other side of
    // the cursor near the right/bottom edges so it never spills outside.
    function moveTip(root, tip, e) {
        const r = root.getBoundingClientRect();
        let x = e.clientX - r.left + 14;
        let y = e.clientY - r.top + 14;
        if (x + tip.offsetWidth > r.width - 8) x = e.clientX - r.left - tip.offsetWidth - 14;
        if (y + tip.offsetHeight > r.height - 8) y = e.clientY - r.top - tip.offsetHeight - 14;
        tip.style.left = `${Math.max(4, x)}px`;
        tip.style.top = `${Math.max(4, y)}px`;
    }

    // Player position arrives on its own 500ms tick, independent of board
    // refreshes — repainting only that layer avoids tearing down pin click
    // handlers twice a second.
    function updatePlayerOnly(root, player) {
        const layer = root.querySelector('#map-player');
        if (layer) layer.innerHTML = playerMarkup(player);
    }

    return { project, baseMarkup, update, updatePlayerOnly, resetView, BOUNDS, W, H };
})();
