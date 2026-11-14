-- ============================================
-- Director kit — how the Director modules (76 on) build scenarios, run them and look at what they made
-- ============================================
--
-- A scenario is built here as the editor saves it (DK.doc) and run with whip_core's TestDirectorScenario: a Test
-- run for the tester, steered from here as the test map is (Take, an answer, an event, a variable). Nothing of value
-- is kept: what a Test hands out goes back at its end, Pay only says, Charge charges nothing.
--
-- What its cards made is looked at ON THE TESTER'S GAME (DK.probe, client/director_kit.lua), as a player sees it:
-- the entity by its netId, its coords, health, seat, lights and so on. The modules that need the world take the
-- tester to the test field first (DK.toField) and back after (DK.goHome).

DK = {}

local FORMAT = 2   -- (whip_core's server/director/doc.lua DirectorDoc.FORMAT)

-- ============================================
-- Building a scenario
-- ============================================

--- A card: its id, type and fields.
function DK.N(id, t, props) return { id = id, type = t, v = 1, x = 0, y = 0, props = props or {} } end

--- A scenario document. spec = { name, nodes, links = { { from, pin, to, toPin? } }, world, vars, settings }.
--- Every card gets a place on the canvas; every wire an id.
function DK.doc(spec)
    local nodes, links = {}, {}
    for i, n in ipairs(spec.nodes or {}) do
        n.x, n.y = ((i - 1) % 8) * 280, ((i - 1) // 8) * 180
        nodes[i] = n
    end
    for i, l in ipairs(spec.links or {}) do
        links[i] = { id = 'w' .. i, from = { node = l[1], pin = l[2] }, to = { node = l[3], pin = l[4] or 'in' } }
    end
    local settings = spec.settings or {}
    settings.start = settings.start or { mode = 'admin' }
    settings.maxConcurrentRuns = settings.maxConcurrentRuns or 1
    settings.maxRunSec = settings.maxRunSec or 300
    return { format = FORMAT, name = spec.name or 'whip_test scenario', vars = spec.vars or {}, world = spec.world or {},
             nodes = nodes, links = links, settings = settings }
end

--- A variable of the scenario: its name, its value at the start, its type ('number', 'text', 'bool').
function DK.var(id, default, vtype)
    if vtype == nil then vtype = type(default) == 'number' and 'number' or type(default) == 'boolean' and 'bool' or 'text' end
    return { id = id, label = id, type = vtype, default = default }
end

-- ============================================
-- Running one
-- ============================================

local function refused(why)
    if tostring(why):find('testing in the editor', 1, true) then skip('the tester is testing in the Director editor') end
end

function DK.result(runId) return exports.whip_core:GetDirectorTestResult(runId) end
function DK.steer(runId, op, ...) return exports.whip_core:SteerDirectorTest(runId, op, ...) end

-- Every test run the kit started and has not seen end. A test that fails part way (an assert) leaves its run going,
-- and the tester may have one scripted test at a time: so each start ends those first (DK.stopAll), and so does
-- every module's teardown, before the runner looks for leftovers.
local started = {}

--- End every test run the kit started that is still going, and wait for what they made to go.
function DK.stopAll()
    for id in pairs(started) do
        local r = DK.result(id)
        if r and r.status == 'running' then DK.steer(id, 'end', nil, 'whip_test: the test before it did not end it') end
    end
    waitFor(function()
        for id in pairs(started) do
            local r = DK.result(id)
            if r and not r.done then return false end
        end
        return true
    end, 10000)
    started = {}
end

--- Run a scenario as the tester's Test and wait for its end: its result (status, reason, vars, fired, steps...).
--- opts: TestDirectorScenario's (seconds, vars, steer).
function DK.run(source, doc, opts)
    DK.stopAll()
    opts = opts or {}
    opts.player = source
    local r, why = exports.whip_core:TestDirectorScenario(doc, opts)
    if r == false then refused(why) end
    assertType(r, 'table', 'the test run started (' .. tostring(why) .. ')')
    return r
end

--- Start one and answer at once (status 'running'): steer it with DK.steer, read it with DK.result.
function DK.start(source, doc, opts)
    DK.stopAll()
    opts = opts or {}
    opts.player = source
    opts.wait = false
    local r, why = exports.whip_core:TestDirectorScenario(doc, opts)
    if r == false then refused(why) end
    assertType(r, 'table', 'the test run started (' .. tostring(why) .. ')')
    started[r.runId] = true
    return r
end

--- How many of an item the tester carries in their pockets, a run's own stacks with their own. (GetItemCount leaves out
--- a run's: they are the mission's, not the player's to spend.)
function DK.carried(source, item)
    local ok, inv = pcall(function() return exports.whip_core:GetInventory(source) end)
    if not ok or type(inv) ~= 'table' then return 0 end
    local n = 0
    for _, slots in pairs(inv) do
        for _, data in pairs(type(slots) == 'table' and slots or {}) do
            if type(data) == 'table' and data.item == item then n = n + (tonumber(data.amount) or 0) end
        end
    end
    return n
end

--- Wait until fn(result) is true: that result, or nil when it never was in `ms`.
function DK.when(runId, fn, ms)
    return waitFor(function()
        local r = DK.result(runId)
        if r and fn(r) then return r end
        return nil
    end, ms or 10000)
end

--- Wait for its end (and what it made to go): its result, or nil.
function DK.over(runId, ms) return DK.when(runId, function(r) return r.done end, ms or 15000) end

--- Wait until a card waits (or has gone on): its result, or nil.
function DK.waiting(runId, node, ms)
    return DK.when(runId, function(r)
        for _, n in ipairs(r.waiting or {}) do if n == node then return true end end
        return false
    end, ms)
end

--- Wait until a card has gone out of this outcome `times` times (1).
function DK.firedWait(runId, node, pin, ms, times)
    return DK.when(runId, function(r) return DK.fired(r, node, pin) >= (times or 1) end, ms)
end

--- Ended: whatever a test left going is over (teardown, a failed assert).
function DK.stop(runId)
    if not runId then return end
    local r = DK.result(runId)
    if r and r.status == 'running' then DK.steer(runId, 'end', nil, 'whip_test is done with it') end
    DK.over(runId, 8000)
end

--- How many times a card went out of an outcome.
function DK.fired(r, node, pin)
    local f = r and r.fired and r.fired[node]
    return f and f[pin] or 0
end

--- How many times a card was reached.
function DK.entered(r, node) return r and r.entered and r.entered[node] or 0 end

--- The run's way through, for a message: "start>out wait>done win".
function DK.trail(r)
    local out = {}
    for _, s in ipairs(r and r.steps or {}) do
        if s.kind == 'out' or s.kind == 'resume' then out[#out + 1] = s.node .. '>' .. tostring(s.pin)
        elseif s.kind == 'enter' and #out < 60 then
            -- (Only a card with no outcome, an ending, is said by itself.)
        end
        if #out >= 40 then out[#out + 1] = '...' break end
    end
    return table.concat(out, ' ')
end

--- What a card said in the run's log (ctx:log), joined: for a message.
function DK.said(r, node)
    local out = {}
    for _, s in ipairs(r and r.steps or {}) do
        if s.kind == 'log' and (node == nil or s.node == node) and s.text then out[#out + 1] = s.text end
    end
    return table.concat(out, ' | ')
end

--- "succeeded (its reason)" etc., for a message.
function DK.how(r)
    if not r then return 'no result' end
    return ('%s (%s) via %s'):format(tostring(r.status), tostring(r.reason), DK.trail(r))
end

-- ============================================
-- The tester's game
-- ============================================

local pending, seq = {}, 0

RegisterNetEvent('whip_test:dk:answer', function(token, result)
    local p = pending[token]
    if p and p.src == source then p.result, p.done = result, true end
end)

--- Ask the tester's game something (client/director_kit.lua's ASK[what]): its answer, and whether it came.
function DK.ask(source, what, args, timeout)
    if HARNESS_OFFLINE then skip('needs the game') end
    seq = seq + 1
    local token = seq
    local p = { src = source }
    pending[token] = p
    TriggerClientEvent('whip_test:dk:ask', source, token, what, args)
    waitFor(function() return p.done end, timeout or 8000)
    pending[token] = nil
    return p.result, p.done == true
end

--- Where the tester's ped is, on the server: { x, y, z, heading }.
function DK.here(source)
    local ped = GetPlayerPed(source)
    local c = GetEntityCoords(ped)
    return { x = c.x, y = c.y, z = c.z, heading = GetEntityHeading(ped) }
end

--- Put the tester somewhere (collision loaded, on the ground there): where they ended up.
function DK.teleport(source, at)
    local got, came = DK.ask(source, 'teleport', { x = at.x, y = at.y, z = at.z, heading = at.heading or 0.0 }, 12000)
    assertTrue(came and type(got) == 'table', 'the tester was moved')
    return got
end

--- The ground's height at each { x, y } near the tester (their game's): the same list with z set.
function DK.ground(source, points)
    local got, came = DK.ask(source, 'ground', points, 8000)
    if not came or type(got) ~= 'table' then return points end
    for i, p in ipairs(points) do
        if type(got[i]) == 'number' then p.z = got[i] end
    end
    return points
end

--- What the tester's game sees of each thing: list = { { net = netId } | { model = name, at = { x, y, z }, radius } }
--- -> { { exists, kind, x, y, z, heading, health, ... } } (client/director_kit.lua's probe).
function DK.probe(source, list)
    local got, came = DK.ask(source, 'probe', list, 8000)
    if not came then return nil end
    return got
end

--- One thing: probe of { net = netId } or { model, at }.
function DK.look(source, what)
    local got = DK.probe(source, { what })
    return got and got[1] or nil
end

--- Is a networked thing still in the world (the server's view)?
function DK.exists(netId)
    if not netId then return false end
    local e = NetworkGetEntityFromNetworkId(netId)
    if e == nil or e == 0 then return false end
    -- (The server's DoesEntityExist answers 1 or 0, not true or false.)
    local yes = DoesEntityExist(e)
    return yes == true or yes == 1
end

--- Distance between two { x, y, z } (or a vector).
function DK.dist(a, b)
    if not (a and b) then return math.huge end
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Flat distance (ground plan).
function DK.dist2d(a, b)
    if not (a and b) then return math.huge end
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

-- ============================================
-- The test field: open, flat ground with room to drive
-- ============================================
--
-- The airport's apron and runways: tarmac all round, nobody's house. A module that makes things in the world takes
-- the tester there (DK.toField) and back where they were (DK.goHome).

DK.FIELD = { x = -1336.0, y = -3044.0, z = 13.95, heading = 240.0 }
local homes = {}

--- A point on the field: `ahead` metres along its heading and `side` to its right.
function DK.at(ahead, side, heading)
    local f = DK.FIELD
    local r = math.rad(f.heading)
    local fx, fy = -math.sin(r), math.cos(r)
    local rx, ry = fy, -fx
    return { x = f.x + fx * (ahead or 0) + rx * (side or 0), y = f.y + fy * (ahead or 0) + ry * (side or 0), z = f.z,
             heading = heading or f.heading }
end

--- Take the tester to the field, on foot and in the shared world; skipped when they cannot be.
function DK.toField(source)
    if HARNESS_OFFLINE then skip('needs the game') end
    if GetPlayerRoutingBucket(source) ~= 0 then skip('the tester is in a world of their own (a property or isolated): go outside') end
    local ped = GetPlayerPed(source)
    if GetVehiclePedIsIn(ped, false) ~= 0 then ClientLeaveVehicle(source) end
    homes[source] = homes[source] or DK.here(source)
    local got = DK.teleport(source, DK.FIELD)
    if type(got) == 'table' and tonumber(got.z) then DK.FIELD.z = tonumber(got.z) end
    return DK.FIELD
end

--- Back where they were before the field.
function DK.goHome(source)
    local h = homes[source]
    homes[source] = nil
    if h and not HARNESS_OFFLINE then
        local ped = GetPlayerPed(source)
        if ped ~= 0 and GetVehiclePedIsIn(ped, false) ~= 0 then ClientLeaveVehicle(source) end
        DK.ask(source, 'teleport', h, 12000)
    end
end

-- ============================================
-- Placed things, as the World tab makes them
-- ============================================

--- An NPC: calm, unarmed, standing, made where it is placed.
function DK.npc(id, at, over)
    local d = { model = 'a_m_y_business_01', coords = at, behaviour = 'stand', conditions = { canMove = true } }
    for k, v in pairs(over or {}) do d[k] = v end
    return { id = id, kind = 'npc', layer = 'run', label = id, def = d }
end

--- A car, unlocked.
function DK.car(id, at, over)
    local d = { model = 'sultan', coords = at, locked = false }
    for k, v in pairs(over or {}) do d[k] = v end
    return { id = id, kind = 'vehicle', layer = 'run', label = id, def = d }
end

--- A spot.
function DK.spot(id, at, over)
    local d = { coords = at }
    for k, v in pairs(over or {}) do d[k] = v end
    return { id = id, kind = 'spot', layer = 'run', label = id, def = d }
end

--- A prop.
function DK.prop(id, at, model, over)
    local d = { model = model or 'prop_barrel_02a', coords = at }
    for k, v in pairs(over or {}) do d[k] = v end
    return { id = id, kind = 'prop', layer = 'run', label = id, def = d }
end

-- ============================================
-- Tasks: one placed thing's list, started by Start Tasks
-- ============================================

--- A thing's maker card, and the outcome it goes on from.
local function maker(w, id, tasks)
    if w.kind == 'npc' then return DK.N(id, 'npc.spawn', { npcs = { w.id }, tasks = tasks }), 'out' end
    if w.kind == 'vehicle' then return DK.N(id, 'vehicle.spawn', { cars = { w.id }, tasks = tasks }), 'out' end
    return DK.N(id, 'prop.show', { prop = w.id, tasks = tasks }), 'out'
end

--- `it` (a placed thing) with this task list; `spec.before` made first and `spec.after` after it (each with their
--- own tasks); a moment to settle; then Start Tasks on `it`. Finished ends the run 'finished', Could not 'could not'.
--- spec: { before, after, loop, settle (seconds), nodes, links, vars, maxRunSec }.
function DK.tasksDoc(it, list, spec)
    spec = spec or {}
    local N = DK.N
    it.def.tasks = { list = list, after = spec.loop and 'loop' or 'stop' }
    local world, nodes, links = { it }, { N('start', 'scenario.started') }, {}
    local prev, pin = 'start', 'out'
    local function add(n, out)
        nodes[#nodes + 1] = n
        links[#links + 1] = { prev, pin, n.id }
        prev, pin = n.id, out
    end
    for i, w in ipairs(spec.before or {}) do world[#world + 1] = w add(maker(w, 'b' .. i, true)) end
    add(maker(it, 'make', false))
    for i, w in ipairs(spec.after or {}) do world[#world + 1] = w add(maker(w, 'a' .. i, true)) end
    add(N('settle', 'flow.wait', { seconds = spec.settle or 1 }), 'done')
    add(N('ts', 'tasks.start', { things = { it.id } }), 'done')
    nodes[#nodes + 1] = N('win', 'scenario.succeed', { reason = 'finished' })
    nodes[#nodes + 1] = N('lose', 'scenario.fail', { reason = 'could not' })
    links[#links + 1] = { 'ts', 'done', 'win' }
    links[#links + 1] = { 'ts', 'failed', 'lose' }
    for _, n in ipairs(spec.nodes or {}) do nodes[#nodes + 1] = n end
    for _, l in ipairs(spec.links or {}) do links[#links + 1] = l end
    return DK.doc({ world = world, vars = spec.vars, nodes = nodes, links = links, settings = { maxRunSec = spec.maxRunSec or 120 } })
end

--- The netId of what the run made for a placed thing (nil if the run ended first, or never made it).
function DK.netOf(runId, wid, ms)
    local r = DK.when(runId, function(x) return (type(x.things[wid]) == 'table' and x.things[wid].netId ~= nil) or x.done end, ms or 15000)
    return r and type(r.things[wid]) == 'table' and r.things[wid].netId or nil
end

--- Look at one thing on the tester's game until `fn(probe)` holds: that probe, or nil; and the last one seen.
function DK.until_(source, q, fn, ms)
    local last
    local got = waitFor(function()
        last = DK.look(source, q)
        return last and last.exists and fn(last) and last or nil
    end, ms or 8000)
    return got, last
end
