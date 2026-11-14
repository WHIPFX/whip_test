-- ============================================
-- whip_test's kit — your resource's own tests, on their own card in /test
-- ============================================
--
-- In your fxmanifest.lua (a test server only: whip_test runs with Config.EnableTestSeams on, never live):
--
--     server_script '@whip_test/lib/kit.lua'
--
-- Then, in a server file of yours:
--
--     Whip.registerWith('whip_test', function()
--         WhipTest.module({
--             category = 'My Café',
--             tests = {
--                 { name = 'a coffee costs $5', fn = function(source)
--                     local ok, why = exports.whip_core:ChargePlayer(source, 5, { method = 'cash' })
--                     WhipTest.assertOk(ok, why, 'charged')
--                 end },
--             },
--         })
--     end)
--
-- /test shows a card named after your resource; /test <your resource> runs it. Each test gets the tester's server
-- id; a test that checks nothing fails ("no assertion ran"). Keep a module's state in your own locals: the `ctx`
-- whip_test hands over arrives as a copy. WhipTest.makeStranger() makes a throwaway character for a test that needs
-- someone else (a key given, money sent); WhipTest.disposeStranger(userId) removes it.

WhipTest = {}

local count = 0
local SKIP = '__whip_test_skip__'

local function fail(label, message)
    error(('%s: %s'):format(label or 'assert', message), 3)
end

function WhipTest.assertEqual(actual, expected, label)
    count = count + 1
    if actual ~= expected then fail(label, ('expected %s, got %s'):format(tostring(expected), tostring(actual))) end
end
function WhipTest.assertTrue(value, label)
    count = count + 1
    if value ~= true then fail(label, 'expected true, got ' .. tostring(value)) end
end
function WhipTest.assertFalse(value, label)
    count = count + 1
    if value ~= false then fail(label, 'expected false, got ' .. tostring(value)) end
end
function WhipTest.assertNil(value, label)
    count = count + 1
    if value ~= nil then fail(label, 'expected nil, got ' .. tostring(value)) end
end
function WhipTest.assertNotNil(value, label)
    count = count + 1
    if value == nil then fail(label, 'expected a value, got nil') end
end
--- A call's answer: anything but nil or false passes; a failure says the call's own reason.
function WhipTest.assertOk(value, err, label)
    count = count + 1
    if value == nil or value == false then fail(label, 'failed — ' .. tostring(err or 'no reason given')) end
end

--- Stop this test and record it as skipped, not failed (a precondition this server does not meet).
function WhipTest.skip(reason)
    error(SKIP .. ':' .. tostring(reason or 'no reason given'), 2)
end

--- Wait until fn() answers something truthy, at most timeoutMs (default 5000): that answer, or nil.
function WhipTest.waitFor(fn, timeoutMs)
    local untilAt = GetGameTimer() + (tonumber(timeoutMs) or 5000)
    repeat
        local v = fn()
        if v then return v end
        Wait(50)
    until GetGameTimer() > untilAt
    return nil
end

--- A throwaway character in the database: (charId, userId), or nil when the test seams are off.
function WhipTest.makeStranger() return exports.whip_test:MakeStranger() end
function WhipTest.disposeStranger(userId) return exports.whip_test:DisposeStranger(userId) end

--- Register a module of tests: { category, order?, setup?(source), teardown?(ctx, source), tests = { { name, fn(source) } } }.
--- Put it in Whip.registerWith('whip_test', ...) so it comes back when whip_test restarts.
---@return boolean ok, string|nil why
function WhipTest.module(def)
    if type(def) ~= 'table' or type(def.tests) ~= 'table' then return false, 'WhipTest.module({ category, tests = { ... } })' end
    local tests = {}
    for i, t in ipairs(def.tests) do
        local userFn = t.fn
        tests[i] = { name = t.name, fn = function(source, ctx)
            count = 0
            userFn(source, ctx)
            return count   -- whip_test counts these as this test's assertions
        end }
    end
    return exports.whip_test:RegisterTestModule({
        category = def.category, order = def.order, setup = def.setup, teardown = def.teardown, tests = tests,
    })
end
