RegisterTestModule({
    order    = 1,
    category = 'Player',
    tests    = {
        {
            name = 'GetPlayer returns WhipPlayer for valid source',
            fn = function(source)
                local player = exports.whip_core:GetPlayer(source)
                assertNotNil(player, 'GetPlayer')
                assertEqual(player.source, source, 'player.source')
            end,
        },
        {
            name = 'GetPlayer returns nil for invalid source',
            fn = function()
                local player = exports.whip_core:GetPlayer(999999)
                assertNil(player, 'GetPlayer(999999)')
            end,
        },
        {
            name = 'GetPlayers contains current player',
            fn = function(source)
                local players = exports.whip_core:GetPlayers()
                assertNotNil(players, 'GetPlayers')
                assertNotNil(players[source], 'players[source]')
            end,
        },
        {
            name = 'GetPlayer({ charId }) finds player',
            fn = function(source)
                local player = exports.whip_core:GetPlayer(source)
                local found = exports.whip_core:GetPlayer({ charId = player.charId })
                assertNotNil(found, 'GetPlayer({ charId })')
                assertEqual(found.source, source, 'found.source')
            end,
        },
        {
            name = 'GetPlayer({ userId }) finds player',
            fn = function(source)
                local player = exports.whip_core:GetPlayer(source)
                local found = exports.whip_core:GetPlayer({ userId = player.userId })
                assertNotNil(found, 'GetPlayer({ userId })')
                assertEqual(found.source, source, 'found.source')
            end,
        },
        {
            name = 'GetPlayer({ identifier }) finds by license',
            fn = function(source)
                -- IDENTIFIERS HAVE THEIR OWN EXPORT NOW. GetPlayer returns the same sheet whip
                -- sends to the CLIENT on playerLoaded, and a licence id has no business being
                -- shipped to the machine it identifies — so serialize() leaves the four
                -- identifiers off and GetPlayerIdentifiers is where they live.
                local ids = exports.whip_core:GetPlayerIdentifiers(source)
                assertNotNil(ids, 'GetPlayerIdentifiers')
                assertType(ids.license, 'string', 'license')

                local found = exports.whip_core:GetPlayer({ identifier = ids.license })
                assertNotNil(found, 'GetPlayer({ identifier })')
                assertEqual(found.source, source, 'found.source')
            end,
        },
        {
            name = 'Player has required fields',
            fn = function(source)
                local p = exports.whip_core:GetPlayer(source)
                assertType(p.charId, 'number', 'charId')
                assertType(p.userId, 'number', 'userId')
                assertType(p.fullName, 'string', 'fullName')
                assertType(p.firstName, 'string', 'firstName')
                assertType(p.lastName, 'string', 'lastName')
                assertType(p.metadata, 'table', 'metadata')

                -- `cash` is on the sheet and was NOT reachable before: it is computed by
                -- getCash(), and a method could never cross the export boundary.
                assertType(p.cash, 'number', 'cash')

                -- And the identifiers are deliberately NOT here. Asserting their absence is the
                -- point — if one reappears on this sheet it is also going to the client.
                assertNil(p.license, 'license is not on the player sheet')
                assertNil(p.steam, 'steam is not on the player sheet')
            end,
        },
        -- 'Player metadata is directly accessible' lived here and could not fail: it wrote a key
        -- into the sheet GetPlayer returned and read it straight back — from the same local copy,
        -- because everything crossing an export is a copy. Whip never saw either write. Metadata
        -- that actually reaches the player (and the database) is 35_player_api's subject; that the
        -- sheet carries a metadata table at all is checked in 'Player has required fields' above.
        {
            -- Statuses are NOT a field on WhipPlayer and have not been since server/stats.lua
            -- took ownership of them (handover documented at server/events_misc.lua:20-21).
            -- This test previously asserted p.statuses and had been failing ever since.
            -- The accessor is GetStats, on both sides (the client's old GetStatuses alias was
            -- removed 24 Sep 2026).
            name = 'Player statuses are readable through the Stats system',
            fn = function(source)
                local stats = exports.whip_core:GetStats(source)
                assertType(stats, 'table', 'GetStats returns a table')
                assertType(stats.health, 'number', 'health type')
                assertType(stats.hunger, 'number', 'hunger type')
                assertType(stats.thirst, 'number', 'thirst type')
            end,
        },
        {
            -- Guards the regression this whole class of failure came from: a field that
            -- silently disappears in a refactor should fail LOUDLY, not read as nil.
            name = 'WhipPlayer does not carry a stale statuses field',
            fn = function(source)
                local p = exports.whip_core:GetPlayer(source)
                assertNil(p.statuses, 'statuses must live in Stats, not on WhipPlayer')
            end,
        },
    }
})
