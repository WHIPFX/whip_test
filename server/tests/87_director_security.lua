-- ============================================
-- Director: Security — what TestDirectorScenario and SteerDirectorTest refuse, and that a test is no script's run
-- ============================================
--
-- A scripted test is a Test: it is hidden from the Director API as a builder's is (ListScenarioRuns, GetScenarioRun,
-- the run events), a script may not write its variables or crew, and only the resource that started it may steer it
-- or read its result. What it is given is checked before anything runs.

local N = DK.N

local function plainDoc(waitSec)
    return DK.doc({
        nodes = { N('start', 'scenario.started'), N('hold', 'flow.wait', { seconds = waitSec or 600 }), N('win', 'scenario.succeed') },
        links = { { 'start', 'out', 'hold' }, { 'hold', 'done', 'win' } },
    })
end

local function refusedWith(r, why, text, label)
    assertFalse(r, label .. ': refused')
    assertTrue(tostring(why):find(text, 1, true) ~= nil, ('%s: saying "%s" (%s)'):format(label, text, tostring(why)))
end

RegisterTestModule({
    order    = 87,
    category = 'Director: Security',
    setup = function(source)
        local p = exports.whip_core:GetPlayer(source)
        if not (p and p.charId) then skip('the tester is not on a character') end
    end,
    teardown = function(ctx)
        DK.stopAll()
    end,
    tests = {
        {
            name = 'TestDirectorScenario checks what it is given before anything runs',
            fn = function(source)
                local T = function(doc, opts) return exports.whip_core:TestDirectorScenario(doc, opts) end
                local r, why = T('not a doc', { player = source })
                refusedWith(r, why, 'a scenario is a document', 'not a document')
                r, why = T(plainDoc(), {})
                refusedWith(r, why, 'opts.player', 'no player')
                r, why = T(plainDoc(), { player = 65000 })
                refusedWith(r, why, 'opts.player', 'nobody on that id')
                r, why = T(plainDoc(), { player = source, seconds = 0 })
                refusedWith(r, why, 'opts.seconds is 1 to', 'no time')
                r, why = T(plainDoc(), { player = source, seconds = 601 })
                refusedWith(r, why, 'opts.seconds is 1 to', 'too long')
                r, why = T(plainDoc(), { player = source, vars = 'x' })
                refusedWith(r, why, 'opts.vars', 'vars not a table')
                r, why = T(plainDoc(), { player = source, steer = { { op = 'jump' } } })
                refusedWith(r, why, 'opts.steer[1]', 'an op it has not got')
                r, why = T(DK.doc({ nodes = { N('win', 'scenario.succeed') } }), { player = source })
                refusedWith(r, why, 'Check:', 'a scenario that fails Check')
            end,
        },
        {
            name = 'One scripted test per player at a time',
            fn = function(source, ctx)
                local r = DK.start(source, plainDoc())
                ctx.runId = r.runId
                local again, why = exports.whip_core:TestDirectorScenario(plainDoc(), { player = source, wait = false })
                refusedWith(again, why, 'already has a scripted test going', 'a second for the tester')
                DK.stop(r.runId)
                ctx.runId = nil
                local after = DK.start(source, plainDoc())
                assertEqual(after.status, 'running', 'once the first is over, another starts')
                DK.stop(after.runId)
            end,
        },
        {
            name = 'SteerDirectorTest refuses what is not so: no such test, an op it has not got, a card not waiting, bad values',
            fn = function(source, ctx)
                local ok, why = DK.steer(-5, 'take', 'hold', 'done')
                refusedWith(ok, why, 'no scripted test of yours', 'no such test')
                local r = DK.start(source, DK.doc({
                    vars = { DK.var('x', 0) },
                    nodes = { N('start', 'scenario.started'), N('hold', 'flow.wait', { seconds = 600 }), N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'hold' }, { 'hold', 'done', 'win' } },
                }))
                ctx.runId = r.runId
                assertNotNil(DK.waiting(r.runId, 'hold', 5000), 'its Wait waits')
                ok, why = DK.steer(r.runId, 'fly')
                refusedWith(ok, why, 'op is', 'an op it has not got')
                ok, why = DK.steer(r.runId, 'take', 'win', 'out')
                refusedWith(ok, why, 'is not waiting', 'Take on a card not waiting')
                ok, why = DK.steer(r.runId, 'take', 'hold', 'nope')
                refusedWith(ok, why, 'has no outcome', 'Take of an outcome it has not got')
                ok, why = DK.steer(r.runId, 'say', 'win', 'opt1')
                refusedWith(ok, why, 'is not waiting', 'an answer to a card not waiting')
                ok, why = DK.steer(r.runId, 'var', 'x', { 1, 2 })
                refusedWith(ok, why, 'a variable is a number', 'a table into a variable')
                ok, why = DK.steer(r.runId, 'var', 'bad name!', 1)
                refusedWith(ok, why, 'a variable\'s name', 'a name that is not one')
                ok, why = DK.steer(r.runId, 'event', 'no spaces allowed', {})
                refusedWith(ok, why, 'an event\'s name', 'an event name that is not one')
                assertEqual(DK.result(r.runId).status, 'running', 'none of it touched the run')
                DK.stop(r.runId)
                ctx.runId = nil
            end,
        },
        {
            name = 'A scripted test is no script\'s run: unlisted, unfound, its events unheard, its variables and crew not theirs to change',
            fn = function(source, ctx)
                local told = 0
                local h1 = AddEventHandler('whip_core:run:started', function() told = told + 1 end)
                local r = DK.start(source, DK.doc({
                    vars = { DK.var('x', 0) },
                    nodes = { N('start', 'scenario.started'), N('hold', 'flow.wait', { seconds = 600 }), N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'hold' }, { 'hold', 'done', 'win' } },
                }))
                ctx.runId = r.runId
                Wait(500)
                RemoveEventHandler(h1)
                local listed, listedWithTests = false, false
                for _, v in ipairs(exports.whip_core:ListScenarioRuns() or {}) do if v.id == r.runId then listed = true end end
                for _, v in ipairs(exports.whip_core:ListScenarioRuns({ tests = true }) or {}) do if v.id == r.runId then listedWithTests = true end end
                assertFalse(listed, 'not in ListScenarioRuns')
                assertTrue(listedWithTests, 'only when tests are asked for')
                assertFalse((exports.whip_core:GetScenarioRun(r.runId)), 'not found by its id')
                assertType(exports.whip_core:GetScenarioRun(r.runId, { tests = true }), 'table', 'found when tests are asked for')
                assertFalse(exports.whip_core:IsPlayerInScenarioRun(source), 'the tester is not "in a run" to scripts')
                assertEqual(told, 0, 'no script heard run:started')
                local ok, why = exports.whip_core:SetScenarioRunVar(r.runId, 'x', 3)
                refusedWith(ok, why, 'Test', 'SetScenarioRunVar')
                ok, why = exports.whip_core:AddPlayerToScenarioRun(r.runId, source)
                refusedWith(ok, why, 'Test', 'AddPlayerToScenarioRun')
                assertTrue((exports.whip_core:EndScenarioRun(r.runId, 'calledOff', 'ended by the test')), 'EndScenarioRun may end it (a script ending what it started)')
                local over = DK.over(r.runId)
                assertEqual(over and over.status, 'aborted', 'ended')
                ctx.runId = nil
            end,
        },
        {
            name = 'What a scripted test hands out never stays, whatever the card says',
            fn = function(source)
                local before = DK.carried(source, 'food')
                local r = DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('give', 'player.giveItem', { item = 'food', amount = 1, keep = 'theirs to keep' }),
                              N('win', 'scenario.succeed'), N('lose', 'scenario.fail', { reason = 'no give' }) },
                    links = { { 'start', 'out', 'give' }, { 'give', 'given', 'win' }, { 'give', 'failed', 'lose' }, { 'give', 'timeout', 'lose' } },
                }))
                if r.reason == 'no give' then skip('the give did not go in (full pockets?)') end
                assertNotNil(waitFor(function() return DK.carried(source, 'food') == before end, 8000),
                    'taken back as the run ended')
            end,
        },
    },
})
