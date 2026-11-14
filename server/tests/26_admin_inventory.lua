-- ============================================
-- Admin inventory inspect — moving another character's items
--
-- WHY THIS MODULE EXISTS
--
-- This path had NO test coverage at all, and it is the one place in the framework where a
-- move crosses between two different characters. Two things make that dangerous:
--
--   1. It is the only client-facing move whose destination is somebody else's property. If
--      the address could name a charId, any client could empty any character on the server.
--      It cannot — the client says "the target" and the server supplies the charId from the
--      ACE-gated session it opened. These tests are the proof of that, not the comment.
--
--   2. Conservation spans TWO row-sets. A move here that loses an item loses it from a
--      character who is not present to notice.
--
-- The offline branch matters most: `deleted = 0` against a TIMESTAMP NULL column meant it had
-- literally never worked, so there is no history of it behaving correctly to fall back on.
--
-- THE TARGET IS A REAL CHARACTER, SO THIS MODULE MAY NOT TOUCH ANYTHING OF THEIRS.
--
-- It used to "clear" slots 20 and 21 of the target with a raw DELETE — AFTER opening the session.
-- The session had already loaded the target's inventory into a cache, so the delete emptied the
-- disk and left the cache holding whatever was really there; the next move onto that slot was a
-- SWAP, the target's real item landed in the tester's pockets, and the runner's cleanup then
-- deleted it. A test that could destroy another player's property on any given run.
--
-- Now: the target is an OFFLINE character (whose disk IS their inventory), the slots used are
-- ones already empty on disk, chosen BEFORE the session opens, and nothing of theirs is ever
-- deleted. If no such character or slot exists, the module skips rather than improvise.
-- ============================================

local ITEM = '_test_admininv'

--- Fire a move the way the inspect UI now does, and report why if it was refused.
---
--- Returns the rejection reason, or '' if nothing was rejected. Every assertion below
--- includes it, because "expected nil, got table" tells you a move did not happen and
--- nothing about WHY — and the reason is already recorded by SecureEvent, so there is no
--- excuse for a failure message that makes you go and guess.
---
--- ClientExecWait waits for the server's outcome, and a move that crosses into the target is
--- WRITE-THROUGH (rawInventory commits inside the handler), so by the time this returns the rows
--- are on disk and the reason read here is this move's own.
local function move(source, from, to)
    ClientExecWait(source, 'whip_core:server:storeMove', 3000, from, to, 0, 'move', 0)
    local reason = exports.whip_core:__TestLastReject('whip_core:server:storeMove')
    return reason and (' [server refused: ' .. tostring(reason) .. ']') or ''
end

local function own(container, slot)  return { kind = container, slot = slot } end
local function target(container, slot) return { kind = 'target', sub = container, slot = slot } end

--- Open an inspect session that will still be alive when the next move arrives.
---
--- Two ways this bites, both found the hard way:
---
---   1. OpenPlayerInventory returns FALSE when a session is already open — deliberately, so
---      an admin cannot stack two inspections. A test that opens without closing passes once
---      and then fails for a reason unrelated to what it is testing.
---
---   2. The server creating the session is only half of it. It then tells the CLIENT to show
---      the UI, and whip_core's OpenInventoryUI refuses to open over an existing UI — at
---      which point the client fires closePlayerInventory to release the session, because
---      leaving it open would lock the target out of their own inventory forever. That is
---      correct behaviour. It also means that if an earlier module left a panel or container
---      UI up, this session is destroyed a round-trip after it is created, and the move that
---      follows is refused with "you have no player inventory open".
---
--- So: close the UI first, THEN open. The close has to complete before the open, which is why
--- it goes through the client and waits.
local function openSession(source, charId)
    pcall(exports.whip_core.ClosePlayerInventory, exports.whip_core, source)
    ClientCloseAllUI(source)
    -- The target is a person: { charId = n } for a character (whip's person rule, audit 3 DX-17).
    -- An admin inspect: no range leash (audit 4, INV-5 — the export's default is 5 m).
    assertTrue(exports.whip_core:OpenPlayerInventory(source, { charId = charId }, { range = false }),
        'inspect session opened for charId ' .. tostring(charId))
end

--- Read a slot straight from the database — the tester's own cache cannot see the target.
local function targetSlot(charId, container, slot)
    local rows = DbQuery(
        'SELECT `item`, `amount` FROM `character_inventory` WHERE `charId` = ? AND `container` = ? AND `slot` = ?',
        { charId, container, slot })
    return rows[1]
end

--- The target slots must be EMPTY when a test starts. setup proved them empty on disk, but a test
--- that moves our fixture there and does not bring it home leaves it behind — and the next test's
--- move onto the same slot then MERGES with it. That read as "4 went in, 8 came back" on 09-23: no
--- item was minted (the total was conserved across both tests), the fixture had just been left in
--- the target by the test before. Every test that puts something on the target now takes it back,
--- and every test checks the slots first so a leftover names itself instead of looking like a dupe.
local function assertTargetEmpty(ctx)
    assertNil(targetSlot(ctx.targetCharId, 'player', ctx.t1),
        ('target slot %d is empty before the test (an earlier test left our fixture there?)'):format(ctx.t1))
    assertNil(targetSlot(ctx.targetCharId, 'player', ctx.t2),
        ('target slot %d is empty before the test'):format(ctx.t2))
end

--- Reserve an empty slot at the far end of the TESTER's pockets (24_placement's claim idiom). The
--- target side is not claimed this way — nothing of the target's may be removed — see setup.
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

RegisterTestModule({
    order    = 26,
    category = 'Admin Inventory',

    setup = function(source, ctx)
        exports.whip_core:RegisterItem(ITEM, {
            name = 'Admin Inspect Fixture', desc = 'admin inventory fixture',
            weight = 0.1, type = 'misc', stack = true, maxStack = 10,
        })

        local p = exports.whip_core:GetPlayer(source)
        assertNotNil(p, 'setup: GetPlayer')
        ctx.charId = p.charId

        -- A real OTHER character, and an OFFLINE one. Fabricating a charId would hit the
        -- characters foreign key, and picking one that does not exist would make every test
        -- below pass for the wrong reason. Offline, because an online target's inventory is a
        -- live cache ahead of its rows — the disk reads below would not be the truth, and the
        -- items being moved about would be in a playing person's pockets.
        local online = {}
        for _, pl in pairs(exports.whip_core:GetPlayers() or {}) do
            if pl.charId then online[pl.charId] = true end
        end
        for _, row in ipairs(DbQuery(
            'SELECT `charId` FROM `characters` WHERE `charId` <> ? AND `deleted` IS NULL ORDER BY `charId`',
            { p.charId })) do
            if not online[row.charId] then ctx.targetCharId = row.charId break end
        end
        if not ctx.targetCharId then
            skip('no second, offline character on this server to inspect')
        end

        -- TWO slots EMPTY ON DISK, chosen before any session exists. For an offline character
        -- the rows ARE the inventory, so an empty row is an empty slot; the session loads exactly
        -- this. From the top down, where a real character is least likely to keep anything.
        local used = {}
        for _, row in ipairs(DbQuery(
            'SELECT `slot` FROM `character_inventory` WHERE `charId` = ? AND `container` = ?',
            { ctx.targetCharId, 'player' })) do
            used[row.slot] = true
        end
        local free = {}
        for slot = exports.whip_core:GetPocketSlots('player'), 1, -1 do
            if not used[slot] then free[#free + 1] = slot end
            if #free == 2 then break end
        end
        if #free < 2 then
            skip(('character %d has no two empty pocket slots to borrow'):format(ctx.targetCharId))
        end
        ctx.t1, ctx.t2 = free[1], free[2]

        RemoveAllOf(source, ITEM)
    end,

    teardown = function(ctx, source)
        if not source then return end
        pcall(exports.whip_core.ClosePlayerInventory, exports.whip_core, source)
        RemoveAllOf(source, ITEM)
        -- OUR FIXTURE ONLY, by item key: a test that failed between its two moves can leave it
        -- sitting in the target's rows. The session is closed above and the target is offline,
        -- so the rows are the whole truth and nothing will write them back. Nothing else of the
        -- target's is touched.
        if ctx.targetCharId then
            pcall(MySQL.query.await,
                'DELETE FROM `character_inventory` WHERE `charId` = ? AND `item` = ?',
                { ctx.targetCharId, ITEM })
        end
    end,

    tests = {
        {
            -- ####################################################################
            -- RENAMED, AND GIVEN SOMETHING TO ASSERT.
            --
            -- This was called "makes the target addressable" and its entire body was the
            -- openSession call — so it never once checked addressability. The only reason it
            -- was not a complete no-op is that the helper asserts the session opened; the test
            -- itself contributed nothing, and the test AFTER this one is what actually proves
            -- a target address resolves.
            --
            -- What it now covers is a rule with no coverage anywhere: a SECOND session is
            -- refused while one is open. The helper's own comment calls that out as something
            -- learned the hard way — "a test that opens without closing passes once and then
            -- fails for a reason unrelated to what it is testing" — but nothing asserted the
            -- rule, so an admin quietly gaining two live inspect sessions would have broken
            -- tests all over this module and been diagnosed here last.
            -- ####################################################################
            name = 'Opening an inspect session succeeds, and a second is refused',
            fn = function(source, ctx)
                openSession(source, ctx.targetCharId)

                assertFalse(exports.whip_core:OpenPlayerInventory(source, { charId = ctx.targetCharId }),
                    'a second inspect session is refused while one is open')

                -- NOTE THE ARGUMENT: this takes the TARGET's charId, not the admin's source.
                -- It answers "is this character being inspected", which is the question that
                -- stops two admins opening the same person at once. (IsPlayerInventoryOpen until
                -- 09-24, renamed to say that.)
                assertTrue(exports.whip_core:IsCharacterBeingInspected(ctx.targetCharId),
                    'the target reads as under inspection while the session is live')
            end,
        },
        {
            name = 'Admin -> target moves the item to the OTHER character',
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                assertTargetEmpty(ctx)
                local mine = claim(source, 1)
                SeedSlot(source, 'player', mine, ITEM, 4)
                openSession(source, ctx.targetCharId)

                local why = move(source, own('player', mine), target('player', ctx.t1))

                assertNil(exports.whip_core:GetItemAt(PocketAddr(source, 'player', mine)),
                    'the item left the admin' .. why)
                local landed = targetSlot(ctx.targetCharId, 'player', ctx.t1)
                assertNotNil(landed, 'the item reached the target on disk' .. why)
                assertEqual(landed.item, ITEM, 'the target slot holds OUR item — it was empty, so no swap')
                assertEqual(landed.amount, 4, 'the whole stack arrived, exactly once')

                -- Bring it home, so the next test starts from an empty target slot (see assertTargetEmpty).
                why = move(source, target('player', ctx.t1), own('player', mine))
                assertNil(targetSlot(ctx.targetCharId, 'player', ctx.t1), 'returned from the target' .. why)
            end,
        },
        {
            name = 'Target -> admin takes it back, conserving the total',
            fn = function(source, ctx)
                -- SEEDS ITS OWN FIXTURE on the target rather than relying on the test above, and
                -- brings it back into a slot proved empty — the admin's slot 2 was never cleared,
                -- so an item left there turned this into a swap that put the admin's item into
                -- the other character, where teardown could not find it.
                RemoveAllOf(source, ITEM)
                assertTargetEmpty(ctx)
                local mine, back = claim(source, 1), claim(source, 2)
                SeedSlot(source, 'player', mine, ITEM, 4)
                openSession(source, ctx.targetCharId)

                local why = move(source, own('player', mine), target('player', ctx.t1))
                assertNotNil(targetSlot(ctx.targetCharId, 'player', ctx.t1), 'seeded onto the target' .. why)

                why = move(source, target('player', ctx.t1), own('player', back))

                assertNil(targetSlot(ctx.targetCharId, 'player', ctx.t1), why ..
                    'the target row was deleted, not left behind as a copy')
                local returned = exports.whip_core:GetItemAt(PocketAddr(source, 'player', back))
                assertEqual(returned and returned.amount, 4, 'the same amount came back — nothing minted or lost')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 4, 'total conserved')
            end,
        },
        {
            name = "Rearranging within the target's own containers conserves the total",
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                assertTargetEmpty(ctx)
                local mine = claim(source, 1)
                SeedSlot(source, 'player', mine, ITEM, 3)
                openSession(source, ctx.targetCharId)

                local why = move(source, own('player', mine), target('player', ctx.t1))
                assertNotNil(targetSlot(ctx.targetCharId, 'player', ctx.t1), 'seeded onto the target' .. why)

                why = move(source, target('player', ctx.t1), target('player', ctx.t2))

                assertNil(targetSlot(ctx.targetCharId, 'player', ctx.t1), 'source slot cleared' .. why)
                local moved = targetSlot(ctx.targetCharId, 'player', ctx.t2)
                assertEqual(moved and moved.amount, 3, 'the stack moved intact within the target')

                -- Put it back so teardown finds nothing stranded.
                why = move(source, target('player', ctx.t2), own('player', mine))
                assertNil(targetSlot(ctx.targetCharId, 'player', ctx.t2), 'returned from the target' .. why)
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 3, 'total conserved')
            end,
        },
        {
            -- MOVED HERE FROM 25_storemove, where it ran with no session open — so it was refused
            -- as 'no player inventory open' before a charId could matter, which proved nothing
            -- about charIds. With a session open the address resolves, and the question is real:
            -- does anything the client puts on it change WHOSE inventory it lands in?
            name = "A target address cannot smuggle in a charId — it lands in the session's target",
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                assertTargetEmpty(ctx)
                local mine = claim(source, 1)
                SeedSlot(source, 'player', mine, ITEM, 2)
                openSession(source, ctx.targetCharId)

                -- Names the TESTER's own character, twice over. fromWire reads neither field.
                local why = move(source, own('player', mine),
                    { kind = 'target', sub = 'player', slot = ctx.t1, id = ctx.charId, charId = ctx.charId })

                local landed = targetSlot(ctx.targetCharId, 'player', ctx.t1)
                assertNotNil(landed, 'the item went to the session\'s target' .. why)
                assertEqual(landed.amount, 2, 'all of it')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 0,
                    'and not into the character the address named')

                -- Bring it home, so the next test starts clean.
                move(source, target('player', ctx.t1), own('player', mine))
                assertNil(targetSlot(ctx.targetCharId, 'player', ctx.t1), 'returned from the target')
            end,
        },
        {
            name = 'Closing the session makes the target unaddressable again',
            fn = function(source, ctx)
                -- The session IS the authorization. Once it is closed the same address that
                -- worked a moment ago must stop working — otherwise an admin who inspected
                -- someone once could reach them forever.
                openSession(source, ctx.targetCharId)
                exports.whip_core:ClosePlayerInventory(source)

                RemoveAllOf(source, ITEM)
                local mine = claim(source, 1)
                SeedSlot(source, 'player', mine, ITEM, 2)

                move(source, own('player', mine), target('player', ctx.t1))

                -- The REASON, not just the stillness: an item that stayed put is also what any
                -- other refusal, or a dropped event, leaves behind.
                local reason = exports.whip_core:__TestLastReject('whip_core:server:storeMove')
                assertTrue(reason ~= nil and reason:find('no player inventory open', 1, true) ~= nil,
                    ('refused because no session is open (got %s)'):format(tostring(reason)))
                local still = exports.whip_core:GetItemAt(PocketAddr(source, 'player', mine))
                assertEqual(still and still.amount, 2, 'the move was refused after the session closed')
                assertNil(targetSlot(ctx.targetCharId, 'player', ctx.t1), 'nothing reached the target')
            end,
        },
    },
})
