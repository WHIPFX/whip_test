-- ============================================
-- Client: Emotes — /e, the props others see, what ends an emote, walks and moods
-- ============================================
--
-- Runs in the player's own game: it plays real emotes on the player's ped. Uses the starter list
-- in whip_core/shared/emote_list.lua ('drink' holds prop_ld_flow_bottle).

local BOTTLE = GetHashKey('prop_ld_flow_bottle')

--- The bottle in the player's hand, or nil.
local function heldBottle()
    for _, obj in ipairs(GetGamePool('CObject')) do
        if GetEntityModel(obj) == BOTTLE and IsEntityAttachedToEntity(obj, PlayerPedId()) then return obj end
    end
    return nil
end

local function drinking()
    -- Truthy, not `== true`: this native answers 1 or false.
    return IsEntityPlayingAnim(PlayerPedId(), 'mp_player_intdrink', 'loop_bottle', 3) and true or false
end

local function meta()
    local data = exports.whip_core:GetPlayerData()
    return data and data.metadata or {}
end

RegisterClientTestModule({
    order    = 16,
    category = 'Client: Emotes',
    teardown = function()
        pcall(exports.whip_core.CancelEmote, exports.whip_core)
        ExecuteCommand('walk c')
        ExecuteCommand('mood c')
    end,
    tests = {
        {
            name = 'PlayEmote drink: the clip plays and a networked bottle is in hand',
            fn = function()
                assertNil(heldBottle(), 'no bottle before')
                local ok, why = exports.whip_core:PlayEmote('drink')
                assertTrue(ok, ('PlayEmote answered true (why: %s)'):format(tostring(why)))
                assertTrue(waitFor(drinking, 3000), 'the drink clip plays')
                assertTrue(waitFor(function() return heldBottle() ~= nil end, 3000), 'the bottle is in hand')
                local networked = waitFor(function()
                    local b = heldBottle()
                    return b ~= nil and NetworkGetEntityIsNetworked(b) and true or false
                end, 2000)
                -- If not, say what the game DOES say about it — this failed once in game (26 Sep)
                -- and the plain "got nil" could not tell a missing registration from a slow one.
                local detail = ''
                if not networked then
                    local b = heldBottle()
                    detail = (' [bottle %s, IsNetworked=%s, netId=%s]'):format(tostring(b),
                        tostring(b and NetworkGetEntityIsNetworked(b)),
                        tostring(b and NetworkGetNetworkIdFromEntity(b)))
                end
                assertTrue(networked, 'the bottle is networked, so others see it' .. detail)
                assertEqual(exports.whip_core:IsEmoting(), 'drink', 'IsEmoting names it')
            end,
        },
        {
            name = 'CancelEmote: the clip stops and the bottle goes',
            fn = function()
                exports.whip_core:PlayEmote('drink')
                assertTrue(waitFor(function() return heldBottle() ~= nil end, 3000), 'set up: bottle in hand')
                assertTrue(exports.whip_core:CancelEmote(), 'CancelEmote answered true')
                assertTrue(waitFor(function() return not drinking() end, 1500), 'the clip stopped')
                assertTrue(waitFor(function() return heldBottle() == nil end, 1500), 'the bottle is gone')
                assertEqual(exports.whip_core:IsEmoting(), false, 'IsEmoting is false')
            end,
        },
        {
            name = 'An unknown emote is refused with a reason',
            fn = function()
                local ok, why = exports.whip_core:PlayEmote('no_such_emote_here')
                assertFalse(ok, 'refused')
                assertType(why, 'string', 'with a reason')
            end,
        },
        {
            name = 'A progress bar ends the emote (and its prop) and keeps its own animation',
            fn = function()
                exports.whip_core:PlayEmote('drink')
                assertTrue(waitFor(function() return heldBottle() ~= nil end, 3000), 'set up: drinking')

                local res
                CreateThread(function()
                    res = table.pack(exports.whip_core:Progress({
                        label = '[TEST] emote vs bar', duration = 1500,
                        anim  = { dict = 'mp_player_intdrink', clip = 'loop_bottle' },
                        disable = { move = false },
                    }))
                end)
                local okDuring, errDuring = pcall(function()
                    assertTrue(waitFor(function() return exports.whip_core:IsEmoting() == false end, 1000),
                        'the emote ended when the bar began')
                    assertTrue(waitFor(function() return heldBottle() == nil end, 1000), "the emote's bottle went with it")
                    assertTrue(waitFor(drinking, 2500), "the bar's own animation plays")
                    local ok = exports.whip_core:PlayEmote('drink')
                    assertFalse(ok, 'no emote while a bar runs')
                end)
                if not okDuring then
                    exports.whip_core:CancelProgress()
                    waitFor(function() return res ~= nil end, 3000)
                    error(errDuring, 0)
                end
                assertTrue(waitFor(function() return res ~= nil end, 4000), 'the bar answered')
                assertTrue(res[1], ('the bar completed (why: %s)'):format(tostring(res[2])))
            end,
        },
        {
            -- Spamming emotes once piled bottles up in the hand, for everyone (26 Sep): the server
            -- deleted props their owner then sent back. Counted near the player, held or not, since
            -- a returned one need not be attached.
            name = 'Spamming emotes leaves no props behind, and none come back',
            fn = function()
                local function bottlesNear()
                    local n, me = 0, GetEntityCoords(PlayerPedId())
                    for _, obj in ipairs(GetGamePool('CObject')) do
                        if GetEntityModel(obj) == BOTTLE and #(GetEntityCoords(obj) - me) < 6.0 then n = n + 1 end
                    end
                    return n
                end
                if bottlesNear() > 0 then skip('a bottle is already near the player') end

                local most = 0
                for i = 1, 16 do
                    exports.whip_core:PlayEmote(i % 2 == 0 and 'drink' or 'wave')
                    Wait(75)
                    most = math.max(most, bottlesNear())
                end
                exports.whip_core:CancelEmote()
                assertTrue(most <= 2, ('never more than two bottles at once (saw %d)'):format(most))
                assertTrue(waitFor(function() return bottlesNear() == 0 end, 4000),
                    ('every bottle went after /e c (%d left)'):format(bottlesNear()))
                -- A deleted object sent back by its owner turns up a few seconds later.
                Wait(3000)
                assertEqual(bottlesNear(), 0, 'and none came back')
            end,
        },
        {
            name = '/walk saves the walk on the character; /walk c clears it',
            fn = function()
                ExecuteCommand('walk gangster')
                assertTrue(waitFor(function() return meta().walk == 'gangster' end, 3000), 'metadata.walk = gangster')
                ExecuteCommand('walk c')
                assertTrue(waitFor(function() return meta().walk == nil end, 3000), 'metadata.walk cleared')
            end,
        },
        {
            name = "/mood puts the face on the player's statebag (for everyone); /mood c takes it off",
            fn = function()
                ExecuteCommand('mood angry')
                assertTrue(waitFor(function() return LocalPlayer.state.whipMood == 'angry' end, 3000), 'bag whipMood = angry')
                assertTrue(waitFor(function() return meta().mood == 'angry' end, 3000), 'metadata.mood = angry')
                ExecuteCommand('mood c')
                assertTrue(waitFor(function() return LocalPlayer.state.whipMood == nil end, 3000), 'bag cleared')
            end,
        },
    },
})
