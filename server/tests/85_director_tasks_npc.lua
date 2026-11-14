-- ============================================
-- Director: NPC Tasks — every task an NPC can play, on an NPC the run made, looked at on the tester's game
-- ============================================
--
-- Each test is one placed NPC with a task list (its page: Tasks), made without its tasks, then Start Tasks: its
-- Finished ends the run ("finished"), Could not fails it. While the list plays, the tester's game is asked what the
-- NPC is doing (its seat, its weapon, its animation...). GTA's own AI (where a walk or a drive takes it) is only
-- asked to have moved it at all; what is the game's to decide is not asserted. Fight the Run's Players is left
-- out: it would go for the tester.

local N = DK.N
local WAVE = { dict = 'friends@frj@ig_1', clip = 'wave_a' }                          -- the 'wave' emote
local THINK = { dict = 'misscarsteal4@aliens', clip = 'rehearsal_base_idle_director' }  -- the 'think' emote's

--- A GTA heading from a to b (0: north, 90: west).
local function headingTo(a, b) return math.deg(math.atan(-(b.x - a.x), b.y - a.y)) % 360.0 end
local function angleOff(a, b) local d = math.abs((a - b) % 360.0) return d > 180 and 360 - d or d end

local function npcAt(id, ahead, side, over) return DK.npc(id, DK.at(ahead, side, DK.FIELD.heading + 180.0), over) end
local function carAt(id, ahead, side, over)
    local at = DK.at(ahead, side, DK.FIELD.heading)
    at.z = at.z + 0.5
    return DK.car(id, at, over)
end

--- Run `doc`, give `during(net, runId)` its look while it plays, then wait for its end: its result.
local function play(source, ctx, doc, during, ms)
    local r = DK.start(source, doc)
    ctx.runId = r.runId
    local net = DK.netOf(r.runId, 'it')
    assertNotNil(net, 'the run made it (' .. DK.how(DK.result(r.runId)) .. ')')
    if during then during(net, r.runId) end
    local over = DK.over(r.runId, ms or 30000)
    assertNotNil(over, 'the run ended')
    return over, net
end

local function finished(r) assertEqual(r.reason, 'finished', 'Start Tasks: Finished (' .. DK.how(r) .. ')') end

RegisterTestModule({
    order    = 85,
    category = 'Director: NPC Tasks',
    setup = function(source)
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
            name = 'Teleport: there at once',
            fn = function(source, ctx)
                local to = DK.at(16, -6)
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 8, 0), { { k = 't', t = 'teleport', at = to }, { k = 'w', t = 'wait', sec = 3 } }),
                    function(net)
                        local o = DK.until_(source, { net = net }, function(x) return DK.dist2d(x, to) < 2.0 end, 6000)
                        assertNotNil(o, 'it is at the point')
                    end)
                finished(r)
            end,
        },
        {
            name = 'Go To (for a time): it sets off towards the point',
            fn = function(source, ctx)
                local to = DK.at(30, 0)
                local from = DK.at(8, 0)
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 8, 0), { { k = 'g', t = 'goTo', at = to, pace = 'run', next = 'time', sec = 5 } }),
                    function(net)
                        local o, last = DK.until_(source, { net = net }, function(x) return DK.dist2d(x, to) < DK.dist2d(from, to) - 3.0 end, 7000)
                        assertNotNil(o, ('it moved towards the point (%.1f m from it)'):format(last and DK.dist2d(last, to) or -1))
                    end)
                finished(r)
            end,
        },
        {
            name = 'Turn To Face: it turns to the point',
            fn = function(source, ctx)
                local me, to = DK.at(8, 0), DK.at(8, 15)
                local want = headingTo(me, to)
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 8, 0), { { k = 'f', t = 'face', target = 'point', at = to, sec = 3 } }),
                    function(net)
                        local o, last = DK.until_(source, { net = net }, function(x) return angleOff(x.heading, want) < 35 end, 5000)
                        assertNotNil(o, ('it faces the point (heading %.0f, wanted %.0f)'):format(last and last.heading or -1, want))
                    end)
                finished(r)
            end,
        },
        {
            name = 'Wander Nearby, Look At, Take Cover, GTA Speech: each plays and the list finishes',
            fn = function(source, ctx)
                local list = {
                    { k = 'a', t = 'wander', radius = 4, sec = 2 },
                    { k = 'b', t = 'lookAt', target = 'nearest', sec = 1 },
                    { k = 'c', t = 'cover', at = DK.at(10, 2), sec = 2 },
                    { k = 'e', t = 'speech', line = 'GENERIC_HI' },
                }
                local t0 = GetGameTimer()
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 8, 0), list))
                finished(r)
                assertGte(GetGameTimer() - t0, 4500, 'not before its steps\' 5 seconds')
            end,
        },
        {
            name = 'Follow: it comes after the tester',
            fn = function(source, ctx)
                DK.teleport(source, DK.FIELD)
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 18, 0), { { k = 'f', t = 'follow', target = 'nearest', pace = 'run', sec = 6 } }),
                    function(net)
                        local o, last = DK.until_(source, { net = net }, function(x) return DK.dist2d(x, DK.FIELD) < 12.0 end, 8000)
                        assertNotNil(o, ('it came nearer (%.1f m away)'):format(last and DK.dist2d(last, DK.FIELD) or -1))
                    end)
                finished(r)
            end,
        },
        {
            name = 'Run Away From: it gets further from the tester',
            fn = function(source, ctx)
                DK.teleport(source, DK.FIELD)
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 6, 0), { { k = 'f', t = 'flee', target = 'nearest', sec = 6 } }),
                    function(net)
                        local o, last = DK.until_(source, { net = net }, function(x) return DK.dist2d(x, DK.FIELD) > 11.0 end, 8000)
                        assertNotNil(o, ('it ran off (%.1f m away)'):format(last and DK.dist2d(last, DK.FIELD) or -1))
                    end)
                finished(r)
            end,
        },
        {
            name = 'Aim At: it holds a gun while it aims (handed a pistol if it has none)',
            fn = function(source, ctx)
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 8, 0), { { k = 'a', t = 'aimAt', target = 'point', at = DK.at(8, 20), sec = 5 } }),
                    function(net)
                        assertNotNil(DK.until_(source, { net = net }, function(x) return x.armed == true or x.armed == 1 end, 6000), 'armed')
                    end)
                finished(r)
            end,
        },
        {
            name = 'Shoot At and Throw: at points away from everyone; each plays its time',
            fn = function(source, ctx)
                local list = {
                    { k = 's', t = 'shootAt', target = 'point', at = DK.at(8, 30), sec = 2, accuracy = 10, rate = 30, pattern = 'single shots' },
                    { k = 't', t = 'throw', item = 'ball', target = 'point', at = DK.at(8, 15), sec = 2 },
                }
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 8, 0), list), function(net)
                    assertNotNil(DK.until_(source, { net = net }, function(x) return x.armed == true or x.armed == 1 end, 4000), 'armed to shoot')
                end)
                finished(r)
            end,
        },
        {
            name = 'Fight an NPC: two of the run\'s NPCs at each other',
            fn = function(source, ctx)
                local other = npcAt('other', 10, 4)
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 10, -2), { { k = 'f', t = 'fightNpc', npc = 'other', sec = 4 } }, { before = { other } }),
                    function(net, runId)
                        local otherNet = DK.netOf(runId, 'other')
                        local o, last = DK.until_(source, { net = net, vs = otherNet }, function(x) return x.combat or x.combatVs end, 5000)
                        -- (What it was doing, said: its combat task 0 waiting, 1 running, 7 none.)
                        assertNotNil(o, ('it is fighting (in combat %s, with the other %s, its combat task %s)')
                            :format(tostring(last and last.combat), tostring(last and last.combatVs), tostring(last and last.combatTask)))
                    end)
                finished(r)
            end,
        },
        {
            name = 'Play Emote by its name: the emote\'s animation plays',
            fn = function(source, ctx)
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 8, 0), { { k = 'e', t = 'emote', by = 'emote', emote = 'wave', sec = 5 } }),
                    function(net)
                        assertNotNil(DK.until_(source, { net = net, anim = WAVE }, function(x) return x.anim == true or x.anim == 1 end, 6000), 'waving')
                    end)
                finished(r)
            end,
        },
        {
            name = 'Play Emote by an animation, then an emote that is a scenario',
            fn = function(source, ctx)
                local list = {
                    { k = 'a', t = 'emote', by = 'animation', dict = THINK.dict, clip = THINK.clip, loop = true, sec = 4 },
                    { k = 's', t = 'emote', by = 'emote', emote = 'smoke', sec = 5 },
                }
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 8, 0), list), function(net)
                    assertNotNil(DK.until_(source, { net = net, anim = THINK }, function(x) return x.anim == true or x.anim == 1 end, 5000), 'the animation')
                    assertNotNil(DK.until_(source, { net = net, scenarioName = 'WORLD_HUMAN_SMOKING' },
                        function(x) return x.scenarioNamed == true or x.scenarioNamed == 1 end, 7000), 'then smoking')
                end)
                finished(r)
            end,
        },
        {
            name = 'Hold a Weapon: the one named, in its hands',
            fn = function(source, ctx)
                local hash = GetHashKey('WEAPON_PISTOL')
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 8, 0), { { k = 'w', t = 'weapon', weapon = 'WEAPON_PISTOL' }, { k = 'x', t = 'wait', sec = 3 } }),
                    function(net)
                        assertNotNil(DK.until_(source, { net = net }, function(x) return x.weapon == hash end, 5000), 'the pistol in hand')
                    end)
                finished(r)
            end,
        },
        {
            name = 'Set Health: it is hurt to the share given',
            fn = function(source, ctx)
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 8, 0), { { k = 'h', t = 'setHealth', pct = 50 }, { k = 'x', t = 'wait', sec = 3 } }),
                    function(net)
                        local o, last = DK.until_(source, { net = net }, function(x) return x.health < x.maxHealth and x.health > 100 end, 5000)
                        assertNotNil(o, ('hurt but alive (%s of %s)'):format(tostring(last and last.health), tostring(last and last.maxHealth)))
                    end)
                finished(r)
            end,
        },
        {
            name = 'Die, then Revive: dead, then up again',
            fn = function(source, ctx)
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 8, 0), { { k = 'd', t = 'die' }, { k = 'w', t = 'wait', sec = 3 }, { k = 'r', t = 'revive' },
                                                                                { k = 'x', t = 'wait', sec = 3 } }),
                    function(net)
                        assertNotNil(DK.until_(source, { net = net }, function(x) return x.dead == true or x.dead == 1 end, 5000), 'dead')
                        assertNotNil(DK.until_(source, { net = net }, function(x) return not (x.dead == true or x.dead == 1) end, 8000), 'alive again')
                    end)
                finished(r)
            end,
        },
        {
            name = 'Writhe and Freeze: each plays and the list finishes',
            fn = function(source, ctx)
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 8, 0), { { k = 'w', t = 'writhe', sec = 4 }, { k = 'f', t = 'freeze', on = true },
                                                                                { k = 'u', t = 'freeze', on = false } }),
                    function(net)
                        assertNotNil(DK.until_(source, { net = net }, function(x) return x.writhe == true or x.writhe == 1 end, 5000), 'writhing')
                    end)
                finished(r)
            end,
        },
        {
            name = 'Sit In (at once), then Get Out: in its seat, then out of the car',
            fn = function(source, ctx)
                local car = carAt('car', 12, 6)
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 8, 4), { { k = 'i', t = 'warpIn', car = 'car', seat = 'front passenger' },
                                                                                 { k = 'w', t = 'wait', sec = 3 }, { k = 'o', t = 'getOut', giveUp = 10 } },
                                                          { before = { car } }),
                    function(net, runId)
                        local carNet = DK.netOf(runId, 'car')
                        local o, last = DK.until_(source, { net = net }, function(x) return x.inVehicle == carNet and x.seat == 0 end, 6000)
                        assertNotNil(o, ('in the front passenger seat (in %s, seat %s)'):format(tostring(last and last.inVehicle), tostring(last and last.seat)))
                        assertNotNil(DK.until_(source, { net = net }, function(x) return x.inVehicle == false end, 12000), 'out again')
                    end)
                finished(r)
            end,
        },
        {
            name = 'Get In: it walks to the car and gets in as the driver',
            fn = function(source, ctx)
                local car = carAt('car', 12, 6)
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 9, 3), { { k = 'i', t = 'getIn', car = 'car', seat = 'driver', giveUp = 25 } },
                                                          { before = { car } }),
                    function(net, runId)
                        local carNet = DK.netOf(runId, 'car')
                        assertNotNil(DK.until_(source, { net = net }, function(x) return x.inVehicle == carNet and x.seat == -1 end, 26000), 'at the wheel')
                    end, 40000)
                finished(r)
            end,
        },
        {
            name = 'Drive To and Cruise Around: the car it drives moves',
            fn = function(source, ctx)
                local car = carAt('car', 12, 6)
                local start = DK.at(12, 6)
                local list = { { k = 'i', t = 'warpIn', car = 'car', seat = 'driver' },
                               { k = 'd', t = 'driveTo', at = DK.at(80, 6), speed = 30, next = 'time', sec = 6 },
                               { k = 'c', t = 'cruise', speed = 30, sec = 4 } }
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 9, 3), list, { before = { car } }), function(_, runId)
                    local carNet = DK.netOf(runId, 'car')
                    local o, last = DK.until_(source, { net = carNet }, function(x) return DK.dist2d(x, start) > 5.0 end, 9000)
                    assertNotNil(o, ('the car moved (%.1f m from its spot)'):format(last and DK.dist2d(last, start) or -1))
                end)
                finished(r)
            end,
        },
        {
            name = 'Follow in a Car: it plays its time behind another car',
            fn = function(source, ctx)
                local car, lead = carAt('car', 12, 6), carAt('lead', 20, 6)
                local list = { { k = 'i', t = 'warpIn', car = 'car', seat = 'driver' },
                               { k = 'f', t = 'followCar', target = 'thing', thing = 'lead', speed = 40, sec = 3 } }
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 9, 3), list, { before = { car, lead } }))
                finished(r)
            end,
        },
        {
            name = 'Wait for a card: the list goes on once that card gives the outcome picked',
            fn = function(source, ctx)
                local t0 = GetGameTimer()
                local r = play(source, ctx, DK.tasksDoc(npcAt('it', 8, 0), { { k = 'w', t = 'wait', by = 'card', card = 'sig', outs = { 'out' }, giveUp = 30 } }, {
                    vars = { DK.var('x', 0) },
                    nodes = { N('later', 'flow.wait', { seconds = 3 }), N('sig', 'var.set', { var = 'x', value = '1' }) },
                    links = { { 'start', 'out', 'later' }, { 'later', 'done', 'sig' } },
                }))
                finished(r)
                assertGte(GetGameTimer() - t0, 2500, 'not before the card went out, 3 seconds in')
            end,
        },
        {
            name = 'A list that starts again never finishes; Stop Tasks stops it',
            fn = function(source, ctx)
                local it = npcAt('it', 8, 0)
                it.def.tasks = { list = { { k = 'w', t = 'wander', radius = 3, sec = 2 } }, after = 'loop' }
                local r = DK.start(source, DK.doc({
                    world = { it },
                    nodes = { N('start', 'scenario.started'), N('make', 'npc.spawn', { npcs = { 'it' }, tasks = false }), N('ts', 'tasks.start', { things = { 'it' } }),
                              N('soon', 'flow.wait', { seconds = 6 }), N('stop', 'tasks.stop', { what = 'it' }), N('win', 'scenario.succeed', { reason = 'stopped' }) },
                    links = { { 'start', 'out', 'make' }, { 'make', 'out', 'ts' }, { 'ts', 'out', 'soon' }, { 'soon', 'done', 'stop' }, { 'stop', 'out', 'win' } },
                }))
                ctx.runId = r.runId
                r = DK.over(r.runId, 20000)
                assertEqual(r and r.reason, 'stopped', 'stopped by Stop Tasks (' .. DK.how(r) .. ')')
                assertEqual(DK.fired(r, 'ts', 'done'), 0, 'its Finished never came in 6 seconds of a 2-second list')
            end,
        },
        {
            name = 'Could not: Start Tasks before its NPC is made',
            fn = function(source)
                local it = npcAt('it', 8, 0)
                it.def.tasks = { list = { { k = 'w', t = 'wait', sec = 1 } } }
                local r = DK.run(source, DK.doc({
                    world = { it },
                    nodes = { N('start', 'scenario.started'), N('seq', 'flow.sequence'), N('ts', 'tasks.start', { things = { 'it' } }),
                              N('make', 'npc.spawn', { npcs = { 'it' }, tasks = false }), N('could', 'scenario.succeed', { reason = 'could not' }),
                              N('did', 'scenario.fail', { reason = 'it played' }) },
                    links = { { 'start', 'out', 'seq' }, { 'seq', 'then1', 'ts' }, { 'seq', 'then2', 'make' }, { 'ts', 'failed', 'could' },
                              { 'ts', 'done', 'did' } },
                }))
                assertEqual(r.reason, 'could not', 'Could not (' .. DK.how(r) .. ')')
            end,
        },
    },
})
