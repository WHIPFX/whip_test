-- ============================================
-- Property themes — a home's look, from the resource that built its interior
-- ============================================
--
-- WHY THIS MODULE EXISTS
--
-- A resource that declares `whip_interior_themes` in its manifest gives its homes looks, and whip
-- matches each to a property by the interior and origin it was set up on (whip_core/server/
-- property_themes.lua). What can go wrong: the wrong home repainted, a look that is not one of its
-- own accepted, or the choice lost when the resource or whip restarts. whip_test declares the line
-- itself and stands in for such a resource with the exports below, with one home next to the tester.
--
-- Tester needs whip.devtools and Config.EnableTestSeams.

local HASH = 434343           -- a made-up archetype, as module 67's
local THEMES = {
    { id = 0, name = 'Plain', walls = '#b2a899', trim = '#c4c1b4', floor = '#997852' },
    { id = 2, name = 'Navy', walls = '#2a364a', trim = '#e6e3db', floor = '#a0815e' },
    { id = 5, name = 'Slate', walls = '#48525a', trim = '#e6e3db', floor = '#b0936e' },
}
local HOMES = {}              -- what GetHomes answers: empty but for this module's run
local pushed = nil            -- the last SetAllThemes table
local calls = {}              -- every SetHomeTheme { key, id }
local refuse = false

-- THE STAND-IN: the four exports a theme resource has (docs.html, "Interior themes").
exports('GetThemes', function() return THEMES end)
exports('GetHomes', function() return HOMES end)
exports('SetAllThemes', function(map) pushed = map; return true end)
exports('SetHomeTheme', function(key, id)
    calls[#calls + 1] = { key, id }
    if refuse then return false, 'refused for the test' end
    return true
end)

local function rescan() return exports.whip_core:__TestThemesRescan(GetCurrentResourceName()) end

local function home(ctx, dx, archetype, design)
    return { key = '_test_home', archetype = archetype or HASH, designArchetype = design,
             position = vector3(ctx.place.x + (dx or 0.0), ctx.place.y, ctx.place.z) }
end

RegisterTestModule({
    order    = 69,
    category = 'Property Themes',

    setup = function(source, ctx)
        pcall(exports.whip_core.__TestPropertySweep, exports.whip_core)
        local player = exports.whip_core:GetPlayer(source)
        ctx.charId = player.charId
        local pos = GetEntityCoords(GetPlayerPed(source))
        ctx.place = { hash = HASH, x = pos.x - 40, y = pos.y + 40, z = pos.z, yaw = 0.0 }
        local fx, err = exports.whip_core:__TestPropertyFixture({
            templateKey = '_test:themes:' .. tostring(os.time()),
            archetypeHash = HASH,
            units = { t = { label = '_test theme unit', base = {
                space = { { type = 'box', center = { x = 0, y = 0, z = 1.5 }, size = { x = 6, y = 6, z = 3 }, heading = 0 } },
            } } },
            properties = { { unitKey = 't', name = '_test Theme Home', place = ctx.place, ownerCharId = ctx.charId } },
        })
        if not fx then error('fixture: ' .. tostring(err)) end
        ctx.templateId, ctx.id = fx.templateId, fx.propertyIds[1]
        HOMES = { home(ctx, 0.5) }
        pushed, calls, refuse = nil, {}, false
        if not rescan() then error('whip_core did not take whip_test as a theme resource') end
    end,

    teardown = function(ctx)
        HOMES = {}
        refuse = false
        pcall(rescan)
        if ctx.templateId then pcall(exports.whip_core.__TestPropertyTeardown, exports.whip_core, ctx.templateId) end
    end,

    tests = {
        {
            name = 'A home within 2 m on the same interior is the property: its looks are offered',
            fn = function(source, ctx)
                local t = exports.whip_core:GetPropertyThemes(ctx.id)
                assertTrue(t ~= nil, 'it has looks')
                assertEqual(t and #t.themes, 3, 'all three')
                assertEqual(t and t.current, 0, 'its first, until one is picked')
                assertEqual(type(pushed), 'table', 'the whole table was sent when it was read')
            end,
        },
        {
            name = 'Picking one saves it and tells the resource which home',
            fn = function(source, ctx)
                local ok, err = exports.whip_core:SetPropertyTheme(ctx.id, 2)
                assertOk(ok, err, 'SetPropertyTheme')
                local last = calls[#calls]
                assertEqual(last and last[1], '_test_home', 'its home')
                assertEqual(last and last[2], 2, 'that look')
                assertEqual(exports.whip_core:GetPropertyThemes(ctx.id).current, 2, 'in force')
                local rows = DbQuery('SELECT `theme` FROM `properties` WHERE `propertyId` = ?', { ctx.id })
                assertEqual(rows[1] and tonumber(rows[1].theme), 2, 'and on its row')
            end,
        },
        {
            name = 'A look that is not one of its own is refused',
            fn = function(source, ctx)
                local n = #calls
                local ok, err = exports.whip_core:SetPropertyTheme(ctx.id, 3)
                assertFalse(ok, 'refused')
                assertTrue(tostring(err):find('not one of', 1, true) ~= nil, tostring(err))
                assertEqual(#calls, n, 'the resource was not asked')
            end,
        },
        {
            name = 'The resource starting again is sent every saved look',
            fn = function(source, ctx)
                pushed = nil
                assertTrue(rescan(), 'read again')
                assertEqual(pushed and pushed._test_home, 2, 'its home\'s look came with it')
            end,
        },
        {
            name = 'A home 3 m away, or of another interior, is not the property',
            fn = function(source, ctx)
                HOMES = { home(ctx, 3.0) }
                rescan()
                assertNil(exports.whip_core:GetPropertyThemes(ctx.id), 'not 3 m away')
                HOMES = { home(ctx, 0.5, HASH + 1) }
                rescan()
                assertNil(exports.whip_core:GetPropertyThemes(ctx.id), 'not another interior')
            end,
        },
        {
            name = 'A home whose interior was replaced still matches by its old one (designArchetype)',
            fn = function(source, ctx)
                HOMES = { home(ctx, 0.5, HASH + 1, HASH) }
                rescan()
                local t = exports.whip_core:GetPropertyThemes(ctx.id)
                assertTrue(t ~= nil, 'matched')
                assertEqual(t and t.current, 2, 'with its look kept')
            end,
        },
        {
            name = 'A resource that refuses the change says so',
            fn = function(source, ctx)
                HOMES = { home(ctx, 0.5) }
                rescan()
                refuse = true
                local ok, err = exports.whip_core:SetPropertyTheme(ctx.id, 5)
                refuse = false
                assertFalse(ok, 'not ok')
                assertTrue(tostring(err):find('did not change', 1, true) ~= nil, tostring(err))
            end,
        },
        {
            name = 'A sale keeps the look',
            fn = function(source, ctx)
                assertOk(exports.whip_core:SetPropertyTheme(ctx.id, 2), nil, 'set')
                assertTrue(exports.whip_core:SetPropertyOwner(ctx.id, nil), 'made unowned')
                assertEqual(exports.whip_core:GetPropertyThemes(ctx.id).current, 2, 'still its look')
            end,
        },
        {
            name = 'Gone from the resource, it has no looks; back, it has them again',
            fn = function(source, ctx)
                HOMES = {}
                rescan()
                assertNil(exports.whip_core:GetPropertyThemes(ctx.id), 'none')
                HOMES = { home(ctx, 0.5) }
                rescan()
                assertEqual(exports.whip_core:GetPropertyThemes(ctx.id).current, 2, 'back, as it was')
            end,
        },
    },
})
