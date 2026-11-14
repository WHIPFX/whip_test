-- ============================================
-- Director: Goals — Go To, Player Arrives / Leaves, Steal and Deliver the Car, Car Entered, Bring, Collect,
-- Survive, Kill Them All
-- ============================================
--
-- On the test field, the tester is moved where a goal wants them (DK.teleport) or put in the run's car (the
-- kit's enter), and the goal must go on, and not before. Nothing here needs a second player.

local N = DK.N

local function madeNet(runId, wid, ms)
    local r = DK.when(runId, function(x) return type(x.things[wid]) == 'table' and x.things[wid].netId ~= nil end, ms or 15000)
    return r and r.things[wid].netId or nil
end

local function enter(source, net, seat)
    local got, came = DK.ask(source, 'enter', { net = net, seat = seat or -1 }, 8000)
    return came and type(got) == 'table' and got.ok == true
end

RegisterTestModule({
    order    = 82,
    category = 'Director: Goals',
    setup = function(source)
        local p = exports.whip_core:GetPlayer(source)
        if not (p and p.charId) then skip('the tester is not on a character') end
        DK.toField(source)
    end,
    teardown = function(ctx, source)
        DK.stopAll()
        ClientLeaveVehicle(source)
        DK.goHome(source)
    end,
    tests = {
        {
            name = 'Goal: Go To waits while the tester is away, and goes on once they are there',
            fn = function(source, ctx)
                DK.teleport(source, DK.FIELD)
                local spot = DK.at(30, 0)
                local r = DK.start(source, DK.doc({
                    world = { DK.spot('there', spot) },
                    nodes = { N('start', 'scenario.started'), N('go', 'goal.goTo', { at = 'there', radius = 4 }), N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'go' }, { 'go', 'done', 'win' } },
                }))
                ctx.runId = r.runId
                assertNotNil(DK.waiting(r.runId, 'go', 5000), 'the goal is up')
                Wait(2500)
                assertEqual(DK.result(r.runId).status, 'running', 'not done while they are 30 m away')
                DK.teleport(source, spot)
                r = DK.over(r.runId, 10000)
                assertEqual(r and r.status, 'succeeded', 'Arrived once there (' .. DK.how(r) .. ')')
            end,
        },
        {
            name = 'Player Arrives and Player Leaves: within its distance, then out of it',
            fn = function(source, ctx)
                DK.teleport(source, DK.FIELD)
                local spot = DK.at(25, 10)
                local r = DK.start(source, DK.doc({
                    world = { DK.spot('there', spot) },
                    nodes = { N('start', 'scenario.started'), N('in', 'area.entered', { at = 'there', radius = 5 }),
                              N('out', 'area.left', { at = 'there', radius = 5 }), N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'in' }, { 'in', 'entered', 'out' }, { 'out', 'left', 'win' } },
                }))
                ctx.runId = r.runId
                assertNotNil(DK.waiting(r.runId, 'in', 5000), 'waiting for them to arrive')
                DK.teleport(source, spot)
                assertNotNil(DK.waiting(r.runId, 'out', 8000), 'arrived; now waiting for them to leave')
                Wait(1500)
                assertEqual(DK.result(r.runId).status, 'running', 'not left while still there')
                DK.teleport(source, DK.FIELD)
                r = DK.over(r.runId, 10000)
                assertEqual(r and r.status, 'succeeded', 'left (' .. DK.how(r) .. ')')
            end,
        },
        {
            name = 'Goal: Steal the Car and Car Entered: done once the tester is at its wheel',
            fn = function(source, ctx)
                DK.teleport(source, DK.FIELD)
                local at = DK.at(10, 6, 150.0)
                at.z = at.z + 0.5
                local r = DK.start(source, DK.doc({
                    world = { DK.car('car', at) },
                    -- (Car Entered is an event card: it listens from the run's start, nothing wired into it.)
                    nodes = { N('start', 'scenario.started'), N('spawn', 'vehicle.spawn', { cars = { 'car' } }),
                              N('steal', 'goal.stealCar', { car = 'car' }), N('entered', 'vehicle.entered', { car = 'car' }),
                              N('all', 'flow.waitAll'), N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'spawn' }, { 'spawn', 'out', 'steal' },
                              { 'steal', 'done', 'all', 'a' }, { 'entered', 'out', 'all', 'b' }, { 'all', 'done', 'win' } },
                }))
                ctx.runId = r.runId
                local net = madeNet(r.runId, 'car')
                assertNotNil(net, 'the car was made')
                Wait(1500)
                assertEqual(DK.fired(DK.result(r.runId), 'steal', 'done'), 0, 'not stolen before they get in')
                assertTrue(enter(source, net, -1), 'the tester is at the wheel')
                r = DK.over(r.runId, 10000)
                assertEqual(r and r.status, 'succeeded', 'both went on (' .. DK.how(r) .. ')')
                ClientLeaveVehicle(source)
            end,
        },
        {
            name = 'Goal: Deliver the Car: only once a player of the run drives it there',
            fn = function(source, ctx)
                DK.teleport(source, DK.FIELD)
                local drop = DK.at(14, -6)
                local at = DK.at(14, -4, 150.0)
                at.z = at.z + 0.5
                local r = DK.start(source, DK.doc({
                    world = { DK.car('car', at), DK.spot('drop', drop) },
                    nodes = { N('start', 'scenario.started'), N('spawn', 'vehicle.spawn', { cars = { 'car' } }),
                              N('deliver', 'goal.deliverCar', { car = 'car', at = 'drop', radius = 8 }), N('win', 'scenario.succeed'),
                              N('lost', 'scenario.fail', { reason = 'lost' }) },
                    links = { { 'start', 'out', 'spawn' }, { 'spawn', 'out', 'deliver' }, { 'deliver', 'done', 'win' }, { 'deliver', 'lost', 'lost' } },
                }))
                ctx.runId = r.runId
                local net = madeNet(r.runId, 'car')
                assertNotNil(net, 'the car was made, in the drop-off')
                Wait(2500)
                assertEqual(DK.result(r.runId).status, 'running', 'there, but nobody drove it: not delivered')
                assertTrue(enter(source, net, -1), 'the tester takes the wheel')
                r = DK.over(r.runId, 10000)
                assertEqual(r and r.status, 'succeeded', 'delivered (' .. DK.how(r) .. ')')
                ClientLeaveVehicle(source)
            end,
        },
        {
            name = 'Goal: Bring Item To: the scenario\'s item, carried to the spot (a Test only says it would take it)',
            fn = function(source, ctx)
                DK.teleport(source, DK.FIELD)
                local spot = DK.at(20, -8)
                local r = DK.start(source, DK.doc({
                    world = { DK.spot('there', spot) },
                    nodes = { N('start', 'scenario.started'), N('give', 'player.giveItem', { item = 'food', amount = 1 }),
                              N('bring', 'goal.bring', { item = 'food', count = 1, at = 'there', radius = 3 }), N('win', 'scenario.succeed'),
                              N('lose', 'scenario.fail', { reason = 'no give' }) },
                    links = { { 'start', 'out', 'give' }, { 'give', 'given', 'bring' }, { 'give', 'failed', 'lose' }, { 'give', 'timeout', 'lose' },
                              { 'bring', 'done', 'win' } },
                }))
                ctx.runId = r.runId
                local up = DK.waiting(r.runId, 'bring', 10000)
                if not up and DK.result(r.runId).reason == 'no give' then skip('the give did not go in (full pockets?)') end
                assertNotNil(up, 'the goal is up, the item given')
                Wait(2000)
                assertEqual(DK.result(r.runId).status, 'running', 'not brought while away')
                DK.teleport(source, spot)
                r = DK.over(r.runId, 10000)
                assertEqual(r and r.status, 'succeeded', 'brought (' .. DK.how(r) .. ')')
            end,
        },
        {
            name = 'Goal: Collect counts only what comes after it starts: the scenario\'s own items',
            fn = function(source)
                local r = DK.run(source, DK.doc({
                    nodes = { N('start', 'scenario.started'), N('first', 'player.giveItem', { item = 'food', amount = 1 }),
                              N('seq', 'flow.sequence'), N('collect', 'goal.collect', { item = 'food', count = 2 }),
                              N('soon', 'flow.wait', { seconds = 2 }), N('more', 'player.giveItem', { item = 'food', amount = 2 }),
                              N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'first' }, { 'first', 'given', 'seq' }, { 'seq', 'then1', 'collect' }, { 'seq', 'then2', 'soon' },
                              { 'soon', 'done', 'more' }, { 'collect', 'done', 'win' } },
                }), { seconds = 30 })
                assertEqual(r.status, 'succeeded', 'collected once two more came (' .. DK.how(r) .. ')')
                local doneAt, moreAt
                for _, s in ipairs(r.steps) do
                    if s.node == 'collect' and s.kind == 'resume' then doneAt = s.ms end
                    if s.node == 'more' and (s.kind == 'resume' or s.kind == 'out') then moreAt = moreAt or s.ms end
                end
                assertGte(doneAt or 0, moreAt or math.huge, 'not before the second give: the one carried before it did not count')
            end,
        },
        {
            name = 'Goal: Survive: done after its time while they stay; failed when they are out of its area',
            fn = function(source)
                DK.teleport(source, DK.FIELD)
                local r = DK.run(source, DK.doc({
                    world = { DK.spot('here', DK.FIELD), DK.spot('far', DK.at(200, 0)) },
                    nodes = { N('start', 'scenario.started'), N('hold', 'goal.survive', { length = 5, at = 'here', radius = 30 }),
                              N('win', 'scenario.succeed', { reason = 'survived' }), N('lose', 'scenario.fail', { reason = 'failed' }) },
                    links = { { 'start', 'out', 'hold' }, { 'hold', 'done', 'win' }, { 'hold', 'failed', 'lose' } },
                }), { seconds = 30 })
                assertEqual(r.reason, 'survived', 'stayed in its area for its 5 seconds (' .. DK.how(r) .. ')')
                r = DK.run(source, DK.doc({
                    world = { DK.spot('far', DK.at(200, 0)) },
                    nodes = { N('start', 'scenario.started'), N('hold', 'goal.survive', { length = 60, at = 'far', radius = 20 }),
                              N('win', 'scenario.succeed', { reason = 'survived' }), N('lose', 'scenario.fail', { reason = 'failed' }) },
                    links = { { 'start', 'out', 'hold' }, { 'hold', 'done', 'win' }, { 'hold', 'failed', 'lose' } },
                }), { seconds = 30 })
                assertEqual(r.reason, 'failed', 'out of its area: failed, long before its minute (' .. DK.how(r) .. ')')
            end,
        },
        {
            name = 'Goal: Kill Them All and All Killed: done once its NPCs are down (here by their own Die task)',
            fn = function(source)
                local list = { list = { { k = 'w', t = 'wait', sec = 2 }, { k = 'd', t = 'die' } } }
                local r = DK.run(source, DK.doc({
                    world = { DK.npc('a', DK.at(12, -4), { tasks = list }), DK.npc('b', DK.at(12, 4), { tasks = list }) },
                    -- (All Killed is an event card: it listens from the run's start, nothing wired into it.)
                    nodes = { N('start', 'scenario.started'), N('spawn', 'npc.spawn', { npcs = { 'a', 'b' } }),
                              N('goal', 'goal.killAll', { npc = 'a' }), N('allDown', 'npc.allKilled', { npc = 'a' }),
                              N('all', 'flow.waitAll'), N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'spawn' }, { 'spawn', 'out', 'goal' },
                              { 'goal', 'done', 'all', 'a' }, { 'allDown', 'out', 'all', 'b' }, { 'all', 'done', 'win' } },
                }), { seconds = 40 })
                assertEqual(r.status, 'succeeded', 'both down, both went on (' .. DK.how(r) .. ')')
            end,
        },
    },
})
