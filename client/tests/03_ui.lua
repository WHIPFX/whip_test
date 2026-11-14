--- The group every wheel entry below is added under, so teardown can take them all off.
local RADIAL_GROUP = '_t_radial'

RegisterClientTestModule({
    order    = 3,
    category = 'Client: UI Library',
    teardown = function()
        pcall(exports.whip_core.RemoveActionGroup, exports.whip_core, RADIAL_GROUP)
        for _, id in ipairs({ '_t_radial', '_t_radial_keep' }) do
            pcall(exports.whip_core.RemoveAction, exports.whip_core, id)
        end
    end,
    tests = {
        -- ####################################################################
        -- ONE SMOKE TEST, NAMED AS ONE, BECAUSE THAT IS ALL THIS IS.
        --
        -- These were three separate tests — "Notify fires without error", "ShowText + HideText
        -- works", "ShowText drives the same band with a manual fill" — and not one of them
        -- asserted anything. Three green rows, two of them claiming the feature "works", for
        -- code that could have drawn nothing at all.
        --
        -- That is not hypothetical here. Read the note further down about ProgressCircle: it
        -- was removed after it turned out never to have rendered, because its JS never marked
        -- the box visible, and the test passed happily through four hundred milliseconds of an
        -- empty screen. Same library, same blind spot.
        --
        -- Notify, ShowText and HideText return nothing and expose no state to read back, so
        -- there is genuinely nothing to assert from Lua — the truth lives in the NUI. Rather
        -- than dress that up as coverage, it is one row that says what it is. Proving these
        -- actually draw needs a check on the NUI side, and that is a real gap, not something
        -- this test should pretend to cover.
        -- ####################################################################
        --
        -- What it CAN assert is that each call returns rather than raising, so that is what it
        -- checks — the runner fails a test that asserts nothing at all, and a raise is the one
        -- failure these calls can report from Lua.
        {
            name = 'SMOKE ONLY: Notify/ShowText/HideText run without raising (nothing to assert)',
            fn = function()
                assertTrue(pcall(exports.whip_core.Notify, exports.whip_core, 'Test notification', 'info', 1000),
                    'Notify did not raise')
                Wait(100)

                assertTrue(pcall(exports.whip_core.ShowText, exports.whip_core, '[TEST] Hello', 'bottom'),
                    'ShowText did not raise')
                Wait(200)
                -- HideText answers now (UI-5): true when the text was ours to hide.
                local hid, hidden = pcall(exports.whip_core.HideText, exports.whip_core)
                assertTrue(hid, 'HideText did not raise')
                assertTrue(hidden, 'HideText hid our own text')

                -- The manual-fill form of the same band.
                assertTrue(pcall(exports.whip_core.ShowText, exports.whip_core, '[TEST] Filling', 'bottom', 50),
                    'ShowText with a fill did not raise')
                Wait(100)
                assertTrue(pcall(exports.whip_core.HideText, exports.whip_core), 'HideText did not raise')
            end,
        },
        -- 'Cancel works with nothing active' removed: UI.Cancel is no longer exported. It only
        -- ever cancels whichever blocking component the library itself has up, which is the
        -- library's own business — the onResourceStop cleanup is its one caller.
        {
            name = 'Progress completes and returns true',
            fn = function()
                local result = exports.whip_core:Progress('Testing...', 400)
                assertTrue(result, 'Progress should complete')
            end,
        },
        {
            -- UI-9 table form, UI-6 IsProgressActive, and UI-4: a bar is "busy" (IsAnyUIOpen) but
            -- not a screen (IsAnyScreenOpen), so the HUD and chat stay up for it.
            name = 'Progress({ ... }) runs; during it IsProgressActive and IsAnyUIOpen are true, IsAnyScreenOpen is not',
            fn = function()
                if exports.whip_core:IsAnyScreenOpen() then skip('a screen was already open') end
                local res = nil
                CreateThread(function()
                    res = table.pack(exports.whip_core:Progress({ label = '[TEST] table form', duration = 700 }))
                end)
                Wait(150)
                assertTrue(exports.whip_core:IsProgressActive(), 'IsProgressActive during the bar')
                assertTrue(exports.whip_core:IsAnyUIOpen(), 'a bar counts as busy')
                assertFalse(exports.whip_core:IsAnyScreenOpen(), 'but not as a screen')

                assertTrue(waitFor(function() return res ~= nil end, 3000), 'the bar answered')
                assertTrue(res[1], ('the table form completed (why: %s)'):format(tostring(res[2])))
                assertFalse(exports.whip_core:IsProgressActive(), 'IsProgressActive after the bar')
            end,
        },
        {
            -- UI-3: every blocking component says WHY it came back empty, and 'busy' is not
            -- 'cancelled'. Nothing opens here: each is refused while the bar holds the slot. Also the
            -- table forms (UI-9) and CancelProgress on our own bar (UI-6).
            name = "While a bar is up, every blocking component answers false, 'busy'; CancelProgress ends it as 'cancelled'",
            fn = function()
                local res = nil
                CreateThread(function()
                    res = table.pack(exports.whip_core:Progress('[TEST] holding the slot', 3000))
                end)
                Wait(150)
                assertTrue(exports.whip_core:IsProgressActive(), 'the bar is up')

                local ok, why = exports.whip_core:Progress('[TEST] second bar', 300)
                assertFalse(ok, 'a second Progress'); assertEqual(why, 'busy', 'Progress: busy')

                local vals, why2 = exports.whip_core:Input({ title = '[TEST]', fields = { { label = 'x', type = 'text' } } })
                assertEqual(vals, false, 'Input answers false, not nil'); assertEqual(why2, 'busy', 'Input: busy')

                local yes, why3 = exports.whip_core:Confirm({ title = '[TEST]', message = 'x', yes = 'Y', no = 'N' })
                assertFalse(yes, 'Confirm'); assertEqual(why3, 'busy', 'Confirm: busy')

                local seen, why4 = exports.whip_core:Alert({ title = '[TEST]', message = 'x', button = 'OK' })
                assertFalse(seen, 'Alert'); assertEqual(why4, 'busy', 'Alert: busy')

                local passed, why5 = exports.whip_core:SkillCheck({ difficulty = 'easy' })
                assertFalse(passed, 'SkillCheck'); assertEqual(why5, 'busy', 'SkillCheck: busy')

                -- The ring (27 Sep 2026): a difficulty that is not in the config is the developer's
                -- mistake, refused with the reason before anything else — not 'busy', not 'failed'.
                local p6, why6 = exports.whip_core:SkillCheck('impossible')
                assertFalse(p6, 'an unknown difficulty')
                assertTrue(tostring(why6):find('no skill check difficulty', 1, true) ~= nil,
                    ('with the reason (got "%s")'):format(tostring(why6)))

                assertTrue(exports.whip_core:CancelProgress(), 'CancelProgress ends our own bar')
                assertTrue(waitFor(function() return res ~= nil end, 3000), 'the bar answered')
                assertFalse(res[1], 'the cancelled bar did not complete')
                assertEqual(res[2], 'cancelled', 'it answered cancelled')
                assertFalse(exports.whip_core:CancelProgress(), 'and with nothing running, CancelProgress is false')
            end,
        },
        {
            -- UI-2: the bar plays the animation and holds the prop for its length, then cleans up.
            name = 'Progress with anim and prop: the prop is in hand during the bar and gone after',
            fn = function()
                local ped = PlayerPedId()
                if IsPedInAnyVehicle(ped, false) then skip('in a vehicle: upper-body animations do not play') end

                local hash = GetHashKey('prop_amb_beer_bottle')
                local function heldProp()
                    for _, obj in ipairs(GetGamePool('CObject')) do
                        if GetEntityModel(obj) == hash and IsEntityAttachedToEntity(obj, PlayerPedId()) then return obj end
                    end
                    return nil
                end
                assertNil(heldProp(), 'no bottle in hand before the bar')

                local res = nil
                CreateThread(function()
                    res = table.pack(exports.whip_core:Progress({
                        label    = '[TEST] drinking',
                        duration = 1500,
                        anim     = { dict = 'mp_player_intdrink', clip = 'loop_bottle' },
                        prop     = { model = 'prop_amb_beer_bottle' },
                        disable  = { move = false },
                    }))
                end)

                -- The checks made DURING the bar run under pcall, so a failed one cannot leave the bar
                -- running into the next test (which then got 'busy' and failed too).
                local okDuring, errDuring = pcall(function()
                    assertTrue(waitFor(function() return heldProp() ~= nil end, 2500), 'the bottle is in hand during the bar')
                    -- TRUTHY, NOT `== true`: this native answers 1 (or false) rather than a boolean,
                    -- like several BOOL natives in FiveM's Lua.
                    assertTrue(IsEntityPlayingAnim(PlayerPedId(), 'mp_player_intdrink', 'loop_bottle', 3) and true or false,
                        'the animation is playing')
                end)
                if not okDuring then
                    exports.whip_core:CancelProgress()
                    waitFor(function() return res ~= nil end, 3000)
                    error(errDuring, 0)
                end

                assertTrue(waitFor(function() return res ~= nil end, 4000), 'the bar answered')
                assertTrue(res[1], ('the bar completed (why: %s)'):format(tostring(res[2])))
                assertTrue(waitFor(function() return heldProp() == nil end, 1000), 'the bottle is gone after the bar')
            end,
        },
        {
            -- UI-8: a flag per (resource, screen), so closing one screen leaves the other held. And a
            -- resource's own screen does not stop its own bar (UI-4).
            name = 'SetUIOpen(open, key): one flag per screen; our own screen does not block our own bar',
            fn = function()
                if exports.whip_core:IsAnyUIOpen() then skip('a screen is already open') end

                -- Under pcall, so a failed check still releases both screens. A held screen left
                -- behind suppresses every prompt, and the Interactions card then skipped with
                -- "UI open: true".
                local ok, err = pcall(function()
                    assertTrue(exports.whip_core:SetUIOpen(true, 'test_a'), 'screen a declared')
                    assertTrue(exports.whip_core:SetUIOpen(true, 'test_b'), 'screen b declared')
                    assertTrue(exports.whip_core:IsAnyUIOpen(), 'held')

                    exports.whip_core:SetUIOpen(false, 'test_a')
                    assertTrue(exports.whip_core:IsAnyUIOpen(), 'closing a leaves b held')

                    local barOk, why = exports.whip_core:Progress('[TEST] over our own screen', 300)
                    assertTrue(barOk, ('our own screen does not block our own bar (why: %s)'):format(tostring(why)))

                    exports.whip_core:SetUIOpen(false, 'test_b')
                    assertFalse(exports.whip_core:IsAnyUIOpen(), 'closing b releases it')
                end)
                if not ok then
                    exports.whip_core:SetUIOpen(false, 'test_a')
                    exports.whip_core:SetUIOpen(false, 'test_b')
                    error(err, 0)
                end
            end,
        },
        {
            -- UI-5: CloseComposer answers, and only closes the caller's own composer.
            name = 'OpenComposer / CloseComposer: our own closes (onCancel runs); nothing open answers false',
            fn = function()
                if exports.whip_core:IsComposerOpen() then skip('a composer was already open') end
                assertFalse(exports.whip_core:CloseComposer(), 'nothing to close')

                local cancelled = false
                assertTrue(exports.whip_core:OpenComposer({
                    placeholder = '[TEST] composer',
                    deferFocus  = true,   -- never takes the keyboard: closed before it arms
                    onSubmit    = function() end,
                    onCancel    = function() cancelled = true end,
                }), 'opened')
                assertTrue(exports.whip_core:IsComposerOpen(), 'open')

                assertTrue(exports.whip_core:CloseComposer(), 'our own composer closes')
                assertFalse(exports.whip_core:IsComposerOpen(), 'closed')
                assertTrue(waitFor(function() return cancelled end, 1000), 'onCancel ran')
            end,
        },
        -- 'ProgressCircle completes' removed with the component. It had never actually rendered —
        -- its JS never marked the box visible — so this test passed for four hundred milliseconds
        -- of nothing being on screen, which is worth remembering about smoke tests that only
        -- assert a return value.
        -- 'ShowText drives the same band with a manual fill' folded into the smoke test at the
        -- top of this module — it asserted nothing either, and two rows saying nothing is no
        -- better than one.
        -- ---- the F1 wheel ----
        --
        -- REWRITTEN 25 Sep 2026 (INT-1): RadialAddOption / RadialRemove / RadialRemoveGroup are gone.
        -- An option on the wheel is an action with `at = { radial = true }`, read back with GetAction,
        -- whose `mounted` is only set once the wheel took it. The wheel itself (what F1 shows) needs a
        -- key held, so it is not asserted here.
        {
            name = 'Radial: AddAction at { radial = true } mounts on the wheel; the same id again replaces it',
            fn = function()
                assertFalse(exports.whip_core:IsRadialOpen(), 'the wheel is not open')

                local def = { id = '_t_radial', at = { radial = true }, label = '[TEST] Option',
                              group = RADIAL_GROUP, onSelect = function() end }
                local id, why = exports.whip_core:AddAction(def)
                assertEqual(id, '_t_radial', 'accepted: it answers the caller\'s id (' .. tostring(why) .. ')')

                local a = exports.whip_core:GetAction('_t_radial')
                assertEqual(a and a.mounted, 'radial', 'mounted on the wheel')
                assertEqual(a and a.engineIds[1], 'act:whip_test:_t_radial', 'as act:<resource>:<id>')

                -- Satellites re-register from onReady, which fires on every resource start: the same id
                -- must land on the same entry, not add a second one.
                def.label = '[TEST] Option (again)'
                id, why = exports.whip_core:AddAction(def)
                assertEqual(id, '_t_radial', 'accepted again, the same id (' .. tostring(why) .. ')')
                a = exports.whip_core:GetAction('_t_radial')
                assertEqual(a and a.label, '[TEST] Option (again)', 'with the new label')
                assertEqual(a and #a.engineIds, 1, 'and still one entry on the wheel')

                assertTrue((exports.whip_core:RemoveAction('_t_radial')), 'RemoveAction takes it off')
                assertNil(exports.whip_core:GetAction('_t_radial'), 'and it is gone')
            end,
        },
        {
            name = 'Radial: the wheel needs a label, and a function label is resolved',
            fn = function()
                local ok, why = exports.whip_core:AddAction({ id = '_t_radial_nolabel', at = { radial = true },
                                                              onSelect = function() end })
                assertFalse(ok, 'an entry with no label is refused')
                assertTrue(type(why) == 'string' and why:find('the wheel needs a label', 1, true) ~= nil,
                    'and says why (got: ' .. tostring(why) .. ')')

                ok, why = exports.whip_core:AddAction({ id = '_t_radial_fn', at = { radial = true }, group = RADIAL_GROUP,
                                                        label = function(ctx) return '[TEST] wheel label for ' .. tostring(ctx.id) end,
                                                        onSelect = function() end })
                assertEqual(ok, '_t_radial_fn', 'a function label is a label (' .. tostring(why) .. ')')
                local a = exports.whip_core:GetAction('_t_radial_fn')
                assertEqual(a and a.mounted, 'radial', 'mounted')
                assertEqual(a and a.options[1].label, '[TEST] wheel label for _t_radial_fn',
                    'the function was called and its text used')
            end,
        },
        {
            name = 'Radial: RemoveActionGroup takes the group off the wheel and leaves the rest',
            fn = function()
                for _, id in ipairs({ '_t_radial_a', '_t_radial_b' }) do
                    assertEqual((exports.whip_core:AddAction({ id = id, at = { radial = true }, label = '[TEST] ' .. id,
                                                               group = RADIAL_GROUP, onSelect = function() end })), id, id .. ' added')
                end
                assertEqual((exports.whip_core:AddAction({ id = '_t_radial_keep', at = { radial = true },
                                                           label = '[TEST] keep', onSelect = function() end })), '_t_radial_keep',
                    'bystander added')

                local ok, n = exports.whip_core:RemoveActionGroup(RADIAL_GROUP)
                assertTrue(ok, 'removed')
                assertGte(n, 2, 'at least the two just added (and any the tests above left)')
                assertNil(exports.whip_core:GetAction('_t_radial_a'), 'the first is gone')
                assertNil(exports.whip_core:GetAction('_t_radial_b'), 'the second is gone')
                assertNotNil(exports.whip_core:GetAction('_t_radial_keep'), 'an entry outside the group is untouched')

                assertTrue((exports.whip_core:RemoveAction('_t_radial_keep')), 'bystander removed')
            end,
        },
    }
})
