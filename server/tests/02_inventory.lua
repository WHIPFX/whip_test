--- The first accessory slot that takes any item. A typed one (slot 4, which whip_test makes
--- bandage-only for the run) refuses food on every path.
---@return number|nil
local function untypedAccessorySlot()
    local untyped
    for slot, def in pairs(exports.whip_core:GetAccessorySlots() or {}) do
        if not def.accepts and (not untyped or slot < untyped) then untyped = slot end
    end
    return untyped
end

--- The items this module can leave ON THE GROUND. Two of its tests exist to prove the drop-at-feet
--- failsafe, so a failing assertion in either leaves the item in the world — and a ground item sits
--- in the cache and the spatial grid for every later module. Swept in teardown, by name, around
--- every position a test recorded.
local GROUND_FIXTURES = { _test_heavy = true, _test_overflow = true }

--- A character_inventory metadata cell, decoded. MariaDB's JSON is text and arrives as a string;
--- a server on MySQL's native JSON type gets it back already decoded.
local function decodeMeta(raw)
    if type(raw) == 'string' then return json.decode(raw) or {} end
    return raw or {}
end

--- Remember where a test stood before something may have gone to the floor.
local function noteGroundPos(ctx, source)
    ctx.groundPositions = ctx.groundPositions or {}
    ctx.groundPositions[#ctx.groundPositions + 1] = GetEntityCoords(GetPlayerPed(source))
end

RegisterTestModule({
    order    = 2,
    category = 'Inventory',
    teardown = function(ctx, source)
        -- EVERYTHING THIS MODULE ADDS IS REMOVED HERE, not at the end of the test that added it.
        -- Cleanup written after the assertions only runs when every assertion passed, which is
        -- exactly when it is least needed — and an item left behind is now reported against this
        -- module as LEAKED STATE.
        if source then
            RemoveAllOf(source, '_test_item')
            RemoveAllOf(source, '_test_meta_item')
            RemoveAllOf(source, '_test_heavy')
            RemoveAllOf(source, '_test_massive')
            RemoveAllOf(source, '_test_stackable')
            RemoveAllOf(source, '_test_filler')
            RemoveAllOf(source, '_test_overflow')
            RemoveAllOf(source, 'food')

            local positions = ctx.groundPositions or {}
            positions[#positions + 1] = GetEntityCoords(GetPlayerPed(source))
            for _, pos in ipairs(positions) do
                for _, g in ipairs(exports.whip_core:GetGroundItemsNearby(pos.x, pos.y, pos.z, 10) or {}) do
                    if GROUND_FIXTURES[g.item] then
                        pcall(exports.whip_core.DeleteGroundItem, exports.whip_core, g.id)
                    end
                end
            end
        end
    end,
    tests = {
        {
            name = 'AddItem puts an item on the player, and SAYS it went to the inventory',
            fn = function(source, ctx)
                -- Relative to what was there, so the counts below are exact rather than ">=". The
                -- runner empties the inventory before a run and after every module, so this is
                -- normally zero — but a count that only works from zero is a count that lies the
                -- day it does not start there.
                ctx.foodBefore = exports.whip_core:GetItemCount(source, 'food') or 0

                local where, err = exports.whip_core:AddItem(source, 'food', 3)
                assertOk(where, err, 'AddItem')

                -- THE REGRESSION NET FOR THE NIL-TRUNCATION RULE.
                --
                -- A FiveM export's return list is truncated at the FIRST NIL, in any position.
                -- GiveOrDrop returned `true, nil, 'inventory'` on this path, so the placement was
                -- dropped at the boundary and every satellite saw nil — while the ground path at
                -- the bottom of this file worked, purely because its middle slot holds a non-nil
                -- error string. One of the two branches of a documented return value was dead and
                -- the suite could not tell, because only the working branch was ever asserted.
                --
                -- 09-24: AddItem now answers WHERE it went as its FIRST value — 'inventory' or
                -- 'ground', or `false, reason` — instead of `true, false|reason, placement`. Both
                -- branches are still asserted: this one here, 'ground' at the bottom of the file.
                assertEqual(where, 'inventory', 'the answer says where it actually went')

                assertEqual(exports.whip_core:GetItemCount(source, 'food'), ctx.foodBefore + 3,
                    'exactly three more food')
            end,
        },
        {
            -- THE AMOUNT IS A MINIMUM. "HasItem returns true" alone passes for any implementation
            -- that ignores the second argument, which is the half satellites lean on to check a
            -- price or a recipe before taking anything.
            name = 'HasItem finds an item the player is carrying, and honours the amount',
            fn = function(source, ctx)
                local have = ctx.foodBefore + 3
                assertTrue(exports.whip_core:HasItem(source, 'food'), 'HasItem with no amount')
                assertTrue(exports.whip_core:HasItem(source, 'food', have), 'exactly what they have')
                assertFalse(exports.whip_core:HasItem(source, 'food', have + 1), 'one more than they have')
            end,
        },
        {
            -- ACROSS EVERY CONTAINER, which the old ">= 3" never looked at: the food it counted was
            -- all in the main grid. A second stack in the accessory strip is what the total is for.
            name = 'GetItemCount totals across every container',
            fn = function(source, ctx)
                local untyped = untypedAccessorySlot()
                if not untyped then skip('the accessory strip has no untyped slot to put food in') end

                -- By address (09-24: RemoveItemFromSlot and PlaceItemAt were removed). Clearing an
                -- empty slot answers false, which is fine here.
                local addr = PocketAddr(source, 'accessory', untyped)
                pcall(exports.whip_core.StoreTake, exports.whip_core, addr)
                local placed, err = exports.whip_core:StoreGive(addr, 'food', 2)
                assertOk(placed, err, 'food placed in the accessory strip')

                assertEqual(exports.whip_core:GetItemCount(source, 'food'), ctx.foodBefore + 5,
                    'the accessory stack is counted with the pocket stack')

                local removed, rErr = exports.whip_core:StoreTake(addr)
                assertOk(removed, rErr, 'accessory stack removed again')
                assertEqual(exports.whip_core:GetItemCount(source, 'food'), ctx.foodBefore + 3,
                    'and the total follows it back down')
            end,
        },
        {
            name = 'RemoveItem takes exactly the amount asked for',
            fn = function(source, ctx)
                local ok, err = exports.whip_core:RemoveItem(source, 'food', 2)
                assertOk(ok, err, 'RemoveItem')
                assertEqual(exports.whip_core:GetItemCount(source, 'food'), ctx.foodBefore + 1,
                    'two gone, one left')
            end,
        },
        {
            -- ALL OR NOTHING. removeItemAcrossContainers totals first and refuses without touching
            -- anything when the total is short — the reason RemoveItem(x, 9999) is a no-op and
            -- RemoveAllOf exists.
            name = 'RemoveItem more than available fails, and takes nothing',
            fn = function(source, ctx)
                local ok, err = exports.whip_core:RemoveItem(source, 'food', 99999)
                assertFalse(ok, 'RemoveItem should fail')
                assertTrue(tostring(err):find('Not enough items', 1, true) ~= nil,
                    ('refused for the shortfall (got "%s")'):format(tostring(err)))
                assertEqual(exports.whip_core:GetItemCount(source, 'food'), ctx.foodBefore + 1,
                    'nothing was taken by the refused call')
            end,
        },
        {
            name = 'HasItem returns false for nonexistent item',
            fn = function(source)
                assertFalse(exports.whip_core:HasItem(source, '_test_nonexistent_item_xyz'), 'HasItem nonexistent')
            end,
        },
        {
            name = 'AddItem with metadata preserves metadata',
            fn = function(source)
                -- Use a distinct item to avoid finding a different food slot
                local reg, regErr = exports.whip_core:RegisterItem('_test_meta_item', {
                    name = 'Test Meta', weight = 0.1, type = 'misc', stack = true, maxStack = 10,
                })
                assertOk(reg, regErr, 'RegisterItem')
                local meta = { testKey = 'testValue', num = 42 }
                local where, err = exports.whip_core:AddItem(source, '_test_meta_item', 1, meta)
                assertEqual(where, 'inventory', 'AddItem with meta: ' .. tostring(err))
                -- (09-24: a FindItem entry is `{ item, amount, metadata, addr }` — no `.data` level.)
                local found = exports.whip_core:FindItem(source, '_test_meta_item')
                assertNotNil(found, 'FindItem')
                assertNotNil(found.metadata, 'metadata exists')
                assertEqual(found.metadata.testKey, 'testValue', 'metadata.testKey')
                assertEqual(found.metadata.num, 42, 'metadata.num')
                -- (Removed in teardown. This used RemoveItem(item, 99) — a guaranteed no-op for a
                -- stack of one, because RemoveItem refuses a short total — so it leaked every run.)
            end,
        },
        {
            -- 09-24: GetSlotData(source, container, slot) was removed. FindItem hands back the
            -- address, and GetItemAt reads it — nil for an empty slot, `false, reason` for a bad one.
            name = 'GetItemAt agrees with FindItem about the slot',
            fn = function(source)
                local found = exports.whip_core:FindItem(source, 'food')
                assertNotNil(found, 'FindItem for slot')
                local slot, err = exports.whip_core:GetItemAt(found.addr)
                assertOk(slot, err, 'GetItemAt')
                assertEqual(slot.item, 'food', 'slot.item')
                assertEqual(slot.amount, found.amount, 'the same amount from both readers')
            end,
        },
        {
            -- The cache is not the oracle — the database is. A metadata change that never reaches
            -- disk is a round count or a serial that comes back wrong after a restart, and a test
            -- reading GetItemAt alone could not tell.
            --
            -- (09-24: SetItemMetadata takes an ADDRESS now, not `source, container, slot` —
            -- FindItem's `addr` is exactly that.)
            name = 'SetItemMetadata updates metadata, in memory and on disk',
            fn = function(source)
                local found = exports.whip_core:FindItem(source, 'food')
                assertNotNil(found, 'FindItem for meta update')
                local ok, err = exports.whip_core:SetItemMetadata(found.addr, { updated = 'yes' })
                assertOk(ok, err, 'SetItemMetadata')
                local slot = exports.whip_core:GetItemAt(found.addr)
                assertEqual(slot.metadata and slot.metadata.updated, 'yes', 'metadata.updated in memory')

                local p = exports.whip_core:GetPlayer(source)
                FlushPersistence(source)
                local rows = DbQuery(
                    'SELECT `metadata` FROM `character_inventory` WHERE `charId` = ? AND `container` = ? AND `slot` = ?',
                    { p.charId, found.addr.sub, found.addr.slot })
                assertNotNil(rows[1], 'the row is on disk')
                assertEqual(decodeMeta(rows[1].metadata).updated, 'yes', 'metadata.updated on disk')
            end,
        },
        {
            -- `quiet` skips the push to the client, and nothing else: it still has to be a real,
            -- saved change. A quiet path that also skipped the save would lose a magazine's round
            -- count at the next restart and look perfect in play.
            name = 'SetItemMetadata with quiet = true still saves',
            fn = function(source)
                local found = exports.whip_core:FindItem(source, 'food')
                assertNotNil(found, 'FindItem for quiet update')
                local ok, err = exports.whip_core:SetItemMetadata(found.addr,
                    { updated = 'quietly' }, { quiet = true })
                assertOk(ok, err, 'SetItemMetadata quiet')
                local slot = exports.whip_core:GetItemAt(found.addr)
                assertEqual(slot.metadata and slot.metadata.updated, 'quietly', 'changed in memory')

                local p = exports.whip_core:GetPlayer(source)
                FlushPersistence(source)
                local rows = DbQuery(
                    'SELECT `metadata` FROM `character_inventory` WHERE `charId` = ? AND `container` = ? AND `slot` = ?',
                    { p.charId, found.addr.sub, found.addr.slot })
                assertNotNil(rows[1], 'the row is on disk')
                assertEqual(decodeMeta(rows[1].metadata).updated, 'quietly', 'and on disk')
            end,
        },
        {
            -- 09-24: the entry is `{ item, amount, metadata, addr }`. It was `{ container, slot, data }`;
            -- the pocket and slot now live in the address, `addr.sub` and `addr.slot`.
            name = 'FindItem finds first occurrence',
            fn = function(source)
                local found = exports.whip_core:FindItem(source, 'food')
                assertNotNil(found, 'FindItem')
                assertEqual(found.item, 'food', 'found.item')
                assertType(found.addr, 'table', 'found.addr')
                assertEqual(found.addr.kind, 'player', 'found.addr is a pocket address')
                assertType(found.addr.slot, 'number', 'found.addr.slot')
                assertType(found.addr.sub, 'string', 'found.addr.sub')
            end,
        },
        {
            -- SEEDED, so the answer is known: two more stacks in two named slots. ">= 1" was
            -- satisfied by the one stack the earlier tests happened to leave.
            name = 'FindAllItems returns every stack, and filters by container',
            fn = function(source, ctx)
                local before = #(exports.whip_core:FindAllItems(source, 'food') or {})
                SeedSlot(source, 'player', 20, 'food', 1)
                SeedSlot(source, 'player', 21, 'food', 2)
                ctx.seeded = true

                local all = exports.whip_core:FindAllItems(source, 'food')
                assertEqual(#all, before + 2, 'two more stacks than before')

                local bySlot = {}
                for _, s in ipairs(all) do
                    if s.addr.sub == 'player' then bySlot[s.addr.slot] = s.amount end
                end
                assertEqual(bySlot[20], 1, 'slot 20 found with its amount')
                assertEqual(bySlot[21], 2, 'slot 21 found with its amount')

                assertEqual(#(exports.whip_core:FindAllItems(source, 'food', 'accessory') or {}), 0,
                    'none of them in the accessory strip')
            end,
        },
        {
            -- 09-24: RemoveItemFromSlot(source, container, slot, amount) was removed; StoreTake on
            -- the slot's address is the take. It answers what it TOOK, `{ item, amount, metadata }`,
            -- or `false, reason` — so the refusal texts below are StoreTake's, not the old call's.
            name = 'StoreTake on a pocket slot takes from that slot only, and refuses a short slot',
            fn = function(source, ctx)
                assertTrue(ctx.seeded == true, 'the previous test seeded slots 20 and 21')
                local s20, s21 = PocketAddr(source, 'player', 20), PocketAddr(source, 'player', 21)

                local taken, err = exports.whip_core:StoreTake(s21, 1)
                assertOk(taken, err, 'StoreTake 1 of 2')
                assertEqual(taken.amount, 1, 'and it answers what it took')
                assertEqual(exports.whip_core:GetItemAt(s21).amount, 1, 'one left in slot 21')
                assertEqual(exports.whip_core:GetItemAt(s20).amount, 1, 'slot 20 untouched')

                -- ALL OR NOTHING on the amount asked for. This used to clear the slot and report
                -- success, so a satellite charging five of something collected one.
                local short, shortErr = exports.whip_core:StoreTake(s21, 5)
                assertFalse(short, 'more than the slot holds is refused')
                assertEqual(shortErr, 'Not enough items', 'and says so')
                assertEqual(exports.whip_core:GetItemAt(s21).amount, 1, 'and takes nothing')

                -- No amount means the whole stack.
                local whole, wholeErr = exports.whip_core:StoreTake(s21)
                assertOk(whole, wholeErr, 'whole stack')
                assertNil(exports.whip_core:GetItemAt(s21), 'slot 21 empty')

                local bad, badErr = exports.whip_core:StoreTake(PocketAddr(source, 'player', 0))
                assertFalse(bad, 'slot 0 is not a slot')
                assertEqual(badErr, 'slot must be a positive integer', 'refused, not clamped to slot 1')
            end,
        },
        {
            -- 09-24: CanFitItem answers `true`, or `false, reason`. The capacity NUMBER it used to
            -- hand back as a second value is gone, so "room to spare" is read from the refusal for an
            -- amount that cannot possibly fit, which says how many would: 'Only N fit'.
            name = 'CanFitItem says yes, with room to spare, for something small',
            fn = function(source)
                local can = exports.whip_core:CanFitItem(source, 'food', 1)
                assertTrue(can, 'one food fits')

                local tooMany, why = exports.whip_core:CanFitItem(source, 'food', 1000000)
                assertFalse(tooMany, 'a million food does not fit')
                local capacity = tonumber(tostring(why):match('^Only (%d+) fit$'))
                assertNotNil(capacity, ('the refusal says how many do fit (got "%s")'):format(tostring(why)))
                assertGt(capacity, 1, 'with room for more than the one asked about')

                local unknown, unknownErr = exports.whip_core:CanFitItem(source, '_test_nonexistent_item_xyz', 1)
                assertFalse(unknown, 'an item that does not exist fits nowhere')
                assertEqual(unknownErr, 'Unknown item "_test_nonexistent_item_xyz"', 'and says why')
            end,
        },
        {
            -- Reads what is actually there. "It returns a table with a player key" was true of an
            -- empty inventory and of one that had lost every item.
            name = 'GetInventory hands back what the player is carrying',
            fn = function(source)
                local inv = exports.whip_core:GetInventory(source)
                assertNotNil(inv, 'GetInventory')
                assertType(inv.player, 'table', 'inv.player')
                local s20 = inv.player[20]
                assertNotNil(s20, 'slot 20 is in the copy')
                assertEqual(s20.item, 'food', 'with its item')
                assertEqual(s20.amount, 1, 'and its amount')
            end,
        },
        {
            -- ADDS THE INDEPENDENT ORACLE. Success used to imply the row had landed, because a
            -- failed write returned false, 'Save failed'. It does not any more: the failure is
            -- printed and the call still succeeds, since the mutation stands and the flush
            -- thread owns the retry. GetItemAt then reads the very cache the call just wrote,
            -- so without a database check the whole test is confined to memory and cannot
            -- disagree with the code — which is what the runner's durable-state preamble exists
            -- to prevent.
            --
            -- (09-24: PlaceItemAt was removed. StoreGive on the slot's address is the place, and
            -- it answers the slot NUMBER it landed in rather than `true`.)
            name = 'StoreGive places at a specific slot, and it reaches disk',
            fn = function(source)
                local addr = PocketAddr(source, 'player', 15)
                -- Clear slot 15 first
                pcall(exports.whip_core.StoreTake, exports.whip_core, addr)
                local placed, err = exports.whip_core:StoreGive(addr, 'food', 1)
                assertOk(placed, err, 'StoreGive')
                assertEqual(placed, 15, 'and answers the slot it went into')
                local slot = exports.whip_core:GetItemAt(addr)
                assertNotNil(slot, 'slot 15 data')
                assertEqual(slot.item, 'food', 'slot 15 item')

                local p = exports.whip_core:GetPlayer(source)
                assertDbScalar(
                    'SELECT `item` FROM `character_inventory` WHERE `charId` = ? AND `container` = ? AND `slot` = ?',
                    { p.charId, 'player', 15 }, 'food', 'slot 15 reached the database')
            end,
        },
        {
            -- 09-24: TakeItemFrom was removed; StoreTake answers what it took rather than `true`.
            name = 'StoreTake empties a specific slot, and the row goes with it',
            fn = function(source)
                local addr = PocketAddr(source, 'player', 15)
                local taken, err = exports.whip_core:StoreTake(addr, 1)
                assertOk(taken, err, 'StoreTake')
                local slot = exports.whip_core:GetItemAt(addr)
                assertNil(slot, 'slot 15 should be empty')

                local p = exports.whip_core:GetPlayer(source)
                assertDbRowCount(
                    'SELECT 1 FROM `character_inventory` WHERE `charId` = ? AND `container` = ? AND `slot` = ?',
                    { p.charId, 'player', 15 }, 0, 'the row was deleted on disk too')
            end,
        },
        -- 'GetItemDef returns known item' and 'GetItemDef returns nil for unknown' lived here
        -- AND in 09_items, under the same two names, asserting the same two things. Item
        -- DEFINITIONS are 09's subject, so they stay there and are gone from here.
        --
        -- The cost was not the duplicated work — it was the duplicated NAMES. A failure report
        -- naming "GetItemDef returns known item" pointed at two different files, so the first
        -- move on seeing it red was to work out which one had actually failed.
        {
            name = 'GetAllItemDefs returns table with entries',
            fn = function()
                local all = exports.whip_core:GetAllItemDefs()
                assertType(all, 'table', 'GetAllItemDefs')
                assertNotNil(all.food, 'all.food')
            end,
        },

        -- ==========================================
        -- Weight Limit Tests
        -- ==========================================
        {
            name = 'Weight limit keeps an overweight item OUT OF THE INVENTORY',
            fn = function(source, ctx)
                -- The fixture weighs one kilo MORE than the container allows, computed rather
                -- than typed. It was a literal 41kg against a literal 40kg limit, and when the
                -- limit rose to 80kg the item fitted — so the test asserting the rejection
                -- started failing, having quietly stopped describing anything true.
                --
                -- ASSERT THE EFFECT, NOT THE RETURN. AddItem is a give: too heavy to carry now
                -- means it lands on the floor and the call reports SUCCESS ('ground', 09-24).
                -- `assertFalse(ok)` was right when a full inventory destroyed the item and is
                -- wrong now. What the weight limit actually promises is that the item is not on
                -- the PLAYER.
                local playerMax = exports.whip_core:GetPocketMaxWeight('player')
                assertNotNil(playerMax, 'player maxWeight is configured')

                exports.whip_core:RegisterItem('_test_heavy', {
                    name = 'Heavy Box', weight = playerMax + 1.0,
                    type = 'misc', stack = true, maxStack = 99,
                })
                RemoveAllOf(source, '_test_heavy')

                -- Over the limit on its own, so this cannot be carried even on an empty
                -- inventory — regardless of which container it tries. Where the player stood is
                -- recorded first, because the failsafe drops it at their feet and teardown has
                -- to find it again.
                noteGroundPos(ctx, source)
                local where = exports.whip_core:AddItem(source, '_test_heavy', 1)

                assertEqual(exports.whip_core:GetItemCount(source, '_test_heavy') or 0, 0,
                    ('%.1fkg was refused by every container (limit %.1fkg)')
                        :format(playerMax + 1.0, playerMax))
                if where then
                    assertEqual(where, 'ground',
                        'an item too heavy to carry went to the floor, not into a pocket')
                end
                -- (The failsafe put it in the world; teardown clears it so later modules see a
                -- clean map, pass or fail.)
            end,
        },
        {
            name = 'CanFitItem returns false when ALL containers full',
            fn = function(source)
                -- CanFitItem asks whether an item fits ANY container, so the fixture has to
                -- out-weigh the most generous one — not the total, and not a number typed in
                -- when the containers happened to be 40/60/10.
                local limits = exports.whip_core:GetPocketMaxWeight()
                assertType(limits, 'table', 'container weight limits are readable')

                local biggest = 0
                for _, kg in pairs(limits) do
                    if type(kg) == 'number' and kg > biggest then biggest = kg end
                end
                assertTrue(biggest > 0, 'at least one container has a weight limit')

                exports.whip_core:RegisterItem('_test_massive', {
                    name = 'Massive Crate', weight = biggest + 1.0,
                    type = 'misc', stack = true, maxStack = 99,
                })
                RemoveAllOf(source, '_test_massive')

                local can, why = exports.whip_core:CanFitItem(source, '_test_massive', 1)
                assertFalse(can, ('CanFitItem false for %.1fkg — no container exceeds %.1fkg')
                    :format(biggest + 1.0, biggest))
                -- (09-24: the second value is a sentence now, not a capacity number.)
                assertEqual(why, 'No room', 'not even one fits anywhere')
            end,
        },

        -- ==========================================
        -- Stack Cap Tests
        -- ==========================================
        {
            name = 'AddItem respects maxStack limit',
            fn = function(source)
                exports.whip_core:RegisterItem('_test_stackable', {
                    name = 'Tiny Thing', weight = 0.01, type = 'misc', stack = true, maxStack = 5,
                })
                -- Record baseline (may have leftovers from prior run)
                local baseline = exports.whip_core:GetItemCount(source, '_test_stackable')
                -- Add 5 — should fill one slot to maxStack
                local where1, err1 = exports.whip_core:AddItem(source, '_test_stackable', 5)
                assertEqual(where1, 'inventory', 'AddItem 5x stackable: ' .. tostring(err1))
                -- Add 3 more — should spill to new slot (first is full at 5)
                local where2, err2 = exports.whip_core:AddItem(source, '_test_stackable', 3)
                assertEqual(where2, 'inventory', 'AddItem 3 more: ' .. tostring(err2))
                -- Total should have increased by exactly 8
                local total = exports.whip_core:GetItemCount(source, '_test_stackable')
                assertEqual(total, baseline + 8, 'added exactly 8')
                -- Verify no single slot exceeds maxStack of 5
                local allSlots = exports.whip_core:FindAllItems(source, '_test_stackable')
                for _, s in ipairs(allSlots) do
                    assertTrue(s.amount <= 5, 'slot amount <= 5, got ' .. tostring(s.amount))
                end
            end,
        },

        -- ==========================================
        -- Container fall-through
        -- ==========================================
        {
            name = 'AddItem falls through to the next container when player is full',
            fn = function(source)
                -- THE SLOT COUNT IS ASKED FOR, NOT TYPED. This filled slots 1..15 and checked
                -- 1..15 — correct when the player container held exactly 15. At 30 slots the
                -- loop left half of it empty, so `AddItem` had somewhere obvious to put the
                -- food and the fallback path this test exists to cover never ran. It still
                -- passed, which is the worst version of wrong.
                local slots = exports.whip_core:GetPocketSlots('player')
                assertNotNil(slots, 'player slot count is known')

                exports.whip_core:RegisterItem('_test_filler', {
                    name = 'Filler', weight = 0.01, type = 'misc', stack = false, maxStack = 1,
                })
                -- Clear test items
                RemoveAllOf(source, '_test_filler')
                RemoveAllOf(source, '_test_heavy')
                RemoveAllOf(source, '_test_massive')
                RemoveAllOf(source, 'food')
                -- Fill every player slot, skipping already-occupied ones (by address, 09-24:
                -- GetSlotData and PlaceItemAt were removed)
                for i = 1, slots do
                    local addr = PocketAddr(source, 'player', i)
                    local existing = exports.whip_core:GetItemAt(addr)
                    if not existing then
                        exports.whip_core:StoreGive(addr, '_test_filler', 1)
                    end
                end
                -- Verify player container is actually full
                local allFull = true
                for i = 1, slots do
                    if not exports.whip_core:GetItemAt(PocketAddr(source, 'player', i)) then
                        allFull = false; break
                    end
                end
                assertTrue(allFull, ('all %d player slots occupied'):format(slots))

                -- The fallback can only land in an UNTYPED accessory slot — the typed ones (phone,
                -- key, cash) now refuse food on this path too, as they always did on a drag. Make
                -- sure one is free, or the test measures the fixture instead of the fallback.
                local untyped = untypedAccessorySlot()
                assertNotNil(untyped, 'the accessory strip has an untyped slot')
                local strip = PocketAddr(source, 'accessory', untyped)
                if exports.whip_core:GetItemAt(strip) then
                    pcall(exports.whip_core.StoreTake, exports.whip_core, strip)
                end

                -- 'inventory', not merely truthy: 'ground' would mean the fallback never found
                -- the accessory strip.
                local where, err = exports.whip_core:AddItem(source, 'food', 1)
                assertEqual(where, 'inventory', 'AddItem kept it on the player: ' .. tostring(err))

                -- The player container is full and holds no food to stack onto, so the item
                -- can only have landed in a LATER container. Asserting that specifically is
                -- the point: "it went somewhere" passes even when the fallback never fires.
                assertNil(exports.whip_core:FindItem(source, 'food', 'player'),
                    'nothing was forced into the full player container')
                assertNotNil(exports.whip_core:FindItem(source, 'food', 'accessory'),
                    'AddItem fell through to the accessory container')

                -- Clean up NOW rather than only in teardown: the next test fills the inventory
                -- itself and must start from the fillers being gone.
                RemoveAllOf(source, '_test_filler')
                RemoveAllOf(source, 'food')
            end,
        },
        {
            name = 'AddItem drops at the feet when EVERY container is full',
            fn = function(source, ctx)
                -- The failsafe: whip never destroys an item because there was nowhere to put
                -- it. Note what is asserted — not just "succeeded", but that the item
                -- genuinely exists in the world, and that it did NOT also end up in a pocket.
                --
                -- The success-on-ground contract is the load-bearing part: a drop answers
                -- 'ground' (09-24; it was `true, reason, 'ground'`), never false. Callers write
                -- `if not where then <undo> end`, so a drop reported as failure would make them
                -- refund a completed transaction or drop a second copy.
                --
                -- Assumes Config.DropOnFullInventory is at its default of true. A server that
                -- turned it off will see this fail, which is the correct signal — the failsafe
                -- genuinely is not running. (whip_core's Config is not readable from here:
                -- every resource gets its own Lua state, so `Config` in this file is
                -- whip_test's own table.)
                exports.whip_core:RegisterItem('_test_filler', {
                    name = 'Filler', weight = 0.01, type = 'misc', stack = false, maxStack = 1,
                })
                exports.whip_core:RegisterItem('_test_overflow', {
                    name = 'Overflow', weight = 0.01, type = 'misc', stack = false, maxStack = 1,
                })
                RemoveAllOf(source, '_test_filler')
                RemoveAllOf(source, '_test_overflow')

                -- Fill every slot that COULD take an ordinary item, asking whip for the shape rather
                -- than assuming it.
                --
                -- NOT a typed accessory slot (the run's Medkit slot). It refuses anything but its
                -- own item on every path now, StoreGive included — so the filler cannot go in,
                -- and the overflow item could not land there either. "Every container is full"
                -- means every slot that would accept the overflow, which is exactly this set.
                local typed = {}
                for slot, def in pairs(exports.whip_core:GetAccessorySlots() or {}) do
                    if def.accepts then typed[slot] = true end
                end
                local function takesAnything(c, i)
                    return not (c == 'accessory' and typed[i])
                end

                -- (09-24: GetPlayerContainers / GetContainerSlots / GetSlotData / PlaceItemAt were
                -- removed — GetPockets, GetPocketSlots, and GetItemAt / StoreGive by address.)
                local containers = exports.whip_core:GetPockets()
                for _, c in ipairs(containers) do
                    local n = exports.whip_core:GetPocketSlots(c) or 0
                    for i = 1, n do
                        local addr = PocketAddr(source, c, i)
                        if takesAnything(c, i) and not exports.whip_core:GetItemAt(addr) then
                            exports.whip_core:StoreGive(addr, '_test_filler', 1)
                        end
                    end
                end
                for _, c in ipairs(containers) do
                    local n = exports.whip_core:GetPocketSlots(c) or 0
                    for i = 1, n do
                        if takesAnything(c, i) then
                            -- assertOk, not assertNotNil: GetItemAt answers `false, reason` for a
                            -- bad address, and false is not nil.
                            local held, heldErr = exports.whip_core:GetItemAt(PocketAddr(source, c, i))
                            assertOk(held, heldErr,
                                ('%s slot %d occupied before the overflow test'):format(c, i))
                        end
                    end
                end

                noteGroundPos(ctx, source)
                local pos = GetEntityCoords(GetPlayerPed(source))
                -- THREE of an item that does not stack: three piles of one (Josh, 5 Oct 2026 — "20
                -- mags on the floor, I should see 20 slots filled"), not one pile of three.
                local where, err = exports.whip_core:AddItem(source, '_test_overflow', 3)

                assertOk(where, err, 'a drop reports SUCCESS — callers must not undo their transaction')
                assertEqual(where, 'ground', 'the answer says where it actually went')
                assertEqual(exports.whip_core:GetItemCount(source, '_test_overflow') or 0, 0,
                    'nothing was forced into a container that had no room')

                local nearby = exports.whip_core:GetGroundItemsNearby(pos.x, pos.y, pos.z, 10) or {}
                local piles, total, oversized = 0, 0, 0
                for _, n in ipairs(nearby) do
                    if n.item == '_test_overflow' then
                        piles, total = piles + 1, total + (n.amount or 0)
                        if (n.amount or 0) > 1 then oversized = oversized + 1 end
                    end
                end
                assertEqual(total, 3, 'all three exist in the world — none destroyed, none doubled')
                assertEqual(piles, 3, 'one pile each: an item that does not stack lands in stacks of one')
                assertEqual(oversized, 0, 'no pile holds more than the item stacks to')
                -- (The ground items and every filler are removed in teardown.)
            end,
        },
    }
})
