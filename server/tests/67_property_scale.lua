-- ============================================
-- Property scale — Register here, Verify, Export pack
-- ============================================
--
-- WHY THIS MODULE EXISTS
--
-- The tools for two hundred flats (whip_core/server/property_admin.lua, "Scale"). An interior set
-- up once is a template, and these drive what the panel sends for every other copy of it:
--
--   Register here   a template's units at a placement become properties, named, and a second
--                   registration of the same placement makes nothing
--   Verify          what an admin's Verify tour reports lands as the property's status, and a
--                   change to the property afterwards makes it unverified again
--   Export pack     a template written out as a pack reads back through the pack reader and the
--                   checker a server uses
--
-- The interior is a made-up archetype hash next to the tester: the server takes the placement on
-- the admin's word (it reads no interior natives), so this is exactly what a real one sends.
-- Tester needs whip.devtools and Config.EnableTestSeams.

local HASH = 424242

local function named(prefix)
    local out = {}
    for _, p in ipairs(exports.whip_core:GetProperties() or {}) do
        if tostring(p.name or ''):sub(1, #prefix) == prefix then out[#out + 1] = p end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

local function fire(source, wait, eventName, ...)
    Wait(wait)
    return ClientExecWait(source, eventName, 5000, ...)
end

local function box(cx)
    return { { type = 'box', center = { x = cx, y = 0, z = 1.5 }, size = { x = 4, y = 4, z = 3 }, heading = 0 } }
end

RegisterTestModule({
    order    = 67,
    category = 'Property Scale',

    setup = function(source, ctx)
        pcall(exports.whip_core.__TestPropertySweep, exports.whip_core)
        local pos = GetEntityCoords(GetPlayerPed(source))
        ctx.place = { hash = HASH, x = pos.x + 30, y = pos.y + 30, z = pos.z, yaw = 0.0 }
        local fx, err = exports.whip_core:__TestPropertyFixture({
            templateKey = '_test:scale:' .. tostring(os.time()),
            label = '_test scale interior',
            archetypeHash = HASH,
            units = {
                a = { label = 'A', base = { space = box(-3) } },
                b = { label = 'B', base = { space = box(3) } },
            },
            properties = {},
        })
        if not fx then error('fixture: ' .. tostring(err)) end
        ctx.templateId = fx.templateId
    end,

    teardown = function(ctx)
        if ctx.templateId then pcall(exports.whip_core.__TestPropertyTeardown, exports.whip_core, ctx.templateId) end
    end,

    tests = {
        {
            name = 'Register here makes the template\'s units into named properties at the placement',
            fn = function(source, ctx)
                assertTrue(fire(source, 1100, 'whip_core:server:propertyAdminRegister', {
                    place = ctx.place, templateId = ctx.templateId, building = '_test Tower',
                    units = { { key = 'a', name = '_test Scale 801', label = '801' },
                              { key = 'b', name = '_test Scale 802', label = '802' } },
                }), 'answered')
                local made = named('_test Scale ')
                assertEqual(#made, 2, 'two properties')
                assertEqual(made[1].building, '_test Tower', 'with the building')
                assertEqual(made[2].label, '802', 'and their labels')
                ctx.ids = { made[1].id, made[2].id }
            end,
        },
        {
            name = 'Registering the same placement again makes nothing',
            fn = function(source, ctx)
                fire(source, 1100, 'whip_core:server:propertyAdminRegister', {
                    place = ctx.place, templateId = ctx.templateId,
                    units = { { key = 'a', name = '_test Scale again' } },
                })
                assertEqual(#named('_test Scale '), 2, 'still two')
            end,
        },
        {
            name = 'A placement of a different interior is refused for this template',
            fn = function(source, ctx)
                local other = { hash = HASH + 1, x = ctx.place.x, y = ctx.place.y + 20, z = ctx.place.z, yaw = 0 }
                fire(source, 1100, 'whip_core:server:propertyAdminRegister', {
                    place = other, templateId = ctx.templateId, units = { { key = 'a', name = '_test Scale wrong' } },
                })
                assertEqual(#named('_test Scale wrong'), 0, 'nothing made')
            end,
        },
        {
            name = 'A clean Verify marks it checked; a problem marks it for attention',
            fn = function(source, ctx)
                if not ctx.ids then assertTrue(false, 'Register made nothing') return end
                assertTrue(fire(source, 300, 'whip_core:server:propertyAdminVerified', ctx.ids[1], { problems = {} }), 'answered')
                assertEqual(exports.whip_core:GetProperty(ctx.ids[1]).status, 'ok', 'checked')
                assertTrue(fire(source, 300, 'whip_core:server:propertyAdminVerified', ctx.ids[2],
                    { problems = { 'door "entrance1" is not where it should be' } }), 'answered')
                local p = exports.whip_core:GetProperty(ctx.ids[2])
                assertEqual(p.status, 'attention', 'needs attention')
                assertTrue(tostring(p.statusReason):find('entrance1', 1, true) ~= nil, 'and says why')
            end,
        },
        {
            name = 'Moving a verified property makes it unverified again',
            fn = function(source, ctx)
                if not ctx.ids then assertTrue(false, 'Register made nothing') return end
                local moved = { hash = HASH, x = ctx.place.x, y = ctx.place.y, z = ctx.place.z + 0.5, yaw = 0 }
                assertTrue(exports.whip_core:__TestPropertyUpdate(ctx.ids[1], { place = moved }), 'moved')
                assertEqual(exports.whip_core:GetProperty(ctx.ids[1]).status, 'unverified', 'unverified')
            end,
        },
        {
            name = 'Export writes a pack that the pack reader and the checker accept, with its placements',
            fn = function(source, ctx)
                local res, err = exports.whip_core:__TestPropertyExport(ctx.templateId, { placements = true, id = '_test.export' })
                assertTrue(res ~= false and res ~= nil, 'exported: ' .. tostring(err))
                assertEqual(res.units, 2, 'both units')
                assertEqual(res.properties, 2, 'both placements')
                local ok, data = exports.whip_core:__TestPackSource(res.text)
                assertTrue(ok, 'reads back: ' .. tostring(data))
                assertEqual(#data.templates[1].units, 2, 'two units in the file')
                assertEqual(#data.properties, 2, 'two properties in the file')
                assertEqual(data.templates[1].archetype, HASH, 'the interior by its hash')
            end,
        },
    },
})
