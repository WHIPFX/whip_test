-- ============================================
-- Client: Vehicles
-- ============================================
--
-- These used to assert only that each export answered with the right TYPE — a table, a boolean —
-- which HasVehicleKey(999999) and friends do whatever is in the key cache. Each now asserts the
-- answer the question actually has.
--
-- No vehicle is spawned. A local car would enter whip's own caches (the entity→vehicleId memo in
-- client/vehicles.lua caches "has none" by entity handle) and outlive the test in ways a teardown
-- cannot see, so GetNearbyVehicles is checked against the game's own vehicle pool instead — the
-- same frame, the same maths, whatever happens to be parked nearby.

RegisterClientTestModule({
    order    = 6,
    category = 'Client: Vehicles',
    tests = {
        {
            name = 'GetNearbyVehicles lists exactly the pool\'s vehicles in range, nearest first',
            fn = function()
                local radius = 100.0
                local nearby = exports.whip_core:GetNearbyVehicles(radius)
                assertType(nearby, 'table', 'GetNearbyVehicles type')

                -- The independent count, taken in the same frame: nothing yields between the
                -- export returning and this loop, so nothing can have moved.
                local myPos = GetEntityCoords(PlayerPedId())
                local expected = 0
                for _, veh in ipairs(GetGamePool('CVehicle')) do
                    if #(myPos - GetEntityCoords(veh)) <= radius then expected = expected + 1 end
                end
                assertEqual(#nearby, expected, 'every vehicle in range, and nothing else')

                for i, v in ipairs(nearby) do
                    assertTrue(v.distance <= radius, ('entry %d is within the radius'):format(i))
                    if i > 1 then
                        assertTrue(nearby[i - 1].distance <= v.distance, ('entry %d is not nearer than entry %d'):format(i, i - 1))
                    end
                end
            end,
        },
        {
            name = 'GetNearbyVehicles caps the radius at 100m',
            fn = function()
                -- A caller asking for the whole map gets 100m, by design (the pool walk is per
                -- call). Anything further out must not appear.
                for i, v in ipairs(exports.whip_core:GetNearbyVehicles(5000.0)) do
                    assertTrue(v.distance <= 100.0, ('entry %d is inside the 100m cap'):format(i))
                end
                -- And the cap is a cap, not a different list: the same set as asking for 100.
                assertEqual(#exports.whip_core:GetNearbyVehicles(5000.0), #exports.whip_core:GetNearbyVehicles(100.0),
                    'asking beyond the cap answers the same as asking for the cap')
            end,
        },
        {
            name = 'HasVehicleKey is false for a vehicle nobody holds a key to',
            fn = function()
                assertFalse(exports.whip_core:HasVehicleKey(999999), 'no key for a vehicle id that does not exist')
                assertFalse(exports.whip_core:HasVehicleKey(nil), 'nor for nil')
            end,
        },
        {
            -- VEH-15. The client's lookup by what you hold took only 'entity' (GetVehicleBy then; one
            -- GetVehicle(ref) on both sides since 14 Nov 2026).
            name = 'GetVehicle takes { plate } and { netId } on the client too, and answers nil for nonsense',
            fn = function()
                assertNil(exports.whip_core:GetVehicle({ plate = '_NOPLT_' }), 'an unknown plate is nil')
                assertNil(exports.whip_core:GetVehicle({ netId = 0 }), 'netId 0 is nil')
                assertNil(exports.whip_core:GetVehicle({ bogus = 1 }), 'an unknown kind is nil')

                -- A whip car that happens to be near, if there is one; no car is spawned for this.
                local near
                for _, v in ipairs(exports.whip_core:GetNearbyVehicles(100.0)) do
                    if v.vehicleId then near = v break end
                end
                if not near then skip('no whip vehicle near you to look up') end

                local byPlate = exports.whip_core:GetVehicle({ plate = near.plate })
                assertEqual(byPlate and byPlate.vehicleId, near.vehicleId, 'found by its plate')
                local byNet = exports.whip_core:GetVehicle({ netId = NetworkGetNetworkIdFromEntity(near.entity) })
                assertEqual(byNet and byNet.vehicleId, near.vehicleId, 'and by its netId')
            end,
        },
        {
            -- VEH-1. The client stat and data reads took only an entity; a reference says what it is.
            name = 'Client vehicle exports take a vehicle REFERENCE — { id } reads the same car as its entity',
            fn = function()
                assertNil(exports.whip_core:GetVehicle({ plate = '_NOPLT_' }), 'a plate on no car is nil')
                assertNil(exports.whip_core:GetVehicleEntity({ id = 999999 }), 'an id with no car here is nil')

                local near
                for _, v in ipairs(exports.whip_core:GetNearbyVehicles(100.0)) do
                    if v.vehicleId then near = v break end
                end
                if not near then skip('no whip vehicle near you to look up') end

                assertEqual(exports.whip_core:GetVehicleEntity({ id = near.vehicleId }), near.entity,
                    'GetVehicleEntity({ id }) finds its entity')
                assertEqual((exports.whip_core:GetVehicle({ entity = near.entity }) or {}).vehicleId, near.vehicleId,
                    'GetVehicle({ entity }) finds its id')
                assertEqual(exports.whip_core:GetVehicleStat({ id = near.vehicleId }, 'engine'),
                    exports.whip_core:GetVehicleStat({ entity = near.entity }, 'engine'),
                    'GetVehicleStat by { id } reads the same as by { entity }')

                -- VEH-12: ONE RULE for a bare number — a vehicleId, here as on the server. It was an
                -- entity for the stat, data and properties calls and a vehicleId for GetVehicle.
                assertEqual(exports.whip_core:GetVehicleStat(near.vehicleId, 'engine'),
                    exports.whip_core:GetVehicleStat({ entity = near.entity }, 'engine'),
                    'a bare number to GetVehicleStat is the vehicleId')
                assertEqual(exports.whip_core:GetVehicleEntity(near.vehicleId), near.entity,
                    'and to GetVehicleEntity')
                assertEqual(type(exports.whip_core:GetVehicleData(near.vehicleId)),
                    type(exports.whip_core:GetVehicleData({ entity = near.entity })),
                    'and to GetVehicleData')
            end,
        },
        {
            -- VEH-13. No car is needed to check the id a list registration hands back.
            name = 'WatchVehicleStat takes a LIST, and its one id drives interval and unwatch for all of it',
            fn = function()
                local id = exports.whip_core:WatchVehicleStat({ '_test_w1', '_test_w2' }, {
                    onGained = function(entity, name, value) end,
                    id       = 'veh13',
                })
                assertType(id, 'string', 'a list registration returns one id')

                assertTrue(exports.whip_core:SetVehicleStatWatchInterval(id, 250),
                    'the interval applies to the whole list')
                assertFalse(exports.whip_core:SetVehicleStatWatchInterval(id, 250),
                    'and setting the same interval again changes nothing')

                assertTrue(exports.whip_core:UnwatchVehicleStat(id), 'unwatching the list works')
                assertFalse(exports.whip_core:UnwatchVehicleStat(id), 'and it is gone afterwards')
            end,
        },
        {
            -- WatchVehicleData (29 Sep 2026, for whip_autos' tuning). No car is needed for the contract.
            name = 'WatchVehicleData answers an id, refuses nonsense with a reason, and unwatches once',
            fn = function()
                -- false, not nil: an export's answer is cut at its first nil, and the reason with it.
                local none, why = exports.whip_core:WatchVehicleData('_test_wd', {})
                assertFalse(none, 'no callbacks, no watcher')
                assertType(why, 'string', 'and it says why')
                assertFalse((exports.whip_core:WatchVehicleData('', { onGained = function() end })), 'an empty key is refused')

                local id = exports.whip_core:WatchVehicleData('_test_wd', {
                    onGained = function(entity, value, vehicleId) end,
                    onStop   = function(entity, value, vehicleId) end,
                    driverOnly = true,
                })
                assertType(id, 'string', 'a watcher id comes back')
                assertTrue(exports.whip_core:UnwatchVehicleData(id), 'unwatching works')
                assertFalse(exports.whip_core:UnwatchVehicleData(id), 'and it is gone afterwards')
            end,
        },
        {
            -- The handling owner (29 Sep 2026). The contract only: no car's handling is touched.
            name = 'SetVehicleHandlingLayer refuses a car that is not there, and a layer never set clears nothing',
            fn = function()
                local ok, why = exports.whip_core:SetVehicleHandlingLayer({ entity = 0 }, '_test', { set = { fMass = 1000 } })
                assertFalse(ok, 'no car, no layer')
                assertType(why, 'string', 'and it says why')
                assertFalse(exports.whip_core:ClearVehicleHandlingLayer('_test_never_set'), 'clearing a layer never set removes nothing')
                assertNil(exports.whip_core:GetVehicleHandlingBase({ entity = 0 }, 'fMass'), 'no car, no base value')
            end,
        },
        {
            -- A layer's `add` (10 Oct 2026, whip_power's top speed): an amount on top of the sets, counted
            -- in the base, taken off again when cleared. On the car you drive: the gearing moves by 10 for
            -- a moment and goes back.
            name = 'SetVehicleHandlingLayer adds an amount on top, refuses a wild one, and takes it off again',
            fn = function()
                local ped = PlayerPedId()
                local veh = GetVehiclePedIsIn(ped, false)
                if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then skip('sit in a driver seat to check it') end
                local F = 'fInitialDriveMaxFlatVel'
                local ok, why = exports.whip_core:SetVehicleHandlingLayer({ entity = veh }, '_test', { add = { [F] = 5000 } })
                assertFalse(ok, 'an amount past 1000 is refused')
                assertType(why, 'string', 'and it says why')

                local before = GetVehicleHandlingFloat(veh, 'CHandlingData', F)
                local base = exports.whip_core:GetVehicleHandlingBase({ entity = veh }, F)
                assertTrue(exports.whip_core:SetVehicleHandlingLayer({ entity = veh }, '_test', { add = { [F] = 10 } }), 'the layer goes on')
                local added = exports.whip_core:GetVehicleHandlingBase({ entity = veh }, F)
                assertTrue(math.abs(added - (base + 10)) < 0.01, ('the base counts it (%.2f, wanted %.2f)'):format(added, base + 10))
                assertTrue(GetVehicleHandlingFloat(veh, 'CHandlingData', F) > before + 5, 'the car has it')
                assertTrue(exports.whip_core:ClearVehicleHandlingLayer('_test'), 'cleared')
                local after = GetVehicleHandlingFloat(veh, 'CHandlingData', F)
                assertTrue(math.abs(after - before) < 0.01, ('and it is back as it was (%.2f, was %.2f)'):format(after, before))
            end,
        },
        {
            -- TakeVehicleControl (1 Oct 2026). No car is spawned: the second half uses the car you drive.
            name = 'TakeVehicleControl refuses a car that is not there, and answers true for the car you drive',
            fn = function()
                local ok, why = exports.whip_core:TakeVehicleControl({ entity = 0 })
                assertFalse(ok, 'no car, no control')
                assertEqual(why, 'no such vehicle', 'and it says why')
                assertFalse(exports.whip_core:TakeVehicleControl(999999), 'nor for a vehicleId with no car here')

                local ped = PlayerPedId()
                local veh = GetVehiclePedIsIn(ped, false)
                if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then skip('sit in a driver seat to check the rest') end
                assertTrue(exports.whip_core:TakeVehicleControl({ entity = veh }), 'the driver controls their own car')
            end,
        },
        {
            name = 'HasVehicleKey({ plate }) is false for a plate nobody holds a key to',
            fn = function()
                assertFalse(exports.whip_core:HasVehicleKey({ plate = '_TST_NO_' }), 'no key for an unknown plate')
                assertFalse(exports.whip_core:HasVehicleKey({ plate = '' }), 'an empty plate matches nothing')
                assertFalse(exports.whip_core:HasVehicleKey({ plate = 12345 }), 'nor does a plate that is not text')
            end,
        },
    }
})
