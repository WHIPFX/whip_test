-- ============================================
-- Test: Panel System (OpenPanel API)
-- Verifies OpenPanel, ClosePanel, the onClose hook in the OpenPanel config, and a panel read and
-- written by its address with StoreRead / StoreGive / StoreTake.
-- 09-24: GetPanelItems, GetSharedPanelItems, GetOpenPanels, UpdatePanelSlot, SetPanelOnMove and
-- SetPanelOnClose were removed; each test here now uses the call that replaced it.
--
-- EACH TEST STARTS BY CLOSING EVERYTHING. They used to close on their last line, so one failed
-- assertion left its panel open and every later test here opened on top of it — and re-opening a
-- panel that is already open is a no-op, so the next test silently inherited the old contents.
-- ============================================

--- Close every panel the tester has open, so a test starts from nothing.
local function fresh(source)
    pcall(exports.whip_core.ClosePanel, exports.whip_core, source)
end

--- The panels this player has open, in GetOpenStores' order (sorted by id). Each is an address,
--- `{ kind = 'panel', id, owner, label }`. (GetOpenPanels answered this until 09-24.)
local function openPanels(source)
    local out = {}
    for _, s in ipairs(exports.whip_core:GetOpenStores(source) or {}) do
        if s.kind == 'panel' then out[#out + 1] = s end
    end
    return out
end

--- What a panel holds, keyed by slot: StoreRead's `.items`. nil plus the reason when the panel is
--- not open. (GetPanelItems / GetSharedPanelItems answered this until 09-24.)
local function panelItems(id)
    local store, err = exports.whip_core:StoreRead({ kind = 'panel', id = id })
    if not store then return nil, err end
    return store.items
end

RegisterTestModule({
    order    = 19,
    category = 'Panels',

    setup = function(source, ctx)
        local p = exports.whip_core:GetPlayer(source)
        assertNotNil(p, 'setup: GetPlayer')
        ctx.charId = p.charId

        -- No UI up before the first OpenPanel: the client refuses to open over one, and answers by
        -- closing the new session a moment later, in the middle of whatever test is running.
        ClientCloseAllUI(source)
        fresh(source)
    end,

    teardown = function(ctx, source)
        if source then fresh(source) end
        -- The second player's side of the shared-close test, if it failed before closing it. The
        -- runner's leak check only looks at the tester, so nothing else would notice.
        if ctx.otherSource then
            pcall(exports.whip_core.ClosePanel, exports.whip_core, ctx.otherSource, ctx.otherPanel)
        end
    end,

    tests = {
        {
            -- Was "returns true" and nothing else, which OpenPanel answers for any config with an
            -- id. What a caller relies on is the session: listed as open, readable, seeded.
            name = 'OpenPanel opens a session seeded from its config',
            fn = function(source, ctx)
                fresh(source)
                local ok = exports.whip_core:OpenPanel(source, {
                    id    = '_test_panel_1',
                    label = 'Test Panel',
                    slots = 5,
                    maxWeight = 10.0,
                    items = {
                        [1] = { item = 'food', amount = 3 },
                    },
                })
                assertTrue(ok, 'OpenPanel returned true')

                local open = openPanels(source)
                assertEqual(#open, 1, 'one panel is open')
                assertEqual(open[1].id, '_test_panel_1', 'and it is this one')

                -- 09-24: the listing no longer carries the slot count; StoreRead of the panel does.
                local store, err = exports.whip_core:StoreRead({ kind = 'panel', id = '_test_panel_1' })
                assertOk(store, err, 'the open panel is readable by its address')
                assertEqual(store.slots, 5, 'with the slot count given')
                assertEqual(store.items[1] and store.items[1].amount, 3, 'seeded with config.items')
            end,
        },
        {
            -- 09-24: was "GetPanelItems returns initial items". GetPanelItems was removed; a panel is
            -- read like any store, by its address.
            name = 'StoreRead of a panel returns its initial items',
            fn = function(source, ctx)
                fresh(source)
                exports.whip_core:OpenPanel(source, {
                    id    = '_test_panel_items',
                    label = 'Items Test',
                    slots = 5,
                    items = {
                        [1] = { item = 'food', amount = 2 },
                        [3] = { item = 'drink', amount = 1 },
                    },
                })

                local items, err = panelItems('_test_panel_items')
                assertOk(items, err, 'StoreRead answered with the contents')
                assertNotNil(items[1], 'Slot 1 exists')
                assertEqual(items[1].item, 'food', 'Slot 1 is food')
                assertEqual(items[1].amount, 2, 'Slot 1 amount is 2')
                assertNil(items[2], 'Slot 2 is empty')
                assertNotNil(items[3], 'Slot 3 exists')
                assertEqual(items[3].item, 'drink', 'Slot 3 is drink')
            end,
        },
        {
            -- 09-24: was "UpdatePanelSlot modifies panel contents". UpdatePanelSlot was removed; a
            -- resource fills a panel slot with StoreGive on its address, which applies the panel's
            -- rules and answers the slot NUMBER it filled (or false, reason).
            name = 'StoreGive into a panel slot modifies panel contents',
            fn = function(source, ctx)
                fresh(source)
                exports.whip_core:OpenPanel(source, {
                    id    = '_test_panel_update',
                    label = 'Update Test',
                    slots = 5,
                    items = {
                        [1] = { item = 'food', amount = 1 },
                    },
                })

                -- Fill slot 2 with a new item
                local slot, err = exports.whip_core:StoreGive(
                    { kind = 'panel', id = '_test_panel_update', slot = 2 }, 'drink', 5)
                assertOk(slot, err, 'StoreGive into the panel')
                assertEqual(slot, 2, 'it answered the slot it filled')

                -- Verify
                local items = panelItems('_test_panel_update') or {}
                assertNotNil(items[2], 'Slot 2 now exists')
                assertEqual(items[2].item, 'drink', 'Slot 2 is drink')
                assertEqual(items[2].amount, 5, 'Slot 2 amount is 5')
                assertEqual(items[1] and items[1].item, 'food', 'slot 1 untouched')
            end,
        },
        {
            -- 09-24: was "UpdatePanelSlot with nil clears slot". Clearing a panel slot is StoreTake on
            -- its address now; with no amount it takes the whole stack and answers what it took.
            name = 'StoreTake clears a panel slot',
            fn = function(source, ctx)
                fresh(source)
                exports.whip_core:OpenPanel(source, {
                    id    = '_test_panel_clear',
                    label = 'Clear Test',
                    slots = 5,
                    items = {
                        [1] = { item = 'food', amount = 3 },
                        [2] = { item = 'drink', amount = 1 },
                    },
                })

                -- Clear slot 1
                local one = { kind = 'panel', id = '_test_panel_clear', slot = 1 }
                local taken, err = exports.whip_core:StoreTake(one)
                assertOk(taken, err, 'StoreTake answered')
                assertEqual(taken.item, 'food', 'it took what was in the slot')
                assertEqual(taken.amount, 3, 'the whole stack, as no amount was given')

                local items = panelItems('_test_panel_clear') or {}
                assertNil(items[1], 'Slot 1 cleared')
                assertNotNil(items[2], 'Slot 2 still exists')

                local again, why = exports.whip_core:StoreTake(one)
                assertFalse(again, 'clearing an empty slot is refused')
                assertEqual(why, 'Empty slot', 'and says the slot is empty')
            end,
        },
        {
            -- The old test registered an EMPTY callback and asserted only that the setter
            -- returned true — it never observed whether the callback fired, when, or with what.
            -- That was the module's only test named after onClose, and onClose is the contract
            -- that changed: it now fires ONLY for the last viewer out, and is handed the shared
            -- instance's final contents rather than that viewer's private copy.
            --
            -- 09-24: SetPanelOnClose was removed. onClose is part of the OpenPanel config, belongs to
            -- the panel, and is handed ONE table: { panel, source, items }.
            name = 'onClose fires on the last close, with the shared contents',
            fn = function(source, ctx)
                fresh(source)
                local fired, got = 0, nil

                local ok = exports.whip_core:OpenPanel(source, {
                    id    = '_test_panel_onclose',
                    label = 'OnClose Test',
                    slots = 3,
                    items = { [1] = { item = 'food', amount = 2 } },
                    onClose = function(c)
                        fired = fired + 1
                        got = c
                    end,
                })
                assertTrue(ok, 'OpenPanel with an onClose returned true')

                assertEqual(fired, 0, 'onClose has not fired merely by the panel opening')

                exports.whip_core:ClosePanel(source)

                -- One viewer, so this close IS the last one.
                assertEqual(fired, 1, 'onClose fired exactly once, on the last close')
                assertNotNil(got, 'it was handed a ctx')
                assertEqual(got.panel, '_test_panel_onclose', 'ctx.panel names the panel')
                assertEqual(got.source, source, 'ctx.source is the viewer who left last')
                assertNotNil(got.items, 'it was handed the contents')
                assertEqual(got.items and got.items[1] and got.items[1].item, 'food',
                    'and they are the instance contents, not an empty private copy')

                local gone, why = exports.whip_core:StoreRead({ kind = 'panel', id = '_test_panel_onclose' })
                assertFalse(gone, 'the instance was torn down with it')
                assertEqual(why, 'that panel is not open', 'and StoreRead says so')
            end,
        },
        {
            -- THE HALF THAT NEEDS TWO PEOPLE, and the reason the contract changed at all: with a
            -- crew around a bench, firing onClose when the FIRST person walks away would hand the
            -- owning resource its contents while the others are still working.
            name = 'onClose does NOT fire while another viewer remains',
            fn = function(source, ctx)
                fresh(source)
                local other = nil
                for src in pairs(exports.whip_core:GetPlayers() or {}) do
                    local id = tonumber(src)
                    if id and id ~= source then other = id break end
                end
                if not other then skip('needs a second player online') end

                local ID = '_test_panel_shared_close'
                local fired, got = 0, nil

                -- 09-24: the hook is in the config (SetPanelOnClose was removed), so it is the PANEL's.
                exports.whip_core:OpenPanel(source, { id = ID, slots = 4,
                    items = { [1] = { item = 'food', amount = 2 } },
                    onClose = function(c)
                        fired = fired + 1
                        got = c
                    end,
                })

                -- Joins the SAME instance. Their items are ignored — it already exists. Recorded
                -- first, so teardown closes their side even if an assertion below fails.
                ctx.otherSource, ctx.otherPanel = other, ID
                exports.whip_core:OpenPanel(other, { id = ID, slots = 4 })

                exports.whip_core:ClosePanel(source)
                assertEqual(fired, 0, 'onClose must not fire while another viewer is inside')
                assertType(exports.whip_core:StoreRead({ kind = 'panel', id = ID }), 'table',
                    'and the instance survives the first close')

                exports.whip_core:ClosePanel(other, ID)
                ctx.otherSource, ctx.otherPanel = nil, nil

                -- 09-24: WHOEVER LEAVES LAST gets it, not only the player who set it. The hooks were
                -- per viewer, and this order (the setter leaves first) meant onClose never ran at all.
                assertEqual(fired, 1, 'onClose fired once, when the last viewer left')
                assertEqual(got and got.source, other, 'handed the player who left last, not the one who set it')
                assertEqual(got and got.panel, ID, 'ctx.panel names the panel')
                assertEqual(got and got.items and got.items[1] and got.items[1].item, 'food',
                    'and ctx.items holds the final contents')
                assertFalse(exports.whip_core:StoreRead({ kind = 'panel', id = ID }),
                    'the last viewer out tears it down')
            end,
        },
        {
            -- ONE test for the three "nothing is open" answers. They were three tests, two of them
            -- copies of 13_external's, and one more — "SetPanelOnMove registers callback" — that
            -- asserted only the setter's return value; 21_panel_contract tests what onValidate DOES.
            --
            -- 09-24: the SetPanelOnMove / SetPanelOnClose "no session to attach to" assertions were
            -- removed with those calls; a panel's hooks come in its OpenPanel config.
            name = 'With nothing open: ClosePanel and StoreRead both say so',
            fn = function(source, ctx)
                fresh(source)
                assertEqual(#openPanels(source), 0, 'nothing is open')

                local closed, closeWhy = exports.whip_core:ClosePanel(source)
                assertFalse(closed, 'ClosePanel returned false when no session')
                assertEqual(closeWhy, 'No such panel open', 'and said why')

                -- 09-24: GetPanelItems answered nil here; StoreRead answers false with the reason.
                local store, err = exports.whip_core:StoreRead({ kind = 'panel', id = '_test_panel_1' })
                assertFalse(store, 'StoreRead refuses a panel nobody has open')
                assertEqual(err, 'that panel is not open', 'and says so')
            end,
        },
        {
            -- ####################################################################
            -- PANELS STACK. THEY USED TO REPLACE.
            --
            -- This test asserted the old model: opening B evicted A, A's onClose fired, and
            -- "the player's panel" named exactly one thing. On 20 Sep 2026 the owner asked for
            -- the opposite — several panels open at once down the right-hand column — and
            -- `_panelSessions[source]` became a SET.
            --
            -- Every assertion below is the mirror of one that used to be here. The test was not
            -- wrong when it was written; it is describing a product decision that was reversed,
            -- which is the one kind of stale test that keeps passing its own logic while
            -- documenting the wrong framework.
            -- ####################################################################
            name = 'OpenPanel STACKS instead of replacing, and each panel is addressed by id',
            fn = function(source, ctx)
                fresh(source)
                local aClosed = false

                exports.whip_core:OpenPanel(source, {
                    id    = '_test_panel_A',
                    label = 'Panel A',
                    slots = 3,
                    items = {
                        [1] = { item = 'food', amount = 10 },
                    },
                    -- 09-24: A's hook is part of A's config (SetPanelOnClose, which took the panel
                    -- id as its third argument, was removed), so it cannot land on the wrong panel.
                    onClose = function() aClosed = true end,
                })

                exports.whip_core:OpenPanel(source, {
                    id    = '_test_panel_B',
                    label = 'Panel B',
                    slots = 5,
                    items = {
                        [1] = { item = 'drink', amount = 7 },
                    },
                })

                -- A SURVIVES. Both halves of the old behaviour are gone, so both are pinned.
                assertFalse(aClosed, 'opening a second panel does NOT close the first')
                assertType(exports.whip_core:StoreRead({ kind = 'panel', id = '_test_panel_A' }), 'table',
                    "panel A's instance is still alive, not torn down")

                -- "The player's panel" has stopped being a well-formed question, and the
                -- ambiguous answer is a refusal rather than an arbitrary pick — returning one
                -- of two via pairs() is how a resource writes a wallet's contents into a duffle.
                --
                -- 09-24: GetPanelItems(source), the read by player alone, was removed. What still
                -- applies is that a panel address without its id is refused, now always rather
                -- than only while two are open.
                local none, noneWhy = exports.whip_core:StoreRead({ kind = 'panel', owner = source })
                assertFalse(none, 'a panel read without an id is refused, not guessed at')
                assertEqual(noneWhy, 'panel address needs the panel id in `id`', 'and says it needs the id')

                local a = panelItems('_test_panel_A')
                assertNotNil(a and a[1], 'panel A is readable by id')
                assertEqual(a[1].item, 'food', 'and still holds its own items')

                local b = panelItems('_test_panel_B')
                assertNotNil(b and b[1], 'panel B is readable by id')
                assertEqual(b[1].item, 'drink', 'and holds its own')
                assertEqual(b[1].amount, 7, 'with its own amount')

                -- The ids are DISCOVERABLE. Without this a caller whose panel was opened by a
                -- context action would have to rebuild whip's private id format — which is
                -- exactly what 30_panelitem did, and exactly what broke when the format changed.
                -- (09-24: GetOpenStores lists them now; GetOpenPanels was removed.)
                local open = openPanels(source)
                assertEqual(#open, 2, 'both panels are listed as open')
                assertEqual(open[1].id, '_test_panel_A', 'sorted by id, so the listing is reproducible')
                assertEqual(open[2].id, '_test_panel_B', 'and B follows A')
                assertEqual(open[1].label, 'Panel A', 'the listing carries the label a caller would show')

                -- RE-OPENING ONE ALREADY OPEN IS A NO-OP, and this too is the reverse of what
                -- the old test pinned. It used to close and re-seed from config.items; that
                -- tore down a live screen and, with two wallets open, silently reordered the
                -- column. A panel you already have open does not need opening.
                exports.whip_core:OpenPanel(source, {
                    id = '_test_panel_B', label = 'Panel B', slots = 5,
                    items = { [1] = { item = 'food', amount = 1 } },
                })
                local reopened = panelItems('_test_panel_B') or {}
                assertEqual(reopened[1] and reopened[1].item, 'drink',
                    're-opening a panel already open keeps its LIVE contents, not config.items')
                assertEqual(#openPanels(source), 2,
                    'and does not add a second copy of it')

                -- Omitting the id on the way out means EVERY panel, which is how a caller
                -- written before stacking still cleans up after itself correctly.
                exports.whip_core:ClosePanel(source)
                assertTrue(aClosed, "the sweep closes A too, so A's onClose finally fires")
                assertEqual(#openPanels(source), 0, 'nothing is left open')
            end,
        },
    }
})
