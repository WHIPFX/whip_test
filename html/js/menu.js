// ============================================
// The /test menu
// ============================================
//
// A card per section (whip_test/shared/sections.lua). Clicking a card runs that section alone;
// "Run full suite" runs everything, as /test always did. Each card shows how many tests it holds
// and how it did the last time it ran, so the one that needs attention is the red one.

var _menuBusy = false;

window.addEventListener('message', function(e) {
    if (e.data && e.data.action === 'showMenu') renderMenu(e.data.data || {});
});

document.addEventListener('keydown', function(e) {
    if (e.key !== 'Escape') return;
    if (!document.getElementById('menu-overlay').classList.contains('hidden')) closeMenu();
});

function closeMenu() {
    document.getElementById('menu-overlay').classList.add('hidden');
    fetch('https://whip_test/closeMenu', { method: 'POST', body: '{}' });
}

// Run one section, or 'all'. Hides the menu straight away: the tests need the game, and the chat
// shows their progress as they go. The report opens by itself when they finish.
function runSection(id) {
    if (_menuBusy) return;
    _menuBusy = true;
    document.getElementById('menu-overlay').classList.add('hidden');
    fetch('https://whip_test/runSection', {
        method: 'POST',
        body: JSON.stringify({ section: id }),
    });
}

// How a section did last time, as a class for the colours and the words on its badge.
function sectionStatus(last) {
    if (!last) return { cls: 'st-none', text: 'Not run yet' };
    var total = (last.passed || 0) + (last.failed || 0) + (last.skipped || 0);
    if (last.failed > 0)  return { cls: 'st-fail', text: '✗ ' + last.failed + ' failed' };
    if (last.partial)     return { cls: 'st-partial', text: 'Stopped part-way' };
    if (last.skipped > 0) return { cls: 'st-skip', text: '✓ ' + last.passed + '/' + total + ' passed' };
    return { cls: 'st-pass', text: '✓ All ' + last.passed + ' passed' };
}

function formatAgo(seconds) {
    if (seconds == null) return '';
    if (seconds < 60) return 'just now';
    if (seconds < 3600) return Math.floor(seconds / 60) + 'm ago';
    return Math.floor(seconds / 3600) + 'h ago';
}

function plural(n, word) {
    return n + ' ' + word + (n === 1 ? '' : 's');
}

function renderMenu(data) {
    _menuBusy = false;
    var sections = data.sections || [];
    var grid = document.getElementById('menu-grid');
    var html = '';
    var totalServer = 0, totalClient = 0;

    for (var i = 0; i < sections.length; i++) {
        var s = sections[i];
        var server = s.server || 0, client = s.client || 0;
        totalServer += server;
        totalClient += client;

        var st = sectionStatus(s.last);
        var counts = plural(server + client, 'test') + ' · ' + server + ' server, ' + client + ' client';

        html += '<div class="section-card ' + st.cls + '" data-id="' + esc(s.id) + '">';
        html +=   '<div class="card-top">';
        html +=     '<span class="card-icon">' + esc(s.icon || '') + '</span>';
        html +=     '<span class="card-title">' + esc(s.label) + '</span>';
        html +=     '<span class="card-run">Run &#9654;</span>';
        html +=   '</div>';
        html +=   '<div class="card-desc">' + esc(s.desc || '') + '</div>';
        html +=   '<div class="card-foot">';
        html +=     '<span class="card-counts">' + counts + '</span>';
        if (s.last) html += '<span class="card-ago">' + formatAgo(s.last.ago) + '</span>';
        html +=     '<span class="card-status ' + st.cls + '">' + st.text + '</span>';
        html +=   '</div>';
        html += '</div>';
    }

    grid.innerHTML = html;

    // One listener per card, reading the id back off the element rather than building it into an
    // onclick string — a section id is a plain word, but nothing here should depend on that.
    var cards = grid.querySelectorAll('.section-card');
    for (var c = 0; c < cards.length; c++) {
        cards[c].addEventListener('click', function() {
            this.classList.add('running');
            runSection(this.getAttribute('data-id'));
        });
    }

    document.getElementById('menu-total').textContent =
        plural(totalServer + totalClient, 'test') + ' · ' + sections.length + ' sections';

    document.getElementById('menu-overlay').classList.remove('hidden');
}
