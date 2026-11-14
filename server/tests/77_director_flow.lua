-- ============================================
-- Director: Flow — If, Do in Order, First Time Only, Wait, Wait for All, Random, variables, steering a run
-- ============================================
--
-- Whole scenarios run as the tester's Test (TestDirectorScenario: server/director/testing.lua), with no world:
-- what the run did is read back from its result (which cards went out of which outcome, its variables, how it
-- ended). Nothing here needs the tester anywhere in particular.

local N = DK.N

--- Pre-Scenario -> `first` ... and a Succeed and a Fail to end on.
local function ends() return N('win', 'scenario.succeed', { reason = 'ok' }), N('lose', 'scenario.fail', { reason = 'wrong way' }) end

--- A doc testing one If: x starts as `have`; yes succeeds, no fails.
local function ifDoc(have, op, value, vtype)
    local win, lose = ends()
    return DK.doc({
        name = 'If ' .. op,
        vars = { DK.var('x', have, vtype) },
        nodes = { N('start', 'scenario.started'), N('if', 'flow.if', { var = 'x', op = op, value = value }), win, lose },
        links = { { 'start', 'out', 'if' }, { 'if', 'yes', 'win' }, { 'if', 'no', 'lose' } },
    })
end

RegisterTestModule({
    order    = 77,
    category = 'Director: Flow',
    setup = function(source)
        local p = exports.whip_core:GetPlayer(source)
        if not (p and p.charId) then skip('the tester is not on a character') end
    end,
    tests = {
        {
            name = 'Pre-Scenario -> Succeed: the run succeeds with its reason, and its result says the way it went',
            fn = function(source)
                local r = DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('win', 'scenario.succeed', { reason = 'all done' }) },
                    links = { { 'start', 'out', 'win' } },
                }))
                assertEqual(r.status, 'succeeded', 'its end (' .. DK.how(r) .. ')')
                assertEqual(r.reason, 'all done', 'its reason')
                assertEqual(DK.fired(r, 'start', 'out'), 1, 'Pre-Scenario went out once')
                assertEqual(DK.entered(r, 'win'), 1, 'Succeed was reached')
                assertTrue(r.done, 'its result is final')
            end,
        },
        {
            name = 'Fail and Call Off end it as they say',
            fn = function(source)
                local r = DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('lose', 'scenario.fail', { reason = 'caught' }) },
                    links = { { 'start', 'out', 'lose' } },
                }))
                assertEqual(r.status, 'failed', 'Fail: failed')
                assertEqual(r.reason, 'caught', 'with its reason')
                r = DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('off', 'scenario.calloff', { reason = 'they said no' }) },
                    links = { { 'start', 'out', 'off' } },
                }))
                assertEqual(r.status, 'aborted', 'Call Off: no result (aborted)')
            end,
        },
        {
            name = 'Wait: it carries on after its time, not before',
            fn = function(source)
                local r = DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('wait', 'flow.wait', { seconds = 2 }), N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'wait' }, { 'wait', 'done', 'win' } },
                }))
                assertEqual(r.status, 'succeeded', 'it ended well (' .. DK.how(r) .. ')')
                local at
                for _, s in ipairs(r.steps) do if s.node == 'wait' and s.kind == 'resume' then at = s.ms end end
                assertNotNil(at, 'the Wait went on')
                assertGte(at, 1900, 'not before its 2 seconds (ms into the run)')
                assertTrue(at < 4500, 'and not long after (' .. tostring(at) .. ' ms)')
            end,
        },
        {
            name = 'If: each of its tests, on a number, a text and a true/false variable',
            fn = function(source)
                local cases = {
                    { 5, 'is', '5', true }, { 5, 'is', '6', false }, { 5, 'is not', '6', true },
                    { 5, 'more than', '4', true }, { 5, 'more than', '5', false }, { 5, 'less than', '6', true },
                    { 5, 'at least', '5', true }, { 5, 'at most', '4', false },
                    { 'gold', 'is', 'gold', true }, { 'gold', 'is not', 'gold', false },
                    { true, 'is', 'yes', true }, { false, 'is', 'true', false },
                }
                for _, c in ipairs(cases) do
                    local r = DK.run(source, ifDoc(c[1], c[2], c[3]))
                    local want = c[4] and 'yes' or 'no'
                    assertEqual(DK.fired(r, 'if', want), 1, ('%s %s %s goes %s'):format(tostring(c[1]), c[2], c[3], want))
                end
            end,
        },
        {
            name = 'If: "is set" and "is empty" (a variable with no value at the start)',
            fn = function(source)
                local r = DK.run(source, ifDoc(nil, 'is empty', nil, 'text'))
                assertEqual(DK.fired(r, 'if', 'yes'), 1, 'no value: is empty')
                r = DK.run(source, ifDoc(nil, 'is set', nil, 'text'))
                assertEqual(DK.fired(r, 'if', 'no'), 1, 'no value: not set')
                r = DK.run(source, ifDoc(nil, 'is set', nil, 'text'), { vars = { x = 'here' } })
                assertEqual(DK.fired(r, 'if', 'yes'), 1, 'given one by opts.vars before the first card: set')
            end,
        },
        {
            name = 'Set Variable and Add to Variable: a number from text, a true/false from "yes", adding and taking away',
            fn = function(source)
                local r = DK.run(source, DK.doc({
                    vars = { DK.var('n', 0), DK.var('ok', false), DK.var('word', '') },
                    nodes = { N('start', 'scenario.started'), N('setN', 'var.set', { var = 'n', value = '12' }),
                              N('add', 'var.add', { var = 'n', amount = 5 }), N('sub', 'var.add', { var = 'n', amount = -2 }),
                              N('setOk', 'var.set', { var = 'ok', value = 'yes' }), N('setW', 'var.set', { var = 'word', value = 'hello' }),
                              N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'setN' }, { 'setN', 'out', 'add' }, { 'add', 'out', 'sub' }, { 'sub', 'out', 'setOk' },
                              { 'setOk', 'out', 'setW' }, { 'setW', 'out', 'win' } },
                }))
                assertEqual(r.status, 'succeeded', 'it ran through (' .. DK.how(r) .. ')')
                assertEqual(r.vars.n, 15, '12, +5, -2')
                assertEqual(r.vars.ok, true, '"yes" into a true/false')
                assertEqual(r.vars.word, 'hello', 'text as typed')
            end,
        },
        {
            name = 'A field can read a variable: a Wait for as long as a variable says',
            fn = function(source)
                local r = DK.run(source, DK.doc({
                    vars = { DK.var('delay', 1) },
                    nodes = { N('start', 'scenario.started'), N('wait', 'flow.wait', { seconds = { var = 'delay' } }), N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'wait' }, { 'wait', 'done', 'win' } },
                }), { vars = { delay = 2 } })
                local at
                for _, s in ipairs(r.steps) do if s.node == 'wait' and s.kind == 'resume' then at = s.ms end end
                assertNotNil(at, 'the Wait went on (' .. DK.how(r) .. ')')
                assertGte(at, 1900, 'for the 2 seconds its variable held, not its default 1')
            end,
        },
        {
            name = 'Do in Order: all four go at once, Then 1 first',
            fn = function(source)
                local r = DK.run(source, DK.doc({
                    vars = { DK.var('order', '') },
                    nodes = { N('start', 'scenario.started'), N('seq', 'flow.sequence'),
                              N('a', 'var.set', { var = 'order', value = '1' }), N('b', 'var.add', { var = 'order', amount = 10 }),
                              N('c', 'var.add', { var = 'order', amount = 100 }), N('wait', 'flow.wait', { seconds = 1 }),
                              N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'seq' }, { 'seq', 'then1', 'a' }, { 'seq', 'then2', 'b' }, { 'seq', 'then3', 'c' },
                              { 'seq', 'then4', 'wait' }, { 'wait', 'done', 'win' } },
                }))
                assertEqual(r.status, 'succeeded', 'it ended (' .. DK.how(r) .. ')')
                -- (Then 1 set the text "1"; Then 2 and 3 added to it as a number: 1 + 10 + 100.)
                assertEqual(r.vars.order, 111, 'Then 1 before Then 2 and Then 3')
                for _, pin in ipairs({ 'then1', 'then2', 'then3', 'then4' }) do
                    assertEqual(DK.fired(r, 'seq', pin), 1, pin .. ' went out')
                end
            end,
        },
        {
            name = 'First Time Only: reached twice, it goes on once',
            fn = function(source)
                local r = DK.run(source, DK.doc({
                    vars = { DK.var('n', 0) },
                    nodes = { N('start', 'scenario.started'), N('seq', 'flow.sequence'), N('once', 'flow.once'),
                              N('add', 'var.add', { var = 'n', amount = 1 }), N('wait', 'flow.wait', { seconds = 1 }),
                              N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'seq' }, { 'seq', 'then1', 'once' }, { 'seq', 'then2', 'once' }, { 'once', 'out', 'add' },
                              { 'seq', 'then3', 'wait' }, { 'wait', 'done', 'win' } },
                }))
                assertEqual(DK.entered(r, 'once'), 2, 'it was reached twice (' .. DK.how(r) .. ')')
                assertEqual(DK.fired(r, 'once', 'out'), 1, 'it went on once')
                assertEqual(r.vars.n, 1, 'what came after it ran once')
            end,
        },
        {
            name = 'Wait for All: on once both wired inputs are reached, in either order',
            fn = function(source)
                local r = DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('seq', 'flow.sequence'), N('slow', 'flow.wait', { seconds = 1 }),
                              N('all', 'flow.waitAll'), N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'seq' }, { 'seq', 'then1', 'slow' }, { 'slow', 'done', 'all', 'a' },
                              { 'seq', 'then2', 'all', 'b' }, { 'all', 'done', 'win' } },
                }))
                assertEqual(r.status, 'succeeded', 'it went on (' .. DK.how(r) .. ')')
                assertEqual(DK.entered(r, 'all'), 2, 'reached by both')
                local doneAt, slowAt
                for _, s in ipairs(r.steps) do
                    if s.node == 'all' and s.kind == 'out' and s.pin == 'done' then doneAt = s.ms end
                    if s.node == 'slow' and s.kind == 'resume' then slowAt = s.ms end
                end
                assertNotNil(doneAt, 'Wait for All went out')
                assertGte(doneAt, slowAt or 0, 'only once the slow one got there')
            end,
        },
        {
            name = 'Reroute: what comes in goes straight out',
            fn = function(source)
                local r = DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('dot', 'flow.reroute'), N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'dot' }, { 'dot', 'out', 'win' } },
                }))
                assertEqual(r.status, 'succeeded', 'through the dot')
            end,
        },
        {
            name = 'Random Chance: 40 rolls at 50% go both ways; at 99% almost all go Yes',
            fn = function(source)
                local function rolls(chance)
                    return DK.run(source, DK.doc({
                        vars = { DK.var('n', 0), DK.var('y', 0), DK.var('no', 0) },
                        nodes = { N('start', 'scenario.started'), N('roll', 'flow.random', { chance = chance }),
                                  N('yes', 'var.add', { var = 'y' }), N('nope', 'var.add', { var = 'no' }),
                                  N('count', 'var.add', { var = 'n' }), N('more', 'flow.if', { var = 'n', op = 'less than', value = '40' }),
                                  N('again', 'flow.wait', { seconds = 0 }), N('win', 'scenario.succeed') },
                        links = { { 'start', 'out', 'roll' }, { 'roll', 'yes', 'yes' }, { 'roll', 'no', 'nope' },
                                  { 'yes', 'out', 'count' }, { 'nope', 'out', 'count' }, { 'count', 'out', 'more' },
                                  { 'more', 'yes', 'again' }, { 'again', 'done', 'roll' }, { 'more', 'no', 'win' } },
                    }), { seconds = 60 })
                end
                local r = rolls(50)
                assertEqual(r.status, 'succeeded', '40 rolls ran (' .. tostring(r.status) .. ' ' .. tostring(r.reason) .. ')')
                assertEqual((r.vars.y or 0) + (r.vars.no or 0), 40, 'each roll went one way')
                assertGt(r.vars.y or 0, 0, 'some Yes at 50%')
                assertGt(r.vars.no or 0, 0, 'some No at 50%')
                r = rolls(99)
                assertTrue((r.vars.no or 0) <= 5, ('at 99%%, few No (%s of 40)'):format(tostring(r.vars.no)))
            end,
        },
        {
            name = 'Countdown: Time\'s up after its seconds; a pulse into Stop calls it off',
            fn = function(source)
                local r = DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('clock', 'flow.countdown', { seconds = 1, show = false }),
                              N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'clock', 'start' }, { 'clock', 'done', 'win' } },
                }))
                assertEqual(DK.fired(r, 'clock', 'done'), 1, 'time\'s up (' .. DK.how(r) .. ')')
                r = DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('seq', 'flow.sequence'), N('clock', 'flow.countdown', { seconds = 30, show = false }),
                              N('soon', 'flow.wait', { seconds = 1 }), N('off', 'scenario.succeed', { reason = 'stopped' }),
                              N('late', 'scenario.fail', { reason = 'it ran out' }) },
                    links = { { 'start', 'out', 'seq' }, { 'seq', 'then1', 'clock', 'start' }, { 'seq', 'then2', 'soon' },
                              { 'soon', 'done', 'clock', 'stop' }, { 'clock', 'stopped', 'off' }, { 'clock', 'done', 'late' } },
                }))
                assertEqual(r.reason, 'stopped', 'Stop called it off before its 30 seconds (' .. DK.how(r) .. ')')
            end,
        },
        {
            name = 'Steering: Take an outcome of a waiting card, as the test map does',
            fn = function(source, ctx)
                local r = DK.start(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('long', 'flow.wait', { seconds = 600 }), N('win', 'scenario.succeed', { reason = 'taken' }) },
                    links = { { 'start', 'out', 'long' }, { 'long', 'done', 'win' } },
                }))
                ctx.runId = r.runId
                assertEqual(r.status, 'running', 'it answered at once, still going')
                assertNotNil(DK.waiting(r.runId, 'long', 5000), 'the ten-minute Wait waits')
                local ok, why = DK.steer(r.runId, 'take', 'long', 'done')
                assertTrue(ok, 'Take (' .. tostring(why) .. ')')
                r = DK.over(r.runId)
                assertNotNil(r, 'it ended')
                assertEqual(r.reason, 'taken', 'on from the outcome taken, long before its ten minutes')
            end,
        },
        {
            name = 'Steering: a variable set while it runs, then read by the card after',
            fn = function(source, ctx)
                local win, lose = ends()
                local r = DK.start(source, DK.doc({
                    vars = { DK.var('x', 0) },
                    nodes = { N('start', 'scenario.started'), N('wait', 'flow.wait', { seconds = 2 }),
                              N('if', 'flow.if', { var = 'x', op = 'is', value = '5' }), win, lose },
                    links = { { 'start', 'out', 'wait' }, { 'wait', 'done', 'if' }, { 'if', 'yes', 'win' }, { 'if', 'no', 'lose' } },
                }))
                ctx.runId = r.runId
                local ok, why = DK.steer(r.runId, 'var', 'x', 5)
                assertTrue(ok, 'set (' .. tostring(why) .. ')')
                r = DK.over(r.runId)
                assertEqual(r and r.status, 'succeeded', 'If saw 5 (' .. DK.how(r) .. ')')
            end,
        },
        {
            name = 'Steering: Wait for Script Event hears an event sent into the test, and Not in time without one',
            fn = function(source)
                local function doc(who)
                    return DK.doc({
                        nodes = { N('start', 'scenario.started'), N('ear', 'script.wait', { event = 'wtest.go', who = who, seconds = 4 }),
                                  N('heard', 'scenario.succeed', { reason = 'heard' }), N('late', 'scenario.fail', { reason = 'late' }) },
                        links = { { 'start', 'out', 'ear' }, { 'ear', 'heard', 'heard' }, { 'ear', 'timeout', 'late' } },
                    })
                end
                local r = DK.run(source, doc('Sent for this run'), { steer = { { op = 'event', name = 'wtest.go', when = 'ear' } } })
                assertEqual(r.reason, 'heard', 'sent for this run: heard (' .. DK.how(r) .. ')')
                r = DK.run(source, doc('About a player in this run'), { steer = { { op = 'event', name = 'wtest.go', when = 'ear', payload = { source = source } } } })
                assertEqual(r.reason, 'heard', 'about the tester: heard')
                r = DK.run(source, doc('Sent for this run'), { steer = { { op = 'event', name = 'wtest.other', when = 'ear' } } })
                assertEqual(r.reason, 'late', 'another event: not heard, Not in time')
            end,
        },
        {
            name = 'Send Signal goes on, and a Test\'s signal reaches no script',
            fn = function(source)
                local heard = 0
                local h = AddEventHandler('whip_core:run:signalled', function() heard = heard + 1 end)
                local r = DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('sig', 'script.signal', { name = 'wtest_alarm', value = 'loud' }),
                              N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'sig' }, { 'sig', 'out', 'win' } },
                }))
                Wait(300)
                RemoveEventHandler(h)
                assertEqual(r.status, 'succeeded', 'it went on')
                assertEqual(heard, 0, 'no script heard a Test\'s signal')
            end,
        },
    },
    teardown = function(ctx)
        DK.stopAll()
    end,
})
