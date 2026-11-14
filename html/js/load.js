/* Live load-test panel.
 *
 * The sparkline engine here is whip_core's vehicle cost overlay (html/js/veh-debug.js), reused
 * rather than rewritten. Both panels answer the same question — WHICH number is moving — and a
 * number only answers that if you can see where it came from. 240 tells you nothing; 240 after a
 * flat 5 tells you everything.
 *
 * Reconfigured for what a load test actually needs:
 *   * three labelled sections, because the dials, the database and the server's own health are
 *     different kinds of fact and an unlabelled divider would leave you guessing
 *   * per-row severity, since here a number can be WRONG rather than merely large — a failed query
 *     or a second of tick drift is not a bigger version of a good result, it is a different one
 */

(function () {
    const root = document.getElementById('load-hud');
    if (!root) return;

    const HISTORY = 60;              // samples per row — 30s at the server's 500ms cadence
    const series = {};

    /* `floor` is the value a sparkline treats as full height until something exceeds it.
     *
     * Without it every line scales to its own maximum, so a row sitting flat at zero draws a
     * full-height bar and reads as alarming. A floor keeps quiet rows quiet and lets a real climb
     * stand out. The numbers below are "what would be unremarkable", not limits. */
    const ROWS = [
        { section: 'Pressure applied' },
        { key: 'phantoms',    label: 'Phantom players',   unit: '',   kind: 'dial', floor: 200 },
        { key: 'extraStats',  label: '  ...x extra stats', unit: '',  kind: 'dial', floor: 20 },
        { key: 'vehicles',    label: 'Vehicles spawned',  unit: '',   kind: 'dial', floor: 50 },
        { key: 'items',       label: 'Ground items',      unit: '',   kind: 'dial', floor: 500 },
        { key: 'containers',  label: 'Containers',        unit: '',   kind: 'dial', floor: 50 },
        { key: 'doors',       label: 'Doors',             unit: '',   kind: 'dial', floor: 50 },
        { key: 'doorToggles', label: '  ...toggled',      unit: '',   kind: 'dial', floor: 500 },
        /* Churn is what makes this a load test rather than a photograph. Standing state measures
         * the cost of HAVING things; a real server is constantly creating and destroying them, and
         * that traffic — inserts, deletes, cache eviction, write-behind movement, broadcasts — is
         * most of what a busy server actually does. */
        { key: 'churned',     label: 'Objects recycled',  unit: '',   kind: 'dial', floor: 500 },
        { key: 'eventsSent',  label: 'Events sent',       unit: '',   kind: 'dial', floor: 1000 },

        { section: 'Database burst' },
        /* PEAK since the last update, not the live figure. A burst drains in far less than the
         * 500ms reporting interval, so the instantaneous value reads 0 almost always and the
         * saturation worth seeing never appears on screen. */
        { key: 'dbInFlight', label: 'Peak in flight',   unit: '',     kind: 'rate', floor: 50,
          warn: 50, hot: 150 },
        { key: 'dbP50',      label: 'p50 latency',       unit: 'ms',   kind: 'key',  floor: 50,
          warn: 100, hot: 500 },
        { key: 'dbP95',      label: 'p95 latency',       unit: 'ms',   kind: 'key',  floor: 50,
          warn: 100, hot: 500 },
        { key: 'dbP99',      label: 'p99 latency',       unit: 'ms',   kind: 'key',  floor: 50,
          warn: 100, hot: 500 },
        { key: 'dbFailed',   label: '  ...failed',       unit: '',     kind: 'rate', floor: 10,
          warn: 1, hot: 1 },

        { section: 'Server health' },
        /* Tick drift, measured against a CALIBRATED floor rather than the 100ms the loop asks for.
         * A Wait cannot return early — the server ticks on a fixed interval and the sleep resumes
         * on the next boundary — so on a 20-tick server every reading used to carry a constant
         * +50ms that looked like strain and was pure arithmetic. The run now samples that floor
         * before applying load, so 0 genuinely means keeping up.
         *
         * Past 2500ms the run aborts itself rather than making things worse. */
        { key: 'driftMs',    label: 'Tick drift',        unit: 'ms',   kind: 'key',  floor: 250,
          warn: 250, hot: 1000 },
        // whip_test's own Lua state (collectgarbage there), not whip_core's or the server's: hence the label.
        { key: 'ramMb',      label: 'whip_test Lua memory', unit: 'MB', kind: 'rate', floor: 200 },
    ];

    let built = false;
    const cells = {};

    function build() {
        root.innerHTML = '';

        const head = document.createElement('div');
        head.className = 'lt-head';

        const title = document.createElement('div');
        title.className = 'lt-title';
        title.textContent = 'Load test';
        head.appendChild(title);

        const elapsed = document.createElement('div');
        elapsed.className = 'lt-speed';       // same treatment as the overlay's speed readout
        elapsed.textContent = '—';
        head.appendChild(elapsed);
        cells.__elapsed = elapsed;

        root.appendChild(head);

        /* ONE GRID FOR EVERY ROW, not a grid per row. The columns have to line up down the panel
         * while the label column sizes itself to the widest label — a per-row grid cannot do both,
         * and a fixed label column clips the longest name. */
        const grid = document.createElement('div');
        grid.className = 'lt-grid';
        root.appendChild(grid);

        let first = true;
        for (const row of ROWS) {
            if (row.section) {
                if (!first) {
                    const rule = document.createElement('div');
                    rule.className = 'lt-rule';
                    grid.appendChild(rule);
                }
                const cap = document.createElement('div');
                cap.className = 'lt-section';
                cap.textContent = row.section;
                grid.appendChild(cap);
                first = false;
                continue;
            }
            first = false;

            const label = document.createElement('span');
            label.className = 'lt-label lt-' + row.kind;
            label.textContent = row.label;

            const spark = document.createElement('canvas');
            spark.className = 'lt-spark';
            spark.width = 120;
            spark.height = 18;

            const value = document.createElement('span');
            value.className = 'lt-value lt-' + row.kind;
            value.textContent = '—';

            const unit = document.createElement('span');
            unit.className = 'lt-unit';
            unit.textContent = row.unit;

            grid.appendChild(label);
            grid.appendChild(spark);
            grid.appendChild(value);
            grid.appendChild(unit);

            cells[row.key] = { value: value, spark: spark, label: label };
            series[row.key] = [];
        }

        const foot = document.createElement('div');
        foot.className = 'lt-foot';
        foot.textContent = '/testloadstop — also works from the server console.';
        root.appendChild(foot);

        built = true;
    }

    /* A sparkline scaled to its own recent maximum OR its floor, whichever is larger. Per-row
     * rather than shared, because each row measures a different quantity and one scale would
     * flatten everything but the busiest. */
    function drawSpark(canvas, values, colour, floor) {
        const ctx = canvas.getContext('2d');
        const w = canvas.width, h = canvas.height;
        ctx.clearRect(0, 0, w, h);
        if (values.length < 2) return;

        let max = floor || 1;
        for (const v of values) if (v > max) max = v;
        if (max <= 0) max = 1;

        const step = w / (HISTORY - 1);
        const y = v => h - 1 - (v / max) * (h - 2);

        // Area fill first, line on top — the fill makes a low line readable at this size.
        ctx.beginPath();
        ctx.moveTo(0, h);
        values.forEach((v, i) => ctx.lineTo(i * step, y(v)));
        ctx.lineTo((values.length - 1) * step, h);
        ctx.closePath();
        ctx.fillStyle = colour + '22';
        ctx.fill();

        ctx.beginPath();
        values.forEach((v, i) => (i === 0 ? ctx.moveTo(0, y(v)) : ctx.lineTo(i * step, y(v))));
        ctx.strokeStyle = colour;
        ctx.lineWidth = 1.5;
        ctx.stroke();
    }

    function severity(row, v) {
        if (row.hot !== undefined && v >= row.hot) return 'hot';
        if (row.warn !== undefined && v >= row.warn) return 'warn';
        return null;
    }

    function fmt(v, unit) {
        if (v === undefined || v === null) return '—';
        if (unit === 'ms') return v >= 100 ? String(Math.round(v)) : v.toFixed(1);
        return String(Math.round(v));
    }

    function elapsedText(s) {
        if (s === undefined || s === null) return '—';
        const m = Math.floor(s / 60);
        return m > 0 ? m + 'm ' + (s % 60) + 's' : s + 's';
    }

    function renderLoad(data) {
        if (!built) build();
        if (!data) return;

        cells.__elapsed.textContent = elapsedText(data.elapsed);

        for (const row of ROWS) {
            if (row.section) continue;

            const v = Number(data[row.key]) || 0;
            const s = series[row.key];
            s.push(v);
            while (s.length > HISTORY) s.shift();

            const cell = cells[row.key];
            cell.value.textContent = fmt(v, row.unit);

            const sev = severity(row, v);

            // Colour by meaning: a dial is a setting, a finding is a finding.
            let colour = '#60a5fa';
            if (row.kind === 'dial') colour = '#818cf8';
            if (sev === 'warn') colour = '#fbbf24';
            if (sev === 'hot')  colour = '#f87171';

            drawSpark(cell.spark, s, colour, row.floor);

            cell.value.classList.toggle('lt-warn', sev === 'warn');
            cell.value.classList.toggle('lt-hot',  sev === 'hot');
            // Zero failures is worth stating positively — it is the row you most want to be boring.
            cell.value.classList.toggle('lt-good', row.key === 'dbFailed' && v === 0);
        }
    }

    /* Start a run with nothing carried over from the last one.
     *
     * CLEARING THE CANVASES MATTERS AS MUCH AS CLEARING THE ARRAYS, which is not obvious and was
     * caught by the harness rather than by reading the code. Emptying `series` only stops OLD data
     * being replotted — the pixels already drawn stay on screen until the next update repaints
     * them half a second later. For half a second a fresh run would show the previous run's shape,
     * which on a panel whose whole job is "watch which line moves" is worse than showing nothing.
     */
    function resetSeries() {
        for (const k in series) {
            series[k] = [];
            const cell = cells[k];
            if (cell && cell.spark) {
                const ctx = cell.spark.getContext('2d');
                ctx.clearRect(0, 0, cell.spark.width, cell.spark.height);
            }
            if (cell && cell.value) {
                cell.value.textContent = '—';
                cell.value.classList.remove('lt-warn', 'lt-hot', 'lt-good');
            }
        }
        if (cells.__elapsed) cells.__elapsed.textContent = '—';
    }

    function showLoad() {
        if (!built) build();
        root.classList.add('visible');
    }

    function hideLoad() {
        root.classList.remove('visible');
    }

    window.addEventListener('message', function (e) {
        if (!e.data) return;
        if (e.data.action === 'loadStart') {
            resetSeries();
            showLoad();
        } else if (e.data.action === 'loadUpdate') {
            renderLoad(e.data.data);
        } else if (e.data.action === 'loadStop') {
            hideLoad();
        }
    });

    // Exposed for the headless harness, which drives these directly rather than posting messages.
    window.renderLoad = renderLoad;
    window.showLoad   = showLoad;
    window.hideLoad   = hideLoad;
})();
