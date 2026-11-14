-- ============================================
-- Client: Clean Screen — another resource's hold on whip's clean screen (HoldCleanScreen / ReleaseCleanScreen)
-- ============================================
--
-- Checks from a satellite's side: a hold puts the screen clean and its release brings it back, two holds need two
-- releases, and letting go of a hold never taken changes nothing. The screen's on and off are heard through the
-- local event 'whip_core:ui:cleanScreen'. If something else already holds it (the Camera Creator's play mode), no
-- event comes and only the answers are checked. The screen is clean for a moment while this runs.

local A, B = 'whip_test_a', 'whip_test_b'

local heard = {}   -- the on / off values the event carried, in order
AddEventHandler('whip_core:ui:cleanScreen', function(payload)
    if type(payload) == 'table' then heard[#heard + 1] = payload.on == true end
end)

local function call(name, id)
    local ok, res = pcall(exports.whip_core[name], exports.whip_core, id)
    if not ok then return 'threw: ' .. tostring(res) end
    return res
end

RegisterClientTestModule({
    order    = 19,
    category = 'Client: Clean Screen',
    teardown = function()
        call('ReleaseCleanScreen', A)
        call('ReleaseCleanScreen', B)
    end,
    tests = {
        {
            name = 'A hold puts the screen clean, and its release brings it back',
            fn = function()
                heard = {}
                assertEqual(call('HoldCleanScreen', A), true, 'HoldCleanScreen answered true')
                Wait(100)
                local wentOn = heard[1] == true
                assertEqual(call('ReleaseCleanScreen', A), true, 'ReleaseCleanScreen answered true')
                Wait(100)
                if wentOn then
                    assertEqual(heard[#heard], false, 'the screen came back when the hold went')
                else
                    print('[whip_test] clean screen already held by something else: only the answers were checked')
                end
            end,
        },
        {
            name = 'Two holds need two releases',
            fn = function()
                heard = {}
                call('HoldCleanScreen', A)
                call('HoldCleanScreen', B)
                Wait(100)
                local wentOn = heard[1] == true
                call('ReleaseCleanScreen', A)
                Wait(100)
                if wentOn then
                    assertEqual(heard[#heard], true, 'still clean while the second hold stands')
                end
                call('ReleaseCleanScreen', B)
                Wait(100)
                if wentOn then
                    assertEqual(heard[#heard], false, 'back once both holds went')
                end
            end,
        },
        {
            name = 'Letting go of a hold never taken changes nothing',
            fn = function()
                heard = {}
                assertEqual(call('ReleaseCleanScreen', 'whip_test_never_held'), true, 'answered true')
                Wait(100)
                assertEqual(#heard, 0, 'no change was heard')
            end,
        },
    },
})
