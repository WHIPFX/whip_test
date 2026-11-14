-- ============================================
-- Item Movement — the real event path
--
-- WHY THIS MODULE EXISTS
-- Moving an item is the most-exercised code path in the framework at runtime and had zero
-- tests. The suite drove only 6 of whip_core's SecureEvents and not one of them was a move,
-- use, drop, pickup or purchase — everything went through exports, which bypass the
-- validation, locking and persistence that the real client path goes through.
--
-- Originally written against `whip_core:server:moveItem`. That event has been deleted: the
-- client now fires `storeMove` for every player-container drag, so testing moveItem would
-- have been testing code nothing calls. What these tests are ABOUT is unchanged — merging,
-- swapping, weight and conservation — because that logic never lived in the event. It lives
-- in Stores.move, and the event is only how a client reaches it.
--
-- 25_storemove covers the addressing and authorization layer. This module stays focused on
-- the move semantics themselves.
--
-- Every test here drives the ACTUAL net event a client would fire, then asserts two things:
--   1. the item is where it should be, and
--   2. the TOTAL count across every container is unchanged.
--
-- (2) is the point. A move that destroys an item, duplicates it, or drops a container from
-- a copy still satisfies "the destination slot has the item" — it fails conservation. That
-- single invariant is what would have caught the shop-overflow destruction and the missing
-- accessory container, and it is the cheapest general detector available.
--
-- EVERY TEST SEEDS ITS OWN FIXTURE, IN SLOTS IT HAS PROVED EMPTY. The first version chained
-- them — test 2 moved whatever test 1 had left in slot 5 — so one failure cascaded down the
-- module, and the fixed low slots meant any item another module left behind turned a move
-- into a SWAP, failing "source slot cleared" for a reason that had nothing to do with moving.
-- ============================================

local TEST_ITEM  = '_test_move'
local OTHER_ITEM = '_test_move_b'   -- the swap partner; was 'food', which this module then leaked

--- Total quantity of the test item across all three player containers.
local function totalAcross(source)
    return exports.whip_core:GetItemCount(source, TEST_ITEM) or 0
end

--- Fire the real move event as a client would, and wait for the SERVER to finish with it.
---@param mode string|nil   'move' (default), 'one' or 'split'
---@param amount number|nil 0 = the whole slot
local function move(source, fromC, fromS, toC, toS, mode, amount)
    return ClientExecWait(source, 'whip_core:server:storeMove', 3000,
        { kind = fromC, slot = fromS }, { kind = toC, slot = toS }, amount or 0, mode or 'move', 0)
end

--- Assert the last move was REFUSED, and for the reason we meant.
---
--- "Nothing moved" stopped being proof of a refusal. readMoveEnds returns `nil, nil` for a
--- same-address move, which the movers convert to SUCCESS with no mutation — so an unchanged
--- inventory is now the signature of a successful no-op as well as of a rejection. Checking the
--- recorded reason is the only thing that still separates them.
---
--- Same helper 25_storemove uses; duplicated rather than shared because these modules are loaded
--- independently and neither owns the other.
local function assertRefused(expect)
    local reason = exports.whip_core:__TestLastReject('whip_core:server:storeMove')
    assertNotNil(reason, 'storeMove recorded a rejection')
    assertTrue(reason:lower():find(expect:lower(), 1, true) ~= nil,
        ('rejected for the expected reason (wanted ~"%s", got "%s")'):format(expect, tostring(reason)))
end

--- Reserve a player slot at the far end of the container, and prove it is empty first
--- (24_placement's claim idiom). Low slots are where other modules and real items congregate.
local function claim(source, n)
    local slots = exports.whip_core:GetPocketSlots('player')
    assertNotNil(slots, 'player slot count is known')
    local slot = slots - n + 1
    assertTrue(slot >= 1, ('player has room for reserved slot #%d'):format(n))
    -- 09-24: by address (RemoveItemFromSlot / GetSlotData were removed). Clearing an empty slot
    -- answers false, 'Empty slot', which is fine here.
    pcall(exports.whip_core.StoreTake, exports.whip_core, PocketAddr(source, 'player', slot))
    assertNil(exports.whip_core:GetItemAt(PocketAddr(source, 'player', slot)),
        ('player slot %d is empty before the test seeds it'):format(slot))
    return slot
end

--- An accessory slot that takes ANY item, cleared and proved empty.
---
--- A strip slot may be typed — runner.lua makes slot 4 bandage-only for the run — so a hardcoded
--- slot is only right for one config. Asking is.
local function claimAccessory(source)
    local free
    for slot, def in pairs(exports.whip_core:GetAccessorySlots() or {}) do
        if not def.accepts and (not free or slot < free) then free = slot end
    end
    assertNotNil(free, 'the accessory strip has a slot that accepts anything')
    pcall(exports.whip_core.StoreTake, exports.whip_core, PocketAddr(source, 'accessory', free))
    assertNil(exports.whip_core:GetItemAt(PocketAddr(source, 'accessory', free)),
        ('accessory slot %d is empty before the test seeds it'):format(free))
    return free
end

--- What is in one of the tester's pocket slots: `{ item, amount, metadata }`, nil when empty, or
--- `false, reason` for a slot that does not exist. 09-24: GetSlotData(source, container, slot) was
--- removed; this is GetItemAt on the pocket's address, which answers the same three ways.
local function slotAt(source, container, slot)
    return exports.whip_core:GetItemAt(PocketAddr(source, container, slot))
end

RegisterTestModule({
    order    = 23,
    category = 'Moves',

    setup = function(source, ctx)
        exports.whip_core:RegisterItem(TEST_ITEM, {
            name = 'Test Move Item', desc = 'movement fixture',
            weight = 0.1, type = 'misc', stack = true, maxStack = 10,
        })
        exports.whip_core:RegisterItem(OTHER_ITEM, {
            name = 'Test Move Partner', desc = 'movement fixture (swap partner)',
            weight = 0.1, type = 'misc', stack = true, maxStack = 10,
        })

        local p = exports.whip_core:GetPlayer(source)
        assertNotNil(p, 'setup: GetPlayer')
        ctx.charId = p.charId

        RemoveAllOf(source, TEST_ITEM)
        RemoveAllOf(source, OTHER_ITEM)
    end,

    teardown = function(ctx, source)
        if not source then return end
        RemoveAllOf(source, TEST_ITEM)
        RemoveAllOf(source, OTHER_ITEM)
    end,

    tests = {
        {
            name = 'Move within player container preserves the total',
            fn = function(source, ctx)
                RemoveAllOf(source, TEST_ITEM)
                local from, to = claim(source, 1), claim(source, 2)
                SeedSlot(source, 'player', from, TEST_ITEM, 3)
                assertEqual(totalAcross(source), 3, 'seeded 3')

                assertTrue(move(source, 'player', from, 'player', to), 'the server answered the move')
                assertLastReject('whip_core:server:storeMove', nil, 'the move was accepted')

                local moved = slotAt(source, 'player', to)
                assertNotNil(moved, 'item arrived at the destination slot')
                assertEqual(moved.item, TEST_ITEM, 'correct item at destination')
                assertEqual(moved.amount, 3, 'amount intact')
                assertNil(slotAt(source, 'player', from), 'source slot cleared')
                assertEqual(totalAcross(source), 3, 'total conserved')
            end,
        },
        {
            name = 'Move player -> accessory preserves the total',
            fn = function(source, ctx)
                -- Was player -> backpack. With the backpack retired, 'accessory' is the only
                -- other container a character is guaranteed to carry, so it is what a
                -- cross-container move has to be tested against.
                --
                -- The accessory container was invisible to GetInventory and to ten
                -- hand-rolled weights payloads. A move INTO it must still conserve.
                RemoveAllOf(source, TEST_ITEM)
                local from, acc = claim(source, 1), claimAccessory(source)
                SeedSlot(source, 'player', from, TEST_ITEM, 3)

                assertTrue(move(source, 'player', from, 'accessory', acc), 'the server answered the move')
                assertLastReject('whip_core:server:storeMove', nil, 'the move was accepted')

                local moved = slotAt(source, 'accessory', acc)
                assertNotNil(moved, 'item arrived in accessory')
                assertEqual(moved.amount, 3, 'amount intact')
                assertNil(slotAt(source, 'player', from), 'left the player container')
                assertEqual(totalAcross(source), 3, 'accessory counts toward the total')
            end,
        },
        {
            name = 'Move accessory -> player preserves the total',
            fn = function(source, ctx)
                -- The return leg, which is not the same code path: leaving a container tests
                -- the vacate-and-delete side, and the accessory is the container most likely
                -- to be forgotten by it. Seeded straight into the strip, so it does not depend
                -- on the test above having left anything there.
                RemoveAllOf(source, TEST_ITEM)
                local acc, to = claimAccessory(source), claim(source, 1)
                SeedSlot(source, 'accessory', acc, TEST_ITEM, 3)

                assertTrue(move(source, 'accessory', acc, 'player', to), 'the server answered the move')
                assertLastReject('whip_core:server:storeMove', nil, 'the move was accepted')

                local moved = slotAt(source, 'player', to)
                assertNotNil(moved, 'item came back out of the accessory')
                assertEqual(moved.amount, 3, 'amount intact')
                assertNil(slotAt(source, 'accessory', acc),
                    'the vacated accessory slot was cleared')
                assertEqual(totalAcross(source), 3, 'total conserved leaving the container')
            end,
        },
        {
            name = 'Swap between two occupied slots preserves both items',
            fn = function(source, ctx)
                RemoveAllOf(source, TEST_ITEM)
                RemoveAllOf(source, OTHER_ITEM)
                local a, b = claim(source, 1), claim(source, 2)
                SeedSlot(source, 'player', a, TEST_ITEM, 1)
                SeedSlot(source, 'player', b, OTHER_ITEM, 2)

                assertTrue(move(source, 'player', a, 'player', b), 'the server answered the swap')
                assertLastReject('whip_core:server:storeMove', nil, 'the swap was accepted')

                local atA = slotAt(source, 'player', a)
                local atB = slotAt(source, 'player', b)
                assertNotNil(atA, 'the first slot is still occupied after the swap')
                assertNotNil(atB, 'the second slot is still occupied after the swap')
                assertEqual(atA.item, OTHER_ITEM, 'items exchanged places')
                assertEqual(atA.amount, 2, 'the partner kept its amount')
                assertEqual(atB.item, TEST_ITEM, 'items exchanged places')
                assertEqual(atB.amount, 1, 'the dragged item kept its amount')

                assertEqual(totalAcross(source), 1, 'test item conserved through swap')
                assertEqual(exports.whip_core:GetItemCount(source, OTHER_ITEM) or 0, 2,
                    'other item conserved through swap')
            end,
        },
        {
            name = 'Move from an empty slot is REFUSED, and changes nothing',
            fn = function(source, ctx)
                RemoveAllOf(source, TEST_ITEM)
                local empty, dest = claim(source, 1), claim(source, 2)
                -- The refusal comes from readMoveEnds (the shared preamble all three movers go
                -- through), not from the mover bodies.
                move(source, 'player', empty, 'player', dest)

                -- The reason FIRST. Without it, this test cannot tell a refusal from the
                -- same-address success case, which is also "nothing happened".
                assertRefused('No item in source slot')
                assertNil(slotAt(source, 'player', dest),
                    'nothing conjured at the destination')
                assertEqual(totalAcross(source), 0, 'total unchanged by a rejected move')
            end,
        },
        {
            name = 'Move to an out-of-range slot is REFUSED and conserves the total',
            fn = function(source, ctx)
                -- A slot past the real container is still a well-formed ADDRESS (the 'addr' type
                -- only insists on a positive integer), so the store's own bounds must refuse it.
                -- Those bounds live in readMoveEnds now — Inventory.moveItem is not on this path
                -- at all. Asked, not assumed: the slot count is configuration.
                RemoveAllOf(source, TEST_ITEM)
                local from = claim(source, 1)
                SeedSlot(source, 'player', from, TEST_ITEM, 2)
                local past = exports.whip_core:GetPocketSlots('player') + 10

                move(source, 'player', from, 'player', past)

                assertRefused('Invalid slot number')
                local still = slotAt(source, 'player', from)
                assertEqual(still and still.amount, 2, 'item stayed in its original slot')
                -- FALSE, not nil — and the assertion gets sharper for it. The slot is past the
                -- end of the container, so GetItemAt (GetSlotData until 09-24) refuses the ADDRESS
                -- rather than reporting an empty slot, which is what nil means. Until the refusals
                -- started answering false, both readings were the same value and this line passed
                -- whether the slot was empty or did not exist at all.
                local data, why = slotAt(source, 'player', past)
                assertFalse(data, 'the slot is refused as an address, not reported as empty')
                assertEqual(why, 'Invalid slot', 'and the reason now survives the export boundary')
                assertEqual(totalAcross(source), 2, 'total unchanged by an invalid move')
            end,
        },
        {
            -- NEW, and the reason both tests above needed a reason check: a same-address move is
            -- now a SUCCESSFUL no-op rather than an error. That is deliberate — it is the guard
            -- that stopped the item printer, where moving a slot onto itself read a stale copy of
            -- its own contents and minted the difference.
            name = 'A move onto its own slot succeeds and mints nothing',
            fn = function(source, ctx)
                RemoveAllOf(source, TEST_ITEM)
                local slot = claim(source, 1)
                SeedSlot(source, 'player', slot, TEST_ITEM, 3)

                move(source, 'player', slot, 'player', slot)

                -- ACCEPTED, and that has to be said: an unchanged slot is also what a refusal
                -- leaves behind, so without this the test passes if the guard is replaced by
                -- an error.
                assertLastReject('whip_core:server:storeMove', nil, 'a same-slot move is a successful no-op')
                local after = slotAt(source, 'player', slot)
                assertNotNil(after, 'the slot still holds its item')
                assertEqual(after.amount, 3, 'the stack did not grow')
                assertEqual(totalAcross(source), 3, 'nothing was conjured')
            end,
        },
        {
            -- THE MODES THAT ACTUALLY PRINTED. Stores.move was never the printer — it opened with
            -- a same-address early return long before readMoveEnds existed. moveOne and
            -- moveAmount had no such guard: right-clicking an item onto its own slot ('one')
            -- turned a stack of N into N+1, once per click, and the stock UI reached it by
            -- accident. The whole-slot test above cannot see that bug at all.
            name = "A same-slot move in 'one' and 'split' modes mints nothing either",
            fn = function(source, ctx)
                RemoveAllOf(source, TEST_ITEM)
                local slot = claim(source, 1)
                SeedSlot(source, 'player', slot, TEST_ITEM, 3)

                move(source, 'player', slot, 'player', slot, 'one')
                assertLastReject('whip_core:server:storeMove', nil, "a same-slot 'one' is a successful no-op")
                local afterOne = slotAt(source, 'player', slot)
                assertEqual(afterOne and afterOne.amount, 3, "'one' onto its own slot did not add a unit")

                -- A split needs an amount (commitMove refuses 'split' without one), and a partial
                -- one — the whole stack would be handed to Stores.move instead of moveAmount.
                move(source, 'player', slot, 'player', slot, 'split', 1)
                assertLastReject('whip_core:server:storeMove', nil, "a same-slot 'split' is a successful no-op")
                local afterSplit = slotAt(source, 'player', slot)
                assertEqual(afterSplit and afterSplit.amount, 3, "'split' onto its own slot did not add a unit")

                assertEqual(totalAcross(source), 3, 'nothing was conjured by either mode')
            end,
        },
        {
            name = 'Player inventory on disk matches the cache after a sequence of moves',
            fn = function(source, ctx)
                -- The independent oracle. Every other assertion in this module reads the
                -- same in-memory cache the move just wrote; this one goes to the database.
                --
                -- COMPARED SLOT BY SLOT, not as a sum. A total matches just as well when a row
                -- sits in the wrong slot, or when a vacated slot's row survived and the arriving
                -- one was never written — two different bugs that add up to the right number.
                RemoveAllOf(source, TEST_ITEM)
                local a, b = claim(source, 1), claim(source, 2)
                local acc = claimAccessory(source)
                SeedSlot(source, 'player', a, TEST_ITEM, 5)

                move(source, 'player', a, 'player', b)
                move(source, 'player', b, 'accessory', acc)
                move(source, 'accessory', acc, 'player', a, 'split', 2)

                FlushPersistence(source)

                -- FindAllItems: every stack in every pocket, each with its address — rather than a
                -- scan of GetInventory over a pocket list written out here by hand.
                local cache = {}
                for _, found in ipairs(exports.whip_core:FindAllItems(source, TEST_ITEM) or {}) do
                    cache[('%s:%d'):format(found.addr.sub, found.addr.slot)] = found.amount
                end

                local disk = {}
                for _, row in ipairs(DbQuery(
                    'SELECT `container`, `slot`, `amount` FROM `character_inventory` WHERE `charId` = ? AND `item` = ?',
                    { ctx.charId, TEST_ITEM })) do
                    disk[('%s:%d'):format(row.container, row.slot)] = row.amount
                end

                -- The expected shape, so a wrong-but-consistent state cannot pass either.
                assertEqual(cache['player:' .. a], 2, 'the split landed back in the first slot')
                assertEqual(cache['accessory:' .. acc], 3, 'the remainder stayed in the accessory')

                for key, amount in pairs(cache) do
                    assertEqual(disk[key], amount, ('disk agrees with the cache at %s'):format(key))
                end
                for key, amount in pairs(disk) do
                    assertEqual(cache[key], amount, ('no stray row on disk at %s'):format(key))
                end
                assertEqual(totalAcross(source), 5, 'total conserved across the sequence')
            end,
        },
    },
})
