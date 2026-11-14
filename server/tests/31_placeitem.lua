-- ============================================
-- placeItem — placing mode's server half, and the `placed` flag
--
-- WHY THIS MODULE EXISTS
--
-- Placing mode's whole promise is EXACTNESS: the ground row is created at the very
-- coordinates the client's ghost stood on, marked `placed = 1`, and every client's
-- renderer trusts that z/heading instead of snapping the prop to the ground. Three
-- things can quietly break that promise and each is pinned here:
--
--   1. The event writing approximate coords, or forgetting the flag — a wallet placed
--      on a table renders on the floor.
--   2. The distance clamp loosening (or tightening onto the legitimate third-person
--      camera gap) — either an exploit or a broken feature.
--   3. The flag falling off somewhere between create() and the cache rows that feed
--      every sync payload.
--
-- The failed-pickup rollback's flag carry (events_inventory re-creates from the cache
-- row with gItem.placed) is pinned INDIRECTLY via the cache assertion in test 3: the
-- rollback reads the same cached row this test proves carries the flag. Staging a
-- genuine add-failure would mean filling the tester's whole inventory; judged not
-- worth what it destroys.
-- ============================================

local ITEM = '_test_placeitem'

--- Ground rows for our fixture item, straight from the database. (A ground row is written the
--- moment it is created — GroundItems.create needs the id back — so no flush is needed first.)
local function placedRows()
    return DbQuery(
        'SELECT `id`, `x`, `y`, `z`, `heading`, `placed`, `rx`, `ry` FROM `ground_items` WHERE `item` = ?', { ITEM })
end

--- Is a TINYINT(1) flag set? Both shapes accepted, ON PURPOSE.
---
--- The driver decides whether TINYINT(1) arrives as a number or a boolean, and it has already
--- changed its mind once under this codebase — see the long note at whip_core/server/ground.lua
--- where loadAll reads `(row.placed == 1) or (row.placed == true)` for exactly this reason.
--- Production reads the flag with that rule, so a test that insists on `1` is not pinning the
--- FEATURE, it is pinning the DRIVER, and it goes red against correct code the next time the
--- driver is upgraded. These two helpers say what the assertions actually mean.
local function flagSet(v)   return v == 1 or v == true  end
local function flagClear(v) return v == 0 or v == false end

--- Remove every fixture row — FROM THE CACHE AND THE GRID TOO, not just the table.
---
--- This used to be a bare SQL DELETE, and that is not what "clear" means here. Ground items
--- live in `GroundItems.cache` with a spatial grid beside it, and the read path this module
--- asserts against — GetGroundItemsNearby — answers from the CACHE, never from the database.
--- So deleting the rows emptied the half nothing reads and left the half everything reads
--- fully populated.
---
--- The damage was a test failing for another test's reasons: rows placed by earlier cases
--- stayed in the cache at coordinates a couple of metres away, and test 3's "first row with
--- our item" search — over a pairs() iteration, so the order is arbitrary — would hand back a
--- previous test's row. It asserted `placed`, which was true either way, and then asserted a
--- tilt belonging to a placement it never made.
---
--- DeleteGroundItem purges the row, the cache entry, the grid cell and the pickup lock, and
--- tells the clients. The sweep afterwards catches any row whose cache entry had already gone,
--- since the export refuses an id it cannot find in the cache.
local function clearRows()
    for _, row in ipairs(placedRows()) do
        pcall(exports.whip_core.DeleteGroundItem, exports.whip_core, row.id)
    end
    pcall(MySQL.query.await, 'DELETE FROM `ground_items` WHERE `item` = ?', { ITEM })
end

--- Reserve an empty high slot (24_placement's claim idiom, via 25_storemove).
local function claim(source, container, n)
    local slots = exports.whip_core:GetPocketSlots(container)
    assertNotNil(slots, ('%s slot count is known'):format(container))
    local slot = slots - n + 1
    assertTrue(slot >= 1, ('%s has room for reserved slot #%d'):format(container, n))
    -- 09-24: by address (RemoveItemFromSlot / GetSlotData were removed). Clearing an empty slot
    -- answers false, 'Empty slot', which is fine here.
    pcall(exports.whip_core.StoreTake, exports.whip_core, PocketAddr(source, container, slot))
    assertNil(exports.whip_core:GetItemAt(PocketAddr(source, container, slot)),
        ('%s slot %d is empty before the module seeds it'):format(container, slot))
    return slot
end

local S = {}

RegisterTestModule({
    order    = 31,
    category = 'Place Item',

    setup = function(source, ctx)
        exports.whip_core:RegisterItem(ITEM, {
            name = 'Place Fixture', desc = 'placing mode fixture',
            weight = 0.1, type = 'misc', stack = true, maxStack = 10,
        })
        clearRows()
        RemoveAllOf(source, ITEM)
        S.slot = claim(source, 'player', 1)

        local p = exports.whip_core:GetPlayer(source)
        assertNotNil(p, 'setup: GetPlayer')
        ctx.charId = p.charId

        local ped = GetPlayerPed(source)
        local pos = GetEntityCoords(ped)
        ctx.x, ctx.y, ctx.z = pos.x, pos.y, pos.z
    end,

    teardown = function(ctx, source)
        -- First: test 1 pauses the flush thread around its raw read.
        pcall(exports.whip_core.__TestPauseFlushThread, exports.whip_core, false)
        clearRows()
        if source then RemoveAllOf(source, ITEM) end
    end,

    tests = {
        {
            name = 'Placing writes an exact, flagged row and empties the slot',
            fn = function(source, ctx)
                clearRows()
                SeedSlot(source, 'player', S.slot, ITEM, 3)
                -- The seed ON DISK, and the background writer held off (teardown resumes it too), so
                -- the raw read below can only find the row gone if the HANDLER removed it.
                FlushPersistence(source)
                exports.whip_core:__TestPauseFlushThread(true)

                -- ~2m in front of the ped, hand-picked z, heading and tilt — the
                -- numbers a ghost would have committed on a slope.
                local px, py, pz, ph = ctx.x + 2.0, ctx.y, ctx.z + 0.4, 123.0
                local prx, pry = 12.5, -7.25
                ClientExecWait(source, 'whip_core:server:placeItem', 3000,
                    'player', S.slot, 3, px, py, pz, ph, prx, pry)

                local stillOnDisk = DbQuery(
                    'SELECT 1 FROM `character_inventory` WHERE `charId` = ? AND `container` = ? AND `slot` = ?',
                    { ctx.charId, 'player', S.slot })
                exports.whip_core:__TestPauseFlushThread(false)

                assertLastReject('whip_core:server:placeItem', nil, 'the placement was accepted')
                local rows = placedRows()
                assertEqual(#rows, 1, 'exactly one ground row exists')
                assertTrue(flagSet(rows[1].placed), 'the row is marked placed')
                -- ±0.01, not the drop tests' ±0.5: exactness IS the feature. If this
                -- ever fails on float rounding alone, the feature has a real problem.
                assertTrue(math.abs(rows[1].x - px) < 0.01, 'x is exact')
                assertTrue(math.abs(rows[1].y - py) < 0.01, 'y is exact')
                assertTrue(math.abs(rows[1].z - pz) < 0.01, 'z is exact — the table-top z, not a ground snap')
                assertTrue(math.abs(rows[1].heading - ph) < 0.01, 'heading is exact')
                assertTrue(math.abs(rows[1].rx - prx) < 0.01, 'pitch is exact — slope placements lie on the slope')
                assertTrue(math.abs(rows[1].ry - pry) < 0.01, 'roll is exact')
                assertNil(exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.slot)),
                    'the whole stack left the inventory')

                -- AND ALREADY OFF DISK, read RAW (no flush) straight after the handler. The ground row
                -- is written at once, so the handler FLUSHES the inventory half rather than queueing
                -- it: left to the write-behind interval, a crash in between would restore the item
                -- to the pocket on restart while the ground row survived — the item in two places. A
                -- flush here would hide exactly that, so this is what the handler left on disk.
                assertEqual(#stillOnDisk, 0,
                    'the inventory row was removed in the same breath as the ground row was written')
            end,
        },
        {
            name = 'A placement beyond reach is refused and the item stays',
            fn = function(source, ctx)
                clearRows()
                SeedSlot(source, 'player', S.slot, ITEM, 2)

                -- 50m out. The clamp is PlaceItemRange + 6.0 camera slack (~16.5m at the
                -- shipped 10.5 range). This refusal happens inside the HANDLER, not in SecureEvent's
                -- param checks — it used to be a console print and nothing else, so this test could
                -- only watch state. The handler records it now, so the reason is the assertion.
                ClientExecWait(source, 'whip_core:server:placeItem', 3000,
                    'player', S.slot, 2, ctx.x + 50.0, ctx.y, ctx.z, 0.0, 0.0, 0.0)

                assertLastReject('whip_core:server:placeItem', 'Too far away to place that',
                    'refused by the reach check, not something else')
                assertEqual(#placedRows(), 0, 'no ground row was created')
                local slotData = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.slot))
                assertNotNil(slotData, 'the item never left the slot')
                assertEqual(slotData.amount, 2, 'full amount retained')
            end,
        },
        {
            name = 'The flag survives into the live cache that feeds sync payloads',
            fn = function(source, ctx)
                clearRows()
                SeedSlot(source, 'player', S.slot, ITEM, 1)
                local px, py, pz = ctx.x + 1.5, ctx.y + 1.0, ctx.z + 0.4
                ClientExecWait(source, 'whip_core:server:placeItem', 3000,
                    'player', S.slot, 1, px, py, pz, 0.0, 4.5, 0.0)

                -- GetGroundItemsNearby reads the same cache rows broadcastCreate, the
                -- login sync and the cell batch send — and the same rows the failed-pickup
                -- rollback re-creates from. `placed` truthy here means every one of those
                -- carries it.
                -- MATCHED BY ID, not by "the first row carrying our item".
                --
                -- getNearby walks a pairs() iteration, so with more than one fixture row in
                -- range the row it hands back first is arbitrary. This test then asserted a
                -- tilt against whichever one it happened to get — passing or failing on hash
                -- order rather than on whether the flag survived. The row just written is the
                -- only one this test has anything to say about, so name it.
                local rows = placedRows()
                assertEqual(#rows, 1, 'exactly one fixture row exists to look for')
                local placedId = rows[1].id

                local nearby = exports.whip_core:GetGroundItemsNearby(px, py, pz, 5.0)
                assertNotNil(nearby, 'nearby query answered')
                local found = nil
                for _, row in ipairs(nearby) do
                    if row.id == placedId then found = row break end
                end
                assertNotNil(found, 'the placed item is in the cache')
                assertTrue(found.placed == true, 'the cache row carries placed = true')
                assertTrue(math.abs((found.rx or 0) - 4.5) < 0.01,
                    'the cache row carries the tilt — sync payloads and rollbacks read this row')
            end,
        },
        {
            name = 'Rows born through the export or the coords form are NOT flagged',
            fn = function(source, ctx)
                -- The export is deliberately 8 args — a satellite drop can never
                -- accidentally mint an exact-placement row, and the coords form
                -- explicitly refuses to thread the flag.
                clearRows()
                local a, whyA = exports.whip_core:CreateGroundItem(ITEM, 1, { tag = 'drop' }, ctx.x, ctx.y, ctx.z, 0.0, nil)
                assertOk(a, whyA, 'the positional form created a row')
                local b, whyB = exports.whip_core:CreateGroundItem(ITEM, 1, vector3(ctx.x + 1.0, ctx.y, ctx.z), { tag = 'coords' })
                assertOk(b, whyB, 'the coords form created a row')

                local rows = placedRows()
                assertEqual(#rows, 2, 'both drops created rows')
                for _, row in ipairs(rows) do
                    assertTrue(flagClear(row.placed), 'an ordinary drop is not marked placed')
                end
            end,
        },
        {
            name = 'A placed item picks back up like any ground item',
            fn = function(source, ctx)
                clearRows()
                SeedSlot(source, 'player', S.slot, ITEM, 1)
                ClientExecWait(source, 'whip_core:server:placeItem', 3000,
                    'player', S.slot, 1, ctx.x + 1.0, ctx.y, ctx.z, 0.0, 0.0, 0.0)
                local rows = placedRows()
                assertEqual(#rows, 1, 'placed row exists')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM) or 0, 0,
                    'nothing of the fixture is left in the pockets before the pickup')

                ClientExecWait(source, 'whip_core:server:quickPickupGroundItem', 3000, rows[1].id)

                assertLastReject('whip_core:server:quickPickupGroundItem', nil, 'the pickup was accepted')
                assertEqual(#placedRows(), 0, 'the ground row is gone')
                -- EXACTLY one. `>= 1` passed a pickup that handed the item over twice — the one
                -- outcome of a pickup that is worse than it failing.
                assertEqual(exports.whip_core:GetItemCount(source, ITEM) or 0, 1,
                    'the item is back in a pocket, once — placed items are ordinary ground items')
            end,
        },
    },
})
