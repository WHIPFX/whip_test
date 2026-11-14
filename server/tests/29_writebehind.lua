-- ============================================
-- Write-behind scheduling
--
-- WHY THIS MODULE EXISTS
--
-- The scheduler's entire job is to DELAY writes, which makes every one of its properties
-- invisible to a test that can only observe the database. "The row is on disk" is equally
-- true under write-through, under a correctly working write-behind, and under a write-behind
-- that silently degraded back to committing every mutation. So these tests assert against the
-- QUEUE — what is owed, what got dropped, what got written — not against the final rows.
--
-- WHERE THIS STANDS
--
-- The player and container kinds both defer now, and a move between two deferred stores is
-- queued as a LINKED pair (a transaction group) that must land together. The sections below
-- follow the order that was built in: the queue itself, teardown correctness, real mutations
-- deferring, containers deferring, and the groups.
--
-- HOW A PENDING WRITE IS MANUFACTURED
--
-- Most tests need real work in the queue without changing any item, so they invalidate the save
-- snapshot: the next build then emits a full rewrite, which is a genuine pending write and
-- nothing else.
--
-- TWO THINGS ABOUT HOW THE QUEUE IS READ, both learned from tests that failed intermittently:
--
--   * __TestDirtyCount counts CHARACTER ROWS too, and the stats tick marks those every few
--     seconds whatever a test is doing. So an absolute count is only meaningful as a DIFFERENCE,
--     taken across code that does not yield — nothing else can run in between. Every exact count
--     here is such a difference; everything else asks about one named unit (__TestIsDirty).
--
--   * The background flush thread is PAUSED for the whole module (setup) and resumed in teardown.
--     Running, it could land a queued write between a test's mark and its look — or, worse, land
--     the write an armed fault was aimed at, leaving the fault unspent and the test measuring an
--     operation that never failed. Every fault test now also proves its fault was consumed.
-- ============================================

local ITEM = '_test_wb'

--- The whole queue, character rows included. Only ever compared as a difference — see above.
local function dirty()
    return exports.whip_core:__TestDirtyCount()
end

--- Is this one unit owed a write?
local function owed(unit)
    return exports.whip_core:__TestIsDirty(unit)
end

local function markDirty(source)
    return exports.whip_core:__TestMarkPlayerDirty(source)
end

--- ONE forced flush, reporting honestly. For the tests that expect — or inspect — a failure.
local function flush()
    return exports.whip_core:__TestFlushPersistence()
end

--- A flush that MUST land. Through the runner's FlushPersistence, which retries the one transient
--- failure the raw seam cannot tell from a real one (an InnoDB deadlock against the character-row
--- write) and raises, naming what is still owed, on anything else.
local function mustFlush()
    FlushPersistence()
end

--- The fault still armed, if any. nil after a test arms one means it FIRED.
local function faultLeft()
    return exports.whip_core:__TestGetDbFaultMode()
end

local function lastWrite()
    return exports.whip_core:__TestLastWrite()
end

local function clearLastWrite()
    return exports.whip_core:__TestClearLastWrite()
end

local function setDurability(mode, kindId)
    return exports.whip_core:__TestSetDurability(kindId or 'player', mode)
end

--- Read a kind's durability without changing it: set it to a known value to learn the old
--- one, then immediately put the old one back.
local function readDurability(kindId)
    local previous = setDurability('writeThrough', kindId)
    if previous then setDurability(previous, kindId) end
    return previous
end

RegisterTestModule({
    order    = 29,
    category = 'Write-Behind',

    setup = function(source, ctx)
        -- (A skip for "seams disabled" used to open this setup. /test now refuses to start
        -- without the seams, so it could never fire.)
        local p = exports.whip_core:GetPlayer(source)
        assertNotNil(p, 'setup: GetPlayer')
        ctx.charId = p.charId
        ctx.unit   = 'player:' .. p.charId

        -- Recorded BEFORE anything below can change them, so teardown always has the truth.
        ctx.originalDurability          = readDurability()
        ctx.originalContainerDurability = readDurability('container')

        exports.whip_core:RegisterItem(ITEM, {
            name = 'Write-Behind Fixture', desc = 'metadata-carrying fixture',
            weight = 0.1, type = 'misc', stack = false, maxStack = 1,
        })
        RemoveAllOf(source, ITEM)

        -- A container fixture for the unload and group tests. Created in setup rather than
        -- per-test so teardown can always remove it, including when a test errors partway.
        local c = CreateContainerNearPlayer(source, {
            name = '_test_wb_stash', type = 'stash', slots = 10, maxWeight = 50.0,
            prop = 'prop_cs_cardbox_01',
        })
        ctx.containerId   = c.containerId
        ctx.containerUnit = 'container:' .. tostring(c.containerId)

        -- Start from an empty queue so a leak from an earlier module cannot be read as this
        -- module's own bookkeeping — and then hold the background writer off (see the header).
        mustFlush()
        exports.whip_core:__TestPauseFlushThread(true)
    end,

    teardown = function(ctx, source)
        -- ####################################################################
        -- SERVER-WIDE STATE GOES BACK FIRST, BEFORE ANYTHING HERE CAN RAISE.
        --
        -- This module is the only one that reaches in and changes how the WHOLE SERVER persists,
        -- so its teardown is the only thing standing between one bad run and every later module
        -- testing a configuration nobody chose. It is not enough for the restore to survive a
        -- failing TEST — it has to survive a failing TEARDOWN, and it did not.
        --
        -- The cleanup below mutates an inventory, which saves, which is exactly the kind of thing
        -- that raises when the store layer is the thing under repair. When it did, every line
        -- after it was skipped: player durability stayed flipped to writeThrough, the fault mode
        -- stayed armed, and BOTH LEAKED INTO THE NEXT RUN, because a test run does not restart
        -- the resource. The following run then opened with the framework misconfigured and
        -- reported failures all over modules that had nothing to do with any of it.
        --
        -- So: restores first, and the cleanup that can raise is fenced. Order is the fix — a
        -- pcall around the restores would only have hidden a different half of the problem.
        -- ####################################################################
        pcall(exports.whip_core.__TestPauseFlushThread, exports.whip_core, false)
        -- Restore whatever the durability was on entry, not a hardcoded default: a test that
        -- errors midway would otherwise leave the whole server deferring writes.
        if ctx.originalDurability then
            pcall(setDurability, ctx.originalDurability)
        end
        if ctx.originalContainerDurability then
            pcall(setDurability, ctx.originalContainerDurability, 'container')
        end
        pcall(exports.whip_core.__TestSetDbFaultMode, exports.whip_core, nil)
        -- A pinned in-flight marker wedges its unit for the rest of the session.
        if ctx.unit then pcall(exports.whip_core.__TestSetInflight, exports.whip_core, ctx.unit, false) end
        if ctx.containerUnit then
            pcall(exports.whip_core.__TestSetInflight, exports.whip_core, ctx.containerUnit, false)
        end

        if source then pcall(RemoveAllOf, source, ITEM) end
        if ctx.containerId then
            pcall(exports.whip_core.DeleteContainer, exports.whip_core, ctx.containerId)
        end
        if ctx.doomedId then
            pcall(exports.whip_core.DeleteContainer, exports.whip_core, ctx.doomedId)
        end
        pcall(flush)
    end,

    tests = {
        {
            name = 'The player kind is WRITE-BEHIND',
            fn = function(source, ctx)
                -- Flipped in W3, having been asserted write-through through W1 and W2 so the
                -- change could not happen by accident before the teardown paths existed.
                -- It stays a tripwire in the other direction now: silently reverting this
                -- would restore 200 transactions/second under automatic fire while every
                -- other test in the suite carried on passing.
                assertEqual(ctx.originalDurability, 'writeBehind',
                    'the player inventory must defer its writes')
            end,
        },
        {
            name = 'Marking a store dirty enqueues it and writes NOTHING',
            fn = function(source, ctx)
                mustFlush()
                clearLastWrite()
                assertFalse(owed(ctx.unit), 'precondition: the player owes nothing')

                -- Nothing between these lines yields, so the difference is ours alone.
                local before = dirty()
                assertTrue(markDirty(source), 'marked the player store dirty')
                assertEqual(dirty() - before, 1, 'exactly one unit became owed')
                assertTrue(owed(ctx.unit), 'and it is the player')
                assertEqual(lastWrite(), nil,
                    'marking dirty must not touch the database — that is the whole point')
            end,
        },
        {
            name = 'Marking the SAME unit repeatedly queues it once',
            fn = function(source, ctx)
                mustFlush()

                -- The property that turns a magazine of ammo into one row. The three player
                -- containers are three separate stores sharing one unit, so this also proves
                -- they cannot each queue a write of the same row-set.
                local before = dirty()
                for _ = 1, 20 do markDirty(source) end

                assertEqual(dirty() - before, 1,
                    '20 marks against one unit must leave one queue entry, not 20')
            end,
        },
        {
            name = 'Flushing drains the queue and actually writes',
            fn = function(source, ctx)
                mustFlush()
                assertTrue(exports.whip_core:__TestInvalidateSnapshot(source),
                    'snapshot invalidated, so there is real work to do')
                markDirty(source)
                clearLastWrite()

                assertTrue(flush(), 'the flush reported success')
                assertFalse(owed(ctx.unit), 'the unit is no longer owed afterwards')

                local w = lastWrite()
                assertNotNil(w, 'the flush performed a write')
                assertTrue((w.queries or 0) > 0,
                    ('the flush emitted queries (got %s)'):format(tostring(w and w.queries)))
            end,
        },
        {
            name = 'Flushing an empty queue is a successful no-op',
            fn = function(source, ctx)
                mustFlush()
                clearLastWrite()

                assertTrue(flush(), 'flushing nothing reported success')
                assertEqual(lastWrite(), nil, 'flushing nothing wrote nothing')
                assertFalse(owed(ctx.unit), 'the player is still owed nothing')
            end,
        },
        {
            name = 'A failed BATCH is recovered by the isolated per-unit retry',
            fn = function(source, ctx)
                -- TWO units, because isolation only means anything for a batch. The batch
                -- transaction fails; rather than leaving every dirty unit on the server owed,
                -- the flush retries each one alone to find the poisoned one. The fault is
                -- one-shot, so both isolated retries succeed and nothing is lost — and the
                -- flush must report THAT, not the first attempt's failure.
                assertTrue(exports.whip_core:__TestLoadContainer(ctx.containerId), 'container loaded')
                mustFlush()

                local before = dirty()
                exports.whip_core:__TestInvalidateSnapshot(source)
                markDirty(source)
                exports.whip_core:__TestMarkContainerDirty(ctx.containerId)
                assertEqual(dirty() - before, 2, 'two units are pending')

                assertTrue(exports.whip_core:__TestSetDbFaultMode('transaction'),
                    'armed a one-shot transaction failure')

                local ok     = flush()
                local unused = faultLeft()
                exports.whip_core:__TestSetDbFaultMode(nil)

                -- WITHOUT THIS, a batch that never failed passes exactly the same way: recovered,
                -- nothing owed. The fault being gone is what proves the batch was really refused.
                assertNil(unused, 'the fault was consumed — the batch transaction really failed')
                assertTrue(ok, 'the isolated retries recovered the transient failure')
                assertFalse(owed(ctx.unit), 'the player is not left owed after a recovered failure')
                assertFalse(owed(ctx.containerUnit), 'nor is the container')
            end,
        },
        {
            name = 'A SINGLE failing unit is not retried behind the caller\'s back',
            fn = function(source, ctx)
                -- With one pending unit the batch WAS that unit, so there is nothing to
                -- isolate. Retrying anyway would be a second commit attempt nobody asked for,
                -- which turns a genuine failure into a silent success on the second try.
                mustFlush()
                local before = dirty()
                exports.whip_core:__TestInvalidateSnapshot(source)
                markDirty(source)
                assertEqual(dirty() - before, 1, 'exactly one unit is pending')

                assertTrue(exports.whip_core:__TestSetDbFaultMode('transaction'), 'fault armed')
                local ok     = flush()
                local unused = faultLeft()
                exports.whip_core:__TestSetDbFaultMode(nil)

                assertNil(unused, 'the fault was consumed by the flush')
                assertFalse(ok, 'the flush reported the failure rather than quietly retrying')
                assertTrue(owed(ctx.unit), 'and the unit is still owed')

                -- Clear the quarantine backoff so later modules are not left with a unit
                -- whose writes silently stop landing. flushNow ignores the backoff.
                assertTrue(exports.whip_core:__TestFlushPlayerNow(source), 'recovered on retry')
                assertFalse(owed(ctx.unit), 'queue drained')
            end,
        },
        {
            -- MAX_FLUSH_FAILS, reached honestly. Since 2 Oct 2026 (P-003) five failures make a unit
            -- STUCK, not abandoned: still owed, still retried, listed by /whipsaves (expect a STUCK
            -- line in the server console from this test). The abandoned-unit test further down
            -- covers the old branch, which stays as a safety net.
            name = 'A unit that fails five times is stuck, still owed, and lands when the database takes it',
            fn = function(source, ctx)
                mustFlush()
                exports.whip_core:__TestInvalidateSnapshot(source)
                markDirty(source)

                local owedAfter, spent = {}, true
                for attempt = 1, 5 do
                    exports.whip_core:__TestSetDbFaultMode('transaction')
                    flush()   -- forced, so the backoff between failures is skipped
                    if faultLeft() ~= nil then spent = false end
                    owedAfter[attempt] = owed(ctx.unit)
                end
                exports.whip_core:__TestSetDbFaultMode(nil)

                assertTrue(spent, 'every one of the five faults was consumed by a real attempt')
                for attempt = 1, 5 do
                    assertTrue(owedAfter[attempt],
                        ('still owed, and still being retried, after failure %d'):format(attempt))
                end
                assertTrue(exports.whip_core:__TestIsStuck(ctx.unit), 'after the fifth failure it is listed as stuck')

                -- The database takes writes again: the stuck save lands with no new change needed.
                mustFlush()
                assertFalse(owed(ctx.unit), 'it landed once the database took it')
                assertFalse(exports.whip_core:__TestIsStuck(ctx.unit), 'and is no longer stuck')
            end,
        },
        {
            name = 'Teardown flushes the unit before its handle goes away',
            fn = function(source, ctx)
                mustFlush()
                exports.whip_core:__TestInvalidateSnapshot(source)
                markDirty(source)
                assertTrue(owed(ctx.unit), 'a write is owed')

                assertTrue(exports.whip_core:__TestTeardownPlayer(source),
                    'teardown reported the flush landed')
                assertFalse(owed(ctx.unit), 'teardown left nothing owed')
            end,
        },
        {
            name = 'Forget drops a unit WITHOUT writing it',
            fn = function(source, ctx)
                mustFlush()
                exports.whip_core:__TestInvalidateSnapshot(source)
                markDirty(source)
                assertTrue(owed(ctx.unit), 'a write is owed')

                clearLastWrite()
                assertTrue(exports.whip_core:__TestForget(ctx.unit), 'forgot the unit')

                assertFalse(owed(ctx.unit), 'the unit left the queue')
                assertEqual(lastWrite(), nil,
                    'forget must discard the work, not quietly write it')

                -- Leave the snapshot consistent for later modules: the rows were never
                -- rewritten, so make the next real save rebuild from scratch.
                exports.whip_core:__TestInvalidateSnapshot(source)
                markDirty(source)
                mustFlush()
            end,
        },
        {
            name = 'Stores.save on a WRITE-THROUGH kind commits immediately',
            fn = function(source, ctx)
                mustFlush()
                -- REAL WORK FOR IT TO COMMIT. With nothing changed, the save built an empty query
                -- set and wrote nothing — so "committed rather than enqueued" was only "did not
                -- enqueue", and a write-through path that silently wrote nothing passed.
                exports.whip_core:__TestInvalidateSnapshot(source)
                clearLastWrite()
                setDurability('writeThrough')

                -- ####################################################################
                -- MEASURE, RESTORE, THEN ASSERT.
                --
                -- A failing assertion RAISES, so a restore written after one is not cleanup, it
                -- is a wish. This test changes how the WHOLE SERVER persists, and it used to
                -- rely on the next test's first line to put that back — so the moment it raised,
                -- every remaining test in this module ran against write-through and reported
                -- failures that had nothing to do with what they were testing.
                --
                -- Read the facts out, put the kind back, and only then judge them.
                -- ####################################################################
                local saved     = exports.whip_core:__TestStoreSave(source)
                local stillOwed = owed(ctx.unit)
                local written   = lastWrite()
                setDurability(ctx.originalDurability)

                assertTrue(saved, 'the save reported success')
                assertFalse(stillOwed,
                    'a write-through kind must never enqueue — callers rely on the write having happened')
                assertNotNil(written, 'the save wrote on the spot')
                assertTrue((written.queries or 0) > 0,
                    ('and the write carried queries (got %s)'):format(tostring(written and written.queries)))
            end,
        },
        {
            name = 'Stores.save on a WRITE-BEHIND kind enqueues instead of committing',
            fn = function(source, ctx)
                -- The routing W3 turns on. Proving it here means the flip is a one-line change
                -- to a kind definition rather than a change with unproven behaviour.
                mustFlush()
                clearLastWrite()
                setDurability('writeBehind')

                -- Measured, restored, then judged — see the write-through test above for why a
                -- restore cannot sit after the assertions that might raise past it.
                local saved   = exports.whip_core:__TestStoreSave(source)
                local queued  = owed(ctx.unit)
                local written = lastWrite()
                setDurability(ctx.originalDurability)

                assertTrue(saved, 'the save reported success')
                assertTrue(queued, 'a write-behind kind must enqueue')
                assertEqual(written, nil, 'and must not have written yet')

                mustFlush()
                assertFalse(owed(ctx.unit), 'the queued write landed once flushed')
            end,
        },

        -- ==========================================================
        -- W2 — teardown correctness
        --
        -- Dropping a cache that still owes a write is the worst hazard in this change,
        -- because it is silent: the pending rows go, and the save snapshot is weak-keyed on
        -- the very table being dropped so it is collected along with them. Nothing errors,
        -- nothing logs, and the loss is bounded by one flush interval — small enough to look
        -- like nothing happened.
        --
        -- Containers have no recovery path at all. The store handle carries only the
        -- containerId and re-reads invCache when it builds queries, so once the cache is gone
        -- the contents are unreachable rather than merely unwritten.
        -- ==========================================================
        {
            name = 'Unloading a container WRITES what it still owes',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:__TestLoadContainer(ctx.containerId),
                    'container contents loaded')
                mustFlush()

                assertTrue(exports.whip_core:__TestMarkContainerDirty(ctx.containerId),
                    'container marked dirty with a real pending write')
                assertTrue(owed(ctx.containerUnit), 'the container is owed a write')

                assertTrue(exports.whip_core:__TestUnloadContainer(ctx.containerId),
                    'unload reported success')
                assertFalse(owed(ctx.containerUnit),
                    'unload must flush before dropping — a queue entry left here is lost data')
                assertFalse(exports.whip_core:__TestContainerCached(ctx.containerId),
                    'the cache was dropped once its write had landed')
            end,
        },
        {
            name = 'Unloading REFUSES to drop a container whose write failed',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:__TestLoadContainer(ctx.containerId),
                    'container contents loaded')
                mustFlush()
                exports.whip_core:__TestMarkContainerDirty(ctx.containerId)

                assertTrue(exports.whip_core:__TestSetDbFaultMode('transaction'),
                    'armed a one-shot transaction failure')
                local unloaded = exports.whip_core:__TestUnloadContainer(ctx.containerId)
                local unused   = faultLeft()
                exports.whip_core:__TestSetDbFaultMode(nil)

                assertNil(unused, 'the fault was consumed by the unload\'s flush')
                assertFalse(unloaded, 'unload must refuse when the write did not land')
                assertTrue(exports.whip_core:__TestContainerCached(ctx.containerId),
                    'the contents are STILL in memory — dropping them here is unrecoverable')

                -- And it recovers: the unit is still owed, so a later flush writes it and the
                -- unload then succeeds.
                mustFlush()
                assertTrue(exports.whip_core:__TestUnloadContainer(ctx.containerId),
                    'unload succeeds once the write has gone through')
            end,
        },

        -- ==========================================================
        -- W3 — the player kind actually defers
        --
        -- Everything above tests the scheduler in isolation. These test the thing the whole
        -- change exists for: that an ordinary mutation stops paying a commit fsync, and that
        -- the ones which MUST still pay it still do.
        -- ==========================================================
        {
            name = 'An ordinary inventory change does not write immediately',
            fn = function(source, ctx)
                SeedSlot(source, 'player', 8, ITEM, 1)
                mustFlush()
                clearLastWrite()

                -- By address since 09-24 (it took source, container, slot).
                assertTrue(exports.whip_core:SetItemMetadata(PocketAddr(source, 'player', 8), { ammo = 29 }),
                    'metadata updated')

                assertEqual(lastWrite(), nil,
                    'a deferred inventory change must not reach the database on the spot')
                assertTrue(owed(ctx.unit), 'it is queued instead')

                mustFlush()
                assertNotNil(lastWrite(), 'and the flush wrote it')
            end,
        },
        {
            name = 'THIRTY changes to one slot write ONE row — the magazine case',
            fn = function(source, ctx)
                -- The whole point of the change, stated as a test. Before deferral this was
                -- 30 transactions, each paying its own commit fsync for an ammo count.
                -- Coalescing is not batching: the 29 intermediate values are never written at
                -- all, because the diff compares against the last PERSISTED state rather than
                -- the last mutation.
                SeedSlot(source, 'player', 8, ITEM, 1)
                mustFlush()
                clearLastWrite()

                local addr   = PocketAddr(source, 'player', 8)
                local before = dirty()
                for round = 30, 1, -1 do
                    exports.whip_core:SetItemMetadata(addr, { ammo = round })
                end

                assertEqual(lastWrite(), nil, 'none of the 30 changes wrote on its own')
                assertEqual(dirty() - before, 1, 'they collapsed into a single queued unit')

                mustFlush()
                local w = lastWrite()
                assertNotNil(w, 'the flush wrote')
                assertEqual(w.replaceRows, 1,
                    ('30 changes to one slot must write ONE row, wrote %s'):format(tostring(w.replaceRows)))
            end,
        },
        {
            name = 'saveAll DEFERS when every participant is write-behind',
            fn = function(source, ctx)
                mustFlush()
                clearLastWrite()
                exports.whip_core:__TestInvalidateSnapshot(source)

                local before = dirty()
                assertTrue(exports.whip_core:__TestSaveAllDeferred(source), 'saveAll succeeded')
                assertEqual(dirty() - before, 1,
                    'two player containers share one unit, so they queue once — not twice')
                assertTrue(owed(ctx.unit), 'and that one is the player')
                assertEqual(lastWrite(), nil, 'and nothing was written')

                mustFlush()
            end,
        },
        {
            name = 'saveAll COMMITS NOW when any participant is write-through',
            fn = function(source, ctx)
                -- The anti-duplication rule. A write-through participant lands whatever
                -- happens, so a crash while the deferred half was still queued would leave
                -- the item in both places.
                --
                -- Since W4 both player and container defer, so one is forced write-through
                -- here deliberately. The rule is about MIXED durability, not about which kind
                -- happens to be involved — ground items and shop stock are the real cases.
                assertTrue(exports.whip_core:__TestLoadContainer(ctx.containerId),
                    'container loaded')
                mustFlush()
                clearLastWrite()

                local prev = setDurability('writeThrough', 'container')
                exports.whip_core:__TestInvalidateSnapshot(source)

                local ok = exports.whip_core:__TestSaveAllMixed(source, ctx.containerId)
                local playerOwed    = owed(ctx.unit)
                local containerOwed = owed(ctx.containerUnit)
                local wrote = lastWrite()
                if prev then setDurability(prev, 'container') end

                assertTrue(ok, 'saveAll succeeded')
                assertFalse(playerOwed,
                    'a write-through participant must force the whole move to commit — the player too')
                assertFalse(containerOwed, 'and the container')
                assertNotNil(wrote,
                    'the deferred half was written immediately, not queued')
            end,
        },
        {
            -- THE FAILURE HALF OF THE RULE ABOVE (M4). A write-through saveAll that FAILS hands the
            -- move to the deferred machinery — and that machinery only knows two units belong
            -- together if somebody says so. Marked dirty but NOT linked, the retry could write one
            -- side alone: the split-transfer bug, one failure path further down. Both must come out
            -- owed AND tied together.
            name = 'A write-through saveAll that FAILS leaves both units owed, and linked',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:__TestLoadContainer(ctx.containerId), 'container loaded')
                mustFlush()

                local prev = setDurability('writeThrough', 'container')
                exports.whip_core:__TestInvalidateSnapshot(source)   -- so the commit has real queries
                exports.whip_core:__TestSetDbFaultMode('transaction')

                local ok = exports.whip_core:__TestSaveAllMixed(source, ctx.containerId)
                local unused        = faultLeft()
                local playerOwed    = owed(ctx.unit)
                local containerOwed = owed(ctx.containerUnit)
                local group         = exports.whip_core:__TestGroupUnits(ctx.containerUnit) or {}
                exports.whip_core:__TestSetDbFaultMode(nil)
                if prev then setDurability(prev, 'container') end

                assertNil(unused, 'the fault was consumed by the write-through commit')
                assertFalse(ok, 'saveAll reported the failure')
                assertTrue(playerOwed, 'the player half is still owed — the move stands in memory')
                assertTrue(containerOwed, 'and so is the container half')
                local linked = false
                for _, u in ipairs(group) do
                    if u == ctx.unit then linked = true end
                end
                assertEqual(#group, 2, 'the container is in a group of two')
                assertTrue(linked, 'and its partner is the player — the retry cannot split them')

                mustFlush()
                assertFalse(owed(ctx.unit), 'the retry landed the player half')
                assertFalse(owed(ctx.containerUnit), 'together with the container half')
                assertEqual(#(exports.whip_core:__TestGroupUnits(ctx.containerUnit) or {}), 1,
                    'and the link was released once they had landed')
            end,
        },

        -- ==========================================================
        -- W4 — containers and vehicle storage defer too
        -- ==========================================================
        {
            name = 'Saving a container ENQUEUES rather than committing',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:__TestLoadContainer(ctx.containerId), 'loaded')
                mustFlush()

                -- __TestSaveContainer goes through Containers.saveInventory, which is what
                -- every close, every drag and every restock calls.
                local before = dirty()
                assertTrue(exports.whip_core:__TestSaveContainer(ctx.containerId),
                    'the save reported success')
                assertEqual(dirty() - before, 1, 'one unit was queued')
                assertTrue(owed(ctx.containerUnit), 'the container is queued, not written')

                mustFlush()
                assertFalse(owed(ctx.containerUnit), 'and it lands when the queue drains')
            end,
        },
        -- ("A player<->container move queues BOTH ends" sat here. The next test makes the same
        -- move and asserts everything it did — both ends owed — plus the link that makes it
        -- safe, which its own comment called the sufficient version. Merged into it.)

        -- ==========================================================
        -- W5 — transaction groups
        --
        -- "Both ends are queued together" is necessary and NOT sufficient. It cannot tell a batch
        -- that HAPPENS to contain both halves of a move from one that is REQUIRED to keep them
        -- together — and that difference was a live duplication bug. flushAll's failure path
        -- retried every queued unit ALONE to find whose rows had poisoned the transaction, so the
        -- receiving store committed, the sending store did not, and after a restart the item
        -- existed in both places.
        --
        -- These assert the LINK rather than the symptom: that the two units are recorded as
        -- inseparable, that the record reads the same from either end, that it is cleared when
        -- they land — and, with a partner pinned mid-write, that the group really does wait.
        -- ==========================================================
        {
            name = 'A deferred two-unit move queues BOTH ends and RECORDS them as inseparable',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:__TestLoadContainer(ctx.containerId), 'loaded')
                mustFlush()

                -- Before the move the container owes nothing and belongs with nobody.
                assertEqual(#exports.whip_core:__TestGroupUnits(ctx.containerUnit), 1,
                    'an idle unit is in no group')

                exports.whip_core:__TestInvalidateSnapshot(source)
                local before = dirty()
                assertTrue(exports.whip_core:__TestSaveAllMixed(source, ctx.containerId),
                    'saveAll succeeded')

                -- Both ends queued: if this ever reports one, the halves are being written
                -- separately and a crash between them duplicates or destroys the item.
                assertEqual(dirty() - before, 2, 'both ends of the move are queued together')
                assertTrue(owed(ctx.unit), 'the player end is owed')
                assertTrue(owed(ctx.containerUnit), 'the container end is owed')

                local group = exports.whip_core:__TestGroupUnits(ctx.containerUnit)
                assertEqual(#group, 2, 'the container is now linked to exactly one other unit')

                -- The partner must be the PLAYER side of the move, not some unrelated unit that
                -- happened to be dirty at the same moment.
                local playerUnit, hasContainer = nil, false
                for _, u in ipairs(group) do
                    if u == ctx.unit then playerUnit = u end
                    if u == ctx.containerUnit then hasContainer = true end
                end
                assertNotNil(playerUnit, 'the player unit is the one it is linked to')
                assertTrue(hasContainer, 'and the group contains the container itself')

                -- Asked from the OTHER end the answer must be the same group. A one-directional
                -- link would let whichever side flushed first walk away on its own, which is the
                -- bug wearing a different hat.
                assertEqual(#exports.whip_core:__TestGroupUnits(playerUnit), 2,
                    'the link reads the same from either end')

                mustFlush()
            end,
        },
        {
            name = 'Landing the transaction CLEARS the link',
            fn = function(source, ctx)
                -- A group that outlived its transaction would hold its members hostage: flushAll
                -- refuses to write a group while any member is backing off, so a stale link is a
                -- unit that can never be written again.
                assertTrue(exports.whip_core:__TestLoadContainer(ctx.containerId), 'loaded')
                mustFlush()

                exports.whip_core:__TestInvalidateSnapshot(source)
                assertTrue(exports.whip_core:__TestSaveAllMixed(source, ctx.containerId),
                    'saveAll succeeded')
                assertEqual(#exports.whip_core:__TestGroupUnits(ctx.containerUnit), 2, 'linked')

                mustFlush()
                assertFalse(owed(ctx.unit), 'the player landed')
                assertFalse(owed(ctx.containerUnit), 'the container landed')
                assertEqual(#exports.whip_core:__TestGroupUnits(ctx.containerUnit), 1,
                    'and the link is gone once there is nothing left to keep together')
            end,
        },
        {
            -- M1: THE GROUP WAITS FOR A PARTNER THAT IS MID-WRITE. flushAll used to skip an
            -- in-flight unit and write its partner alone in the same pass — then unlink them on
            -- commit, leaving one half of a transfer on disk while the other half's commit was
            -- still running: both places, after a crash. readyToWrite now holds the whole group
            -- back while any member is in flight.
            name = 'A partner with a commit IN FLIGHT holds its whole group back',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:__TestLoadContainer(ctx.containerId), 'loaded')
                mustFlush()

                exports.whip_core:__TestInvalidateSnapshot(source)
                assertTrue(exports.whip_core:__TestSaveAllMixed(source, ctx.containerId),
                    'saveAll linked the two units')
                clearLastWrite()

                -- Pin the CONTAINER as mid-commit, then ask for everything to be written.
                assertTrue(exports.whip_core:__TestSetInflight(ctx.containerUnit, true), 'container pinned in flight')
                local flushed    = flush()
                local wrote      = lastWrite()
                local playerOwed = owed(ctx.unit)
                exports.whip_core:__TestSetInflight(ctx.containerUnit, false)

                assertNil(wrote, 'the PLAYER half was not written while its partner was mid-commit')
                assertTrue(playerOwed, 'it is still owed, to go with its partner')
                assertFalse(flushed, 'and the flush says it could not land everything')

                mustFlush()
                assertFalse(owed(ctx.unit), 'released, the player half lands')
                assertFalse(owed(ctx.containerUnit), 'together with the container half')
            end,
        },
        {
            name = 'An ABANDONED unit keeps its link, so its partner cannot be written alone',
            fn = function(source, ctx)
                -- ####################################################################
                -- THE WORST CASE THIS MECHANISM EXISTS FOR, AND IT IS NOT OBVIOUS.
                --
                -- After five failed flushes a unit is GIVEN UP ON: it leaves the write queue and
                -- memory carries the truth for the rest of the session. That is a deliberate
                -- decision about durability, and it is fine on its own.
                --
                -- What is not fine is dropping its GROUP at the same time, which the code used to
                -- do. Both halves of that abandoned move are still in memory with the item moved,
                -- and on disk with the item still at the sender. Unlink them and the next
                -- unrelated change to the RECEIVER — adding cash, anything — marks only the
                -- receiver dirty, writes it alone, and the item now exists on disk in BOTH
                -- places. The sender's removal is never written, because nothing touches it again.
                --
                -- So: abandon one side, touch the other, and assert the abandoned partner came
                -- back with it. (The give-up itself is exercised for real further up; this uses the
                -- seam that imitates its end state, because reaching it for a GROUP needs a fault
                -- that fires five times.)
                -- ####################################################################
                assertTrue(exports.whip_core:__TestLoadContainer(ctx.containerId), 'loaded')
                mustFlush()

                exports.whip_core:__TestInvalidateSnapshot(source)
                assertTrue(exports.whip_core:__TestSaveAllMixed(source, ctx.containerId),
                    'saveAll succeeded')

                local group = exports.whip_core:__TestGroupUnits(ctx.containerUnit)
                assertEqual(#group, 2, 'the two units are linked')

                -- Give up on the player half, exactly as the fifth failed flush would.
                assertTrue(exports.whip_core:__TestAbandonUnit(ctx.unit), 'abandoned')
                assertFalse(owed(ctx.unit), 'the abandoned unit has left the write queue')

                -- THE LINK MUST HAVE SURVIVED. This is the assertion the old code failed.
                assertEqual(#exports.whip_core:__TestGroupUnits(ctx.unit), 2,
                    'an abandoned unit stays tied to its partner — dropping the link here is how '
                    .. 'a later write duplicates the item')

                -- Now touch the surviving half, the way any ordinary change would.
                assertTrue(exports.whip_core:__TestMarkContainerDirty(ctx.containerId), 'touched')

                -- Touching one member re-arms the whole group, so the abandoned half is owed again
                -- and the pair goes back to disk together rather than the survivor going alone.
                assertTrue(owed(ctx.unit), 'touching one member re-armed the abandoned partner')

                mustFlush()
                assertEqual(#exports.whip_core:__TestGroupUnits(ctx.unit), 1,
                    'the link is released once they actually landed')
            end,
        },
        {
            name = 'A unit with a commit IN FLIGHT is not written again underneath it',
            fn = function(source, ctx)
                -- ####################################################################
                -- THE OVERLAPPING-SAVE DUPLICATION, AND IT NEEDS NO FAILURE AT ALL.
                --
                -- buildSaveQueries diffs the cache against the last CONFIRMED snapshot, and the
                -- snapshot only advances after the write lands. So while a commit is in flight
                -- the snapshot still describes the state before it, and a second build started
                -- in that window diffs against the same stale snapshot:
                --
                --     snapshot {A}      move A->B   build 1: write B, delete A
                --                         ... yields on the database ...
                --                       move B->C   build 2: write C, delete A
                --
                -- Build 2 cannot emit "delete B" — the snapshot it diffed has never heard of B.
                -- BOTH transactions succeed and the row at B is left behind forever: one item
                -- in, two out, nothing pending, and every later build agrees there is nothing
                -- to repair.
                --
                -- The real interleaving needs a mutation to land mid-round-trip, which a test
                -- cannot schedule. The RULE can be asserted directly: nothing writes a unit
                -- while a commit for it is outstanding. (The GROUP version is the M1 test above.)
                -- ####################################################################
                mustFlush()
                clearLastWrite()

                local unit = ctx.unit

                markDirty(source)
                assertTrue(owed(unit), 'the unit is owed')

                -- Pin it as mid-commit, as a real in-flight transaction would.
                assertTrue(exports.whip_core:__TestSetInflight(unit, true), 'marked in flight')

                -- Measured, then released, then judged — a raise past the release would leave
                -- the unit pinned for the rest of the session and every later module failing to
                -- write it.
                local flushed   = flush()
                local stillOwed = owed(unit)
                local wrote     = lastWrite()
                exports.whip_core:__TestSetInflight(unit, false)

                assertNil(wrote, 'nothing was written for a unit already mid-commit')
                assertTrue(stillOwed,
                    'and it is still owed, so the next pass writes it against a CURRENT snapshot')
                assertFalse(flushed,
                    'the flush reports incomplete rather than claiming everything landed')

                -- Released, it writes normally. Proves the guard let go rather than wedging.
                assertTrue(exports.whip_core:__TestIsInflight(unit) == false, 'released')
                mustFlush()
                assertFalse(owed(unit), 'the queue drained')
            end,
        },
        {
            name = 'Deleting a container settles its queued write, then forgets it',
            fn = function(source, ctx)
                -- Since 2 Oct 2026 (P-032) the owed write lands BEFORE the delete, so the other half
                -- of a move is never written alone, and the unit is forgotten after it: nothing is
                -- left to fire at rows that are gone.
                local c = CreateContainerNearPlayer(source, {
                    name = '_test_wb_doomed', type = 'stash', slots = 5, maxWeight = 20.0,
                    prop = 'prop_cs_cardbox_01',
                })
                ctx.doomedId = c.containerId   -- teardown's, if an assertion fails before the delete
                local unit = 'container:' .. tostring(c.containerId)

                assertTrue(exports.whip_core:__TestLoadContainer(c.containerId), 'loaded')
                mustFlush()
                assertTrue(exports.whip_core:__TestMarkContainerDirty(c.containerId), 'queued')
                assertTrue(owed(unit), 'a write is owed')

                assertTrue(exports.whip_core:DeleteContainer(c.containerId), 'container deleted')
                ctx.doomedId = nil
                assertFalse(owed(unit),
                    'deleting the container dropped its queued write instead of leaving it to fail')

                assertTrue(flush(), 'the next flush has nothing to trip over')
            end,
        },
    },
})
