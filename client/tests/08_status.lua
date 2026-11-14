-- ============================================
-- Client: Stats
-- ============================================
--
-- The client's stats are the server's, synced down; the client cannot set one. So what these can
-- check is that the read exports agree with each other and hold the stats every character has,
-- and that OnStatChange takes its options. The round trip — the server changes a stat and the
-- client sees it — needs a server-driven test and is not covered here.

RegisterClientTestModule({
    order    = 8,
    category = 'Client: Stats',
    tests = {
        {
            name = 'GetAllStats holds health and hunger, and GetStat agrees with every entry',
            fn = function()
                local s = exports.whip_core:GetAllStats()
                assertType(s, 'table', 'stats type')
                assertType(s.health, 'number', 'health is synced')
                assertType(s.hunger, 'number', 'hunger is synced')

                -- Read in the same frame, so a sync cannot land in between. A table value (a
                -- satellite's custom stat could be one) arrives as a fresh copy from each export
                -- call and cannot be compared by ==, so only plain values are compared.
                for name, value in pairs(s) do
                    if type(value) ~= 'table' then
                        assertEqual(exports.whip_core:GetStat(name), value,
                            ('GetStat(%s) matches GetAllStats'):format(tostring(name)))
                    end
                end
                assertNil(exports.whip_core:GetStat('_test_no_such_stat'), 'an unknown stat reads nil')
            end,
        },
        {
            -- STAT-10, 24 Sep 2026: GetStatuses was GetAllStats under an old name, and nothing
            -- outside whip_core called it. This used to check the two agreed.
            name = 'GetStatuses is gone — GetAllStats is the one name',
            fn = function()
                local ok = pcall(function() return exports.whip_core:GetStatuses() end)
                assertFalse(ok, 'calling the removed export fails')
            end,
        },
        {
            name = 'OnStatChange { now = true, table = true } is called straight away with one table',
            fn = function()
                -- The same options the server's OnStatChange takes. The listener cannot be taken
                -- back off, so it only records while this test is running.
                local heard, listening = nil, true
                local ok, err = exports.whip_core:OnStatChange('health', function(change)
                    if listening and type(change) == 'table' and heard == nil then heard = change end
                end, '_t08_now', { now = true, table = true })
                assertTrue(ok, 'registered: ' .. tostring(err))

                local deadline = GetGameTimer() + 2000
                while heard == nil and GetGameTimer() < deadline do Wait(50) end
                listening = false
                assertNotNil(heard, 'called without anything changing')
                assertEqual(heard and heard.key, 'health', 'the table names the stat')
                assertEqual(heard and heard.value, exports.whip_core:GetStat('health'), 'with the current value')
                assertNil(heard and heard.old, 'and no old value')

                local ok2, e2 = exports.whip_core:OnStatChange('health', nil)
                assertFalse(ok2, 'no callback is refused')
                assertNotNil(e2, 'with a reason')
            end,
        },
    }
})
