-- ============================================
-- Sentinel — the statebag tamper watch
--
-- WHY THIS MODULE EXISTS
--
-- Statebags are client-writable. Sentinel is what stops that mattering: it keeps a server-side
-- LEDGER of what whip actually wrote, watches the bags for values that disagree, corrects them
-- and counts strikes. Three exports make that surface available to satellites, and none of them
-- had a test.
--
-- The property worth protecting is narrow and absolute: `GetSentinelTruth` answers what the
-- SERVER wrote, never what the bag currently says. Server logic that reads a bag directly is
-- reading something a modded client controls — that is the whole reason this file exists — so
-- a getTruth that ever fell back to the bag would silently undo the protection everywhere at
-- once, with nothing looking wrong.
--
-- The second (STAT-1, 24 Sep 2026): the write is for a resource's OWN keys. whip's own — isDead,
-- charId, the damage modifiers — are refused to everyone else, or the truth itself is forgeable.
--
-- WHAT THIS MODULE DELIBERATELY DOES NOT TEST, AND WHY
--
-- It does not tamper. Writing a wrong value onto a watched key is exactly what Sentinel is
-- built to catch, and catching it means `record()` — which counts a STRIKE against the player
-- and, at `Config.Sentinel.autoKick` (3 on this server), calls DropPlayer. A test that proved
-- the correction worked would kick the person running the suite out of the game, and three
-- reruns would do it even if the threshold were higher.
--
-- Everything below therefore uses the sanctioned write path, which the handler recognises as an
-- echo and ignores. Proving the correction itself needs an isolated source that is not a real
-- player, and that is a fixture this suite does not have — worth saying plainly rather than
-- leaving a gap nobody can see.
-- ============================================

--- Registered keys are never unregistered while whip_test is up (Sentinel unwinds an owner's
--- watches when that resource STOPS). A fixed name would still work now — registering your own
--- key again is fine since 24 Sep 2026 — but a fresh one keeps each test's key its own. Unique per
--- registration, seeded from the boot time so two runs cannot collide either.
local BOOT = GetGameTimer()
local _seq = 0
local function freshKey()
    _seq = _seq + 1
    return ('_test_sentinel_%d_%d'):format(BOOT, _seq)
end

RegisterTestModule({
    order    = 38,
    category = 'Sentinel',

    setup = function(source, ctx)
        -- (An `if not exports.whip_core.GetSentinelTruth then skip() end` guard used to sit here.
        -- It could never fire: indexing a missing export raises "No such export" instead of
        -- answering nil, so a missing Sentinel showed as SETUP FAILED either way — which is the
        -- honest result for a core that lost its exports.)
        ctx.keys = {}
    end,

    teardown = function(ctx, source)
        -- The ledger entries are cleared with the player, and the watches with the resource.
        -- Blanking the values is still worth doing: a stale test key left on a live player's
        -- bag is noise in the Event Monitor for the rest of the session.
        if ctx and ctx.keys and source then
            for _, key in ipairs(ctx.keys) do
                pcall(exports.whip_core.SetSentinelPlayerKey, exports.whip_core, source, key, nil)
            end
        end
    end,

    tests = {
        -- ==========================================
        -- Registration
        -- ==========================================
        {
            name = 'A player-family key registers',
            fn = function(source, ctx)
                local key = freshKey()
                ctx.keys[#ctx.keys + 1] = key

                local ok, err = exports.whip_core:RegisterSentinelKey({ key = key, family = 'player' })
                assertTrue(ok, 'RegisterSentinelKey: ' .. tostring(err))
            end,
        },
        {
            -- STAT-2, fixed 24 Sep 2026 (REG-1): the same resource registering its own key again
            -- used to be refused ('already watched'), so every whip_core:onReady re-fire failed for
            -- a satellite doing exactly what the docs said. The one registration rule makes it a
            -- no-op; only ANOTHER resource is refused (the next test, on whip_core's own key).
            name = 'Registering your OWN key again is fine (the same thing again changes nothing)',
            fn = function(source, ctx)
                local key = freshKey()
                ctx.keys[#ctx.keys + 1] = key

                assertTrue(exports.whip_core:RegisterSentinelKey({ key = key, family = 'player' }),
                    'first registration stands')

                local ok, err = exports.whip_core:RegisterSentinelKey({ key = key, family = 'player' })
                assertTrue(ok, ('the second is accepted too (got "%s")'):format(tostring(err)))

                local mine = exports.whip_core:GetRegistrations('whip_test')
                local found = false
                for _, r in ipairs(mine or {}) do
                    if r.registry == 'SentinelKey' and r.key == key then found = true end
                end
                assertTrue(found, 'GetRegistrations lists the key as whip_test\'s')
            end,
        },
        {
            name = "whip_core's own watched keys cannot be hijacked",
            fn = function(source, ctx)
                -- The same rule, on the key where it matters most. whip registers its own
                -- player keys at file scope; a satellite that could re-register one would own
                -- the truth for "is this player dead", which gates revive, damage and looting.
                --
                -- The literal is PLAYER_DEAD_KEY from whip_core/shared/statebags.lua. That
                -- constant is whip_core's global and does not cross into this resource, so it
                -- has to be spelled out — if whip renames the key this test goes red, and a
                -- rename of a watched statebag key IS something that should be noticed.
                local ok, err = exports.whip_core:RegisterSentinelKey({
                    key = 'whipDead', family = 'player',
                })
                assertFalse(ok, 'a key whip_core already watches is refused')
                assertNotNil(err, 'with a reason')
                assertTrue(tostring(err):find('whip_core', 1, true) ~= nil,
                    ('naming whip_core as the owner (got "%s")'):format(tostring(err)))
            end,
        },
        {
            name = 'Malformed registrations are refused with a reason',
            fn = function(source, ctx)
                local bad = {
                    { def = 'not a table',                              why = 'a non-table def' },
                    { def = {},                                          why = 'no key' },
                    { def = { key = '', family = 'player' },             why = 'an empty key' },
                    { def = { key = freshKey() },                        why = 'no family' },
                    { def = { key = freshKey(), family = 'nonsense' },   why = 'an unknown family' },
                    { def = { key = freshKey(), family = 'entity' },     why = 'entity family with no truth fn' },
                }
                for _, case in ipairs(bad) do
                    local ok, err = exports.whip_core:RegisterSentinelKey(case.def)
                    assertFalse(ok, case.why .. ' is refused')
                    assertNotNil(err, case.why .. ' says why')
                end
            end,
        },
        {
            name = 'An entity-family key WITH a truth function is accepted',
            fn = function(source, ctx)
                -- Entity truth lives in the owning module's private state, so the registration
                -- has to supply the reader. Note the function crosses an export boundary to get
                -- here, so this also covers the callable-not-'function' problem that has bitten
                -- every other registration API in whip.
                local key = freshKey()
                local ok, err = exports.whip_core:RegisterSentinelKey({
                    key = key, family = 'entity',
                    truth = function(_) return nil end,
                })
                assertTrue(ok, 'RegisterSentinelKey (entity): ' .. tostring(err))
            end,
        },

        -- ==========================================
        -- The ledger
        -- ==========================================
        {
            name = 'SetSentinelPlayerKey writes the truth, and GetTruth reads it back',
            fn = function(source, ctx)
                local key = freshKey()
                ctx.keys[#ctx.keys + 1] = key
                exports.whip_core:RegisterSentinelKey({ key = key, family = 'player' })

                assertTrue(exports.whip_core:SetSentinelPlayerKey(source, key, 'alpha'),
                    'the sanctioned write reported success')
                assertEqual(exports.whip_core:GetSentinelTruth(source, key), 'alpha',
                    'and the server truth is what was written')
            end,
        },
        {
            name = 'The sanctioned write reaches the statebag as well as the ledger',
            fn = function(source, ctx)
                -- Both halves matter and they are written together: the ledger is what the
                -- server trusts, the bag is what clients render from. A write that updated only
                -- the ledger would leave every client showing stale state; only the bag, and
                -- the next bag change would look like a tamper against a truth of nil.
                local key = freshKey()
                ctx.keys[#ctx.keys + 1] = key
                exports.whip_core:RegisterSentinelKey({ key = key, family = 'player' })

                exports.whip_core:SetSentinelPlayerKey(source, key, 'bravo')

                assertEqual(Player(source).state[key], 'bravo', 'the bag carries it')
                assertEqual(exports.whip_core:GetSentinelTruth(source, key), 'bravo',
                    'and the ledger agrees')
            end,
        },
        {
            name = 'FALSE is a real value — it is not collapsed to nil',
            fn = function(source, ctx)
                -- whip_core's own comment records this as a live bug that was fixed: reading
                -- the ledger as `ledger[key] or nil` turned a stored `false` into nil, which
                -- made whip's OWN login writes flag themselves as tampers. whipJob and
                -- whipEscorted are both legitimately false.
                local key = freshKey()
                ctx.keys[#ctx.keys + 1] = key
                exports.whip_core:RegisterSentinelKey({ key = key, family = 'player' })

                exports.whip_core:SetSentinelPlayerKey(source, key, false)

                local truth = exports.whip_core:GetSentinelTruth(source, key)
                assertFalse(truth, 'the truth is false')
                assertNotNil(truth, 'and specifically NOT nil — the two mean different things here')
            end,
        },
        {
            name = 'An unwritten key and an unknown source both read nil',
            fn = function(source, ctx)
                assertNil(exports.whip_core:GetSentinelTruth(source, '_test_sentinel_never_written'),
                    'a key the server never wrote has no truth')
                assertNil(exports.whip_core:GetSentinelTruth(99999, '_test_sentinel_never_written'),
                    'and a source with no ledger answers nil rather than raising')
            end,
        },
        {
            name = 'SetSentinelPlayerKey refuses malformed arguments, and says why',
            fn = function(source, ctx)
                -- It writes straight onto a player's bag, so it validates before it touches
                -- anything rather than letting a bad key become a bag entry nobody watches.
                local ok1, e1 = exports.whip_core:SetSentinelPlayerKey('not a number', 'k', 1)
                assertFalse(ok1, 'a non-numeric source is refused')
                assertEqual(e1, 'no such player', 'naming the problem')
                local ok2, e2 = exports.whip_core:SetSentinelPlayerKey(source, 123, 1)
                assertFalse(ok2, 'a non-string key is refused')
                assertNotNil(e2, 'with a reason')
            end,
        },

        -- ==========================================
        -- Whose keys (STAT-1)
        -- ==========================================
        {
            -- STAT-1, fixed 24 Sep 2026. The export wrote ANY key into the ledger, and the ledger is
            -- what whip's gates read back as the truth — so a satellite could mark a dead player
            -- alive, as far as every check in whip was concerned.
            --
            -- SAFE ON A LIVE TESTER EVEN IF IT REGRESSES: every write offers the value the ledger
            -- already holds, so a write that wrongly lands changes nothing about the player.
            name = "whip_core's own keys cannot be WRITTEN by another resource either",
            fn = function(source, ctx)
                -- Literals, as above: whip_core's key constants do not cross into this resource.
                for _, key in ipairs({ 'whipDead', 'whipJob', 'whipDamageMod' }) do
                    local before = exports.whip_core:GetSentinelTruth(source, key)
                    local ok, err = exports.whip_core:SetSentinelPlayerKey(source, key, before)
                    assertFalse(ok, ('"%s" is refused'):format(key))
                    assertEqual(err, ('key "%s" is owned by whip_core'):format(key), ('"%s" names its owner'):format(key))
                    assertEqual(exports.whip_core:GetSentinelTruth(source, key), before,
                        ('and the truth for "%s" is untouched'):format(key))
                end
            end,
        },
        {
            name = 'A key nobody watches is anyone\'s to write',
            fn = function(source, ctx)
                local key = freshKey()   -- never registered
                ctx.keys[#ctx.keys + 1] = key
                local ok, err = exports.whip_core:SetSentinelPlayerKey(source, key, 'charlie')
                assertTrue(ok, 'accepted: ' .. tostring(err))
                assertEqual(exports.whip_core:GetSentinelTruth(source, key), 'charlie', 'and written')
            end,
        },
        {
            name = 'A source nobody holds is refused rather than given a ledger nothing clears',
            fn = function(source, ctx)
                local key = freshKey()
                ctx.keys[#ctx.keys + 1] = key
                exports.whip_core:RegisterSentinelKey({ key = key, family = 'player' })
                local ok, err = exports.whip_core:SetSentinelPlayerKey(99999, key, 'x')
                assertFalse(ok, 'refused')
                assertEqual(err, 'no such player', 'naming the problem')
                assertNil(exports.whip_core:GetSentinelTruth(99999, key), 'and no ledger was made for it')
            end,
        },
        {
            name = 'Overwriting a truth replaces it rather than accumulating',
            fn = function(source, ctx)
                local key = freshKey()
                ctx.keys[#ctx.keys + 1] = key
                exports.whip_core:RegisterSentinelKey({ key = key, family = 'player' })

                exports.whip_core:SetSentinelPlayerKey(source, key, 'first')
                exports.whip_core:SetSentinelPlayerKey(source, key, 'second')
                assertEqual(exports.whip_core:GetSentinelTruth(source, key), 'second',
                    'the latest write is the truth')

                -- nil is how a satellite says "this player no longer carries this key".
                exports.whip_core:SetSentinelPlayerKey(source, key, nil)
                assertNil(exports.whip_core:GetSentinelTruth(source, key),
                    'and writing nil clears it')
            end,
        },
    }
})
