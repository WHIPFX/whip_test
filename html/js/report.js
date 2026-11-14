// Resolution scaling (same pattern as whip_core)
(function() {
    var s = window.innerHeight / 1440;
    document.documentElement.style.setProperty('--ui-scale', s);
})();

window.addEventListener('message', function(e) {
    if (e.data.action === 'showReport') {
        renderReport(e.data.data);
    } else if (e.data.action === 'enduranceStart') {
        document.getElementById('endurance-hud').classList.remove('hidden');
        document.getElementById('endurance-stats').innerHTML = '<span style="color:#8b949e">Starting...</span>';
        document.getElementById('endurance-systems').innerHTML = '';
    } else if (e.data.action === 'enduranceStop') {
        document.getElementById('endurance-hud').classList.add('hidden');
    } else if (e.data.action === 'enduranceUpdate') {
        renderEndurance(e.data.data);
    }
    // loadStart / loadUpdate / loadStop are handled by js/load.js, which owns its own panel and
    // its own stylesheet. Kept separate because it is whip_core's overlay language, not this
    // resource's report styling, and mixing the two would leave neither coherent.
});

// Only when the report is actually up: the /test menu shares this page and handles its own Escape,
// and closing a hidden report would take the cursor away from an open menu.
document.addEventListener('keydown', function(e) {
    if (e.key !== 'Escape') return;
    if (!document.getElementById('report-overlay').classList.contains('hidden')) closeReport();
});

function closeReport() {
    document.getElementById('report-overlay').classList.add('hidden');
    fetch('https://whip_test/closeReport', { method: 'POST', body: '{}' });
}

// Back to the section cards. The report closes first (and gives the cursor back), so a menu the
// server refuses to open never leaves the cursor stuck on an empty screen.
function backToMenu() {
    closeReport();
    fetch('https://whip_test/openMenu', { method: 'POST', body: '{}' });
}

function renderReport(data) {
    _lastReportData = data;
    var overlay = document.getElementById('report-overlay');
    overlay.classList.remove('hidden');

    // Says what was tested — a section, or the full suite.
    document.querySelector('#report-header h1').textContent = data.title || 'whip_core Test Report';

    // Summary
    var summary = document.getElementById('report-summary');
    var html = '';
    html += '<span class="stat-passed">' + data.passed + ' passed</span>';
    html += '<span class="stat-failed">' + data.failed + ' failed</span>';
    // A skip is a test declaring its preconditions unmet, not a defect. The server has always
    // sent this as its own count; rendering it as a failure made a green run look broken and,
    // worse, buried a real failure among rows that were never going to run.
    if (data.skipped) {
        html += '<span class="stat-skipped">' + data.skipped + ' skipped</span>';
    }
    html += '<span class="stat-time">' + (data.totalTime / 1000).toFixed(1) + 's</span>';
    if (data.partial) {
        html += '<span class="stat-partial">PARTIAL (stopped)</span>';
    }
    summary.innerHTML = html;

    // Group by category
    var categories = {};
    var categoryOrder = [];
    for (var i = 0; i < data.results.length; i++) {
        var r = data.results[i];
        if (!categories[r.category]) {
            categories[r.category] = { tests: [], passed: 0, failed: 0, skipped: 0 };
            categoryOrder.push(r.category);
        }
        categories[r.category].tests.push(r);
        if (r.passed) categories[r.category].passed++;
        else if (r.skipped) categories[r.category].skipped++;
        else categories[r.category].failed++;
    }

    // Render
    var body = document.getElementById('report-body');
    html = '';
    for (var c = 0; c < categoryOrder.length; c++) {
        var catName = categoryOrder[c];
        var cat = categories[catName];
        var hasFail = cat.failed > 0;
        var expanded = hasFail ? ' expanded' : '';

        html += '<div class="category' + expanded + '">';
        html += '<div class="category-header" onclick="toggleCategory(this)">';
        html += '<span class="category-arrow">▶</span>';
        html += '<span class="category-name">' + esc(catName) + '</span>';
        html += '<span class="category-count">' + cat.passed + '/' + (cat.passed + cat.failed + cat.skipped) + '</span>';
        html += '<span class="category-badge ' + (hasFail ? 'badge-fail' : 'badge-pass') + '">';
        html += hasFail ? 'FAIL' : 'PASS';
        html += '</span>';
        html += '</div>';
        html += '<div class="category-tests">';

        for (var t = 0; t < cat.tests.length; t++) {
            var test = cat.tests[t];
            var cls = test.passed ? 'test-pass' : (test.skipped ? 'test-skip' : 'test-fail');
            var icon = test.passed ? '✓' : (test.skipped ? '−' : '✗');
            var sideClass = test.side === 'server' ? 'side-server' : 'side-client';

            html += '<div class="test-row ' + cls + '">';
            html += '<span class="test-icon">' + icon + '</span>';
            html += '<span class="test-name">' + esc(test.name) + '</span>';
            html += '<span class="test-side ' + sideClass + '">' + test.side + '</span>';
            html += '<span class="test-duration">' + test.duration + 'ms</span>';
            html += '</div>';

            if (!test.passed && test.error) {
                html += '<div class="test-error">' + esc(test.error) + '</div>';
            }
        }

        html += '</div></div>';
    }
    body.innerHTML = html;
}

var _lastReportData = null;

function copyFailures() {
    if (!_lastReportData) return;
    var lines = [];
    var head = _lastReportData.passed + ' passed, ' + _lastReportData.failed + ' failed';
    if (_lastReportData.skipped) head += ', ' + _lastReportData.skipped + ' skipped';
    lines.push(head + ', ' + (_lastReportData.totalTime / 1000).toFixed(1) + 's');
    lines.push('');
    for (var i = 0; i < _lastReportData.results.length; i++) {
        var r = _lastReportData.results[i];
        if (r.passed) continue;
        lines.push((r.skipped ? 'SKIPPED — ' : '') + r.category + ': ' + r.name +
                   ' [' + r.side + ' ' + r.duration + 'ms]');
        if (r.error) lines.push('  ' + r.error);
    }
    if (lines.length <= 2) {
        lines.push('(no failures)');
    }
    var text = lines.join('\n');
    try {
        navigator.clipboard.writeText(text).then(function() {
            var btn = document.getElementById('btn-copy');
            btn.textContent = 'Copied!';
            setTimeout(function() { btn.textContent = 'Copy Failures'; }, 1500);
        }).catch(function() { fallbackCopy(text); });
    } catch(e) { fallbackCopy(text); }
}

function formatTime(seconds) {
    var m = Math.floor(seconds / 60);
    var s = seconds % 60;
    if (m > 0) return m + 'm ' + s + 's';
    return s + 's';
}

function renderEndurance(d) {
    // Stats row
    var ramClass = d.ramDeltaMB > 50 ? 'bad' : d.ramDeltaMB > 20 ? 'warn' : 'ok';
    var errClass = d.totalErrors > 0 ? 'bad' : 'ok';

    var html = '';
    html += '<div class="e-stat"><span class="e-stat-value">' + formatTime(d.elapsed) + '</span><span class="e-stat-label">elapsed</span></div>';
    html += '<div class="e-stat"><span class="e-stat-value">' + d.totalCycles + '</span><span class="e-stat-label">cycles</span></div>';
    html += '<div class="e-stat"><span class="e-stat-value ' + errClass + '">' + d.totalErrors + '</span><span class="e-stat-label">errors</span></div>';
    html += '<div class="e-stat"><span class="e-stat-value ' + ramClass + '">' + d.ramMB + '</span><span class="e-stat-label">RAM MB</span></div>';
    html += '<div class="e-stat"><span class="e-stat-value ' + ramClass + '">' + (d.ramDeltaMB >= 0 ? '+' : '') + d.ramDeltaMB + '</span><span class="e-stat-label">delta MB</span></div>';
    document.getElementById('endurance-stats').innerHTML = html;

    // Per-system rows
    html = '';
    for (var i = 0; i < d.systems.length; i++) {
        var sys = d.systems[i];
        var eClass = sys.errors > 0 ? 'dirty' : 'clean';
        html += '<div class="e-sys-row">';
        html += '<span class="e-sys-name">' + sys.name + '</span>';
        html += '<span class="e-sys-cycles">' + sys.cycles + '</span>';
        html += '<span class="e-sys-avg">' + sys.avgMs + 'ms</span>';
        html += '<span class="e-sys-errors ' + eClass + '">' + (sys.errors > 0 ? sys.errors + ' err' : '0') + '</span>';
        html += '</div>';
    }
    document.getElementById('endurance-systems').innerHTML = html;
}

function fallbackCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.left = '-9999px';
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    document.body.removeChild(ta);
    var btn = document.getElementById('btn-copy');
    btn.textContent = 'Copied!';
    setTimeout(function() { btn.textContent = 'Copy Failures'; }, 1500);
}

function toggleCategory(header) {
    header.parentElement.classList.toggle('expanded');
}

function esc(str) {
    var d = document.createElement('div');
    d.textContent = str;
    return d.innerHTML;
}
