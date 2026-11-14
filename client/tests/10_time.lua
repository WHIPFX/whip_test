-- ============================================
-- Client: Time
-- ============================================
--
-- These were three type checks — and IsTimeFrozen is coerced with `and true or false`, so it could
-- not have failed on any clock at all. The client's sky is now a STACK OF LAYERS
-- (client/time.lua): the server's time and weather at the bottom, and anything a zone, a menu or a
-- satellite puts on top of it. The layers are client-only and fully reversible, which is what lets
-- them be tested for real from here.

local BASE = '_test_layer_base'
local TOP  = '_test_layer_top'

RegisterClientTestModule({
    order    = 10,
    category = 'Client: Time',
    teardown = function()
        pcall(exports.whip_core.ClearWeatherLayer, exports.whip_core, TOP)
        pcall(exports.whip_core.ClearWeatherLayer, exports.whip_core, BASE)
    end,
    tests = {
        {
            name = 'GetTime is the time the game is showing',
            fn = function()
                local h, m = exports.whip_core:GetTime()
                assertType(h, 'number', 'hour type')
                assertType(m, 'number', 'minute type')

                -- whip pushes its clock at the engine once a second (NetworkOverrideClockTime), and
                -- the engine keeps running between pushes, so the two can be a minute or so apart —
                -- never more, and never a different hour except across the turn of one.
                --
                -- Assumes the server's first timeSync has arrived, which it has long before the
                -- client phase of a /test run: until then whip does not drive the engine clock.
                local ours  = h * 60 + m
                local games = GetClockHours() * 60 + GetClockMinutes()
                local apart = math.abs(ours - games)
                if apart > 720 then apart = 1440 - apart end   -- across midnight
                assertTrue(apart <= 2, ('whip says %02d:%02d, the game shows %02d:%02d')
                    :format(h, m, GetClockHours(), GetClockMinutes()))
            end,
        },
        {
            name = 'A layer with frozen = false beats a lower one with frozen = true',
            fn = function()
                -- THE BUG THE LAYER REWRITE FIXED. Built as `opts.frozen ~= nil and (...) or nil`,
                -- a layer saying "NOT frozen" fell through to nil — "says nothing" — and the frozen
                -- layer underneath won. Priorities far above anything whip itself uses, so no zone
                -- or menu layer can sit between them.
                assertTrue(exports.whip_core:SetWeatherLayer(BASE, { priority = 900, frozen = true }),
                    'the frozen layer is accepted')
                assertTrue(exports.whip_core:IsTimeFrozen(), 'a frozen layer freezes the clock')
                assertEqual(exports.whip_core:GetWeatherLayers().owners.frozen, BASE, 'and owns the field')

                assertTrue(exports.whip_core:SetWeatherLayer(TOP, { priority = 901, frozen = false }),
                    'the unfreezing layer is accepted')
                assertFalse(exports.whip_core:IsTimeFrozen(), 'the higher layer\'s FALSE wins')
                assertEqual(exports.whip_core:GetWeatherLayers().owners.frozen, TOP, 'the higher layer owns the field')

                assertTrue(exports.whip_core:IsTimeOverridden(), 'layers are active')
            end,
        },
        {
            name = 'A layer\'s weather wins while it is on, and clearing the layers puts the sky back',
            fn = function()
                -- Taken with no test layer on, so it is the weather and freeze state to come back to.
                exports.whip_core:ClearWeatherLayer(TOP)
                exports.whip_core:ClearWeatherLayer(BASE)
                local beforeWeather = exports.whip_core:GetWeather()
                local beforeFrozen  = exports.whip_core:IsTimeFrozen()
                assertType(beforeWeather, 'string', 'weather type')

                local want = (beforeWeather == 'THUNDER') and 'FOGGY' or 'THUNDER'
                exports.whip_core:SetWeatherLayer(TOP, { priority = 901, weather = want:lower() })
                assertEqual(exports.whip_core:GetWeather(), want, 'the layer\'s weather wins (and is upper-cased)')
                assertEqual(exports.whip_core:GetWeatherLayers().owners.weather, TOP, 'and it owns the field')
                assertTrue(exports.whip_core:ClearWeatherLayer(TOP), 'the layer is removed')

                assertEqual(exports.whip_core:GetWeather(), beforeWeather, 'the weather is back')
                assertEqual(exports.whip_core:IsTimeFrozen(), beforeFrozen, 'the freeze state is back')
                for _, l in ipairs(exports.whip_core:GetWeatherLayers().layers) do
                    assertTrue(l.name ~= TOP and l.name ~= BASE, ('no test layer left behind (%s)'):format(l.name))
                end
                assertFalse(exports.whip_core:ClearWeatherLayer(TOP), 'clearing a layer that is not there says so')
            end,
        },
    }
})
