-- ============================================
-- Inventory API (2026-09-24) — the INV-* list from the API TODO, and round 2
--
-- WHY THIS MODULE EXISTS
--
-- The inventory section of the API review was worked top to bottom on 09-24 (plan file
-- whip-api-todo-2026-09-23.md, section 3), and then a second time the same day to take it from a 7
-- to an 8 or 9 — one way to do each thing, the old names removed (INV-R). What can be proved through
-- exports is proved here:
--
--   * INV-1 / INV-2  a mistyped item or a bad amount is refused — never a ghost item on the ground
--   * one answer     AddItem answers WHERE it went; CanFitItem answers true or a reason
--   * INV-12         AddItem's reason / options table (noDrop, pocket)
--   * one handle     a slot is an address: GetItemAt, SetItemMetadata (any store), StoreTake,
--                    FindItem's `addr`, a context action's `addr`, LogActivity's slot
--   * INV-3          StoreGive / StoreTake / StoreRead / StoreCount / FindItemByUid, a stash loaded
--                    on demand, panels and the accessory strip by address, StoreMove to "wherever"
--   * INV-8 / INV-9  item events for every change to the pockets, and a logged StoreMove
--   * panels         a panel's rules hold for server writes; its onValidate / onChange / onClose
--   * INV-16         OpenStore / CloseStore — a stash, and a resource's own store kind
--   * INV-4 / INV-5  another resource's context action gets the sheet; whip's own can't be taken
--   * INV-15/17/18/21 GetOpenStores, shop reasons, the ground table form, GetPockets
--
-- Not here, because it needs a second client: INV-6 (what another viewer is shown).
-- ============================================

local ITEM   = '_test_inv43'          -- stacks to 10, light
local HEAVY  = '_test_inv43_heavy'    -- heavier than any pocket
local SINGLE = '_test_inv43_single'   -- one per slot, carries metadata
local CTX    = '_test_inv43_ctx'      -- has a context option only this module handles
local PANEL  = '_test_inv43_panel'
local KIND   = '_t43box'              -- a store kind this module registers, then OPENS
local BADKIND = '_t43bad'             -- one whose instanceId borrows another kind's name
local BAG, BAG_ACTION = '_test_inv43_bag', '_t43_open_bag'   -- an item that opens its own panel

local OURS = { [ITEM] = true, [HEAVY] = true, [SINGLE] = true, [CTX] = true, [BAG] = true, cash = true }

--- The item events whip announced, newest last, for our items only. File scope, so the handlers
--- are registered once per resource start rather than once per run.
---
--- The current names (EVT-2): one table, { source, item, amount, count, reason, by }, kept whole
--- as `info`. The old itemAdded / itemRemoved aliases are module 46's to test, not this one's.
local _events = {}
AddEventHandler('whip_core:item:added', function(e)
    if OURS[e.item] then _events[#_events + 1] = { kind = 'added', src = e.source, item = e.item, amount = e.amount, info = e } end
end)
AddEventHandler('whip_core:item:removed', function(e)
    if OURS[e.item] then _events[#_events + 1] = { kind = 'removed', src = e.source, item = e.item, amount = e.amount, info = e } end
end)

--- The events recorded since `from` for one item.
local function eventsFor(from, item)
    local out = {}
    for i = from + 1, #_events do
        if _events[i].item == item then out[#out + 1] = _events[i] end
    end
    return out
end

--- What the context-action handler below was last handed.
local _ctxPlayer, _ctxAddr = nil, nil

--- The registered kind's own storage: [boxId] = { [slot] = { item, amount, metadata } }. The handle
--- whip is given carries only the id — see 36_storekind for why a live table cannot cross.
local _box = {}

local function boxKind(instanceId)
    return {
        resolve = function(key)
            if type(key) ~= 'table' then return nil end
            local id = tostring(key.id or '')
            if not _box[id] then return nil end
            return { id = id }
        end,
        instanceId = instanceId or function(_, h) return KIND .. ':' .. h.id end,
        label      = function(_, h) return 'T43 Box ' .. h.id end,
        slots      = function() return 4 end,
        maxWeight  = function() return 50.0 end,
        get   = function(h, slot) return _box[h.id] and _box[h.id][slot] or nil end,
        set   = function(h, slot, item, amount, metadata)
            if not _box[h.id] then return false end
            _box[h.id][slot] = { item = item, amount = amount, metadata = metadata }
            return true
        end,
        clear = function(h, slot) if _box[h.id] then _box[h.id][slot] = nil end end,
    }
end

local function groundRowsOf(item)
    return DbQuery('SELECT `id` FROM `ground_items` WHERE `item` = ?', { item })
end

local function clearGroundOf(item)
    for _, row in ipairs(groundRowsOf(item)) do
        pcall(exports.whip_core.DeleteGroundItem, exports.whip_core, row.id)
    end
end

local function clearLogsOf(item)
    DbQuery('DELETE FROM `activity_log` WHERE `itemKey` = ?', { item })
end

local function stash(ctx, slot)
    return { kind = 'container', id = ctx.containerId, slot = slot }
end

--- A free-ish slot near the end of the pockets, cleared, for tests that need one of their own.
local function lastSlot(offset)
    return exports.whip_core:GetPocketSlots('player') - (offset or 0)
end

RegisterTestModule({
    order    = 43,
    category = 'Inventory API',

    setup = function(source, ctx)
        local p = exports.whip_core:GetPlayer(source)
        if not p then skip('no player loaded') end
        ctx.charId = p.charId

        exports.whip_core:RegisterItem(ITEM,   { name = 'INV43', weight = 0.1, type = 'misc', stack = true, maxStack = 10 })
        exports.whip_core:RegisterItem(HEAVY,  { name = 'INV43 Heavy', weight = 5000, type = 'misc', stack = false })
        exports.whip_core:RegisterItem(SINGLE, { name = 'INV43 Single', weight = 0.1, type = 'misc', stack = false })
        exports.whip_core:RegisterItem(CTX, {
            name = 'INV43 Ctx', weight = 0.1, type = 'misc', stack = false,
            contextOptions = { { action = CTX, label = 'Test' } },
        })

        for item in pairs(OURS) do
            if item ~= 'cash' then RemoveAllOf(source, item); clearGroundOf(item) end
        end

        -- (source, player, slotData, addr) since 09-24 — the item's address, not a container and a slot.
        exports.whip_core:RegisterContextAction(CTX, function(src, player, slotData, addr)
            _ctxPlayer, _ctxAddr = player, addr
        end)

        local ok, err = exports.whip_core:RegisterStoreKind(KIND, boxKind())
        assertOk(ok, err, 'RegisterStoreKind ' .. KIND)

        local c = CreateContainerNearPlayer(source, {
            name = '_test_inv43_stash', type = 'stash', slots = 10, maxWeight = 100.0,
        })
        ctx.containerId = c.containerId
    end,

    teardown = function(ctx, source)
        if source then
            pcall(exports.whip_core.ClosePanel, exports.whip_core, source, PANEL)
            pcall(exports.whip_core.CloseStore, exports.whip_core, source, { kind = KIND, id = 'b1' })
            if ctx.containerId then
                pcall(exports.whip_core.CloseStore, exports.whip_core, source, { kind = 'container', id = ctx.containerId })
            end
            pcall(ClientCloseAllUI, source)
            for item in pairs(OURS) do
                if item ~= 'cash' then RemoveAllOf(source, item) end
            end
        end
        if ctx.containerId then
            pcall(exports.whip_core.DeleteContainer, exports.whip_core, ctx.containerId)
        end
        for item in pairs(OURS) do
            if item ~= 'cash' then clearGroundOf(item); clearLogsOf(item) end
        end
        _box = {}
    end,

    tests = {
        -- ==========================================
        -- INV-1 / INV-2 — what a give or a take will accept
        -- ==========================================
        {
            name = 'AddItem refuses a mistyped item, and drops nothing on the ground',
            fn = function(source)
                local where, err = exports.whip_core:AddItem(source, '_test_no_such_item', 1)
                assertFalse(where, 'refused')
                assertTrue(tostring(err):find('Unknown item', 1, true) ~= nil,
                    ('saying so (got "%s")'):format(tostring(err)))
                assertDbScalar('SELECT COUNT(*) FROM `ground_items` WHERE `item` = ?', { '_test_no_such_item' }, 0,
                    'no ghost row on the ground')

                local gOk = exports.whip_core:CreateGroundItem({ item = '_test_no_such_item', coords = GetEntityCoords(GetPlayerPed(source)) })
                assertFalse(gOk, 'CreateGroundItem refuses it too')
            end,
        },
        {
            name = 'Item amounts must be whole numbers of 1 or more, everywhere',
            fn = function(source)
                local before = exports.whip_core:GetItemCount(source, ITEM)
                local AMOUNT_ERR = 'Amount must be a whole number of 1 or more'

                for label, bad in pairs({ ['half'] = 0.5, ['negative'] = -3, ['zero'] = 0, ['a word'] = 'lots' }) do
                    local okCall, where, err = pcall(exports.whip_core.AddItem, exports.whip_core, source, ITEM, bad)
                    assertTrue(okCall, 'AddItem ' .. label .. ' answered rather than threw')
                    assertFalse(where, 'AddItem ' .. label .. ' refused')
                    assertEqual(err, AMOUNT_ERR, 'AddItem ' .. label .. ' says why')

                    local okR, removed = pcall(exports.whip_core.RemoveItem, exports.whip_core, source, ITEM, bad)
                    assertTrue(okR, 'RemoveItem ' .. label .. ' answered rather than threw')
                    assertFalse(removed, 'RemoveItem ' .. label .. ' refused')

                    local okH, has = pcall(exports.whip_core.HasItem, exports.whip_core, source, ITEM, bad)
                    assertTrue(okH, 'HasItem ' .. label .. ' answered rather than threw')
                    assertFalse(has, 'HasItem ' .. label .. ' is not a yes')

                    local fit, why = exports.whip_core:CanFitItem(source, ITEM, bad)
                    assertFalse(fit, 'CanFitItem ' .. label .. ' is not a yes')
                    assertEqual(why, AMOUNT_ERR, 'CanFitItem ' .. label .. ' says why')
                end

                assertEqual(exports.whip_core:GetItemCount(source, ITEM), before, 'nothing changed')
            end,
        },

        -- ==========================================
        -- One answer rule — AddItem and CanFitItem (09-24)
        -- ==========================================
        {
            name = 'AddItem answers where it went, takes a reason or options, and noDrop refuses',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:FlushActivityLog(), 'earlier rows out before clearing')
                clearLogsOf(ITEM)

                local where, err = exports.whip_core:AddItem(source, ITEM, 1, nil, { reason = 't43 reason' })
                assertEqual(where, 'inventory', ('into the pockets, and it says so (got %s, %s)'):format(tostring(where), tostring(err)))
                assertTrue(exports.whip_core:FlushActivityLog(), 'flushed')
                assertDbScalar('SELECT COUNT(*) FROM `activity_log` WHERE `itemKey` = ? AND `detail` = ?',
                    { ITEM, 't43 reason · by whip_test' }, 1, 'the reason reached the log, beside who asked')

                local strip, stripErr = exports.whip_core:AddItem(source, ITEM, 1, nil, { pocket = 'bogus' })
                assertFalse(strip, 'a pocket that does not exist is refused')
                assertNotNil(stripErr, 'with a reason')

                -- Heavier than any pocket: it cannot fit.
                local none, noneErr = exports.whip_core:AddItem(source, HEAVY, 1, nil, { noDrop = true })
                assertFalse(none, 'noDrop: refused')
                assertNotNil(noneErr, 'noDrop: with the reason it did not fit')
                assertEqual(#groundRowsOf(HEAVY), 0, 'noDrop: nothing on the ground')

                local dropped = exports.whip_core:AddItem(source, HEAVY, 1)
                if dropped ~= 'ground' then
                    skip('this server has Config.DropOnFullInventory = false, so nothing drops anyway')
                end
                assertEqual(dropped, 'ground', 'without noDrop it is given — to the ground, and it says so')
                clearGroundOf(HEAVY)
            end,
        },
        {
            name = 'CanFitItem answers true, or false with a sentence',
            fn = function(source)
                assertTrue(exports.whip_core:CanFitItem(source, ITEM, 1), 'one light item fits')

                local fit, why = exports.whip_core:CanFitItem(source, HEAVY, 1)
                assertFalse(fit, 'the heavy one does not')
                assertEqual(why, 'No room', 'and it says so — a sentence, never a capacity number')

                local unk, unkWhy = exports.whip_core:CanFitItem(source, '_test_no_such_item', 1)
                assertFalse(unk, 'an unknown item does not "fit"')
                assertTrue(tostring(unkWhy):find('Unknown item', 1, true) ~= nil,
                    ('and the reason says why (got "%s")'):format(tostring(unkWhy)))
            end,
        },

        -- ==========================================
        -- One handle for a slot — the address (09-24)
        -- ==========================================
        {
            -- MERGE BY DEFAULT since 25 Sep 2026 (audit 3, INV-12): it replaced unless asked to merge,
            -- so the first call a newcomer writes wiped the item's serial.
            name = 'SetItemMetadata by address: merges, replaces or removes on request, keeps the uid, refuses what cannot be saved',
            fn = function(source, ctx)
                RemoveAllOf(source, SINGLE)
                local slot = lastSlot()
                local addr = PocketAddr(source, 'player', slot)
                exports.whip_core:StoreTake(addr)
                assertOk(exports.whip_core:StoreGive(addr, SINGLE, 1, { a = 1, b = 2 }), nil, 'seeded')

                -- Give it an identity, the way a first logged touch does — LogActivity names the slot
                -- by address too.
                assertTrue(exports.whip_core:LogActivity(source, 'test_event', { detail = 'mint', slotData = addr }), 'uid minted')
                local uid = exports.whip_core:GetItemAt(addr).metadata.uid
                assertNotNil(uid, 'the item has a uid')

                local oldForm, oldErr = exports.whip_core:LogActivity(source, 'test_event', { detail = 'x', slotData = { container = 'player', slot = slot } })
                assertFalse(oldForm, 'the old { container, slot } spelling is refused, not logged against nothing')
                assertNotNil(oldErr, 'with a reason')

                assertTrue(exports.whip_core:SetItemMetadata(addr, { b = 3 }), 'merged, with no options')
                local m = exports.whip_core:GetItemAt(addr).metadata
                assertEqual(m.a, 1, 'merge left the other keys alone')
                assertEqual(m.b, 3, 'and changed the one passed')
                assertEqual(m.uid, uid, 'and kept the uid')

                assertTrue(exports.whip_core:SetItemMetadata(addr, nil, { remove = { 'b' } }), 'removed')
                m = exports.whip_core:GetItemAt(addr).metadata
                assertNil(m.b, 'remove took the key away')
                assertEqual(m.a, 1, 'and left the rest')

                local bare, bareErr = exports.whip_core:SetItemMetadata(addr, nil)
                assertFalse(bare, 'a bare nil is refused rather than wiping the item')
                assertNotNil(bareErr, 'with a reason')
                assertEqual(exports.whip_core:GetItemAt(addr).metadata.a, 1, 'and nothing changed')

                assertTrue(exports.whip_core:SetItemMetadata(addr, { c = 4 }, { replace = true }), 'replaced')
                m = exports.whip_core:GetItemAt(addr).metadata
                assertNil(m.a, 'a replace drops the old keys')
                assertEqual(m.c, 4, 'and sets the new one')
                assertEqual(m.uid, uid, 'but the uid survives a replace too')

                local nanOk, nanErr = exports.whip_core:SetItemMetadata(addr, { n = 0 / 0 })
                assertFalse(nanOk, 'a NaN cannot be saved, so it is refused')
                assertTrue(tostring(nanErr):find('cannot be saved', 1, true) ~= nil,
                    ('saying so (got "%s")'):format(tostring(nanErr)))
                assertEqual(exports.whip_core:GetItemAt(addr).metadata.c, 4, 'and nothing changed')
            end,
        },
        {
            name = 'GetItemAt and SetItemMetadata work on a stash, not only the pockets',
            fn = function(source, ctx)
                local addr = stash(ctx, 10)
                exports.whip_core:StoreTake(addr)
                assertOk(exports.whip_core:StoreGive(addr, SINGLE, 1, { tier = 1 }), nil, 'a single in stash slot 10')

                assertTrue(exports.whip_core:SetItemMetadata(addr, { tier = 2 }), 'changed in the stash')
                local it = exports.whip_core:GetItemAt(addr)
                assertEqual(it and it.item, SINGLE, 'GetItemAt reads a stash slot')
                assertEqual(it and it.metadata and it.metadata.tier, 2, 'and sees the change')

                assertOk(exports.whip_core:StoreTake(addr), nil, 'taken back out')
            end,
        },
        {
            name = 'GetItemAt: nil for an empty slot, false and a reason for a wrong address',
            fn = function(source)
                local empty = PocketAddr(source, 'player', lastSlot(2))
                exports.whip_core:StoreTake(empty)
                assertNil(exports.whip_core:GetItemAt(empty), 'an empty slot is nil — an answer, not a refusal')

                local no, why = exports.whip_core:GetItemAt(PocketAddr(source, 'player', 9999))
                assertFalse(no, 'a slot the pockets have not got is refused')
                assertNotNil(why, 'with a reason')

                local acc, accWhy = exports.whip_core:GetItemAt({ kind = 'accessory', id = source, slot = 1 })
                assertFalse(acc, "the strip is { kind = 'player', sub = 'accessory' } — there is no second spelling")
                assertNotNil(accWhy, 'with a reason')
            end,
        },
        {
            name = 'FindItem answers the item and its address, and the address reads it back',
            fn = function(source)
                RemoveAllOf(source, SINGLE)
                local slot = lastSlot()
                SeedSlot(source, 'player', slot, SINGLE, 1)

                local found = exports.whip_core:FindItem(source, SINGLE)
                assertNotNil(found, 'found')
                assertEqual(found and found.item, SINGLE, 'the item')
                assertEqual(found and found.addr and found.addr.kind, 'player', 'its address is a pocket')
                assertEqual(found and found.addr and found.addr.sub, 'player', 'the main pocket')
                assertEqual(found and found.addr and found.addr.slot, slot, 'and the slot')
                assertEqual(exports.whip_core:GetItemAt(found.addr).item, SINGLE, 'GetItemAt(found.addr) is the same item')

                assertEqual(#exports.whip_core:FindAllItems(source, SINGLE), 1, 'FindAllItems answers the same shape')
                assertNil(exports.whip_core:FindItem(source, SINGLE, 'bogus'), 'a pocket that does not exist finds nothing')
            end,
        },

        -- ==========================================
        -- INV-3 — the store verbs
        -- ==========================================
        {
            name = 'StoreGive: into a stash wherever it fits, across slots, all or nothing',
            fn = function(source, ctx)
                local slot, err = exports.whip_core:StoreGive({ kind = 'container', id = ctx.containerId }, ITEM, 25)
                assertOk(slot, err, 'StoreGive 25 with no slot')
                assertEqual(exports.whip_core:StoreCount({ kind = 'container', id = ctx.containerId }, ITEM), 25,
                    'all 25 are there')

                local read = exports.whip_core:StoreRead({ kind = 'container', id = ctx.containerId })
                assertNotNil(read, 'StoreRead answered')
                local stacks = 0
                for _, it in pairs(read.items) do
                    if it.item == ITEM then
                        stacks = stacks + 1
                        assertTrue(it.amount <= 10, 'no stack is bigger than the item allows')
                    end
                end
                assertEqual(stacks, 3, 'spread over three stacks of at most 10')
                assertEqual(read.slots, 10, 'with the stash size')
                assertNotNil(read.items[slot], 'keyed by slot NUMBER')

                local over, overErr = exports.whip_core:StoreGive(stash(ctx, 9), ITEM, 11)
                assertFalse(over, 'more than one slot holds is refused for a named slot')
                assertNotNil(overErr, 'with a reason')

                local tooMany = exports.whip_core:StoreGive({ kind = 'container', id = ctx.containerId }, ITEM, 500)
                assertFalse(tooMany, 'more than the stash has room for is refused')
                assertEqual(exports.whip_core:StoreCount({ kind = 'container', id = ctx.containerId }, ITEM), 25,
                    'and none of it was placed — all or nothing')

                local unk = exports.whip_core:StoreGive({ kind = 'container', id = ctx.containerId }, '_test_no_such_item', 1)
                assertFalse(unk, 'an unknown item is refused')
            end,
        },
        {
            name = 'StoreTake: from a slot, or an item from wherever it is in the store',
            fn = function(source, ctx)
                local read = exports.whip_core:StoreRead({ kind = 'container', id = ctx.containerId })
                local first
                for slot, it in pairs(read.items) do
                    if it.item == ITEM and (not first or slot < first) then first = slot end
                end
                assertNotNil(first, 'a stack to take from (the test above filled the stash)')

                local taken, err = exports.whip_core:StoreTake(stash(ctx, first), 3)
                assertOk(taken, err, 'StoreTake 3 from a slot')
                assertEqual(taken.item, ITEM, 'answers with what it took')
                assertEqual(taken.amount, 3, 'and how many')

                local byItem, byErr = exports.whip_core:StoreTake({ kind = 'container', id = ctx.containerId }, 20, { item = ITEM })
                assertOk(byItem, byErr, 'StoreTake 20 by item')
                assertEqual(exports.whip_core:StoreCount({ kind = 'container', id = ctx.containerId }, ITEM), 2,
                    '25 - 3 - 20 = 2 left')

                local short = exports.whip_core:StoreTake({ kind = 'container', id = ctx.containerId }, 5, { item = ITEM })
                assertFalse(short, 'asking for more than is there is refused')
                assertEqual(exports.whip_core:StoreCount({ kind = 'container', id = ctx.containerId }, ITEM), 2,
                    'and takes nothing')
            end,
        },
        {
            name = 'A stash nobody has open is loaded on demand',
            fn = function(source, ctx)
                FlushPersistence()
                if not exports.whip_core:__TestUnloadContainer(ctx.containerId) then
                    skip('the stash could not be unloaded (seams off, or still in use)')
                end
                assertFalse(exports.whip_core:__TestContainerCached(ctx.containerId), 'precondition: not in memory')
                assertEqual(exports.whip_core:StoreCount({ kind = 'container', id = ctx.containerId }, ITEM), 2,
                    'read straight from the database, without anyone opening it')
            end,
        },
        {
            name = 'StoreMove leaves the destination slot to whip, logs the move, and announces the pockets',
            fn = function(source, ctx)
                local read = exports.whip_core:StoreRead({ kind = 'container', id = ctx.containerId })
                local from
                for slot, it in pairs(read.items) do if it.item == ITEM then from = slot end end
                assertNotNil(from, 'something to move (2 left from the tests above)')

                assertTrue(exports.whip_core:FlushActivityLog(), 'earlier rows out before clearing')
                clearLogsOf(ITEM)
                local mark = #_events
                local before = exports.whip_core:GetItemCount(source, ITEM)

                local ok, err = exports.whip_core:StoreMove(stash(ctx, from), { kind = 'player', id = source },
                    { reason = 't43 move' })
                assertOk(ok, err, 'StoreMove with no destination slot')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), before + 2, 'it landed in the pockets')

                local added = waitFor(function()
                    for _, e in ipairs(eventsFor(mark, ITEM)) do
                        if e.kind == 'added' and e.src == source then return e end
                    end
                end, 2000)
                assertNotNil(added, 'itemAdded fired for the player')
                assertEqual(added and added.amount, 2, 'for the two that arrived')

                assertTrue(exports.whip_core:FlushActivityLog(), 'flushed')
                local rows = DbQuery('SELECT `detail` FROM `activity_log` WHERE `itemKey` = ? AND `event` = ?', { ITEM, 'moved' })
                assertTrue(#rows >= 1, 'a "moved" row was written')
                assertTrue(tostring(rows[1] and rows[1].detail):find('t43 move', 1, true) ~= nil,
                    ('with the reason (got "%s")'):format(tostring(rows[1] and rows[1].detail)))
            end,
        },

        -- ==========================================
        -- INV-8 — item events for every change
        -- ==========================================
        {
            name = 'item:added / item:removed fire for exports and cash, with the count and who asked',
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                local mark = #_events

                assertOk(exports.whip_core:AddItem(source, ITEM, 2, nil, 'ev test'), nil, 'given')
                local add = waitFor(function()
                    for _, e in ipairs(eventsFor(mark, ITEM)) do if e.kind == 'added' then return e end end
                end, 2000)
                assertNotNil(add, 'itemAdded fired')
                assertEqual(add and add.amount, 2, 'with the amount')
                assertEqual(add and add.info and add.info.count, 2, 'and what they carry now')
                assertTrue(tostring(add and add.info and add.info.reason):find('ev test', 1, true) ~= nil,
                    'and the reason')

                mark = #_events
                assertTrue(exports.whip_core:RemoveItem(source, ITEM, 2), 'taken')
                local rem = waitFor(function()
                    for _, e in ipairs(eventsFor(mark, ITEM)) do if e.kind == 'removed' then return e end end
                end, 2000)
                assertNotNil(rem, 'itemRemoved fired')
                assertEqual(rem and rem.info and rem.info.count, 0, 'they carry none now')

                -- Cash is an item: it used to fire nothing. (PayPlayer drops a note that does not fit at
                -- the tester's feet, so room is asked first.)
                mark = #_events
                if not exports.whip_core:CanFitItem(source, 'cash', 1) then
                    skip('no room in the pockets for a banknote')
                end
                local paid, payWhy = exports.whip_core:PayPlayer(source, 1, { method = 'cash', reason = 'ev cash' })
                assertOk(paid, payWhy, 'a banknote paid')
                local cash = waitFor(function()
                    for _, e in ipairs(eventsFor(mark, 'cash')) do if e.kind == 'added' then return e end end
                end, 2000)
                assertNotNil(cash, 'itemAdded fired for cash')
                exports.whip_core:ChargePlayer(source, 1, { method = 'cash', reason = 'ev cash back' })

                -- Into a STASH, nothing reached the player's pockets: no event for them.
                mark = #_events
                assertOk(exports.whip_core:StoreGive({ kind = 'container', id = ctx.containerId }, ITEM, 1), nil,
                    'StoreGive into the stash')
                Wait(200)
                assertEqual(#eventsFor(mark, ITEM), 0, 'and no item event for the player')
            end,
        },

        -- ==========================================
        -- Panels by address; a panel's rules; its hooks (09-24)
        -- ==========================================
        {
            name = 'A panel and the accessory strip can be addressed like any store',
            fn = function(source)
                assertTrue(exports.whip_core:OpenPanel(source, { id = PANEL, label = 'INV43', slots = 4 }), 'panel open')
                local slot, err = exports.whip_core:StoreGive({ kind = 'panel', id = PANEL }, ITEM, 2)
                assertOk(slot, err, 'StoreGive into the panel')
                local read = exports.whip_core:StoreRead({ kind = 'panel', id = PANEL })
                assertEqual(read and read.items[slot] and read.items[slot].amount, 2, 'StoreRead sees the panel hold it')

                local labelled = false
                for _, s in ipairs(exports.whip_core:GetOpenStores(source)) do
                    if s.kind == 'panel' and s.id == PANEL and s.label == 'INV43' then labelled = true end
                end
                assertTrue(labelled, 'GetOpenStores lists the panel, with its label')
                assertTrue(exports.whip_core:ClosePanel(source, PANEL), 'closed')

                local gone, goneWhy = exports.whip_core:StoreRead({ kind = 'panel', id = PANEL })
                assertFalse(gone, 'a panel nobody has open cannot be read')
                assertNotNil(goneWhy, 'with a reason')
                local again, againWhy = exports.whip_core:ClosePanel(source, PANEL)
                assertFalse(again, 'closing it again is refused')
                assertEqual(againWhy, 'No such panel open', 'and says why')

                local strip = exports.whip_core:StoreRead({ kind = 'player', id = source, sub = 'accessory' })
                assertNotNil(strip, 'the accessory strip answers')
                assertEqual(strip.slots, exports.whip_core:GetPocketSlots('accessory'), 'with its size')
            end,
        },
        {
            name = 'A panel\'s rules hold for server writes too, and a refusal changes nothing',
            fn = function(source)
                assertTrue(exports.whip_core:OpenPanel(source, {
                    id = PANEL, label = 'INV43 rules', slots = 3, allowedItems = { 'food' },
                }), 'panel open')
                local one = { kind = 'panel', id = PANEL, slot = 1 }

                assertOk(exports.whip_core:StoreGive(one, 'food', 1), nil, 'an allowed item goes in')

                local ok, err = exports.whip_core:StoreGive({ kind = 'panel', id = PANEL, slot = 2 }, ITEM, 1)
                assertFalse(ok, 'an item the panel does not allow is refused')
                assertNotNil(err, 'with a reason')

                assertFalse(exports.whip_core:StoreGive(one, '_test_no_such_item', 1), 'an unknown item is refused')
                assertFalse(exports.whip_core:StoreGive(one, 'food', 0.5), 'half an item is refused')
                assertFalse(exports.whip_core:StoreGive({ kind = 'panel', id = PANEL, slot = 9 }, 'food', 1),
                    'a slot the panel has not got is refused')
                assertEqual(exports.whip_core:GetItemAt(one).amount, 1, 'slot 1 still holds its one food')

                assertOk(exports.whip_core:StoreTake(one), nil, 'clearing is StoreTake')
                assertNil(exports.whip_core:GetItemAt(one), 'and the slot is empty')
                exports.whip_core:ClosePanel(source, PANEL)
            end,
        },
        {
            name = 'OpenPanel\'s hooks: onValidate can refuse a move, onChange hears it land, onClose gets what is left',
            fn = function(source)
                local changed, closed = nil, nil
                assertTrue(exports.whip_core:OpenPanel(source, {
                    id = PANEL, label = 'INV43 hooks', slots = 3,
                    onValidate = function(c)
                        if c.direction == 'in' and c.item == ITEM then return false, 'no INV43 here' end
                    end,
                    onChange = function(c) changed = c end,
                    onClose  = function(c) closed = c end,
                }), 'panel open, with its hooks')

                local slot = lastSlot()
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', slot, ITEM, 1)
                local refused, why = exports.whip_core:StoreMove(PocketAddr(source, 'player', slot),
                    { kind = 'panel', id = PANEL, slot = 1 })
                assertFalse(refused, 'onValidate refused the move')
                assertEqual(why, 'no INV43 here', 'with its own reason')
                assertEqual(exports.whip_core:GetItemAt(PocketAddr(source, 'player', slot)).item, ITEM, 'the item stayed')

                RemoveAllOf(source, SINGLE)
                SeedSlot(source, 'player', slot, SINGLE, 1)
                local moved, moveErr = exports.whip_core:StoreMove(PocketAddr(source, 'player', slot),
                    { kind = 'panel', id = PANEL, slot = 2 })
                assertOk(moved, moveErr, 'an item it allows moves in')

                local c = waitFor(function() return changed end, 2000)
                assertNotNil(c, 'onChange ran')
                assertEqual(c and c.direction, 'in', 'direction is the panel\'s point of view')
                assertEqual(c and c.panel, PANEL, 'it names the panel')
                assertEqual(c and c.source, source, 'and whose move it was')
                assertEqual(c and c.item, SINGLE, 'and what moved')
                assertEqual(c and c.items and c.items[2] and c.items[2].item, SINGLE, 'and what the panel holds now')
                assertEqual(c and c.other and c.other.kind, 'player', 'the other end is an address')

                assertTrue(exports.whip_core:ClosePanel(source, PANEL), 'closed')
                local cl = waitFor(function() return closed end, 2000)
                assertNotNil(cl, 'onClose ran when the last viewer left')
                assertEqual(cl and cl.panel, PANEL, 'naming the panel')
                assertEqual(cl and cl.items and cl.items[2] and cl.items[2].item, SINGLE, 'with what was left in it')
            end,
        },
        {
            -- The list spelling of allowedItems on a RegisterPanelItem used to refuse EVERYTHING: only
            -- the keys were kept, so { 'x' } became { [1] = true } (09-24).
            name = 'An item panel takes allowedItems as a list of names',
            fn = function(source)
                exports.whip_core:RegisterItem(BAG, {
                    name = 'INV43 Bag', weight = 0.5, type = 'misc', stack = false, defaultAction = BAG_ACTION,
                })
                assertOk(exports.whip_core:RegisterPanelItem(BAG, { slots = 2, allowedItems = { ITEM } }), nil,
                    'registered with a list of names')

                RemoveAllOf(source, BAG)
                local slot = lastSlot(3)
                SeedSlot(source, 'player', slot, BAG, 1)
                ClientCloseAllUI(source)
                assertTrue(ClientExecWait(source, 'whip_core:server:customContextAction', 3000, BAG_ACTION, 'player', slot),
                    'opened through its action')

                local pid
                for _, s in ipairs(exports.whip_core:GetOpenStores(source)) do
                    if s.kind == 'panel' and tostring(s.id):find(BAG_ACTION, 1, true) then pid = s.id end
                end
                assertNotNil(pid, 'the bag\'s panel is open')

                assertOk(exports.whip_core:StoreGive({ kind = 'panel', id = pid, slot = 1 }, ITEM, 1), nil,
                    'the listed item goes in')
                assertFalse(exports.whip_core:StoreGive({ kind = 'panel', id = pid, slot = 2 }, SINGLE, 1),
                    'anything else does not')

                exports.whip_core:ClosePanel(source, pid)
                ClientCloseAllUI(source)
                RemoveAllOf(source, BAG)
            end,
        },

        -- ==========================================
        -- FindItemByUid, GetOpenStores, OpenStore / CloseStore (INV-3, INV-15, INV-16)
        -- ==========================================
        {
            name = 'FindItemByUid finds one specific item',
            fn = function(source, ctx)
                -- ITS OWN ITEM. This borrowed the one the SetItemMetadata test minted, and the FindItem
                -- and hook tests in between take every SINGLE away — so on its first run (09-24) it
                -- looked for an item that was already gone. It mints one here, where nothing can move it.
                RemoveAllOf(source, SINGLE)
                local slot = lastSlot()
                local addr = PocketAddr(source, 'player', slot)
                SeedSlot(source, 'player', slot, SINGLE, 1)
                assertTrue(exports.whip_core:LogActivity(source, 'test_event', { detail = 'mint for FindItemByUid', slotData = addr }),
                    'a uid minted')
                local item = exports.whip_core:GetItemAt(addr)
                local uid = item and item.metadata and item.metadata.uid
                assertNotNil(uid, 'the item has a uid')

                local found = exports.whip_core:FindItemByUid(uid)
                assertNotNil(found, 'found')
                assertEqual(found and found.kind, 'player', 'in a player\'s pockets')
                assertEqual(found and found.id, source, 'this player\'s')
                assertEqual(found and found.sub, 'player', 'the main pocket')
                assertEqual(found and found.slot, slot, 'in the slot it was put in')
                assertNil(exports.whip_core:FindItemByUid('_no_such_uid'), 'an unknown uid finds nothing')
            end,
        },
        {
            name = 'OpenStore / CloseStore a stash, and GetOpenStores lists it while it is open',
            fn = function(source, ctx)
                ClientCloseAllUI(source)
                local ok, err = exports.whip_core:OpenStore(source, { kind = 'container', id = ctx.containerId },
                    { skipDistance = true, skipAccess = true })
                assertOk(ok, err, 'OpenStore a stash')

                local found = false
                for _, a in ipairs(exports.whip_core:GetOpenStores(source)) do
                    if a.kind == 'container' and a.id == ctx.containerId then found = true end
                end
                assertTrue(found, 'the stash is listed')

                assertTrue(exports.whip_core:CloseStore(source, { kind = 'container', id = ctx.containerId }), 'CloseStore')
                assertFalse(exports.whip_core:__TestIsViewer(source, 'container:' .. tostring(ctx.containerId)),
                    'they can no longer move anything in it')
                local again, why = exports.whip_core:CloseStore(source, { kind = 'container', id = ctx.containerId })
                assertFalse(again, 'closing it again is refused')
                assertEqual(why, 'That is not open', 'and says why')
                ClientCloseAllUI(source)
            end,
        },
        {
            name = 'OpenStore shows a resource\'s own store kind, and the open is what lets the player drag into it',
            fn = function(source)
                _box['b1'] = {}
                local SLOT = lastSlot(1)
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', SLOT, ITEM, 2)

                -- Server-only kind (no authorize): a drag is refused until the store is opened for them.
                assertTrue(ClientExecWait(source, 'whip_core:server:storeMove', 3000,
                    { kind = 'player', slot = SLOT }, { kind = KIND, id = 'b1', slot = 1 }, 0, 'move', 0), 'answered')
                assertLastReject('whip_core:server:storeMove', ('to: store kind "%s" is server-only'):format(KIND),
                    'before the open: refused')

                ClientCloseAllUI(source)
                local ok, err = exports.whip_core:OpenStore(source, { kind = KIND, id = 'b1' })
                assertOk(ok, err, 'OpenStore the box')
                -- A client that could not show it would hand it straight back; give it that moment.
                Wait(500)
                assertTrue(exports.whip_core:__TestIsViewer(source, KIND .. ':b1'), 'the player is a viewer of it')
                local listed = false
                for _, a in ipairs(exports.whip_core:GetOpenStores(source)) do
                    if a.kind == KIND and a.id == 'b1' then listed = true end
                end
                assertTrue(listed, 'GetOpenStores lists it, by the address it was opened with')

                assertTrue(ClientExecWait(source, 'whip_core:server:storeMove', 3000,
                    { kind = 'player', slot = SLOT }, { kind = KIND, id = 'b1', slot = 1 }, 0, 'move', 0), 'answered')
                assertLastReject('whip_core:server:storeMove', nil, 'while open: the drag counts')
                assertEqual(_box['b1'][1] and _box['b1'][1].amount, 2, 'and the box\'s own table has the stack')

                assertTrue(exports.whip_core:CloseStore(source, { kind = KIND, id = 'b1' }), 'CloseStore')
                assertTrue(ClientExecWait(source, 'whip_core:server:storeMove', 3000,
                    { kind = KIND, id = 'b1', slot = 1 }, { kind = 'player', slot = SLOT }, 0, 'move', 0), 'answered')
                assertLastReject('whip_core:server:storeMove', ('from: store kind "%s" is server-only'):format(KIND),
                    'after the close: refused again')
                assertEqual(_box['b1'][1] and _box['b1'][1].amount, 2, 'and the stack stayed in the box')
                ClientCloseAllUI(source)
            end,
        },
        {
            name = 'OpenStore readOnly lets them look but not move, and a borrowed storeId is refused',
            fn = function(source)
                _box['b2'] = { [1] = { item = ITEM, amount = 1 } }
                ClientCloseAllUI(source)
                assertOk(exports.whip_core:OpenStore(source, { kind = KIND, id = 'b2' }, { readOnly = true }), nil,
                    'OpenStore read-only')
                Wait(500)
                local SLOT = lastSlot(1)
                exports.whip_core:StoreTake(PocketAddr(source, 'player', SLOT))
                assertTrue(ClientExecWait(source, 'whip_core:server:storeMove', 3000,
                    { kind = KIND, id = 'b2', slot = 1 }, { kind = 'player', slot = SLOT }, 0, 'move', 0), 'answered')
                assertLastReject('whip_core:server:storeMove', 'from: You can only look at that', 'refused: read-only')
                exports.whip_core:CloseStore(source, { kind = KIND, id = 'b2' })
                ClientCloseAllUI(source)

                -- A kind whose instanceId answers another kind's name would share that store's viewers.
                assertOk(exports.whip_core:RegisterStoreKind(BADKIND, boxKind(function(_, h) return 'container:' .. h.id end)),
                    nil, 'a kind with a borrowed storeId registers')
                local bad, badWhy = exports.whip_core:OpenStore(source, { kind = BADKIND, id = 'b2' })
                assertFalse(bad, 'but OpenStore refuses it')
                assertTrue(tostring(badWhy):find('instanceId', 1, true) ~= nil,
                    ('saying why (got "%s")'):format(tostring(badWhy)))
            end,
        },
        {
            name = 'OpenStore points the other kinds at the call that opens them',
            fn = function(source)
                local p, pWhy = exports.whip_core:OpenStore(source, { kind = 'player', id = source })
                assertFalse(p, 'a player\'s pockets are not opened with OpenStore')
                assertTrue(tostring(pWhy):find('OpenPlayerInventory', 1, true) ~= nil, 'it names OpenPlayerInventory')

                local pn, pnWhy = exports.whip_core:OpenStore(source, { kind = 'panel', id = PANEL })
                assertFalse(pn, 'nor a panel')
                assertTrue(tostring(pnWhy):find('OpenPanel', 1, true) ~= nil, 'it names OpenPanel')

                local g, gWhy = exports.whip_core:OpenStore(source, { kind = 'vehicle', id = 1, sub = 'glovebox' })
                assertFalse(g, 'nor a glovebox, which belongs to the seat')
                assertNotNil(gWhy, 'with a reason')
            end,
        },

        -- ==========================================
        -- INV-4 / INV-5 — context actions
        -- ==========================================
        {
            name = 'Another resource\'s context action is handed the player sheet and the item\'s address',
            fn = function(source)
                RemoveAllOf(source, CTX)
                local slot = lastSlot(1)
                SeedSlot(source, 'player', slot, CTX, 1)
                _ctxPlayer, _ctxAddr = nil, nil

                assertTrue(ClientExecWait(source, 'whip_core:server:customContextAction', 3000, CTX, 'player', slot),
                    'the server answered')
                local p = waitFor(function() return _ctxPlayer end, 2000)
                assertNotNil(p, 'the handler ran')
                assertEqual(p and p.charId, exports.whip_core:GetPlayer(source).charId, 'with the player\'s sheet')
                assertNil(p and p.inventory, 'which does not carry their whole inventory')
                assertNil(p and p.identifiers, 'or their identifiers')

                assertEqual(_ctxAddr and _ctxAddr.kind, 'player', 'the fourth argument is an address')
                assertEqual(_ctxAddr and _ctxAddr.id, source, 'of this player')
                assertEqual(_ctxAddr and _ctxAddr.sub, 'player', 'in the main pocket')
                assertEqual(_ctxAddr and _ctxAddr.slot, slot, 'in the slot used')
                assertEqual(exports.whip_core:GetItemAt(_ctxAddr).item, CTX, 'and GetItemAt(addr) reads that item')
            end,
        },
        {
            name = 'whip_core\'s own panel actions cannot be taken over',
            fn = function()
                local ok, err = exports.whip_core:RegisterContextAction('open_wallet', function() end)
                assertFalse(ok, 'the wallet\'s action is refused')
                assertNotNil(err, 'with a reason')

                local mine = exports.whip_core:RegisterContextAction(CTX, function(src, player, slotData, addr)
                    _ctxPlayer, _ctxAddr = player, addr
                end)
                assertTrue(mine, 'a resource\'s own action registers, and says so')
                assertTrue(exports.whip_core:RegisterUseHandler(SINGLE, function() return false end),
                    'RegisterUseHandler answers too')
            end,
        },

        -- ==========================================
        -- INV-17 / INV-18 / INV-21 / cash
        -- ==========================================
        {
            name = 'Ground items: the table form, GetGroundItem, and a default range',
            fn = function(source)
                local pos = GetEntityCoords(GetPlayerPed(source))
                local row, err = exports.whip_core:CreateGroundItem({ item = ITEM, amount = 2, coords = vector3(pos.x, pos.y + 2.0, pos.z) })
                assertOk(row, err, 'CreateGroundItem, table form')
                assertEqual(exports.whip_core:GetGroundItem(row.id).item, ITEM, 'GetGroundItem finds it by id')

                local okCall, near = pcall(exports.whip_core.GetGroundItemsNearby, exports.whip_core, pos)
                assertTrue(okCall, 'GetGroundItemsNearby with no range answers rather than throws')
                local seen = false
                for _, g in ipairs(near or {}) do if g.id == row.id then seen = true end end
                assertTrue(seen, 'and finds it within the default range')

                assertTrue(exports.whip_core:DeleteGroundItem(row.id), 'removed')
                assertNil(exports.whip_core:GetGroundItem(row.id), 'and gone')
            end,
        },
        {
            name = 'Shop exports answer with reasons, and GetShop finds by what you have',
            fn = function()
                local okCall, shop, err = pcall(exports.whip_core.CreateShop, exports.whip_core, nil)
                assertTrue(okCall, 'CreateShop(nil) answers rather than throws')
                assertFalse(shop, 'and refuses')
                assertNotNil(err, 'with a reason')

                local noPos, posErr = exports.whip_core:CreateShop({ name = 'INV43 nowhere' })
                assertFalse(noPos, 'a shop with no position is refused')
                assertNotNil(posErr, 'with a reason')

                local upd, updErr = exports.whip_core:UpdateShop(987654, { name = 'x' })
                assertFalse(upd, 'an unknown shop cannot be updated')
                assertEqual(updErr, 'Shop not found', 'and it says why')

                assertNil(exports.whip_core:GetShop({ id = 987654 }), 'GetShop({ id }) finds nothing for an unknown shop')
                assertType(exports.whip_core:GetShops({ job = 987654 }), 'table', 'GetShops({ job }) returns a list')
            end,
        },
        {
            name = 'GetPockets names the pockets, and the pocket calls answer for each',
            fn = function(source, ctx)
                local pockets = exports.whip_core:GetPockets()
                assertType(pockets, 'table', 'GetPockets answers a list')
                assertEqual(pockets[1], 'player', 'the main pocket first')
                for _, p in ipairs(pockets) do
                    assertType(exports.whip_core:GetPocketSlots(p), 'number', 'GetPocketSlots(' .. p .. ')')
                    assertType(exports.whip_core:GetPocketMaxWeight(p), 'number', 'GetPocketMaxWeight(' .. p .. ')')
                end
                assertFalse(exports.whip_core:IsCharacterBeingInspected(ctx.charId), 'nobody is inspecting the tester')
            end,
        },
        {
            name = 'Cash says why it refused',
            fn = function(source)
                -- ChargePlayer in cash (RemovePlayerCash, which said only 'Not enough cash', until 14 Nov 2026).
                local receipt, err = exports.whip_core:ChargePlayer(source, 999999999, { method = 'cash' })
                assertFalse(receipt, 'more cash than they have is refused')
                assertTrue(type(err) == 'string' and err:find('Not enough cash (have $', 1, true) == 1,
                    'and it says why, with what they have (got: ' .. tostring(err) .. ')')
            end,
        },
    },
})
