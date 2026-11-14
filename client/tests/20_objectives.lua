-- ============================================
-- Client: Objectives — a resource's own objective card (ShowObjective / HideObjective)
-- ============================================
--
-- Checks the answers from a satellite's side: a card goes up and comes down, again with the same id changes it, and
-- what is not a card is refused with a reason. A card shows at the top right for a moment while this runs.

local ID = 'whip_test_card'

local function call(name, ...)
    local ok, a, b = pcall(exports.whip_core[name], exports.whip_core, ...)
    if not ok then return 'threw: ' .. tostring(a) end
    return a, b
end

RegisterClientTestModule({
    order    = 20,
    category = 'Client: Objectives',
    teardown = function()
        call('HideObjective', ID)
    end,
    tests = {
        {
            name = 'A card goes up, changes, and comes down',
            fn = function()
                assertEqual(call('ShowObjective', ID, 'whip_test: a card', { icon = 'target' }), true,
                    'ShowObjective answered true')
                Wait(300)
                assertEqual(call('ShowObjective', ID, 'whip_test: the same card, changed', { icon = 'pin', film = true }),
                    true, 'again with the same id answered true')
                Wait(300)
                assertEqual(call('HideObjective', ID), true, 'HideObjective answered true')
            end,
        },
        {
            name = 'A name whip has no glyph for still puts the card up (with the flag)',
            fn = function()
                assertEqual(call('ShowObjective', ID, 'whip_test: no such glyph', { icon = 'whip_test_no_glyph' }), true,
                    'answered true')
                call('HideObjective', ID)
            end,
        },
        {
            name = 'What is not a card is refused, with why',
            fn = function()
                local ok, why = call('ShowObjective', ID, '   ')
                assertEqual(ok, false, 'an empty text is refused')
                assertNotNil(why, 'and says why')
                ok, why = call('ShowObjective', '', 'whip_test')
                assertEqual(ok, false, 'an empty id is refused')
                assertNotNil(why, 'and says why')
                ok, why = call('ShowObjective', ID, 'whip_test', { countdown = -5 })
                assertEqual(ok, false, 'a clock below 0 is refused')
                assertNotNil(why, 'and says why')
            end,
        },
        {
            name = 'Taking down a card never put up answers true',
            fn = function()
                assertEqual(call('HideObjective', 'whip_test_never_shown'), true, 'answered true')
            end,
        },
    },
})
