-- ============================================
-- Menu & Shift-Click (2026-09-24) — Split and Destroy outside the pockets, and shift-click
--
-- WHY THIS MODULE EXISTS
--
-- Josh (24 Sep 2026): right-clicking an item outside the main inventory offered nothing, so a stack
-- in a stash, a boot, a wallet or on the ground could not be split or destroyed; and shift + click
-- should send an item straight across — pockets to whatever is open, and back. Both must be SOUND
-- (a move that cannot happen is refused, with the reason) and OPTIMISTIC (the screen changes at once
-- and is put back on a refusal).
--
-- The optimistic half lives in the NUI and is checked by hand. What is proved here is the half the
-- screen relies on: every event, fired exactly as the NUI fires it, lands or refuses for the right
-- reason — through the same store rules a drag is held to.
--
--   * destroyItem   any store the player can reach, by address; a read-only panel and a panel's
--                   onValidate can refuse; onChange hears it (direction 'out', destroyed = true)
--   * splitItem     through the move hooks now: the first free slot, a panel's onValidate asked
--   * quickMove     the server picks the slot (joins a stack before taking an empty slot), and
--                   refuses a full store, an item the store does not take, and a store not open
--   * ground        splitGroundItem makes two piles with the same total; destroyGroundItem
-- ============================================

local ITEM   = '_test_msc44'          -- stacks to 10, light
local SINGLE = '_test_msc44_single'   -- one per slot
local PANEL  = '_test_msc44_panel'
local STASH_SLOTS = 10

local EV_DESTROY  = 'whip_core:server:destroyItem'
local EV_SPLIT    = 'whip_core:server:splitItem'
local EV_QUICK    = 'whip_core:server:quickMove'
local EV_GSPLIT   = 'whip_core:server:splitGroundItem'
local EV_GDESTROY = 'whip_core:server:destroyGroundItem'

--- The WIRE form of a pocket address, exactly as client/inventory.lua builds it for the NUI.
local function pocket(slot)
    return { kind = 'player', slot = slot }
end

--- A slot of this module's stash, wire form. Leave the slot out for the whole store.
local function stash(ctx, slot)
    return { kind = 'container', id = ctx.containerId, slot = slot }
end

--- A slot of this module's panel, wire form.
local function panel(slot)
    return { kind = 'panel', id = PANEL, slot = slot }
end

--- The same stash slot, in the form server-side exports take (no difference for a container).
local function stashItem(ctx, slot)
    return exports.whip_core:GetItemAt(stash(ctx, slot))
end

local function emptyStash(ctx)
    for slot = 1, STASH_SLOTS do
        if stashItem(ctx, slot) then exports.whip_core:StoreTake(stash(ctx, slot)) end
    end
end

local function lastSlot(offset)
    return exports.whip_core:GetPocketSlots('player') - (offset or 0)
end

--- A refusal SecureEvent made itself carries the parameter's name in front ("to: ..."), so those
--- are matched by what they say rather than exactly.
local function assertRefusedSaying(eventName, fragment, label)
    local reason = exports.whip_core:__TestLastReject(eventName)
    assertNotNil(reason, label .. ' (refused)')
    assertTrue(reason ~= nil and reason:find(fragment, 1, true) ~= nil,
        ('%s (got "%s")'):format(label, tostring(reason)))
end

local function clearGroundOf(item)
    for _, row in ipairs(DbQuery('SELECT `id` FROM `ground_items` WHERE `item` = ?', { item })) do
        pcall(exports.whip_core.DeleteGroundItem, exports.whip_core, row.id)
    end
end

--- A pile on the ground a step from the player — inside the Nearby reach every ground gesture checks.
local function pileNearPlayer(source, item, amount)
    local pos = GetEntityCoords(GetPlayerPed(source))
    local row, err = exports.whip_core:CreateGroundItem({
        item = item, amount = amount, coords = vector3(pos.x + 1.0, pos.y, pos.z),
    })
    assertOk(row, err, 'a pile on the ground')
    return row
end

RegisterTestModule({
    order    = 44,
    category = 'Menu & Shift-Click',

    setup = function(source, ctx)
        if not exports.whip_core:GetPlayer(source) then skip('no player loaded') end

        exports.whip_core:RegisterItem(ITEM,   { name = 'MSC44', weight = 0.1, type = 'misc', stack = true, maxStack = 10 })
        exports.whip_core:RegisterItem(SINGLE, { name = 'MSC44 Single', weight = 0.1, type = 'misc', stack = false })
        RemoveAllOf(source, ITEM); RemoveAllOf(source, SINGLE)
        clearGroundOf(ITEM)

        local c = CreateContainerNearPlayer(source, {
            name = '_test_msc44_stash', type = 'stash', slots = STASH_SLOTS, maxWeight = 100.0,
        })
        ctx.containerId = c.containerId

        -- Open for this player, so its address is theirs to use — the same viewer rights a stash
        -- they walked up to gives them.
        ClientCloseAllUI(source)
        local ok, err = exports.whip_core:OpenStore(source, { kind = 'container', id = ctx.containerId },
            { skipDistance = true, skipAccess = true })
        assertOk(ok, err, 'the stash is open')
    end,

    teardown = function(ctx, source)
        if source then
            pcall(exports.whip_core.ClosePanel, exports.whip_core, source, PANEL)
            if ctx.containerId then
                pcall(exports.whip_core.CloseStore, exports.whip_core, source, { kind = 'container', id = ctx.containerId })
            end
            pcall(ClientCloseAllUI, source)
            RemoveAllOf(source, ITEM); RemoveAllOf(source, SINGLE)
        end
        if ctx.containerId then
            pcall(exports.whip_core.DeleteContainer, exports.whip_core, ctx.containerId)
        end
        clearGroundOf(ITEM)
    end,

    tests = {
        -- ==========================================
        -- Destroy — any store, through the store's rules
        -- ==========================================
        {
            name = 'Destroy works in a stash',
            fn = function(source, ctx)
                emptyStash(ctx)
                assertOk(exports.whip_core:StoreGive(stash(ctx, 2), ITEM, 3), nil, 'seeded the stash')

                ClientExecWait(source, EV_DESTROY, 3000, stash(ctx, 2), 0)

                assertLastReject(EV_DESTROY, nil, 'the destroy was accepted')
                assertNil(stashItem(ctx, 2), 'the slot is empty')
                assertEqual(exports.whip_core:StoreCount(stash(ctx), ITEM), 0, 'and nothing of it is left')
            end,
        },
        {
            name = 'Destroy works in the pockets, by address',
            fn = function(source)
                local slot = lastSlot()
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', slot, ITEM, 4)

                ClientExecWait(source, EV_DESTROY, 3000, pocket(slot), 0)

                assertLastReject(EV_DESTROY, nil, 'the destroy was accepted')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 0, 'the stack is gone')
            end,
        },
        {
            name = 'Destroy refuses a read-only panel, and the item stays',
            fn = function(source)
                assertTrue(exports.whip_core:OpenPanel(source, { id = PANEL, label = 'MSC44 ro', slots = 2, readOnly = true }),
                    'read-only panel open')
                assertOk(exports.whip_core:StoreGive(panel(1), ITEM, 2), nil, 'the resource put something in it')

                ClientExecWait(source, EV_DESTROY, 3000, panel(1), 0)

                assertRefusedSaying(EV_DESTROY, 'read-only', 'refused because it is read-only')
                local still = exports.whip_core:GetItemAt(panel(1))
                assertEqual(still and still.amount, 2, 'the item is still there')
                exports.whip_core:ClosePanel(source, PANEL)
            end,
        },
        {
            name = 'Destroy asks a panel\'s onValidate, which can refuse it',
            fn = function(source)
                local seen = nil
                assertTrue(exports.whip_core:OpenPanel(source, {
                    id = PANEL, label = 'MSC44 keep', slots = 2,
                    onValidate = function(c)
                        seen = c
                        if c.destroyed then return false, 'Nothing is destroyed in here' end
                    end,
                }), 'panel open, with onValidate')
                assertOk(exports.whip_core:StoreGive(panel(1), ITEM, 2), nil, 'something in it')

                ClientExecWait(source, EV_DESTROY, 3000, panel(1), 0)

                assertLastReject(EV_DESTROY, 'Nothing is destroyed in here', 'refused with the hook\'s own reason')
                assertNotNil(seen, 'onValidate was asked')
                assertEqual(seen and seen.direction, 'out', 'as the item leaving')
                assertEqual(seen and seen.destroyed, true, 'told it is being destroyed')
                assertNil(seen and seen.other, 'with no other end')
                local still = exports.whip_core:GetItemAt(panel(1))
                assertEqual(still and still.amount, 2, 'the item is still there')
                exports.whip_core:ClosePanel(source, PANEL)
            end,
        },
        {
            name = 'Destroy in a panel: onChange hears it',
            fn = function(source)
                local changed = nil
                assertTrue(exports.whip_core:OpenPanel(source, {
                    id = PANEL, label = 'MSC44 hear', slots = 2,
                    onChange = function(c) changed = c end,
                }), 'panel open, with onChange')
                assertOk(exports.whip_core:StoreGive(panel(1), ITEM, 2), nil, 'something in it')

                ClientExecWait(source, EV_DESTROY, 3000, panel(1), 0)

                assertLastReject(EV_DESTROY, nil, 'the destroy was accepted')
                assertNil(exports.whip_core:GetItemAt(panel(1)), 'the slot is empty')
                local c = waitFor(function() return changed end, 2000)
                assertNotNil(c, 'onChange ran')
                assertEqual(c and c.direction, 'out', 'as the item leaving')
                assertEqual(c and c.destroyed, true, 'destroyed')
                assertEqual(c and c.item, ITEM, 'naming what went')
                assertNil(c and c.items and c.items[1], 'and the panel holds nothing there now')
                exports.whip_core:ClosePanel(source, PANEL)
            end,
        },

        -- ==========================================
        -- Split — through the move hooks now
        -- ==========================================
        {
            name = 'Split in a stash puts the new half in the first free slot',
            fn = function(source, ctx)
                emptyStash(ctx)
                assertOk(exports.whip_core:StoreGive(stash(ctx, 3), ITEM, 6), nil, 'seeded slot 3')

                ClientExecWait(source, EV_SPLIT, 3000, stash(ctx, 3), 2, 0)

                assertLastReject(EV_SPLIT, nil, 'the split was accepted')
                local origin, half = stashItem(ctx, 3), stashItem(ctx, 1)
                assertEqual(origin and origin.amount, 4, 'four stayed')
                assertEqual(half and half.amount, 2, 'two went to slot 1, the first free one')
                assertEqual(exports.whip_core:StoreCount(stash(ctx), ITEM), 6, 'nothing made, nothing lost')
            end,
        },
        {
            name = 'Split always leaves one behind',
            fn = function(source, ctx)
                emptyStash(ctx)
                assertOk(exports.whip_core:StoreGive(stash(ctx, 1), ITEM, 3), nil, 'seeded')

                ClientExecWait(source, EV_SPLIT, 3000, stash(ctx, 1), 99, 0)

                assertLastReject(EV_SPLIT, nil, 'accepted')
                assertEqual(stashItem(ctx, 1) and stashItem(ctx, 1).amount, 1, 'one stayed')
                assertEqual(stashItem(ctx, 2) and stashItem(ctx, 2).amount, 2, 'the rest moved')
            end,
        },
        {
            name = 'Split in a panel asks its onValidate, which can refuse it',
            fn = function(source)
                local seen = nil
                assertTrue(exports.whip_core:OpenPanel(source, {
                    id = PANEL, label = 'MSC44 nosplit', slots = 3,
                    onValidate = function(c)
                        seen = c
                        if c.direction == 'within' then return false, 'No splitting in here' end
                    end,
                }), 'panel open, with onValidate')
                assertOk(exports.whip_core:StoreGive(panel(1), ITEM, 6), nil, 'six in it')

                ClientExecWait(source, EV_SPLIT, 3000, panel(1), 3, 0)

                assertLastReject(EV_SPLIT, 'No splitting in here', 'refused with the hook\'s reason')
                assertEqual(seen and seen.direction, 'within', 'the hook saw a move within the panel')
                local still = exports.whip_core:GetItemAt(panel(1))
                assertEqual(still and still.amount, 6, 'the stack is whole')
                assertNil(exports.whip_core:GetItemAt(panel(2)), 'and nothing appeared beside it')
                exports.whip_core:ClosePanel(source, PANEL)
            end,
        },
        {
            name = 'Split refuses a stack of one',
            fn = function(source, ctx)
                emptyStash(ctx)
                assertOk(exports.whip_core:StoreGive(stash(ctx, 1), ITEM, 1), nil, 'seeded')
                ClientExecWait(source, EV_SPLIT, 3000, stash(ctx, 1), 1, 0)
                assertLastReject(EV_SPLIT, 'Nothing to split', 'refused, saying why')
            end,
        },

        -- ==========================================
        -- quickMove — shift + click
        -- ==========================================
        {
            name = 'Shift-click from the pockets joins a stack in the stash before taking an empty slot',
            fn = function(source, ctx)
                emptyStash(ctx)
                assertOk(exports.whip_core:StoreGive(stash(ctx, 4), ITEM, 2), nil, 'two already in slot 4')
                local slot = lastSlot()
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', slot, ITEM, 3)

                ClientExecWait(source, EV_QUICK, 3000, pocket(slot), stash(ctx), 0)

                assertLastReject(EV_QUICK, nil, 'the move was accepted')
                assertEqual(stashItem(ctx, 4) and stashItem(ctx, 4).amount, 5, 'it joined the stack in slot 4')
                assertNil(stashItem(ctx, 1), 'rather than taking empty slot 1')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 0, 'and left the pockets')
            end,
        },
        {
            name = 'Shift-click from the stash lands in the pockets',
            fn = function(source, ctx)
                emptyStash(ctx)
                RemoveAllOf(source, SINGLE)
                assertOk(exports.whip_core:StoreGive(stash(ctx, 2), SINGLE, 1), nil, 'seeded')

                ClientExecWait(source, EV_QUICK, 3000, stash(ctx, 2), { kind = 'player' }, 0)

                assertLastReject(EV_QUICK, nil, 'the move was accepted')
                assertNil(stashItem(ctx, 2), 'it left the stash')
                assertEqual(exports.whip_core:GetItemCount(source, SINGLE), 1, 'and is in the pockets')
            end,
        },
        {
            name = 'Shift-click into a full store is refused, and nothing moves',
            fn = function(source)
                assertTrue(exports.whip_core:OpenPanel(source, { id = PANEL, label = 'MSC44 full', slots = 1 }),
                    'a one-slot panel open')
                assertOk(exports.whip_core:StoreGive(panel(1), SINGLE, 1), nil, 'and full')
                local slot = lastSlot()
                RemoveAllOf(source, SINGLE)
                SeedSlot(source, 'player', slot, SINGLE, 1)

                ClientExecWait(source, EV_QUICK, 3000, pocket(slot), { kind = 'panel', id = PANEL }, 0)

                assertLastReject(EV_QUICK, 'No room there', 'refused, saying why')
                local still = exports.whip_core:GetItemAt(PocketAddr(source, 'player', slot))
                assertEqual(still and still.item, SINGLE, 'the item stayed in the pockets')
                exports.whip_core:ClosePanel(source, PANEL)
            end,
        },
        {
            name = 'Shift-click refuses an item the store does not take',
            fn = function(source)
                assertTrue(exports.whip_core:OpenPanel(source, {
                    id = PANEL, label = 'MSC44 picky', slots = 3, allowedItems = { ITEM },
                }), 'a panel that takes only MSC44')
                local slot = lastSlot()
                RemoveAllOf(source, SINGLE)
                SeedSlot(source, 'player', slot, SINGLE, 1)

                ClientExecWait(source, EV_QUICK, 3000, pocket(slot), { kind = 'panel', id = PANEL }, 0)

                assertLastReject(EV_QUICK, 'That item does not go there', 'refused, saying why')
                assertEqual(exports.whip_core:GetItemCount(source, SINGLE), 1, 'the item stayed')
                exports.whip_core:ClosePanel(source, PANEL)
            end,
        },
        {
            name = 'Shift-click cannot reach a store the player has not opened',
            fn = function(source)
                local slot = lastSlot()
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', slot, ITEM, 1)

                ClientExecWait(source, EV_QUICK, 3000, pocket(slot), { kind = 'container', id = 999999 }, 0)

                assertRefusedSaying(EV_QUICK, 'not open for you', 'refused by the address check')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 1, 'the item stayed')
            end,
        },
        {
            name = 'A whole-store address still refuses a bad slot when one is sent',
            fn = function(source, ctx)
                -- "No slot" is allowed for quickMove's destination; a slot that IS sent is checked
                -- as strictly as ever, so a bad one is never read as "none".
                local slot = lastSlot()
                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', slot, ITEM, 1)

                ClientExecWait(source, EV_QUICK, 3000, pocket(slot), stash(ctx, 0), 0)

                assertRefusedSaying(EV_QUICK, 'slot must be a positive integer', 'refused')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 1, 'the item stayed')
            end,
        },

        -- ==========================================
        -- The ground — Split and Destroy on the Nearby panel
        -- ==========================================
        {
            name = 'Split a pile on the ground: two piles, same total',
            fn = function(source)
                clearGroundOf(ITEM)
                local row = pileNearPlayer(source, ITEM, 5)

                ClientExecWait(source, EV_GSPLIT, 3000, row.id, 2, 0)

                assertLastReject(EV_GSPLIT, nil, 'the split was accepted')
                assertEqual(exports.whip_core:GetGroundItem(row.id).amount, 3, 'three stayed in the pile')
                assertDbScalar('SELECT `amount` FROM `ground_items` WHERE `id` = ?', { row.id }, 3,
                    'and the row says so')
                assertDbScalar('SELECT COUNT(*) FROM `ground_items` WHERE `item` = ?', { ITEM }, 2,
                    'there are two piles now')
                -- CAST: SUM is a DECIMAL, which can arrive as text; SIGNED comes back a number like COUNT.
                assertDbScalar('SELECT CAST(SUM(`amount`) AS SIGNED) FROM `ground_items` WHERE `item` = ?', { ITEM }, 5,
                    'holding five between them')
                clearGroundOf(ITEM)
            end,
        },
        {
            name = 'Split refuses a pile of one on the ground',
            fn = function(source)
                clearGroundOf(ITEM)
                local row = pileNearPlayer(source, ITEM, 1)
                ClientExecWait(source, EV_GSPLIT, 3000, row.id, 1, 0)
                assertLastReject(EV_GSPLIT, 'Nothing to split', 'refused, saying why')
                assertEqual(exports.whip_core:GetGroundItem(row.id).amount, 1, 'the pile is unchanged')
                clearGroundOf(ITEM)
            end,
        },
        {
            name = 'Destroy a pile on the ground',
            fn = function(source)
                clearGroundOf(ITEM)
                local row = pileNearPlayer(source, ITEM, 4)

                ClientExecWait(source, EV_GDESTROY, 3000, row.id, 0)

                assertLastReject(EV_GDESTROY, nil, 'the destroy was accepted')
                assertNil(exports.whip_core:GetGroundItem(row.id), 'the pile is gone')
                assertDbScalar('SELECT COUNT(*) FROM `ground_items` WHERE `id` = ?', { row.id }, 0,
                    'and so is its row')
            end,
        },
    },
})
