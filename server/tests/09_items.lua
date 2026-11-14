RegisterTestModule({
    order    = 9,
    category = 'Item Registration',
    teardown = function(ctx, source)
        if source then
            RemoveAllOf(source, '_test_registered_item')
            RemoveAllOf(source, '_test_ctx_item')
        end
        -- THE GENERATOR GOES TOO. RegisterItemDefaultMetadata has no owner sweep, so the function this
        -- module installs stayed registered after the run — a reference into whip_test's Lua state,
        -- called for every '_test_registered_item' anyone creates. Registering nil removes it.
        pcall(exports.whip_core.RegisterItemDefaultMetadata, exports.whip_core, '_test_registered_item', nil)
    end,
    tests = {
        {
            name = 'GetItemDef returns known item',
            fn = function()
                local def = exports.whip_core:GetItemDef('food')
                assertNotNil(def, 'GetItemDef food')
                assertType(def.name, 'string', 'name type')
                assertType(def.weight, 'number', 'weight type')
            end,
        },
        {
            name = 'GetItemDef returns nil for unknown',
            fn = function()
                assertNil(exports.whip_core:GetItemDef('_test_nonexistent_xyzabc'), 'unknown item')
            end,
        },
        {
            -- whip_gunny's melee weapons (29 Sep 2026) are equipped and put away and nothing else, so
            -- the inventory offers Equip only — never "Open", they have no magazine slot. And the
            -- handheld flashlight must not read the same as the gun-mounted one.
            name = "whip_gunny's melee weapons offer Equip only, and the handheld flashlight has its own name",
            fn = function()
                if GetResourceState('whip_gunny') ~= 'started' then skip('needs whip_gunny running') end
                local bat = exports.whip_core:GetItemDef('gunny_bat')
                assertNotNil(bat, 'gunny_bat is registered')
                assertEqual(bat.type, 'weapon', 'as a weapon')
                local actions = {}
                for _, o in ipairs(bat.contextOptions or {}) do actions[#actions + 1] = tostring(o.action) end
                assertEqual(table.concat(actions, ','), 'whip_gunny:equip_weapon', 'Equip and nothing else')

                local torch = exports.whip_core:GetItemDef('gunny_torch')
                local rail  = exports.whip_core:GetItemDef('gunny_flashlight')
                assertNotNil(torch, 'gunny_torch is registered')
                assertNotNil(rail, 'the flashlight attachment still is')
                assertTrue(torch.name ~= rail.name,
                    ('two different names in the inventory (got "%s" and "%s")'):format(tostring(torch.name), tostring(rail.name)))
            end,
        },
        {
            name = 'RegisterItem makes new item available',
            fn = function()
                local ok, err = exports.whip_core:RegisterItem('_test_registered_item', {
                    name   = 'Test Item',
                    weight = 0.1,
                    type   = 'misc',
                    stack  = true,
                    maxStack = 10,
                })
                assertOk(ok, err, 'RegisterItem')
                local def = exports.whip_core:GetItemDef('_test_registered_item')
                assertNotNil(def, 'registered item')
                assertEqual(def.name, 'Test Item', 'name')
                assertEqual(def.weight, 0.1, 'weight')
            end,
        },
        {
            -- Re-registering YOUR OWN item is normal — onReady runs again on every start — and a
            -- changed definition replaces the old one. The same definition again is a no-op that
            -- still answers true (it used to make every client download every item definition).
            name = 'Re-registering your own item replaces it, and the same definition again is fine',
            fn = function()
                local ok, err = exports.whip_core:RegisterItem('_test_registered_item', {
                    name = 'Test Item', weight = 0.2, type = 'misc', stack = true, maxStack = 10,
                })
                assertOk(ok, err, 'a changed definition from the same owner')
                assertEqual(exports.whip_core:GetItemDef('_test_registered_item').weight, 0.2,
                    'the new definition replaced the old')

                local same, sameErr = exports.whip_core:RegisterItem('_test_registered_item', {
                    name = 'Test Item', weight = 0.2, type = 'misc', stack = true, maxStack = 10,
                })
                assertOk(same, sameErr, 'the identical definition again')
            end,
        },
        {
            -- AN ITEM BELONGS TO WHOEVER DECLARED IT. Taking over someone else's used to be silent
            -- last-write-wins: any resource could redefine `cash` and every player's inventory
            -- changed under it. whip_core owns every item in its own config.
            --
            -- THE PROBE IS cash's OWN DEFINITION, handed back. If the refusal ever broke, the
            -- "hijack" would change nothing a player could notice — a test that could damage the
            -- server's currency on failure is not one worth running.
            name = 'RegisterItem refuses an item another resource owns',
            fn = function()
                local current = exports.whip_core:GetItemDef('cash')
                assertNotNil(current, 'cash is defined')

                local ok, err = exports.whip_core:RegisterItem('cash', current)
                assertFalse(ok, 'whip_test cannot redefine whip_core\'s cash')
                -- The one registration rule's wording (REG-1): 'item "cash" belongs to whip_core'.
                assertTrue(tostring(err):find('belongs to whip_core', 1, true) ~= nil,
                    ('and says who owns it (got "%s")'):format(tostring(err)))

                local bad, badErr = exports.whip_core:RegisterItem('', { name = 'x' })
                assertFalse(bad, 'an empty key is refused')
                assertType(badErr, 'string', 'with a reason')
            end,
        },
        {
            name = 'RegisterItemDefaultMetadata + AddItem produces metadata',
            fn = function(source)
                exports.whip_core:RegisterItemDefaultMetadata('_test_registered_item', function(itemKey)
                    return { generated = true, ts = 12345 }
                end)
                -- (09-24: AddItem answers where it went, 'inventory' or 'ground', and a FindItem
                -- entry is `{ item, amount, metadata, addr }` — no `.data` level.)
                local where, err = exports.whip_core:AddItem(source, '_test_registered_item', 1)
                assertEqual(where, 'inventory', 'AddItem with meta gen: ' .. tostring(err))
                -- Verify metadata was generated
                local found = exports.whip_core:FindItem(source, '_test_registered_item')
                assertNotNil(found, 'FindItem')
                assertNotNil(found.metadata, 'metadata exists on item')
                assertTrue(found.metadata.generated, 'metadata.generated is true')
                -- (Removed in teardown. This used RemoveItem(item, 99): a stack of one cannot pay
                -- 99, so RemoveItem refused and the item leaked into every later module.)
            end,
        },
        {
            -- USES the action rather than only registering it.
            --
            -- The export's whole body is one table assignment, which cannot raise — so "it did
            -- not throw" was green regardless of whether the function did anything at all, and
            -- the registered handler was never invoked. 17_item_use already deleted this exact
            -- pattern for RegisterItemUse and RegisterUseHandler and replaced it with tests that
            -- use an item and observe the consequence; this copy was left behind.
            --
            -- (A dead tester is refused before any of this runs — the runner will not start a
            -- run for one, which is what keeps this test honest.)
            name = 'A registered context action runs when the item is used',
            fn = function(source)
                -- 09-24: an action is called with `(source, player, slotData, addr)` — the used item's
                -- address. It was `(source, player, slotData, container, slot)`.
                local fired, handedAddr = false, nil
                exports.whip_core:RegisterContextAction('_test_action',
                    function(src, player, slotData, addr)
                        fired = true
                        handedAddr = addr
                    end)

                -- `usable` MUST BE FALSY for a defaultAction to fire, and that is not obvious.
                --
                -- events_inventory dispatches defaultAction only in the `elseif err == 'Item not
                -- usable'` FALLBACK arm. Inventory.use returns that string from `if not def.usable`,
                -- so marking the item usable takes the normal path, finds no registered use handler,
                -- and is refused (P-007) without the defaultAction. That is how weapons and magazines are
                -- declared, and it is why this fixture leaves `usable` unset.
                exports.whip_core:RegisterItem('_test_ctx_item', {
                    name = 'Ctx Fixture', desc = 'context action fixture',
                    weight = 0.1, type = 'misc', stack = false, maxStack = 1,
                    defaultAction = '_test_action',
                })

                SeedSlot(source, 'player', 6, '_test_ctx_item', 1)
                -- Waits for the SERVER to finish the use now, not for a fixed half second.
                assertTrue(ClientExecWait(source, 'whip_core:server:useItem', 3000, 'player', 6),
                    'the server answered useItem')
                assertLastReject('whip_core:server:useItem', nil, 'useItem')

                assertTrue(fired, 'the registered context action actually ran')
                assertEqual(handedAddr and handedAddr.sub, 'player', 'it was handed the pocket used')
                assertEqual(handedAddr and handedAddr.slot, 6, 'and the slot used')
                assertEqual(exports.whip_core:GetItemCount(source, '_test_ctx_item'), 1,
                    'a defaultAction dispatch does not consume the item')
                -- (Removed in teardown.)
            end,
        },
        {
            name = 'GetItemDefs includes registered item',
            fn = function()
                local all = exports.whip_core:GetItemDefs()
                assertNotNil(all['_test_registered_item'], 'registered item in GetItemDefs')
            end,
        },
    }
})
