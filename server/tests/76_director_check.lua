-- ============================================
-- Director: Check — what CheckDirectorScenario says of a scenario before it can run (server/director/graph.lua)
-- ============================================
--
-- Each case is a small document with one thing wrong (or nothing): whether it passes, and the problem Check names,
-- as the editor's Check button shows it. No run starts here.

local N = DK.N
local F = { x = 100.0, y = 200.0, z = 30.0, heading = 0.0 }

--- Check one doc: passes?, and every problem as "[severity] node: message" lines.
local function check(doc)
    local ok, probs = exports.whip_core:CheckDirectorScenario(doc)
    local lines = {}
    for _, p in ipairs(probs or {}) do
        lines[#lines + 1] = ('[%s] %s%s'):format(tostring(p.severity), p.node and (p.node .. ': ') or '', tostring(p.message))
    end
    return ok, lines, probs or {}
end

--- Does some problem of this severity say `text` (about `node`, when given)?
local function says(probs, severity, text, node)
    for _, p in ipairs(probs) do
        if p.severity == severity and tostring(p.message):find(text, 1, true) and (node == nil or p.node == node) then return true end
    end
    return false
end

--- One case: it passes or not, and (when given) an error or warning saying `text`.
local function expect(doc, passes, severity, text, node)
    local ok, lines, probs = check(doc)
    local all = table.concat(lines, ' | ')
    assertEqual(ok == true, passes, (passes and 'passes' or 'does not pass') .. ' (' .. all .. ')')
    if text then assertTrue(says(probs, severity, text, node), ('%s "%s"%s (%s)'):format(severity, text, node and (' on ' .. node) or '', all)) end
end

local function plain(nodes, links, spec)
    spec = spec or {}
    spec.nodes, spec.links = nodes, links
    return DK.doc(spec)
end

local function spawnThen(world, card)
    return plain({ N('start', 'scenario.started'), N('sp', 'npc.spawn', { npcs = { 'npc' } }), card, N('win', 'scenario.succeed') },
                 { { 'start', 'out', 'sp' }, { 'sp', 'out', card.id }, { card.id, 'done', 'win' } }, { world = world })
end

RegisterTestModule({
    order    = 76,
    category = 'Director: Check',
    tests = {
        {
            name = 'A plain scenario passes with no problems',
            fn = function()
                local ok, lines = check(plain({ N('start', 'scenario.started'), N('win', 'scenario.succeed') }, { { 'start', 'out', 'win' } }))
                assertTrue(ok, 'passes')
                assertEqual(#lines, 0, 'and says nothing (' .. table.concat(lines, ' | ') .. ')')
            end,
        },
        {
            name = 'What a run needs: a Pre-Scenario to start it, a Succeed it can reach',
            fn = function()
                expect(plain({ N('win', 'scenario.succeed') }, {}), false, 'error', 'nothing starts this scenario')
                expect(plain({ N('start', 'scenario.started'), N('lose', 'scenario.fail') }, { { 'start', 'out', 'lose' } }),
                    false, 'error', 'there is no Succeed card')
                expect(plain({ N('start', 'scenario.started'), N('win', 'scenario.succeed') }, { { 'start', 'nope', 'win' } }),
                    false, 'error', 'nothing leads to a Succeed card')
            end,
        },
        {
            name = 'Broken pieces: a document that is not one, an unknown card, two cards with one id',
            fn = function()
                expect({ format = 2, name = 'x', nodes = 'oops' }, false, 'error', 'the scenario\'s nodes are not a list')
                expect({ format = 1, name = 'x', nodes = {} }, false, 'error', 'made before the Director was rebuilt')
                expect(plain({ N('start', 'scenario.started'), N('x', 'nope.card'), N('win', 'scenario.succeed') },
                    { { 'start', 'out', 'x' } }), false, 'error', 'unknown card type "nope.card"', 'x')
                expect(plain({ N('start', 'scenario.started'), N('start', 'scenario.succeed') }, {}), false, 'error', 'two cards share this id')
            end,
        },
        {
            name = 'Wires: to a card that is not there, from or into a pin the card has not got',
            fn = function()
                expect(plain({ N('start', 'scenario.started'), N('win', 'scenario.succeed') }, { { 'start', 'out', 'win' }, { 'start', 'out', 'ghost' } }),
                    false, 'error', 'a wire goes to a card that does not exist')
                expect(plain({ N('start', 'scenario.started'), N('win', 'scenario.succeed') }, { { 'start', 'nope', 'win' } }),
                    false, 'error', 'a wire leaves from "nope"')
                expect(plain({ N('start', 'scenario.started'), N('win', 'scenario.succeed') }, { { 'start', 'out', 'win', 'side' } }),
                    false, 'error', 'a wire arrives at "side"')
                -- A Fail Condition is wired to nothing: a wire into one is refused.
                expect(plain({ N('start', 'scenario.started'), N('fv', 'fail.variable', { var = 'x', op = 'more than', value = '3' }),
                               N('win', 'scenario.succeed') }, { { 'start', 'out', 'fv' }, { 'start', 'out', 'win' } }, { vars = { DK.var('x', 0) } }),
                    false, 'error', 'a wire arrives at "in"', 'fv')
            end,
        },
        {
            name = 'Fields: a required one empty, a variable or placed thing that is not there, the wrong kind of thing',
            fn = function()
                expect(plain({ N('start', 'scenario.started'), N('msg', 'player.message', {}), N('win', 'scenario.succeed') },
                    { { 'start', 'out', 'msg' }, { 'msg', 'out', 'win' } }), false, 'error', 'is empty', 'msg')
                expect(plain({ N('start', 'scenario.started'), N('set', 'var.set', { var = 'ghost', value = '1' }), N('win', 'scenario.succeed') },
                    { { 'start', 'out', 'set' }, { 'set', 'out', 'win' } }), false, 'error', 'a variable that does not exist', 'set')
                expect(plain({ N('start', 'scenario.started'), N('sp', 'npc.spawn', { npcs = { 'ghost' } }), N('win', 'scenario.succeed') },
                    { { 'start', 'out', 'sp' }, { 'sp', 'out', 'win' } }), false, 'error', 'a placed thing that does not exist', 'sp')
                expect(plain({ N('start', 'scenario.started'), N('sp', 'npc.spawn', { npcs = { 'car' } }), N('win', 'scenario.succeed') },
                    { { 'start', 'out', 'sp' }, { 'sp', 'out', 'win' } }, { world = { DK.car('car', F) } }), false, 'error', 'is a vehicle, not a npc', 'sp')
                expect(plain({ N('start', 'scenario.started'), N('give', 'player.giveItem', { item = 'not_an_item_zz' }), N('win', 'scenario.succeed') },
                    { { 'start', 'out', 'give' }, { 'give', 'given', 'win' } }), false, 'error', 'is not an item on this server', 'give')
            end,
        },
        {
            name = 'Names: two variables or two placed things with one name; a signal and an event in their shape',
            fn = function()
                expect(plain({ N('start', 'scenario.started'), N('win', 'scenario.succeed') }, { { 'start', 'out', 'win' } },
                    { vars = { DK.var('a', 1), DK.var('a', 2) } }), false, 'error', 'two variables are called a')
                expect(plain({ N('start', 'scenario.started'), N('win', 'scenario.succeed') }, { { 'start', 'out', 'win' } },
                    { world = { DK.car('a', F), DK.npc('a', F) } }), false, 'error', 'two placed things share the id a')
                expect(plain({ N('start', 'scenario.started'), N('sig', 'script.signal', { name = 'two words' }), N('win', 'scenario.succeed') },
                    { { 'start', 'out', 'sig' }, { 'sig', 'out', 'win' } }), false, 'error', 'A signal is one word', 'sig')
                expect(plain({ N('start', 'scenario.started'), N('ear', 'script.wait', { event = 'nodot' }), N('win', 'scenario.succeed') },
                    { { 'start', 'out', 'ear' }, { 'ear', 'heard', 'win' } }), false, 'error', 'two words with a dot', 'ear')
            end,
        },
        {
            name = 'Loops: one that never waits is refused; one through a Wait passes',
            fn = function()
                expect(plain({ N('start', 'scenario.started'), N('a', 'var.add', { var = 'x' }), N('b', 'var.add', { var = 'x' }), N('win', 'scenario.succeed') },
                    { { 'start', 'out', 'a' }, { 'a', 'out', 'b' }, { 'b', 'out', 'a' } }, { vars = { DK.var('x', 0) } }),
                    false, 'error', 'in a loop that never waits')
                expect(plain({ N('start', 'scenario.started'), N('a', 'var.add', { var = 'x' }), N('w', 'flow.wait', { seconds = 1 }),
                               N('if', 'flow.if', { var = 'x', op = 'at least', value = '3' }), N('win', 'scenario.succeed') },
                    { { 'start', 'out', 'a' }, { 'a', 'out', 'if' }, { 'if', 'no', 'w' }, { 'w', 'done', 'a' }, { 'if', 'yes', 'win' } },
                    { vars = { DK.var('x', 0) } }), true)
            end,
        },
        {
            name = 'Warnings, which still pass: an outcome that goes nowhere, a card nothing leads to',
            fn = function()
                expect(plain({ N('start', 'scenario.started'), N('if', 'flow.if', { var = 'x', op = 'is', value = '1' }), N('win', 'scenario.succeed') },
                    { { 'start', 'out', 'if' }, { 'if', 'yes', 'win' } }, { vars = { DK.var('x', 0) } }),
                    true, 'warning', 'the "no" outcome goes nowhere', 'if')
                expect(plain({ N('start', 'scenario.started'), N('win', 'scenario.succeed'), N('lost', 'player.message', { text = 'hi' }) },
                    { { 'start', 'out', 'win' } }), true, 'warning', 'nothing leads to this card', 'lost')
            end,
        },
        {
            name = 'Tasks: Start Tasks on a thing with none, on one no card makes, a step its kind cannot do, Finished that never comes',
            fn = function()
                expect(spawnThen({ DK.npc('npc', F) }, N('ts', 'tasks.start', { things = { 'npc' } })), false, 'error', 'has no tasks yet', 'ts')
                expect(plain({ N('start', 'scenario.started'), N('ts', 'tasks.start', { things = { 'npc' } }), N('win', 'scenario.succeed') },
                    { { 'start', 'out', 'ts' }, { 'ts', 'done', 'win' } },
                    { world = { DK.npc('npc', F, { tasks = { list = { { k = 'a', t = 'wait', sec = 1 } } } }) } }),
                    false, 'error', 'no card makes "npc"', 'ts')
                expect(spawnThen({ DK.npc('npc', F, { tasks = { list = { { k = 'a', t = 'siren' } } } }) }, N('ts', 'tasks.start', { things = { 'npc' } })),
                    false, 'error', 'a npc cannot do it')
                expect(spawnThen({ DK.npc('npc', F, { tasks = { after = 'loop', list = { { k = 'a', t = 'wait', sec = 1 } } } }) },
                    N('ts', 'tasks.start', { things = { 'npc' } })), false, 'error', 'the "Finished" outcome never comes', 'ts')
                expect(spawnThen({ DK.npc('npc', F, { tasks = { list = { { k = 'a', t = 'wait', sec = 1 } } } }) },
                    N('ts', 'tasks.start', { things = { 'npc' } })), true)
            end,
        },
        {
            name = 'A driving event must be one the car has',
            fn = function()
                expect(plain({ N('start', 'scenario.started'), N('pt', 'vehicle.playTake', { car = 'car', take = 99 }), N('win', 'scenario.succeed') },
                    { { 'start', 'out', 'pt' }, { 'pt', 'done', 'win' } }, { world = { DK.car('car', F) } }),
                    false, 'error', 'pick one of the car\'s driving events', 'pt')
            end,
        },
        {
            name = 'Lead-in: Scenario Started with no Pre-Scenario before it is never reached',
            fn = function()
                expect(plain({ N('begin', 'scenario.begin'), N('win', 'scenario.succeed') }, { { 'begin', 'started', 'win' } }),
                    false, 'error', 'nothing starts this scenario')
            end,
        },
        {
            name = 'Not a scenario at all: refused with a reason, never a throw',
            fn = function()
                local ok, probs = exports.whip_core:CheckDirectorScenario('a string')
                assertFalse(ok, 'refused')
                assertTrue(type(probs) == 'table' and probs[1] and probs[1].severity == 'error', 'with an error saying why')
            end,
        },
    },
})
