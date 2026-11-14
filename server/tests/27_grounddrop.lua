-- ============================================
-- CreateGroundItem — both call shapes
--
-- WHY THIS MODULE EXISTS
--
-- This one signature has been called wrongly by TWO independent authors, both passing a
-- vector where the metadata argument goes:
--
--   shops.lua        a purchase that overflowed the buyer's inventory destroyed the item
--                    after payment had been taken
--   whip_gunny       an ejected magazine is destroyed instead of dropped
--
-- Both failed the same way: x/y/z are NOT NULL, so the INSERT threw, a pcall swallowed it,
-- and the caller discarded the return. Nothing anywhere said an item had just ceased to
-- exist.
--
-- When two separate developers make the identical mistake against one signature, the
-- signature is the defect — so both shapes are now accepted. These tests pin that, and pin
-- the refusal path, so a future tidy-up cannot quietly restore silent destruction.
-- ============================================

local ITEM = '_test_grounddrop'

--- Ground rows for our fixture item, read straight from the database.
local function droppedRows()
    return DbQuery(
        'SELECT `id`, `x`, `y`, `z`, `metadata` FROM `ground_items` WHERE `item` = ?', { ITEM })
end

--- Remove every fixture row — THROUGH whip_core, so the cache and the grid go with it.
---
--- This used to be a bare SQL DELETE, which emptied the half of a ground item nothing reads. The
--- cache and the spatial grid kept every row, so each one went on rendering at the tester's feet
--- and could still be PICKED UP — GroundItems.delete answers yes for a cached row whether or not
--- the database still has it, so every pickup handed over an item that no longer existed
--- anywhere. The suite was minting fixture items into the world on every run.
---
--- Three passes, because there are three places a row can be:
---   1. rows on disk: deleted through the export (row, cache, grid, clients),
---   2. cache-only ghosts an OLDER run's SQL cleanup left behind near the tester: found through the
---      same cache the pickup reads, and deleted through the export,
---   3. disk rows the cache never knew (the export refuses an id it cannot find): SQL, which is
---      now safe because there is no cache entry to strand.
---@param ctx table|nil  for the tester's position; the ghost sweep is skipped without it
local function clearDropped(ctx)
    for _, row in ipairs(droppedRows()) do
        pcall(exports.whip_core.DeleteGroundItem, exports.whip_core, row.id)
    end
    if ctx and ctx.x then
        local ok, nearby = pcall(exports.whip_core.GetGroundItemsNearby, exports.whip_core,
            ctx.x, ctx.y, ctx.z, 50.0)
        for _, row in ipairs(ok and nearby or {}) do
            if row.item == ITEM then
                pcall(exports.whip_core.DeleteGroundItem, exports.whip_core, row.id)
            end
        end
    end
    pcall(MySQL.query.await, 'DELETE FROM `ground_items` WHERE `item` = ?', { ITEM })
end

RegisterTestModule({
    order    = 27,
    category = 'Ground Drop',

    setup = function(source, ctx)
        exports.whip_core:RegisterItem(ITEM, {
            name = 'Ground Drop Fixture', desc = 'ground drop fixture',
            weight = 0.1, type = 'misc', stack = true, maxStack = 10,
        })

        local ped = GetPlayerPed(source)
        local pos = GetEntityCoords(ped)
        ctx.x, ctx.y, ctx.z = pos.x, pos.y, pos.z

        clearDropped(ctx)
    end,

    teardown = function(ctx, source)
        clearDropped(ctx)
        if source then RemoveAllOf(source, ITEM) end
    end,

    tests = {
        {
            name = 'Positional form (item, amount, metadata, x, y, z) creates the row',
            fn = function(source, ctx)
                clearDropped(ctx)
                local data, why = exports.whip_core:CreateGroundItem(
                    ITEM, 2, { tag = 'positional' }, ctx.x, ctx.y, ctx.z, 0.0, nil)

                -- assertOk, not assertNotNil: a refusal is `false, reason`, and false is not nil.
                assertOk(data, why, 'CreateGroundItem returned a row')
                local rows = droppedRows()
                assertEqual(#rows, 1, 'exactly one ground row exists')
                assertTrue(math.abs(rows[1].x - ctx.x) < 0.5, 'x came from the positional argument')
                assertTrue(rows[1].metadata:find('positional', 1, true) ~= nil,
                    'metadata was stored, not swallowed as a coordinate')
            end,
        },
        {
            name = 'Coords form (item, amount, coords, metadata) creates the row',
            fn = function(source, ctx)
                -- The shape whip_gunny already uses. Before the signature accepted it, this
                -- call destroyed the item.
                clearDropped(ctx)
                local data, why = exports.whip_core:CreateGroundItem(
                    ITEM, 1, vector3(ctx.x, ctx.y, ctx.z), { tag = 'coords', ammo = 27 })

                assertOk(data, why, 'CreateGroundItem accepted a vector3')
                local rows = droppedRows()
                assertEqual(#rows, 1, 'exactly one ground row exists')
                assertTrue(math.abs(rows[1].x - ctx.x) < 0.5, 'x was taken from the vector')
                assertTrue(math.abs(rows[1].z - ctx.z) < 0.5, 'z was taken from the vector')
                assertTrue(rows[1].metadata:find('27', 1, true) ~= nil,
                    'the metadata that FOLLOWS the vector was stored — a magazine keeps its rounds')
            end,
        },
        {
            name = 'A plain table of coordinates is accepted too',
            fn = function(source, ctx)
                -- Not every caller has a real vector3 to hand; some build {x=,y=,z=}.
                clearDropped(ctx)
                local data, why = exports.whip_core:CreateGroundItem(
                    ITEM, 1, { x = ctx.x, y = ctx.y, z = ctx.z }, { tag = 'table' })

                assertOk(data, why, 'a table with x/y/z was read as coordinates')
                local rows = droppedRows()
                assertEqual(#rows, 1, 'row created')
                -- Where it landed and what it carries, as test 2 checks for the vector. A row count
                -- alone passes when the table is mistaken for METADATA and the coordinates are
                -- taken from somewhere else — the exact confusion the two-shape signature invites.
                assertTrue(math.abs(rows[1].x - ctx.x) < 0.5, 'x was taken from the table')
                assertTrue(math.abs(rows[1].z - ctx.z) < 0.5, 'z was taken from the table')
                assertTrue(rows[1].metadata:find('table', 1, true) ~= nil,
                    'the metadata that follows the table was stored as metadata')
            end,
        },
        {
            name = 'Metadata carrying x/y/z is still metadata, not coordinates',
            fn = function(source, ctx)
                -- The ambiguity in accepting both shapes. An item whose METADATA happens to
                -- record a position — a map marker, a saved waypoint — must not be mistaken
                -- for the position to drop it at. The 4th argument being a number settles it.
                clearDropped(ctx)
                local data, why = exports.whip_core:CreateGroundItem(
                    ITEM, 1, { x = 111.0, y = 222.0, z = 333.0, tag = 'marker' },
                    ctx.x, ctx.y, ctx.z)

                assertOk(data, why, 'created')
                local rows = droppedRows()
                assertEqual(#rows, 1, 'row created')
                assertTrue(math.abs(rows[1].x - ctx.x) < 0.5,
                    'dropped at the REAL coordinates, not at the ones inside the metadata')
                assertTrue(rows[1].metadata:find('marker', 1, true) ~= nil,
                    'the metadata survived intact')
            end,
        },
        {
            name = 'Missing coordinates are REFUSED, not silently swallowed',
            fn = function(source, ctx)
                -- The actual bug: no usable coordinates meant a NOT NULL violation inside a
                -- pcall, and the item vanished with no error anyone would see. It must now
                -- come back as a clear failure so the caller can keep the item.
                clearDropped(ctx)
                local data, why = exports.whip_core:CreateGroundItem(ITEM, 1, { tag = 'nowhere' })

                -- assertFalse, NOT assertNil — the refusal is `false, reason` now, see below.
                assertFalse(data, 'no row was created')

                -- THE REASON IS THE ASSERTION, because a falsy return has two meanings here.
                --
                -- GroundItems.create refuses a bad coordinate AND swallows an INSERT failure, and
                -- both come back falsy. Delete the coordinate guard and the call falls through to
                -- the pcall'd INSERT with x = nil, the NOT NULL violation is swallowed, nothing is
                -- written — exactly the silent-destruction bug this module exists to prevent,
                -- passing as green. Only the reason separates them.
                --
                -- WHY THIS ASSERTION USED TO BE IMPOSSIBLE, and what was actually going on.
                --
                -- The original comment declined to check the reason, claiming a FiveM export
                -- marshals only its FIRST return value. That is wrong, but so was the first
                -- correction of it, which said the truncation applies only to a LEADING nil.
                --
                -- THE RULE IS: an export's return list is TRUNCATED AT THE FIRST NIL, in any
                -- position. `nil, 'Invalid coordinates'` lost the reason; `true, nil, removed`
                -- from TakeItemFrom lost the third value in exactly the same way. AddItem's
                -- three-value return survives ONLY on the ground path, where the middle slot
                -- holds a non-nil error string — its `true, nil, 'inventory'` case was losing
                -- the placement and nothing caught it, because no test asserted that value.
                -- 02_inventory now does.
                --
                -- So the guard was reporting its reason to nobody. create returns `false, reason`
                -- — still falsy for every caller, and the reason actually crosses.
                assertEqual(why, 'Invalid coordinates',
                    'refused for the RIGHT reason, not a swallowed NOT NULL violation')
                assertEqual(#droppedRows(), 0, 'nothing reached the database')
            end,
        },
    },
})
