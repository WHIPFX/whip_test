-- ============================================
-- Director: Player Cards — Give Item, Has Item?, Has Money?, Charge, Pay, messages, flags, the bar and the ring
-- ============================================
--
-- What a run does to its player, in a Test: Give hands out what the run's end takes back, Pay and Charge only say
-- what they would do, and a flag set in a Test is the test's alone (never the character's). The tester's real
-- pockets and money are read before and after: nothing a Test does may stay.

local N = DK.N
local ITEM = 'food'

-- (The run's own stacks counted too: GetItemCount leaves out what a run hands out.)
local function count(source) return DK.carried(source, ITEM) end
local function cash(source) return tonumber((exports.whip_core:GetPlayerCash(source))) or 0 end

RegisterTestModule({
    order    = 80,
    category = 'Director: Player Cards',
    setup = function(source)
        local p = exports.whip_core:GetPlayer(source)
        if not (p and p.charId) then skip('the tester is not on a character') end
    end,
    teardown = function(ctx)
        DK.stopAll()
    end,
    tests = {
        {
            name = 'Give Item: in their pockets while the Test runs, taken back when it ends',
            fn = function(source, ctx)
                local before = count(source)
                local r = DK.start(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('give', 'player.giveItem', { item = ITEM, amount = 2, keep = 'theirs to keep' }),
                              N('hold', 'flow.wait', { seconds = 600 }), N('win', 'scenario.succeed'), N('lose', 'scenario.fail', { reason = 'no give' }) },
                    links = { { 'start', 'out', 'give' }, { 'give', 'given', 'hold' }, { 'give', 'failed', 'lose' }, { 'give', 'timeout', 'lose' },
                              { 'hold', 'done', 'win' } },
                }))
                ctx.runId = r.runId
                local got = DK.firedWait(r.runId, 'give', 'given', 10000)
                if not got then
                    local now = DK.result(r.runId)
                    if now and DK.fired(now, 'give', 'failed') > 0 then skip('the give did not go in (full pockets?): ' .. DK.said(now, 'give')) end
                end
                assertNotNil(got, 'given')
                assertEqual(count(source), before + 2, 'two in their pockets while it runs')
                DK.steer(r.runId, 'take', 'hold', 'done')
                assertNotNil(DK.over(r.runId), 'it ended')
                local back = waitFor(function() return count(source) == before end, 8000)
                assertTrue(back ~= nil, ('taken back at its end, "theirs to keep" or not (%d, had %d)'):format(count(source), before))
            end,
        },
        {
            name = 'Player Has Item?: Yes with enough, No with too few; anyone and everyone in the run',
            fn = function(source)
                local before = count(source)
                local r = DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('give', 'player.giveItem', { item = ITEM, amount = 2 }),
                              N('two', 'player.hasItem', { item = ITEM, count = before + 2 }),
                              N('three', 'player.hasItem', { item = ITEM, count = before + 3 }),
                              N('any', 'player.hasItem', { item = ITEM, count = before + 1, who = 'anyone in the run' }),
                              N('all', 'player.hasItem', { item = ITEM, count = before + 1, who = 'everyone in the run' }),
                              N('win', 'scenario.succeed'), N('lose', 'scenario.fail', { reason = 'no give' }) },
                    links = { { 'start', 'out', 'give' }, { 'give', 'given', 'two' }, { 'give', 'failed', 'lose' }, { 'give', 'timeout', 'lose' },
                              { 'two', 'yes', 'three' }, { 'two', 'no', 'three' }, { 'three', 'yes', 'any' }, { 'three', 'no', 'any' },
                              { 'any', 'yes', 'all' }, { 'any', 'no', 'all' }, { 'all', 'yes', 'win' }, { 'all', 'no', 'win' } },
                }))
                if r.reason == 'no give' then skip('the give did not go in (full pockets?)') end
                assertEqual(DK.fired(r, 'two', 'yes'), 1, 'carrying 2 more: Yes (' .. DK.how(r) .. ')')
                assertEqual(DK.fired(r, 'three', 'no'), 1, 'asked for 3 more: No')
                assertEqual(DK.fired(r, 'any', 'yes'), 1, 'anyone in the run: Yes')
                assertEqual(DK.fired(r, 'all', 'yes'), 1, 'everyone in the run (only the tester): Yes')
                assertNotNil(waitFor(function() return count(source) == before end, 8000), 'and taken back after')
            end,
        },
        {
            name = 'Player Has Money? by cash: Yes for what they carry, No for a dollar more',
            fn = function(source)
                local have = cash(source)
                local function ask(amount)
                    return DK.run(source, DK.doc({
                        nodes = { N('start', 'scenario.started'), N('has', 'player.hasMoney', { amount = amount, where = 'cash' }),
                                  N('yes', 'scenario.succeed', { reason = 'yes' }), N('no', 'scenario.succeed', { reason = 'no' }) },
                        links = { { 'start', 'out', 'has' }, { 'has', 'yes', 'yes' }, { 'has', 'no', 'no' } },
                    }))
                end
                assertEqual(ask(have + 1).reason, 'no', ('$%d more than the $%d they carry: No'):format(1, have))
                if have >= 1 then assertEqual(ask(have).reason, 'yes', 'exactly what they carry: Yes') end
            end,
        },
        {
            name = 'Charge in a Test takes nothing: Paid when they could, Could not pay when not',
            fn = function(source)
                local have = cash(source)
                local function charge(amount)
                    return DK.run(source, DK.doc({
                        nodes = { N('start', 'scenario.started'), N('charge', 'player.charge', { amount = amount, method = 'cash' }),
                                  N('paid', 'scenario.succeed', { reason = 'paid' }), N('short', 'scenario.succeed', { reason = 'short' }),
                                  N('late', 'scenario.fail', { reason = 'late' }) },
                        links = { { 'start', 'out', 'charge' }, { 'charge', 'paid', 'paid' }, { 'charge', 'short', 'short' }, { 'charge', 'timeout', 'late' } },
                    }))
                end
                assertEqual(charge(have + 1).reason, 'short', 'more than they carry: Could not pay')
                if have >= 1 then assertEqual(charge(1).reason, 'paid', '$1 of what they carry: Paid') end
                assertEqual(cash(source), have, 'and their cash is as it was')
            end,
        },
        {
            name = 'Pay in a Test pays nothing, and goes on from Paid',
            fn = function(source)
                local have = cash(source)
                local r = DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('pay', 'player.pay', { amount = 5000, method = 'cash' }),
                              N('win', 'scenario.succeed', { reason = 'paid' }), N('lose', 'scenario.fail', { reason = 'not paid' }) },
                    links = { { 'start', 'out', 'pay' }, { 'pay', 'paid', 'win' }, { 'pay', 'failed', 'lose' }, { 'pay', 'timeout', 'lose' } },
                }))
                assertEqual(r.reason, 'paid', 'Paid')
                Wait(500)
                assertEqual(cash(source), have, 'not a dollar more')
            end,
        },
        {
            name = 'Message, Show Objective and Clear Objective go straight on',
            fn = function(source)
                local r = DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('msg', 'player.message', { text = '[whip_test] a Director message', kind = 'info' }),
                              N('obj', 'player.objective', { text = '[whip_test] an objective' }), N('wait', 'flow.wait', { seconds = 1 }),
                              N('clear', 'player.clearObjective'), N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'msg' }, { 'msg', 'out', 'obj' }, { 'obj', 'out', 'wait' }, { 'wait', 'done', 'clear' },
                              { 'clear', 'out', 'win' } },
                }))
                assertEqual(r.status, 'succeeded', 'through all three (' .. DK.how(r) .. ')')
            end,
        },
        {
            name = 'Player flags: on, a value, added to, off; a Test\'s flags are its own, never the character\'s',
            fn = function(source)
                local F = 'wtest_flag'
                local r = DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'),
                              N('on', 'flag.set', { flag = F, to = 'on' }), N('isOn', 'flag.if', { flag = F, op = 'is set' }),
                              N('val', 'flag.set', { flag = F, to = 'to a value', value = '3' }), N('is3', 'flag.if', { flag = F, op = 'is', value = '3' }),
                              N('add', 'flag.set', { flag = F, to = 'add a number', value = '2' }), N('atLeast5', 'flag.if', { flag = F, op = 'at least', value = '5' }),
                              N('off', 'flag.set', { flag = F, to = 'off' }), N('gone', 'flag.if', { flag = F, op = 'is not set' }),
                              N('win', 'scenario.succeed'), N('lose', 'scenario.fail', { reason = 'a flag test went No' }) },
                    links = { { 'start', 'out', 'on' }, { 'on', 'out', 'isOn' }, { 'isOn', 'yes', 'val' }, { 'isOn', 'no', 'lose' },
                              { 'val', 'out', 'is3' }, { 'is3', 'yes', 'add' }, { 'is3', 'no', 'lose' },
                              { 'add', 'out', 'atLeast5' }, { 'atLeast5', 'yes', 'off' }, { 'atLeast5', 'no', 'lose' },
                              { 'off', 'out', 'gone' }, { 'gone', 'yes', 'win' }, { 'gone', 'no', 'lose' } },
                }))
                assertEqual(r.status, 'succeeded', 'every flag test went Yes (' .. DK.how(r) .. ')')
                -- Set and left on in one Test: the next Test (a run of its own) does not see it.
                DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('on', 'flag.set', { flag = F, to = 'on' }), N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'on' }, { 'on', 'out', 'win' } },
                }))
                r = DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('has', 'flag.if', { flag = F, op = 'is set' }),
                              N('yes', 'scenario.succeed', { reason = 'kept' }), N('no', 'scenario.succeed', { reason = 'not kept' }) },
                    links = { { 'start', 'out', 'has' }, { 'has', 'yes', 'yes' }, { 'has', 'no', 'no' } },
                }))
                assertEqual(r.reason, 'not kept', 'a Test\'s flag is gone with it')
            end,
        },
        {
            name = 'Progress: the bar runs its length on the tester\'s screen, then Done',
            fn = function(source)
                local r = DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('bar', 'player.progress', { label = '[whip_test] working', seconds = 2, canCancel = false }),
                              N('done', 'scenario.succeed', { reason = 'done' }), N('stopped', 'scenario.fail', { reason = 'stopped' }),
                              N('late', 'scenario.fail', { reason = 'no answer' }) },
                    links = { { 'start', 'out', 'bar' }, { 'bar', 'done', 'done' }, { 'bar', 'stopped', 'stopped' }, { 'bar', 'timeout', 'late' } },
                }), { seconds = 30 })
                if HARNESS_OFFLINE then skip('needs the game') end
                assertEqual(r.reason, 'done', 'Done (' .. DK.how(r) .. ')')
                local at
                for _, s in ipairs(r.steps) do if s.node == 'bar' and s.kind == 'resume' then at = s.ms end end
                assertGte(at or 0, 1800, 'not before its 2 seconds')
            end,
        },
        {
            name = 'Skill Check: the ring waits on the tester; taken from the test map it goes on',
            fn = function(source, ctx)
                local r = DK.start(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('ring', 'player.skillCheck', { difficulty = 'easy' }),
                              N('passed', 'scenario.succeed', { reason = 'passed' }), N('missed', 'scenario.fail', { reason = 'missed' }),
                              N('late', 'scenario.fail', { reason = 'no answer' }) },
                    links = { { 'start', 'out', 'ring' }, { 'ring', 'passed', 'passed' }, { 'ring', 'failed', 'missed' }, { 'ring', 'timeout', 'late' } },
                }))
                ctx.runId = r.runId
                assertNotNil(DK.waiting(r.runId, 'ring', 5000), 'the ring waits')
                assertTrue((DK.steer(r.runId, 'take', 'ring', 'passed')), 'taken')
                r = DK.over(r.runId)
                assertEqual(r and r.reason, 'passed', 'on from Passed')
            end,
        },
    },
})
