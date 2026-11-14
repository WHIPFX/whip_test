-- ============================================
-- Vehicle damage — what a car keeps through the garage
--
-- whip_core/server/vehicle_damage.lua keeps an owned car's engine and body health, its doors torn
-- off and its burst tyres, as five vehicle stats. What can go wrong, and what this checks:
--
--   * A fresh entity is a car like new. Read before its stored damage is back on, it would be saved
--     as new: a free repair on every garage trip. The spawn test checks the stored number survives
--     the spawn and the store.
--   * The game running the car puts the damage back, with the engine never below the floor (a wreck
--     must not spawn on fire). The spawn test reads the car's own health off the server to see it.
--   * A repair must clear the record, or the next spawn puts the damage back.
--
-- The spawn test needs the tester in game: the car is spawned beside them, so their game runs it
-- and does the put-back. Doors cannot be seen from the server, so only health and a rim are checked.
-- ============================================

local PLATE = 'TDMG'

local STATS = { 'engineHealth', 'bodyHealth', 'doorsOff', 'tyresFlat', 'tyresRim' }

--- One stat out of the vehStats JSON on disk, as a number (nil when the key is absent).
local function vehStatOnDisk(vehicleId, name)
    FlushPersistence()
    local rows = DbQuery(
        ("SELECT JSON_UNQUOTE(JSON_EXTRACT(`vehStats`, '$.%s')) AS v FROM `vehicles` WHERE `vehicleId` = ?"):format(name),
        { vehicleId })
    return rows[1] and tonumber(rows[1].v) or nil
end

--- A spot beside the tester with no car on it, near enough for their game to run the car.
local function clearSpotBeside(source)
    local pos = GetEntityCoords(GetPlayerPed(source))
    for _, o in ipairs({ { 6, 0 }, { -6, 0 }, { 0, 6 }, { 0, -6 }, { 9, 9 }, { -9, 9 }, { 9, -9 }, { -9, -9 } }) do
        local at = vector3(pos.x + o[1], pos.y + o[2], pos.z)
        local free = true
        for _, veh in ipairs(GetAllVehicles()) do
            if #(GetEntityCoords(veh) - at) < 4.5 then free = false; break end
        end
        if free then return at end
    end
end

local function clearPlate(plate)
    local car = { plate = plate }
    pcall(exports.whip_core.DespawnVehicle, exports.whip_core, car)
    pcall(exports.whip_core.DeleteVehicle, exports.whip_core, car)
    DbQuery('DELETE FROM `vehicles` WHERE `plate` = ?', { plate })
end

local function near(value, want, label)
    assertNotNil(value, label)
    assertTrue(math.abs(value - want) <= 1.5, ('%s: %s, wanted %s'):format(label, tostring(value), tostring(want)))
end

RegisterTestModule({
    order    = 75,
    category = 'Vehicle Damage',

    setup = function(source, ctx)
        local p = exports.whip_core:GetPlayer(source)
        if not p then skip('no player loaded') end
        clearPlate(PLATE)

        local vehicleId, err = exports.whip_core:CreateOwnedVehicle(source, {
            model = 'asea', plate = PLATE, state = 'garaged',
        })
        if not vehicleId or vehicleId == false then
            skip('could not create the fixture vehicle: ' .. tostring(err))
        end
        ctx.vehicleId = vehicleId
    end,

    teardown = function(ctx)
        if ctx.vehicleId then
            pcall(exports.whip_core.DespawnVehicle, exports.whip_core, ctx.vehicleId)
            pcall(exports.whip_core.DeleteVehicle, exports.whip_core, ctx.vehicleId)
        end
        clearPlate(PLATE)
    end,

    tests = {
        {
            name = 'A new car reads as undamaged, and the damage stats are whip\'s own',
            fn = function(source, ctx)
                assertEqual(exports.whip_core:GetVehicleStat(ctx.vehicleId, 'engineHealth'), 1000, 'engine')
                assertEqual(exports.whip_core:GetVehicleStat(ctx.vehicleId, 'bodyHealth'), 1000, 'body')
                assertEqual(exports.whip_core:GetVehicleStat(ctx.vehicleId, 'doorsOff'), 0, 'doors')
                assertEqual(exports.whip_core:GetVehicleStat(ctx.vehicleId, 'tyresFlat'), 0, 'flat tyres')
                assertEqual(exports.whip_core:GetVehicleStat(ctx.vehicleId, 'tyresRim'), 0, 'tyres on the rim')

                local took = exports.whip_core:RegisterVehicleStat('engineHealth', { default = 0, min = 0, max = 1 })
                assertFalse(took, 'a satellite cannot take engineHealth')
            end,
        },
        {
            name = 'Kept damage is written to the car\'s row',
            fn = function(source, ctx)
                -- A wreck's engine (below the floor), a dented body, a tyre on its rim.
                assertTrue(exports.whip_core:SetVehicleStat(ctx.vehicleId, 'engineHealth', 50), 'engine set')
                assertTrue(exports.whip_core:SetVehicleStat(ctx.vehicleId, 'bodyHealth', 600), 'body set')
                assertTrue(exports.whip_core:SetVehicleStat(ctx.vehicleId, 'tyresRim', 1), 'rim set')
                assertEqual(vehStatOnDisk(ctx.vehicleId, 'engineHealth'), 50, 'engine on disk')
                assertEqual(vehStatOnDisk(ctx.vehicleId, 'bodyHealth'), 600, 'body on disk')
                assertEqual(vehStatOnDisk(ctx.vehicleId, 'tyresRim'), 1, 'rim on disk')
            end,
        },
        {
            name = 'Pulled out, the car wears its damage (engine at the floor) and is not saved as new',
            fn = function(source, ctx)
                local at = clearSpotBeside(source)
                if not at then skip('no clear spot beside the tester') end

                local ok, err = exports.whip_core:RetrieveVehicle(ctx.vehicleId)
                assertTrue(ok, 'RetrieveVehicle: ' .. tostring(err))
                local netId, sErr = exports.whip_core:SpawnVehicle(ctx.vehicleId, at.x, at.y, at.z, 0.0)
                assertOk(netId, sErr, 'SpawnVehicle')
                local entity = NetworkGetEntityFromNetworkId(netId)

                -- The tester's game puts it back, and the server's copy of the car follows by sync.
                -- Config.VehicleDamage.engineFloor as shipped: whip_test cannot read whip_core's Config.
                local floor = 100
                local engine = waitFor(function()
                    local e = GetVehicleEngineHealth(entity)
                    return (e > 0 and e <= floor + 1.5) and e or nil
                end, 15000)
                assertNotNil(engine, ('the engine came down to the floor (%s); it reads %s')
                    :format(tostring(floor), tostring(GetVehicleEngineHealth(entity))))
                near(GetVehicleEngineHealth(entity), floor, 'engine on the car')
                near(GetVehicleBodyHealth(entity), 600, 'body on the car')

                local onRim = false
                for wheel = 0, 15 do
                    if IsVehicleTyreBurst(entity, wheel, true) then onRim = true; break end
                end
                assertTrue(onRim, 'a tyre is on its rim')

                -- Past the settle, a read takes what the car has: the floor, never a new car's 1000.
                Wait(2500)
                assertTrue(exports.whip_core:DespawnVehicle(ctx.vehicleId), 'stored')
                near(exports.whip_core:GetVehicleStat(ctx.vehicleId, 'engineHealth'), floor, 'engine kept')
                near(exports.whip_core:GetVehicleStat(ctx.vehicleId, 'bodyHealth'), 600, 'body kept')
                assertEqual(exports.whip_core:GetVehicleStat(ctx.vehicleId, 'tyresRim'), 1, 'rim kept')
            end,
        },
        {
            name = 'ClearVehicleDamage forgets it all, on disk too',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:SetVehicleStat(ctx.vehicleId, 'doorsOff', 3), 'doors set')
                local ok, err = exports.whip_core:ClearVehicleDamage(ctx.vehicleId)
                assertOk(ok, err, 'ClearVehicleDamage')
                for _, name in ipairs(STATS) do
                    assertNil(vehStatOnDisk(ctx.vehicleId, name), name .. ' off the row')
                end
                assertEqual(exports.whip_core:GetVehicleStat(ctx.vehicleId, 'engineHealth'), 1000, 'engine like new')
                assertEqual(exports.whip_core:GetVehicleStat(ctx.vehicleId, 'doorsOff'), 0, 'no doors off')
            end,
        },
        {
            name = 'ClearVehicleDamage refuses a car that does not exist',
            fn = function()
                local ok, err = exports.whip_core:ClearVehicleDamage(999999999)
                assertFalse(ok, 'refused')
                assertNotNil(err, 'with a reason')
            end,
        },
    },
})
