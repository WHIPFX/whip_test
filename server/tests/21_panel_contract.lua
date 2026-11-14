-- ============================================
-- Panel move contract — what a panel's onValidate hook is asked, and what its answer does
--
-- WHY THIS MODULE EXISTS
--
-- A panel's onValidate(ctx) hook, passed in its OpenPanel config, may return:
--     false[, why]    reject the move
--     anything else   allow the standard move
-- and a hook that ERRORS rejects it too.
--
-- IT WAS TRI-STATE UNTIL 09-24. The hook was SetPanelOnMove's callback, set per viewer after
-- opening, and it had a third answer, 'handled': "the callback performed the move ITSELF;
-- whip_core must not touch it". That was the entire move implementation for whip_gunny's
-- magazine loading and whip_phone's SIM handling, which is why this module was written. The
-- 09-24 rework removed SetPanelOnMove and 'handled': the hooks belong to the panel, and a hook
-- that acts on a move does it in onChange, after the move has landed.
--
-- The 19_panels module used to assert only that SetPanelOnMove RETURNED TRUE — i.e. that the
-- setter worked. Nothing exercised the contract itself, which made the panel handler the most
-- dangerous 259 lines in the framework to refactor blind. This is the net.
--
-- UPDATE: those 259 lines are gone. The panel is now an ordinary store kind, and the contract
-- is its beforeMove hook, reached through whip_core:server:storeMove like every other move.
-- panelMove below still TAKES the old words — direction 'toPanel', panelSlot, invContainer,
-- invSlot — to describe the drag a test makes. The hook is handed the new ctx (09-24), and the
-- first test pins the mapping: 'toPanel' → direction 'in', panelSlot → slot, invContainer →
-- other.sub, invSlot → otherSlot.
-- ============================================

local PANEL_ITEM = '_test_panel_move'

--- Fire a panel move the way the client now does: as two store addresses.
---
--- The three directions were three code paths. They are three store pairings.
local function panelMove(source, moveData)
    local function panelAddr(slot)
        return { kind = 'panel', id = moveData.panelId, slot = slot }
    end
    local function invAddr(slot)
        return { kind = moveData.invContainer, slot = slot }
    end

    local from, to
    if moveData.direction == 'toPanel' then
        from, to = invAddr(moveData.invSlot), panelAddr(moveData.panelSlot)
    elseif moveData.direction == 'fromPanel' then
        from, to = panelAddr(moveData.panelSlot), invAddr(moveData.invSlot)
    else
        from, to = panelAddr(moveData.panelSlot), panelAddr(moveData.toPanelSlot)
    end

    return ClientExecWait(source, 'whip_core:server:storeMove', 3000,
        from, to, moveData.amount or 0, 'move', 0)
end

--- What the panel holds, keyed by slot: StoreRead's `.items`, or `{}` when it is not open — the
--- same answer `GetPanelItems(source) or {}` gave before GetPanelItems was removed (09-24).
local function panelContents(panelId)
    local store = exports.whip_core:StoreRead({ kind = 'panel', id = panelId })
    return store and store.items or {}
end

--- Start a test from nothing: no panel open, the fixture item seeded, the panel opened.
---
--- CLOSED AT THE START, NOT THE END. Each test used to close its panel on its last line, so a
--- failed assertion left it open — and re-opening a panel that is already open is a no-op
--- (panels.lua), so the NEXT test inherited the old contents and failed too. One failure became
--- a cascade blamed on innocent tests.
---
--- `extra` is merged into the OpenPanel config, and it is how a test gives the panel its
--- onValidate (09-24: the hooks are part of the config; SetPanelOnMove was removed). Closing
--- first matters for that too: hooks are set by the first opener that brings any, so a panel
--- left open would keep the previous test's hook.
local function freshPanel(source, ctx, amount, extra)
    pcall(exports.whip_core.ClosePanel, exports.whip_core, source)
    RemoveAllOf(source, PANEL_ITEM)
    SeedSlot(source, 'player', 1, PANEL_ITEM, amount)

    local config = { id = ctx.panelId, label = 'Contract', slots = 4 }
    for k, v in pairs(extra or {}) do config[k] = v end
    assertTrue(exports.whip_core:OpenPanel(source, config), 'panel opened')
end

RegisterTestModule({
    order    = 21,
    category = 'Panel Contract',

    setup = function(source, ctx)
        local p = exports.whip_core:GetPlayer(source)
        assertNotNil(p, 'setup: GetPlayer')
        ctx.charId  = p.charId
        ctx.panelId = '_test_contract_panel'

        exports.whip_core:RegisterItem(PANEL_ITEM, {
            name = 'Panel Move Fixture', desc = 'panel contract fixture',
            weight = 0.1, type = 'misc', stack = true, maxStack = 20,
        })

        -- NO UI UP BEFORE THE FIRST OpenPanel. These tests yield inside ClientExecWait, and a
        -- client that refused to open the panel over a UI already on screen answers by closing
        -- the session — which would land in the middle of the move under test.
        ClientCloseAllUI(source)
    end,

    teardown = function(ctx, source)
        if source then
            pcall(exports.whip_core.ClosePanel, exports.whip_core, source)
            RemoveAllOf(source, PANEL_ITEM)
        end
    end,

    tests = {
        {
            -- 09-24: was "onMove returning false ...". The hook is onValidate in the OpenPanel
            -- config now (SetPanelOnMove was removed), and it is handed one ctx.
            name = "onValidate returning false rejects the move and changes nothing",
            fn = function(source, ctx)
                -- CAPTURES THE PAYLOAD, rather than only noting that something fired.
                --
                -- This module's stated purpose was that whip_gunny and whip_phone see no change in
                -- the vocabulary they receive — and no assertion here ever looked at it. The
                -- vocabulary is BUILT IN A DIFFERENT FILE: Stores.panelHookCtx turns the move's ctx
                -- into the hook's, with `other` as an address. A translation error anywhere in that
                -- would have left every other test in this module green.
                --
                -- 09-24: the words changed, so the satellites did see a change; this pins the new
                -- ones, and each label below names the old field it replaced.
                local sawCallback, saw = false, nil
                freshPanel(source, ctx, 5, {
                    onValidate = function(c)
                        sawCallback = true
                        saw = c
                        return false   -- reject
                    end,
                })

                local before = exports.whip_core:GetItemCount(source, PANEL_ITEM)
                panelMove(source, {
                    panelId = ctx.panelId, direction = 'toPanel',
                    panelSlot = 1, invContainer = 'player', invSlot = 1,
                    item = PANEL_ITEM, amount = 2,
                })

                assertTrue(sawCallback, 'onValidate ran')

                assertNotNil(saw, 'the hook was handed a ctx')
                assertEqual(saw.direction, 'in', "direction (was 'toPanel')")
                assertEqual(saw.slot, 1, 'slot, the panel slot (was panelSlot)')
                assertEqual(saw.other and saw.other.kind, 'player', 'other is the far end, as an address')
                assertEqual(saw.other and saw.other.sub, 'player', 'other.sub names the pocket (was invContainer)')
                assertEqual(saw.otherSlot, 1, 'otherSlot, the pocket slot (was invSlot)')
                assertEqual(saw.item, PANEL_ITEM, 'item')
                assertEqual(saw.amount, 2, 'amount')
                assertEqual(saw.panel, ctx.panelId, 'panel names the panel the hook belongs to')
                assertEqual(saw.source, source, 'source is the player moving')
                -- This was `toPanelSlot is nil`. A within-panel move carries that slot as otherSlot
                -- now, so the field that must be absent here is swap.
                assertNil(saw.swap, 'swap is only set for the returning half of a swap')
                assertEqual(exports.whip_core:GetItemCount(source, PANEL_ITEM), before,
                    'a rejected move left the player inventory untouched')

                assertNil(panelContents(ctx.panelId)[1], 'nothing was placed in the panel')
                -- 09-24: 'Not allowed', not 'Move rejected': a bare false gets the panel kind's own
                -- default reason (stores.lua, the panel kind's beforeMove).
                assertLastReject('whip_core:server:storeMove', 'Not allowed',
                    "refused by the hook's veto, not by something in front of it")
            end,
        },
        -- "onMove returning 'handled' ..." was removed 09-24 with SetPanelOnMove; 'handled' no longer exists.
        {
            -- 09-24: was "onMove allowing ...". onValidate in the OpenPanel config now.
            name = 'onValidate allowing the move performs it exactly once',
            fn = function(source, ctx)
                freshPanel(source, ctx, 5, {
                    onValidate = function(c)
                        return true   -- allow
                    end,
                })

                panelMove(source, {
                    panelId = ctx.panelId, direction = 'toPanel',
                    panelSlot = 1, invContainer = 'player', invSlot = 1,
                    item = PANEL_ITEM, amount = 2,
                })

                local panelItems = panelContents(ctx.panelId)
                assertNotNil(panelItems[1], 'item arrived in the panel')
                assertEqual(panelItems[1].item, PANEL_ITEM, 'correct item')
                assertEqual(panelItems[1].amount, 2, 'exactly the requested amount, not double')

                -- Conservation: 5 total, 2 now in the panel, so 3 left on the player.
                assertEqual(exports.whip_core:GetItemCount(source, PANEL_ITEM), 3,
                    'the moved amount left the player inventory exactly once')
            end,
        },
        {
            name = 'A callback that errors REFUSES the move, and conserves the item',
            fn = function(source, ctx)
                -- whip_core FAILS CLOSED when a callback throws. onValidate is a VETO — it is how
                -- a satellite decides what may enter its panel — and a hook that errored has
                -- not approved anything, it has failed to answer. Treating that as approval
                -- turns a satellite bug into an exploit nobody notices, because the move
                -- simply works and no rule looks broken.
                --
                -- Conservation is asserted too, but note it cannot pin the policy on its own:
                -- the total is 4 whether the move is allowed or refused. The placement
                -- assertions below are what actually hold the contract.
                --
                -- This DELIBERATELY throws. FiveM prints the stack trace in whip_test's
                -- context (the callback is a cross-resource reference), and whip_core logs
                -- that a callback errored. Both lines in the server console are EXPECTED
                -- output from this test, not a fault.
                -- (09-24: the hook is onValidate in the OpenPanel config; SetPanelOnMove was removed.)
                freshPanel(source, ctx, 4, {
                    onValidate = function(c)
                        error('[EXPECTED] whip_test 21_panel_contract is deliberately erroring here')
                    end,
                })

                panelMove(source, {
                    panelId = ctx.panelId, direction = 'toPanel',
                    panelSlot = 1, invContainer = 'player', invSlot = 1,
                    item = PANEL_ITEM, amount = 1,
                })

                local panelItems = panelContents(ctx.panelId)
                local inPanel    = panelItems[1] and panelItems[1].amount or 0
                local onPlayer   = exports.whip_core:GetItemCount(source, PANEL_ITEM) or 0
                assertEqual(inPanel + onPlayer, 4, 'total conserved despite the callback error')
                assertEqual(inPanel, 0,
                    'a hook that errored has not approved anything — the move must be refused')
                assertEqual(onPlayer, 4, 'the item stayed exactly where it was')

                -- PROVES THE HOOK WAS REACHED. The counts above hold for a move refused for ANY
                -- reason — a bad address, the rate limiter — so this pins that it was the errored
                -- hook that refused it (stores.lua, beforeMove: fail closed).
                assertLastReject('whip_core:server:storeMove', 'The panel could not verify this move',
                    'refused because the hook errored')
            end,
        },
        {
            name = 'A read-only panel refuses cross-boundary moves',
            fn = function(source, ctx)
                freshPanel(source, ctx, 3, { label = 'Contract RO', readOnly = true })

                local before = exports.whip_core:GetItemCount(source, PANEL_ITEM)
                panelMove(source, {
                    panelId = ctx.panelId, direction = 'toPanel',
                    panelSlot = 1, invContainer = 'player', invSlot = 1,
                    item = PANEL_ITEM, amount = 1,
                })

                assertEqual(exports.whip_core:GetItemCount(source, PANEL_ITEM), before,
                    'read-only panel took nothing from the player')
                assertNil(panelContents(ctx.panelId)[1],
                    'and nothing landed in the panel')

                -- PINS THE LAYER. The refusal happens at the ADDRESS — fromWire will not hand out
                -- a read-only panel address at all — so it never reaches the panel kind's own
                -- readOnly branch, and without a reason check this test passes on any refusal
                -- whatsoever. Note the consequence: because the address is refused, a WITHIN-panel
                -- rearrangement is refused too, even though the kind hook would have allowed it.
                local why = exports.whip_core:__TestLastReject('whip_core:server:storeMove')
                assertNotNil(why, 'the move was recorded as rejected')
                assertTrue(tostring(why):find('read-only', 1, true) ~= nil,
                    ('refused as read-only, not for some other reason (got "%s")'):format(tostring(why)))
            end,
        },
        {
            -- NO MORE THAN APPROVED, WHATEVER AMOUNT IS SENT (audit 7, INV-5). A stack that grows
            -- while onValidate waits must move only the amount the hook was asked about. Audit 6 held
            -- that for amount 0 alone; an amount of the stack or more (999999, from a modified client)
            -- still moved the grown live stack — 106 rounds into a chamber approved for 6.
            --
            -- THE STACK GROWS FROM INSIDE THE HOOK. The first version added the 10 from the test a fixed
            -- 250 ms after asking the client to move — but the move reaches the server only after a round
            -- trip through the client, so the 10 could land BEFORE the move began: the hook was then
            -- asked about 16, and moving 16 was right (first run, 09-26: "expected 6, got 16"). Growing
            -- it inside onValidate is exactly the window the fix is about, every time, and `asked` pins
            -- what the hook approved.
            name = 'A stack that grows while onValidate waits moves only what was approved, even for amount 999999',
            fn = function(source, ctx)
                local asked, grew, growErr
                freshPanel(source, ctx, 6, {
                    onValidate = function(c)
                        if asked == nil and c.direction == 'in' then
                            asked = c.amount
                            -- A second move merging into the source while this hook has the move waiting.
                            grew, growErr = exports.whip_core:StoreGive(PocketAddr(source, 'player', 1), PANEL_ITEM, 10)
                        end
                        return true
                    end,
                })
                panelMove(source, {
                    panelId = ctx.panelId, direction = 'toPanel',
                    panelSlot = 1, invContainer = 'player', invSlot = 1,
                    item = PANEL_ITEM, amount = 999999,
                })

                local inPanel = panelContents(ctx.panelId)[1]
                local left = exports.whip_core:GetItemAt(PocketAddr(source, 'player', 1))
                pcall(exports.whip_core.ClosePanel, exports.whip_core, source)

                assertEqual(asked, 6, 'the hook was asked about the 6 in the pocket')
                assertOk(grew, growErr, 'the stack grew by 10 while the hook had the move waiting')
                assertLastReject('whip_core:server:storeMove', nil, 'the move was accepted')
                assertEqual(inPanel and inPanel.amount, 6, 'the panel got the 6 that were approved')
                assertEqual(left and left.amount, 10, 'the 10 that arrived meanwhile stayed in the pocket')
            end,
        },
        {
            -- A PANEL WITH NO onClose GIVES BACK WHAT PLAYERS PUT IN (Josh, 27 Sep 2026). What was left
            -- used to be gone, logged as lost (audit 6, INV-4). Each player now gets back what THEY put
            -- in and did not take out; what the resource stocked it with (`items`) goes with the panel.
            name = 'A panel with no onClose gives back what the player put in, and not what it was stocked with',
            fn = function(source, ctx)
                local foodBefore = exports.whip_core:GetItemCount(source, 'food')
                freshPanel(source, ctx, 5, { items = { [2] = { item = 'food', amount = 2 } } })
                panelMove(source, {
                    panelId = ctx.panelId, direction = 'toPanel',
                    panelSlot = 1, invContainer = 'player', invSlot = 1,
                    item = PANEL_ITEM, amount = 3,
                })
                local inPanel = panelContents(ctx.panelId)[1]
                local stockSeen = panelContents(ctx.panelId)[2]
                exports.whip_core:ClosePanel(source)

                assertEqual(inPanel and inPanel.amount, 3, 'the 3 went into the panel')
                assertEqual(stockSeen and stockSeen.item, 'food', 'beside the 2 food it was stocked with')
                assertEqual(exports.whip_core:GetItemCount(source, PANEL_ITEM), 5,
                    'closing it gave the 3 back: all 5 are the player\'s again')
                assertEqual(exports.whip_core:GetItemCount(source, 'food'), foodBefore,
                    'and the stock stayed the panel\'s — nothing free')
            end,
        },
        {
            -- A DESTROY TAKES ONLY WHAT WAS APPROVED (audit 7, INV-4). commitDestroy had none of
            -- commitMove's re-reads: whatever sat in the slot after a hook that waited was destroyed,
            -- all of it. Here the stack grows from 2 to 6 while onValidate has the destroy waiting —
            -- the 2 that were asked about go, the 4 that arrived stay.
            name = 'A destroy takes only what onValidate approved, not what arrived while it waited',
            fn = function(source, ctx)
                local grew, growErr
                freshPanel(source, ctx, 1, {
                    onValidate = function(c)
                        if c.destroyed and grew == nil then
                            grew, growErr = exports.whip_core:StoreGive(
                                { kind = 'panel', id = ctx.panelId, slot = 1 }, PANEL_ITEM, 4)
                        end
                        return true
                    end,
                })
                assertOk(exports.whip_core:StoreGive({ kind = 'panel', id = ctx.panelId, slot = 1 }, PANEL_ITEM, 2), nil,
                    '2 in the panel to destroy')
                ClientExecWait(source, 'whip_core:server:destroyItem', 3000,
                    { kind = 'panel', id = ctx.panelId, slot = 1 }, 0)
                local left = panelContents(ctx.panelId)[1]
                exports.whip_core:ClosePanel(source)

                assertOk(grew, growErr, 'the stack grew by 4 while the hook had the destroy waiting')
                assertLastReject('whip_core:server:destroyItem', nil, 'the destroy was accepted')
                assertEqual(left and left.amount, 4, 'the 2 that were approved went; the 4 that arrived stayed')
            end,
        },
    },
})
