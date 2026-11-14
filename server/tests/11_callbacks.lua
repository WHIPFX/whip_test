-- ============================================
-- Callbacks — server-side registration, and a real round trip
--
-- This module's two tests were both `assertTrue(true)`, with comments explaining that the
-- real round-trip happens on the client. Its replacement was not much better: one test
-- asserting a global that setup set on the line before it returned, which could not fail.
--
-- Callbacks are client->server by construction (client/callback.lua Callback() -> the
-- 'whip_core:server:triggerCallback' net event -> the registered handler), and ClientCallback
-- is how a server test gets to that path now: it asks the tester's client to make the call
-- and hands back what the callback answered. So the round trip is tested HERE, against the
-- same handlers client/tests/11_callbacks.lua calls.
--
-- The setup is still load-bearing for that client module, which is why the handlers stay
-- registered for the whole run rather than being torn down with this module.
-- ============================================

RegisterTestModule({
    order    = 11,
    category = 'Callbacks',
    setup = function()
        -- SecureCallback, not RegisterCallback. The raw registrar stopped being exported when
        -- the transport was given a rate limit: it was the only public entry point in whip with
        -- no schema, no session check and no Event Monitor entry, so a satellite using it got
        -- none of the protection the framework advertises and was never told.
        --
        -- These handlers take whatever the client sends, so their params are declared 'any'.
        -- That is the honest declaration for an echo — 'any' documents "unvalidated on purpose"
        -- where a missing params list would merely look like someone forgot.
        exports.whip_core:SecureCallback('_test_echo', {
            params = { { 'val', 'any' } },
        }, function(source, player, val)
            return val
        end)
        exports.whip_core:SecureCallback('_test_multi', {
            params = { { 'a', 'any' }, { 'b', 'any' }, { 'c', 'any' } },
        }, function(source, player, a, b, c)
            return a + b + c
        end)
        exports.whip_core:SecureCallback('_test_table', {
            params = { { 'data', 'any' } },
        }, function(source, player, data)
            return { received = true, original = data }
        end)

        -- A DECLARED param with no default, so a wrong type is refused — the half of a callback
        -- the echoes above can never show.
        exports.whip_core:SecureCallback('_test_cb_typed', {
            rateLimit = false,
            params = { { 'val', 'int', 1, 10 } },
        }, function(source, player, val)
            return val
        end)
    end,

    tests = {
        {
            -- A dead setup still fails HERE rather than as 'unknown callback' in a different file:
            -- an unregistered name answers nil, and this asserts the value.
            name = 'A registered callback answers the client that asked',
            fn = function(source)
                local answered, res = ClientCallback(source, '_test_echo', nil, 42)
                assertTrue(answered, 'the client got an answer')
                assertEqual(res and res[1], 42, 'the echo came back')

                answered, res = ClientCallback(source, '_test_multi', nil, 10, 20, 30)
                assertEqual(res and res[1], 60, 'several arguments arrive in order')

                answered, res = ClientCallback(source, '_test_table', nil, { a = 1, b = 'test' })
                local t = res and res[1]
                assertTrue(type(t) == 'table' and t.received == true, 'a table comes back as a table')
                assertEqual(t.original and t.original.b, 'test', 'with its contents intact')
            end,
        },
        {
            name = "A callback's declared params refuse a wrong type, and the refusal is recorded",
            fn = function(source)
                local answered, res = ClientCallback(source, '_test_cb_typed', nil, 'seven')
                assertTrue(answered, 'a refused callback still answers the client')
                -- false, reason (SEC-5, 24 Sep 2026) — it used to be a bare nil.
                assertEqual(res and res[1], false, 'with false')
                assertEqual(res and res[2], 'val: expected number, got string', 'and the reason')
                assertLastReject('cb:_test_cb_typed', 'val: expected number, got string',
                    'refused by its param, under the cb: name')

                answered, res = ClientCallback(source, '_test_cb_typed', nil, 7)
                assertEqual(res and res[1], 7, 'the right type goes through')
                assertLastReject('cb:_test_cb_typed', nil, 'and is not refused')
            end,
        },
        {
            -- An unknown name must be answered straight away (server/callback.lua), not leave the
            -- client waiting out its 10-second timeout. The console's "unknown callback" warning
            -- for this name is EXPECTED output, printed once per server session.
            name = "An unknown callback name answers false, 'Unknown callback'",
            fn = function(source)
                local started = GetGameTimer()
                local answered, res = ClientCallback(source, '_test_no_such_callback', nil)
                assertTrue(answered, 'the client got an answer')
                assertEqual(res and res[1], false, 'and it was false')
                assertEqual(res and res[2], 'Unknown callback', 'saying why')
                assertTrue(GetGameTimer() - started < 5000,
                    'answered by the server, not by the client giving up after 10 seconds')
            end,
        },
    },
})
