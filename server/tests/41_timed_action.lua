-- ============================================
-- Timed actions — the server's clock for a progress bar
--
-- WHY THIS MODULE EXISTS
--
-- StartTimedAction / FinishTimedAction are what stop a modified client skipping a progress bar the
-- CLIENT runs: reviving hands something over only when FinishTimedAction says yes. If it ever starts
-- saying yes too easily, that goes back to trusting the client, and nothing would look broken. These
-- tests pin the four ways it must say no, and the one way it must say yes. (Armour, drinking and the
-- nitrous and FMC installs moved to the server Progress / declared timed use on 24 Sep 2026 — module
-- 48 covers those.)
--
-- Short durations on purpose: the rule is "at least 90% of the duration", and a 400ms bar tests
-- that as well as a 5 second one without making the suite wait.
-- ============================================

RegisterTestModule({
    order    = 41,
    category = 'Timed Actions',

    tests = {
        {
            name = 'A finish nobody started is refused, and the refusal is on record',
            fn = function(source)
                local ok, reason = exports.whip_core:FinishTimedAction(source, '_test_never_started')
                assertFalse(ok, 'finish without a start')
                assertEqual(reason, 'finished without being started', 'with the reason')
                -- Recorded for the Event Monitor under '<resource>:<name>', so an admin can see a
                -- client sending finishes it never earned.
                assertLastReject('whip_test:_test_never_started', 'finished without being started',
                    'the refusal is recorded')
            end,
        },
        {
            name = 'A finish sooner than the bar could fill is refused, and uses up the start',
            fn = function(source)
                assertTrue(exports.whip_core:StartTimedAction(source, '_test_early', 300), 'started')
                local ok, reason = exports.whip_core:FinishTimedAction(source, '_test_early')
                assertFalse(ok, 'finished instantly')
                assertTrue(tostring(reason):find('minimum is 270ms', 1, true) ~= nil,
                    ('refused for being early (got "%s")'):format(tostring(reason)))

                -- One-shot: the refused finish consumed the start, so waiting it out and asking
                -- again must not turn the same start into a success.
                Wait(350)
                assertFalse(exports.whip_core:FinishTimedAction(source, '_test_early'),
                    'second finish after the refused one')
            end,
        },
        {
            name = 'A finish after the full duration succeeds, once',
            fn = function(source)
                -- An item's address is what a use handler starts with (09-24), so that is the match.
                assertTrue(exports.whip_core:StartTimedAction(source, '_test_ok', 400,
                    PocketAddr(source, 'player', 3)), 'started')
                Wait(450)
                -- The answer is the start's values (09-24), so it is a table rather than `true`.
                local started = exports.whip_core:FinishTimedAction(source, '_test_ok',
                    PocketAddr(source, 'player', 3))
                assertType(started, 'table', 'finished after the bar')
                assertFalse(exports.whip_core:FinishTimedAction(source, '_test_ok',
                    PocketAddr(source, 'player', 3)), 'the same start cannot be finished twice')
            end,
        },
        {
            -- 09-24: the finish hands back what the start was given, so a use handler can start from
            -- the item's address and the finish learns it without the client naming any slot.
            name = 'A finish with no values hands back what the start was given',
            fn = function(source)
                local addr = PocketAddr(source, 'player', 4)
                assertTrue(exports.whip_core:StartTimedAction(source, '_test_handback', 200, addr), 'started')
                Wait(250)
                local started, reason = exports.whip_core:FinishTimedAction(source, '_test_handback')
                assertType(started, 'table', ('finished (got %s)'):format(tostring(reason)))
                assertEqual(started.kind, 'player', 'kind came back')
                assertEqual(started.id, source, 'id came back')
                assertEqual(started.sub, 'player', 'sub came back')
                assertEqual(started.slot, 4, 'slot came back')

                -- Started with nothing: the answer is still a table, just an empty one.
                assertTrue(exports.whip_core:StartTimedAction(source, '_test_handback2', 200), 'started bare')
                Wait(250)
                assertType(exports.whip_core:FinishTimedAction(source, '_test_handback2'), 'table',
                    'a bare start finishes with an empty table')
            end,
        },
        {
            name = 'A finish for a different slot than the start is refused',
            fn = function(source)
                -- The start is asserted and so is the reason: without both, a start that silently
                -- failed read as a pass here, refused as "finished without being started".
                assertTrue(exports.whip_core:StartTimedAction(source, '_test_match', 200,
                    PocketAddr(source, 'player', 3)), 'started')
                Wait(250)
                local ok, reason = exports.whip_core:FinishTimedAction(source, '_test_match',
                    PocketAddr(source, 'player', 7))
                assertFalse(ok, 'finished from another slot')
                assertEqual(reason, 'finished a different action from the one that was started',
                    'refused because the slot differs')
            end,
        },
        {
            name = 'Starting the same action again restarts its clock',
            fn = function(source)
                -- A player who cancels and starts again gets a fresh bar, and the finish is timed
                -- against THAT one — the first start's head start does not carry over.
                assertTrue(exports.whip_core:StartTimedAction(source, '_test_restart', 300), 'first start')
                Wait(250)
                assertTrue(exports.whip_core:StartTimedAction(source, '_test_restart', 300), 'second start')
                local ok, reason = exports.whip_core:FinishTimedAction(source, '_test_restart')
                assertFalse(ok, 'a finish straight after the restart is early')
                assertTrue(tostring(reason):find('minimum is', 1, true) ~= nil,
                    ('refused for being early (got "%s")'):format(tostring(reason)))
            end,
        },
        {
            name = 'Nonsense durations are refused at the start',
            fn = function(source)
                assertFalse(exports.whip_core:StartTimedAction(source, '_test_bad', 0), 'zero')
                assertFalse(exports.whip_core:StartTimedAction(source, '_test_bad', -500), 'negative')
                assertFalse(exports.whip_core:StartTimedAction(source, '_test_bad', 0/0), 'NaN')
                assertFalse(exports.whip_core:StartTimedAction(source, '_test_bad', 1/0), 'infinite')
                assertFalse(exports.whip_core:StartTimedAction(source, '', 500), 'empty name')
            end,
        },
    },
})
