-- ============================================
-- Director: World Things — what a run makes (NPCs, cars, props, ground items, containers) and that it all goes
-- ============================================
--
-- On the test field (the airport: DK.toField), each card makes its thing where the World tab placed it; the
-- tester's game is asked what it sees there (DK.probe), and once the run ends, everything it made must be gone.

local N = DK.N

local function gone(netId, ms) return waitFor(function() return not DK.exists(netId) end, ms or 10000) ~= nil end

--- The netId of what a run made for a placed thing, once it has (its result's things).
local function madeNet(runId, wid, ms)
    local r = DK.when(runId, function(x) return type(x.things[wid]) == 'table' and x.things[wid].netId ~= nil end, ms or 10000)
    return r and r.things[wid].netId or nil, r
end

--- Wait for the tester's game to see it (in range, loaded): its probe, or nil.
local function seen(source, q, ms)
    return waitFor(function()
        local o = DK.look(source, q)
        return o and o.exists and o or nil
    end, ms or 8000)
end

RegisterTestModule({
    order    = 81,
    category = 'Director: World Things',
    setup = function(source, ctx)
        local p = exports.whip_core:GetPlayer(source)
        if not (p and p.charId) then skip('the tester is not on a character') end
        DK.toField(source)
    end,
    teardown = function(ctx, source)
        DK.stopAll()
        DK.goHome(source)
    end,
    tests = {
        {
            name = 'Spawn NPC: made where it was placed, seen by the tester\'s game; gone when the run ends',
            fn = function(source, ctx)
                local at = DK.at(8, 0, 60.0)
                local r = DK.start(source, DK.doc({
                    world = { DK.npc('guy', at) },
                    nodes = { N('start', 'scenario.started'), N('spawn', 'npc.spawn', { npcs = { 'guy' } }), N('hold', 'flow.wait', { seconds = 600 }),
                              N('win', 'scenario.succeed'), N('lose', 'scenario.fail', { reason = 'not made' }) },
                    links = { { 'start', 'out', 'spawn' }, { 'spawn', 'out', 'hold' }, { 'spawn', 'failed', 'lose' }, { 'hold', 'done', 'win' } },
                }))
                ctx.runId = r.runId
                local net, now = madeNet(r.runId, 'guy')
                assertNotNil(net, 'Spawn NPC made it (' .. DK.how(now or DK.result(r.runId)) .. ')')
                assertTrue(DK.exists(net), 'the server has it')
                local o = seen(source, { net = net })
                assertNotNil(o, 'the tester\'s game sees it')
                assertEqual(o.kind, 'ped', 'a ped')
                assertTrue(DK.dist2d(o, at) < 3.0, ('where it was placed (%.1f m off)'):format(DK.dist2d(o, at)))
                DK.steer(r.runId, 'end', 'succeeded', 'checked')
                assertNotNil(DK.over(r.runId), 'it ended')
                assertTrue(gone(net), 'and the NPC went with it')
            end,
        },
        {
            name = 'Spawn NPC with several: each its own ped, each where it was placed',
            fn = function(source, ctx)
                local a, b = DK.at(10, -3), DK.at(10, 3)
                local r = DK.start(source, DK.doc({
                    world = { DK.npc('one', a), DK.npc('two', b, { model = 'a_f_y_business_01' }) },
                    nodes = { N('start', 'scenario.started'), N('spawn', 'npc.spawn', { npcs = { 'one', 'two' } }), N('hold', 'flow.wait', { seconds = 600 }),
                              N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'spawn' }, { 'spawn', 'out', 'hold' }, { 'hold', 'done', 'win' } },
                }))
                ctx.runId = r.runId
                local n1 = madeNet(r.runId, 'one')
                local n2 = madeNet(r.runId, 'two')
                assertNotNil(n1, 'the first made')
                assertNotNil(n2, 'the second made')
                assertNotEqual(n1, n2, 'two peds, not one')
                local o2 = seen(source, { net = n2 })
                assertTrue(o2 ~= nil and DK.dist2d(o2, b) < 3.0, 'the second where it was placed')
                DK.stop(r.runId)
                assertTrue(gone(n1) and gone(n2), 'both gone at the end')
            end,
        },
        {
            name = 'Spawn Car: made where it was placed, with its plate; gone when the run ends',
            fn = function(source, ctx)
                local at = DK.at(12, 6, 150.0)
                at.z = at.z + 0.5
                local r = DK.start(source, DK.doc({
                    world = { DK.car('car', at, { plate = 'WTEST01' }) },
                    nodes = { N('start', 'scenario.started'), N('spawn', 'vehicle.spawn', { cars = { 'car' } }), N('hold', 'flow.wait', { seconds = 600 }),
                              N('win', 'scenario.succeed'), N('lose', 'scenario.fail', { reason = 'not made' }) },
                    links = { { 'start', 'out', 'spawn' }, { 'spawn', 'out', 'hold' }, { 'spawn', 'failed', 'lose' }, { 'spawn', 'timeout', 'lose' },
                              { 'hold', 'done', 'win' } },
                }))
                ctx.runId = r.runId
                local net, now = madeNet(r.runId, 'car', 15000)
                assertNotNil(net, 'Spawn Car made it (' .. DK.how(now or DK.result(r.runId)) .. ')')
                local o = seen(source, { net = net })
                assertNotNil(o, 'the tester\'s game sees it')
                assertEqual(o.kind, 'vehicle', 'a car')
                assertTrue(DK.dist2d(o, at) < 3.0, ('where it was placed (%.1f m off)'):format(DK.dist2d(o, at)))
                assertEqual((tostring(o.plate):gsub('%s+', '')), 'WTEST01', 'its plate')
                DK.stop(r.runId)
                assertTrue(gone(net), 'gone at the end')
            end,
        },
        {
            name = 'Show Prop and Hide Prop: on every game where it was placed, then taken away',
            fn = function(source, ctx)
                local at = DK.at(6, -5)
                local model = 'prop_barrel_02a'
                local r = DK.start(source, DK.doc({
                    world = { DK.prop('barrel', at, model) },
                    nodes = { N('start', 'scenario.started'), N('show', 'prop.show', { prop = 'barrel' }), N('hold', 'flow.wait', { seconds = 600 }),
                              N('hide', 'prop.hide', { prop = 'barrel' }), N('after', 'flow.wait', { seconds = 600 }), N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'show' }, { 'show', 'out', 'hold' }, { 'hold', 'done', 'hide' }, { 'hide', 'out', 'after' },
                              { 'after', 'done', 'win' } },
                }))
                ctx.runId = r.runId
                assertNotNil(DK.waiting(r.runId, 'hold', 5000), 'shown')
                local q = { model = model, at = at, radius = 2.0 }
                assertNotNil(seen(source, q, 10000), 'the tester\'s game has it there')
                DK.steer(r.runId, 'take', 'hold', 'done')
                assertNotNil(DK.waiting(r.runId, 'after', 5000), 'hidden')
                local away = waitFor(function()
                    local o = DK.look(source, q)
                    return o and not o.exists
                end, 8000)
                assertTrue(away ~= nil, 'taken away from the tester\'s game')
                DK.stop(r.runId)
            end,
        },
        {
            name = 'A prop shown is taken away when the run ends',
            fn = function(source, ctx)
                local at = DK.at(6, 5)
                local model = 'prop_barrel_02a'
                local r = DK.start(source, DK.doc({
                    world = { DK.prop('barrel', at, model) },
                    nodes = { N('start', 'scenario.started'), N('show', 'prop.show', { prop = 'barrel' }), N('hold', 'flow.wait', { seconds = 600 }),
                              N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'show' }, { 'show', 'out', 'hold' }, { 'hold', 'done', 'win' } },
                }))
                ctx.runId = r.runId
                local q = { model = model, at = at, radius = 2.0 }
                assertNotNil(seen(source, q, 10000), 'shown')
                DK.stop(r.runId)
                local away = waitFor(function()
                    local o = DK.look(source, q)
                    return o and not o.exists
                end, 8000)
                assertTrue(away ~= nil, 'gone after the end')
            end,
        },
        {
            name = 'Place Item: on the ground at its spot, and gone from the ground when the run ends',
            fn = function(source, ctx)
                local at = DK.at(4, 2)
                local r = DK.start(source, DK.doc({
                    world = { { id = 'drop', kind = 'groundItem', layer = 'run', label = 'drop', def = { item = 'food', amount = 1, coords = at } } },
                    nodes = { N('start', 'scenario.started'), N('place', 'item.place', { item = 'drop' }), N('hold', 'flow.wait', { seconds = 600 }),
                              N('win', 'scenario.succeed'), N('lose', 'scenario.fail', { reason = 'not placed' }) },
                    links = { { 'start', 'out', 'place' }, { 'place', 'placed', 'hold' }, { 'place', 'failed', 'lose' }, { 'place', 'timeout', 'lose' },
                              { 'hold', 'done', 'win' } },
                }))
                ctx.runId = r.runId
                local now = DK.when(r.runId, function(x) return type(x.things.drop) == 'table' and x.things.drop.groundId ~= nil or x.done end, 10000)
                local gid = now and type(now.things.drop) == 'table' and now.things.drop.groundId or nil
                assertNotNil(gid, 'placed (' .. DK.how(now) .. ')')
                assertGte(tonumber(DbQuery('SELECT COUNT(*) AS n FROM ground_items WHERE id = ?', { gid })[1].n) or 0, 1, 'a row on the ground')
                DK.stop(r.runId)
                local cleared = waitFor(function()
                    local rows = DbQuery('SELECT COUNT(*) AS n FROM ground_items WHERE id = ?', { gid })
                    return rows and rows[1] and tonumber(rows[1].n) == 0
                end, 10000)
                assertTrue(cleared ~= nil, 'taken off the ground at its end')
            end,
        },
        {
            name = 'Remove: takes away what the run made for a thing, there and then',
            fn = function(source, ctx)
                local r = DK.start(source, DK.doc({
                    world = { DK.npc('guy', DK.at(9, -2)) },
                    nodes = { N('start', 'scenario.started'), N('spawn', 'npc.spawn', { npcs = { 'guy' } }), N('hold', 'flow.wait', { seconds = 600 }),
                              N('rm', 'world.remove', { what = 'guy' }), N('after', 'flow.wait', { seconds = 600 }), N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'spawn' }, { 'spawn', 'out', 'hold' }, { 'hold', 'done', 'rm' }, { 'rm', 'out', 'after' },
                              { 'after', 'done', 'win' } },
                }))
                ctx.runId = r.runId
                local net = madeNet(r.runId, 'guy')
                assertNotNil(net, 'made')
                DK.steer(r.runId, 'take', 'hold', 'done')
                assertNotNil(DK.waiting(r.runId, 'after', 10000), 'Remove went on')
                assertTrue(gone(net), 'the NPC is gone while the run still goes')
                assertEqual(DK.result(r.runId).status, 'running', 'the run itself goes on')
                DK.stop(r.runId)
            end,
        },
        {
            name = 'Show Blip, Set Waypoint and Remove Blip go on',
            fn = function(source)
                local r = DK.run(source, DK.doc({
                    world = { DK.spot('here', DK.at(30, 0)) },
                    nodes = { N('start', 'scenario.started'), N('blip', 'map.blip', { at = 'here', label = '[whip_test] blip' }),
                              N('wp', 'map.waypoint', { at = 'here' }), N('wait', 'flow.wait', { seconds = 1 }),
                              N('rm', 'map.blipRemove', { at = 'here' }), N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'blip' }, { 'blip', 'out', 'wp' }, { 'wp', 'out', 'wait' }, { 'wait', 'done', 'rm' },
                              { 'rm', 'out', 'win' } },
                }))
                assertEqual(r.status, 'succeeded', 'through all three (' .. DK.how(r) .. ')')
            end,
        },
    },
})
