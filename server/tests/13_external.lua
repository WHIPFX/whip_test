-- The item the "accepted" RegisterPanelItem test opens for real, and the context action that opens it.
local PANEL_HOST   = '_test_panelitem_ok'
local PANEL_ACTION = '_test_panel_open'

--- The panels this player has open, from GetOpenStores (GetOpenPanels until 09-24). Each is an
--- address, `{ kind = 'panel', id, owner, label }`.
local function openPanels(source)
    local out = {}
    for _, s in ipairs(exports.whip_core:GetOpenStores(source) or {}) do
        if s.kind == 'panel' then out[#out + 1] = s end
    end
    return out
end

RegisterTestModule({
    order    = 13,
    category = 'Panel (OpenPanel API)',

    -- START WITH NO UI UP. The client refuses to open a panel over an inventory that is already on
    -- screen, and answers by closing the session it was sent — asynchronously, so it lands a moment
    -- later, in the middle of whichever test happens to be running.
    setup = function(source)
        ClientCloseAllUI(source)
        pcall(exports.whip_core.ClosePanel, exports.whip_core, source)
    end,

    teardown = function(ctx, source)
        if source then
            pcall(exports.whip_core.ClosePanel, exports.whip_core, source)
            RemoveAllOf(source, PANEL_HOST)
        end
    end,

    tests = {
        {
            -- `true` no longer means "your config created this panel". A panel's contents are ONE
            -- shared table keyed on its id, so opening either creates the instance or JOINS an
            -- existing one — and a second opener's `items` are deliberately ignored. The boolean
            -- is identical in both cases, so assert the instance instead.
            name = 'OpenPanel creates the shared instance for its id',
            fn = function(source)
                local ok = exports.whip_core:OpenPanel(source, {
                    id    = '_test_panel',
                    label = 'Test Panel',
                    slots = 3,
                    items = {},
                })
                assertTrue(ok, 'OpenPanel')

                -- 09-24: GetSharedPanelItems was removed; the panel is read by its address, and a
                -- panel nobody has open answers false with a reason where it answered nil.
                local inst, err = exports.whip_core:StoreRead({ kind = 'panel', id = '_test_panel' })
                assertOk(inst, err, 'an instance exists for this panel id')
                assertNil(next(inst.items), 'seeded from the config items, which were empty')

                local none, why = exports.whip_core:StoreRead({ kind = 'panel', id = '_no_such_panel' })
                assertFalse(none, 'false for a panel nobody has open')
                assertEqual(why, 'that panel is not open', 'and it says so')
            end,
        },
        {
            -- "Snapshot" was the old contract's word, from when every viewer held a private deep
            -- copy and a snapshot was the only readable state a panel had. There is one table
            -- now, and two ways to read it — by viewer, and by panel id. Both must agree, and
            -- both must hand back a COPY rather than the live instance.
            --
            -- The write and the reads are one test now. UpdatePanelSlot used to have a test of its
            -- own that asserted only its return value, and the effect was checked by the next test.
            --
            -- 09-24: UpdatePanelSlot, GetPanelItems and GetSharedPanelItems were removed. The write
            -- is StoreGive on the panel's address, and the two reads are StoreRead of that address
            -- through this viewer (`owner = source`) and by id alone (any viewer).
            name = 'StoreGive writes the shared table; both reads agree, and neither leaks it',
            fn = function(source)
                local slot, err = exports.whip_core:StoreGive(
                    { kind = 'panel', id = '_test_panel', slot = 1 }, 'food', 1)
                assertOk(slot, err, 'StoreGive into the panel')
                assertEqual(slot, 1, 'it answered the slot it filled')

                local viewerAddr = { kind = 'panel', id = '_test_panel', owner = source }
                local byViewer, viewerErr = exports.whip_core:StoreRead(viewerAddr)
                local byId, idErr         = exports.whip_core:StoreRead({ kind = 'panel', id = '_test_panel' })
                assertOk(byViewer, viewerErr, 'StoreRead through this viewer answered')
                assertOk(byId, idErr, 'StoreRead by id answered')

                local mine, shared = byViewer.items, byId.items
                assertEqual(mine[1] and mine[1].item, 'food', 'slot 1 set by StoreGive')
                assertEqual(mine[1].amount, 1, 'with the amount given')
                assertEqual(shared[1] and shared[1].item, mine[1].item,
                    'both reads see the one shared table')

                -- Mutating what we were handed must not reach the panel.
                mine[1].amount = 99
                local again = exports.whip_core:StoreRead(viewerAddr)
                assertEqual(again and again.items[1] and again.items[1].amount, 1,
                    'the returned table is a copy, not the live instance')
            end,
        },
        {
            -- Under the old contract close WAS teardown, so `true` implied the panel was gone.
            -- Now it returns true for any viewer leaving and only the LAST one tears the instance
            -- down — so the boolean stopped distinguishing the two, which is exactly what changed.
            name = 'The last viewer closing tears the instance down',
            fn = function(source)
                local ok = exports.whip_core:ClosePanel(source)
                assertTrue(ok, 'ClosePanel')

                -- 09-24: GetPanelItems / GetSharedPanelItems were removed. The session is gone when
                -- GetOpenStores no longer lists it; the instance when StoreRead cannot find it.
                assertEqual(#openPanels(source), 0, 'session gone')
                local gone, why = exports.whip_core:StoreRead({ kind = 'panel', id = '_test_panel' })
                assertFalse(gone, 'last viewer out — the instance was destroyed')
                assertEqual(why, 'that panel is not open', 'and StoreRead says so')

                local again, againWhy = exports.whip_core:ClosePanel(source)
                assertFalse(again, 'a second close finds no session')
                assertEqual(againWhy, 'No such panel open', 'and says why')
            end,
        },
        {
            -- WAS `pcall(...)` + `assertTrue(ok, 'did not crash')`, which proved nothing.
            --
            -- RegisterPanelItem cannot raise — it prints and returns `false, reason` — so the
            -- assertion was green no matter what the export did, or did not do. The comment also
            -- named the wrong branch: the no-action check runs BEFORE the not-registered check,
            -- so an unregistered item with no action refuses for the FIRST reason and never
            -- reaches "is not registered". The console line during the run says exactly that.
            --
            -- The three tests here pin both refusal branches and the accept path.
            name = 'RegisterPanelItem refuses when nothing names the action that opens the panel',
            fn = function()
                local ok, reason = exports.whip_core:RegisterPanelItem('_test_panel_item', {
                    slots        = 2,
                    label        = 'Test Panel',
                    storageKey   = 'slots',
                    allowedItems = { food = {} },
                })
                assertFalse(ok, 'refused — no config.action and no item defaultAction')
                assertNotNil(reason, 'and said why')
                assertTrue(tostring(reason):find('no defaultAction', 1, true) ~= nil,
                    ('refused on the ACTION branch, not some other one (got "%s")'):format(tostring(reason)))
            end,
        },
        {
            name = 'RegisterPanelItem refuses an action on an item that does not exist',
            fn = function()
                -- Naming an action gets past the first branch, so this is the only way to reach
                -- the second one. Without this test that branch had no coverage at all.
                local ok, reason = exports.whip_core:RegisterPanelItem('_test_panel_ghost', {
                    slots = 2, label = 'Ghost Panel', action = PANEL_ACTION,
                })
                assertFalse(ok, 'refused — the item is not registered')
                assertTrue(tostring(reason):find('not registered', 1, true) ~= nil,
                    ('refused on the ITEM branch (got "%s")'):format(tostring(reason)))
            end,
        },
        {
            -- config.action exists so a satellite does not have to invent a defaultAction it does
            -- not want purely to attach a panel — a phone opens from a context option and is not a
            -- usable item at all.
            --
            -- "ACCEPTED" MUST MEAN "OPENS". This used to assert the registration returned true and
            -- stop — for an item that declared no contextOptions, which customContextAction refuses
            -- to run an action for (it only runs actions the item itself names). The registration
            -- succeeded and the panel could never have been opened by anybody. So the item now
            -- names the action, and the test opens it the way a player does: through the context
            -- menu event, from the tester's client.
            name = 'RegisterPanelItem with config.action: the context action opens the panel',
            fn = function(source)
                exports.whip_core:RegisterItem(PANEL_HOST, {
                    name = 'Panel Item Fixture', desc = 'panel registration fixture',
                    weight = 0.1, type = 'misc', stack = false, maxStack = 1,
                    contextOptions = { { action = PANEL_ACTION, label = 'Open' } },
                })

                local ok, reason = exports.whip_core:RegisterPanelItem(PANEL_HOST, {
                    slots = 2, label = 'Test Panel', storageKey = 'slots',
                    action = PANEL_ACTION,
                })
                assertTrue(ok, 'registered: ' .. tostring(reason))

                ClientCloseAllUI(source)
                SeedSlot(source, 'player', 10, PANEL_HOST, 1)
                assertTrue(ClientExecWait(source, 'whip_core:server:customContextAction', 3000,
                    PANEL_ACTION, 'player', 10), 'the server answered the context action')

                local opened = nil
                for _, p in ipairs(openPanels(source)) do
                    if tostring(p.id):sub(1, #PANEL_ACTION + 1) == PANEL_ACTION .. '_' then
                        opened = p
                        break
                    end
                end
                assertNotNil(opened, 'a panel for the item is open')
                assertEqual(opened.label, 'Test Panel', 'with the registered label')

                -- 09-24: the slot count and the contents come from StoreRead of the panel's address
                -- (GetOpenPanels listed the slots, and GetPanelItems read the items, until then).
                -- The generator RegisterPanelItem installs gave the item its empty storage.
                local store, err = exports.whip_core:StoreRead({ kind = 'panel', id = opened.id })
                assertOk(store, err, 'its contents are readable by id')
                assertEqual(store.slots, 2, 'with the registered slot count')
                assertNil(next(store.items), 'and empty, as a new item is')

                assertTrue(exports.whip_core:ClosePanel(source, opened.id), 'closed by id')
            end,
        },
    }
})
