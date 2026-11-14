-- ============================================
-- Test: DB Persistence Round-Trip
-- Verifies that inventory, ground items, containers,
-- and player data actually reach the database.
--
-- NOTE: exports.whip_core:GetPlayer() returns a serialized
-- COPY, not the live metatable object. Metatable methods
-- like :save(), :getCash(), :addCash() don't cross the
-- export boundary. Use standalone exports or direct DB
-- queries for verification.
--
-- SUMs are CAST to SIGNED in SQL: SUM() comes back from the driver as a DECIMAL, which arrives
-- as a string, and assertDbScalar compares exactly — '7' is not 7.
-- ============================================

local TEST_ITEMS = { '_test_persist', '_test_persist_del', '_test_persist_meta' }

--- A stat that declares persist, and one that declares it must NOT persist. Registered by this
--- module so the statuses test asserts on values it chose, not on whatever the real stats hold.
local PERSIST_STAT = '_test_persist_stat'
local SESSION_STAT = '_test_session_stat'

--- How much of an item this character has ON DISK, as a number.
local function dbAmountQuery()
    return 'SELECT CAST(COALESCE(SUM(`amount`), 0) AS SIGNED) AS `total` FROM `character_inventory` '
        .. 'WHERE `charId` = ? AND `item` = ?'
end

RegisterTestModule({
    order    = 16,
    category = 'Persistence',

    setup = function(source, ctx)
        local p = exports.whip_core:GetPlayer(source)
        assertNotNil(p, 'setup: GetPlayer')
        ctx.charId = p.charId
        ctx.healthBefore = exports.whip_core:GetStat(source, 'health')

        -- Register test-only items
        exports.whip_core:RegisterItem('_test_persist', {
            name   = 'Persist Test',
            weight = 0.1,
            type   = 'misc',
            stack  = true,
            maxStack = 100,
        })
        exports.whip_core:RegisterItem('_test_persist_del', {
            name = 'Delete Test', weight = 0.1, type = 'misc',
            stack = true, maxStack = 100,
        })
        exports.whip_core:RegisterItem('_test_persist_meta', {
            name = 'Meta Test', weight = 0.1, type = 'misc',
            stack = false, maxStack = 1,
        })

        -- Clean slate: remove any leftover test items from DB + cache
        for _, item in ipairs(TEST_ITEMS) do
            RemoveAllOf(source, item)
            DbQuery('DELETE FROM `character_inventory` WHERE `charId` = ? AND `item` = ?', { p.charId, item })
        end
    end,

    teardown = function(ctx, source)
        -- Unconditional: the negative control pauses the flush thread, and a test that errors
        -- between pausing and resuming would leave every LATER module running against a server
        -- that never writes anything back.
        pcall(exports.whip_core.__TestPauseFlushThread, exports.whip_core, false)
        pcall(exports.whip_core.__TestSetDbFaultMode, exports.whip_core, nil)

        if not source then return end

        -- The tester's own health, which two tests below move on purpose.
        if ctx.healthBefore then
            pcall(exports.whip_core.SetStat, exports.whip_core, source, 'health', ctx.healthBefore, 't16 restore')
        end

        -- RETIRING A PERSISTED STAT TAKES THREE STEPS, in this order, or it lives on the tester's
        -- row forever. getForSave CARRIES FORWARD any saved stat that is not registered, so a
        -- satellite being stopped does not wipe its players' values — which means simply
        -- unregistering ours would keep it in `statuses` for good. Registered as persist = false
        -- is the one state that DROPS it; then something that re-queues the row; then a flush to
        -- write it without the key. Only then can it be unregistered.
        --
        -- THE RE-QUEUE IS A METADATA MARK, as 39_stats_effects' purgeCarry does. It was a SetStat on
        -- the (now non-persisted) stat, which queues nothing — Stats.set only marks the row for a
        -- persisted stat — and this worked only because the health restore above had queued it.
        pcall(function()
            exports.whip_core:RegisterStat(PERSIST_STAT, { type = 'custom', default = 0, min = 0, max = 1000, persist = false })
            exports.whip_core:SetPlayerMetadata(source, '_test_t16_mark', GetGameTimer())
            FlushPersistence(source)
            exports.whip_core:SetPlayerMetadata(source, '_test_t16_mark', nil)
        end)
        pcall(exports.whip_core.__TestUnregisterStat, exports.whip_core, PERSIST_STAT)
        pcall(exports.whip_core.__TestUnregisterStat, exports.whip_core, SESSION_STAT)

        for _, item in ipairs(TEST_ITEMS) do RemoveAllOf(source, item) end
        if ctx._groundId then
            pcall(exports.whip_core.DeleteGroundItem, exports.whip_core, ctx._groundId)
        end
        for _, key in ipairs({ '_containerId', '_controlId' }) do
            if ctx[key] then
                pcall(ClientCloseContainer, source, ctx[key], 2000)
                pcall(exports.whip_core.DeleteContainer, exports.whip_core, ctx[key])
            end
        end
        for _, item in ipairs(TEST_ITEMS) do
            pcall(DbQuery, 'DELETE FROM `character_inventory` WHERE `charId` = ? AND `item` = ?',
                { ctx.charId, item })
        end
    end,

    tests = {
        -- ==========================================
        -- Inventory → DB
        -- ==========================================
        -- AddItem answers WHERE the item went — 'inventory' | 'ground' — or false, reason (09-24;
        -- it was `true, false|reason, placement`). 'inventory' is the one these tests need: an item
        -- dropped at the tester's feet never reaches character_inventory.
        {
            name = 'AddItem persists to character_inventory table',
            fn = function(source, ctx)
                local where, err = exports.whip_core:AddItem(source, '_test_persist', 7)
                assertEqual(where, 'inventory', 'AddItem put it in the pockets: ' .. tostring(err))
                assertDbScalar(dbAmountQuery(), { ctx.charId, '_test_persist' }, 7,
                    'DB amount matches AddItem amount')
            end,
        },
        {
            name = 'RemoveItem persists removal to DB',
            fn = function(source, ctx)
                local where, err = exports.whip_core:AddItem(source, '_test_persist_del', 5)
                assertEqual(where, 'inventory', 'AddItem 5 put them in the pockets: ' .. tostring(err))
                assertDbScalar(dbAmountQuery(), { ctx.charId, '_test_persist_del' }, 5,
                    'items exist in DB before removal')

                local rok = exports.whip_core:RemoveItem(source, '_test_persist_del', 3)
                assertTrue(rok, 'RemoveItem 3 succeeded')
                assertDbScalar(dbAmountQuery(), { ctx.charId, '_test_persist_del' }, 2,
                    'DB reflects partial removal (5 - 3 = 2)')
            end,
        },
        {
            name = 'AddItem with metadata persists metadata to DB',
            fn = function(source, ctx)
                local meta = { serial = 'ABC123', tier = 3 }
                local where, err = exports.whip_core:AddItem(source, '_test_persist_meta', 1, meta)
                assertEqual(where, 'inventory', 'AddItem with meta put it in the pockets: ' .. tostring(err))
                FlushPersistence(source)

                -- Should be exactly one row with this unique item key
                local rows = DbQuery(
                    'SELECT `metadata` FROM `character_inventory` WHERE `charId` = ? AND `item` = ?',
                    { ctx.charId, '_test_persist_meta' }
                )
                assertEqual(#rows, 1, 'exactly one row in DB')

                local dbMeta = json.decode(rows[1].metadata)
                assertNotNil(dbMeta, 'Metadata decoded from DB')
                assertEqual(dbMeta.serial, 'ABC123', 'Metadata.serial preserved in DB')
                assertEqual(dbMeta.tier, 3, 'Metadata.tier preserved in DB')
            end,
        },

        -- ==========================================
        -- Cash → DB
        -- ==========================================
        {
            name = 'Cash item persists to DB after AddItem',
            fn = function(source, ctx)
                -- Flushed BEFORE the baseline too: read unflushed, `before` could be behind the
                -- cache, and the old `>=` below hid exactly that.
                FlushPersistence(source)
                local before = tonumber(DbQuery(dbAmountQuery(), { ctx.charId, 'cash' })[1].total) or 0

                local where, err = exports.whip_core:AddItem(source, 'cash', 500)
                assertEqual(where, 'inventory', 'AddItem cash put it in the pockets: ' .. tostring(err))
                assertDbScalar(dbAmountQuery(), { ctx.charId, 'cash' }, before + 500,
                    'cash on disk went up by exactly 500')

                assertTrue(exports.whip_core:RemoveItem(source, 'cash', 500), 'test cash taken back')
            end,
        },

        -- ==========================================
        -- Ground Items → DB
        -- ==========================================
        {
            name = 'CreateGroundItem persists to ground_items table',
            fn = function(source, ctx)
                -- The insert is synchronous (ground.lua), so there is nothing to flush first.
                local gItem, err = exports.whip_core:CreateGroundItem(
                    '_test_persist', 3, { origin = 'test' },
                    100.0, 200.0, 30.0, 0.0, ctx.charId
                )
                assertOk(gItem, err, 'CreateGroundItem')
                ctx._groundId = gItem.id

                local rows = DbQuery(
                    'SELECT `item`, `amount`, `metadata` FROM `ground_items` WHERE `id` = ?',
                    { gItem.id }
                )
                assertEqual(#rows, 1, 'Exactly one row in DB')
                assertEqual(rows[1].item, '_test_persist', 'Item key matches in DB')
                assertEqual(rows[1].amount, 3, 'Amount matches in DB')

                local dbMeta = json.decode(rows[1].metadata)
                assertEqual(dbMeta.origin, 'test', 'Metadata preserved in DB')
            end,
        },
        {
            name = 'DeleteGroundItem removes from ground_items table',
            fn = function(source, ctx)
                -- A MISSING FIXTURE IS A FAILURE, NOT A PASS. This was `if not ctx._groundId then
                -- return end`, so if the earlier test never created the ground item this one
                -- reported green having deleted nothing and asserted nothing.
                assertNotNil(ctx._groundId, 'the earlier test left a ground item to delete')

                exports.whip_core:DeleteGroundItem(ctx._groundId)
                assertDbRowCount('SELECT `id` FROM `ground_items` WHERE `id` = ?', { ctx._groundId }, 0,
                    'Ground item row removed from DB')
                ctx._groundId = nil
            end,
        },

        -- ==========================================
        -- Container Inventory → DB
        -- ==========================================
        {
            name = 'Container item persists to container_inventory table',
            fn = function(source, ctx)
                -- Created NEAR THE PLAYER. It used to be placed at (0, 0, 50) — the world
                -- origin, fifty metres up — which openContainer refuses on its distance
                -- check. The container therefore never opened, the placement below always
                -- failed, and the test fell into an escape hatch that asserted only that the
                -- container row existed. A test named "item persists to container_inventory"
                -- never once looked at container_inventory.
                local cDef = CreateContainerNearPlayer(source, {
                    name      = '_test_persist_container',
                    type      = 'stash',
                    slots     = 5,
                    maxWeight = 50,
                })
                ctx._containerId = cDef.containerId

                -- The give below no longer needs the container open (09-24: StoreGive loads it on
                -- demand). The open and close stay because they are the trip a player makes, and
                -- the negative control below repeats this exact sequence.
                OpenContainerOrFail(source, cDef.containerId)

                -- StoreGive CREATES the item in the named store; it does not move one from the
                -- player. (This used to AddItem to the player first and check HasItem, which was
                -- setup for a move that never happened — and left two items in the pockets.)
                -- It names the container by address; PlaceItemAt(source, 'container', ...) meant
                -- "whatever this player has open", and was removed 09-24.
                --
                -- No escape hatch either. This used to be `if placeOk then ... else ... end`, where
                -- the else branch asserted the container row existed in `containers` and called
                -- that a pass. A conditional assertion is not an assertion — whichever branch runs,
                -- the test reports success, so it can only ever be green.
                local placeOk, placeErr = exports.whip_core:StoreGive(
                    { kind = 'container', id = cDef.containerId, slot = 1 }, '_test_persist', 2)
                -- assertOk: StoreGive answers the slot NUMBER, which assertTrue would reject.
                assertOk(placeOk, placeErr, 'StoreGive into the container')

                ClientCloseContainer(source, cDef.containerId, 3000)
                FlushPersistence(source)

                local rows = DbQuery(
                    'SELECT `item`, `amount` FROM `container_inventory` WHERE `containerId` = ? AND `slot` = 1',
                    { cDef.containerId }
                )
                assertEqual(#rows, 1, 'Row exists in container_inventory')
                assertEqual(rows[1].item, '_test_persist', 'Item key matches in container DB')
                assertEqual(rows[1].amount, 2, 'Amount matches in container DB')
            end,
        },
        {
            name = 'NEGATIVE CONTROL: with the write faulted, the row is absent and still owed',
            fn = function(source, ctx)
                -- The point of this test is not the framework. It is the test ABOVE.
                --
                -- "Row exists in container_inventory" only means something if the same query,
                -- run when persistence did NOT happen, comes back empty. Otherwise a green
                -- tick proves nothing — which is exactly how the previous version of that
                -- test passed for months while the container was never even open.
                --
                -- So: do the identical sequence with the write deliberately failed, and
                -- assert the opposite outcome. If BOTH tests pass, the assertion above
                -- discriminates. If this one fails, the one above is worthless.
                local cDef = CreateContainerNearPlayer(source, {
                    name      = '_test_persist_negative',
                    type      = 'stash',
                    slots     = 5,
                    maxWeight = 50,
                })
                -- Recorded BEFORE anything can fail, so teardown can always find it.
                ctx._controlId = cDef.containerId

                -- WHY THE FLUSH THREAD IS PAUSED
                --
                -- Containers are write-behind now, so a single injected fault no longer
                -- PREVENTS a write — it defers it, and the retry is supposed to succeed. That
                -- is the design working, not a defect. So this control has to hold the queue
                -- still and fault the ONE explicit flush; otherwise the background thread
                -- lands the row a second later and the control reports the write as permitted
                -- when it was only early.
                exports.whip_core:__TestPauseFlushThread(true)

                OpenContainerOrFail(source, cDef.containerId)

                -- Queued, not written — nothing has touched the database yet. (By address, as above.)
                local placeOk, placeErr = exports.whip_core:StoreGive(
                    { kind = 'container', id = cDef.containerId, slot = 1 }, '_test_persist', 2)
                assertOk(placeOk, placeErr, 'placed into the control container')

                -- Fault the one flush that could put this row on disk. flushNow makes exactly
                -- one attempt, so a one-shot fault lands on it rather than being spent by a
                -- batch and then recovered by the isolated retry.
                assertTrue(exports.whip_core:__TestSetDbFaultMode('transaction'), 'transaction fault armed')
                assertFalse(exports.whip_core:__TestFlushContainerNow(cDef.containerId),
                    'the faulted flush reported failure')
                exports.whip_core:__TestSetDbFaultMode(nil)

                local rows = DbQuery(
                    'SELECT `item` FROM `container_inventory` WHERE `containerId` = ? AND `slot` = 1',
                    { cDef.containerId }
                )
                assertEqual(#rows, 0,
                    'a faulted write leaves NOTHING on disk — so the positive test above is real')

                -- And the write is still OWED, not dropped: a failed flush puts the unit back.
                assertTrue(exports.whip_core:__TestIsDirty('container:' .. tostring(cDef.containerId)),
                    'the container is still queued for its write')

                exports.whip_core:__TestPauseFlushThread(false)
            end,
        },

        -- ==========================================
        -- Player Data → DB (the character row, write-behind)
        -- ==========================================
        {
            -- WAS RED AGAINST CORRECT CODE, then weak. It asserted `hunger` and `thirst` were in the
            -- column until both were deliberately made session-only; its replacement read whatever
            -- the last flush happened to write, and judged "registered" by whether a stat was in the
            -- live cache — which a STOPPED satellite's stat still is, so it would have gone red the
            -- first time one was stopped during a run.
            --
            -- So it sets values it chose, on stats it registered, and reads them back.
            name = 'The statuses column holds the stats that persist, and not the ones that do not',
            fn = function(source, ctx)
                local ok, why = exports.whip_core:RegisterStat(PERSIST_STAT,
                    { type = 'custom', default = 0, min = 0, max = 1000, persist = true })
                assertOk(ok, why, 'a persisted test stat registered')
                ok, why = exports.whip_core:RegisterStat(SESSION_STAT,
                    { type = 'custom', default = 0, min = 0, max = 1000, persist = false })
                assertOk(ok, why, 'a session-only test stat registered')

                exports.whip_core:SetStat(source, PERSIST_STAT, 421)
                exports.whip_core:SetStat(source, SESSION_STAT, 77)

                assertDbScalar(
                    ("SELECT CAST(JSON_EXTRACT(`statuses`, '$.%s') AS SIGNED) FROM `characters` WHERE `charId` = ?")
                        :format(PERSIST_STAT),
                    { ctx.charId }, 421, 'the persisted stat reached disk with its value')
                assertDbScalar(
                    ("SELECT JSON_CONTAINS_PATH(`statuses`, 'one', '$.%s') FROM `characters` WHERE `charId` = ?")
                        :format(SESSION_STAT),
                    { ctx.charId }, 0, 'the session-only stat did not')

                -- Every declared stat reached disk, read from the REGISTRY rather than hardcoded —
                -- a stat quietly not saving is a real, quiet bug class.
                local expected = exports.whip_core:__TestPersistedStatNames()
                assertNotNil(expected, 'the stat registry is readable')
                local statuses = json.decode(DbQuery(
                    'SELECT `statuses` FROM `characters` WHERE `charId` = ?', { ctx.charId })[1].statuses)
                assertType(statuses, 'table', 'statuses decoded from DB')
                for name in pairs(expected) do
                    assertNotNil(statuses[name],
                        ('stat "%s" declares persist and must be in the column'):format(name))
                end

                -- Vitals have their own columns and must never be duplicated into statuses.
                assertNil(statuses.health, 'health is a column, not a status')
                assertNil(statuses.armour, 'armour is a column, not a status')
            end,
        },
        {
            -- THE GUARD FOR 09-23's REGRESSION. A misplaced `local function writeRows` made every
            -- character-row save throw, and health, statuses and metadata stopped reaching disk —
            -- while this test, which asserted only `health >= 100` against whatever was already
            -- there, stayed green. It now writes a value nothing else would and reads it back.
            name = "A change to the tester's health reaches the characters row",
            fn = function(source, ctx)
                local target = (ctx.healthBefore == 150) and 160 or 150
                exports.whip_core:SetStat(source, 'health', target)
                assertEqual(exports.whip_core:GetStat(source, 'health'), target, 'set in memory')
                assertDbScalar('SELECT `health` FROM `characters` WHERE `charId` = ?', { ctx.charId },
                    target, 'and written to the row')

                exports.whip_core:SetStat(source, 'health', ctx.healthBefore)
            end,
        },
        {
            -- A failed character-row write must stay owed, not be dropped. Since one save stage 4
            -- (2 Oct 2026) the row is written in the player's unit with their pockets and position, so
            -- the write to fail is that unit's transaction ('transaction'; the background thread uses
            -- its own fault name and is paused besides).
            name = 'A character-row write that fails is kept, and lands on the next flush',
            fn = function(source, ctx)
                -- Drain first, so nothing else is pending. Then PAUSE the background save thread, so
                -- the failed write stays visible until this test lets it go.
                FlushPersistence(source)
                local onDisk = DbQuery('SELECT `health` FROM `characters` WHERE `charId` = ?',
                    { ctx.charId })[1].health
                local target = (onDisk == 170) and 180 or 170

                exports.whip_core:__TestPauseFlushThread(true)   -- teardown resumes it unconditionally

                assertTrue(exports.whip_core:__TestSetDbFaultMode('transaction'), 'fault armed')
                exports.whip_core:SetStat(source, 'health', target)
                assertFalse(exports.whip_core:__TestFlushPersistence(source),
                    'the faulted flush reported failure')
                assertNil(exports.whip_core:__TestGetDbFaultMode(), 'the fault was consumed by the row write')

                -- Nothing else can write the row while the threads are paused, so the failed write is
                -- visible as a failure: the row still holds the old value.
                assertEqual(DbQuery('SELECT `health` FROM `characters` WHERE `charId` = ?',
                    { ctx.charId })[1].health, onDisk, 'the faulted write did not reach the row')

                exports.whip_core:__TestPauseFlushThread(false)

                -- Still owed: the next flush writes it.
                assertDbScalar('SELECT `health` FROM `characters` WHERE `charId` = ?', { ctx.charId },
                    target, 'the next flush landed the change')

                exports.whip_core:SetStat(source, 'health', ctx.healthBefore)
            end,
        },
    }
})
