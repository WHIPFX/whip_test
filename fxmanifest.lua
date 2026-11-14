fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'whip_test'
description 'Automated test suite for whip_core'
version '1.0.0'
whip_updates 'WHIPFX/whip_test'   -- whip_core checks this repository's releases for a newer version

dependency 'whip_core'
whip_requires '1.0'   -- the whip_core it is built for: the setup report flags an older one

-- A stand-in theme resource for module 69 (whip_core/server/property_themes.lua): its exports are in
-- server/tests/69_property_themes.lua, and it has no homes but while that module runs.
whip_interior_themes 'v1'

-- The /test menu's sections: which test modules each card runs. Both halves need it — the server
-- runs its modules by section, and so does the client.
shared_scripts {
    'shared/sections.lua',
    -- whip's satellite helper (Whip.register / call / ready), included the way any resource
    -- includes it — module 46 tests it from here.
    '@whip_core/lib/satellite.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/runner.lua',
    -- What the Director modules (76 on) build and run their scenarios with: before them.
    'server/director_kit.lua',
    'server/tests/*.lua',
    -- Load test. Shares nothing with the suite above except the NUI page, and does nothing at all
    -- until /testload is typed.
    'server/loadtest.lua',
}

client_scripts {
    'client/runner.lua',
    -- What the Director modules ask this game: where things are, what they do.
    'client/director_kit.lua',
    'client/tests/*.lua',
    'client/loadtest.lua',
    -- The deliberate cheat: writes watched statebag keys the way a cheat menu would, so
    -- the Sentinel can be proven against a genuinely client-originated tamper. Gated by
    -- this resource not being ensured — it exists only while whip_test is manually started.
    'client/sn_tamper.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/css/report.css',
    'html/js/report.js',
    -- The /test menu: a card per section, and the full-suite button.
    'html/css/menu.css',
    'html/js/menu.js',
    -- Load-test panel. Its own stylesheet and script because it uses whip_core's overlay language
    -- rather than this resource's report styling.
    'html/css/load.css',
    'html/js/load.js',
}
