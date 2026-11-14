RegisterClientTestModule({
    order    = 11,
    category = 'Client: Callbacks',
    tests = {
        {
            name = 'Echo round-trip returns correct value',
            fn = function()
                local result = exports.whip_core:Callback('_test_echo', 42)
                assertEqual(result, 42, 'echo result')
            end,
        },
        {
            name = 'Echo round-trip with string',
            fn = function()
                local result = exports.whip_core:Callback('_test_echo', 'hello')
                assertEqual(result, 'hello', 'echo string')
            end,
        },
        {
            name = 'Multi-arg callback returns sum',
            fn = function()
                local result = exports.whip_core:Callback('_test_multi', 10, 20, 30)
                assertEqual(result, 60, 'multi sum')
            end,
        },
        {
            name = 'Table arg preserved through round-trip',
            fn = function()
                local result = exports.whip_core:Callback('_test_table', { a = 1, b = 'test' })
                assertNotNil(result, 'result not nil')
                assertType(result, 'table', 'result type')
                assertTrue(result.received, 'received flag')
                assertNotNil(result.original, 'original preserved')
                assertEqual(result.original.a, 1, 'original.a')
                assertEqual(result.original.b, 'test', 'original.b')
            end,
        },
    }
})
