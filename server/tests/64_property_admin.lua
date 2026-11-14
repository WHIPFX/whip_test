-- ============================================
-- Property admin — the /whip Properties section's writes
-- ============================================
--
-- WHY THIS MODULE EXISTS
--
-- The panel's buttons are the admin-facing way to change a home: its owner, its keys, its name
-- and settings. Each is a SecureEvent that checks what it is given, so these fire the same events
-- from the tester's client that the panel fires, and read back what the server made of them.
-- Tester needs whip.devtools (as /test already does) and Config.EnableTestSeams for the fixture.

local function toWorld(place, lx, ly, lz)
    local t = math.rad(place.yaw)
    local c, s = math.cos(t), math.sin(t)
    return place.x + lx * c - ly * s, place.y + lx * s + ly * c, place.z + lz
end

local function fire(source, eventName, ...)
    -- Each admin event is rate limited (250-1000 ms); space them out.
    Wait(1100)
    return ClientExecWait(source, eventName, 5000, ...)
end

RegisterTestModule({
    order    = 64,
    category = 'Property Admin',

    setup = function(source, ctx)
        -- A run that crashed never reached its teardown; clear what it left first.
        pcall(exports.whip_core.__TestPropertySweep, exports.whip_core)
        local player = exports.whip_core:GetPlayer(source)
        ctx.charId = player.charId
        local pos = GetEntityCoords(GetPlayerPed(source))
        ctx.pos = { x = pos.x, y = pos.y, z = pos.z }
        ctx.place = { x = pos.x - 25, y = pos.y + 20, z = pos.z, yaw = 0.0 }
        -- A second property on the same unit, for "place it for every property on this unit".
        ctx.place2 = { x = pos.x - 25, y = pos.y + 45, z = pos.z, yaw = 0.0 }
        ctx.otherCharId = MySQL.scalar.await(
            'SELECT `charId` FROM `characters` WHERE `charId` <> ? AND `deleted` IS NULL ORDER BY `charId` LIMIT 1', { ctx.charId })

        local fx, err = exports.whip_core:__TestPropertyFixture({
            templateKey = '_test:admin:' .. tostring(os.time()),
            units = { a = { label = '_test admin unit', base = {
                space = { { type = 'box', center = { x = 0, y = 0, z = 1.5 }, size = { x = 6, y = 4, z = 3 }, heading = 0 } },
                doors = { { key = 'front', role = 'entrance', model = GetHashKey('prop_door_01'), pos = { x = 3, y = 0, z = 0 }, heading = 90 } },
            } } },
            properties = {
                { unitKey = 'a', name = '_test Admin Home', place = ctx.place },
                { unitKey = 'a', name = '_test Admin Home Two', place = ctx.place2 },
            },
        })
        if not fx then error('fixture: ' .. tostring(err)) end
        ctx.templateId, ctx.id, ctx.id2 = fx.templateId, fx.propertyIds[1], fx.propertyIds[2]
    end,

    teardown = function(ctx)
        if ctx.templateId then pcall(exports.whip_core.__TestPropertyTeardown, exports.whip_core, ctx.templateId) end
    end,

    tests = {
        {
            name = 'Name, building and settings save through the panel, and the door takes the auto-lock',
            fn = function(source, ctx)
                assertTrue(fire(source, 'whip_core:server:propertyAdminUpdate', ctx.id, {
                    name = '_test Renamed Home', building = '_test Street', label = '',
                    settings = { price = 250000, maxObjects = 40, autolock = true, autolockDelay = 15 },
                }), 'the server answered')
                local p = exports.whip_core:GetProperty(ctx.id)
                assertEqual(p.name, '_test Renamed Home', 'renamed')
                assertEqual(p.building, '_test Street', 'building set')
                assertEqual(p.settings.maxObjects, 40, 'furniture limit')
                assertEqual(p.settings.price, 250000, 'price')
                local door = exports.whip_core:GetDoor(p.doorIds.front)
                assertTrue(door.autolock == true and door.autolockDelay == 15, 'the front door locks itself after 15 s')
            end,
        },
        {
            name = 'Settings outside their limits are refused, and nothing changes',
            fn = function(source, ctx)
                fire(source, 'whip_core:server:propertyAdminUpdate', ctx.id, { settings = { maxObjects = 5000 } })
                assertEqual(exports.whip_core:GetProperty(ctx.id).settings.maxObjects, 40, 'still 40')
            end,
        },
        {
            name = 'An owner must be a real character; setting one writes it onto the door',
            fn = function(source, ctx)
                fire(source, 'whip_core:server:propertyAdminSetOwner', ctx.id, 999999999)
                assertNil(exports.whip_core:GetProperty(ctx.id).ownerCharId, 'no such character, no owner')

                assertTrue(fire(source, 'whip_core:server:propertyAdminSetOwner', ctx.id, ctx.charId), 'answered')
                local p = exports.whip_core:GetProperty(ctx.id)
                assertEqual(p.ownerCharId, ctx.charId, 'owned')
                local ids = exports.whip_core:GetDoor(p.doorIds.front).requirements.charIds
                assertTrue(#ids == 1 and ids[1] == ctx.charId, 'the door lists the owner')
            end,
        },
        {
            name = 'An admin gives and takes a key without standing next to anybody',
            fn = function(source, ctx)
                if not ctx.otherCharId then
                    assertTrue(true, 'no second character — skipped')
                    return
                end
                assertTrue(fire(source, 'whip_core:server:propertyAdminGrantKey', ctx.id, ctx.otherCharId), 'answered')
                assertTrue(exports.whip_core:HasPropertyAccess(ctx.id, { charId = ctx.otherCharId }), 'they have a key')
                assertTrue(fire(source, 'whip_core:server:propertyAdminRevokeKey', ctx.id, ctx.otherCharId), 'answered')
                assertFalse(exports.whip_core:HasPropertyAccess(ctx.id, { charId = ctx.otherCharId }), 'and it is gone')
            end,
        },
        {
            name = 'Making it unowned from the panel locks it to everyone',
            fn = function(source, ctx)
                assertTrue(fire(source, 'whip_core:server:propertyAdminSetOwner', ctx.id, 0), 'answered')
                local p = exports.whip_core:GetProperty(ctx.id)
                assertNil(p.ownerCharId, 'unowned')
                assertEqual(#exports.whip_core:GetDoor(p.doorIds.front).requirements.charIds, 0, 'nobody on the door')
            end,
        },
        {
            name = 'A sign placed for one property lands where it was aimed, and only on that one',
            fn = function(source, ctx)
                -- Between the tester and the property: within reach of both.
                local x, y, z = ctx.pos.x - 12, ctx.pos.y + 10, ctx.pos.z + 1
                assertTrue(fire(source, 'whip_core:server:propertyAdminSetSign', ctx.id, 'sign', 'property', x, y, z, 90.0),
                    'answered')
                local s = exports.whip_core:GetProperty(ctx.id).sign
                assertTrue(s and math.abs(s.x - x) < 0.01 and math.abs(s.y - y) < 0.01 and math.abs(s.z - z) < 0.01,
                    'at the aimed spot')
                assertTrue(math.abs(s.heading - 90.0) < 0.01, 'facing the aimed way')
                assertNil(exports.whip_core:GetProperty(ctx.id2).sign, 'the other property on the unit has none')
            end,
        },
        {
            name = 'A manager placed for the unit reaches every property on it, each at its own placement',
            fn = function(source, ctx)
                local x, y, z = ctx.pos.x - 12, ctx.pos.y + 12, ctx.pos.z + 1.5
                assertTrue(fire(source, 'whip_core:server:propertyAdminSetSign', ctx.id, 'manager', 'unit', x, y, z, 180.0),
                    'answered')
                local m1 = exports.whip_core:GetProperty(ctx.id).manager
                local m2 = exports.whip_core:GetProperty(ctx.id2).manager
                assertTrue(m1 and math.abs(m1.x - x) < 0.01 and math.abs(m1.y - y) < 0.01, 'on the one it was aimed at')
                -- Same local spot, so it sits the placements' difference away on the other.
                local dx, dy = ctx.place2.x - ctx.place.x, ctx.place2.y - ctx.place.y
                assertTrue(m2 and math.abs(m2.x - (x + dx)) < 0.01 and math.abs(m2.y - (y + dy)) < 0.01,
                    'and on the other, at its own placement')
            end,
        },
        {
            name = 'A sign aimed too far from the admin is refused',
            fn = function(source, ctx)
                local before = exports.whip_core:GetProperty(ctx.id).sign
                fire(source, 'whip_core:server:propertyAdminSetSign', ctx.id, 'sign', 'property',
                    ctx.place.x + 90, ctx.place.y, ctx.place.z, 0.0)
                local after = exports.whip_core:GetProperty(ctx.id).sign
                assertTrue(after and math.abs(after.x - before.x) < 0.01, 'it did not move')
            end,
        },
        {
            name = 'Delete from the panel removes it and gives its door back',
            fn = function(source, ctx)
                local doorId = exports.whip_core:GetProperty(ctx.id).doorIds.front
                assertTrue(fire(source, 'whip_core:server:propertyAdminDelete', ctx.id), 'answered')
                assertNil(exports.whip_core:GetProperty(ctx.id), 'gone')
                assertNil(exports.whip_core:GetDoor(doorId), 'with the door it made')
                local x, y, z = toWorld(ctx.place, 0, 0, 1)
                assertNil(exports.whip_core:GetPropertyAt(x, y, z), 'and nothing answers for its space')
            end,
        },
    },
})
