-- ============================================
-- Director: Live Runs — a real run of a scenario a script starts, steers and ends; Scenario Started and cooldown
-- ============================================
--
-- A real run (not a Test) needs a scenario that is switched on and starts "From a script". whip_test registers one
-- of its own in code ('whip_test_live', with __RegisterDirectorScenario: the plumbing under Whip.scenario, called
-- straight because setup needs the status it returns): it waits until a Director admin accepts it, or
-- trusts whip_test, in /whip (Director > Shipped), and a person switches it on once there. Until then this module
-- is skipped, saying so. Its cards only wait, branch and end: nothing is handed out or paid.
--
-- Its cooldown is a minute: the module waits it out, and ends with Call Offs (which start none), so the next /test
-- starts clean.

local N = DK.N
local KEY = 'whip_test_live'

local function liveDoc()
    return DK.doc({
        name = 'whip_test: live runs',
        vars = { DK.var('x', 0) },
        settings = { start = { mode = 'script' }, scriptSwitch = true, maxConcurrentRuns = 1, maxRunSec = 120, cooldownMin = 1 },
        nodes = { N('start', 'scenario.started'), N('begin', 'scenario.begin'),
                  N('ear', 'script.wait', { event = 'whip_test.done', who = 'Sent for this run', seconds = 60 }),
                  N('if', 'flow.if', { var = 'x', op = 'is', value = '5' }),
                  N('went', 'scenario.succeed', { reason = 'went' }), N('wrong', 'scenario.fail', { reason = 'x was not 5' }),
                  N('late', 'scenario.fail', { reason = 'no event' }), N('cooling', 'scenario.calloff', { reason = 'cooling' }) },
        links = { { 'start', 'out', 'begin' }, { 'begin', 'started', 'ear' }, { 'begin', 'notnow', 'cooling' },
                  { 'ear', 'heard', 'if' }, { 'ear', 'timeout', 'late' }, { 'if', 'yes', 'went' }, { 'if', 'no', 'wrong' } },
    })
end

--- The run:ended a script hears for this run id, waited for: its payload, or nil.
local ended = {}
local function endedOf(runId, ms) return waitFor(function() return ended[runId] end, ms or 10000) end

RegisterTestModule({
    order    = 79,
    category = 'Director: Live Runs',
    setup = function(source, ctx)
        local p = exports.whip_core:GetPlayer(source)
        if not (p and p.charId) then skip('the tester is not on a character') end
        local status, why = exports.whip_core:__RegisterDirectorScenario(KEY, liveDoc())
        if status ~= 'accepted' then
            skip(('the scenario "%s" is %s: accept it (or trust whip_test) in /whip, Director > Shipped, and switch it on once'):format(
                KEY, tostring(status or why)))
        end
        local okOn, onWhy = exports.whip_core:SwitchScenario(KEY, true, 'whip_test live runs')
        if not okOn then skip(('"%s" could not be switched on (%s): switch it on once in /whip'):format(KEY, tostring(onWhy))) end
        ctx.handlers = {
            AddEventHandler('whip_core:run:ended', function(p)
                if type(p) == 'table' and type(p.run) == 'table' and p.run.scenario == KEY then ended[p.run.id] = p end
            end),
        }
    end,
    teardown = function(ctx)
        if ctx.runId then pcall(function() exports.whip_core:EndScenarioRun(ctx.runId, 'calledOff', 'whip_test is done') end) end
        for _, h in ipairs(ctx.handlers or {}) do RemoveEventHandler(h) end
        pcall(function() exports.whip_core:SwitchScenario(KEY, false, 'whip_test live runs over') end)
    end,
    tests = {
        {
            name = 'StartScenarioRun: a real run for the tester, listed for scripts and found by its id',
            fn = function(source, ctx)
                local started = {}
                local h = AddEventHandler('whip_core:run:started', function(p)
                    if type(p) == 'table' and type(p.run) == 'table' then started[p.run.id] = true end
                end)
                local id, why = exports.whip_core:StartScenarioRun(KEY, source)
                assertType(id, 'number', 'started (' .. tostring(why) .. ')')
                ctx.runId = id
                -- (Cooling down from this module's last run, under a minute ago: its Scenario Started says Not now.)
                Wait(1500)
                RemoveEventHandler(h)
                if ended[id] and tostring(ended[id].reason):find('cooling', 1, true) then
                    ctx.runId = nil
                    skip('the tester is cooling down from this module\'s last run: /test it again in a minute')
                end
                local view = exports.whip_core:GetScenarioRun(id)
                assertType(view, 'table', 'GetScenarioRun finds it')
                local listed = false
                for _, v in ipairs(exports.whip_core:GetScenarioRuns({ scenario = KEY }) or {}) do if v.id == id then listed = true end end
                assertTrue(listed, 'GetScenarioRuns lists it')
                assertTrue(exports.whip_core:IsPlayerInScenarioRun(source, KEY), 'the tester is in it')
                assertTrue(waitFor(function() return started[id] end, 3000) ~= nil, 'scripts heard run:started')
                local again = exports.whip_core:StartScenarioRun(KEY, source)
                assertFalse(again, 'a second run of it for the same player is refused while one goes')
            end,
        },
        {
            name = 'A script steers it: a variable of its type, an event into it; it succeeds and scripts hear how',
            fn = function(source, ctx)
                if not ctx.runId then skip('no run from the test before') end
                assertNotNil(waitFor(function()
                    local ok, v = exports.whip_core:GetScenarioRunVar(ctx.runId, 'x')
                    return ok and v ~= nil
                end, 3000), 'its variable can be read')
                local bad = exports.whip_core:SetScenarioRunVar(ctx.runId, 'x', 'five')
                assertFalse(bad, 'text into a number variable is refused')
                assertTrue((exports.whip_core:SetScenarioRunVar(ctx.runId, 'x', 5)), 'a number goes in')
                local ok, v = exports.whip_core:GetScenarioRunVar(ctx.runId, 'x')
                assertTrue(ok and v == 5, 'and reads back')
                local sent, heard = exports.whip_core:SendDirectorEvent('whip_test.done', { source = source }, { runId = ctx.runId })
                assertTrue(sent, 'the event was sent (' .. tostring(heard) .. ')')
                local e = endedOf(ctx.runId)
                assertNotNil(e, 'scripts heard run:ended')
                assertEqual(e.reason, 'went', 'it went the way its variable said')
                ctx.runId = nil
            end,
        },
        {
            name = 'Cooldown: straight after, the tester\'s next run gets to Scenario Started and goes Not now',
            fn = function(source, ctx)
                local id, why = exports.whip_core:StartScenarioRun(KEY, source)
                assertType(id, 'number', 'a run starts, its lead-in at least (' .. tostring(why) .. ')')
                ctx.runId = id
                local e = endedOf(id)
                assertNotNil(e, 'it ended by itself')
                assertTrue(tostring(e.reason):find('cooling', 1, true) ~= nil, 'from Not now: the tester is cooling down (' .. tostring(e.reason) .. ')')
                ctx.runId = nil
            end,
        },
        {
            name = 'Cooldown over: a minute on, the next run gets past Scenario Started (then is ended by the test)',
            fn = function(source, ctx)
                -- (The minute is waited out so the next /test starts clean, whatever this finds.)
                Wait(62000)
                local id, why = exports.whip_core:StartScenarioRun(KEY, source)
                assertType(id, 'number', 'started (' .. tostring(why) .. ')')
                ctx.runId = id
                -- Past Scenario Started it waits for its event: still going, not ended for cooling.
                Wait(2000)
                assertNil(ended[id], 'not Not now this time: it did not end')
                assertType(exports.whip_core:GetScenarioRun(id), 'table', 'still going, waiting for its event')
                assertTrue((exports.whip_core:EndScenarioRun(id, 'calledOff', 'whip_test is done')), 'EndScenarioRun ends it')
                local e = endedOf(id)
                assertNotNil(e, 'ended')
                assertNil(tostring(e.reason):find('cooling', 1, true), 'and not for cooling (' .. tostring(e.reason) .. ')')
                ctx.runId = nil
            end,
        },
        {
            name = 'Called off: no cooldown ("no thanks" is a job never taken), so the next run gets past Scenario Started',
            fn = function(source, ctx)
                -- (The run before this one was called off with EndScenarioRun.)
                local id, why = exports.whip_core:StartScenarioRun(KEY, source)
                assertType(id, 'number', 'started (' .. tostring(why) .. ')')
                ctx.runId = id
                Wait(2000)
                assertNil(ended[id], 'not Not now: the Call Off before it started no cooldown')
                assertTrue((exports.whip_core:EndScenarioRun(id, 'calledOff', 'whip_test is done')), 'EndScenarioRun ends it')
                assertNotNil(endedOf(id), 'ended')
                ctx.runId = nil
            end,
        },
    },
})
