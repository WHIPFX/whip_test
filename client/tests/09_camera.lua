RegisterClientTestModule({
    order    = 9,
    category = 'Client: Camera',
    teardown = function()
        pcall(exports.whip_core.StopCamera, exports.whip_core)
    end,
    tests = {
        {
            name = 'IsCameraActive returns false initially',
            fn = function()
                assertFalse(exports.whip_core:IsCameraActive(), 'IsCameraActive')
            end,
        },
        {
            name = 'PlayCamera + StopCamera work',
            fn = function()
                local pos = GetEntityCoords(PlayerPedId())
                -- Camera.Play is blocking if it has canLook/exitKey loops
                -- Just test that the export doesn't crash and IsCameraActive works
                -- Use a very short non-blocking call
                CreateThread(function()
                    exports.whip_core:PlayCamera({
                        pos = pos + vector3(0, 0, 5),
                        rot = vector3(-20.0, 0.0, 0.0),
                        fov = 50,
                        exitKey = false,
                    })
                end)
                Wait(200)
                local wasActive = exports.whip_core:IsCameraActive()
                exports.whip_core:StopCamera()
                Wait(200)
                local isNowStopped = not exports.whip_core:IsCameraActive()
                assertTrue(wasActive, 'camera was active')
                assertTrue(isNowStopped, 'camera stopped')
            end,
        },
        {
            -- UI-7: with exitKey on (the default) PlayCamera ran its loop in the caller's thread and
            -- did not return until the camera ended. async hands the loop a thread of its own.
            name = 'PlayCamera({ async = true }) returns at once; StopCamera answers for its own camera',
            fn = function()
                local pos = GetEntityCoords(PlayerPedId())
                local t0 = GetGameTimer()
                local played = exports.whip_core:PlayCamera({
                    pos = pos + vector3(0, 0, 5), rot = vector3(-20.0, 0.0, 0.0), async = true,
                })
                assertTrue(played, 'PlayCamera answered')
                assertTrue(GetGameTimer() - t0 < 500, 'and returned at once, with exitKey on')
                assertTrue(exports.whip_core:IsCameraActive(), 'the camera is up')

                assertTrue(exports.whip_core:StopCamera(), 'StopCamera stops our own camera')
                assertFalse(exports.whip_core:IsCameraActive(), 'the camera is down')
                assertFalse(exports.whip_core:StopCamera(), 'with nothing playing StopCamera is false')
            end,
        },
        {
            name = 'PlayCameraPath({ async = true }) returns at once and ends itself at the end of the path',
            fn = function()
                local pos = GetEntityCoords(PlayerPedId())
                local rot = vector3(-20.0, 0.0, 0.0)
                local t0 = GetGameTimer()
                assertTrue(exports.whip_core:PlayCameraPath({
                    points = { { pos = pos + vector3(0, 0, 5), rot = rot }, { pos = pos + vector3(5, 0, 5), rot = rot } },
                    duration = 600, async = true,
                }), 'PlayCameraPath answered')
                assertTrue(GetGameTimer() - t0 < 300, 'and returned at once')
                assertTrue(exports.whip_core:IsCameraActive(), 'the path is playing')
                assertTrue(waitFor(function() return not exports.whip_core:IsCameraActive() end, 2500),
                    'the path stopped itself at its end')
            end,
        },
        {
            -- The race the async form opened (92fc446): a path's thread stops the camera when the path
            -- ends — it must not stop a camera that REPLACED it meanwhile.
            name = "A path replaced by another camera does not stop the new one at the old path's end",
            fn = function()
                local pos = GetEntityCoords(PlayerPedId())
                local rot = vector3(-20.0, 0.0, 0.0)
                exports.whip_core:PlayCameraPath({
                    points = { { pos = pos + vector3(0, 0, 5), rot = rot }, { pos = pos + vector3(5, 0, 5), rot = rot } },
                    duration = 400, async = true,
                })
                Wait(100)
                exports.whip_core:PlayCamera({ pos = pos + vector3(0, 0, 8), rot = rot, exitKey = false, async = true })
                Wait(700)   -- well past the first path's end
                assertTrue(exports.whip_core:IsCameraActive(), 'the replacing camera is still up')
                exports.whip_core:StopCamera()
            end,
        },
        {
            -- CLI-9: a point without a rot, or duration = 0, threw mid-path with the script camera
            -- already rendering, and a path has no exit key — the player was stuck in it. Both are
            -- refused now, with a reason, before any camera exists.
            name = 'A bad path is refused before any camera goes up',
            fn = function()
                local pos = GetEntityCoords(PlayerPedId())
                local rot = vector3(-20.0, 0.0, 0.0)
                local ok, why = exports.whip_core:PlayCameraPath({
                    points = { { pos = pos + vector3(0, 0, 5), rot = rot }, { pos = pos + vector3(5, 0, 5) } },
                    duration = 600, async = true,
                })
                assertFalse(ok, 'a point with no rot is refused')
                assertNotNil(why, 'with a reason')
                assertFalse(exports.whip_core:IsCameraActive(), 'and no camera went up')

                local zero = exports.whip_core:PlayCameraPath({
                    points = { { pos = pos + vector3(0, 0, 5), rot = rot }, { pos = pos + vector3(5, 0, 5), rot = rot } },
                    duration = 0, async = true,
                })
                assertFalse(zero, 'duration = 0 is refused')
                assertFalse(exports.whip_core:IsCameraActive(), 'and no camera went up')

                assertFalse(exports.whip_core:PlayCamera({ pos = 'here', async = true }), 'a pos that is not a vector3 is refused')
            end,
        },
    }
})
