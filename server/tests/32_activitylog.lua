-- ============================================
-- Activity log — the uid stamp and the two timelines
--
-- WHY THIS MODULE EXISTS
--
-- The item-timeline feature rests on one mechanism: a uid stamped into an item
-- instance's METADATA at its first logged touch, riding the metadata through every
-- move, give, drop, ground row and pickup. If the stamp stops travelling — a store
-- kind starts copying metadata, a rollback rebuilds a table — item timelines quietly
-- fragment into single-event orphans and nobody notices until an admin needs one.
-- These tests pin the stamp's journey through the roughest trip an item takes:
-- pocket → placed on the ground → picked back up.
-- ============================================

local ITEM = '_test_actlog'

local function logRowsFor(uid)
    return DbQuery(
        'SELECT `event`, `charId`, `itemUid`, `amount` FROM `activity_log` WHERE `itemUid` = ? ORDER BY `id` ASC',
        { uid })
end

local function clearLogs()
    DbQuery('DELETE FROM `activity_log` WHERE `itemKey` = ?', { ITEM })
end

--- Through whip_core, not SQL. A raw DELETE leaves the row in GroundItems' cache and grid, where it
--- keeps rendering and can still be picked up — conjuring the item back from nothing.
local function clearGround()
    for _, row in ipairs(DbQuery('SELECT `id` FROM `ground_items` WHERE `item` = ?', { ITEM })) do
        pcall(exports.whip_core.DeleteGroundItem, exports.whip_core, row.id)
    end
end

--- The n-th slot from the end of a pocket, emptied for this module. (GetPocketSlots, StoreTake and
--- GetItemAt since 09-24; GetContainerSlots, RemoveItemFromSlot and GetSlotData were removed.)
local function claim(source, container, n)
    local slots = exports.whip_core:GetPocketSlots(container)
    assertNotNil(slots, 'slot count known')
    local slot = slots - n + 1
    exports.whip_core:StoreTake(PocketAddr(source, container, slot))   -- false when already empty
    assertNil(exports.whip_core:GetItemAt(PocketAddr(source, container, slot)), 'reserved slot is empty')
    return slot
end

local S = {}

RegisterTestModule({
    order    = 32,
    category = 'Activity Log',

    setup = function(source, ctx)
        exports.whip_core:RegisterItem(ITEM, {
            name = 'Log Fixture', desc = 'activity log fixture',
            weight = 0.1, type = 'misc', stack = true, maxStack = 10,
        })
        clearGround()
        RemoveAllOf(source, ITEM)
        S.slot = claim(source, 'player', 5)

        local ped = GetPlayerPed(source)
        local pos = GetEntityCoords(ped)
        ctx.x, ctx.y, ctx.z = pos.x, pos.y, pos.z
        ctx.charId = exports.whip_core:GetPlayer(source).charId
    end,

    teardown = function(ctx, source)
        clearGround()
        clearLogs()
        if source then RemoveAllOf(source, ITEM) end
        if ctx.charId then
            DbQuery('DELETE FROM `activity_log` WHERE `charId` = ? AND `event` = ?', { ctx.charId, 'test_event' })
        end
    end,

    tests = {
        {
            name = 'A placement mints the uid, logs first_seen, and the pickup shares the timeline',
            fn = function(source, ctx)
                clearGround()
                SeedSlot(source, 'player', S.slot, ITEM, 2)

                -- Place → the item's first logged touch: uid minted, first_seen + placed.
                assertTrue(ClientExecWait(source, 'whip_core:server:placeItem', 3000,
                    'player', S.slot, 2, ctx.x + 1.0, ctx.y, ctx.z, 0.0, 0.0, 0.0), 'server answered the place')
                assertLastReject('whip_core:server:placeItem', nil, 'place accepted')

                local ground = DbQuery('SELECT `id`, `metadata` FROM `ground_items` WHERE `item` = ?', { ITEM })
                assertEqual(#ground, 1, 'ground row exists')
                local meta = json.decode(ground[1].metadata or '{}') or {}
                assertNotNil(meta.uid, 'the ground row metadata carries the minted uid')
                local uid = meta.uid

                -- Pick it back up — the SAME uid must ride home in the metadata.
                assertTrue(ClientExecWait(source, 'whip_core:server:quickPickupGroundItem', 3000, ground[1].id),
                    'server answered the pickup')
                assertLastReject('whip_core:server:quickPickupGroundItem', nil, 'pickup accepted')

                -- The pickup writes its row LAST, after the inventory flush, so poll for it rather than
                -- read once and race the handler's tail.
                local rows = waitFor(function()
                    exports.whip_core:FlushActivityLog()
                    local r = logRowsFor(uid)
                    for _, row in ipairs(r) do
                        if row.event == 'picked_up' then return r end
                    end
                    return nil
                end, 5000)
                assertNotNil(rows, 'a picked_up row landed for this uid')
                assertEqual(rows[1].event, 'first_seen', 'the timeline opens with first_seen')
                local sawPlaced = false
                for _, r in ipairs(rows) do
                    if r.event == 'placed' then sawPlaced = true end
                end
                assertTrue(sawPlaced, 'the placement is on the item timeline')

                -- And the instance in the pocket still carries it, ready for its next event.
                -- (FindItem answers { item, amount, metadata, addr } since 09-24 — no `.data`.)
                local found = exports.whip_core:FindItem(source, ITEM)
                assertNotNil(found, 'the stack is back in a pocket')
                assertEqual(found.amount, 2, 'the whole stack came back')
                assertEqual(found.metadata and found.metadata.uid, uid,
                    'the pocket stack carries the SAME uid the ground row had')
            end,
        },
        {
            name = 'Destroy closes a timeline with the same uid',
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.slot, ITEM, 1)
                -- First touch via destroy: mints uid and logs first_seen + destroyed. The event takes
                -- the slot as an address (the wire form the NUI sends) since 24 Sep 2026.
                assertTrue(ClientExecWait(source, 'whip_core:server:destroyItem', 3000,
                        { kind = 'player', slot = S.slot }, 0),
                    'server answered the destroy')
                assertTrue(exports.whip_core:FlushActivityLog(), 'activity log flushed')

                local rows = DbQuery(
                    'SELECT `event`, `itemUid` FROM `activity_log` WHERE `itemKey` = ? ORDER BY `id` DESC LIMIT 2',
                    { ITEM })
                assertEqual(#rows, 2, 'two rows written')
                assertEqual(rows[1].event, 'destroyed', 'destroyed is the newest row')
                assertEqual(rows[2].event, 'first_seen', 'first_seen precedes it')
                assertNotNil(rows[1].itemUid, 'destroyed row is tied to an instance')
                assertEqual(rows[1].itemUid, rows[2].itemUid, 'both rows share one uid')
                assertNil(exports.whip_core:GetItemAt(PocketAddr(source, 'player', S.slot)), 'and the slot is empty')
            end,
        },
        {
            name = 'The satellite export writes a player row, detail verbatim',
            fn = function(source, ctx)
                local ok = exports.whip_core:LogActivity(source, 'test_event', 'from 32_activitylog')
                assertTrue(ok, 'plain export write accepted')
                assertTrue(exports.whip_core:FlushActivityLog(), 'activity log flushed')

                local rows = DbQuery(
                    'SELECT `event`, `detail`, `itemUid` FROM `activity_log` WHERE `charId` = ? AND `event` = ? ORDER BY `id` DESC LIMIT 1',
                    { ctx.charId, 'test_event' })
                assertEqual(#rows, 1, 'the row landed against the acting character')
                assertEqual(rows[1].detail, 'from 32_activitylog', 'detail stored verbatim')
                assertNil(rows[1].itemUid, 'no slot named, so no item timeline')
                DbQuery('DELETE FROM `activity_log` WHERE `charId` = ? AND `event` = ?', { ctx.charId, 'test_event' })
            end,
        },
        {
            -- THE DOCUMENTED FORM USED TO BE UNREACHABLE. The export asked for "the live slot table",
            -- and a satellite can only ever hand it a copy — so the uid it minted went into the copy,
            -- every call began a new timeline, and the real item never got one. It now takes the
            -- slot's ADDRESS and stamps the real slot.
            name = 'LogActivity with a slot address mints into the REAL item, and the next call joins it',
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.slot, ITEM, 1)
                -- Earlier tests' rows for this item would otherwise be read as this one's.
                assertTrue(exports.whip_core:FlushActivityLog(), 'earlier rows out before clearing')
                clearLogs()

                -- A whip address since 09-24 — the same one GetItemAt, StoreTake and a use handler
                -- use. It was `{ container = 'player', slot = n }`, which is now refused (see below).
                local addr = PocketAddr(source, 'player', S.slot)
                assertNil((exports.whip_core:GetItemAt(addr).metadata or {}).uid,
                    'precondition: the fixture has no uid yet')

                assertTrue(exports.whip_core:LogActivity(source, 'test_event', 'first', addr), 'first call accepted')
                assertTrue(exports.whip_core:LogActivity(source, 'test_event', 'second', addr), 'second call accepted')

                local live = exports.whip_core:GetItemAt(addr)
                local uid = live and live.metadata and live.metadata.uid
                assertNotNil(uid, 'the REAL slot now carries a uid')

                assertTrue(exports.whip_core:FlushActivityLog(), 'activity log flushed')
                local rows = DbQuery(
                    'SELECT `event`, `itemUid`, `detail` FROM `activity_log` WHERE `charId` = ? AND `event` IN (?, ?) '
                    .. 'AND `itemKey` = ? ORDER BY `id` ASC',
                    { ctx.charId, 'first_seen', 'test_event', ITEM })
                local events, seenFirst = 0, 0
                for _, r in ipairs(rows) do
                    assertEqual(r.itemUid, uid, 'every row sits on the real item\'s uid')
                    if r.event == 'test_event' then events = events + 1 end
                    if r.event == 'first_seen' then seenFirst = seenFirst + 1 end
                end
                assertEqual(events, 2, 'both calls landed on one timeline')
                assertEqual(seenFirst, 1, 'the timeline was born ONCE, not once per call')

                -- The mint is metadata like any other: it must reach disk with the item.
                assertDbScalar(
                    'SELECT JSON_UNQUOTE(JSON_EXTRACT(`metadata`, \'$.uid\')) FROM `character_inventory` '
                    .. 'WHERE `charId` = ? AND `container` = ? AND `slot` = ?',
                    { ctx.charId, 'player', S.slot }, uid, 'the uid is on disk')
            end,
        },
        {
            -- A COPY (GetItemAt's answer) is still accepted for callers written the old way, but a
            -- uid minted into a copy belongs to nothing, so none is.
            name = 'LogActivity with a slot COPY never mints, and uses a uid the copy already carries',
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', S.slot, ITEM, 1)
                assertTrue(exports.whip_core:FlushActivityLog(), 'earlier rows out before clearing')
                clearLogs()

                local addr = PocketAddr(source, 'player', S.slot)
                local copy = exports.whip_core:GetItemAt(addr)
                assertTrue(exports.whip_core:LogActivity(source, 'test_event', 'copy-no-uid', copy), 'accepted')
                local live = exports.whip_core:GetItemAt(addr)
                assertNil(live.metadata and live.metadata.uid, 'nothing was minted onto the real item')

                -- Give the real item a uid through the address form, then pass a fresh copy.
                assertTrue(exports.whip_core:LogActivity(source, 'test_event', 'mint', addr), 'the address call minted')
                local uid = exports.whip_core:GetItemAt(addr).metadata.uid
                local copy2 = exports.whip_core:GetItemAt(addr)
                assertTrue(exports.whip_core:LogActivity(source, 'test_event', 'copy-with-uid', copy2), 'accepted')

                assertTrue(exports.whip_core:FlushActivityLog(), 'activity log flushed')
                local rows = DbQuery(
                    'SELECT `detail`, `itemUid`, `itemKey` FROM `activity_log` WHERE `charId` = ? AND `event` = ? '
                    .. 'AND `detail` IN (?, ?) ORDER BY `id` ASC',
                    { ctx.charId, 'test_event', 'copy-no-uid', 'copy-with-uid' })
                assertEqual(#rows, 2, 'both copy calls wrote a row')
                assertEqual(rows[1].itemKey, ITEM, 'the copy still names the item')
                assertNil(rows[1].itemUid, 'no uid invented for a copy that had none')
                assertEqual(rows[2].itemUid, uid, 'a copy that carries the real uid joins its timeline')
            end,
        },
        {
            -- By whip address since 09-24. The bad-pocket reason now comes from resolving the address
            -- (Stores.fromAddr), so that one asserts only that there IS a reason, not its wording.
            name = 'An address that names nothing is refused',
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                local ok, err = exports.whip_core:LogActivity(source, 'test_event', 'x', PocketAddr(source, 'player', S.slot))
                assertFalse(ok, 'empty slot refused')
                assertEqual(err, 'Empty slot', 'with the reason')
                ok, err = exports.whip_core:LogActivity(source, 'test_event', 'x', PocketAddr(source, 'nope', 1))
                assertFalse(ok, 'unknown pocket refused')
                assertTrue(type(err) == 'string' and err ~= '', ('with a reason (got %s)'):format(tostring(err)))
                ok, err = exports.whip_core:LogActivity(source, 'test_event', 'x', PocketAddr(source, 'player', 0))
                assertFalse(ok, 'slot 0 refused')
                assertEqual(err, 'slot must be a positive integer', 'with the reason')

                -- The old `{ container, slot }` spelling is refused OUT LOUD (09-24), rather than
                -- falling through and writing a row tied to no item.
                ok, err = exports.whip_core:LogActivity(source, 'test_event', 'x', { container = 'player', slot = S.slot })
                assertFalse(ok, 'the old { container, slot } form is refused')
                assertTrue(type(err) == 'string' and err:find('address', 1, true) ~= nil,
                    ('with a reason that names the address form (got %s)'):format(tostring(err)))
            end,
        },
        {
            -- Items ENTERING and LEAVING the game, not moving within it. This is the half of the log
            -- a dupe shows up in: before these rows existed, an item a satellite (or a bug) created
            -- simply appeared, and its timeline began at the first time a player moved it.
            name = 'Items entering and leaving through the exports are logged, with who asked',
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                assertTrue(exports.whip_core:FlushActivityLog(), 'RemoveAllOf\'s own row, out before clearing')
                clearLogs()

                -- AddItem answers where the item went (09-24); a drop at the tester's feet would log
                -- a different detail, so the pockets are what this needs.
                local where, err = exports.whip_core:AddItem(source, ITEM, 3)
                assertEqual(where, 'inventory', 'AddItem put it in the pockets: ' .. tostring(err))
                assertTrue(exports.whip_core:RemoveItem(source, ITEM, 3), 'RemoveItem accepted')
                assertTrue(exports.whip_core:FlushActivityLog(), 'activity log flushed')

                local rows = DbQuery(
                    'SELECT `event`, `amount`, `detail` FROM `activity_log` WHERE `itemKey` = ? ORDER BY `id` ASC',
                    { ITEM })
                assertEqual(#rows, 2, 'one row in, one row out')
                assertEqual(rows[1].event, 'gained', 'the add is logged as gained')
                assertEqual(rows[2].event, 'lost', 'the remove is logged as lost')
                assertEqual(rows[1].amount, 3, 'gained amount')
                assertEqual(rows[2].amount, 3, 'lost amount')
                assertEqual(rows[1].detail, 'by whip_test', 'the gain names the resource that asked')
                assertEqual(rows[2].detail, 'by whip_test', 'so does the loss')
            end,
        },
        {
            -- The exports took no reason, so every row a satellite caused read "by <resource>" and
            -- an admin could not tell a sale from a refund (AI build test, 09-24). The reason goes
            -- in beside the name; the name stays, because it is the part a caller cannot choose.
            name = 'A reason given to the item and cash exports is logged beside the resource',
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                assertTrue(exports.whip_core:FlushActivityLog(), 'earlier rows out before clearing')
                clearLogs()

                local where, err = exports.whip_core:AddItem(source, ITEM, 2, nil, 'quest reward')
                assertEqual(where, 'inventory', 'AddItem put it in the pockets: ' .. tostring(err))
                assertTrue(exports.whip_core:RemoveItem(source, ITEM, 1, 'used up'), 'RemoveItem accepted')
                local found = exports.whip_core:FindItem(source, ITEM)
                assertNotNil(found, 'one left to take from its slot')
                -- StoreTake from the slot FindItem names (09-24: RemoveItemFromSlot was removed, and
                -- FindItem hands back `addr` in place of container and slot). It answers the taken stack.
                local taken, takeErr = exports.whip_core:StoreTake(found.addr, 1, { reason = 'handed in' })
                assertOk(taken, takeErr, 'StoreTake accepted')

                if not exports.whip_core:AddPlayerCash(source, 1, 'test wage') then
                    skip('no room in your pockets for a banknote')
                end
                assertTrue(exports.whip_core:RemovePlayerCash(source, 1, 'test fee'), 'RemovePlayerCash accepted')
                assertTrue(exports.whip_core:FlushActivityLog(), 'activity log flushed')

                -- ONLY THE GAINS AND LOSSES (09-24). A take from one slot is written on that item's OWN
                -- timeline (Log.item, as RemoveItemFromSlot's was), so an item with no uid yet also gets
                -- its first_seen row there, just before the loss. That row belongs to the timeline, not
                -- to this test. StoreTake also names the store the item came out of.
                local rows = DbQuery(
                    'SELECT `event`, `detail`, `itemUid` FROM `activity_log` WHERE `itemKey` = ? AND `event` IN (?, ?) '
                    .. 'ORDER BY `id` ASC', { ITEM, 'gained', 'lost' })
                assertEqual(#rows, 3, 'three rows for the fixture item')
                assertEqual(rows[1].detail, 'quest reward · by whip_test', 'AddItem: the reason, then who asked')
                assertEqual(rows[2].detail, 'used up · by whip_test', 'RemoveItem the same')
                assertEqual(rows[3].detail, 'handed in · by whip_test · from Player Inventory',
                    'StoreTake the same, then the store it came out of')
                assertNotNil(rows[3].itemUid, 'a take from ONE slot sits on that item\'s own timeline')

                local cash = DbQuery(
                    'SELECT `event`, `detail` FROM `activity_log` WHERE `charId` = ? AND `itemKey` = ? '
                    .. 'AND `detail` IN (?, ?) ORDER BY `id` ASC',
                    { ctx.charId, 'cash', 'test wage · by whip_test', 'test fee · by whip_test' })
                DbQuery('DELETE FROM `activity_log` WHERE `charId` = ? AND `itemKey` = ? AND `detail` IN (?, ?)',
                    { ctx.charId, 'cash', 'test wage · by whip_test', 'test fee · by whip_test' })
                assertEqual(#cash, 2, 'both cash rows carry their reason')
                assertEqual(cash[1].event, 'gained', 'the wage is a gain')
                assertEqual(cash[2].event, 'lost', 'the fee is a loss')
            end,
        },
    },
})
