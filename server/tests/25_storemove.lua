-- ============================================
-- storeMove — the one move event, and the 'addr' param type
--
-- WHY THIS MODULE EXISTS
--
-- whip_core:server:storeMove replaces twelve client-facing move events whose only real
-- difference was which pair of stores they connected. The pairing is now a parameter.
--
-- The part that needs testing hardest is not the moving — 23_moves already covers that
-- through Stores.move — it is the 'addr' PARAM TYPE, because that is now the single
-- authorization gate for every store a client can name. Twelve handlers used to each check
-- for themselves, inconsistently: one enum list omitted `accessory` entirely, and one
-- endpoint was declared {'fromType','string',20} and validated nothing at all. If `addr`
-- gets this wrong, it gets it wrong for every move in the game at once.
--
-- So most of what follows is negative testing: a client naming a container it never opened,
-- a vehicle it does not hold, a panel belonging to someone else, or a store kind that is not
-- client-addressable at all.
--
-- WHAT IS NOT HERE ANY MORE, AND WHERE IT WENT. Plain moves within the pockets and into the
-- accessory strip are 23_moves' subject, and the panel hook contract (refuse / allow / an erroring
-- hook / read-only) is 21_panel_contract's — both drive the same storeMove event, so the copies
-- here proved nothing twice. What stayed is what only this module asks: the mode and amount
-- parameters, the swap's returning half, addressing, and the export.
--
-- (09-24: the panel hooks here are the OpenPanel config's onValidate(ctx) / onChange(ctx) now.
-- SetPanelOnMove, and its third answer 'handled', were removed from whip_core.)
-- ============================================

local ITEM     = '_test_storemove'
local OCCUPANT = '_test_storemove_b'   -- what sits in a destination, for the swap tests

--- Fire storeMove exactly as the NUI will.
local function storeMove(source, from, to, amount, mode, opId)
    return ClientExecWait(source, 'whip_core:server:storeMove', 3000,
        from, to, amount or 0, mode or 'move', opId or 0)
end

--- Slots this module works in, filled by setup().
---
--- WHY THESE ARE NOT 1, 2, 3
---
--- They were, and it made the suite depend on what the tester happened to be carrying. Low
--- slots are where real items live: on this box player slot 1 holds a rifle and slot 2 a
--- minigun. Seeding slot 1 destroyed the rifle on every run — and worse, if that rifle was
--- EQUIPPED, whip_gunny still had the slot in its EquippedWeapons state and would write the
--- weapon back into it partway through, landing a row exactly where a test had just asserted
--- the slot was empty.
---
--- 24_placement already solved this with a claim() helper. This module had not adopted it.
local S = {}

--- Reserve a slot at the far end of a container, and prove it is empty first.
---
--- Asserting emptiness matters as much as picking a high number: silently seeding over
--- something means the test passes while having destroyed whatever was there.
local function claim(source, container, n)
    local slots = exports.whip_core:GetPocketSlots(container)
    assertNotNil(slots, ('%s slot count is known'):format(container))
    local slot = slots - n + 1
    assertTrue(slot >= 1, ('%s has room for reserved slot #%d'):format(container, n))
    -- By address (09-24: RemoveItemFromSlot and GetSlotData were removed). Taking from an empty
    -- slot answers false, 'Empty slot', which is fine here.
    pcall(exports.whip_core.StoreTake, exports.whip_core, PocketAddr(source, container, slot))
    assertNil(exports.whip_core:GetItemAt(PocketAddr(source, container, slot)),
        ('%s slot %d is empty before the module seeds it'):format(container, slot))
    return slot
end

--- Reserve an accessory slot that will actually accept an arbitrary test item.
---
--- A strip slot may be TYPED (`accepts`), and a store correctly refuses anything else. Only slots
--- with no `accepts` are usable as scratch space: in the shipped config every slot but 4, which
--- runner.lua makes the Medkit slot for the run.
---@param source number
---@return number slot
local function claimAccessory(source)
    local free
    for slot, def in pairs(exports.whip_core:GetAccessorySlots() or {}) do
        if not def.accepts and (not free or slot < free) then free = slot end
    end

    assertNotNil(free,
        'the accessory strip has at least one slot that accepts anything — if this fails, every '
        .. 'slot has been typed and this module needs a different scratch container')

    -- Prove it is empty, exactly as claim() does: silently seeding over something means the
    -- test passes having destroyed whatever was there.
    pcall(exports.whip_core.StoreTake, exports.whip_core, PocketAddr(source, 'accessory', free))
    assertNil(exports.whip_core:GetItemAt(PocketAddr(source, 'accessory', free)),
        ('accessory slot %d is empty before the module seeds it'):format(free))
    return free
end

--- A player-container address, in the WIRE form the NUI sends to storeMove: the pocket is the kind.
---
--- Not the form the server exports take. GetItemAt, StoreTake, StoreGive and the StoreMove export
--- want `{ kind = 'player', id = source, sub = pocket, slot }` — runner.lua's PocketAddr (09-24).
local function pAddr(container, slot)
    return { kind = container, slot = slot }
end

--- What the scratch panel ('_test_sm_panel') holds right now, keyed by slot.
---
--- Read by the panel's address (09-24: GetPanelItems was removed). StoreRead answers false while the
--- panel is not open, and here that is a failure, not an empty panel.
---@return table items
local function panelItems()
    local panel, err = exports.whip_core:StoreRead({ kind = 'panel', id = '_test_sm_panel' })
    assertOk(panel, err, 'the scratch panel is open and reads back')
    return panel.items or {}
end

--- Open this module's scratch panel from NOTHING.
---
--- Panel contents are a SHARED INSTANCE per id, torn down only when its last viewer closes — so a
--- test that failed before its ClosePanel left the instance alive, and the next test's OpenPanel
--- joined it, inheriting the dead test's contents and ignoring the `items` it asked for. Closing
--- first means each test starts from the config it wrote.
---
--- THE HOOKS TOO (09-24). onValidate / onChange live in the OpenPanel config and belong to the
--- panel: the first opener that brings any sets them, and a later opener's are ignored while it
--- stays open. Joining a leaked panel would run the dead test's hook instead of this one's.
local function openFreshPanel(source, config)
    pcall(exports.whip_core.ClosePanel, exports.whip_core, source, config.id)
    return exports.whip_core:OpenPanel(source, config)
end

--- Assert the last storeMove was REFUSED, and refused for the reason under test.
---
--- Checking only that nothing moved is a false positive waiting to happen: a rate-limited
--- event, a typo'd item key and a correctly-rejected address all leave the inventory
--- untouched. This reads the rejection SecureEvent actually recorded.
---@param expect string  substring the rejection reason must contain
local function assertRefused(expect)
    local reason = exports.whip_core:__TestLastReject('whip_core:server:storeMove')
    assertNotNil(reason, 'storeMove recorded a rejection')
    assertTrue(reason:lower():find(expect:lower(), 1, true) ~= nil,
        ('rejected for the expected reason (wanted ~"%s", got "%s")'):format(expect, tostring(reason)))
end

RegisterTestModule({
    order    = 25,
    category = 'StoreMove',

    setup = function(source, ctx)
        exports.whip_core:RegisterItem(ITEM, {
            name = 'StoreMove Fixture', desc = 'storeMove fixture',
            weight = 0.1, type = 'misc', stack = true, maxStack = 10,
        })
        exports.whip_core:RegisterItem(OCCUPANT, {
            name = 'StoreMove Occupant', desc = 'storeMove fixture (swap partner)',
            weight = 0.1, type = 'misc', stack = true, maxStack = 10,
        })

        local p = exports.whip_core:GetPlayer(source)
        assertNotNil(p, 'setup: GetPlayer')
        ctx.charId = p.charId
        ctx.tempContainers = {}   -- containers a test made for itself; teardown deletes them
        RemoveAllOf(source, ITEM)
        RemoveAllOf(source, OCCUPANT)

        -- Reserved from the top down, so the module never touches the low slots where the
        -- tester's own weapons and other modules' fixtures sit.
        S.p1 = claim(source, 'player', 1)
        S.p2 = claim(source, 'player', 2)
        S.p3 = claim(source, 'player', 3)
        S.p4 = claim(source, 'player', 4)
        S.p5 = claim(source, 'player', 5)
        -- The cross-container tests need a SECOND container. That used to be the backpack;
        -- with it retired, 'accessory' is the only other container a character is guaranteed
        -- to have.
        --
        -- ####################################################################
        -- NOT "COUNT BACK FROM THE END" ANY MORE, BECAUSE THE STRIP IS TYPED.
        --
        -- These were claim(source, 'accessory', 1..3), which is slots 5, 4 and 3. Slot 3 is the
        -- CASH slot and slot 5 is the Medkit slot THIS SUITE REGISTERS ITSELF in runner.lua — so
        -- two of the three scratch slots only accept an item this module does not use. The store
        -- refused those moves exactly as it should, and the suite reported its own rules as two
        -- failures: "Only Cash can go there" and "Only Bandage can go there" were in the server
        -- log the whole time, being read as bugs.
        --
        -- Asking which slots are untyped is the fix, and it keeps working when somebody registers
        -- another one.
        -- ####################################################################
        S.a = claimAccessory(source)

        -- A container fixture, for the cross-UNIT tests.
        --
        -- Every player container shares one unit ('player:<charId>'), so a player->accessory move
        -- cannot demonstrate a two-unit transaction no matter how it is asserted. A container is
        -- its own unit, which is what makes all-or-nothing observable.
        -- Returns the container DEFINITION, not an id — the id is a field on it.
        local cDef = CreateContainerNearPlayer(source, {
            name = 'StoreMove Fixture Stash', slots = 10, maxWeight = 50.0,
        })
        ctx.containerId = cDef.containerId
    end,

    teardown = function(ctx, source)
        -- SERVER-WIDE SWITCHES FIRST, before anything below can raise: two tests pause the flush
        -- thread and one arms a fault, and each used to put them back only on its success path.
        -- A failure between the two left every LATER module on a server that writes only when
        -- asked, with a fault waiting for the next commit.
        pcall(exports.whip_core.__TestPauseFlushThread, exports.whip_core, false)
        pcall(exports.whip_core.__TestSetDbFaultMode, exports.whip_core, nil)

        if not source then return end
        -- A test that fails mid-way leaves its panel open, and an open panel keeps its hooks
        -- (the panel's onValidate / onChange) alive for every LATER module that joins it.
        pcall(exports.whip_core.ClosePanel, exports.whip_core, source)
        -- Same for a container: a leaked viewer membership now PINS that container's cache for
        -- the rest of the session and can be picked up by any later test resolving 'container'.
        local doomed = {}
        if ctx.containerId then doomed[#doomed + 1] = ctx.containerId end
        for _, id in ipairs(ctx.tempContainers or {}) do doomed[#doomed + 1] = id end
        for _, id in ipairs(doomed) do
            pcall(ClientCloseContainer, source, id, 3000)
            pcall(exports.whip_core.DeleteContainer, exports.whip_core, id)
        end
        RemoveAllOf(source, ITEM)
        RemoveAllOf(source, OCCUPANT)
        if ctx.typedItem then RemoveAllOf(source, ctx.typedItem) end
    end,

    tests = {
        -- ==========================================
        -- The move itself
        -- ==========================================
        {
            -- REPLACES "storeMove crosses containers" and "reaches 'accessory'", which were the
            -- same player->accessory move 23_moves makes. This is the cross-container case
            -- nothing else covers, and it was an exploit: the accessory strip's per-slot rule was
            -- only asked about the item ARRIVING. Drag the phone OUT of its slot onto a pocket
            -- slot holding anything, and the swap wrote that anything back into the phone slot
            -- unexamined. Stores.move and commitMove both check the returning half now.
            name = 'A swap cannot put an arbitrary item into a typed accessory slot',
            fn = function(source, ctx)
                -- Prefer the slot whip_test registers itself (runner.lua makes slot 4 accept
                -- bandages): seeding a phone into the phone slot could wake whip_phone.
                local typed, accepts
                for slot, def in pairs(exports.whip_core:GetAccessorySlots() or {}) do
                    if def.accepts and (not typed or def.accepts == 'bandage') then
                        typed, accepts = slot, def.accepts
                        if accepts == 'bandage' then break end
                    end
                end
                assertNotNil(typed, 'the accessory strip has a typed slot')
                ctx.typedItem = accepts

                RemoveAllOf(source, ITEM)
                RemoveAllOf(source, accepts)
                pcall(exports.whip_core.StoreTake, exports.whip_core, PocketAddr(source, 'accessory', typed))
                SeedSlot(source, 'accessory', typed, accepts, 1)
                SeedSlot(source, 'player', S.p1, ITEM, 2)

                -- The typed item leaves its slot; ITEM would have to come back into it.
                storeMove(source, pAddr('accessory', typed), pAddr('player', S.p1))

                assertRefused('can go there')
                local stillTyped = exports.whip_core:GetItemAt(PocketAddr(source, 'accessory', typed))
                assertEqual(stillTyped and stillTyped.item, accepts, 'the typed slot kept its own item')
                local stillPocket = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p1))
                assertEqual(stillPocket and stillPocket.item, ITEM, 'the pocket kept its item')
                assertEqual(stillPocket and stillPocket.amount, 2, 'and all of it')

                RemoveAllOf(source, accepts)
            end,
        },
        {
            name = "storeMove mode='split' moves a partial amount",
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 6)

                storeMove(source, pAddr('player', S.p1), pAddr('player', S.p3), 2, 'split')

                local src = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p1))
                local dst = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p3))
                assertEqual(src and src.amount, 4, 'the remainder stayed put')
                assertEqual(dst and dst.amount, 2, 'the split amount arrived')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 6, 'total conserved')
            end,
        },
        {
            name = "storeMove mode='one' moves exactly one",
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 5)

                storeMove(source, pAddr('player', S.p1), pAddr('player', S.p4), 0, 'one')

                local src = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p1))
                local dst = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p4))
                assertEqual(src and src.amount, 4, 'one left the source')
                assertEqual(dst and dst.amount, 1, 'exactly one arrived')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 5, 'total conserved')
            end,
        },
        {
            name = 'An operation id is carried without changing the move',
            fn = function(source, ctx)
                -- opId is pure correlation: the server echoes it back on rejection so the
                -- NUI can roll back the move that actually failed rather than guessing at
                -- the oldest one still pending. It must never influence the move itself.
                --
                -- WHAT THIS CANNOT SEE: the reply itself. A non-zero opId changes which message
                -- answers the drag (the inventory push marked as a reply, or moveAck), and that
                -- only reaches the client. Without a client-side recorder the protocol half is an
                -- in-game check; this pins the half the server owns.
                --
                -- (A second test here used to claim "a rejected move with an operation id still
                -- refuses". The refusal it relied on happens in SecureEvent's param validation,
                -- before the handler and its opId are ever reached, so it was the rawInventory test
                -- below with a number added. Deleted.)
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 4)

                storeMove(source, pAddr('player', S.p1), pAddr('player', S.p5), 0, 'move', 4242)

                assertLastReject('whip_core:server:storeMove', nil, 'the move with an opId was accepted')
                local moved = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p5))
                assertEqual(moved and moved.amount, 4, 'the move happened normally with an opId set')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 4, 'total conserved')
            end,
        },
        {
            -- RENAMED, because it never proved a transaction.
            --
            -- Both ends of a player->accessory move are the SAME unit — the player kind's unitKey
            -- is 'player:<charId>' for every one of its containers — and that kind is write-behind.
            -- So Stores.saveAll finds no write-through participant, marks dirty and returns
            -- WITHOUT committing anything. The rows this reads only reached disk because the test
            -- itself then called FlushPersistence. It was measuring the flush thread, and would
            -- have passed identically if storeMove persisted nothing at all.
            --
            -- What it can honestly prove is the DEFERRAL: nothing on disk until a flush, both
            -- sides after one. The flush thread is paused so the background pass cannot land the
            -- write before the assertion looks.
            name = 'storeMove defers both sides, and one flush lands them',
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 3)
                FlushPersistence(source)   -- settle the seed, so what follows is only the move

                -- Put back by teardown too, if anything below raises before the resume.
                exports.whip_core:__TestPauseFlushThread(true)

                storeMove(source, pAddr('player', S.p1), pAddr('accessory', S.a))

                -- THIS UNIT, not the whole queue. __TestDirtyCount also counts character rows,
                -- which the stats tick marks every few seconds and the pause does not stop — so
                -- "more than zero owed" was true whether or not the move had queued anything.
                assertTrue(exports.whip_core:__TestIsDirty('player:' .. ctx.charId),
                    'the move was DEFERRED, not committed at move time')

                -- DbQuery, NOT assertDbRowCount. assertDbRowCount calls FlushPersistence before
                -- it reads — so the assertion that nothing had reached disk was itself writing
                -- it to disk first, and then correctly reporting the row it had just caused.
                -- Every "nothing on disk yet" check has to read RAW.
                local early = DbQuery(
                    'SELECT 1 FROM `character_inventory` WHERE `charId` = ? AND `container` = ? AND `slot` = ?',
                    { ctx.charId, 'accessory', S.a })
                assertEqual(#early, 0, 'and nothing reached disk yet')

                exports.whip_core:__TestPauseFlushThread(false)
                FlushPersistence(source)

                assertDbRowCount(
                    'SELECT 1 FROM `character_inventory` WHERE `charId` = ? AND `container` = ? AND `slot` = ?',
                    { ctx.charId, 'player', S.p1 }, 0, 'the vacated slot was deleted on disk')
                assertDbScalar(
                    'SELECT `amount` FROM `character_inventory` WHERE `charId` = ? AND `container` = ? AND `slot` = ?',
                    { ctx.charId, 'accessory', S.a }, 3, 'the destination reached disk')
            end,
        },
        {
            -- The atomicity the old test NAMED but could not reach: two different units, whose
            -- rows must never disagree on disk. player and container are separate units, so this
            -- is the pairing where a half-landed move would duplicate or destroy the item.
            --
            -- WHAT A FAULT ACTUALLY DOES HERE, which the first version of this test got wrong.
            -- The seam is ONE-SHOT. flushAll batches every dirty unit into a single transaction;
            -- that batch consumes the fault and fails. flushAll then deliberately RETRIES EACH
            -- UNIT ALONE to find the one poisoned row instead of dragging the whole server
            -- through the same failure every second — and by then the fault is spent, so both
            -- retries succeed and flushAll returns TRUE. It reports whether everything ultimately
            -- landed, not whether the first attempt did, which is the right contract for a caller
            -- deciding whether it may drop a cache.
            --
            -- So asserting `false`, or that neither side landed, was asserting against the
            -- recovery design rather than against a correctness property. The property that
            -- actually has to hold — through the batch, through isolation, through any future
            -- retry scheme — is that the two sides AGREE. That is what this asserts.
            --
            -- Worth knowing: isolation genuinely does re-open a half-land window that the single
            -- batch does not have. If one unit's retry succeeds and the other's fails, disk holds
            -- half the move until the quarantined unit drains. Memory stays correct and the write
            -- is still owed, so it self-heals — unless the row is permanently unwritable or the
            -- server stops first. Bounded and deliberate, but it is a trade, not an absence of one.
            name = 'A faulted cross-unit move never half-lands',
            fn = function(source, ctx)
                local c = ctx.containerId
                assertNotNil(c, 'the container fixture exists')

                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 3)
                FlushPersistence(source)

                OpenContainerOrFail(source, c)
                -- The landing slot must be empty, or the move is a merge or a swap and measures
                -- something else. It is our own fixture, so emptying it destroys nothing real.
                -- (By address, 09-24: TakeItemFrom's 'container' — "whatever this player has
                -- open" — was removed with it.)
                pcall(exports.whip_core.StoreTake, exports.whip_core, { kind = 'container', id = c, slot = 1 })

                -- THE FLUSH THREAD IS PAUSED, and the fault is armed AFTER the move and aimed at the
                -- flush — where both deferred halves actually get written.
                --
                -- Unpaused, the background pass usually landed the move during the round trip
                -- (its writes are never faulted), so the fault armed here found nothing to fail,
                -- stayed armed for up to ten seconds, and this test measured a move that never
                -- failed. The fault check below is what proves that is no longer happening.
                exports.whip_core:__TestPauseFlushThread(true)
                storeMove(source, pAddr('player', S.p1), { kind = 'container', id = c, slot = 1 })
                local moved = exports.whip_core:__TestLastReject('whip_core:server:storeMove') == nil

                exports.whip_core:__TestSetDbFaultMode('transaction')
                exports.whip_core:__TestFlushPersistence(source)
                local unspent = exports.whip_core:__TestGetDbFaultMode()
                exports.whip_core:__TestSetDbFaultMode(nil)
                exports.whip_core:__TestPauseFlushThread(false)

                -- Read both sides RAW — assertDb* would flush first and destroy the evidence.
                local dst = DbQuery(
                    'SELECT `amount` FROM `container_inventory` WHERE `containerId` = ? AND `slot` = 1',
                    { c })
                local src = DbQuery(
                    'SELECT `amount` FROM `character_inventory` WHERE `charId` = ? AND `container` = ? AND `slot` = ?',
                    { ctx.charId, 'player', S.p1 })

                -- CLEAN UP BEFORE ASSERTING. A failed assertion aborts the test, so anything left
                -- after it never runs — the previous version left the container open on failure and
                -- the NEXT test then failed to open one of its own, reporting a cascade as a second
                -- independent defect.
                pcall(function()
                    storeMove(source, { kind = 'container', id = c, slot = 1 }, pAddr('player', S.p1))
                    FlushPersistence(source)
                end)
                ClientCloseContainer(source, c, 3000)

                assertTrue(moved, 'the move itself was accepted')
                assertNil(unspent, 'the armed fault was consumed by the flush — the write really did fail once')

                local onDst, onSrc = #dst > 0, #src > 0

                assertFalse(onDst and onSrc,
                    'the item is not on disk in BOTH places at once — that is the duplication')
                assertTrue(onDst or onSrc,
                    'and it did not vanish from disk entirely — that is the destruction')

                -- Whichever side holds it must hold the WHOLE stack; a split total is the same
                -- bug wearing different numbers.
                local amount = onDst and dst[1].amount or src[1].amount
                assertEqual(amount, 3, 'the full stack is on exactly one side, not split across both')

                -- Memory is the authority and is unaffected by a write failure. The move stands.
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 3,
                    'and memory still holds exactly one stack')
            end,
        },

        -- ==========================================
        -- beforeMove — what the hook is TOLD, through storeMove
        -- ==========================================
        --
        -- The verdict itself (refuse, allow, an erroring hook, a read-only panel) is
        -- 21_panel_contract's, through this same event; five copies of it lived here too. What
        -- stays is the part only these can see: the amount a 'one' move reports, the swap's
        -- returning half, and the state the hook is handed.
        --
        -- (09-24) The hook is the panel's onValidate(ctx), given in the OpenPanel config — it was
        -- SetPanelOnMove(source, fn(source, moveData), id), removed. The fields map one to one:
        -- moveData.direction 'toPanel' / 'fromPanel' is ctx.direction 'in' / 'out', and a refusal
        -- is `return false, 'why'`. Its third answer, 'handled', went with it.
        {
            -- A right-click is mode 'one', and the client sends whatever amount it likes with it —
            -- the whole stack, typically. The hook used to be told THAT, so whip_gunny, asked
            -- whether a single round could go into a magazine, was asked about thirty and said
            -- no. The storeMove handler now tells the hooks 1 for a 'one' move, whatever arrived.
            name = "A right-click ('one') move tells the hook ONE, not the whole stack",
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 5)

                -- Says nothing back, which allows: only `false` refuses.
                local told
                assertTrue(openFreshPanel(source, {
                    id = '_test_sm_panel', label = 'SM', slots = 4,
                    onValidate = function(hctx) told = hctx.amount end,
                }), 'panel opened')

                storeMove(source, pAddr('player', S.p1),
                    { kind = 'panel', id = '_test_sm_panel', slot = 1 }, 5, 'one')

                assertLastReject('whip_core:server:storeMove', nil, 'the move was accepted')
                assertEqual(told, 1, 'the hook was asked about ONE unit, not the amount the client sent')
                local items = panelItems()
                assertEqual(items[1] and items[1].amount, 1, 'exactly one arrived in the panel')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 4, 'exactly one left the player')

                exports.whip_core:ClosePanel(source, '_test_sm_panel')
            end,
        },
        {
            -- THE RETURNING HALF OF A SWAP IS A MOVE TOO. A whole-slot drag onto something it
            -- cannot merge with sends the occupant back the other way, and the hooks used to see
            -- only the forward half — so a hook-guarded slot could be EMPTIED by swapping into it.
            -- Dragging a stack onto a revolver's chamber put the banknotes in the chamber.
            -- commitMove now puts the reverse move to the same hooks, and refuses unless it is ok.
            name = 'The returning half of a swap is put to the hook, and can refuse it',
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 2)

                -- Lets anything in and nothing out. The forward half passes; only the returning
                -- half can be refused.
                --
                -- (09-24) It refuses with its OWN reason now, and the assertion below expects that
                -- reason. The old hook answered a bare false and the test matched the generic
                -- 'Move rejected' — which any refusal on either half would have produced too.
                local sawReturn, sawSwap = false, nil
                assertTrue(openFreshPanel(source, {
                    id = '_test_sm_panel', label = 'SM', slots = 4,
                    items = { [1] = { item = OCCUPANT, amount = 1 } },
                    onValidate = function(hctx)
                        if hctx.direction == 'out' and hctx.item == OCCUPANT then
                            sawReturn, sawSwap = true, hctx.swap
                        end
                        if hctx.direction ~= 'in' then return false, 'Nothing leaves this panel' end
                    end,
                }), 'panel opened with an occupant in slot 1')

                -- Whole slot onto a different item: a swap.
                storeMove(source, pAddr('player', S.p1),
                    { kind = 'panel', id = '_test_sm_panel', slot = 1 })

                assertTrue(sawReturn, 'the hook was asked about the occupant travelling back out')
                assertTrue(sawSwap, 'and was told it is the returning half of a swap (ctx.swap)')
                assertLastReject('whip_core:server:storeMove', 'Nothing leaves this panel',
                    'the swap was refused because its returning half was')
                local items = panelItems()
                assertEqual(items[1] and items[1].item, OCCUPANT, 'the occupant is still in the panel')
                local still = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p1))
                assertEqual(still and still.item, ITEM, 'the dragged stack is still in the pocket')
                assertEqual(still and still.amount, 2, 'all of it')
                assertEqual(exports.whip_core:GetItemCount(source, OCCUPANT) or 0, 0,
                    'nothing of the occupant reached the player')

                exports.whip_core:ClosePanel(source, '_test_sm_panel')
            end,
        },
        {
            name = 'Item state survives a panel round trip',
            fn = function(source, ctx)
                -- Written after a report of a whip_gunny magazine arriving empty. That was
                -- not reproducible and may predate any of this work, but "an item came back
                -- from a panel having lost its state" is precisely the failure this framework
                -- got wrong historically — stacks used to merge on item key alone, throwing
                -- one side's metadata away — so it deserves a standing test rather than a
                -- memory of someone once looking into it.
                --
                -- For a magazine the metadata IS the ammo count. Losing it is not cosmetic.
                RemoveAllOf(source, ITEM)

                local slot = S.p2   -- a claimed slot; this was a hardcoded 6
                -- By address (09-24: RemoveItemFromSlot and PlaceItemAt were removed). StoreGive
                -- answers the slot it landed in, not `true`, hence assertOk.
                pcall(exports.whip_core.StoreTake, exports.whip_core, PocketAddr(source, 'player', slot))
                local seeded, seedErr = exports.whip_core:StoreGive(PocketAddr(source, 'player', slot), ITEM, 1,
                    { rounds = 27, serial = 'MAG-A' })
                assertOk(seeded, seedErr, 'seeded an item carrying state')

                -- (09-24) No hook. This set an allow-everything SetPanelOnMove, and a panel with no
                -- onValidate already allows every move. The panel is still NAMED when it is read
                -- back (panelItems), for the reason this comment used to give: panels stack, so
                -- "the player's panel" is no answer once anything else is open, and the test would
                -- then blame the wrong subsystem. 30_panelitem was bitten by exactly this.
                assertTrue(openFreshPanel(source, {
                    id = '_test_sm_panel', label = 'SM', slots = 4,
                }), 'panel opened')

                storeMove(source, pAddr('player', slot),
                    { kind = 'panel', id = '_test_sm_panel', slot = 1 })

                local inPanel = panelItems()[1]
                assertNotNil(inPanel, 'the item reached the panel')
                assertEqual(inPanel.metadata and inPanel.metadata.rounds, 27,
                    'the panel holds the ORIGINAL state, not a blank one')
                -- The IDENTITY as well as the state. storeMove stamps the instance's uid before it
                -- moves, and the activity log's whole timeline for this item hangs off it: a copy
                -- that came back with a new uid is, as far as the history is concerned, a
                -- different magazine that appeared from nowhere.
                local uid = inPanel.metadata and inPanel.metadata.uid
                assertNotNil(uid, 'the move stamped the instance with a uid')

                storeMove(source, { kind = 'panel', id = '_test_sm_panel', slot = 1 },
                    pAddr('player', slot))

                local back = exports.whip_core:GetItemAt(PocketAddr(source, 'player', slot))
                assertNotNil(back, 'the item came back')
                assertEqual(back.metadata and back.metadata.rounds, 27,
                    'the round count survived the round trip')
                assertEqual(back.metadata and back.metadata.serial, 'MAG-A',
                    'the rest of the state survived too')
                assertEqual(back.metadata and back.metadata.uid, uid,
                    'and it is the SAME instance — the uid survived the round trip')

                exports.whip_core:ClosePanel(source, '_test_sm_panel')
            end,
        },
        {
            name = 'beforeMove receives the SERVER state, not the client claim',
            fn = function(source, ctx)
                -- The legacy panel handler passed the NUI's copy of the metadata straight to
                -- onMove. This passes what the store actually holds. That is a real change,
                -- and it is the safe direction — a client should never get to tell the server
                -- how many rounds are in the magazine it is moving — but a satellite reading
                -- data.metadata now sees something different, so it is worth pinning.
                RemoveAllOf(source, ITEM)

                local slot = S.p3   -- a claimed slot; this was a hardcoded 7
                pcall(exports.whip_core.StoreTake, exports.whip_core, PocketAddr(source, 'player', slot))
                local seeded, seedErr = exports.whip_core:StoreGive(PocketAddr(source, 'player', slot), ITEM, 2,
                    { rounds = 12 })
                assertOk(seeded, seedErr, 'seeded')

                -- The panel's onValidate (09-24; this was SetPanelOnMove). Its ctx carries the same
                -- item / amount / metadata fields the old moveData did.
                local seen
                assertTrue(openFreshPanel(source, {
                    id = '_test_sm_panel', label = 'SM', slots = 4,
                    onValidate = function(hctx) seen = hctx end,
                }), 'panel opened')

                storeMove(source, pAddr('player', slot),
                    { kind = 'panel', id = '_test_sm_panel', slot = 1 })

                assertNotNil(seen, 'the hook ran')
                assertEqual(seen.item, ITEM, 'the hook was told the real item')
                assertEqual(seen.metadata and seen.metadata.rounds, 12,
                    'the hook was told the state the SERVER holds')
                assertEqual(seen.amount, 2, 'the hook was told the real amount')

                exports.whip_core:ClosePanel(source, '_test_sm_panel')
            end,
        },

        -- ==========================================
        -- splitItem — one address, framework picks the slot
        -- ==========================================
        {
            name = 'splitItem divides a stack and conserves the total',
            fn = function(source, ctx)
                -- Kept as its own event because a split has no destination. What changed is
                -- that its address is now an 'addr' like everything else, instead of a
                -- hand-rolled enum with a slot hardcoded to 1..50.
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 6)

                ClientExecWait(source, 'whip_core:server:splitItem', 3000,
                    pAddr('player', S.p1), 2)

                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 6,
                    'splitting created nothing and destroyed nothing')
                local origin = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p1))
                assertNotNil(origin, 'the original slot still holds the remainder')
                assertEqual(origin.amount, 4, 'the split amount left the original stack')
            end,
        },
        {
            name = 'splitItem refuses an address the player cannot name',
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 6)

                ClientExecWait(source, 'whip_core:server:splitItem', 3000,
                    { kind = 'container', id = 999999, slot = 1 }, 2)

                local reason = exports.whip_core:__TestLastReject('whip_core:server:splitItem')
                assertNotNil(reason, 'the split was rejected')
                assertTrue(reason:find('not open for you', 1, true) ~= nil,
                    ('rejected for the expected reason (got "%s")'):format(tostring(reason)))
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 6, 'total conserved')
            end,
        },

        -- ==========================================
        -- 'addr' as the authorization gate — the negative cases
        -- ==========================================
        {
            name = 'A container the player has not opened cannot be addressed',
            fn = function(source, ctx)
                -- The open lock IS the authorization. Without this check any client could
                -- name any containerId on the server and empty it from across the map.
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 3)

                local c = CreateContainerNearPlayer(source, {
                    name = '_test_unopened', slots = 5, maxWeight = 20.0,
                })
                -- Recorded BEFORE anything can fail, so teardown deletes it either way. It used to
                -- be deleted on the last line, which a failed assertion never reaches.
                ctx.tempContainers[#ctx.tempContainers + 1] = c.containerId

                -- Deliberately NOT opened.
                storeMove(source, pAddr('player', S.p1),
                    { kind = 'container', id = c.containerId, slot = 1 })

                assertRefused('not open for you')
                local still = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p1))
                assertEqual(still and still.amount, 3, 'the item never left the player')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 3, 'total conserved')
            end,
        },
        {
            name = 'An OPEN container is addressable and the move persists',
            fn = function(source, ctx)
                -- The path the client now takes for every stash drag. Also the first test to
                -- prove 'addr' accepts a store when the lock IS held, rather than only that
                -- it refuses one when it is not.
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 4)

                local c = CreateContainerNearPlayer(source, {
                    name = '_test_storemove_ctr', slots = 10, maxWeight = 50.0,
                })
                ctx.tempContainers[#ctx.tempContainers + 1] = c.containerId   -- teardown's, if we fail
                OpenContainerOrFail(source, c.containerId)

                storeMove(source, pAddr('player', S.p1),
                    { kind = 'container', id = c.containerId, slot = 1 })

                assertNil(exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p1)),
                    'the item left the player')
                -- ####################################################################
                -- WHAT THE STORE LAYER OWED, READ BEFORE THE FLUSH.
                --
                -- When this fails it says "expected 4, got nil" — a missing row, with no way to
                -- tell which half broke: a move that never marked the container dirty, or a
                -- flush that dropped a unit it was holding.
                --
                -- FlushPersistence cannot separate them either, and that is worth knowing.
                -- Stores.flushAll returns `skipped == 0`, which is TRUE for an empty queue — so
                -- "the flush worked and the row is missing" and "there was nothing to write"
                -- report identically, and the helper's loud "still unwritten" error never fires
                -- for the second one.
                --
                -- These two seams separate the cases. NOT owed before the flush means the move
                -- is at fault; owed, and still no row afterwards, means the commit is.
                -- ####################################################################
                local cUnit   = 'container:' .. tostring(c.containerId)
                local wasOwed = exports.whip_core:__TestIsDirty(cUnit)
                local group   = exports.whip_core:__TestGroupUnits(cUnit) or {}

                FlushPersistence(source)
                assertDbScalar(
                    'SELECT `amount` FROM `container_inventory` WHERE `containerId` = ? AND `slot` = ?',
                    { c.containerId, 1 }, 4,
                    ('the item reached the container on disk (%s was %sowed before the flush; group: %s)')
                        :format(cUnit, wasOwed and '' or 'NOT ', table.concat(group, ' + ')))

                -- Back out again, so the fixture teardown can find it.
                storeMove(source, { kind = 'container', id = c.containerId, slot = 1 },
                    pAddr('player', S.p1))
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 4, 'total conserved')

                ClientCloseContainer(source, c.containerId)
            end,
        },
        {
            name = 'A non-integer id is refused rather than coerced',
            fn = function(source, ctx)
                -- Store ids index lock tables directly, or build a lock key by string
                -- concatenation. tostring(7.0) is "7.0", which matches no lock that
                -- tostring(7) created — and string.format('%d', 7.5) raises outright. Either
                -- way a fractional id must die at the boundary, not downstream.
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 3)

                storeMove(source, pAddr('player', S.p1), { kind = 'container', id = 7.5, slot = 1 })
                assertRefused('whole-number id')

                storeMove(source, pAddr('player', S.p1),
                    { kind = 'vehicle', id = 7.5, sub = 'trunk', slot = 1 })
                assertRefused('whole-number id')

                local still = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p1))
                assertEqual(still and still.amount, 3, 'nothing moved')
            end,
        },
        {
            name = 'The ignition cannot be addressed while on foot',
            fn = function(source, ctx)
                -- The ignition is authorized by PHYSICAL PRESENCE, not by an open lock.
                --
                -- ONE REFUSAL, NOT TWO. This expected 'you must be in the vehicle' because the
                -- check used to ask whether the player was in *a* vehicle, and a second, stricter
                -- message covered sitting in the wrong one. Both collapsed when the rule became
                -- the driver's seat of THIS car — a passenger could otherwise address the ignition
                -- and lift the key out of it mid-drive.
                --
                -- Matching the exact message rather than the substring 'vehicle' still matters:
                -- the trunk branch refuses with a message containing that word too, so a loose
                -- match would pass with this check deleted entirely.
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 1)

                storeMove(source, pAddr('player', S.p1),
                    { kind = 'vehicle', id = 999999, sub = 'key', slot = 1 })

                assertRefused('you must be in the driver seat')

                local still = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p1))
                assertEqual(still and still.amount, 1, 'nothing moved')
            end,
        },
        -- (A test followed here for "the ignition of a vehicle you are NOT sitting in". It could
        -- never run — nothing in this module ever set the ctx.vehiclePlate it skipped without —
        -- and the refusal it expected, 'not the vehicle you are sitting in', no longer exists:
        -- fromWire has ONE ignition rule now, "the driver's seat of this car", and the on-foot
        -- test above already pins its message. The case still worth having — a PASSENGER in the
        -- named car being refused — needs a car to sit in, which is 05_vehicles' fixture.)
        {
            name = 'A vehicle storage the player does not hold cannot be addressed',
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 3)

                storeMove(source, pAddr('player', S.p1),
                    { kind = 'vehicle', id = 999999, sub = 'trunk', slot = 1 })

                assertRefused('not open for you')
                local still = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p1))
                assertEqual(still and still.amount, 3, 'the item never left the player')
            end,
        },
        {
            name = 'rawInventory is not client-addressable',
            fn = function(source, ctx)
                -- rawInventory is the offline-admin path: its key is a charId. If a client
                -- could name it, a client could move items out of any offline character.
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 3)

                storeMove(source, pAddr('player', S.p1),
                    { kind = 'rawInventory', id = ctx.charId, slot = 1 })

                assertRefused('not a client-addressable store')
                local still = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p1))
                assertEqual(still and still.amount, 3, 'the move was refused')
            end,
        },
        {
            name = 'The target inventory is unreachable without an inspect session',
            fn = function(source, ctx)
                -- The admin inventory-inspect path resolves to a rawInventory store, which is
                -- another CHARACTER's items. The client may say "the target", never "charId
                -- 4" — the charId comes from a session the server opened after its own ACE
                -- check. With no session open there is no target, so this must refuse.
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 3)

                storeMove(source, pAddr('player', S.p1),
                    { kind = 'target', sub = 'player', slot = 1 })

                assertRefused('no player inventory open')
                local still = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p1))
                assertEqual(still and still.amount, 3, 'nothing moved')
            end,
        },
        -- ("A target address cannot smuggle in a charId" lived here, with NO session open — so it
        -- was refused as 'no player inventory open' before a charId could matter, which is the
        -- test above. It moved to 26_admin_inventory, where a session is open and the smuggled
        -- charId would actually have something to redirect.)
        {
            name = 'An unknown store kind is refused',
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 3)

                storeMove(source, pAddr('player', S.p1), { kind = 'admin_bank', slot = 1 })
                assertRefused('not a client-addressable store')
                storeMove(source, pAddr('player', S.p1), { kind = '../../etc', slot = 1 })
                assertRefused('not a client-addressable store')

                local still = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p1))
                assertEqual(still and still.amount, 3, 'neither bogus kind moved anything')
            end,
        },
        {
            name = 'A malformed address is refused rather than coerced',
            fn = function(source, ctx)
                -- Slot is an ADDRESS. Sanitize.int would clamp 0 up to 1 and 9999 down to the
                -- bound, i.e. act on a slot the caller never named — which for a destroy path
                -- means destroying the wrong item.
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 3)

                for _, bad in ipairs({ 0, -5, 1.5, 'two' }) do
                    storeMove(source, pAddr('player', S.p1), pAddr('player', bad))
                    assertRefused('slot must be a positive integer')
                end
                storeMove(source, pAddr('player', S.p1), 'not a table')
                assertRefused('address must be a table')

                local still = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p1))
                assertEqual(still and still.amount, 3, 'no malformed address moved anything')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 3, 'total conserved')
            end,
        },
        -- ("A slot past the end of a real store is refused" lived here — the same address, the
        -- same readMoveEnds bound and the same reason as 23_moves' out-of-range test. That one is
        -- the copy that stays: the split between "may you NAME this store" ('addr', above) and "is
        -- that a slot it has" (the store) is explained there.)

        -- ==========================================================
        -- THE EXPORT — a second entry point to the same operation
        --
        -- EVERYTHING ABOVE TESTS THE NET EVENT `whip_core:server:storeMove`, the path a player's
        -- drag takes. The EXPORT of the same name is what a satellite calls, and it had no
        -- coverage in this file at all — so when it turned out to perform the in-memory move and
        -- nothing else (no hooks, no persistence, no client sync), every test here stayed green.
        --
        -- That is the shape worth remembering: two implementations of one operation, one of them
        -- exercised and one of them not. They share Stores.commitMove now, and these tests exist
        -- so they cannot quietly come apart again.
        -- ==========================================================
        {
            name = 'the StoreMove EXPORT moves a stack, addressed the way the client addresses',
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 5)

                local ok, err = exports.whip_core:StoreMove(
                    { kind = 'player', id = source, sub = 'player', slot = S.p1 },
                    { kind = 'player', id = source, sub = 'player', slot = S.p2 }
                )

                assertTrue(ok, 'the export reported success: ' .. tostring(err))
                assertNil(exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p1)),
                    'source slot emptied')
                local moved = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p2))
                assertNotNil(moved, 'destination slot filled')
                assertEqual(moved.amount, 5, 'the whole stack moved')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 5, 'total conserved')
            end,
        },
        {
            -- 28 Sep 2026: whip_gunny left a drawn gun in the hand, firing, for up to ten seconds after
            -- it was dragged to another slot — a move changes no count, so item:added / item:removed
            -- said nothing and gunny could only poll. whip_core:inventory:changed says it, once.
            name = 'a move between your own slots announces whip_core:inventory:changed, once',
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 3)

                local heard = 0
                local handle = AddEventHandler('whip_core:inventory:changed', function(e)
                    if type(e) == 'table' and e.source == source then heard = heard + 1 end
                end)
                local ok, err = exports.whip_core:StoreMove(
                    { kind = 'player', id = source, sub = 'player', slot = S.p1 },
                    { kind = 'player', id = source, sub = 'player', slot = S.p2 }
                )
                waitFor(function() return heard > 0 end, 1000)
                Wait(250)   -- long enough for a second announcement to show up, if there were one
                RemoveEventHandler(handle)

                assertTrue(ok, 'the move went through: ' .. tostring(err))
                assertEqual(heard, 1, 'announced exactly once')
            end,
        },
        {
            name = 'the StoreMove EXPORT leaves the move OWED to the database, not just to memory',
            fn = function(source, ctx)
                -- THE ACTUAL BUG, ASSERTED DIRECTLY. The old export called Stores.move and
                -- returned, so the item appeared to move and was never queued for a write — it
                -- was back where it started after the next restart. Checking the slots cannot
                -- see that. Checking that the move left the unit DIRTY can.
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 4)
                FlushPersistence(source)   -- start from a clean queue, retrying a transient deadlock

                -- THIS UNIT, with the background writer held off, measured before it is judged.
                -- The whole-queue count this used includes character rows, which the stats tick
                -- marks every few seconds — "exactly zero owed" failed whenever it had just ticked.
                local unit = 'player:' .. ctx.charId
                exports.whip_core:__TestPauseFlushThread(true)
                local owedBefore = exports.whip_core:__TestIsDirty(unit)
                local ok, err = exports.whip_core:StoreMove(
                    { kind = 'player', id = source, sub = 'player', slot = S.p1 },
                    { kind = 'player', id = source, sub = 'player', slot = S.p3 }
                )
                local owedAfter = exports.whip_core:__TestIsDirty(unit)
                exports.whip_core:__TestPauseFlushThread(false)

                assertFalse(owedBefore, 'nothing owed for the player before the move')
                assertTrue(ok, 'the export reported success: ' .. tostring(err))
                assertTrue(owedAfter,
                    'the move is queued for the database — which the old export never did')

                FlushPersistence(source)
                assertFalse(exports.whip_core:__TestIsDirty(unit), 'and it lands')
                assertDbScalar(
                    'SELECT `amount` FROM `character_inventory` WHERE `charId` = ? AND `container` = ? AND `slot` = ?',
                    { ctx.charId, 'player', S.p3 }, 4, 'at the slot it was moved to')
            end,
        },
        {
            name = 'the StoreMove EXPORT refuses an address with no server-side meaning',
            fn = function(source, ctx)
                -- 'basket' exists only relative to a player with a shop open, so there is no
                -- server-wide "the basket" to address. Guessing one would put items into
                -- somebody's checkout; fromAddr says so instead.
                local ok, err = exports.whip_core:StoreMove(
                    { kind = 'player', id = source, sub = 'player', slot = S.p1 },
                    { kind = 'basket', slot = 1 }
                )
                assertTrue(not ok, 'refused')
                assertNotNil(err, 'and said why')
            end,
        },
        {
            -- REFUSED NOW, WITH A REASON (09-24). This was "still accepts the deprecated
            -- six-argument form": it was kept working for a while, on the view that breaking a
            -- caller was a worse way to tell them their call shape was outdated. It was removed
            -- with the rest of the old inventory API. What has to hold now is that an old caller
            -- hears WHY, and that nothing moves — its first argument must not be misread as an
            -- address.
            name = 'the StoreMove EXPORT refuses the removed six-argument form, and says why',
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.p1, ITEM, 2)

                local ok, err = exports.whip_core:StoreMove(
                    'player', { source = source, container = 'player' }, S.p1,
                    'player', { source = source, container = 'player' }, S.p4
                )

                assertFalse(ok, 'the old form is refused')
                assertTrue(tostring(err):find('takes two addresses', 1, true) ~= nil,
                    ('and the reason says what it takes instead (got "%s")'):format(tostring(err)))
                local still = exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.p1))
                assertEqual(still and still.amount, 2, 'and nothing moved')
            end,
        },
    },
})
