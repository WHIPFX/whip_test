-- ============================================
-- Director: Endings — how a run ends: Succeed, Fail, its time limit, nothing left, After cards, the lead-in
-- ============================================
--
-- A run ends once (runtime.lua finish): by a Succeed, Fail or Call Off card, by its time limit (failed), by having
-- nothing left to wait for (failed), or from outside (aborted). A failed or succeeded run with an Activate After
-- Failure / Success card plays that card's chain first, then ends as it was going to. Before a Scenario Started card
-- (its lead-in) nothing counts: a Fail there ends it quietly, as called off.

local N = DK.N

--- start -> `first`; plus `extra` cards and wires.
local function doc(nodes, links, spec)
    spec = spec or {}
    spec.nodes = { N('start', 'scenario.started') }
    for _, n in ipairs(nodes) do spec.nodes[#spec.nodes + 1] = n end
    spec.links = links
    return DK.doc(spec)
end

RegisterTestModule({
    order    = 78,
    category = 'Director: Endings',
    setup = function(source)
        local p = exports.whip_core:GetPlayer(source)
        if not (p and p.charId) then skip('the tester is not on a character') end
    end,
    tests = {
        {
            name = 'Its time limit: a run still going after Max run time fails, "ran out of time"',
            fn = function(source)
                local r = DK.run(source, doc({ N('long', 'flow.wait', { seconds = 600 }), N('win', 'scenario.succeed') },
                    { { 'start', 'out', 'long' }, { 'long', 'done', 'win' } }, { settings = { maxRunSec = 2 } }))
                assertEqual(r.status, 'failed', 'failed (' .. DK.how(r) .. ')')
                assertEqual(r.reason, 'ran out of time', 'for its time')
                assertNil(r.late, 'by its own limit, not the test\'s')
            end,
        },
        {
            name = 'Nothing left to wait for: a branch that ends without Succeed or Fail fails the run',
            fn = function(source)
                local r = DK.run(source, doc({ N('set', 'var.set', { var = 'x', value = '1' }) }, { { 'start', 'out', 'set' } },
                    { vars = { DK.var('x', 0) } }))
                assertEqual(r.status, 'failed', 'failed')
                assertTrue(tostring(r.reason):find('nothing left to wait for', 1, true) ~= nil, 'saying so (' .. tostring(r.reason) .. ')')
            end,
        },
        {
            name = 'A reason can come from a variable',
            fn = function(source)
                local r = DK.run(source, doc({ N('lose', 'scenario.fail', { reason = { var = 'why' } }) }, { { 'start', 'out', 'lose' } },
                    { vars = { DK.var('why', 'the default') } }), { vars = { why = 'the alarm went off' } })
                assertEqual(r.reason, 'the alarm went off', 'the variable\'s text')
            end,
        },
        {
            name = 'Activate After Failure: its chain plays once the run fails, a Succeed in it changes nothing',
            fn = function(source)
                local r = DK.run(source, doc({
                    N('lose', 'scenario.fail', { reason = 'caught' }), N('after', 'run.afterFail'),
                    N('mark', 'var.set', { var = 'after', value = 'played' }), N('slow', 'flow.wait', { seconds = 1 }),
                    N('again', 'scenario.succeed', { reason = 'no' }),
                    N('afterWin', 'run.afterSuccess'), N('wrong', 'var.set', { var = 'wrong', value = 'yes' }),
                }, {
                    { 'start', 'out', 'lose' }, { 'after', 'out', 'mark' }, { 'mark', 'out', 'slow' }, { 'slow', 'done', 'again' },
                    { 'afterWin', 'out', 'wrong' },
                }, { vars = { DK.var('after', ''), DK.var('wrong', '') } }))
                assertEqual(r.status, 'failed', 'still failed (' .. DK.how(r) .. ')')
                assertEqual(r.reason, 'caught', 'with the Fail\'s reason')
                assertEqual(r.vars.after, 'played', 'the After Failure chain played')
                assertEqual(DK.fired(r, 'slow', 'done'), 1, 'its Wait too: the run waited for it')
                assertEqual(r.vars.wrong, '', 'not the After Success one')
            end,
        },
        {
            name = 'Activate After Success: its chain plays once the run succeeds',
            fn = function(source)
                local r = DK.run(source, doc({
                    N('win', 'scenario.succeed', { reason = 'paid' }), N('after', 'run.afterSuccess'),
                    N('mark', 'var.set', { var = 'after', value = 'played' }), N('afterLose', 'run.afterFail'),
                    N('wrong', 'var.set', { var = 'wrong', value = 'yes' }),
                }, { { 'start', 'out', 'win' }, { 'after', 'out', 'mark' }, { 'afterLose', 'out', 'wrong' } },
                { vars = { DK.var('after', ''), DK.var('wrong', '') } }))
                assertEqual(r.status, 'succeeded', 'succeeded')
                assertEqual(r.reason, 'paid', 'its reason')
                assertEqual(r.vars.after, 'played', 'the After Success chain played')
                assertEqual(r.vars.wrong, '', 'not the After Failure one')
            end,
        },
        {
            name = 'Running out of time is a failure too: After Failure plays',
            fn = function(source)
                local r = DK.run(source, doc({
                    N('long', 'flow.wait', { seconds = 600 }), N('win', 'scenario.succeed'), N('after', 'run.afterFail'),
                    N('mark', 'var.set', { var = 'after', value = 'played' }),
                }, { { 'start', 'out', 'long' }, { 'long', 'done', 'win' }, { 'after', 'out', 'mark' } },
                { vars = { DK.var('after', '') }, settings = { maxRunSec = 2 } }))
                assertEqual(r.reason, 'ran out of time', 'failed for its time')
                assertEqual(r.vars.after, 'played', 'its After Failure chain played')
            end,
        },
        {
            name = 'Ended from outside: aborted plays no After card; ended as failed does',
            fn = function(source)
                local function d()
                    return doc({ N('long', 'flow.wait', { seconds = 600 }), N('win', 'scenario.succeed'), N('after', 'run.afterFail'),
                                 N('mark', 'var.set', { var = 'after', value = 'played' }) },
                               { { 'start', 'out', 'long' }, { 'long', 'done', 'win' }, { 'after', 'out', 'mark' } },
                               { vars = { DK.var('after', '') } })
                end
                local r = DK.run(source, d(), { steer = { { op = 'end', when = 'long', reason = 'stopped by hand' } } })
                assertEqual(r.status, 'aborted', 'aborted')
                assertEqual(r.reason, 'stopped by hand', 'with the reason given')
                assertEqual(r.vars.after, '', 'no After card for an abort')
                r = DK.run(source, d(), { steer = { { op = 'end', when = 'long', outcome = 'failed', reason = 'failed by hand' } } })
                assertEqual(r.status, 'failed', 'ended as failed')
                assertEqual(r.vars.after, 'played', 'After Failure played')
            end,
        },
        {
            name = 'The lead-in: a Fail before Scenario Started By Player ends it quietly (aborted); after it, a real failure',
            fn = function(source)
                local r = DK.run(source, doc({ N('lose', 'scenario.fail', { reason = 'said no' }), N('begin', 'scenario.begin') },
                    { { 'start', 'out', 'lose' } }))
                assertEqual(r.status, 'aborted', 'before Scenario Started By Player: aborted (' .. DK.how(r) .. ')')
                assertTrue(tostring(r.reason):find('before Scenario Started By Player', 1, true) ~= nil, 'saying so (' .. tostring(r.reason) .. ')')
                r = DK.run(source, doc({ N('begin', 'scenario.begin'), N('lose', 'scenario.fail', { reason = 'caught' }) },
                    { { 'start', 'out', 'begin' }, { 'begin', 'started', 'lose' } }))
                assertEqual(DK.fired(r, 'begin', 'started'), 1, 'a Test\'s Scenario Started always starts')
                assertEqual(r.status, 'failed', 'after it: failed')
                assertEqual(r.reason, 'caught', 'with its reason')
            end,
        },
        {
            name = 'Scenario Started reached a second time goes on from Started',
            fn = function(source)
                local r = DK.run(source, doc({ N('seq', 'flow.sequence'), N('begin', 'scenario.begin'), N('slow', 'flow.wait', { seconds = 1 }),
                                               N('add', 'var.add', { var = 'n' }), N('end', 'flow.wait', { seconds = 2 }),
                                               N('win', 'scenario.succeed') },
                    { { 'start', 'out', 'seq' }, { 'seq', 'then1', 'begin' }, { 'seq', 'then2', 'slow' }, { 'slow', 'done', 'begin' },
                      { 'begin', 'started', 'add' }, { 'seq', 'then3', 'end' }, { 'end', 'done', 'win' } },
                    { vars = { DK.var('n', 0) } }))
                assertEqual(DK.fired(r, 'begin', 'started'), 2, 'both times: Started (' .. DK.how(r) .. ')')
                assertEqual(DK.fired(r, 'begin', 'notnow'), 0, 'never Not now')
                assertEqual(r.vars.n, 2, 'what follows it ran twice')
                assertEqual(r.status, 'succeeded', 'and the run went on')
            end,
        },
        {
            name = 'The test\'s own time: still going after opts.seconds, it is ended (aborted, late)',
            fn = function(source)
                local r = DK.run(source, doc({ N('long', 'flow.wait', { seconds = 600 }), N('win', 'scenario.succeed') },
                    { { 'start', 'out', 'long' }, { 'long', 'done', 'win' } }), { seconds = 2 })
                assertEqual(r.status, 'aborted', 'aborted')
                assertTrue(r.late, 'late: the test ended it')
            end,
        },
        {
            name = 'A result is kept after its end, and is nobody else\'s',
            fn = function(source)
                local r = DK.run(source, doc({ N('win', 'scenario.succeed', { reason = 'kept' }) }, { { 'start', 'out', 'win' } }))
                local again = DK.result(r.runId)
                assertNotNil(again, 'read again by its id')
                assertEqual(again.reason, 'kept', 'the same result')
                assertNil(DK.result(-1), 'no result for an id that is no test')
                local ok = DK.steer(r.runId, 'take', 'win', 'out')
                assertFalse(ok, 'an ended test cannot be steered')
            end,
        },
    },
})
