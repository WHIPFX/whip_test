-- ============================================
-- Failure Paths — what happens when the database says no
--
-- WHY THIS MODULE EXISTS
--
-- Every other test in this suite calls a healthy export with valid arguments against a
-- healthy database. That is why the suite reported 284 passing while a bug sat in the code
-- that DELETED A CHARACTER'S ENTIRE INVENTORY whenever a read hiccuped:
--
--   Inventory.load caught the read error and returned an empty-but-PRESENT cache. The very
--   next save then emitted `DELETE FROM character_inventory WHERE charId = ?` because, as
--   far as it could tell, the character owned nothing.
--
-- You cannot express that from a test without a way to make the read fail. whip_core now
-- exposes a gated, one-shot fault injector (server/testseams.lua) for exactly this.
--
-- These tests assert against the DATABASE, not against the cache the code just wrote. That
-- independence is the entire point — an assertion that reads back the same in-memory table
-- the call under test populated can never disagree with it.
-- ============================================

local TEST_ITEM = '_test_faultpath'

--- How many rows a container holds on disk.
local function containerRows(containerId)
    return #DbQuery('SELECT `slot` FROM `container_inventory` WHERE `containerId` = ?', { containerId })
end

RegisterTestModule({
    order    = 20,
    category = 'Failure Paths',

    setup = function(source, ctx)
        local p = exports.whip_core:GetPlayer(source)
        assertNotNil(p, 'setup: GetPlayer')
        ctx.charId = p.charId

        exports.whip_core:RegisterItem(TEST_ITEM, {
            name = 'Fault Path Fixture', desc = 'failure-path fixture',
            weight = 0.1, type = 'misc', stack = true, maxStack = 20,
        })
    end,

    teardown = function(ctx, source)
        -- Always disarm, even if a test failed midway — a left-armed fault would make the
        -- next unrelated read fail.
        pcall(exports.whip_core.__TestSetDbFaultMode, exports.whip_core, nil)
        if ctx.containerId then
            pcall(exports.whip_core.DeleteContainer, exports.whip_core, ctx.containerId)
        end
        if source then RemoveAllOf(source, TEST_ITEM) end
    end,

    tests = {
        {
            name = 'Seam arms and disarms',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:__TestSetDbFaultMode('inventory_read'), 'armed')
                assertEqual(exports.whip_core:__TestGetDbFaultMode(), 'inventory_read', 'reports armed mode')
                assertTrue(exports.whip_core:__TestSetDbFaultMode(nil), 'disarmed')
                assertNil(exports.whip_core:__TestGetDbFaultMode(), 'reports disarmed')
            end,
        },
        {
            -- THE test. This is the one that was missing.
            --
            -- NAMED FOR WHAT IT CAN PROVE. It was "does NOT delete the character rows", but
            -- __TestLoadInventory only calls Inventory.load — nothing installs the result or saves
            -- it — so the rows could not have been deleted here whatever load returned. The wipe
            -- came from an empty table being SAVED; the contract that prevents it is that a failed
            -- read is nil, and that is what this pins. The row count stays as a sanity check.
            name = 'A failed inventory read answers nil, never an empty inventory',
            fn = function(source, ctx)
                SeedSlot(source, 'player', 1, TEST_ITEM, 4)
                assertDbScalar(
                    'SELECT CAST(COALESCE(SUM(`amount`), 0) AS SIGNED) FROM `character_inventory` WHERE `charId` = ? AND `item` = ?',
                    { ctx.charId, TEST_ITEM }, 4, 'fixture is on disk before the fault')

                -- Make the next inventory read fail, then trigger one.
                assertTrue(exports.whip_core:__TestSetDbFaultMode('inventory_read'), 'armed')
                local loaded = exports.whip_core:__TestLoadInventory(ctx.charId)
                assertNil(exports.whip_core:__TestGetDbFaultMode(), 'the read consumed the fault')

                -- Contract: nil means "the read failed", never "the character owns nothing".
                -- Returning an empty table here is what caused the wipe.
                assertNil(loaded, 'a failed read returns nil, not an empty inventory')

                assertDbScalar(
                    'SELECT CAST(COALESCE(SUM(`amount`), 0) AS SIGNED) FROM `character_inventory` WHERE `charId` = ? AND `item` = ?',
                    { ctx.charId, TEST_ITEM }, 4, 'rows still on disk')

                -- And an unfaulted read of the same character answers with a table.
                local good = exports.whip_core:__TestLoadInventory(ctx.charId)
                assertType(good, 'table', 'a healthy read answers with a table')
            end,
        },
        {
            name = 'A failed container read refuses the open and leaves the stash contents on disk',
            fn = function(source, ctx)
                -- Must be within reach: openContainer distance-checks against the player
                -- (events_containers.lua). A container at the world origin can never be
                -- opened, so the open this test is about would be refused before it ever read.
                local c = CreateContainerNearPlayer(source, {
                    name = '_test_faultpath_ctr', type = 'stash',
                    slots = 5, maxWeight = 20.0, locked = false,
                })
                ctx.containerId = c.containerId
                local storeId = 'container:' .. tostring(c.containerId)

                -- Assert the container actually opened, not merely that the client acked. The seed
                -- no longer needs it open (09-24: StoreGive names the stash by address and loads it
                -- on demand), but this open is the control: it shows this container CAN open.
                OpenContainerOrFail(source, c.containerId)
                local seeded, seedErr = exports.whip_core:StoreGive(
                    { kind = 'container', id = c.containerId, slot = 1 }, TEST_ITEM, 3)
                assertOk(seeded, seedErr, 'seeded the container')
                ClientCloseContainer(source, c.containerId)
                FlushPersistence(source)

                local before = containerRows(c.containerId)
                assertEqual(before, 1, 'container contents are on disk')

                -- UNLOADED, so the next open has to READ — the read is what the fault fails. A
                -- cache still in memory would open without touching the database, the fault would
                -- never fire, and the open would succeed.
                exports.whip_core:__TestUnloadContainer(c.containerId)
                assertFalse(exports.whip_core:__TestContainerCached(c.containerId), 'nothing cached before the open')

                -- Deliberately NOT OpenContainerOrFail: this open is SUPPOSED to be refused.
                assertTrue(exports.whip_core:__TestSetDbFaultMode('container_read'), 'armed')
                ClientOpenContainer(source, c.containerId)
                assertNil(exports.whip_core:__TestGetDbFaultMode(), 'the open tried to read and consumed the fault')

                -- Membership of THIS store, not "the" open one — a player can have several stores
                -- open, and GetOpenContainer (removed 09-24) answered with whichever pairs() reached
                -- first.
                assertFalse(exports.whip_core:__TestIsViewer(source, storeId),
                    'a container whose contents could not be read must not open')
                assertFalse(exports.whip_core:__TestContainerCached(c.containerId),
                    'and no empty cache was installed in its place')

                FlushPersistence(source)
                assertEqual(containerRows(c.containerId), before, 'a failed container read did not empty the stash')
            end,
        },
        {
            -- Guards the Stage 0 change: a container store CANNOT BE RESOLVED while its contents
            -- are not loaded, so nothing can write to it. Before it, a failed load plus a write
            -- auto-created a one-entry cache, and the stale-row DELETE then removed every other
            -- slot.
            --
            -- Replaces "Container contents survive a delete-and-recreate cycle", which deleted and
            -- recreated nothing — it re-read the rows the previous test had left.
            name = 'A container whose contents are not loaded cannot be written to',
            fn = function(source, ctx)
                if not ctx.containerId then skip('previous test did not create a container') end

                assertFalse(exports.whip_core:__TestContainerCached(ctx.containerId), 'not loaded')
                assertFalse(exports.whip_core:__TestMarkContainerDirty(ctx.containerId),
                    'an unloaded container cannot be addressed for a write')
                assertFalse(exports.whip_core:__TestIsDirty('container:' .. tostring(ctx.containerId)),
                    'so nothing was queued for it')

                FlushPersistence(source)
                local rows = DbQuery(
                    'SELECT `slot`, `item`, `amount` FROM `container_inventory` WHERE `containerId` = ?',
                    { ctx.containerId }
                )
                assertEqual(#rows, 1, 'contents still present')
                assertEqual(rows[1].item, TEST_ITEM, 'and they are the items we put there')
                assertEqual(rows[1].amount, 3, 'in full')
            end,
        },
    },
})
