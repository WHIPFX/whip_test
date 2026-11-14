-- ============================================
-- Test: Item Use & Handler Registration
-- Verifies RegisterUseHandler, handler invocation,
-- consumption behavior, and context actions.
-- (RegisterItemUse, its second name, was removed 09-24.)
--
-- Every use goes through the real hotbar event, whip_core:server:useItem, from the tester's
-- client. That event is rate limited to one per 500ms, so each test waits that out FIRST and
-- then asserts the use was not refused — otherwise the rate limiter and the rule under test
-- look identical ("the handler did not run").
-- ============================================

local USE_EVENT = 'whip_core:server:useItem'

--- Use the item in a pocket slot the way the hotbar does, and pin how the server answered.
---
--- `refusedWith` is the handler's own refusal when the use is turned down by the RULE under test
--- (a cooldown, a crashed handler): since 09-24 those are recorded as rejections with the reason
--- the player is shown (UI-1), so a test can tell them from the rate limiter by the reason.
local function useSlot(source, slot, refusedWith)
    Wait(600)   -- clear useItem's own 500ms rate limit
    assertTrue(ClientExecWait(source, USE_EVENT, 3000, 'player', slot), 'the server answered useItem')
    assertLastReject(USE_EVENT, refusedWith,
        refusedWith and ('refused for "%s", not by the gate'):format(refusedWith) or 'the use was accepted')
end

RegisterTestModule({
    order    = 17,
    category = 'Item Use',

    setup = function(source, ctx)
        local p = exports.whip_core:GetPlayer(source)
        assertNotNil(p, 'setup: GetPlayer')
        ctx.charId = p.charId

        -- Register test items
        exports.whip_core:RegisterItem('_test_usable', {
            name   = 'Test Usable',
            weight = 0.1,
            type   = 'misc',
            usable = true,
            stack  = true,
            maxStack = 10,
        })
        exports.whip_core:RegisterItem('_test_usable_noeat', {
            name   = 'Test No Consume',
            weight = 0.1,
            type   = 'misc',
            usable = true,
            stack  = true,
            maxStack = 10,
        })
        exports.whip_core:RegisterItem('_test_usable_cd', {
            name   = 'Test Cooldown',
            weight = 0.1,
            type   = 'misc',
            usable = true,
            stack  = true,
            maxStack = 10,
            cooldown = 5,
        })
        exports.whip_core:RegisterItem('_test_usable_err', {
            name   = 'Test Broken Handler',
            weight = 0.1,
            type   = 'misc',
            usable = true,
            stack  = true,
            maxStack = 10,
        })
    end,

    teardown = function(ctx, source)
        RemoveAllOf(source, '_test_usable')
        RemoveAllOf(source, '_test_usable_noeat')
        RemoveAllOf(source, '_test_usable_cd')
        RemoveAllOf(source, '_test_usable_err')
    end,

    tests = {
        -- These three tests used to be `pcall(register…); assertTrue(did not throw)`.
        -- RegisterItemUse, RegisterContextAction and RegisterUseHandler are each a single
        -- bare table assignment (events_misc.lua) that cannot throw, so all three were
        -- guaranteed green even if the export body were `function() end`. They are replaced
        -- with tests that actually USE an item and observe the consequence.
        -- (09-24: RegisterItemUse was removed; every test here registers through RegisterUseHandler.)
        {
            name = 'Using an item invokes its handler and consumes one',
            fn = function(source, ctx)
                -- 09-24: a handler is called with `(source, player, slotData, addr)` — the used item's
                -- address. It was `(source, player, slotData, container, slot)`.
                local invoked, handedAddr = false, nil
                exports.whip_core:RegisterUseHandler('_test_usable', function(src, player, slotData, addr)
                    invoked = true
                    handedAddr = addr
                    return true   -- consume
                end)

                RemoveAllOf(source, '_test_usable')
                SeedSlot(source, 'player', 1, '_test_usable', 3)

                useSlot(source, 1)

                assertTrue(invoked, 'the registered handler actually ran')
                assertEqual(exports.whip_core:GetItemCount(source, '_test_usable'), 2,
                    'handler returning true consumed exactly one')
                assertEqual(handedAddr and handedAddr.sub, 'player', 'the handler was handed the pocket used')
                assertEqual(handedAddr and handedAddr.slot, 1, 'and the slot used')
            end,
        },
        {
            name = 'Handler returning false does NOT consume the item',
            fn = function(source, ctx)
                -- The contract a reusable item relies on — a jerry can, a tool — and the one whip's
                -- declared timed uses answer with, having taken the item themselves.
                local invoked = false
                exports.whip_core:RegisterUseHandler('_test_usable_noeat', function(src, player, slotData)
                    invoked = true
                    return false   -- do NOT consume
                end)

                RemoveAllOf(source, '_test_usable_noeat')
                SeedSlot(source, 'player', 2, '_test_usable_noeat', 2)

                useSlot(source, 2)

                assertTrue(invoked, 'the registered handler actually ran')
                assertEqual(exports.whip_core:GetItemCount(source, '_test_usable_noeat'), 2,
                    'returning false left the count untouched')
            end,
        },
        -- 'RegisterUseHandler is an equivalent entry point to RegisterItemUse': removed 09-24 with RegisterItemUse.
        {
            name = 'Cooldown blocks a second use inside the window',
            fn = function(source, ctx)
                -- '_test_usable_cd' declares cooldown = 5 in this module's setup.
                local uses = 0
                exports.whip_core:RegisterUseHandler('_test_usable_cd', function(src, player, slotData)
                    uses = uses + 1
                    return true
                end)

                RemoveAllOf(source, '_test_usable_cd')
                SeedSlot(source, 'player', 4, '_test_usable_cd', 5)

                -- Three uses, each past useItem's rate limit — the two that do nothing are refused
                -- BY THE COOLDOWN, the rule under test, and say so; not by the gate in front of it.
                -- About two seconds, well inside five.
                useSlot(source, 4)
                useSlot(source, 4, 'Item on cooldown')
                useSlot(source, 4, 'Item on cooldown')

                assertEqual(uses, 1, 'only the first use inside the cooldown window ran')
                assertEqual(exports.whip_core:GetItemCount(source, '_test_usable_cd'), 4,
                    'only one item consumed despite three attempts')
            end,
        },
        {
            -- A handler that throws must not cost the player the item: Inventory.useItem pcalls it
            -- and answers 'Use failed' before anything is consumed. The stack trace this prints in
            -- the console is EXPECTED output from this test.
            name = 'A handler that errors consumes nothing',
            fn = function(source, ctx)
                local reached = false
                exports.whip_core:RegisterUseHandler('_test_usable_err', function(src, player, slotData)
                    reached = true
                    error('[EXPECTED] whip_test 17_item_use is deliberately erroring here')
                end)

                RemoveAllOf(source, '_test_usable_err')
                SeedSlot(source, 'player', 5, '_test_usable_err', 2)

                useSlot(source, 5, 'Use failed')

                assertTrue(reached, 'the handler was reached')
                assertEqual(exports.whip_core:GetItemCount(source, '_test_usable_err'), 2,
                    'an erroring handler consumed nothing')
            end,
        },
        {
            -- An address is REJECTED, never clamped: slot 0 used to arrive as slot 1 and use
            -- whatever was sitting there.
            name = 'Using an out-of-range slot is refused, not clamped onto a real one',
            fn = function(source, ctx)
                local uses = 0
                exports.whip_core:RegisterUseHandler('_test_usable', function() uses = uses + 1 return true end)
                RemoveAllOf(source, '_test_usable')
                SeedSlot(source, 'player', 1, '_test_usable', 2)

                Wait(600)
                assertTrue(ClientExecWait(source, USE_EVENT, 3000, 'player', 0), 'the server answered slot 0')
                assertLastReject(USE_EVENT, 'slot: invalid id', 'slot 0 refused as an address')

                Wait(600)
                assertTrue(ClientExecWait(source, USE_EVENT, 3000, 'player', 51), 'the server answered slot 51')
                assertLastReject(USE_EVENT, 'slot: invalid id', 'slot 51 refused as an address')

                assertEqual(uses, 0, 'nothing was used')
                assertEqual(exports.whip_core:GetItemCount(source, '_test_usable'), 2, 'nothing was consumed')
            end,
        },
        {
            name = 'GetItemDef returns correct properties for usable item',
            fn = function(source, ctx)
                local def = exports.whip_core:GetItemDef('_test_usable_cd')
                assertNotNil(def, 'GetItemDef returned')
                assertTrue(def.usable, 'Item is usable')
                assertEqual(def.cooldown, 5, 'Cooldown value preserved')
            end,
        },
    }
})
