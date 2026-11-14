-- ============================================
-- Property wizard — setting a property up from the /whip panel
-- ============================================
--
-- WHY THIS MODULE EXISTS
--
-- The wizard (whip_core/tools/property_wizard.lua) builds a draft in the world and sends it once,
-- at Save. These send the drafts it sends — a new property, one part changed, a re-bind — from the
-- tester's client, and read back what the server made of them: that a good one is made whole
-- (template, unit, property, doors), and that a bad, distant or duplicate one writes nothing.
--
-- An open-world draft (no interior), next to the tester: the placement is checked against where
-- the tester stands. Tester needs whip.devtools, and Config.EnableTestSeams for the teardown.

local NAME = '_test Wizard Home'

local function toWorld(place, lx, ly, lz)
    local t = math.rad(place.yaw)
    local c, s = math.cos(t), math.sin(t)
    return place.x + lx * c - ly * s, place.y + lx * s + ly * c, place.z + lz
end

--- Save is rate limited to one every 2 s, the part edits to one a second.
local function fire(source, wait, eventName, ...)
    Wait(wait)
    return ClientExecWait(source, eventName, 5000, ...)
end

local function named(name)
    local out = {}
    for _, p in ipairs(exports.whip_core:GetProperties() or {}) do
        if p.name == name then out[#out + 1] = p end
    end
    return out
end

local function box(cx, cy, sx, sy)
    return { type = 'box', center = { x = cx, y = cy, z = 1.5 }, size = { x = sx, y = sy, z = 3 }, heading = 0 }
end

local function draft(ctx, over)
    local d = {
        place = ctx.place,
        space = { box(0, 0, 6, 4) },
        doors = { { key = 'entrance1', role = 'entrance', model = GetHashKey('prop_door_01'),
                    pos = { x = 3, y = 0, z = 0 }, heading = 90 } },
        sign = { pos = { x = 3.4, y = -1.2, z = 1.5 }, heading = 270 },
        manager = { pos = { x = 2.2, y = 0.8, z = 1.5 }, heading = 90 },
        name = NAME, label = 'W1',
        settings = { price = 5000, maxObjects = 20, autolock = false, autolockDelay = 10 },
        ownerCharId = ctx.charId,
    }
    for k, v in pairs(over or {}) do d[k] = v end
    return d
end

RegisterTestModule({
    order    = 65,
    category = 'Property Wizard',

    setup = function(source, ctx)
        pcall(exports.whip_core.__TestPropertySweep, exports.whip_core)
        local player = exports.whip_core:GetPlayer(source)
        ctx.charId = player.charId
        local pos = GetEntityCoords(GetPlayerPed(source))
        ctx.place = { hash = 0, x = pos.x - 30, y = pos.y + 25, z = pos.z, yaw = 0.0 }
    end,

    teardown = function(ctx)
        if ctx.templateId then pcall(exports.whip_core.__TestPropertyTeardown, exports.whip_core, ctx.templateId) end
        pcall(exports.whip_core.__TestPropertySweep, exports.whip_core)
    end,

    tests = {
        {
            name = 'A draft saved from the wizard becomes a whole property: owner, settings, doors and signs',
            fn = function(source, ctx)
                assertTrue(fire(source, 2100, 'whip_core:server:propertyAdminSave', draft(ctx)), 'the server answered')
                local found = named(NAME)
                assertEqual(#found, 1, 'one property by that name')
                local p = exports.whip_core:GetProperty(found[1].id)
                ctx.id, ctx.templateId = p.id, p.templateId
                assertEqual(p.label, 'W1', 'its unit label')
                assertEqual(p.ownerCharId, ctx.charId, 'owned by the tester')
                assertEqual(p.settings.price, 5000, 'price')
                assertEqual(p.settings.maxObjects, 20, 'furniture limit')
                local doorId = p.doorIds and p.doorIds.entrance1
                assertTrue(doorId ~= nil, 'the entrance became a whip door')
                ctx.doorId = doorId
                local ids = exports.whip_core:GetDoor(doorId).requirements.charIds
                assertTrue(#ids == 1 and ids[1] == ctx.charId, 'locked to its owner')
                local sx, sy = toWorld(ctx.place, 3.4, -1.2, 0)
                assertTrue(p.sign and math.abs(p.sign.x - sx) < 0.01 and math.abs(p.sign.y - sy) < 0.01, 'the outside sign where the draft put it')
                assertTrue(p.manager ~= nil, 'and the manager')
                local x, y, z = toWorld(ctx.place, 0, 0, 1)
                local at = exports.whip_core:GetPropertyAt(x, y, z)
                assertTrue(at and at.id == p.id, 'its space answers for the middle of the box')
            end,
        },
        {
            name = 'The same space saved again is refused: it is that property already',
            fn = function(source, ctx)
                fire(source, 2100, 'whip_core:server:propertyAdminSave', draft(ctx))
                assertEqual(#named(NAME), 1, 'still only one')
            end,
        },
        {
            name = 'A draft whose placement is far from the admin is refused',
            fn = function(source, ctx)
                local far = { hash = 0, x = ctx.place.x + 400, y = ctx.place.y, z = ctx.place.z, yaw = 0 }
                fire(source, 2100, 'whip_core:server:propertyAdminSave', draft(ctx, { place = far, name = '_test Wizard Far' }))
                assertEqual(#named('_test Wizard Far'), 0, 'nothing made')
            end,
        },
        {
            name = 'A draft the checker refuses writes nothing (a door with no model)',
            fn = function(source, ctx)
                local place = { hash = 0, x = ctx.place.x, y = ctx.place.y + 20, z = ctx.place.z, yaw = 0 }
                fire(source, 2100, 'whip_core:server:propertyAdminSave', draft(ctx, {
                    place = place, name = '_test Wizard Broken',
                    doors = { { key = 'entrance1', role = 'entrance', pos = { x = 3, y = 0, z = 0 }, heading = 90 } },
                }))
                assertEqual(#named('_test Wizard Broken'), 0, 'nothing made')
            end,
        },
        {
            name = 'A draft with no space is refused',
            fn = function(source, ctx)
                local place = { hash = 0, x = ctx.place.x, y = ctx.place.y + 20, z = ctx.place.z, yaw = 0 }
                fire(source, 2100, 'whip_core:server:propertyAdminSave', draft(ctx, {
                    place = place, name = '_test Wizard Empty', space = {},
                }))
                assertEqual(#named('_test Wizard Empty'), 0, 'nothing made')
            end,
        },
        {
            name = 'Editing its space from the wizard: the new box answers, for this property',
            fn = function(source, ctx)
                if not ctx.id then assertTrue(false, 'the first test made no property') return end
                assertTrue(fire(source, 1100, 'whip_core:server:propertyAdminSavePart', ctx.id, 'space', 'property',
                    { box(2, 0, 10, 4) }), 'answered')
                local x, y, z = toWorld(ctx.place, 6, 0, 1)   -- inside the new box, outside the old
                local at = exports.whip_core:GetPropertyAt(x, y, z)
                assertTrue(at and at.id == ctx.id, 'the grown space holds the new point')
            end,
        },
        {
            name = 'Editing its doors: taking the entrance off gives its door back',
            fn = function(source, ctx)
                if not ctx.id then assertTrue(false, 'the first test made no property') return end
                assertTrue(fire(source, 1100, 'whip_core:server:propertyAdminSavePart', ctx.id, 'doors', 'property', {}),
                    'answered')
                local p = exports.whip_core:GetProperty(ctx.id)
                assertTrue(not (p.doorIds and p.doorIds.entrance1), 'no entrance any more')
                assertNil(exports.whip_core:GetDoor(ctx.doorId), 'and the door it made is gone')
            end,
        },
        {
            name = 'A part edit the checker refuses changes nothing',
            fn = function(source, ctx)
                if not ctx.id then assertTrue(false, 'the first test made no property') return end
                fire(source, 1100, 'whip_core:server:propertyAdminSavePart', ctx.id, 'space', 'property',
                    { { type = 'box', center = { x = 0, y = 0, z = 1 }, size = { x = 0, y = 4, z = 3 } } })
                local x, y, z = toWorld(ctx.place, 6, 0, 1)
                local at = exports.whip_core:GetPropertyAt(x, y, z)
                assertTrue(at and at.id == ctx.id, 'still the grown space')
            end,
        },
        {
            name = 'Re-bind is refused for an open-world property, and it stays put',
            fn = function(source, ctx)
                if not ctx.id then assertTrue(false, 'the first test made no property') return end
                local moved = { hash = 0, x = ctx.place.x + 5, y = ctx.place.y, z = ctx.place.z, yaw = 0 }
                fire(source, 1100, 'whip_core:server:propertyAdminRebind', ctx.id, moved)
                local p = exports.whip_core:GetProperty(ctx.id)
                assertTrue(math.abs(p.place.x - ctx.place.x) < 0.01, 'the placement did not move')
            end,
        },
    },
})
