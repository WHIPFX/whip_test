-- ============================================
-- SecureEvent / SecureCallback Tests
--
-- This module used to contain three tests whose entire body was `assertTrue(true)`,
-- justified by a comment saying the pipeline was "validated by the vehicle/door/zone
-- tests". It was not: those tests drive SecureEvents with VALID arguments, so they prove
-- the happy path and nothing about validation. Nothing in the suite ever sent a bad
-- parameter and checked it was corrected or rejected.
--
-- These tests drive a real SecureEvent from the client with deliberately hostile input
-- and assert what the handler actually received — i.e. they test validateParam and the
-- gates in front of it (whip_core/server/secure.lua) rather than asserting that
-- registration returned.
--
-- EVERY REFUSAL IS ASSERTED BY ITS REASON (assertLastReject), not only by "the handler did
-- not run". A handler that never ran proves nothing on its own: the rate limiter, a missing
-- session or a dead flag all look exactly like the rule under test.
-- ============================================

-- What each _test handler received, and how many times it ran. Keyed by event name so every
-- test starts from its own zero instead of inheriting a neighbour's count.
local _counts = {}
local _last   = {}

--- A handler that records what validation handed it.
---@param name string
---@return function
local function recorder(name)
    return function(src, player, value)
        _counts[name] = (_counts[name] or 0) + 1
        _last[name]   = value
    end
end

local function resetCounts(name)
    _counts[name] = 0
    _last[name]   = nil
end

--- Fire a whip_core event from the tester's client and wait for the SERVER's answer.
local function fire(source, eventName, ...)
    assertTrue(ClientExecWait(source, eventName, 3000, ...),
        ('%s: the server answered'):format(eventName))
end

--- Fire `n` copies without waiting between them, then wait until the server has recorded an
--- outcome — accepted or refused — for every one. A fixed Wait here used to be a guess: a slow
--- client read as "the rate limiter let nothing through".
local function fireBurst(source, eventName, n, ...)
    local before = exports.whip_core:__TestEventSeq(eventName) or 0
    for _ = 1, n do
        ClientExec(source, eventName, ...)
    end
    local done = waitFor(function()
        return (exports.whip_core:__TestEventSeq(eventName) or 0) >= before + n
    end, 5000)
    assertTrue(done == true, ('%s: the server answered all %d'):format(eventName, n))
end

--- An ACE nobody is granted. Outside the whip namespace on purpose: a server that grants
--- `whip` as a whole would grant `whip.anything` with it.
local NEVER_ACE = '_whip_test.never_granted'

RegisterTestModule({
    order    = 10,
    category = 'SecureEvent',
    setup = function(source, ctx)
        _counts, _last = {}, {}

        -- NOT RATE LIMITED, on purpose. These events exist to test VALIDATION, and a 500ms limit
        -- here used to force a Wait(600) before every call — and turned any slow call into a
        -- "handler never ran" that was really the rate limiter. The limiter has its own events
        -- below.
        exports.whip_core:SecureEvent('_test_secure_event', {
            rateLimit = false,
            params = {
                { 'name',   'key',  30 },
                { 'amount', 'int',  1, 100, 1 },
                { 'mode',   'enum', { 'a', 'b', 'c' }, 'a' },
            },
        }, function(src, player, name, amount, mode)
            _counts._test_secure_event = (_counts._test_secure_event or 0) + 1
            _last._test_secure_event   = { name = name, amount = amount, mode = mode }
        end)

        exports.whip_core:SecureEvent('_test_secure_vehicle', {
            rateLimit = false,
            params = { { 'vehicle', 'vehicle' } },
        }, recorder('_test_secure_vehicle'))

        exports.whip_core:SecureEvent('_test_secure_id', {
            rateLimit = false,
            params = { { 'target', 'id', 1, 100 } },
        }, recorder('_test_secure_id'))

        exports.whip_core:SecureEvent('_test_secure_bool', {
            rateLimit = false,
            params = { { 'flag', 'bool' } },
        }, recorder('_test_secure_bool'))

        exports.whip_core:SecureEvent('_test_secure_string', {
            rateLimit = false,
            params = { { 'text', 'string', 20 } },
        }, recorder('_test_secure_string'))

        exports.whip_core:SecureEvent('_test_secure_ace', {
            rateLimit = false,
            ace = NEVER_ACE,
        }, recorder('_test_secure_ace'))

        -- 'record' and 'player' (dev review E6): one table of named fields; another player, here the tester
        -- (notSelf = false) since a run has one player.
        exports.whip_core:SecureEvent('_test_secure_record', {
            rateLimit = false,
            params = { { 'form', 'record', { { 'accountId', 'id' }, { 'note', 'string', 20 } } } },
        }, recorder('_test_secure_record'))
        exports.whip_core:SecureEvent('_test_secure_player', {
            rateLimit = false,
            params = { { 'target', 'player', { notSelf = false } } },
        }, recorder('_test_secure_player'))
        exports.whip_core:SecureEvent('_test_secure_notself', {
            rateLimit = false,
            params = { { 'target', 'player' } },
        }, recorder('_test_secure_notself'))

        -- `near` resolves a position from the event's own parameters. Here the parameter is an
        -- offset from the tester, so one event can be sent both near and far — and 999 stands
        -- for "an id that resolves to nothing", 777 for a resolver that breaks.
        exports.whip_core:SecureEvent('_test_secure_near', {
            rateLimit = false,
            near = {
                range   = 5.0,
                message = false,   -- no toast on the tester's screen for a deliberate refusal
                at = function(src, player, dx)
                    if dx == 999 then return nil end
                    if dx == 777 then
                        error('[EXPECTED] whip_test 10_secure is deliberately erroring in near.at')
                    end
                    local c = GetEntityCoords(GetPlayerPed(src))
                    return c.x + dx, c.y, c.z
                end,
            },
            params = { { 'dx', 'int', 0, 1000, 0 } },
        }, recorder('_test_secure_near'))

        -- The rate limiter, on its own events: one with a declared limit, one on the default,
        -- one that opts out.
        exports.whip_core:SecureEvent('_test_secure_burst', {
            rateLimit = 500,
        }, recorder('_test_secure_burst'))

        exports.whip_core:SecureEvent('_test_secure_defaultrate', {
        }, recorder('_test_secure_defaultrate'))

        exports.whip_core:SecureEvent('_test_secure_unlimited', {
            rateLimit = false,
        }, recorder('_test_secure_unlimited'))

        -- The dead-player gate: the default, and the two ways through it.
        exports.whip_core:SecureEvent('_test_dead_default', {
            rateLimit = false,
        }, recorder('_test_dead_default'))
        exports.whip_core:SecureEvent('_test_dead_allowed', {
            rateLimit = false,
            whileDead = true,
        }, recorder('_test_dead_allowed'))
        exports.whip_core:SecureEvent('_test_dead_ace', {
            rateLimit = false,
            ace = 'whip.devtools',   -- /test requires it, so the tester holds it
        }, recorder('_test_dead_ace'))

        exports.whip_core:SecureCallback('_test_secure_cb', {
            rateLimit = false,
            params = { { 'val', 'int', 0, 999, 0 } },
        }, function(src, player, val)
            return val * 2
        end)
        exports.whip_core:SecureCallback('_test_dead_cb_ok', {
            rateLimit = false,
            whileDead = true,
        }, function(src, player)
            return 'answered'
        end)

        -- A handler IN ANOTHER RESOURCE that refuses (this one — whip_test is a satellite). The
        -- export it calls runs on a different coroutine from the wrapper, which is how a
        -- satellite's refusal used to be stamped over with 'ok' (AI build test, 09-24).
        exports.whip_core:SecureEvent('_test_veto_event', {
            rateLimit = false,
            params = { { 'veto', 'bool' } },
        }, function(src, player, veto)
            _counts._test_veto_event = (_counts._test_veto_event or 0) + 1
            if veto then
                exports.whip_core:RecordEventRejection('_test_veto_event', src, 'vetoed by the handler')
            end
        end)
        exports.whip_core:SecureCallback('_test_veto_cb', {
            rateLimit = false,
        }, function(src, player)
            -- Named as registered, WITHOUT the 'cb:' prefix — the way a satellite would write it.
            exports.whip_core:RecordEventRejection('_test_veto_cb', src, 'callback vetoed')
            return 'no'
        end)

        -- A real owned car for the 'vehicle' param tests. Garaged, so nothing has to be
        -- spawned or stood next to — the type authorises on ownership, not on distance.
        --
        -- A PLATE PER RUN. This was the fixed 'SECT', so a car left behind by a crashed run made
        -- every later run's setup fail on a plate that already existed.
        local vehicleId, createErr = exports.whip_core:CreateOwnedVehicle(source, {
            model = 'asea',
            plate = ('ST%06d'):format(math.random(0, 999999)),
            state = 'garaged',
        })
        ctx.vehicleId       = (vehicleId and vehicleId ~= false) and vehicleId or nil
        ctx.vehicleSetupErr = ctx.vehicleId and 'ok' or createErr
    end,
    teardown = function(ctx, source)
        -- Before anything else: a test that failed while the tester was flagged dead must not
        -- leave them refused by every event on the server for the rest of the run.
        if ctx.deadPrev ~= nil and source then
            pcall(exports.whip_core.__TestSetDeadFlag, exports.whip_core, source, ctx.deadPrev)
        end
        if ctx.vehicleId then
            pcall(exports.whip_core.DeleteVehicle, exports.whip_core, ctx.vehicleId)
        end
    end,
    tests = {
        {
            name = 'Valid parameters reach the handler unchanged',
            fn = function(source)
                resetCounts('_test_secure_event')
                fire(source, '_test_secure_event', 'good_name', 42, 'b')
                assertLastReject('_test_secure_event', nil, 'accepted')
                local got = _last._test_secure_event
                assertNotNil(got, 'handler ran')
                assertEqual(got.name, 'good_name', 'name')
                assertEqual(got.amount, 42, 'amount')
                assertEqual(got.mode, 'b', 'mode')
            end,
        },
        {
            name = "'record' checks each named field, hands over only those, and refuses a bad one",
            fn = function(source)
                resetCounts('_test_secure_record')
                fire(source, '_test_secure_record', { accountId = 5, note = 'hello', extra = 'dropped' })
                local got = _last._test_secure_record
                assertNotNil(got, 'handler ran')
                assertEqual(got.accountId, 5, 'accountId')
                assertEqual(got.note, 'hello', 'note')
                assertNil(got.extra, 'a field the schema does not name is not handed over')
                resetCounts('_test_secure_record')
                fire(source, '_test_secure_record', { accountId = 'five', note = 'x' })
                assertEqual(_counts._test_secure_record or 0, 0, 'a bad field: the handler never ran')
                fire(source, '_test_secure_record', 'not a table')
                assertEqual(_counts._test_secure_record or 0, 0, 'not a table: refused')
            end,
        },
        {
            name = "'player' hands over the player's light sheet, and refuses yourself unless notSelf = false",
            fn = function(source, ctx)
                resetCounts('_test_secure_player')
                fire(source, '_test_secure_player', source)
                local got = _last._test_secure_player
                assertNotNil(got, 'handler ran')
                assertEqual(got.source, source, 'their source')
                assertEqual(got.charId, exports.whip_core:GetCharId(source), 'their charId')
                assertNil(got.cash, 'the light sheet: no cash')

                resetCounts('_test_secure_notself')
                fire(source, '_test_secure_notself', source)
                assertEqual(_counts._test_secure_notself or 0, 0, 'yourself: refused by default')
                fire(source, '_test_secure_notself', 65000)
                assertEqual(_counts._test_secure_notself or 0, 0, 'nobody online: refused')
            end,
        },
        {
            -- REJECTED, NOT REWRITTEN (audit 2, CORE-16). A key names something, and stripping the
            -- bad characters used to turn 'legion.sq' into 'legionsq' and act on THAT — so a key
            -- the cleaner would have changed now stops the event before the handler.
            name = "'key' parameter rejects anything the cleaner would change, rather than changing it",
            fn = function(source)
                resetCounts('_test_secure_event')

                fire(source, '_test_secure_event', "bad name!@#$%^&*()", 5, 'a')
                assertLastReject('_test_secure_event', 'name: invalid key', 'bad characters')

                -- Too long: Sanitize.key would CUT it to 30, which is a different key.
                fire(source, '_test_secure_event', string.rep('k', 31), 5, 'a')
                assertLastReject('_test_secure_event', 'name: invalid key', 'one character too long')

                -- Not a string at all.
                fire(source, '_test_secure_event', 12345, 5, 'a')
                assertLastReject('_test_secure_event', 'name: invalid key', 'a number')

                assertEqual(_counts._test_secure_event, 0, 'the handler ran for none of them')

                -- And a clean key still goes straight through, all 30 characters of it.
                fire(source, '_test_secure_event', 'clean_key-1', 5, 'a')
                assertLastReject('_test_secure_event', nil, 'clean key accepted')
                assertEqual(_last._test_secure_event.name, 'clean_key-1', 'a valid key arrives unchanged')

                fire(source, '_test_secure_event', string.rep('k', 30), 5, 'a')
                assertEqual(_last._test_secure_event.name, string.rep('k', 30), 'exactly the limit is fine')
            end,
        },
        {
            name = "'int' parameter is clamped to its declared range",
            fn = function(source)
                resetCounts('_test_secure_event')
                fire(source, '_test_secure_event', 'clamp', 99999, 'a')
                assertEqual(_last._test_secure_event.amount, 100, 'clamped to declared max of 100')

                fire(source, '_test_secure_event', 'clamp', -50, 'a')
                assertEqual(_last._test_secure_event.amount, 1, 'clamped to declared min of 1')

                -- A declared default makes a non-number an answer rather than a refusal.
                fire(source, '_test_secure_event', 'clamp', 'lots', 'a')
                assertEqual(_last._test_secure_event.amount, 1, 'a non-number takes the default')
                assertEqual(_counts._test_secure_event, 3, 'none of the three was refused')
            end,
        },
        {
            name = "'enum' parameter falls back to its default when not in the allowed set",
            fn = function(source)
                resetCounts('_test_secure_event')
                fire(source, '_test_secure_event', 'enumtest', 10, 'not_a_mode')
                assertNotNil(_last._test_secure_event, 'handler ran')
                assertEqual(_last._test_secure_event.mode, 'a', 'invalid enum replaced with declared default')
            end,
        },
        {
            -- An ADDRESS, so REJECTED rather than clamped: `int` turning 0 into 1 is how an id of 0
            -- used to unban ban #1 and delete vehicle #1 (Sanitize.id).
            name = "'id' parameter rejects zero, fractions, out-of-range and text — and accepts a numeric string",
            fn = function(source)
                resetCounts('_test_secure_id')
                for _, bad in ipairs({ 0, 1.5, 101, 'abc', -3 }) do
                    fire(source, '_test_secure_id', bad)
                    assertLastReject('_test_secure_id', 'target: invalid id',
                        ('%s is not an id'):format(tostring(bad)))
                end
                assertEqual(_counts._test_secure_id, 0, 'the handler ran for none of them')

                -- NUI datasets arrive as text, so a numeric string is accepted — as the NUMBER.
                fire(source, '_test_secure_id', '7')
                assertLastReject('_test_secure_id', nil, "'7' accepted")
                assertEqual(_last._test_secure_id, 7, "'7' arrives as the number 7")
            end,
        },
        {
            -- What the SENDER meant, not Lua truthiness: `not not raw` made the string "false" and
            -- the number 0 both true, so a door "unlocked" by sending locked = "false".
            name = "'bool' parameter reads the spellings a sender means, and refuses the rest",
            fn = function(source)
                resetCounts('_test_secure_bool')
                local cases = {
                    { 'false', false }, { 0, false }, { '0', false },
                    { 'true', true },   { 1, true },  { '1', true },
                }
                for _, case in ipairs(cases) do
                    fire(source, '_test_secure_bool', case[1])
                    assertEqual(_last._test_secure_bool, case[2],
                        ('%s (%s) reads as %s'):format(tostring(case[1]), type(case[1]), tostring(case[2])))
                end

                -- No declared default, so anything else is refused rather than guessed at.
                fire(source, '_test_secure_bool', 'maybe')
                assertLastReject('_test_secure_bool', 'flag: expected true or false', "'maybe' refused")
                assertEqual(_counts._test_secure_bool, #cases, 'and did not reach the handler')
            end,
        },
        {
            name = "'string' parameter strips control characters, truncates, and refuses empty",
            fn = function(source)
                resetCounts('_test_secure_string')

                fire(source, '_test_secure_string', '')
                assertLastReject('_test_secure_string', 'text: empty string', 'empty refused')
                assertEqual(_counts._test_secure_string, 0, 'the handler did not run for it')

                fire(source, '_test_secure_string', 'ab\1cd')
                assertEqual(_last._test_secure_string, 'abcd', 'control characters stripped')

                fire(source, '_test_secure_string', string.rep('s', 26))
                assertEqual(_last._test_secure_string, string.rep('s', 20), 'cut to the declared 20')
            end,
        },
        {
            -- The type resolves an id to a vehicle AND authorises it. What the handler receives
            -- must be a SNAPSHOT: a satellite writing to its own argument cannot be allowed to
            -- change whip's state, which is the same rule that took GetVehicleDef off the exports.
            name = "'vehicle' parameter arrives as a snapshot, not the live record",
            fn = function(source, ctx)
                assertNotNil(ctx.vehicleId, 'setup created a vehicle: ' .. tostring(ctx.vehicleSetupErr))
                resetCounts('_test_secure_vehicle')
                fire(source, '_test_secure_vehicle', ctx.vehicleId)

                local v = _last._test_secure_vehicle
                assertNotNil(v, 'handler ran')
                assertEqual(v.vehicleId, ctx.vehicleId, 'vehicleId')
                assertEqual(v.model, 'asea', 'model')
                assertNotNil(v.owner, 'owner block present')

                -- Occupants are opt-in and this path never asks, because it runs on every call.
                assertNil(v.occupants, 'occupants left out')

                v.model = 'TAMPERED'
                assertEqual(exports.whip_core:GetVehicle(ctx.vehicleId).model, 'asea',
                    'writing to the argument did not reach the framework')
            end,
        },
        {
            -- The ownership branch ('not your vehicle') needs a car belonging to ANOTHER character,
            -- and TransferVehicle can only hand one to somebody online. That half is in-game only.
            name = "'vehicle' parameter rejects an id that is not a vehicle, by the right reason",
            fn = function(source)
                resetCounts('_test_secure_vehicle')

                fire(source, '_test_secure_vehicle', 999999)
                assertLastReject('_test_secure_vehicle', 'vehicle: no such vehicle', 'an unknown id')

                fire(source, '_test_secure_vehicle', 0)
                assertLastReject('_test_secure_vehicle', 'vehicle: must be a whole vehicle id', 'zero')

                assertEqual(_counts._test_secure_vehicle, 0, 'the handler ran for neither')
            end,
        },
        {
            name = "'ace' refuses a player without the permission, and says which",
            fn = function(source)
                if IsPlayerAceAllowed(source, NEVER_ACE) then
                    skip(('the tester is granted %s, so it cannot stand for a missing ACE'):format(NEVER_ACE))
                end
                resetCounts('_test_secure_ace')
                fire(source, '_test_secure_ace')
                assertLastReject('_test_secure_ace', 'ACE denied: ' .. NEVER_ACE, 'refused on the ACE')
                assertEqual(_counts._test_secure_ace, 0, 'the handler never ran')
            end,
        },
        {
            -- Declared in the schema so an early return inside a handler cannot skip it — which is
            -- exactly how doorToggle ended up with no distance check at all.
            name = "'near' lets a close request through, refuses a far one, and fails closed on a broken resolver",
            fn = function(source)
                resetCounts('_test_secure_near')

                fire(source, '_test_secure_near', 0)
                assertLastReject('_test_secure_near', nil, 'at the tester')
                assertEqual(_counts._test_secure_near, 1, 'a request at the tester ran')

                fire(source, '_test_secure_near', 500)
                assertLastReject('_test_secure_near', 'Too far away', '500m away')
                assertEqual(_counts._test_secure_near, 1, 'the far request did not run')

                -- nil from `at` means "nothing there to measure" — an id that resolves to nothing.
                -- It REFUSES now (SEC-3, 24 Sep 2026): it used to be let through for the handler to
                -- notice, and a handler that did not was reachable from anywhere. allowUnknown keeps
                -- the old way — see the 'Registry & Security' module.
                fire(source, '_test_secure_near', 999)
                assertEqual(_counts._test_secure_near, 1, 'no position: refused, the handler never ran')
                assertLastReject('_test_secure_near', 'Too far away (near.at found no position)',
                    'refused for having no position')

                -- A resolver that THROWS is recorded as an error and the handler never runs. The
                -- stack trace this prints in the console is EXPECTED output from this test.
                fire(source, '_test_secure_near', 777)
                assertEqual(_counts._test_secure_near, 1, 'a broken resolver did not let the request through')
            end,
        },
        {
            name = 'A declared rate limit lets one of a burst through, and refuses the rest as rate limited',
            fn = function(source)
                resetCounts('_test_secure_burst')
                -- rateLimit is 500ms with no burst, so back to back only the first gets a token.
                fireBurst(source, '_test_secure_burst', 5)
                assertEqual(_counts._test_secure_burst, 1, 'exactly one of five calls passed the rate limiter')
                assertLastReject('_test_secure_burst', 'Rate limited', 'the others were refused by the limiter')
            end,
        },
        {
            -- EVERY EVENT IS RATE LIMITED unless it opts out: a schema with no `rateLimit` gets ten
            -- back to back, then one per 100ms (secure.lua, DEFAULT_RATE_LIMIT_MS / _BURST).
            name = 'An event that declares no rate limit gets the default of ten back to back',
            fn = function(source)
                resetCounts('_test_secure_defaultrate')
                fireBurst(source, '_test_secure_defaultrate', 15)
                -- Ten from the burst. An eleventh is possible only if the fifteen arrive spread
                -- over more than 100ms, which earns one more token.
                assertGte(_counts._test_secure_defaultrate, 10, 'the burst of ten was honoured')
                assertTrue(_counts._test_secure_defaultrate <= 11,
                    ('the limiter engaged after the burst (%d of 15 ran)'):format(_counts._test_secure_defaultrate))
                assertLastReject('_test_secure_defaultrate', 'Rate limited', 'the rest were rate limited')

                -- And `rateLimit = false` really means none.
                resetCounts('_test_secure_unlimited')
                fireBurst(source, '_test_secure_unlimited', 15)
                assertEqual(_counts._test_secure_unlimited, 15, 'an event that opts out is never limited')
            end,
        },
        {
            name = 'A SecureCallback validates its parameters and answers the client',
            fn = function(source)
                local answered, res = ClientCallback(source, '_test_secure_cb', nil, 21)
                assertTrue(answered, 'the callback answered')
                assertEqual(res and res[1], 42, 'the handler ran with the validated value')
                assertLastReject('cb:_test_secure_cb', nil, 'accepted')

                -- 'int' clamps, and a callback's params go through the same validation.
                answered, res = ClientCallback(source, '_test_secure_cb', nil, 5000)
                assertEqual(res and res[1], 999 * 2, 'clamped to the declared max before the handler saw it')
            end,
        },
        {
            name = "A satellite handler's RecordEventRejection stays a refusal, for events and callbacks",
            fn = function(source)
                resetCounts('_test_veto_event')

                fire(source, '_test_veto_event', true)
                assertEqual(_counts._test_veto_event, 1, 'the handler ran')
                assertLastReject('_test_veto_event', 'vetoed by the handler',
                    'the refusal is the last word, not an ok stamped over it')

                -- A refusal belongs to the call that made it: the next, accepted, call is ok.
                fire(source, '_test_veto_event', false)
                assertLastReject('_test_veto_event', nil, 'the next call that does not refuse is accepted')

                local answered, res = ClientCallback(source, '_test_veto_cb')
                assertTrue(answered, 'the callback answered')
                assertEqual(res and res[1], 'no', 'with what the handler returned')
                assertLastReject('cb:_test_veto_cb', 'callback vetoed',
                    "a callback refusal named without 'cb:' is logged against the callback")
            end,
        },
        {
            -- DEAD PLAYERS ACT ON NOTHING, BY DEFAULT (Josh, 2026-09-23). The rule lives in the one
            -- gate every client request passes (secure.lua, refusedWhileDead), so an event written
            -- tomorrow is covered without anybody remembering to add it. `whileDead = true` and an
            -- `ace` are the only ways through.
            --
            -- The flag is flipped on the SERVER only (__TestSetDeadFlag) — the ped, the death screen
            -- and the stats are untouched, because the gate reads nothing else and a real death
            -- would leave the tester to wait out the respawn timer.
            name = 'A dead player is refused by default; whileDead and ace events still pass',
            fn = function(source, ctx)
                for _, name in ipairs({ '_test_dead_default', '_test_dead_allowed', '_test_dead_ace' }) do
                    resetCounts(name)
                end

                ctx.deadPrev = exports.whip_core:__TestSetDeadFlag(source, true)
                assertNotNil(ctx.deadPrev, 'the tester has a player session to flag')

                local ok, err = pcall(function()
                    fire(source, '_test_dead_default')
                    fire(source, '_test_dead_allowed')
                    fire(source, '_test_dead_ace')

                    assertEqual(_counts._test_dead_default, 0, 'the default event did not run')
                    assertLastReject('_test_dead_default', 'Player is dead', 'refused because the player is dead')

                    assertEqual(_counts._test_dead_allowed, 1, 'a whileDead event runs for a dead player')
                    assertLastReject('_test_dead_allowed', nil, 'and was not refused')

                    assertEqual(_counts._test_dead_ace, 1, 'an ace event runs for a dead admin')
                    assertLastReject('_test_dead_ace', nil, 'and was not refused')

                    -- Callbacks go through the same gate.
                    local answered, res = ClientCallback(source, '_test_secure_cb', nil, 21)
                    assertTrue(answered, 'the refused callback still answered the client')
                    -- false, reason (SEC-5, 24 Sep 2026) — it used to be a bare nil.
                    assertEqual(res and res[1], false, 'with false')
                    assertEqual(res and res[2], 'Player is dead', 'and the reason')
                    assertLastReject('cb:_test_secure_cb', 'Player is dead', 'the callback was refused for the dead flag')

                    answered, res = ClientCallback(source, '_test_dead_cb_ok')
                    assertEqual(res and res[1], 'answered', 'a whileDead callback answers a dead player')
                end)

                -- PUT IT BACK BEFORE ANYTHING ELSE CAN FAIL. Teardown does it again in case this
                -- line is never reached.
                exports.whip_core:__TestSetDeadFlag(source, ctx.deadPrev)
                ctx.deadPrev = nil

                -- The row flush may have written isDead = 1 while the flag was up. Re-queue the row
                -- so the next flush writes the real value back.
                exports.whip_core:SetPlayerMetadata(source, '_test_dead_gate', nil)

                if not ok then error(err, 0) end

                -- And alive again means acting again.
                fire(source, '_test_dead_default')
                assertEqual(_counts._test_dead_default, 1, 'once alive, the default event runs')
            end,
        },
    },
})
