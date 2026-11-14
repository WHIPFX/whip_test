--- The items this module puts on the ground by hand, as opposed to the 'food' rows it creates at
--- fixed coordinates (those are tracked by id).
local FIXTURE_ITEMS = { '_test_dropitem', '_test_dropstack' }

--- Find a ground row of `item` near the tester whose metadata passes `match`.
local function findNearby(source, item, match)
    local pos = GetEntityCoords(GetPlayerPed(source))
    for _, g in ipairs(exports.whip_core:GetGroundItemsNearby(pos.x, pos.y, pos.z, 10) or {}) do
        if g.item == item and (not match or match(g)) then return g end
    end
    return nil
end

RegisterTestModule({
    order    = 6,
    category = 'Ground Items',
    setup = function(source, ctx)
        ctx.createdIds = {}
    end,
    -- CLEANS BY IDENTITY, not only by remembered id — and THROUGH whip_core, never by SQL.
    --
    -- Ground ids stopped being stable. A failed pickup re-creates the item as a NEW row with a
    -- NEW auto-increment id, and AddItem's failsafe drops to the floor as another. Both leave a
    -- row this teardown has no id for — and a leaked row sits in the cache and the spatial grid
    -- for every later module, where 'GetGroundItemsNearby finds items in range' is exactly the
    -- kind of assertion that hides it rather than surfacing it.
    --
    -- This used to finish with a raw `DELETE ... WHERE item LIKE '_test_%'`. That removed the rows
    -- and left every one of them in whip_core's cache and grid: still drawn at the tester's feet,
    -- and still pickable — GroundItems.delete only checks the cache — so each pickup of a ghost
    -- conjured an item from nothing. The ids are read from the database instead and deleted
    -- through the export, which does the row and the cache together.
    teardown = function(ctx, source)
        for _, id in ipairs(ctx.createdIds or {}) do
            pcall(exports.whip_core.DeleteGroundItem, exports.whip_core, id)
        end

        local ok, rows = pcall(DbQuery, 'SELECT `id` FROM `ground_items` WHERE `item` IN (?, ?)', FIXTURE_ITEMS)
        if ok then
            for _, row in ipairs(rows) do
                pcall(exports.whip_core.DeleteGroundItem, exports.whip_core, row.id)
            end
        end

        if source then
            for _, item in ipairs(FIXTURE_ITEMS) do RemoveAllOf(source, item) end
        end
    end,
    tests = {
        {
            name = 'CreateGroundItem returns item with ID, and the row is on disk',
            fn = function(source, ctx)
                local item, err = exports.whip_core:CreateGroundItem('food', 5, nil, 0, 0, 50, 0, nil)
                assertOk(item, err, 'CreateGroundItem')
                assertType(item.id, 'number', 'item.id')
                assertEqual(item.item, 'food', 'item.item')
                assertEqual(item.amount, 5, 'item.amount')
                ctx.createdIds[#ctx.createdIds + 1] = item.id
                ctx.firstId = item.id

                -- Write-through: the insert has to land before the id exists, so no flush is owed.
                assertDbScalar('SELECT `amount` FROM `ground_items` WHERE `id` = ?', { item.id }, 5,
                    'the row is on disk')
            end,
        },
        {
            name = 'CreateGroundItem with metadata preserves it',
            fn = function(source, ctx)
                local meta = { _testFlag = true }
                local item, err = exports.whip_core:CreateGroundItem('food', 1, meta, 10, 10, 50, 0, nil)
                assertOk(item, err, 'CreateGroundItem with meta')
                ctx.createdIds[#ctx.createdIds + 1] = item.id
                ctx.secondId = item.id
                assertNotNil(item.metadata, 'metadata')
                assertTrue(item.metadata._testFlag, 'metadata._testFlag')
            end,
        },
        {
            -- NAMES THE ROWS IT EXPECTS. ">= 1" passed on any item anyone had ever dropped near the
            -- origin — the kind of leaked row this module's own teardown comment warns about.
            name = 'GetGroundItemsNearby finds the items in range',
            fn = function(source, ctx)
                local nearby = exports.whip_core:GetGroundItemsNearby(0, 0, 50, 20)
                assertType(nearby, 'table', 'GetGroundItemsNearby')
                local ids = {}
                for _, n in ipairs(nearby) do ids[n.id] = true end
                assertTrue(ids[ctx.firstId] == true, 'the item at the origin')
                assertTrue(ids[ctx.secondId] == true, 'the item 14 m away, inside a 20 m radius')
            end,
        },
        {
            name = 'GetGroundItemsNearby returns empty for far coords',
            fn = function(source, ctx)
                local nearby = exports.whip_core:GetGroundItemsNearby(9999, 9999, 50, 5)
                assertType(nearby, 'table', 'GetGroundItemsNearby far')
                assertEqual(#nearby, 0, 'should be empty')
            end,
        },
        {
            -- Asserts the delete, not the absence of something a loop happened not to visit: the old
            -- body only asserted INSIDE a loop over the nearby list, so an empty list proved nothing.
            name = 'DeleteGroundItem removes item, from the world and from disk',
            fn = function(source, ctx)
                local item, err = exports.whip_core:CreateGroundItem('food', 1, nil, 5, 5, 50, 0, nil)
                assertOk(item, err, 'create for delete')
                ctx.createdIds[#ctx.createdIds + 1] = item.id

                local ok, delErr = exports.whip_core:DeleteGroundItem(item.id)
                assertOk(ok, delErr, 'DeleteGroundItem')

                for _, n in ipairs(exports.whip_core:GetGroundItemsNearby(5, 5, 50, 3) or {}) do
                    assertNotEqual(n.id, item.id, 'deleted item should not appear')
                end
                assertDbRowCount('SELECT 1 FROM `ground_items` WHERE `id` = ?', { item.id }, 0,
                    'the row is gone from disk')

                local again = exports.whip_core:DeleteGroundItem(item.id)
                assertFalse(again, 'a second delete finds nothing')
            end,
        },

        -- ==========================================
        -- Drop/Pickup Lifecycle — through the REAL handlers
        -- ==========================================
        {
            -- DRIVES THE REAL HANDLER, as the pickup test below already did.
            --
            -- This used to SIMULATE a drop — RemoveItem, then CreateGroundItem with the metadata
            -- copied across by the test — and then assert its own simulation. dropToGround itself
            -- never ran, so its uid stamp, its weight of the taken stack and the flush that keeps
            -- the item from existing in two places after a crash were all untested.
            name = 'Dropping from the inventory puts the item on the ground, metadata and all',
            fn = function(source, ctx)
                -- Use a unique non-stackable item so metadata never gets lost to stacking
                local reg, regErr = exports.whip_core:RegisterItem('_test_dropitem', {
                    name = 'Test Drop', weight = 0.1, type = 'misc', stack = false, maxStack = 1,
                })
                assertOk(reg, regErr, 'RegisterItem')

                local slot = 4
                -- By address (09-24: RemoveItemFromSlot and PlaceItemAt were removed). Clearing an
                -- empty slot answers false, which is fine here; StoreGive answers the slot number.
                local addr = PocketAddr(source, 'player', slot)
                exports.whip_core:StoreTake(addr)
                local placed, pErr = exports.whip_core:StoreGive(addr, '_test_dropitem', 1,
                    { quality = 'gold', serial = 12345 })
                assertOk(placed, pErr, 'the item to drop is in slot 4')

                -- The spot: the player's game finds it (client/ground.lua, walls); the test names one
                -- half a metre beside the tester, which the server takes as within reach.
                local here = GetEntityCoords(GetPlayerPed(source))
                assertTrue(ClientExecWait(source, 'whip_core:server:dropToGround', 3000, 'player', slot, 1, 0,
                    here.x + 0.5, here.y, here.z - 1.0), 'the server answered the drop')
                assertLastReject('whip_core:server:dropToGround', nil, 'drop')

                assertNil(exports.whip_core:GetItemAt(addr), 'the slot is empty')
                assertEqual(exports.whip_core:GetItemCount(source, '_test_dropitem'), 0, 'nothing left on the player')

                local g = findNearby(source, '_test_dropitem', function(row)
                    return row.metadata and row.metadata.serial == 12345
                end)
                assertNotNil(g, 'the item is on the ground at the tester\'s feet')
                ctx.createdIds[#ctx.createdIds + 1] = g.id
                ctx._dropId = g.id
                ctx._dropPos = GetEntityCoords(GetPlayerPed(source))

                local p = exports.whip_core:GetPlayer(source)
                assertDbScalar('SELECT `createdBy` FROM `ground_items` WHERE `id` = ?', { g.id }, p.charId,
                    'the row is on disk, credited to the dropper')
            end,
        },
        {
            name = 'Ground item has correct metadata after drop',
            fn = function(source, ctx)
                assertNotNil(ctx._dropId, 'dropId from previous test')
                local nearby = exports.whip_core:GetGroundItemsNearby(ctx._dropPos.x, ctx._dropPos.y, ctx._dropPos.z, 50)
                local found = nil
                for _, n in ipairs(nearby) do
                    if n.id == ctx._dropId then found = n; break end
                end
                assertNotNil(found, 'dropped item in nearby')
                assertEqual(found.amount, 1, 'amount is 1')
                assertNotNil(found.metadata, 'metadata survived')
                assertEqual(found.metadata.quality, 'gold', 'quality preserved')
                assertEqual(found.metadata.serial, 12345, 'serial preserved')
                -- The drop stamps the instance, so its timeline follows it through the floor.
                assertType(found.metadata.uid, 'string', 'the dropped instance carries a uid')
                ctx._dropUid = found.metadata.uid
            end,
        },
        {
            -- DRIVES THE REAL HANDLER instead of re-implementing it.
            --
            -- This used to simulate a pickup as "AddItem, then DeleteGroundItem" and then assert
            -- its own simulation — pinning the exact ordering the framework has since abandoned.
            -- The handler now deletes the ground row FIRST, write-through, and only then adds; if
            -- the add fails the item goes back as a NEW row with a NEW id. So the old test could
            -- not have caught a regression in the real path, because it never touched it.
            name = 'The pickup handler removes the ground row and returns the item with metadata',
            fn = function(source, ctx)
                assertNotNil(ctx._dropId, 'dropId')

                -- Within reach: the drop landed half a metre from the tester moments ago, and the
                -- handler refuses anything past the pickup range. A tester who has walked off has
                -- not found a pickup bug.
                local ped = GetPlayerPed(source)
                local here = GetEntityCoords(ped)
                if #(here - ctx._dropPos) > 5.0 then
                    skip('the tester moved away from the dropped item during the run')
                end

                local slot = 4
                local addr = PocketAddr(source, 'player', slot)
                exports.whip_core:StoreTake(addr)   -- false when already empty, which is fine

                assertTrue(ClientExecWait(source, 'whip_core:server:pickupGroundItem', 3000,
                    ctx._dropId, 'player', slot), 'pickup handler answered')

                -- Gone from DISK, not merely from the cache. The delete is write-through, so this
                -- is assertable immediately and is the half a cache check cannot see.
                assertDbRowCount('SELECT `id` FROM `ground_items` WHERE `id` = ?',
                    { ctx._dropId }, 0, 'ground row is gone from disk')

                -- assertOk, not assertNotNil: GetItemAt answers nil for an empty slot and false for a
                -- refused address, and assertNotNil passes on false (09-24).
                local d, dErr = exports.whip_core:GetItemAt(addr)
                assertOk(d, dErr or 'the slot is empty', 'landed in the slot the player aimed at')
                assertEqual(d.item, '_test_dropitem', 'the right item')
                assertNotNil(d.metadata, 'metadata exists')
                assertEqual(d.metadata.quality, 'gold', 'quality survived round-trip')
                assertEqual(d.metadata.serial, 12345, 'serial survived round-trip')
                assertEqual(d.metadata.uid, ctx._dropUid, 'the same instance came back — same uid')
                assertEqual(exports.whip_core:GetItemCount(source, '_test_dropitem'), 1,
                    'exactly one — the pickup did not duplicate it')
                -- (Removed in teardown.)
            end,
        },
        {
            -- ONLY THE DELETE THAT TOOK THE ROW HANDS OVER THE PILE (audit 7, INV-2). A pickup whose
            -- DELETE stalled past the 10 s lock let a second pickup in; both DELETEs "succeeded" (the
            -- second found no row and was not asked) and both players got the pile. Here the row is
            -- taken first — as that stalled rival would have — and the pickup must refuse.
            name = 'A pile whose row is already gone is refused, not handed over',
            fn = function(source, ctx)
                RemoveAllOf(source, '_test_dropitem')
                local pos = GetEntityCoords(GetPlayerPed(source))
                local g, err = exports.whip_core:CreateGroundItem('_test_dropitem', 1, { serial = 777 },
                    pos.x, pos.y, pos.z, 0.0, nil)
                assertOk(g, err, 'a pile at the tester\'s feet')
                ctx.createdIds[#ctx.createdIds + 1] = g.id

                DbQuery('DELETE FROM `ground_items` WHERE `id` = ?', { g.id })   -- the rival's DELETE
                local slot = 4
                exports.whip_core:StoreTake(PocketAddr(source, 'player', slot))
                ClientExecWait(source, 'whip_core:server:pickupGroundItem', 3000, g.id, 'player', slot)

                assertEqual(exports.whip_core:GetItemCount(source, '_test_dropitem'), 0,
                    'nothing was handed over for a pile that was already gone')
                assertNotNil(exports.whip_core:__TestLastReject('whip_core:server:pickupGroundItem'),
                    'the pickup was refused')
                assertNil(exports.whip_core:GetGroundItem(g.id), 'and the stale pile left the server\'s memory too')
            end,
        },
        {
            -- The right-click "drop one" off a held stack: exactly one unit leaves, and the rest stay
            -- where they were. Its own handler, with its own copy of the take-then-create rule.
            name = 'Dropping ONE off a stack leaves the rest in the slot',
            fn = function(source, ctx)
                local reg, regErr = exports.whip_core:RegisterItem('_test_dropstack', {
                    name = 'Test Drop Stack', weight = 0.1, type = 'misc', stack = true, maxStack = 10,
                })
                assertOk(reg, regErr, 'RegisterItem')

                local slot = 7
                SeedSlot(source, 'player', slot, '_test_dropstack', 3)

                local here = GetEntityCoords(GetPlayerPed(source))
                assertTrue(ClientExecWait(source, 'whip_core:server:dropOneToGround', 3000, 'player', slot, 0,
                    here.x + 0.5, here.y, here.z - 1.0), 'the server answered the drop-one')
                assertLastReject('whip_core:server:dropOneToGround', nil, 'drop-one')

                local d, dErr = exports.whip_core:GetItemAt(PocketAddr(source, 'player', slot))
                assertOk(d, dErr or 'the slot is empty', 'the slot still holds the rest')
                assertEqual(d.amount, 2, 'exactly one left the stack')

                local g = findNearby(source, '_test_dropstack')
                assertNotNil(g, 'the one unit is on the ground')
                ctx.createdIds[#ctx.createdIds + 1] = g.id
                assertEqual(g.amount, 1, 'as a single unit')
                assertDbScalar('SELECT `amount` FROM `ground_items` WHERE `id` = ?', { g.id }, 1,
                    'and on disk')
            end,
        },
        {
            -- THE SPOT IS THE PLAYER'S GAME'S, WITHIN REACH (Josh, 5 Oct 2026: drops went through
            -- walls). One past the Ground panel's reach — through a wall, from a modded client — is
            -- refused, and the item stays where it was.
            name = 'A drop spot out of reach is refused: "Nowhere to place!"',
            fn = function(source, ctx)
                local slot = 7
                SeedSlot(source, 'player', slot, '_test_dropstack', 2)
                local here = GetEntityCoords(GetPlayerPed(source))
                ClientExecWait(source, 'whip_core:server:dropOneToGround', 3000, 'player', slot, 0,
                    here.x + 8.0, here.y, here.z - 1.0)
                assertNotNil(exports.whip_core:__TestLastReject('whip_core:server:dropOneToGround'),
                    'the drop was refused')
                local d = exports.whip_core:GetItemAt(PocketAddr(source, 'player', slot))
                assertEqual(d and d.amount, 2, 'nothing left the slot')

                ClientExecWait(source, 'whip_core:server:dropToGround', 3000, 'player', slot, 1, 0)
                assertNotNil(exports.whip_core:__TestLastReject('whip_core:server:dropToGround'),
                    'a drop with no spot at all is refused too')
                d = exports.whip_core:GetItemAt(PocketAddr(source, 'player', slot))
                assertEqual(d and d.amount, 2, 'and nothing left the slot')
            end,
        },
    }
})
