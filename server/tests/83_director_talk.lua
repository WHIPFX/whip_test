-- ============================================
-- Director: Conversations — Dialog Line, Goal: Talk To, Pick Team, Haggle (hot and cold, for a card), Sell to NPC
-- ============================================
--
-- The tester's answers are said into the run as the capsule would send them (TestDirectorScenario's `say`: the
-- card hears the choice, its id and an amount), so no screen needs pressing. Each talk is with an NPC the run made
-- on the test field. A Test pays, charges and buys nothing: what a deal agreed is read from its variable, and from
-- what a Give Item it was for hands out.

local N = DK.N

local function npcWorld() return { DK.npc('npc', DK.at(4, 0, DK.FIELD.heading + 180.0)) } end

--- start -> Spawn NPC -> the card `id` (its own fields), and its outcomes each ending with their name as the reason.
local function talkDoc(card, outs, spec)
    spec = spec or {}
    local nodes = { N('start', 'scenario.started'), N('spawn', 'npc.spawn', { npcs = { 'npc' } }), card }
    local links = { { 'start', 'out', 'spawn' }, { 'spawn', 'out', card.id } }
    for _, pin in ipairs(outs) do
        nodes[#nodes + 1] = N('end_' .. pin, 'scenario.succeed', { reason = pin })
        links[#links + 1] = { card.id, pin, 'end_' .. pin }
    end
    for _, n in ipairs(spec.nodes or {}) do nodes[#nodes + 1] = n end
    for _, l in ipairs(spec.links or {}) do links[#links + 1] = l end
    return DK.doc({ world = spec.world or npcWorld(), vars = spec.vars, nodes = nodes, links = links })
end

local HAGGLE = { 'deal', 'bad', 'walked', 'angry', 'timeout' }
local function haggle(props) local p = { npc = 'npc', base = 1000, floor = 700, ceiling = 1500, rounds = 3, priceVar = 'price' }
    for k, v in pairs(props or {}) do p[k] = v end
    return N('hg', 'npc.haggle', p)
end
local function say(option, amount) return { op = 'say', node = 'hg', option = option, amount = amount } end

RegisterTestModule({
    order    = 83,
    category = 'Director: Conversations',
    setup = function(source)
        local p = exports.whip_core:GetPlayer(source)
        if not (p and p.charId) then skip('the tester is not on a character') end
        DK.toField(source)
    end,
    teardown = function(ctx, source)
        DK.stopAll()
        RemoveAllOf(source, 'food')
        DK.goHome(source)
    end,
    tests = {
        {
            name = 'Dialog Line: the answer chosen is the way it goes on',
            fn = function(source)
                local line = N('dl', 'dialog.line', { npc = 'npc', line = 'Want the job?', opt1 = 'Yes', opt2 = 'No', opt3 = 'Maybe' })
                local r = DK.run(source, talkDoc(line, { 'opt1', 'opt2', 'opt3' }), { steer = { { op = 'say', node = 'dl', option = 'opt2' } } })
                assertEqual(r.reason, 'opt2', 'answer 2 (' .. DK.how(r) .. ')')
                r = DK.run(source, talkDoc(line, { 'opt1', 'opt2', 'opt3' }), { steer = { { op = 'say', node = 'dl', option = 'opt3' } } })
                assertEqual(r.reason, 'opt3', 'answer 3')
            end,
        },
        {
            name = 'Dialog Line on to another: two answers in a row',
            fn = function(source)
                local first = N('dl', 'dialog.line', { npc = 'npc', line = 'Ready?', opt1 = 'Yes', opt2 = 'No' })
                local r = DK.run(source, talkDoc(first, { 'opt2' }, {
                    nodes = { N('dl2', 'dialog.line', { npc = 'npc', line = 'Sure?', opt1 = 'Sure', opt2 = 'Not really' }),
                              N('sure', 'scenario.succeed', { reason = 'sure' }), N('not', 'scenario.succeed', { reason = 'not' }) },
                    links = { { 'dl', 'opt1', 'dl2' }, { 'dl2', 'opt1', 'sure' }, { 'dl2', 'opt2', 'not' } },
                }), { steer = { { op = 'say', node = 'dl', option = 'opt1' }, { op = 'say', node = 'dl2', option = 'opt1' } } })
                assertEqual(r.reason, 'sure', 'Yes, then Sure (' .. DK.how(r) .. ')')
            end,
        },
        {
            name = 'Dialog Line with nobody to speak (its NPC not made) goes out of Walked away',
            fn = function(source)
                local r = DK.run(source, DK.doc({
                    world = npcWorld(),
                    nodes = { N('start', 'scenario.started'), N('dl', 'dialog.line', { npc = 'npc', line = 'Hi', opt1 = 'Hi', away = 'out' }),
                              N('left', 'scenario.succeed', { reason = 'left' }), N('hi', 'scenario.succeed', { reason = 'hi' }) },
                    links = { { 'start', 'out', 'dl' }, { 'dl', 'left', 'left' }, { 'dl', 'opt1', 'hi' } },
                }))
                assertEqual(r.reason, 'left', 'Walked away (' .. DK.how(r) .. ')')
            end,
        },
        {
            name = 'Goal: Talk To: done once the talk with its NPC ends on an answer',
            fn = function(source)
                local r = DK.run(source, DK.doc({
                    world = npcWorld(),
                    nodes = { N('start', 'scenario.started'), N('spawn', 'npc.spawn', { npcs = { 'npc' } }), N('seq', 'flow.sequence'),
                              N('goal', 'goal.speakTo', { npc = 'npc' }),
                              N('dl', 'dialog.line', { npc = 'npc', line = 'Hello', opt1 = 'Hello back' }),
                              N('all', 'flow.waitAll'), N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'spawn' }, { 'spawn', 'out', 'seq' }, { 'seq', 'then1', 'goal' }, { 'seq', 'then2', 'dl' },
                              { 'goal', 'done', 'all', 'a' }, { 'dl', 'opt1', 'all', 'b' }, { 'all', 'done', 'win' } },
                }), { steer = { { op = 'say', node = 'dl', option = 'opt1' } } })
                assertEqual(r.status, 'succeeded', 'the goal and the line both went on (' .. DK.how(r) .. ')')
                assertEqual(DK.fired(r, 'goal', 'done'), 1, 'Talk To: done')
            end,
        },
        {
            name = 'Pick Team alone: Let\'s go is Ready with nobody else',
            fn = function(source)
                local r = DK.run(source, talkDoc(N('team', 'dialog.team', { npc = 'npc' }), { 'ready', 'left', 'timeout' }),
                    { steer = { { op = 'say', node = 'team', option = 'go' } } })
                assertEqual(r.reason, 'ready', 'Ready (' .. DK.how(r) .. ')')
            end,
        },
        {
            name = 'Haggle: a yes within its limit settles there (Deal), its price in the variable',
            fn = function(source)
                local r = DK.run(source, talkDoc(haggle(), HAGGLE, { vars = { DK.var('price', 0) } }),
                    { steer = { say('ask', 1200), say('take') } })
                assertEqual(r.reason, 'deal', 'Deal (' .. DK.how(r) .. ')')
                assertEqual(r.vars.price, 1200, 'at the price asked')
            end,
        },
        {
            name = 'Haggle: a No just past its limit costs patience, and the opening offer still stands',
            fn = function(source)
                local r = DK.run(source, talkDoc(haggle(), HAGGLE, { vars = { DK.var('price', 0) } }),
                    { steer = { say('ask', 1600), say('take') } })
                assertEqual(r.reason, 'deal', 'settled at its opening: still a Deal (' .. DK.how(r) .. ')')
                assertEqual(r.vars.price, 1000, 'its opening offer')
            end,
        },
        {
            name = 'Haggle: an insult with normal patience is Angry; with long patience it drops its offer (a Bad deal)',
            fn = function(source)
                local r = DK.run(source, talkDoc(haggle(), HAGGLE, { vars = { DK.var('price', 0) } }), { steer = { say('ask', 3000) } })
                assertEqual(r.reason, 'angry', 'an insult takes all its patience: Angry (' .. DK.how(r) .. ')')
                r = DK.run(source, talkDoc(haggle({ patience = 'long' }), HAGGLE, { vars = { DK.var('price', 0) } }),
                    { steer = { say('ask', 3000), say('take') } })
                assertEqual(r.reason, 'bad', 'settled after an insult: a Bad deal')
                assertEqual(r.vars.price, 700, 'at its worst offer (the floor)')
            end,
        },
        {
            name = 'Haggle: Forget it is Walked away',
            fn = function(source)
                local r = DK.run(source, talkDoc(haggle(), HAGGLE, { vars = { DK.var('price', 0) } }), { steer = { say('leave') } })
                assertEqual(r.reason, 'walked', 'Walked away')
            end,
        },
        {
            name = 'Haggling for a card: the count agreed is what Give Item hands out',
            fn = function(source, ctx)
                local before = DK.carried(source, 'food')
                local r = DK.start(source, talkDoc(haggle({ forCard = 'give', base = 2, floor = 1, ceiling = 5 }), { 'bad', 'walked', 'angry', 'timeout' }, {
                    vars = { DK.var('price', 0) },
                    nodes = { N('give', 'player.giveItem', { item = 'food', amount = 1 }), N('hold', 'flow.wait', { seconds = 600 }),
                              N('win', 'scenario.succeed', { reason = 'given' }), N('lose', 'scenario.fail', { reason = 'not given' }) },
                    links = { { 'hg', 'deal', 'give' }, { 'give', 'given', 'hold' }, { 'give', 'failed', 'lose' }, { 'give', 'timeout', 'lose' },
                              { 'hold', 'done', 'win' } },
                }), { steer = { say('ask', 4), say('take') } })
                ctx.runId = r.runId
                local got = DK.waiting(r.runId, 'hold', 15000)
                local now = DK.result(r.runId)
                if not got and now and now.reason == 'not given' then skip('the give did not go in (full pockets?)') end
                assertNotNil(got, 'agreed, then given (' .. DK.how(now) .. ')')
                assertEqual(now.vars.price, 4, 'agreed at 4')
                assertEqual(DK.carried(source, 'food') - before, 4, 'Give Item gave the 4 agreed, not its own 1')
                DK.stop(r.runId)
            end,
        },
        {
            name = 'Sell to NPC: nothing to sell goes out of Had none; with some, Sold in a Test takes nothing',
            fn = function(source)
                RemoveAllOf(source, 'food')
                local sell = N('sell', 'npc.sell', { npc = 'npc', item = 'food', price = 10, soldVar = 'sold' })
                local outs = { 'sold', 'nothing', 'cancelled', 'timeout' }
                local r = DK.run(source, talkDoc(sell, outs, { vars = { DK.var('sold', 0) } }))
                assertEqual(r.reason, 'nothing', 'none on them: Had none (' .. DK.how(r) .. ')')
                local ok = exports.whip_core:AddItem(source, 'food', 3)
                if not ok then skip('could not give the tester food to sell') end
                r = DK.run(source, talkDoc(sell, outs, { vars = { DK.var('sold', 0) } }), { steer = { { op = 'say', node = 'sell', option = 'yes' } } })
                assertEqual(r.reason, 'sold', 'Sold (' .. DK.how(r) .. ')')
                Wait(500)
                assertEqual(exports.whip_core:GetItemCount(source, 'food'), 3, 'a Test buys nothing: the 3 are still theirs')
                RemoveAllOf(source, 'food')
            end,
        },
    },
})
