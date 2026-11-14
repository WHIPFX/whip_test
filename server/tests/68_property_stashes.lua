-- ============================================
-- Property stashes — furniture that holds things
-- ============================================
--
-- WHY THIS MODULE EXISTS
--
-- A piece of furniture in Config.PropertyStashProps is a stash of the property it stands in
-- (whip_core/server/property_stashes.lua): only the owner and keyholders open it. A furniture save
-- writes the room anew, so what can go wrong is expensive: a save that throws a stash's things away,
-- a stash that changes into a new empty one each time the room is saved, or a modified game taking
-- another home's stash. These save rooms the way the furnisher does and look at the stashes after.
--
-- Tester needs whip.devtools and Config.EnableTestSeams, and at least one stash model in
-- Config.PropertyStashProps that the furnisher's catalog offers (skipped without one).

local ITEM = '_test_stashitem'

--- One piece of furniture, `lx` metres along the room from its middle.
local function piece(ctx, model, lx, tag, stash)
    return {
        model = model, x = ctx.place.x + lx, y = ctx.place.y, z = ctx.place.z + 0.5,
        rx = 0.0, ry = 0.0, rz = 0.0, tag = tag,
        extra = stash and { stash = stash } or nil,
    }
end

local function save(ctx, objects)
    return exports.whip_core:__TestFurnitureSave(ctx.id, objects) or { ok = false, err = 'no answer' }
end

local function stashes(ctx) return exports.whip_core:GetPropertyStashes(ctx.id) or {} end

--- The stash the answer gave this tag.
local function stashOf(res, tag)
    for _, pair in ipairs(res.stashes or {}) do
        if pair[1] == tag then return pair[2] end
    end
    return nil
end

local function skipped(ctx)
    if ctx.stash then return false end
    assertTrue(true, 'no stash model in Config.PropertyStashProps that the catalog offers — skipped')
    return true
end

RegisterTestModule({
    order    = 68,
    category = 'Property Stashes',

    setup = function(source, ctx)
        pcall(exports.whip_core.__TestPropertySweep, exports.whip_core)
        local player = exports.whip_core:GetPlayer(source)
        ctx.charId = player.charId
        local info = exports.whip_core:__TestStashSetup() or {}
        ctx.stash, ctx.plain, ctx.limit = info.stash, info.plain, info.limit
        exports.whip_core:RegisterItem(ITEM, {
            name = 'Stash Fixture', desc = 'property stash fixture',
            weight = 0.1, type = 'misc', stack = true, maxStack = 20,
        })

        local pos = GetEntityCoords(GetPlayerPed(source))
        ctx.place = { x = pos.x + 40, y = pos.y - 40, z = pos.z, yaw = 0.0 }
        local fx, err = exports.whip_core:__TestPropertyFixture({
            templateKey = '_test:stashes:' .. tostring(os.time()),
            units = { s = { label = '_test stash unit', base = {
                space = { { type = 'box', center = { x = 0, y = 0, z = 1.5 }, size = { x = 12, y = 6, z = 3 }, heading = 0 } },
            } } },
            properties = { { unitKey = 's', name = '_test Stash Home', place = ctx.place, ownerCharId = ctx.charId } },
        })
        if not fx then error('fixture: ' .. tostring(err)) end
        ctx.templateId, ctx.id = fx.templateId, fx.propertyIds[1]
    end,

    teardown = function(ctx)
        if ctx.templateId then pcall(exports.whip_core.__TestPropertyTeardown, exports.whip_core, ctx.templateId) end
    end,

    tests = {
        {
            name = 'A stash piece placed makes a stash for the property, for its owner and keyholders',
            fn = function(source, ctx)
                if skipped(ctx) then return end
                local res = save(ctx, { piece(ctx, ctx.stash, 0.0, 1) })
                assertTrue(res.ok, 'saved: ' .. tostring(res.err))
                local list = stashes(ctx)
                assertEqual(#list, 1, 'one stash')
                ctx.first = list[1] and list[1].containerId
                assertEqual(stashOf(res, 1), ctx.first, 'the answer names it for the piece')
                local def = exports.whip_core:GetContainerDef(ctx.first)
                assertTrue(def ~= nil and def.propertyId == ctx.id, 'it is the property\'s')
                assertTrue(def and def.requirements and def.requirements.property == ctx.id, 'opened by the property\'s people')
                assertTrue(def and def.prop == false, 'no prop of its own: the furniture is it')
            end,
        },
        {
            name = 'Sent back with its stash, a piece keeps it, and the stash follows it',
            fn = function(source, ctx)
                if skipped(ctx) or not ctx.first then return end
                local res = save(ctx, { piece(ctx, ctx.stash, 2.0, 1, ctx.first) })
                assertTrue(res.ok, 'saved: ' .. tostring(res.err))
                local list = stashes(ctx)
                assertEqual(#list, 1, 'still one stash')
                assertEqual(list[1] and list[1].containerId, ctx.first, 'the same one')
                assertTrue(list[1] and math.abs(list[1].x - (ctx.place.x + 2.0)) < 0.05, 'moved with its furniture')
            end,
        },
        {
            name = 'A plain piece is no stash',
            fn = function(source, ctx)
                if skipped(ctx) or not ctx.first or not ctx.plain then return end
                local res = save(ctx, { piece(ctx, ctx.stash, 2.0, 1, ctx.first), piece(ctx, ctx.plain, -2.0, 2) })
                assertTrue(res.ok, 'saved: ' .. tostring(res.err))
                assertEqual(#stashes(ctx), 1, 'still one stash')
                assertNil(stashOf(res, 2), 'nothing for the plain piece')
            end,
        },
        {
            name = 'A stash id that is not this property\'s, or comes twice, counts as none',
            fn = function(source, ctx)
                if skipped(ctx) or not ctx.first then return end
                if (ctx.limit or 0) < 3 then assertTrue(true, 'the limit is under 3 — skipped') return end
                local res = save(ctx, {
                    piece(ctx, ctx.stash, 2.0, 1, ctx.first),
                    piece(ctx, ctx.stash, 0.0, 2, ctx.first),       -- the same stash again
                    piece(ctx, ctx.stash, -2.0, 3, 999999999),      -- somebody else's, or nobody's
                })
                assertTrue(res.ok, 'saved: ' .. tostring(res.err))
                assertEqual(#stashes(ctx), 3, 'the two others got stashes of their own')
                assertEqual(stashOf(res, 1), ctx.first, 'the first keeps its own')
                local two, three = stashOf(res, 2), stashOf(res, 3)
                assertTrue(two and two ~= ctx.first and three and three ~= ctx.first and two ~= three, 'two new ones')

                -- And taken away again, empty: they go.
                local back = save(ctx, { piece(ctx, ctx.stash, 2.0, 1, ctx.first) })
                assertTrue(back.ok, 'saved: ' .. tostring(back.err))
                assertEqual(#stashes(ctx), 1, 'the empty ones went with their furniture')
                assertNil(exports.whip_core:GetContainerDef(two), 'deleted')
            end,
        },
        {
            name = 'A stash holding something is never thrown away: the save is refused',
            fn = function(source, ctx)
                if skipped(ctx) or not ctx.first then return end
                local slot, err = exports.whip_core:StoreGive({ kind = 'container', id = ctx.first }, ITEM, 2)
                assertOk(slot, err, 'something put in it')
                local version = exports.whip_core:GetPropertyObjectVersion(ctx.id)

                local res = save(ctx, {})
                assertFalse(res.ok, 'refused')
                assertTrue(tostring(res.err):find('Empty', 1, true) ~= nil, 'saying to empty it: ' .. tostring(res.err))
                assertTrue(exports.whip_core:GetContainerDef(ctx.first) ~= nil, 'the stash is still there')
                assertEqual(exports.whip_core:GetPropertyObjectCount(ctx.id), 1, 'and so is its furniture')
                assertEqual(exports.whip_core:GetPropertyObjectVersion(ctx.id), version, 'nothing was written')
                assertEqual(exports.whip_core:StoreCount({ kind = 'container', id = ctx.first }, ITEM), 2, 'with what is in it')
            end,
        },
        {
            name = 'The admin\'s Clear is refused too while a stash holds something',
            fn = function(source, ctx)
                if skipped(ctx) or not ctx.first then return end
                local ok, err = exports.whip_core:__TestFurnitureClear(ctx.id)
                assertFalse(ok, 'refused')
                assertTrue(tostring(err):find('Container Manager', 1, true) ~= nil, 'pointing at the Container Manager: ' .. tostring(err))
                assertTrue(exports.whip_core:GetContainerDef(ctx.first) ~= nil, 'the stash is still there')
                assertEqual(exports.whip_core:GetPropertyObjectCount(ctx.id), 1, 'and its furniture')
            end,
        },
        {
            name = 'Emptied, its furniture can be taken away, and the stash goes with it',
            fn = function(source, ctx)
                if skipped(ctx) or not ctx.first then return end
                local taken, err = exports.whip_core:StoreTake({ kind = 'container', id = ctx.first }, 2, { item = ITEM })
                assertOk(taken, err, 'emptied')
                local res = save(ctx, {})
                assertTrue(res.ok, 'saved: ' .. tostring(res.err))
                assertEqual(#stashes(ctx), 0, 'no stashes')
                assertNil(exports.whip_core:GetContainerDef(ctx.first), 'deleted')
            end,
        },
        {
            name = 'One property has at most Config.PropertyStashLimit stashes',
            fn = function(source, ctx)
                if skipped(ctx) then return end
                local limit = ctx.limit or 0
                if limit > 20 then assertTrue(true, 'the limit is over 20 — skipped') return end
                local objects = {}
                for i = 1, limit + 1 do objects[i] = piece(ctx, ctx.stash, -5.0 + i * 0.4, i) end
                local res = save(ctx, objects)
                assertFalse(res.ok, 'refused')
                assertTrue(tostring(res.err):find(tostring(limit), 1, true) ~= nil, 'naming the limit: ' .. tostring(res.err))
                assertEqual(#stashes(ctx), 0, 'none made')
            end,
        },
        {
            name = 'Deleting the property deletes its stashes',
            fn = function(source, ctx)
                if skipped(ctx) then return end
                if (ctx.limit or 0) < 1 then assertTrue(true, 'the limit is 0 — skipped') return end
                local res = save(ctx, { piece(ctx, ctx.stash, 0.0, 1) })
                assertTrue(res.ok, 'saved: ' .. tostring(res.err))
                local id = stashOf(res, 1)
                assertTrue(id ~= nil, 'a stash')
                local slot, err = exports.whip_core:StoreGive({ kind = 'container', id = id }, ITEM, 1)
                assertOk(slot, err, 'something put in it')
                assertTrue(exports.whip_core:__TestPropertyDelete(ctx.id), 'deleted')
                assertNil(exports.whip_core:GetContainerDef(id), 'the stash went with it')
            end,
        },
    },
})
