-- ============================================
-- Targeted placement — the conjure/destroy primitives
--
-- WHY THIS MODULE EXISTS
--
-- StoreGive and StoreTake are how every satellite hands out a reward or consumes a material,
-- and they are deliberately NOT moves: one creates an item from nothing, the other destroys one.
-- Because they conserve nothing by construction, the only thing standing between them and
-- duplicated or vanished items is the set of rules they apply on the way in.
--
-- 09-24: this module was written against PlaceItemAt / TakeItemFrom / RemoveItemFromSlot, which
-- were removed. StoreGive / StoreTake / GetItemAt take an ADDRESS (PocketAddr for the pockets) and
-- reach the same Stores.place / Stores.take, so every rule below is still asked the same question.
--
-- Those rules used to be written out three times inside PlaceItemAt itself — once per branch
-- for player, container and vehicle storage — and the three copies disagreed:
--
--   * only the container branch checked allowedItems; the vehicle branch checked it for key
--     storage alone, and the player branch not at all,
--   * the player branch checked weight BEFORE testing whether the slot was occupied, the
--     other two checked it after, so a merge onto an existing stack skipped weight entirely,
--   * none of the three compared metadata before merging two stacks together.
--
-- All three now route through Stores.place / Stores.take. These tests pin the behaviour that
-- unification is supposed to guarantee, so a future edit to one code path cannot quietly
-- reintroduce a difference between the seven store types.
-- ============================================

local FIXTURE = '_test_place'
local HEAVY   = '_test_place_heavy'

--- The container this module seeds into. Was the backpack, which is gone — it is now an
--- ordinary item (a duffle bag) rather than a container every character carries, so a test
--- cannot assume one exists. `player` is the only container guaranteed present, and at 30
--- slots it has the headroom this module needs.
local SCRATCH = 'player'

--- Claim a slot in the tester's inventory that is guaranteed empty before the test runs.
---
--- The first version of this module hardcoded player slots 20-26 and every seeding placement
--- failed: the player container was 15 slots, so all seven were out of range and Stores.place
--- correctly refused them. Slot counts are configuration, so a test must ask rather than
--- assume — and this module runs twenty-fourth, on an inventory the earlier modules have been
--- filling, so it must also clear whatever it is about to write to.
---@param source number
---@param n number  1-based index into this module's private run of slots
---@return number slot
local function claim(source, n)
    local slots = exports.whip_core:GetPocketSlots(SCRATCH)
    assertNotNil(slots, SCRATCH .. ' slot count is known')
    -- Work down from the end: low slots are where other modules and real items congregate.
    local slot = slots - n + 1
    assertTrue(slot >= 1, ('%s has room for slot #%d'):format(SCRATCH, n))
    -- 09-24: by address (RemoveItemFromSlot / GetSlotData were removed). Clearing an empty slot
    -- answers false, 'Empty slot', which is fine here.
    pcall(exports.whip_core.StoreTake, exports.whip_core, PocketAddr(source, SCRATCH, slot))
    assertNil(exports.whip_core:GetItemAt(PocketAddr(source, SCRATCH, slot)),
        ('%s slot %d is empty before the test seeds it'):format(SCRATCH, slot))
    return slot
end

RegisterTestModule({
    order    = 24,
    category = 'Placement',

    setup = function(source, ctx)
        exports.whip_core:RegisterItem(FIXTURE, {
            name = 'Placement Fixture', desc = 'placement fixture',
            weight = 0.1, type = 'misc', stack = true, maxStack = 10,
        })
        -- Heavy enough that a handful of them exceeds any container's allowance.
        exports.whip_core:RegisterItem(HEAVY, {
            name = 'Placement Ballast', desc = 'placement fixture',
            weight = 5.0, type = 'misc', stack = true, maxStack = 100,
        })

        local p = exports.whip_core:GetPlayer(source)
        assertNotNil(p, 'setup: GetPlayer')

        RemoveAllOf(source, FIXTURE)
        RemoveAllOf(source, HEAVY)

        ctx.charId    = p.charId
        ctx.accWeight = exports.whip_core:GetPocketMaxWeight('accessory')
    end,

    teardown = function(ctx, source)
        if not source then return end
        RemoveAllOf(source, FIXTURE)
        RemoveAllOf(source, HEAVY)
    end,

    tests = {
        {
            name = "StoreGive honours the TARGETED container's weight limit",
            fn = function(source, ctx)
                -- The bug this pins: the capacity question used to be "does this fit anywhere
                -- across the player's three containers", which is a different question from
                -- "does this fit in the accessory slot I aimed at". Aiming directly at a small
                -- container walked straight past that container's own allowance.
                assertNotNil(ctx.accWeight, 'accessory maxWeight is configured')
                assertTrue(ctx.accWeight < 9999, 'accessory has a real weight limit to test against')

                -- AN UNTYPED SLOT, so the weight limit is the only thing that can refuse. This aimed
                -- at slot 1 — the phone slot — and once PlaceItemAt (now StoreGive) learned the strip's
                -- per-slot rule it refused for the item type instead, passing without weight being asked.
                local target
                for slot, def in pairs(exports.whip_core:GetAccessorySlots() or {}) do
                    if not def.accepts and (not target or slot < target) then target = slot end
                end
                assertNotNil(target, 'the accessory strip has an untyped slot to test weight on')

                RemoveAllOf(source, HEAVY)
                local addr = PocketAddr(source, 'accessory', target)
                pcall(exports.whip_core.StoreTake, exports.whip_core, addr)

                -- One more than the accessory could hold even when completely empty.
                -- 09-24: StoreGive refuses more than one slot's maxStack up front ('only N fit in one
                -- slot'), before Stores.place is asked. HEAVY's maxStack of 100 keeps this amount
                -- under that, so weight is still the rule that answers.
                local overAmount = math.floor(ctx.accWeight / 5.0) + 1
                local ok, why = exports.whip_core:StoreGive(addr, HEAVY, overAmount)

                assertFalse(ok, 'placing past the accessory weight limit was rejected')
                -- The reason pins WHICH rule refused it. The slot is chosen untyped precisely so
                -- nothing but weight can say no; if that ever stops being true, this is where it shows.
                assertEqual(why, 'Too heavy', 'refused by the weight limit, not some other rule')
                assertNil(exports.whip_core:GetItemAt(addr),
                    'the rejected placement left the slot empty')
                assertEqual(exports.whip_core:GetItemCount(source, HEAVY) or 0, 0,
                    'a rejected placement conjured nothing anywhere else either')
            end,
        },
        {
            name = "StoreGive honours a typed accessory slot's accepts rule",
            fn = function(source, ctx)
                -- The strip's per-slot rule was only enforced on the drag path; PlaceItemAt (now
                -- StoreGive), give and AddItem's fallback could all put anything in the phone slot.
                local typed
                for slot, def in pairs(exports.whip_core:GetAccessorySlots() or {}) do
                    if def.accepts and def.accepts ~= FIXTURE then typed = slot break end
                end
                assertNotNil(typed, 'the accessory strip has a typed slot')

                local addr = PocketAddr(source, 'accessory', typed)
                local before = exports.whip_core:GetItemAt(addr)
                RemoveAllOf(source, FIXTURE)
                assertFalse(exports.whip_core:StoreGive(addr, FIXTURE, 1),
                    'the fixture was refused by a slot typed for something else')
                local after = exports.whip_core:GetItemAt(addr)
                assertEqual(after and after.item, before and before.item, 'the typed slot is unchanged')
                assertEqual(exports.whip_core:GetItemCount(source, FIXTURE) or 0, 0,
                    'nothing was conjured anywhere else')
            end,
        },
        {
            name = 'StoreGive refuses to merge stacks whose metadata differs',
            fn = function(source, ctx)
                -- Merging on item key alone silently discarded one side's state. For a plain
                -- fixture that is invisible; for a whip_gunny magazine it is the round count.
                local slot = claim(source, 1)
                local addr = PocketAddr(source, SCRATCH, slot)

                -- 09-24: StoreGive answers the slot NUMBER, so assertOk (assertTrue wants exactly true).
                local seeded, seedErr = exports.whip_core:StoreGive(addr, FIXTURE, 2, { serial = 'AAA' })
                assertOk(seeded, seedErr, 'seeded a stack with metadata')

                local ok, why = exports.whip_core:StoreGive(addr, FIXTURE, 2, { serial = 'BBB' })
                assertFalse(ok, 'a differently-stated stack did not merge')
                -- 09-24: the reason too. StoreGive has refusals of its own before Stores.place is asked
                -- (unknown item, amount, a slot's maxStack), so "refused" alone no longer proves it was
                -- the metadata rule that said no.
                assertEqual(why, 'Different item state', 'refused by the metadata rule, not some other one')

                local data = exports.whip_core:GetItemAt(addr)
                assertNotNil(data, 'the original stack survived')
                assertEqual(data.amount, 2, 'the original stack was not grown')
                assertEqual(data.metadata and data.metadata.serial, 'AAA',
                    'the original metadata was not overwritten')
            end,
        },
        {
            name = 'StoreGive merges onto a matching stack exactly once',
            fn = function(source, ctx)
                RemoveAllOf(source, FIXTURE)
                local slot = claim(source, 2)
                local addr = PocketAddr(source, SCRATCH, slot)

                local first, firstErr = exports.whip_core:StoreGive(addr, FIXTURE, 3)
                assertOk(first, firstErr, 'seeded a stack')
                local second, secondErr = exports.whip_core:StoreGive(addr, FIXTURE, 4)
                assertOk(second, secondErr, 'merged onto it')
                -- 09-24: the answer is the slot it landed in — the one we named, not a second one.
                assertEqual(second, slot, 'StoreGive answered the slot it merged into')

                local data = exports.whip_core:GetItemAt(addr)
                assertNotNil(data, 'slot still holds the stack')
                assertEqual(data.amount, 7, 'amounts added, not doubled or replaced')
                assertEqual(exports.whip_core:GetItemCount(source, FIXTURE), 7,
                    'nothing was conjured into a second slot as well')
            end,
        },
        {
            name = 'StoreGive will not overflow maxStack',
            fn = function(source, ctx)
                RemoveAllOf(source, FIXTURE)
                local slot = claim(source, 3)
                local addr = PocketAddr(source, SCRATCH, slot)

                local seeded, seedErr = exports.whip_core:StoreGive(addr, FIXTURE, 8)
                assertOk(seeded, seedErr, 'seeded 8 of a 10-max stack')

                local ok, why = exports.whip_core:StoreGive(addr, FIXTURE, 5)
                assertFalse(ok, 'placing 5 more onto an 8/10 stack was rejected')
                -- 09-24: the reason too. 5 is under the 10 StoreGive allows into one slot up front, so
                -- this must be Stores.place's MERGE check answering — the rule this test is about.
                assertEqual(why, 'Stack is full', 'refused by the merge check, not the up-front one')

                local data = exports.whip_core:GetItemAt(addr)
                assertEqual(data and data.amount, 8, 'the stack was not clamped up to 10 either')
            end,
        },
        {
            name = 'StoreGive rejects an out-of-range slot without conjuring anything',
            fn = function(source, ctx)
                -- Bounds belong to the store, not to a constant in the caller: the player
                -- container is 30 slots and the accessory 5, and PlaceItemAt (now StoreGive) used
                -- to clamp with a hardcoded 50 rather than ask.
                RemoveAllOf(source, FIXTURE)

                local slots = exports.whip_core:GetPocketSlots('player')
                assertNotNil(slots, 'player slot count is known')

                -- 09-24: by address. Slot 0 is now refused by the address check itself (a slot must
                -- be a positive integer), and a slot past the end by the store's bounds in Stores.place.
                assertFalse(exports.whip_core:StoreGive(PocketAddr(source, 'player', slots + 1), FIXTURE, 1),
                    'a slot past the end was rejected')
                assertFalse(exports.whip_core:StoreGive(PocketAddr(source, 'player', 0), FIXTURE, 1),
                    'slot 0 was rejected rather than clamped up to slot 1')
                assertEqual(exports.whip_core:GetItemCount(source, FIXTURE) or 0, 0,
                    'neither rejection conjured the item somewhere else')
            end,
        },
        {
            name = 'StoreTake removes a partial amount and leaves the rest intact',
            fn = function(source, ctx)
                RemoveAllOf(source, FIXTURE)
                local slot = claim(source, 4)
                local addr = PocketAddr(source, SCRATCH, slot)

                local seeded, seedErr = exports.whip_core:StoreGive(addr, FIXTURE, 6, { serial = 'KEEP' })
                assertOk(seeded, seedErr, 'seeded 6')

                -- 09-24: StoreTake answers what it TOOK, { item, amount, metadata } (TakeItemFrom
                -- answered true), so assertOk — and the answer can be checked as well.
                local taken, takeErr = exports.whip_core:StoreTake(addr, 2)
                assertOk(taken, takeErr, 'took 2 of 6')
                assertEqual(taken.amount, 2, 'the answer names the amount taken')

                local data = exports.whip_core:GetItemAt(addr)
                assertNotNil(data, 'the remainder is still there')
                assertEqual(data.amount, 4, 'exactly the requested amount was destroyed')
                assertEqual(data.metadata and data.metadata.serial, 'KEEP',
                    'a partial take did not drop the metadata')
            end,
        },
        {
            name = 'StoreTake refuses to remove more than the slot holds',
            fn = function(source, ctx)
                RemoveAllOf(source, FIXTURE)
                local slot = claim(source, 5)
                local addr = PocketAddr(source, SCRATCH, slot)

                local seeded, seedErr = exports.whip_core:StoreGive(addr, FIXTURE, 3)
                assertOk(seeded, seedErr, 'seeded 3')

                assertFalse(exports.whip_core:StoreTake(addr, 9),
                    'taking 9 from a stack of 3 was rejected')

                local data = exports.whip_core:GetItemAt(addr)
                assertEqual(data and data.amount, 3,
                    'the over-take neither emptied the slot nor went negative')
            end,
        },
        {
            name = 'StoreTake on an empty slot is rejected',
            fn = function(source, ctx)
                local slot = claim(source, 6)
                assertFalse(exports.whip_core:StoreTake(PocketAddr(source, SCRATCH, slot), 1),
                    'taking from an empty slot was rejected')
            end,
        },
        {
            -- WAS "place then take round-trips to disk" — a whole placement and a whole take,
            -- which 02_inventory already proves row for row. What nothing proved is the PARTIAL
            -- take on disk: the in-memory test above shows the remainder keeps its metadata, and
            -- a partial take is exactly the write an incremental save could get half right (the
            -- amount updated, the metadata column rewritten from a stale copy, or the row left
            -- alone because "the item is still there").
            name = 'A partial take reaches disk with its metadata, and the last take deletes the row',
            fn = function(source, ctx)
                -- The primitives are the only inventory mutation whip_gunny and whip_phone
                -- perform, so what they leave in the database is what a satellite's state
                -- actually is after a restart.
                RemoveAllOf(source, FIXTURE)
                local slot = claim(source, 7)
                local addr = PocketAddr(source, SCRATCH, slot)

                local placed, placeErr = exports.whip_core:StoreGive(addr, FIXTURE, 6, { serial = 'DISK' })
                assertOk(placed, placeErr, 'placed 6')
                FlushPersistence(source)
                local taken, takeErr = exports.whip_core:StoreTake(addr, 2)
                assertOk(taken, takeErr, 'took 2 of 6')

                assertDbScalar(
                    'SELECT `amount` FROM `character_inventory` WHERE `charId` = ? AND `container` = ? AND `slot` = ?',
                    { ctx.charId, SCRATCH, slot }, 4, 'the partial take reached the database')
                assertDbScalar(
                    "SELECT JSON_UNQUOTE(JSON_EXTRACT(`metadata`, '$.serial')) FROM `character_inventory` "
                        .. 'WHERE `charId` = ? AND `container` = ? AND `slot` = ?',
                    { ctx.charId, SCRATCH, slot }, 'DISK', 'and the remainder kept its metadata on disk')

                local last, lastErr = exports.whip_core:StoreTake(addr, 4)
                assertOk(last, lastErr, 'took the last 4')
                assertDbRowCount(
                    'SELECT 1 FROM `character_inventory` WHERE `charId` = ? AND `container` = ? AND `slot` = ?',
                    { ctx.charId, SCRATCH, slot }, 0, 'emptying the slot deleted the row')
            end,
        },
    },
})
