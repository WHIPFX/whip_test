-- ============================================
-- Time & Weather (server)
--
-- THE CLOCK IS DERIVED, NOT STORED (whip_core/server/time.lua): anchor + elapsed x timeScale.
-- So "SetFrozen freezes time" is not proven by IsTimeFrozen() returning true — that only reads
-- the flag back. These tests WATCH THE CLOCK: frozen, it must stand still; running at a raised
-- scale, it must move.
--
-- Every setter also writes the one `whip_world` row, and that row is what a restart comes back
-- to, so the durable half is asserted against the database rather than read back from memory.
--
-- These change the real world clock and weather for everyone on the server while they run;
-- teardown puts back what setup found.
-- ============================================

--- The game time as minutes since midnight.
local function nowMinutes()
    local h, m = exports.whip_core:GetTime()
    return h * 60 + m
end

RegisterTestModule({
    order    = 12,
    category = 'Time & Weather',
    setup = function(source, ctx)
        local h, m = exports.whip_core:GetTime()
        ctx.origHour    = h
        ctx.origMinute  = m
        ctx.origWeather = exports.whip_core:GetWeather()
        ctx.origFrozen  = exports.whip_core:IsTimeFrozen()
        ctx.origScale   = exports.whip_core:GetTimeScale()
    end,
    teardown = function(ctx, source)
        -- Guarded: teardown runs after a failed setup too, and SetTime(nil) throws.
        if ctx.origScale ~= nil then exports.whip_core:SetTimeScale(ctx.origScale) end
        if ctx.origHour ~= nil then exports.whip_core:SetTime(ctx.origHour, ctx.origMinute) end
        if ctx.origWeather ~= nil then exports.whip_core:SetWeather(ctx.origWeather) end
        if ctx.origFrozen ~= nil then exports.whip_core:SetFrozen(ctx.origFrozen) end

        -- The layer is per-player state on the TESTER, and a failed test used to leave them
        -- stuck at 22:00 in the rain for the rest of the session.
        if source then pcall(exports.whip_core.ClearPlayerWeatherLayer, exports.whip_core, source, 'whip_test') end
    end,
    tests = {
        {
            -- Frozen first, so the clock cannot tick between SetTime and the read — SetTime awaits
            -- its database write, and at a raised scale a minute can pass inside that await.
            name = 'SetTime sets the clock exactly, and the world row records it',
            fn = function()
                exports.whip_core:SetFrozen(true)
                exports.whip_core:SetTime(14, 30)
                local h, m = exports.whip_core:GetTime()
                assertEqual(h, 14, 'hour after set')
                assertEqual(m, 30, 'minute after set')

                -- What a restart resumes from. Frozen, so the saved minute is exactly the one set.
                assertDbScalar('SELECT `gameMinutes` FROM `whip_world` WHERE `id` = 1', {},
                    14 * 60 + 30, 'whip_world.gameMinutes')

                -- Out-of-range input wraps rather than erroring.
                exports.whip_core:SetTime(25, 61)
                h, m = exports.whip_core:GetTime()
                assertEqual(h, 1, '25 wraps to 1')
                assertEqual(m, 1, '61 wraps to 1')
            end,
        },
        {
            name = 'A frozen clock stands still, even at the fastest time scale',
            fn = function()
                exports.whip_core:SetFrozen(true)
                exports.whip_core:SetTimeScale(10)
                exports.whip_core:SetTime(8, 0)
                assertTrue(exports.whip_core:IsTimeFrozen(), 'the flag reads frozen')

                -- At scale 10 a real second and a half is seven game minutes. A deliberate wait:
                -- the thing under test is that time passing does NOT move the clock.
                Wait(1500)
                assertEqual(nowMinutes(), 8 * 60, 'the clock did not move while frozen')
            end,
        },
        {
            name = 'An unfrozen clock runs at its time scale, from where it was frozen',
            fn = function()
                exports.whip_core:SetFrozen(true)
                exports.whip_core:SetTimeScale(10)
                exports.whip_core:SetTime(8, 0)

                exports.whip_core:SetFrozen(false)
                assertFalse(exports.whip_core:IsTimeFrozen(), 'the flag reads running')

                -- Resumes from 08:00 — unfreezing must not credit the clock with the time it stood
                -- still — and moves: at scale 10, about five game minutes a real second.
                local moved = waitFor(function() return nowMinutes() > 8 * 60 end, 4000)
                assertTrue(moved == true, 'the clock started running')
                local m = nowMinutes() - 8 * 60
                assertTrue(m >= 1 and m < 60,
                    ('it resumed from 08:00 rather than jumping (%d minutes on)'):format(m))

                exports.whip_core:SetFrozen(true)
            end,
        },
        {
            name = 'SetTimeScale changes the scale and clamps it to 0..10',
            fn = function()
                exports.whip_core:SetTimeScale(2.0)
                assertEqual(exports.whip_core:GetTimeScale(), 2.0, 'timeScale')

                exports.whip_core:SetTimeScale(50)
                assertEqual(exports.whip_core:GetTimeScale(), 10, 'capped at 10')

                exports.whip_core:SetTimeScale(-3)
                assertEqual(exports.whip_core:GetTimeScale(), 0, 'floored at 0')

                exports.whip_core:SetTimeScale(1.0)
                assertDbScalar('SELECT `timeScale` FROM `whip_world` WHERE `id` = 1', {}, 1.0,
                    'whip_world.timeScale')
            end,
        },
        {
            -- WAS SetWeather('CLEAR') — the configured start weather, and almost always the weather
            -- already in effect, so it passed whether or not SetWeather did anything. The return
            -- value was ignored under a comment saying it "may return true or nil"; it returns true,
            -- or false and a reason.
            name = 'SetWeather changes the weather, and the world row records it',
            fn = function()
                local current = exports.whip_core:GetWeather()
                local target  = (current == 'RAIN') and 'CLOUDS' or 'RAIN'

                assertTrue(exports.whip_core:SetWeather(target), 'SetWeather accepted ' .. target)
                assertEqual(exports.whip_core:GetWeather(), target, 'weather after set')
                assertDbScalar('SELECT `weather` FROM `whip_world` WHERE `id` = 1', {}, target,
                    'whip_world.weather')

                -- Lower case is the same weather.
                assertTrue(exports.whip_core:SetWeather('clear'), 'lower case accepted')
                assertEqual(exports.whip_core:GetWeather(), 'CLEAR', 'normalised to upper case')
            end,
        },
        {
            name = 'SetWeather refuses a weather that does not exist, and changes nothing',
            fn = function()
                local before = exports.whip_core:GetWeather()
                local ok, why = exports.whip_core:SetWeather('NOT_A_WEATHER')
                assertFalse(ok, 'refused')
                assertEqual(why, 'Invalid weather type', 'with the reason')
                assertEqual(exports.whip_core:GetWeather(), before, 'the weather is unchanged')
            end,
        },
        {
            -- A layer's booleans must survive the copy: `and x or nil` would drop frozen = false as if
            -- absent (time.lua, cleanLayer).
            name = 'SetPlayerWeatherLayer stores exactly what it was given, false included',
            fn = function(source)
                assertTrue(exports.whip_core:SetPlayerWeatherLayer(source, 'whip_test', {
                    hour = 22, minute = 15, weather = 'rain', frozen = false, blackout = true,
                }), 'layer accepted')

                local layer = (exports.whip_core:GetPlayerWeatherLayers(source) or {})['whip_test']
                assertNotNil(layer, 'GetPlayerWeatherLayers has it')
                assertEqual(layer.hour, 22, 'hour')
                assertEqual(layer.minute, 15, 'minute')
                assertEqual(layer.weather, 'RAIN', 'weather, upper-cased')
                assertEqual(layer.frozen, false, 'frozen = false survives the copy')
                assertEqual(layer.blackout, true, 'blackout is copied')
            end,
        },
        {
            name = 'ClearPlayerWeatherLayer removes the layer',
            fn = function(source)
                -- Set here as well, so this does not pass merely because the test above failed
                -- before it set anything.
                exports.whip_core:SetPlayerWeatherLayer(source, 'whip_test', { hour = 3 })
                assertNotNil((exports.whip_core:GetPlayerWeatherLayers(source) or {})['whip_test'], 'a layer to clear')

                exports.whip_core:ClearPlayerWeatherLayer(source, 'whip_test')
                assertNil((exports.whip_core:GetPlayerWeatherLayers(source) or {})['whip_test'], 'nothing is left behind')
            end,
        },
    }
})
