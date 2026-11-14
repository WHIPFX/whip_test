-- ============================================
-- UI from the server — section 6 of the API review (24 Sep 2026)
--
--   UI-1  NotifyPlayer, and a SecureEvent handler's `return false, 'why'` being a refusal: the
--         player is told why and the Event Monitor records it.
--   UI-2  the server Progress(source, opts) — a bar the server shows and times itself — and the
--         declared timed use: RegisterUseHandler(item, { duration, ..., onComplete }).
--
-- Every bar here is REAL: it is drawn on the tester's screen and the tester's client answers it.
-- Durations are short on purpose, and nothing here needs a key pressed.
-- ============================================

local USE_EVENT = 'whip_core:server:useItem'
local ITEM      = '_test_timed_use'

--- Use the item in a pocket slot the way the hotbar does, and pin how the event came out.
--- (useItem is rate limited to one per 500ms, so wait that out first — see 17_item_use.)
---
--- `refusedWith`: the reason the use must be refused with, or nil for a use that goes through. A
--- declared use that does not happen answers `false, 'why'` (audit 3, ARC-4), which the event
--- records as a refusal with that why — the player is shown it. It used to come back as a bare
--- false, a use like any other, which is what this helper once pinned for every case.
local function useSlot(source, slot, refusedWith)
    Wait(600)
    assertTrue(ClientExecWait(source, USE_EVENT, 3000, 'player', slot), 'the server answered useItem')
    if refusedWith then
        assertLastReject(USE_EVENT, refusedWith, 'the use was refused, with its reason')
    else
        assertLastReject(USE_EVENT, nil, 'the use was not refused')
    end
end

RegisterTestModule({
    order    = 48,
    category = 'UI From The Server',

    setup = function(source, ctx)
        exports.whip_core:RegisterItem(ITEM, {
            name     = 'Test Timed Use',
            weight   = 0.1,
            type     = 'misc',
            usable   = true,
            stack    = true,
            maxStack = 10,
        })

        -- Handlers that answer the three ways a handler can.
        exports.whip_core:SecureEvent('_test_ui_refuse', { rateLimit = 100 }, function()
            return false, '[TEST] refused on purpose'
        end)
        exports.whip_core:SecureEvent('_test_ui_refuse_bare', { rateLimit = 100 }, function()
            return false
        end)
        exports.whip_core:SecureEvent('_test_ui_refuse_empty', { rateLimit = 100 }, function()
            return false, ''
        end)
        exports.whip_core:SecureEvent('_test_ui_ok', { rateLimit = 100 }, function()
            return
        end)

        -- A bar will not open over an open inventory's screen of another resource, and closes
        -- whip's own — start from nothing open so no test inherits a panel.
        ClientCloseAllUI(source)
    end,

    teardown = function(ctx, source)
        RemoveAllOf(source, ITEM)
    end,

    tests = {
        -- ---- UI-1 ----------------------------------------------------------------------
        {
            name = 'NotifyPlayer: sent to a player on the server; refused for no text or nobody',
            fn = function(source)
                assertTrue(exports.whip_core:NotifyPlayer(source, '[TEST] NotifyPlayer', 'info', 800),
                    'sent to the tester')
                assertFalse(exports.whip_core:NotifyPlayer(source, ''), 'no text is refused')
                assertFalse(exports.whip_core:NotifyPlayer(65000, '[TEST] nobody'),
                    'a player who is not on the server is refused')
            end,
        },
        {
            name = "A SecureEvent handler's false, 'why' is recorded as a rejection with that text",
            fn = function(source)
                -- The player also sees the text as an error toast; that half lives in the NUI.
                assertTrue(ClientExecWait(source, '_test_ui_refuse', 3000), 'the server answered')
                assertLastReject('_test_ui_refuse', '[TEST] refused on purpose',
                    "recorded with the handler's own text")
            end,
        },
        {
            name = 'A bare false (or an empty message) is a rejection without text; nothing returned is ok',
            fn = function(source)
                assertTrue(ClientExecWait(source, '_test_ui_refuse_bare', 3000), 'answered: bare false')
                assertLastReject('_test_ui_refuse_bare', 'refused by the handler', 'a bare false is refused')

                assertTrue(ClientExecWait(source, '_test_ui_refuse_empty', 3000), "answered: false, ''")
                assertLastReject('_test_ui_refuse_empty', 'refused by the handler',
                    'an empty message is no message, not a blank reason')

                assertTrue(ClientExecWait(source, '_test_ui_ok', 3000), 'answered: nothing returned')
                assertLastReject('_test_ui_ok', nil, 'a handler that returns nothing is ok')
            end,
        },

        -- ---- UI-2: the server Progress --------------------------------------------------
        {
            name = 'Server Progress: a bar that runs its length answers true',
            fn = function(source)
                local t0 = GetGameTimer()
                local done, why = exports.whip_core:Progress(source, { label = '[TEST] server bar', duration = 400 })
                assertTrue(done, ('the bar completed (why: %s)'):format(tostring(why)))
                assertGte(GetGameTimer() - t0, 360, 'and the server waited for it')
            end,
        },
        {
            name = 'Server Progress refuses a call it cannot run',
            fn = function(source)
                local ok, why = exports.whip_core:Progress(source, false)
                assertFalse(ok, 'no options table')
                assertEqual(why, 'Progress needs an options table', 'with the reason')

                ok, why = exports.whip_core:Progress(source, { label = '[TEST] no duration' })
                assertFalse(ok, 'no duration')
                assertEqual(why, 'duration must be a positive number of milliseconds', 'with the reason')

                ok, why = exports.whip_core:Progress(65000, { duration = 400 })
                assertFalse(ok, 'a player who is not loaded')
                assertEqual(why, 'Player not loaded', 'with the reason (one spelling across whip since 09-25)')
            end,
        },
        {
            -- A FLOOR THAT DOES NOT FIT IS REFUSED, NOT LOWERED (audit 7, SEC-3). It was held two
            -- seconds under the timeout, so a 2 s check's floor became 0 (the instant "passed" the
            -- floor exists to stop), and a fractional number threw in the warning's print. All three
            -- calls answer before anything reaches the player's screen.
            name = 'Server SkillCheck refuses a minMs that does not fit its timeout, and a bad difficulty',
            fn = function(source)
                local ok, why = exports.whip_core:SkillCheck(source, 'easy', { timeoutMs = 2000, minMs = 2000 })
                assertFalse(ok, 'a minMs as long as the timeout')
                assertTrue(tostring(why):find('minMs', 1, true) ~= nil,
                    ('with a reason naming minMs (got "%s")'):format(tostring(why)))

                ok, why = exports.whip_core:SkillCheck(source, 'easy', { timeoutMs = 2100.5, minMs = 2500.5 })
                assertFalse(ok, 'fractional numbers are refused the same way')
                assertTrue(tostring(why):find('minMs', 1, true) ~= nil,
                    ('with the same reason, not an error (got "%s")'):format(tostring(why)))

                -- The ring (27 Sep 2026): the difficulty is read by the same code the client draws from
                -- (shared/skillcheck.lua), so one it cannot draw is refused here, with the reason — the
                -- caller must not hear 'failed' for it (audit 6, CLI-12; audit 7, CLI-13).
                ok, why = exports.whip_core:SkillCheck(source, 'impossible')
                assertFalse(ok, 'a difficulty that is not in the config')
                assertTrue(tostring(why):find('no skill check difficulty', 1, true) ~= nil,
                    ('with a reason naming it (got "%s")'):format(tostring(why)))

                -- The needle's checks list is refused by name, not quietly drawn as 'medium'.
                ok, why = exports.whip_core:SkillCheck(source, { { areaSize = 0.2 } })
                assertFalse(ok, 'the old list of checks')
                assertTrue(tostring(why):find('takes a difficulty', 1, true) ~= nil,
                    ('with a reason saying what it takes now (got "%s")'):format(tostring(why)))

                -- And its one-table form (audit 7, DX-4): { checks, speed } was quietly one easy zone.
                ok, why = exports.whip_core:SkillCheck(source, { checks = { { areaSize = 0.2 } }, speed = 900 })
                assertFalse(ok, 'the old { checks, speed } form')
                assertTrue(tostring(why):find('takes a difficulty', 1, true) ~= nil,
                    ('refused with the same reason (got "%s")'):format(tostring(why)))

                -- And the old third argument, a speed, where opts now goes.
                ok, why = exports.whip_core:SkillCheck(source, 'easy', 900)
                assertFalse(ok, 'a number where opts goes')
                assertEqual(why, 'opts must be a table', 'with the reason')
            end,
        },
        {
            name = 'Server Progress: a second bar while one is up answers busy; the first still completes',
            fn = function(source)
                local first = nil
                CreateThread(function()
                    first = table.pack(exports.whip_core:Progress(source, { label = '[TEST] first', duration = 1200 }))
                end)
                Wait(300)

                local ok, why = exports.whip_core:Progress(source, { label = '[TEST] second', duration = 400 })
                assertFalse(ok, 'the second bar did not run')
                assertEqual(why, 'busy', 'it answered busy, not cancelled')

                assertTrue(waitFor(function() return first ~= nil end, 4000), 'the first bar answered')
                assertTrue(first[1], ('the first bar completed (why: %s)'):format(tostring(first[2])))
            end,
        },
        {
            name = 'Server Progress: a bar cancelled on the client answers cancelled',
            fn = function(source)
                local res = nil
                CreateThread(function()
                    res = table.pack(exports.whip_core:Progress(source, { label = '[TEST] cancel me', duration = 3000 }))
                end)
                Wait(400)

                -- The bar belongs to whip_test (the resource that asked), so whip_test's client may
                -- cancel it.
                assertTrue(ClientCancelProgress(source), 'the client acknowledged the cancel')
                assertTrue(waitFor(function() return res ~= nil end, 3000), 'the server bar answered')
                assertFalse(res[1], 'not completed')
                assertEqual(res[2], 'cancelled', 'answered cancelled')
            end,
        },
        {
            name = 'A progress answer that matches no running bar is refused and recorded',
            fn = function(source)
                -- What a client inventing a "done" for a bar it was never shown sends.
                assertTrue(ClientExecWait(source, 'whip_core:server:progressResult', 3000, 999999, true, ''),
                    'the server answered')
                assertLastReject('whip_core:server:progressResult', 'answer did not match a bar that is running',
                    'refused, and on record')
            end,
        },

        -- ---- UI-2: the declared timed use ------------------------------------------------
        {
            name = 'A declared timed use runs the bar, takes one, then calls onComplete',
            fn = function(source)
                local got = nil
                assertOk(exports.whip_core:RegisterUseHandler(ITEM, {
                    label    = '[TEST] timed use',
                    duration = 400,
                    onComplete = function(src, player, item, addr)
                        got = { src = src, item = item and item.item, sub = addr and addr.sub,
                                countNow = exports.whip_core:GetItemCount(src, ITEM) }
                    end,
                }))

                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', 1, ITEM, 3)

                local t0 = GetGameTimer()
                useSlot(source, 1)

                assertNotNil(got, 'onComplete ran')
                assertEqual(got.src, source, 'onComplete was handed the player')
                assertEqual(got.item, ITEM, 'and the item')
                assertEqual(got.sub, 'player', 'and where it was')
                assertEqual(got.countNow, 2, 'the item was already taken when onComplete ran')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 2, 'exactly one was used up')
                -- useSlot waits 600ms before firing; the rest is the bar.
                assertGte(GetGameTimer() - t0 - 600, 360, 'the use waited for the bar')
            end,
        },
        {
            name = "canUse answering false, 'why' refuses before any bar and keeps the item",
            fn = function(source)
                local completed = false
                assertOk(exports.whip_core:RegisterUseHandler(ITEM, {
                    duration = 2000,
                    canUse = function() return false, '[TEST] not now' end,
                    onComplete = function() completed = true end,
                }))

                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', 1, ITEM, 3)

                local t0 = GetGameTimer()
                useSlot(source, 1, '[TEST] not now')

                assertFalse(completed, 'onComplete did not run')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 3, 'nothing was taken')
                -- The client's ack alone is ~500ms; a two-second bar would be well past this.
                assertTrue(GetGameTimer() - t0 - 600 < 1500, 'no bar was run')
            end,
        },
        {
            name = "onComplete answering false, 'why' gives the item back",
            fn = function(source)
                assertOk(exports.whip_core:RegisterUseHandler(ITEM, {
                    duration = 400,
                    onComplete = function() return false, '[TEST] undone on purpose' end,
                }))

                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', 1, ITEM, 3)
                useSlot(source, 1, '[TEST] undone on purpose')

                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 3, 'the item came back')
            end,
        },
        {
            -- The stack trace this prints in the console is EXPECTED output from this test.
            name = 'An onComplete that errors gives the item back',
            fn = function(source)
                local reached = false
                assertOk(exports.whip_core:RegisterUseHandler(ITEM, {
                    duration = 400,
                    onComplete = function()
                        reached = true
                        error('[EXPECTED] whip_test 48_server_ui is deliberately erroring here')
                    end,
                }))

                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', 1, ITEM, 3)
                -- Told, not silently refused: they watched the whole bar.
                useSlot(source, 1, 'That did not work')

                assertTrue(reached, 'onComplete was reached')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 3, 'the item came back')
            end,
        },
        {
            name = 'consume = false keeps the item and still completes',
            fn = function(source)
                local completed = false
                assertOk(exports.whip_core:RegisterUseHandler(ITEM, {
                    duration = 400,
                    consume  = false,
                    onComplete = function() completed = true end,
                }))

                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', 1, ITEM, 3)
                useSlot(source, 1)

                assertTrue(completed, 'onComplete ran')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 3, 'nothing was taken')
            end,
        },
        {
            name = 'An item that leaves during the bar is not used',
            fn = function(source)
                local completed = false
                assertOk(exports.whip_core:RegisterUseHandler(ITEM, {
                    duration = 1500,
                    onComplete = function() completed = true end,
                }))

                RemoveAllOf(source, ITEM)
                SeedSlot(source, 'player', 1, ITEM, 1)

                -- Fired without waiting: the bar is running while the item is taken away.
                Wait(600)
                ClientExec(source, USE_EVENT, 'player', 1)
                Wait(600)
                RemoveAllOf(source, ITEM)

                Wait(2000)   -- the rest of the bar, and the answer
                assertLastReject(USE_EVENT, 'You no longer have it', 'the use was refused, and said why')
                assertFalse(completed, 'onComplete did not run for an item that was gone')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 0, 'and nothing was conjured back')
            end,
        },
        {
            name = 'A table that is not a declaration is refused at registration',
            fn = function(source)
                local ok, err = exports.whip_core:RegisterUseHandler(ITEM, { label = '[TEST] no duration' })
                assertFalse(ok, 'a table without a duration')
                assertTrue(tostring(err):find('needs a duration', 1, true) ~= nil,
                    ('with a reason saying so (got "%s")'):format(tostring(err)))

                ok, err = exports.whip_core:RegisterUseHandler(ITEM, { duration = 0 })
                assertFalse(ok, 'a zero duration')
                assertTrue(tostring(err):find('positive number', 1, true) ~= nil,
                    ('with a reason saying so (got "%s")'):format(tostring(err)))
            end,
        },
        {
            -- ShowPlayerText (the Director's objectives, 2 Oct 2026): drawn on the tester's screen briefly.
            name = 'ShowPlayerText: shown, ours to hide, released with its tag; bad input refused',
            fn = function(source)
                local tag = ('_t48_text:%d'):format(GetGameTimer())
                local ok, why = exports.whip_core:ShowPlayerText(source, '[TEST] ^1Take the package', { tag = tag })
                assertTrue(ok, 'shown (' .. tostring(why) .. ')')
                Wait(300)
                assertTrue((exports.whip_core:HidePlayerText(source)), 'ours to take down')
                local okAgain = exports.whip_core:HidePlayerText(source)
                assertFalse(okAgain, 'nothing left to take down')

                assertTrue((exports.whip_core:ShowPlayerText(source, '[TEST] objective', { tag = tag, position = 'top', progress = 40 })),
                    'shown again, at the top, part filled')
                local okR, n = exports.whip_core:ReleaseTag(tag)
                assertTrue(okR and (n or 0) >= 1, 'ReleaseTag took it down')
                local okC, whyC = exports.whip_core:ShowPlayerText(source, '[TEST] again', { tag = tag })
                assertFalse(okC, 'a released tag refuses it')
                assertTrue(tostring(whyC):find('ended', 1, true) ~= nil, 'and says so (got: ' .. tostring(whyC) .. ')')

                local cases = {
                    { text = '   ',        opts = nil,                      why = 'empty' },
                    { text = 'x',          opts = { position = 'middle' }, why = 'position' },
                    { text = 'x',          opts = { progress = 'half' },   why = 'progress' },
                }
                for i, c in ipairs(cases) do
                    local okB, whyB = exports.whip_core:ShowPlayerText(source, c.text, c.opts)
                    assertFalse(okB, ('case %d is refused'):format(i))
                    assertTrue(tostring(whyB):find(c.why, 1, true) ~= nil, ('case %d says "%s" (got: %s)'):format(i, c.why, tostring(whyB)))
                end
                local okN = exports.whip_core:ShowPlayerText(65000, 'x')
                assertFalse(okN, 'nobody by that id')
            end,
        },
    },
})
