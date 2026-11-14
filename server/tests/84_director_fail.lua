-- ============================================
-- Director: Fail Conditions — rules wired to nothing that fail a run whenever they are broken
-- ============================================
--
-- Each watches the whole run, once a second (its watch: runtime.lua): a variable passing a test, the tester
-- straying from a spot (moved there by the kit), an NPC killed (here by its own Die task), the run's car lost or
-- damaged (by Remove, or its own Set Health task). Broken, the run fails with the card's reason (After Failure then
-- plays), or only the player is taken out. Never broken, it changes nothing.

local N = DK.N

--- start -> `chain`... with a long Wait at its end (the run stays going until a rule breaks), plus `extra` cards.
local function watchDoc(spec)
    local nodes = { N('start', 'scenario.started') }
    local links = {}
    local prev, pin = 'start', 'out'
    for _, n in ipairs(spec.chain or {}) do
        nodes[#nodes + 1] = n
        links[#links + 1] = { prev, pin, n.id }
        prev, pin = n.id, spec.pins and spec.pins[n.id] or 'out'
    end
    nodes[#nodes + 1] = N('hold', 'flow.wait', { seconds = spec.hold or 600 })
    nodes[#nodes + 1] = N('win', 'scenario.succeed', { reason = 'nothing broke' })
    links[#links + 1] = { prev, pin, 'hold' }
    links[#links + 1] = { 'hold', 'done', 'win' }
    for _, n in ipairs(spec.extra or {}) do nodes[#nodes + 1] = n end
    for _, l in ipairs(spec.links or {}) do links[#links + 1] = l end
    return DK.doc({ world = spec.world, vars = spec.vars, nodes = nodes, links = links })
end

local function field(source) DK.toField(source) end

RegisterTestModule({
    order    = 84,
    category = 'Director: Fail Conditions',
    setup = function(source)
        local p = exports.whip_core:GetPlayer(source)
        if not (p and p.charId) then skip('the tester is not on a character') end
    end,
    teardown = function(ctx, source)
        DK.stopAll()
        DK.goHome(source)
    end,
    tests = {
        {
            name = 'Fail If a Variable: the moment its test passes, the run fails with its reason',
            fn = function(source)
                local r = DK.run(source, watchDoc({
                    vars = { DK.var('alarms', 0) },
                    chain = { N('w', 'flow.wait', { seconds = 1 }), N('add', 'var.add', { var = 'alarms', amount = 3 }) },
                    pins = { w = 'done' },
                    extra = { N('rule', 'fail.variable', { var = 'alarms', op = 'at least', value = '3', reason = 'too many alarms' }) },
                }), { seconds = 20 })
                assertEqual(r.status, 'failed', 'failed (' .. DK.how(r) .. ')')
                assertEqual(r.reason, 'too many alarms', 'with its reason')
            end,
        },
        {
            name = 'A rule never broken changes nothing: the run ends as its cards say',
            fn = function(source)
                local r = DK.run(source, watchDoc({
                    vars = { DK.var('alarms', 0) }, hold = 2,
                    extra = { N('rule', 'fail.variable', { var = 'alarms', op = 'at least', value = '3' }) },
                }), { seconds = 20 })
                assertEqual(r.status, 'succeeded', 'succeeded (' .. DK.how(r) .. ')')
            end,
        },
        {
            name = 'A rule set from outside the run breaks it too, and After Failure plays',
            fn = function(source)
                local r = DK.run(source, watchDoc({
                    vars = { DK.var('alarms', 0), DK.var('after', '') },
                    extra = { N('rule', 'fail.variable', { var = 'alarms', op = 'more than', value = '0', reason = 'seen' }),
                              N('af', 'run.afterFail'), N('mark', 'var.set', { var = 'after', value = 'played' }) },
                    links = { { 'af', 'out', 'mark' } },
                }), { seconds = 20, steer = { { op = 'var', name = 'alarms', value = 1, when = 'hold' } } })
                assertEqual(r.reason, 'seen', 'failed by its rule (' .. DK.how(r) .. ')')
                assertEqual(r.vars.after, 'played', 'After Failure played')
            end,
        },
        {
            name = 'Fail If a Player Strays: past its distance, for everyone; or only that player out (the last one: called off)',
            fn = function(source)
                field(source)
                local function doc(ends)
                    return watchDoc({
                        world = { DK.spot('here', DK.FIELD) },
                        extra = { N('rule', 'fail.strays', { at = 'here', radius = 10, grace = 0, ends = ends, reason = 'you left' }) },
                    })
                end
                local r = DK.start(source, doc('everyone'))
                assertNotNil(DK.waiting(r.runId, 'hold', 5000), 'going, the tester within 10 m')
                Wait(2500)
                assertEqual(DK.result(r.runId).status, 'running', 'not broken while they stay')
                DK.teleport(source, DK.at(40, 0))
                r = DK.over(r.runId, 10000)
                assertEqual(r and r.status, 'failed', 'strayed: failed (' .. DK.how(r) .. ')')
                assertEqual(r.reason, 'you left', 'with its reason')
                DK.teleport(source, DK.FIELD)
                r = DK.start(source, doc('them'))
                assertNotNil(DK.waiting(r.runId, 'hold', 5000), 'going')
                DK.teleport(source, DK.at(40, 0))
                r = DK.over(r.runId, 10000)
                assertEqual(r and r.status, 'aborted', 'only them out, and with nobody left it ends (' .. DK.how(r) .. ')')
                DK.teleport(source, DK.FIELD)
            end,
        },
        {
            name = 'Fail If an NPC Dies: the hostage dies (its own Die task), the run fails',
            fn = function(source)
                field(source)
                local r = DK.run(source, watchDoc({
                    world = { DK.npc('hostage', DK.at(10, 0), { tasks = { list = { { k = 'w', t = 'wait', sec = 2 }, { k = 'd', t = 'die' } } } }) },
                    chain = { N('spawn', 'npc.spawn', { npcs = { 'hostage' } }) },
                    extra = { N('rule', 'fail.npcDies', { npc = 'hostage', reason = 'the hostage died' }) },
                }), { seconds = 30 })
                assertEqual(r.reason, 'the hostage died', 'failed by its rule (' .. DK.how(r) .. ')')
            end,
        },
        {
            -- (Wrecked, by its own Blow Up task, well away from the tester. A Remove card is the run taking its car away
            -- itself, not losing it: that is no breach.)
            name = 'Fail If the Car Is Lost: once the run made it, wrecked, it fails the run',
            fn = function(source)
                field(source)
                local at = DK.at(26, 12, 150.0)
                at.z = at.z + 0.5
                local car = DK.car('car', at, { tasks = { list = { { k = 'w', t = 'wait', sec = 2 }, { k = 'b', t = 'blowUp' } } } })
                local r = DK.run(source, watchDoc({
                    world = { car },
                    chain = { N('spawn', 'vehicle.spawn', { cars = { 'car' } }) },
                    extra = { N('rule', 'fail.carLost', { car = 'car', reason = 'the car is gone' }) },
                }), { seconds = 30 })
                assertEqual(r.reason, 'the car is gone', 'failed by its rule (' .. DK.how(r) .. ')')
            end,
        },
        {
            name = 'Fail If the Car Is Damaged: more damage than its share fails the run (its own Set Health task)',
            fn = function(source)
                field(source)
                local at = DK.at(12, -6, 150.0)
                at.z = at.z + 0.5
                local car = DK.car('car', at, { tasks = { list = { { k = 'w', t = 'wait', sec = 3 }, { k = 'h', t = 'setHealth', pct = 30 } } } })
                local r = DK.run(source, watchDoc({
                    world = { car },
                    chain = { N('spawn', 'vehicle.spawn', { cars = { 'car' } }) },
                    extra = { N('rule', 'fail.carDamaged', { car = 'car', percent = 25, reason = 'scratched' }) },
                }), { seconds = 30 })
                assertEqual(r.reason, 'scratched', 'failed by its rule (' .. DK.how(r) .. ')')
            end,
        },
    },
})
