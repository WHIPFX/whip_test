-- ============================================
-- Client: Player
-- ============================================
--
-- CHECKED AGAINST THE STATEBAG, NOT AGAINST A TYPE. These used to assert that charId was "a
-- number" and that IsPlayerDead returned "a boolean" — both true of any value the cache could
-- hold, including the wrong character's id. The server writes the character id and the dead
-- flag onto this player's statebag through the Sentinel (shared/statebags.lua), so there is an
-- independent copy to compare the client cache against.

RegisterClientTestModule({
    order    = 1,
    category = 'Client: Player',
    tests = {
        {
            name = 'IsPlayerLoaded returns true',
            fn = function()
                assertTrue(exports.whip_core:IsPlayerLoaded(), 'IsPlayerLoaded')
            end,
        },
        {
            name = 'GetPlayer and GetCharId name the character the server loaded',
            fn = function()
                local data = exports.whip_core:GetPlayer()
                assertNotNil(data, 'GetPlayer')
                assertType(data.charId, 'number', 'charId type')

                -- NOT ON THE STATEBAG (SEC-15, 26 Sep 2026): a bag reaches every client, so the
                -- charId and name are no longer put there. The name is asked for instead.
                assertNil(LocalPlayer.state.whipCharId, 'no charId on the shared player bag')
                assertNil(LocalPlayer.state.whipName, 'and no name')
                assertEqual(exports.whip_core:GetPlayerFullName(GetPlayerServerId(PlayerId())), data.fullName,
                    'GetPlayerFullName answers your own name')
                assertNil(exports.whip_core:GetPlayerFullName(65000, true),
                    'and nil for a server id nobody holds, after asking the server')

                -- Was its own test, reading the same field; now it has to agree with it.
                assertEqual(exports.whip_core:GetCharId(), data.charId, 'GetCharId agrees with GetPlayer')
            end,
        },
        {
            name = 'IsPlayerDead is false, and agrees with the server\'s dead flag',
            fn = function()
                -- /test refuses to start for a dead tester, so false is the only right answer.
                local dead = exports.whip_core:IsPlayerDead()
                assertFalse(dead, 'the tester is alive')

                -- 'whipDead' is PLAYER_DEAD_KEY. Absent while alive at load, false after a revive —
                -- so compared as `== true` rather than to the raw value.
                assertEqual(dead, LocalPlayer.state.whipDead == true,
                    'the client\'s own death state agrees with the server\'s statebag')
            end,
        },
        {
            -- STAT-8, 24 Sep 2026. GetPlayer was the login snapshot plus cash; isDead, health
            -- and armour went stale while IsPlayerDead and GetStat stayed right.
            name = 'GetPlayer is live: isDead, health and armour agree with their own exports',
            fn = function()
                local data = exports.whip_core:GetPlayer()
                assertEqual(data.isDead, exports.whip_core:IsPlayerDead(), 'isDead is IsPlayerDead()')
                assertEqual(data.health, exports.whip_core:GetStat('health'), 'health is GetStat(\'health\')')
                assertEqual(data.armour, exports.whip_core:GetStat('armour'), 'armour is GetStat(\'armour\')')
                assertType(data.metadata, 'table', 'and metadata is there')
            end,
        },
    }
})
