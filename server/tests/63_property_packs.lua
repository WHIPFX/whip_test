-- ============================================
-- Property packs — an MLO that registers itself
-- ============================================
--
-- WHY THIS MODULE EXISTS
--
-- A pack is written by an MLO's author and applied to a server people live on. Every rule in
-- server/property_packs.lua's header is a promise to one of the two: the author's mistake is
-- refused with where it is; the players' owners, keys and names are never overwritten by an
-- update; a home an admin deleted does not come back; one the author dropped is not deleted under
-- someone. These tests hold the server to each of those, through the same export a resource uses.
--
-- The pack is registered from this resource, so it belongs to whip_test. It needs
-- Config.EnableTestSeams for the teardown.

local PACK_ID = '_test.pack'
local DOOR = 'prop_door_01'

local function toWorld(place, lx, ly, lz)
    local t = math.rad(place.yaw)
    local c, s = math.cos(t), math.sin(t)
    return place.x + lx * c - ly * s, place.y + lx * s + ly * c, place.z + lz
end

local UNIT = {
    key = 'flat', label = 'Flat',
    space = { { type = 'box', center = { x = 0, y = 0, z = 1.5 }, size = { x = 6, y = 4, z = 3 } } },
    visit = { x = 0, y = 0, z = 0.2 },
    doors = { { key = 'front', role = 'entrance', model = DOOR, pos = { x = 3, y = 0, z = 0 }, heading = 90 } },
    sign  = { pos = { x = 3.2, y = 0.8, z = 1.6 }, heading = 90 },
}

--- The pack, at a version, with these properties.
local function pack(version, props)
    return {
        format = 1, id = PACK_ID, version = version, label = '_test pack',
        templates = { { key = 'house', archetype = 0, label = '_test house', units = { UNIT } } },
        properties = props,
    }
end

local function prop(key, name, place)
    return { key = key, template = 'house', unit = 'flat', name = name, building = '_test',
             placement = { pos = { x = place.x, y = place.y, z = place.z }, heading = place.yaw } }
end

--- The property a pack key names, through the space it stands in (the export has no by-key read).
local function byPlace(place)
    local x, y, z = toWorld(place, 0, 0, 1)
    return exports.whip_core:GetPropertyAt(x, y, z)
end

RegisterTestModule({
    order    = 63,
    category = 'Property Packs',

    setup = function(source, ctx)
        -- What a crashed run left behind goes first (see the sandbox test's note).
        pcall(exports.whip_core.__TestPropertySweep, exports.whip_core)
        pcall(exports.whip_core.__TestPackRemove, exports.whip_core, PACK_ID)
        local player = exports.whip_core:GetPlayer(source)
        ctx.charId = player.charId
        local pos = GetEntityCoords(GetPlayerPed(source))
        ctx.p1 = { x = pos.x + 20, y = pos.y + 50, z = pos.z, yaw = 15.0 }
        ctx.p2 = { x = pos.x + 20, y = pos.y + 65, z = pos.z, yaw = 0.0 }
        ctx.p3 = { x = pos.x + 20, y = pos.y + 80, z = pos.z, yaw = 90.0 }
    end,

    teardown = function(ctx)
        pcall(exports.whip_core.__TestPackRemove, exports.whip_core, PACK_ID)
        if ctx.adminTemplate then pcall(exports.whip_core.__TestPropertyTeardown, exports.whip_core, ctx.adminTemplate) end
    end,

    tests = {
        {
            name = 'A pack with a mistake is refused, and says exactly where the mistake is',
            fn = function(source, ctx)
                local bad = pack('1', {})
                bad.templates[1].units = { {
                    key = 'flat', space = UNIT.space,
                    doors = { { key = 'front', role = 'entrance', pos = { x = 3, y = 0, z = 0 } } },
                } }
                local ok, why = exports.whip_core:RegisterPropertyPack(bad)
                assertFalse(ok, 'refused')
                assertEqual(why, 'templates[1].units[1].doors[1].model: a door needs a model (a name or a hash)', 'the path to it')
                assertNil(byPlace(ctx.p1), 'and nothing was made')
            end,
        },
        {
            name = 'A good pack makes its homes, and the same pack again writes nothing',
            fn = function(source, ctx)
                local ok, how = exports.whip_core:RegisterPropertyPack(pack('1', {
                    prop('one', '_test One', ctx.p1), prop('two', '_test Two', ctx.p2),
                }))
                assertTrue(ok, 'applied: ' .. tostring(how))
                assertEqual(how, 'applied', 'how')
                local one = byPlace(ctx.p1)
                assertTrue(one ~= nil and one.name == '_test One', 'property one stands where the pack put it')
                ctx.idOne, ctx.idTwo = one and one.id, byPlace(ctx.p2) and byPlace(ctx.p2).id
                assertEqual(one.propertyKey, PACK_ID .. ':one', 'with the pack\'s key')
                assertNotNil(one.doorIds and one.doorIds.front, 'and its front door')

                local again, how2 = exports.whip_core:RegisterPropertyPack(pack('1', {
                    prop('one', '_test One', ctx.p1), prop('two', '_test Two', ctx.p2),
                }))
                assertTrue(again, 'accepted again')
                assertEqual(how2, 'unchanged', 'and it wrote nothing')
            end,
        },
        {
            name = 'An update leaves the owner and an admin\'s rename alone, and moves what nobody touched',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:SetPropertyOwner(ctx.idOne, { charId = ctx.charId }), 'one has an owner')
                assertTrue(exports.whip_core:__TestPropertyUpdate(ctx.idOne, { name = '_test Renamed by an admin' }), 'renamed')

                local ok, how = exports.whip_core:RegisterPropertyPack(pack('2', {
                    prop('one', '_test One v2', ctx.p1), prop('two', '_test Two v2', ctx.p2),
                }))
                assertTrue(ok and how == 'applied', 'v2 applied: ' .. tostring(how))

                local one = exports.whip_core:GetProperty(ctx.idOne)
                assertEqual(one.name, '_test Renamed by an admin', 'the admin\'s name stays')
                assertEqual(one.ownerCharId, ctx.charId, 'the owner stays')
                assertEqual(exports.whip_core:GetProperty(ctx.idTwo).name, '_test Two v2', 'the untouched name follows the pack')
            end,
        },
        {
            name = 'A home the pack stops listing is flagged for an admin, not deleted',
            fn = function(source, ctx)
                local ok = exports.whip_core:RegisterPropertyPack(pack('3', { prop('one', '_test One v2', ctx.p1) }))
                assertTrue(ok, 'v3 applied')
                local two = exports.whip_core:GetProperty(ctx.idTwo)
                assertNotNil(two, 'two still exists')
                assertTrue(type(two.packIssue) == 'string' and two.packIssue:sub(1, 8) == 'orphaned', 'and is flagged orphaned')
            end,
        },
        {
            name = 'A home an admin deletes is never made again by its pack',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:__TestPropertyDelete(ctx.idTwo), 'two deleted')
                local ok = exports.whip_core:RegisterPropertyPack(pack('4', {
                    prop('one', '_test One v2', ctx.p1), prop('two', '_test Two v2', ctx.p2),
                }))
                assertTrue(ok, 'v4 (listing two again) applied')
                assertNil(byPlace(ctx.p2), 'two did not come back')
            end,
        },
        {
            name = 'A pack home landing on an admin\'s home takes it over, owner and all',
            fn = function(source, ctx)
                local fx, err = exports.whip_core:__TestPropertyFixture({
                    templateKey = '_test:packclaim:' .. tostring(os.time()),
                    units = { flat = { label = 'admin flat', base = {
                        space = { { type = 'box', center = { x = 0, y = 0, z = 1.5 }, size = { x = 6, y = 4, z = 3 }, heading = 0 } },
                        doors = { { key = 'front', role = 'entrance', model = GetHashKey(DOOR), pos = { x = 3, y = 0, z = 0 }, heading = 90 } },
                    } } },
                    properties = { { unitKey = 'flat', name = '_test Admin home', place = ctx.p3 } },
                })
                assertTrue(fx ~= false and fx ~= nil, 'the admin home: ' .. tostring(err))
                ctx.adminTemplate = fx.templateId
                local adminId = fx.propertyIds[1]
                assertTrue(exports.whip_core:SetPropertyOwner(adminId, { charId = ctx.charId }), 'it has an owner')

                local ok, how = exports.whip_core:RegisterPropertyPack(pack('5', {
                    prop('one', '_test One v2', ctx.p1), prop('three', '_test Three', ctx.p3),
                }))
                assertTrue(ok, 'v5 applied: ' .. tostring(how))
                local three = exports.whip_core:GetProperty(adminId)
                assertNotNil(three, 'the same property, by its old id')
                assertEqual(three.propertyKey, PACK_ID .. ':three', 'now the pack\'s')
                assertEqual(three.ownerCharId, ctx.charId, 'with its owner')
            end,
        },
        {
            -- THE TEST THAT HUNG THE SERVER ON 24 SEP 2026. It ran `while true do end` in a sandbox
            -- whose limit was a debug hook this server's Lua did not honour, and nothing stopped it.
            -- A pack file is PARSED when it is plain data and REFUSED UNREAD when it is code, on every
            -- server (Josh, 26 Sep 2026: code packs are gone). Nothing here is ever run.
            name = 'A pack file with code is refused unread; plain data is read, never run',
            fn = function(source, ctx)
                local ok, why = exports.whip_core:__TestPackSource('while true do end')
                assertFalse(ok, 'the loop did not run to the end of time')
                assertTrue(type(why) == 'string' and why:find('uses code', 1, true) ~= nil, 'refused unread: ' .. tostring(why))

                local okData, data = exports.whip_core:__TestPackSource(
                    'return { floors = { vec3(1, 2, 3), vec3(-4, 5, 6.5) }, name = [[Mega]], on = true }')
                assertTrue(okData and data.floors[2].x == -4 and data.floors[2].z == 6.5 and data.name == 'Mega' and data.on == true,
                    'plain data is read')

                assertFalse(exports.whip_core:__TestPackSource('os.exit() return {}'), 'os is not there')
                assertFalse(exports.whip_core:__TestPackSource('return { f = print }'), 'a function is not data')

                local ok4 = exports.whip_core:__TestPackSource(
                    'local t = {} for i = 1, 36 do t[i] = vec3(i, 0, 0) end return { floors = t }')
                assertFalse(ok4, 'even an ordinary loop is code, and refused')
            end,
        },
    },
})
