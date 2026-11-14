-- ============================================
-- Client: Voice — whip_voice's megaphone in the player's hand, and the radio's HUD light
-- ============================================
--
-- Runs in the player's own game: it plays the megaphone emote on the player's ped (whip_core's
-- shared/emote_list.lua `megaphone`, which whip_voice's megaphone item plays).

local MEGAPHONE = GetHashKey('prop_megaphone_01')

--- The megaphone in the player's hand, or nil.
local function heldMegaphone()
    for _, obj in ipairs(GetGamePool('CObject')) do
        if GetEntityModel(obj) == MEGAPHONE and IsEntityAttachedToEntity(obj, PlayerPedId()) then return obj end
    end
    return nil
end

RegisterClientTestModule({
    order    = 17,
    category = 'Client: Voice',
    teardown = function()
        pcall(exports.whip_core.CancelEmote, exports.whip_core)
        pcall(exports.whip_core.SetVoiceTalking, exports.whip_core, false)
    end,
    tests = {
        {
            name = 'The megaphone emote holds a networked megaphone up, and goes away cleanly',
            fn = function()
                assertNil(heldMegaphone(), 'no megaphone before')
                local ok, why = exports.whip_core:PlayEmote('megaphone')
                assertTrue(ok, ('PlayEmote answered true (why: %s)'):format(tostring(why)))
                assertEqual(exports.whip_core:IsEmoting(), 'megaphone', 'IsEmoting names it (whip_voice watches this)')
                assertTrue(waitFor(function() return heldMegaphone() ~= nil end, 3000), 'the megaphone is in hand')
                assertTrue(waitFor(function()
                    local m = heldMegaphone()
                    return m ~= nil and NetworkGetEntityIsNetworked(m) and true or false
                end, 2000), 'networked, so others see it')
                assertTrue(exports.whip_core:CancelEmote(), 'CancelEmote answered true')
                assertTrue(waitFor(function() return heldMegaphone() == nil end, 1500), 'the megaphone is gone')
                assertEqual(exports.whip_core:IsEmoting(), false, 'IsEmoting is false')
            end,
        },
        {
            name = 'The voice gauge takes the radio mode (and back)',
            fn = function()
                -- The look is checked by eye; this checks the export takes the mode and does not throw.
                assertTrue(pcall(exports.whip_core.SetVoiceTalking, exports.whip_core, true, 'radio'), 'radio mode taken')
                assertTrue(pcall(exports.whip_core.SetVoiceTalking, exports.whip_core, true), 'back to normal talking')
                assertTrue(pcall(exports.whip_core.SetVoiceTalking, exports.whip_core, false), 'off')
            end,
        },
    },
})
