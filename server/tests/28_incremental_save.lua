-- ============================================
-- Incremental inventory writes
--
-- WHY THIS MODULE EXISTS
--
-- Saving an inventory used to rewrite every row the character owned. Changing one number
-- inside one item's metadata — firing a round, moving cash into a wallet — rewrote all
-- seventeen of their items. Sixty rounds was roughly a thousand row writes.
--
-- The save now diffs against the last state that was CONFIRMED WRITTEN and emits only what
-- differs. The danger is entirely in the comparison: anything the diff fails to notice is
-- never written, and NOTHING REPORTS IT. Silent item loss, the worst class of bug here.
--
-- So these tests measure the SIZE of each write. A test that only asserted "the item is on
-- disk" would pass identically whether the optimisation happened, silently regressed to full
-- rewrites, or stopped writing changed rows at all.
--
-- WHY "LAST WRITE" AND NOT "PENDING WRITE"
--
-- The first version of this module asked what the NEXT save would write, and every test
-- failed with zero. The only observable is what a write actually emitted, after the fact.
--
-- WHERE THAT WRITE HAPPENS CHANGED (S2b/W3)
--
-- These tests originally measured straight after the mutation, because every mutation
-- committed before it returned. Player inventories are write-behind now: a mutation enqueues,
-- and the transaction happens at the FLUSH. So each test settles first, performs the one
-- change under test, and measures the flush — see settle() and measure() below.
--
-- Measuring at the mutation would now be worse than useless: the "wrote nothing" assertions
-- would pass because nothing had been written YET, which is a different fact entirely.
--
-- THE WALLET CASE IS THE ONE THAT MATTERS
--
-- A wallet keeps its whole contents in its own metadata:
--     {"slots":[{"item":"cash","amount":1}]}
-- Two wallets are the same item with the same amount, differing ONLY there. Compare item and
-- amount alone and every wallet on the server looks identical to every other one — putting
-- cash in a wallet would write nothing and silently revert on the next restart. That test is
-- the acceptance criterion for this whole change.
-- ============================================

local ITEM   = '_test_incr'
local WALLET = '_test_incr_wallet'

--- What the most recent save actually wrote.
local function lastWrite()
    return exports.whip_core:__TestLastWrite() or {}
end

local function save(source)
    return exports.whip_core:__TestSaveInventory(source)
end

--- Land everything outstanding, discard the record of it, and STOP any other writer.
---
--- Leaves a clean baseline so the next measurement reports only the change under test.
---
--- The pause is not incidental. `_lastWrite` is a single global holding whatever built most
--- recently, and the background flush thread builds once a second whether a test is looking or
--- not. Leave it running and a measurement can read a write it did not cause — which fails
--- intermittently, on whichever test happens to straddle a tick, and looks for all the world
--- like the diff logic being wrong.
local function settle(source)
    FlushPersistence(source)
    exports.whip_core:__TestPauseFlushThread(true)
    exports.whip_core:__TestClearLastWrite()
end

--- Land what is outstanding and report the write it produced.
---
--- WHY THE MEASUREMENT MOVED (S2b/W3)
---
--- This module used to read the write straight after the mutation, because every mutation
--- committed before it returned. Player inventories are write-behind now: a mutation enqueues
--- and the transaction happens at the FLUSH. Reading immediately afterwards would find no
--- write at all — and the "wrote nothing" assertions would pass for entirely the wrong
--- reason, while the ones expecting a row would fail against nil.
---
--- The measurement is still the same fact, taken at the point the write actually occurs.
---
--- Resumes the background flush that settle() stopped, so the pause never outlives the one
--- measurement it exists to protect.
local function measure(source)
    FlushPersistence(source)          -- explicit flushes still run while the thread is paused
    local w = lastWrite() or {}
    exports.whip_core:__TestPauseFlushThread(false)
    return w
end

--- Restart the background flush without taking a measurement.
---
--- For the tests that settle() to get a clean baseline but never call measure(). Without it
--- the pause leaks past the end of the test and every later one runs on a server that writes
--- only when asked — which is not the configuration they are meant to be testing.
local function resume()
    exports.whip_core:__TestPauseFlushThread(false)
end

--- The raw value of one character_inventory column, WITHOUT flushing first — measure() has
--- already flushed, and assertDbScalar would flush again and could not show a value mid-state.
local function storedColumn(charId, column, container, slot)
    local rows = DbQuery(
        ('SELECT `%s` AS v FROM `character_inventory` WHERE `charId` = ? AND `container` = ? AND `slot` = ?'):format(column),
        { charId, container, slot })
    return rows[1] and rows[1].v
end

RegisterTestModule({
    order    = 28,
    category = 'Incremental Save',

    setup = function(source, ctx)
        -- (A `skip` here for "seams disabled" could never fire: indexing an export that exists
        -- always gives something callable, and /test now refuses to start without the seams.)
        exports.whip_core:RegisterItem(ITEM, {
            name = 'Incremental Fixture', desc = 'incremental save fixture',
            weight = 0.1, type = 'misc', stack = true, maxStack = 10,
        })
        -- Stands in for a wallet: contents live in its own metadata.
        exports.whip_core:RegisterItem(WALLET, {
            name = 'Incremental Wallet', desc = 'metadata-carrying fixture',
            weight = 0.1, type = 'misc', stack = false, maxStack = 1,
        })

        local p = exports.whip_core:GetPlayer(source)
        assertNotNil(p, 'setup: GetPlayer')
        ctx.charId = p.charId
        ctx.unit = 'player:' .. p.charId
        ctx.containers = {}   -- every container a test makes; teardown deletes them
        RemoveAllOf(source, ITEM)
        RemoveAllOf(source, WALLET)
    end,

    teardown = function(ctx, source)
        -- Unconditional, and first. settle() stops the background flush and measure() starts
        -- it again; a test erroring between the two would otherwise leave every LATER module
        -- running against a server whose only writes are the ones tests ask for explicitly.
        pcall(exports.whip_core.__TestPauseFlushThread, exports.whip_core, false)
        pcall(exports.whip_core.__TestSetDbFaultMode, exports.whip_core, nil)

        -- DURABILITY TOO. Two tests pin a kind write-through, and each used to put it back only
        -- on the line after its assertions — so one failure left the player (or container) kind
        -- write-through for the rest of the run, and 29's durability tripwire then blamed 29.
        -- A test records what it changed in ctx as it changes it; whatever is still recorded
        -- here was never put back.
        for kindId, previous in pairs(ctx.restoreDurability or {}) do
            pcall(exports.whip_core.__TestSetDurability, exports.whip_core, kindId, previous)
        end

        if not source then return end
        for _, id in ipairs(ctx.containers or {}) do
            pcall(ClientCloseContainer, source, id, 3000)
            pcall(exports.whip_core.DeleteContainer, exports.whip_core, id)
        end
        RemoveAllOf(source, ITEM)
        RemoveAllOf(source, WALLET)
    end,

    tests = {
        {
            name = 'A save with nothing changed writes NOTHING',
            fn = function(source, ctx)
                settle(source)                     -- bring the snapshot up to date
                save(source)                       -- and again, having changed nothing

                local w = measure(source)
                assertEqual(w.queries, 0,
                    ('an unchanged inventory wrote %s queries'):format(tostring(w.queries)))
            end,
        },
        {
            name = 'An unchanged save still reports SUCCESS',
            fn = function(source, ctx)
                -- Inventory.save used to treat an empty query set as FAILURE, because the old
                -- builder always emitted at least a DELETE. Diffing makes emptiness the normal
                -- case, and every caller branches on this return.
                --
                -- PINNED WRITE-THROUGH, because the branch under test is otherwise unreachable.
                -- The player kind is write-behind now, so a save takes the deferred path — mark
                -- dirty, return true — and never builds any queries at all. Left alone, this
                -- assertion could only fail if the store stopped resolving, which is a different
                -- test entirely.
                --
                -- MEASURED, RESTORED, THEN JUDGED: an assertion raises, so a restore written after
                -- one only runs when nothing is wrong. Recorded in ctx as well, for teardown.
                local prev = exports.whip_core:__TestSetDurability('player', 'writeThrough')
                ctx.restoreDurability = { player = prev }
                settle(source)
                local saved = save(source)
                -- THIS UNIT, not the whole queue: __TestDirtyCount also counts character rows,
                -- which the stats tick marks on its own schedule and the pause does not stop.
                local owed  = exports.whip_core:__TestIsDirty(ctx.unit)
                if prev then exports.whip_core:__TestSetDurability('player', prev) end
                ctx.restoreDurability = nil

                assertTrue(saved, 'saving an unchanged inventory reported failure')
                assertFalse(owed, 'a write-through save committed rather than enqueuing')

                -- And the FLUSH of an unchanged inventory must report success too — that is
                -- where the empty query set is now actually handled. This half was always real.
                -- (FlushPersistence raises if it cannot land everything.)
                FlushPersistence(source)
                resume()
            end,
        },
        {
            name = 'Changing ONE slot writes ONE row, not the whole inventory',
            fn = function(source, ctx)
                -- The entire point. Without the diff this equals the character's full item
                -- count, and every other test in the suite still passes.
                SeedSlot(source, 'player', 9, ITEM, 3)
                settle(source)

                SeedSlot(source, 'player', 9, ITEM, 4)

                local w = measure(source)
                assertEqual(w.replaceRows, 1,
                    ('changing one slot wrote %s rows'):format(tostring(w.replaceRows)))
            end,
        },
        {
            name = 'METADATA-ONLY change is detected — the wallet case',
            fn = function(source, ctx)
                -- Same item, same amount, different contents. This is what carrying cash in a
                -- wallet looks like to the save path, and the case a naive diff misses.
                --
                -- Slot calls by address since 09-24 (RemoveItemFromSlot / PlaceItemAt were removed).
                -- Clearing an empty slot answers false, which is fine; StoreGive answers the slot
                -- NUMBER, so it is checked with assertOk rather than assertTrue.
                RemoveAllOf(source, WALLET)
                local addr = PocketAddr(source, 'player', 10)
                exports.whip_core:StoreTake(addr)
                local placed, placeErr = exports.whip_core:StoreGive(addr, WALLET, 1, { slots = {} })
                assertOk(placed, placeErr, 'seeded an empty wallet')
                settle(source)

                -- Put "cash" in it. Item and amount are untouched.
                assertTrue(exports.whip_core:SetItemMetadata(addr,
                    { slots = { { item = 'cash', amount = 500 } } }), 'metadata updated')

                local w = measure(source)
                assertEqual(w.replaceRows, 1,
                    'a metadata-only change MUST write a row — otherwise wallet contents never persist')

                -- And it must actually reach the database (measure() already flushed).
                local stored = storedColumn(ctx.charId, 'metadata', 'player', 10)
                assertNotNil(stored, 'wallet row exists on disk')
                assertTrue(tostring(stored):find('500', 1, true) ~= nil,
                    ('the wallet contents reached the database (got %s)'):format(tostring(stored)))
            end,
        },
        {
            name = 'NESTED metadata change is detected, not just the top level',
            fn = function(source, ctx)
                -- A shallow compare would see {slots=<table>} on both sides, find one key
                -- each, and call them equal. Moving cash BETWEEN wallet slots would then be
                -- invisible. The comparison has to recurse.
                RemoveAllOf(source, WALLET)
                local addr = PocketAddr(source, 'player', 11)
                exports.whip_core:StoreTake(addr)
                local placed, placeErr = exports.whip_core:StoreGive(addr, WALLET, 1,
                    { slots = { { item = 'cash', amount = 100 } } })
                assertOk(placed, placeErr, 'seeded')
                settle(source)

                -- Same shape, same key count, deeper value changed.
                assertTrue(exports.whip_core:SetItemMetadata(addr,
                    { slots = { { item = 'cash', amount = 250 } } }), 'metadata updated')

                local w = measure(source)
                assertEqual(w.replaceRows, 1,
                    'a change nested inside metadata MUST be detected')
            end,
        },
        {
            -- THE OTHER HALF OF THE SAME COMPARISON. A compare that goes by REFERENCE instead of
            -- by value would pass the test above — a new table is always "different" — and write
            -- a row on every save of every item whose metadata was ever re-set to what it already
            -- held. That is the full rewrite this module exists to prevent, reached a new way.
            name = 'An IDENTICAL nested table writes nothing — values are compared, not tables',
            fn = function(source, ctx)
                RemoveAllOf(source, WALLET)
                local addr = PocketAddr(source, 'player', 11)
                exports.whip_core:StoreTake(addr)
                local placed, placeErr = exports.whip_core:StoreGive(addr, WALLET, 1,
                    { slots = { { item = 'cash', amount = 100 } } })
                assertOk(placed, placeErr, 'seeded')
                settle(source)

                -- A brand-new table, equal in every value to the one already there.
                assertTrue(exports.whip_core:SetItemMetadata(addr,
                    { slots = { { item = 'cash', amount = 100 } } }), 'metadata re-set to the same value')

                local w = measure(source)
                assertEqual(w.replaceRows or 0, 0,
                    ('re-setting identical metadata wrote %s rows'):format(tostring(w.replaceRows)))
            end,
        },
        {
            name = 'Removing an item writes a DELETE for that slot alone',
            fn = function(source, ctx)
                SeedSlot(source, 'player', 12, ITEM, 2)
                settle(source)

                -- StoreTake by address (09-24: RemoveItemFromSlot was removed). Asserted now: the
                -- old pcall hid a refused take, which then read as a diff that wrote no DELETE.
                local taken, takeErr = exports.whip_core:StoreTake(PocketAddr(source, 'player', 12))
                assertOk(taken, takeErr, 'the slot was emptied')

                local w = measure(source)
                assertEqual(w.deleteRows, 1,
                    ('removing one item deleted %s rows'):format(tostring(w.deleteRows)))
                assertEqual(w.replaceRows, 0, 'a removal rewrites nothing')

                assertDbRowCount(
                    'SELECT 1 FROM `character_inventory` WHERE `charId` = ? AND `container` = ? AND `slot` = ?',
                    { ctx.charId, 'player', 12 }, 0, 'the row was deleted on disk')
            end,
        },
        {
            name = 'A CONTAINER writes only the changed slot',
            fn = function(source, ctx)
                -- Stashes matter more than a player here: the shop's stash declares a
                -- thousand slots, so moving one item was rewriting every row it held.
                --
                -- HOW THIS MEASURES A WRITE IT HAS NO SEAM FOR. There is no __TestLastWrite for a
                -- container, and the final amounts are the same whether one row was written or
                -- all of them — so the old version of this test passed under a full rewrite. A
                -- TRIPWIRE does the measuring instead: after both rows are on disk, slot 2's row
                -- is changed behind whip's back. An incremental save never touches slot 2, so the
                -- tripwire survives; a full rewrite puts slot 2 back to what the cache holds and
                -- erases it. The container is this test's own, so editing its row harms nothing.
                local c = CreateContainerNearPlayer(source, {
                    name = '_test_incr_ctr', slots = 20, maxWeight = 100.0,
                })
                ctx.containers[#ctx.containers + 1] = c.containerId
                OpenContainerOrFail(source, c.containerId)

                -- Two separate items in the container, so a full rewrite would be 2 rows.
                -- (StoreGive makes them from nothing; nothing needs to be in the pockets. It names the
                -- container by address since 09-24, when PlaceItemAt's "whatever this player has open"
                -- went, and answers the slot number — so assertOk, not assertTrue.)
                local function slotAddr(slot) return { kind = 'container', id = c.containerId, slot = slot } end
                local placed, placeErr = exports.whip_core:StoreGive(slotAddr(1), ITEM, 2)
                assertOk(placed, placeErr, 'first placed')
                placed, placeErr = exports.whip_core:StoreGive(slotAddr(2), ITEM, 2)
                assertOk(placed, placeErr, 'second placed')
                FlushPersistence(source)

                assertTrue(MySQL.update.await(
                    'UPDATE `container_inventory` SET `amount` = 77 WHERE `containerId` = ? AND `slot` = 2',
                    { c.containerId }) == 1, 'tripwire set on slot 2')

                -- Change only slot 1. (StoreTake since 09-24, when TakeItemFrom was removed; it answers
                -- the taken stack, not true.)
                local taken, takeErr = exports.whip_core:StoreTake(slotAddr(1), 1)
                assertOk(taken, takeErr, 'took one from slot 1')

                assertDbScalar(
                    'SELECT `amount` FROM `container_inventory` WHERE `containerId` = ? AND `slot` = ?',
                    { c.containerId, 1 }, 1, 'slot 1 updated on disk')
                assertDbScalar(
                    'SELECT `amount` FROM `container_inventory` WHERE `containerId` = ? AND `slot` = ?',
                    { c.containerId, 2 }, 77,
                    'slot 2 was NOT rewritten — a full rewrite would have put 2 back over the tripwire')

                ClientCloseContainer(source, c.containerId, 3000)
            end,
        },
        {
            name = 'An UNCHANGED container save reports success, not "contents not loaded"',
            fn = function(source, ctx)
                -- Containers.saveInventory used to infer "never loaded" from an empty query
                -- set. An unchanged container now produces none, so that inference had to be
                -- replaced with a direct cache check — otherwise every untouched stash would
                -- report itself as broken.
                local c = CreateContainerNearPlayer(source, {
                    name = '_test_incr_ctr2', slots = 10, maxWeight = 50.0,
                })
                ctx.containers[#ctx.containers + 1] = c.containerId
                OpenContainerOrFail(source, c.containerId)

                -- PINNED WRITE-THROUGH for the same reason as the player case above: the
                -- container kind is write-behind, so saveInventory marks dirty and returns true
                -- BEFORE building any queries — and the empty-query-set branch this test is named
                -- for is unreachable. Left alone it proved only that the cache was non-nil, which
                -- OpenContainerOrFail already guaranteed one line earlier.
                --
                -- Measured, restored, then judged — and recorded for teardown in between.
                local prev = exports.whip_core:__TestSetDurability('container', 'writeThrough')
                ctx.restoreDurability = { container = prev }
                local first  = exports.whip_core:__TestSaveContainer(c.containerId)
                local second = exports.whip_core:__TestSaveContainer(c.containerId)
                local owed   = exports.whip_core:__TestIsDirty('container:' .. tostring(c.containerId))
                if prev then exports.whip_core:__TestSetDurability('container', prev) end
                ctx.restoreDurability = nil

                assertTrue(first, 'first save')
                assertTrue(second, 'saving an unchanged container reported failure')
                assertFalse(owed, 'a write-through container save must not enqueue')

                -- The discriminator the test was missing: a container whose contents were NEVER
                -- loaded must still be refused. Without this, "returns true" proves nothing —
                -- the whole point is telling an unchanged container from an unloaded one.
                assertFalse(exports.whip_core:__TestSaveContainer(999999),
                    'an unloaded container must not report a successful save')

                ClientCloseContainer(source, c.containerId, 3000)
            end,
        },
        {
            name = 'A FAILED save does not advance the snapshot',
            fn = function(source, ctx)
                -- The retry property. If a commit fails the snapshot must stay put, so the
                -- next attempt re-emits everything changed since the last SUCCESS. Advancing
                -- it on failure would drop the change permanently and report nothing.
                SeedSlot(source, 'player', 13, ITEM, 5)
                settle(source)

                -- The mutation only ENQUEUES now, so the transaction — and therefore the
                -- failure — happens at the flush, and that is what the fault has to be armed
                -- against.
                assertTrue(exports.whip_core:SetItemMetadata(PocketAddr(source, 'player', 13),
                    { marker = 'survives-a-failed-save' }), 'the change was accepted')

                -- __TestFlushPlayerNow, not the interval flush. The fault is ONE-SHOT and the
                -- interval flush isolates a failed batch by retrying each unit alone — which
                -- would spend the fault on the first attempt and then succeed, leaving this
                -- test measuring an operation that never actually failed. flushNow makes
                -- exactly one commit attempt.
                assertTrue(exports.whip_core:__TestSetDbFaultMode('transaction'), 'fault armed')
                assertFalse(exports.whip_core:__TestFlushPlayerNow(source),
                    'the faulted flush reported failure')
                exports.whip_core:__TestSetDbFaultMode(nil)

                -- The retry must STILL have something to write — proof the snapshot did not
                -- move when the transaction failed.
                exports.whip_core:__TestClearLastWrite()
                assertTrue(exports.whip_core:__TestFlushPlayerNow(source), 'retry flushed')
                local w = lastWrite() or {}
                assertEqual(w.replaceRows, 1,
                    'after a failed save the change MUST be rewritten, not forgotten')

                local stored = storedColumn(ctx.charId, 'metadata', 'player', 13)
                assertTrue(tostring(stored):find('survives-a-failed-save', 1, true) ~= nil,
                    ('the change lost to the failed save reached disk on retry (got %s)')
                        :format(tostring(stored)))
                resume()
            end,
        },
    },
})
