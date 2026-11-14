-- ============================================
-- Property garage — a private garage for the owner and keyholders
-- ============================================
--
-- WHY THIS MODULE EXISTS
--
-- A unit with bays gives each of its properties a garage of its own, 'property:<id>', that only
-- the owner and keyholders may use (whip_core/server/garages.lua, "Private garages"). What can go
-- wrong is expensive: a stranger using somebody's garage, or a car left behind in a garage its
-- owner can no longer open. These build a property with two bays next to the tester, put the
-- tester's car in its garage, and change who may use it.
--
-- Tester needs whip.devtools and Config.EnableTestSeams, and a second character on the database
-- for the key tests (skipped without one).

local function toWorld(place, lx, ly, lz)
    local t = math.rad(place.yaw)
    local c, s = math.cos(t), math.sin(t)
    return place.x + lx * c - ly * s, place.y + lx * s + ly * c, place.z + lz
end

local function bayCount(key)
    local n = 0
    for _, s in ipairs(exports.whip_core:GetGarageSpots() or {}) do
        if s.garageKey == key then n = n + 1 end
    end
    return n
end

RegisterTestModule({
    order    = 66,
    category = 'Property Garage',

    setup = function(source, ctx)
        pcall(exports.whip_core.__TestPropertySweep, exports.whip_core)
        local player = exports.whip_core:GetPlayer(source)
        ctx.charId = player.charId
        local pos = GetEntityCoords(GetPlayerPed(source))
        ctx.place = { x = pos.x - 30, y = pos.y - 25, z = pos.z, yaw = 0.0 }
        ctx.otherCharId = MySQL.scalar.await(
            'SELECT `charId` FROM `characters` WHERE `charId` <> ? AND `deleted` IS NULL ORDER BY `charId` LIMIT 1', { ctx.charId })

        local fx, err = exports.whip_core:__TestPropertyFixture({
            templateKey = '_test:garage:' .. tostring(os.time()),
            units = { g = { label = '_test garage unit', base = {
                space = { { type = 'box', center = { x = 0, y = 0, z = 1.5 }, size = { x = 6, y = 4, z = 3 }, heading = 0 } },
                garage = { bays = {
                    { pos = { x = 0, y = -6, z = 0 }, heading = 90 },
                    { pos = { x = 4, y = -6, z = 0 }, heading = 90 },
                } },
            } } },
            properties = { { unitKey = 'g', name = '_test Garage Home', place = ctx.place, ownerCharId = ctx.charId } },
        })
        if not fx then error('fixture: ' .. tostring(err)) end
        ctx.templateId, ctx.id = fx.templateId, fx.propertyIds[1]
        ctx.key = 'property:' .. tostring(ctx.id)
    end,

    teardown = function(ctx, source)
        if ctx.vehicleId then
            if source then
                for _ = 1, 5 do
                    if not exports.whip_core:RemoveVehicleKey(source, ctx.vehicleId) then break end
                end
            end
            pcall(exports.whip_core.DeleteVehicle, exports.whip_core, ctx.vehicleId)
        end
        if ctx.templateId then pcall(exports.whip_core.__TestPropertyTeardown, exports.whip_core, ctx.templateId) end
    end,

    tests = {
        {
            name = 'A unit with bays gives its property a private garage, with those bays',
            fn = function(source, ctx)
                local g = exports.whip_core:GetGarage(ctx.key)
                assertTrue(g ~= nil, 'the garage exists')
                assertTrue(g.private == true, 'and is private')
                assertEqual(bayCount(ctx.key), 2, 'two bays')
                assertEqual(exports.whip_core:GetProperty(ctx.id).garageKey, ctx.key, 'the property names it')
            end,
        },
        {
            name = 'Its owner may use it; somebody else may not',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:CanUseGarage(ctx.key, { charId = ctx.charId }), 'the owner')
                if ctx.otherCharId then
                    assertFalse(exports.whip_core:CanUseGarage(ctx.key, { charId = ctx.otherCharId }), 'a stranger')
                end
            end,
        },
        {
            name = 'A key opens the garage too, and taking it back closes it',
            fn = function(source, ctx)
                if not ctx.otherCharId then assertTrue(true, 'no second character — skipped') return end
                assertTrue(exports.whip_core:GivePropertyKey(ctx.id, { charId = ctx.otherCharId }), 'key given')
                assertTrue(exports.whip_core:CanUseGarage(ctx.key, { charId = ctx.otherCharId }), 'the keyholder may')
                assertTrue(exports.whip_core:RemovePropertyKey(ctx.id, { charId = ctx.otherCharId }), 'key taken')
                assertFalse(exports.whip_core:CanUseGarage(ctx.key, { charId = ctx.otherCharId }), 'and now may not')
            end,
        },
        {
            name = 'GetNearestGarage never answers a private garage, even standing in its bay',
            fn = function(source, ctx)
                local x, y, z = toWorld(ctx.place, 0, -6, 0)
                local near = exports.whip_core:GetNearestGarage(x, y, z)
                assertTrue(near ~= ctx.key, 'not the private one')
            end,
        },
        {
            name = 'A car in it follows its owner out when the owner loses the property',
            fn = function(source, ctx)
                local vehicleId, err = exports.whip_core:CreateOwnedVehicle(source, {
                    model = 'asea', plate = ('WG%06d'):format(os.time() % 1000000), state = 'garaged',
                })
                assertOk(vehicleId, err, 'CreateOwnedVehicle')
                ctx.vehicleId = vehicleId
                assertTrue(exports.whip_core:SetVehicleGarage(vehicleId, ctx.key), 'parked in the property garage')
                assertEqual(exports.whip_core:GetVehicle(vehicleId).garage, ctx.key, 'it is there')

                assertTrue(exports.whip_core:SetPropertyOwner(ctx.id, nil), 'made unowned')
                local after = exports.whip_core:GetVehicle(vehicleId).garage
                assertTrue(after ~= nil and after ~= ctx.key, 'moved out, to ' .. tostring(after))
                local dest = after and exports.whip_core:GetGarage(after)
                assertTrue(dest ~= nil and not dest.private, 'into a public garage')
            end,
        },
        {
            name = 'Taking its bays away removes the garage, and the car in it goes to a public one first',
            fn = function(source, ctx)
                if not ctx.vehicleId then assertTrue(false, 'the car test made no car') return end
                assertTrue(exports.whip_core:SetPropertyOwner(ctx.id, { charId = ctx.charId }), 'owned again')
                assertTrue(exports.whip_core:SetVehicleGarage(ctx.vehicleId, ctx.key), 'parked in it again')

                assertTrue(exports.whip_core:__TestPropertyUpdate(ctx.id, { overrides = { garage = false } }), 'no garage for it')
                assertNil(exports.whip_core:GetGarage(ctx.key), 'the garage is gone')
                assertEqual(bayCount(ctx.key), 0, 'with its bays')
                local after = exports.whip_core:GetVehicle(ctx.vehicleId).garage
                assertTrue(after ~= nil and after ~= ctx.key, 'the car went to ' .. tostring(after))
            end,
        },
        {
            name = 'Giving it bays again brings the garage back',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:__TestPropertyUpdate(ctx.id, { overrides = false }), 'override removed')
                assertTrue(exports.whip_core:GetGarage(ctx.key) ~= nil, 'the garage is back')
                assertEqual(bayCount(ctx.key), 2, 'with both bays')
            end,
        },
        {
            name = 'Deleting the property removes its garage',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:__TestPropertyDelete(ctx.id), 'deleted')
                assertNil(exports.whip_core:GetGarage(ctx.key), 'no garage')
                assertEqual(bayCount(ctx.key), 0, 'no bays')
            end,
        },
    },
})
