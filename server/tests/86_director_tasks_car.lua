-- ============================================
-- Director: Car & Prop Tasks — a car's own tasks (a scripted drive, doors, lights, siren, tyres...), and a prop's
-- ============================================
--
-- As the NPC tasks module: one placed car or prop with a task list, made without its tasks, then Start Tasks; the
-- tester's game is asked what it sees while the list plays. The scripted drive is a short recorded drive written
-- into director_takes for this module (straight along the field, then a stop) and deleted after: played by the car's
-- own Play a Scripted Driving Event task, and by the Play Scripted Driving Event card.

local N = DK.N
local TAKE_FIELDS = { 't', 'x', 'y', 'z', 'qx', 'qy', 'qz', 'qw', 'vx', 'vy', 'vz', 'steer', 'rpm', 'flags', 'w0', 'w1', 'w2', 'w3' }

--- A drive as a take's samples: from `start` along `heading` at 8 m/s for 5 s, then braking to a stop in 1 s
--- (44 m in all). Answers the samples and where it ends.
local function driveSamples(start, heading)
    local r = math.rad(heading)
    local fx, fy = -math.sin(r), math.cos(r)
    local qz, qw = math.sin(r / 2), math.cos(r / 2)
    local out = {}
    for t = 0, 6000, 250 do
        local v, d
        if t <= 5000 then
            v, d = 8.0, 8.0 * t / 1000
        else
            local dt = (t - 5000) / 1000
            v, d = 8.0 - 8.0 * dt, 40.0 + 8.0 * dt - 4.0 * dt * dt
        end
        local w = v / 0.33
        local s = { t, start.x + fx * d, start.y + fy * d, start.z, 0.0, 0.0, qz, qw, fx * v, fy * v, 0.0, 0.0, 0.2 + 0.05 * v, 128, w, w, w, w }
        for i, x in ipairs(s) do
            if i ~= 1 and i ~= 14 then x = math.floor(x * 1000 + 0.5) / 1000 end
            out[#out + 1] = x
        end
    end
    return out, { x = start.x + fx * 44.0, y = start.y + fy * 44.0, z = start.z }
end

local function carAt(id, ahead, side, over)
    local at = DK.at(ahead, side, DK.FIELD.heading)
    at.z = at.z + 0.5
    return DK.car(id, at, over)
end

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
local function yes(v) return v == true or v == 1 end

--- The lock the server holds on a car (2 locked, 1 open), by its netId; nil if it cannot be read.
local function serverLock(net)
    local ent = NetworkGetEntityFromNetworkId(net)
    if not ent or ent == 0 then return nil end
    local ok, v = pcall(GetVehicleDoorLockStatus, ent)
    return ok and v or nil
end

RegisterTestModule({
    order    = 86,
    category = 'Director: Car & Prop Tasks',
    setup = function(source, ctx)
        local p = exports.whip_core:GetPlayer(source)
        if not (p and p.charId) then skip('the tester is not on a character') end
        DK.toField(source)
        -- The drive: from 14 m ahead and 8 to the right, along the field.
        ctx.takeStart = DK.at(14, 8, DK.FIELD.heading)
        ctx.takeStart.z = ctx.takeStart.z + 0.6
        local samples, finish = driveSamples(ctx.takeStart, DK.FIELD.heading)
        ctx.takeEnd = finish
        local data = json.encode({ format = 2, fields = TAKE_FIELDS, samples = samples })
        local ok, id = pcall(MySQL.insert.await,
            'INSERT INTO `director_takes` (`scenarioKey`, `worldId`, `model`, `lengthMs`, `samples`, `data`, `madeByName`) VALUES (?, ?, ?, ?, ?, ?, ?)',
            { 'whip_test', 'it', 'sultan', 6000, #samples // #TAKE_FIELDS, data, 'whip_test' })
        ctx.takeId = ok and math.tointeger(tonumber(id)) or nil
    end,
    teardown = function(ctx, source)
        DK.stopAll()
        if ctx.takeId then pcall(MySQL.query.await, 'DELETE FROM `director_takes` WHERE `id` = ?', { ctx.takeId }) end
        DK.goHome(source)
    end,
    tests = {
        {
            name = 'Play a Scripted Driving Event (the car\'s own task): the car drives, and its list finishes',
            fn = function(source, ctx)
                if not ctx.takeId then skip('the test drive could not be written to director_takes') end
                local start = ctx.takeStart
                local car = DK.car('it', { x = start.x, y = start.y, z = start.z, heading = DK.FIELD.heading },
                    { takes = { { id = ctx.takeId, label = 'whip_test drive', ms = 6000 } } })
                local r = play(source, ctx, DK.tasksDoc(car, { { k = 't', t = 'take', take = ctx.takeId } }, { settle = 2 }), function(net)
                    local o, last = DK.until_(source, { net = net }, function(x) return (x.speed or 0) > 4.0 end, 8000)
                    assertNotNil(o, ('it drives (%.1f m/s)'):format(last and last.speed or -1))
                end, 40000)
                finished(r)
            end,
        },
        {
            name = 'The scripted drive ends where it was recorded to end',
            fn = function(source, ctx)
                if not ctx.takeId then skip('the test drive could not be written to director_takes') end
                local start = ctx.takeStart
                local car = DK.car('it', { x = start.x, y = start.y, z = start.z, heading = DK.FIELD.heading },
                    { takes = { { id = ctx.takeId, label = 'whip_test drive', ms = 6000 } } })
                local doc = DK.tasksDoc(car, { { k = 't', t = 'take', take = ctx.takeId } }, { settle = 2,
                    nodes = { N('hold', 'flow.wait', { seconds = 600 }) } })
                -- Finished goes on to a long Wait (not the end), so the car is still there to look at.
                for _, l in ipairs(doc.links) do if l.from.node == 'ts' and l.from.pin == 'done' then l.to.node = 'hold' end end
                doc.links[#doc.links + 1] = { id = 'wx', from = { node = 'hold', pin = 'done' }, to = { node = 'win', pin = 'in' } }
                local r = DK.start(source, doc)
                ctx.runId = r.runId
                local net = DK.netOf(r.runId, 'it')
                assertNotNil(net, 'made')
                assertNotNil(DK.firedWait(r.runId, 'ts', 'done', 30000), 'the drive finished')
                Wait(1500)
                local o = DK.look(source, { net = net })
                assertTrue(o and o.exists, 'the car is still there')
                assertTrue(DK.dist2d(o, ctx.takeEnd) < 6.0, ('it stopped where the drive ends (%.1f m off, %.1f m from its start)')
                    :format(DK.dist2d(o, ctx.takeEnd), DK.dist2d(o, ctx.takeStart)))
                DK.stop(r.runId)
            end,
        },
        {
            name = 'Play Scripted Driving Event (the card): makes the car where the drive starts and plays it; Finished',
            fn = function(source, ctx)
                if not ctx.takeId then skip('the test drive could not be written to director_takes') end
                local car = DK.car('car', ctx.takeStart, { takes = { { id = ctx.takeId, label = 'whip_test drive', ms = 6000 } } })
                local r = DK.run(source, DK.doc({
                    world = { car },
                    nodes = { N('start', 'scenario.started'), N('settle', 'flow.wait', { seconds = 2 }),
                              N('drive', 'vehicle.playTake', { car = 'car', take = ctx.takeId, riders = false }),
                              N('win', 'scenario.succeed', { reason = 'driven' }), N('lose', 'scenario.fail', { reason = 'could not' }),
                              N('late', 'scenario.fail', { reason = 'too long' }) },
                    links = { { 'start', 'out', 'settle' }, { 'settle', 'done', 'drive' }, { 'drive', 'done', 'win' },
                              { 'drive', 'failed', 'lose' }, { 'drive', 'timeout', 'late' } },
                }), { seconds = 60 })
                assertEqual(r.reason, 'driven', 'Finished (' .. DK.how(r) .. '; ' .. DK.said(r) .. ')')
                assertTrue(type(r.things.car) == 'table' and r.things.car.vehicleId ~= nil, 'it made the car itself')
            end,
        },
        {
            -- (Not a police car: its siren flashes the headlights, which would muddle what the lights read.)
            name = 'Engine, Lights and Indicators: as each step set them',
            fn = function(source, ctx)
                local list = { { k = 'e', t = 'engine', how = 'on' }, { k = 'l', t = 'lights', lights = 'on', beam = true },
                               { k = 'i', t = 'indicators', side = 'hazards' }, { k = 'w', t = 'wait', sec = 5 } }
                local r = play(source, ctx, DK.tasksDoc(carAt('it', 12, 6), list), function(net)
                    assertNotNil(DK.until_(source, { net = net }, function(x) return yes(x.engine) end, 5000), 'its engine runs')
                    local o, last = DK.until_(source, { net = net }, function(x) return x.lightsOn or x.highbeams end, 3000)
                    assertNotNil(o, 'its lights are on (the game read lights / full beam: ' .. tostring(last and last.lightsRaw) .. ')')
                    o, last = DK.until_(source, { net = net }, function(x) return x.indicators == 3 end, 3000)
                    assertNotNil(o, 'hazards: both indicators (read ' .. tostring(last and last.indicators) .. ')')
                end)
                finished(r)
            end,
        },
        {
            name = 'Siren: on, on a police car',
            fn = function(source, ctx)
                local list = { { k = 'e', t = 'engine', how = 'on' }, { k = 's', t = 'siren', on = true }, { k = 'w', t = 'wait', sec = 4 } }
                local r = play(source, ctx, DK.tasksDoc(carAt('it', 12, 6, { model = 'police' }), list), function(net)
                    assertNotNil(DK.until_(source, { net = net }, function(x) return yes(x.siren) end, 4000), 'its siren is on')
                end)
                finished(r)
            end,
        },
        {
            name = 'Engine off, a door open, a window smashed',
            fn = function(source, ctx)
                local list = { { k = 'e', t = 'engine', how = 'on' }, { k = 'x', t = 'wait', sec = 2 }, { k = 'o', t = 'engine', how = 'off' },
                               { k = 'd', t = 'door', door = 'front left', how = 'open' }, { k = 'g', t = 'windows', window = 'front right', how = 'smashed' },
                               { k = 'w', t = 'wait', sec = 4 } }
                local r = play(source, ctx, DK.tasksDoc(carAt('it', 12, 6), list), function(net)
                    assertNotNil(DK.until_(source, { net = net }, function(x) return x.doors and (x.doors[1] or 0) > 0.1 end, 7000), 'the front left door open')
                    local o = DK.look(source, { net = net })
                    assertTrue(o and not yes(o.engine), 'its engine off')
                    assertNotNil(DK.until_(source, { net = net }, function(x) return x.windows and x.windows[2] == false end, 3000), 'the front right window smashed')
                end)
                finished(r)
            end,
        },
        {
            name = 'Tyres: one burst, then fixed',
            fn = function(source, ctx)
                local list = { { k = 'b', t = 'tyres', tyre = 'front left', how = 'burst' }, { k = 'w', t = 'wait', sec = 3 },
                               { k = 'f', t = 'tyres', tyre = 'front left', how = 'fixed' }, { k = 'x', t = 'wait', sec = 3 } }
                local r = play(source, ctx, DK.tasksDoc(carAt('it', 12, 6), list), function(net)
                    assertNotNil(DK.until_(source, { net = net }, function(x) return x.tyres and yes(x.tyres[1]) end, 4000), 'burst')
                    assertNotNil(DK.until_(source, { net = net }, function(x) return x.tyres and not yes(x.tyres[1]) end, 5000), 'fixed')
                end)
                finished(r)
            end,
        },
        {
            name = 'Dirt and the Alarm',
            fn = function(source, ctx)
                local list = { { k = 'd', t = 'dirt', pct = 100 }, { k = 'a', t = 'alarm' }, { k = 'w', t = 'wait', sec = 4 } }
                local r = play(source, ctx, DK.tasksDoc(carAt('it', 12, 6), list), function(net)
                    assertNotNil(DK.until_(source, { net = net }, function(x) return (x.dirt or 0) >= 14.0 end, 4000), 'filthy')
                    assertNotNil(DK.until_(source, { net = net }, function(x) return yes(x.alarm) end, 3000), 'its alarm going')
                end)
                finished(r)
            end,
        },
        {
            name = 'Convertible Roof: down',
            fn = function(source, ctx)
                local list = { { k = 'r', t = 'roof', how = 'down' }, { k = 'w', t = 'wait', sec = 5 } }
                local r = play(source, ctx, DK.tasksDoc(carAt('it', 12, 6, { model = 'felon2' }), list), function(net)
                    assertNotNil(DK.until_(source, { net = net }, function(x) return x.roof == 1 or x.roof == 2 end, 6000), 'lowering or lowered')
                end)
                finished(r)
            end,
        },
        {
            name = 'Lock or Unlock: whip\'s own lock, held by the server',
            fn = function(source, ctx)
                local list = { { k = 'l', t = 'lock', on = true }, { k = 'w', t = 'wait', sec = 3 }, { k = 'u', t = 'lock', on = false },
                               { k = 'x', t = 'wait', sec = 3 } }
                local r = play(source, ctx, DK.tasksDoc(carAt('it', 12, 6), list), function(net)
                    assertNotNil(waitFor(function() return serverLock(net) == 2 end, 4000), 'locked')
                    assertNotNil(waitFor(function() return serverLock(net) == 1 end, 5000), 'unlocked')
                end)
                finished(r)
            end,
        },
        {
            name = 'Speed Up To, Brake, Flash the Lights, Sound the Horn: each plays its time',
            fn = function(source, ctx)
                local list = { { k = 's', t = 'speedTo', speed = 40, sec = 2 }, { k = 'b', t = 'brake', sec = 2 },
                               { k = 'f', t = 'flashLights', sec = 2 }, { k = 'h', t = 'horn', sec = 1 } }
                local t0 = GetGameTimer()
                local r = play(source, ctx, DK.tasksDoc(carAt('it', 14, 8), list), function(net)
                    local o, last = DK.until_(source, { net = net }, function(x) return (x.speed or 0) > 4.0 end, 4000)
                    assertNotNil(o, ('it sped up (%.1f m/s)'):format(last and last.speed or -1))
                end)
                finished(r)
                assertGte(GetGameTimer() - t0, 6500, 'not before its 7 seconds')
            end,
        },
        {
            name = 'Set Health on a car, and Freeze',
            fn = function(source, ctx)
                local list = { { k = 'h', t = 'setHealth', pct = 40 }, { k = 'f', t = 'freeze', on = true }, { k = 'w', t = 'wait', sec = 3 },
                               { k = 'u', t = 'freeze', on = false } }
                local r = play(source, ctx, DK.tasksDoc(carAt('it', 12, 6), list), function(net)
                    local o, last = DK.until_(source, { net = net }, function(x)
                        return math.min(x.engineHealth or 1000, x.bodyHealth or 1000) <= 650
                    end, 4000)
                    assertNotNil(o, ('damaged (engine %s, body %s)'):format(tostring(last and last.engineHealth), tostring(last and last.bodyHealth)))
                end)
                finished(r)
            end,
        },
        {
            name = 'Teleport a car',
            fn = function(source, ctx)
                local to = DK.at(20, -10)
                local r = play(source, ctx, DK.tasksDoc(carAt('it', 12, 6), { { k = 't', t = 'teleport', at = to }, { k = 'w', t = 'wait', sec = 3 } }),
                    function(net)
                        assertNotNil(DK.until_(source, { net = net }, function(x) return DK.dist2d(x, to) < 3.0 end, 5000), 'at the point')
                    end)
                finished(r)
            end,
        },
        {
            name = 'Everyone Out: whoever sits in the car gets out',
            fn = function(source, ctx)
                local rider = DK.npc('rider', DK.at(10, 3), { tasks = { list = { { k = 'i', t = 'warpIn', car = 'it', seat = 'driver' } } } })
                local list = { { k = 'w', t = 'wait', sec = 4 }, { k = 'o', t = 'everyoneOut', giveUp = 10 }, { k = 'x', t = 'wait', sec = 2 } }
                local r = play(source, ctx, DK.tasksDoc(carAt('it', 12, 6), list, { after = { rider } }), function(net, runId)
                    local riderNet = DK.netOf(runId, 'rider')
                    assertNotNil(riderNet, 'its rider was made')
                    assertNotNil(DK.until_(source, { net = riderNet }, function(x) return x.inVehicle == net end, 5000), 'the rider sat in it')
                    assertNotNil(DK.until_(source, { net = riderNet }, function(x) return x.inVehicle == false end, 14000), 'and got out')
                end)
                finished(r)
            end,
        },
        {
            name = 'Set on Fire, and Blow Up (away from the tester)',
            fn = function(source, ctx)
                local r = play(source, ctx, DK.tasksDoc(carAt('it', 24, 12), { { k = 'f', t = 'fire' }, { k = 'w', t = 'wait', sec = 3 } }), function(net)
                    assertNotNil(DK.until_(source, { net = net }, function(x) return yes(x.onFire) or (x.engineHealth or 1000) < 0 end, 4000), 'its engine alight')
                end)
                finished(r)
                r = play(source, ctx, DK.tasksDoc(carAt('it', 24, -12), { { k = 'b', t = 'blowUp' }, { k = 'w', t = 'wait', sec = 3 } }), function(net)
                    assertNotNil(DK.until_(source, { net = net }, function(x) return yes(x.dead) end, 4000), 'blown up')
                end)
                finished(r)
            end,
        },
        {
            name = 'A prop\'s timeline: Slide To, Turn To, then Teleport',
            fn = function(source, ctx)
                local model = 'prop_barrel_02a'
                local from, to, jump = DK.at(6, -4), DK.at(6, 2), DK.at(10, -6)
                local list = { { k = 's', t = 'slideTo', at = to, sec = 2 }, { k = 'r', t = 'turnTo', heading = 90, sec = 1 },
                               { k = 'w', t = 'wait', sec = 2 }, { k = 't', t = 'teleport', at = jump }, { k = 'x', t = 'wait', sec = 3 } }
                local r = DK.start(source, DK.tasksDoc(DK.prop('it', from, model), list))
                ctx.runId = r.runId
                local slid = DK.until_(source, { model = model, at = to, radius = 1.0 }, function() return true end, 8000)
                assertNotNil(slid, 'slid to its point')
                local turned, last = DK.until_(source, { model = model, at = to, radius = 1.0 }, function(x) return math.abs(((x.heading - 90 + 180) % 360) - 180) < 15 end, 4000)
                assertNotNil(turned, ('turned to 90 (%.0f)'):format(last and last.heading or -1))
                assertNotNil(DK.until_(source, { model = model, at = jump, radius = 1.0 }, function() return true end, 6000), 'then at the teleport\'s point')
                r = DK.over(r.runId, 20000)
                finished(r)
            end,
        },
        {
            name = 'A prop fades out, and Change Look plays',
            fn = function(source, ctx)
                local model = 'prop_barrel_02a'
                local at = DK.at(6, -2)
                local r = DK.start(source, DK.tasksDoc(DK.prop('it', at, model), { { k = 'l', t = 'look', variant = 1 }, { k = 'f', t = 'fade', pct = 0, sec = 1 },
                                                                                  { k = 'w', t = 'wait', sec = 3 } }))
                ctx.runId = r.runId
                local o, last = DK.until_(source, { model = model, at = at, radius = 1.5 }, function(x)
                    return (x.alpha or 255) <= 10 or x.visible == false or x.visible == 0
                end, 8000)
                if not o and last and not last.exists then o = last end   -- (faded right out: no longer drawn at all)
                assertNotNil(o, ('faded out (alpha %s)'):format(tostring(last and last.alpha)))
                r = DK.over(r.runId, 20000)
                finished(r)
            end,
        },
    },
})
