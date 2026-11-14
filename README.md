# whip_test

The automated test suite for [WHIP](https://github.com/WHIPFX/txAdmin-recipe)'s `whip_core`. It runs WHIP's real
exports, events and screens on a running server and reports what passed and what failed. It also has a load test,
which measures what WHIP costs with a full server without needing the players.

**For a test server only.** A run gives and takes items, money and cars on the tester's character, makes test
doors, containers and vehicles, and the load test deliberately strains the server. Never ensure it on a live server.

## Requirements

- `whip_core`, from the same release as this resource.
- `oxmysql`.
- A tester with the `whip.devtools` ACE and developer mode on (`/w`).

## Installation

whip_test isn't in WHIP's txAdmin recipe. Put `whip_test` in your test server's `resources` folder, then start it
from the console when you want it (`ensure whip_test`).

## Commands

| Command | Does |
| --- | --- |
| `/test` | Opens the test menu: a card per section, and the full suite. |
| `/test all` | Runs the full suite. |
| `/test <section>` | Runs one section, by its id in `shared/sections.lua`. |
| `/teststop` | Stops a run. |
| `/testlong` | The endurance run. |
| `/testload` | The load test. Every dial has a default, so bare `/testload` is a full run. |
| `/testloadstop` | Stops a load test. Works from the server console. |
| `/testloadclean` | Counts what a load test left behind, and deletes it only with `confirm`. |

`/testpanel`, `/testpanelro`, `/dumpster`, `/lootcrate`, `/medkit`, `/evidence`, `/vendingmachine`, `/toolbox`,
`/dropoff`, `/safebox`, `/trashcan` and `/showcase` open demo panels.

## License

whip_test is licensed under the GNU LGPL 3.0; see `COPYING.LESSER`, and `COPYING` for the GPL 3.0 it builds on.
`NOTICE.md` says what the licence doesn't cover; `whip_core`'s `NOTICE.md` is the full list.
