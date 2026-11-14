-- ============================================
-- Client: Interactions (AddAction — world prompts and car parts)
-- ============================================
--
-- REWRITTEN 25 Sep 2026 (INT-1). The Interact* exports these tests drove are gone: a resource puts
-- "the player can do X" into the world with ONE export, AddAction, changes it with UpdateAction,
-- takes it out with RemoveAction / RemoveActionGroup and reads it back with GetAction. This module
-- covers that API and the world-prompt and car-part engines under it; 03_ui.lua covers the F1 wheel.
--
-- EVERY CALL CROSSES THE EXPORT BOUNDARY, which is the point. whip_test is a satellite, so its
-- actions are keyed 'whip_test:<id>' (Registry.caller), and a function in a table below arrives on
-- whip_core's side exactly as whip_power's does.
--
-- WHAT IS OBSERVABLE FROM HERE:
--   * GetAction: the action as whip_core holds it — where it is mounted, and for each option whether
--     it could be offered right now and, if not, why. It resolves function labels, so the
--     "[object Object]" kind of bug (a satellite's function label never being called) shows.
--   * canInteract, which whip_core calls back. The LIVE scoring loop calls it with a ctx that carries
--     ctx.typed; GetAction's own check hands a ctx without it. So counting the calls whose ctx has
--     ctx.typed watches the loop itself: it runs for a prompt in front of the tester, it keeps going
--     past a neighbour that throws, and it stops when an admin switches the prompt off.
--
-- WHAT IS NOT, and the seam it would need:
--   * onSelect. Only a key press fires it; a "press this prompt" export would (the /whip panel's
--     Interactions.fire has none).
--   * ctx.typed with digits in it. Typing starts with ctx.beginInput, which only onSelect's ctx
--     carries — the same seam.
--   * which prompt holds focus. InteractGetFocusedId went with the Interact* exports.
--   * a point placed from the admin side, mounted here. It is whip_core's own action, and GetAction
--     reads only the caller's.

local function NOOP() end

local function add(def)
    return exports.whip_core:AddAction(def)
end

-- AddAction answers the id, or false and why. Did it take (true/false), and why not.
local function added(def)
    local id, why = add(def)
    return type(id) == 'string', why
end

local function get(id)
    return exports.whip_core:GetAction(id)
end

local function has(s, fragment)
    return type(s) == 'string' and s:find(fragment, 1, true) ~= nil
end

--- The first option of an action as GetAction reads it, or an empty table.
local function opt1(id)
    local a = get(id)
    return (a and a.options and a.options[1]) or {}
end

--- A spot out of the way, for actions that only need to exist.
local FAR = vector3(10.0, 20.0, 50.0)

--- Where a prompt has to be for the scoring pass to ask it: ahead of the gameplay camera, within
--- reach of the player, at chest height.
---@param ahead number  metres in front of the player, along the camera's heading
---@return number x, number y, number z
local function inFrontOfTester(ahead)
    local pos = GetEntityCoords(PlayerPedId())
    local heading = math.rad(GetGameplayCamRot(2).z)
    return pos.x - math.sin(heading) * ahead, pos.y + math.cos(heading) * ahead, pos.z + 0.3
end

--- A canInteract that counts how often the LIVE LOOP asks it — the calls whose ctx carries
--- ctx.typed — and, the first time, records the ctx and what ctx.typed held. A VALUE since DX-21
--- (25 Sep 2026): it was a function, packed as a fresh reference on every per-frame call.
local function loopProbe()
    local p = { loop = 0 }
    p.fn = function(ctx)
        if ctx and ctx.typed ~= nil then
            p.loop = p.loop + 1
            if p.typedOk == nil then
                p.typedOk = ctx.typed == false or type(ctx.typed) == 'string'
                p.typedValue = ctx.typed
                p.ctx = { id = ctx.id, owner = ctx.owner, option = ctx.option }
            end
        end
        return true
    end
    return p
end

--- Prompts are hidden from the loop while any UI is open, in a vehicle, or downed. Close what we
--- can, and skip — saying which — when the rest is true.
local function promptsCanRun()
    exports.whip_core:CloseInventory()
    waitFor(function() return not exports.whip_core:IsAnyUIOpen() end, 2000)
    if IsPedInAnyVehicle(PlayerPedId(), false) then skip('in a vehicle: world prompts are off') end
    local dead = exports.whip_core:IsPlayerDead()
    if dead then skip('downed: world prompts are off') end
end

--- Wait for the loop to ask the probe a few times, or skip with the likely blocker named. EVERY
--- ANSWER INTO A LOCAL FIRST: an export answering nil arrives as no value at all, and tostring()
--- with nothing throws.
local function awaitLoop(p, x, y, z)
    if waitFor(function() return p.loop >= 3 end, 2500) then return end
    local uiOpen = exports.whip_core:IsAnyUIOpen()
    local onScreen = World3dToScreen2d(x, y, z)
    skip(('the loop never asked a prompt 1.2m in front — UI open: %s, on screen: %s')
        :format(tostring(uiOpen), tostring(onScreen)))
end

local GROUPS = { '_t_ia', '_t_ia_auto', '_t_ia_rm', '_t_ia_req', '_t_ia_can', '_t_ia_live' }

RegisterClientTestModule({
    order    = 4,
    category = 'Client: Interactions',
    teardown = function(ctx)
        for _, g in ipairs(GROUPS) do
            pcall(exports.whip_core.RemoveActionGroup, exports.whip_core, g)
        end
        for _, id in ipairs({ '_t_prompt', '_t_upd', '_t_fnlabel', '_t_fnlabel_boom', '_t_opts', '_t_opt_sel',
                              '_t_entity', '_t_part', '_t_part_multi', '_t_part_bad', '_t_rm_keep', '_t_off',
                              '_t_ace_yes', '_t_ace_no' }) do
            pcall(exports.whip_core.RemoveAction, exports.whip_core, id)
        end
        if ctx.obj and DoesEntityExist(ctx.obj) then DeleteEntity(ctx.obj) end
    end,
    tests = {
        -- ==========================================
        -- The API
        -- ==========================================
        {
            name = 'AddAction refuses what it cannot place, and says why (and registers nothing)',
            fn = function()
                local cases = {
                    { def = '[TEST] not a table',                                              why = 'an action is a table' },
                    { def = { id = '_t_bad', label = 'x', onSelect = NOOP },                   why = 'at says where the action is' },
                    { def = { id = '_t_bad', at = { flying = true }, onSelect = NOOP },        why = 'at says where the action is' },
                    { def = { id = '_t_bad', at = { coords = 'here' }, onSelect = NOOP },      why = 'at.coords must be a vector3' },
                    { def = { id = '_t_bad', at = { entity = -1 }, onSelect = NOOP },          why = 'at.entity does not exist' },
                    { def = { id = '_t_bad', at = { coords = FAR }, label = 'x' },             why = 'onSelect is required' },
                    { def = { id = '_t_bad', at = { coords = FAR }, label = 'x',
                              options = { { id = 'a', label = 'A' } } },                       why = 'onSelect is required' },
                    { def = { id = '_t_bad', at = { radial = true }, onSelect = NOOP },        why = 'the wheel needs a label' },
                    -- The Alt aim menu is gone: `aim` is no place now
                    { def = { id = '_t_bad', at = { aim = 'vehicle' }, onSelect = NOOP },      why = 'at says where the action is' },
                }
                for i, c in ipairs(cases) do
                    local ok, why = add(c.def)
                    assertFalse(ok, ('case %d is refused'):format(i))
                    assertTrue(has(why, c.why), ('case %d says "%s" (got: %s)'):format(i, c.why, tostring(why)))
                end
                assertNil(get('_t_bad'), 'nothing refused was registered')
            end,
        },
        {
            -- WARNED, NOT REFUSED (12 Oct 2026, shared/interact_spec.lua): a misspelt field used to be
            -- skipped without a word, and a `scale` that was not a number stopped every prompt drawing.
            name = 'AddAction warns about a field it does not have and a value out of range, keeps the action, and answers the warnings third',
            fn = function()
                local id, why, warnings = add({
                    id = '_t_warn', at = { coords = FAR, ofset = FAR }, group = '_t_ia',
                    lable = '[TEST] typo', label = '[TEST] warned', distance = 1, scale = 10, focusMode = 'closest',
                    onSelect = NOOP,
                })
                assertEqual(id, '_t_warn', 'still added: the id (' .. tostring(why) .. ')')
                assertFalse(why, 'added: the second answer is false (not nil, so the warnings cross the export)')
                assertType(warnings, 'table', 'a third answer: the warnings')
                local all = table.concat(type(warnings) == 'table' and warnings or {}, ' | ')
                for _, says in ipairs({ "lable is not a field — use 'label'", "distance is not a field — use 'reach'",
                                        "at.ofset is not a field — use 'offset'", 'got 10, so 4 is used',
                                        "focusMode is 'aim' or 'near'" }) do
                    assertTrue(has(all, says), ('it says "%s" (got: %s)'):format(says, all))
                end
                assertEqual(get('_t_warn') and get('_t_warn').label, '[TEST] warned', 'the real label is kept')

                local idClean, whyClean, none = add({ id = '_t_warn', at = { coords = FAR }, group = '_t_ia',
                    label = '[TEST] clean', scale = 1.5, onSelect = NOOP })
                assertEqual(idClean, '_t_warn', 'a clean one (' .. tostring(whyClean) .. ')')
                assertNil(none, 'has no warnings')
            end,
        },
        {
            -- STYLES (12 Oct 2026, client/interact_style.lua): a name or a table, checked like any
            -- field, and changed in place by SetActionStyle.
            name = 'An action takes a style by name or table; SetActionStyle changes it; a misspelt one is warned about',
            fn = function()
                local id, why, warnings = add({ id = '_t_style', at = { coords = FAR }, group = '_t_ia',
                    label = '[TEST] styled', style = 'subtle', onSelect = NOOP })
                assertEqual(id, '_t_style', 'added (' .. tostring(why) .. ')')
                assertNil(warnings, 'subtle is a style (' .. table.concat(type(warnings) == 'table' and warnings or {}, ' | ') .. ')')
                assertEqual(get('_t_style').style, 'subtle', 'GetAction says which')

                local sOk, sWhy, sWarn = exports.whip_core:SetActionStyle('_t_style', { tint = '#ff0000', badgeScale = 1.5 })
                assertTrue(sOk, 'SetActionStyle (' .. tostring(sWhy) .. ')')
                assertNil(sWarn, 'no warnings')
                local st = get('_t_style').style
                assertEqual(type(st) == 'table' and st.tint and st.tint.r, 255, 'the tint, as { r, g, b }')
                assertEqual(type(st) == 'table' and st.badgeScale, 1.5, 'the size')
                assertEqual(get('_t_style').mounted, 'prompt', 'still the same prompt')

                local _, _, misspelt = exports.whip_core:SetActionStyle('_t_style', 'subtel')
                local all = table.concat(type(misspelt) == 'table' and misspelt or {}, ' | ')
                assertTrue(has(all, "use 'subtle'"), 'a misspelt name says which it meant (got: ' .. all .. ')')
                assertNil(get('_t_style').style, 'and the prompt wears the default')

                local okNo, whyNo = exports.whip_core:SetActionStyle('_t_never_added', 'subtle')
                assertFalse(okNo, 'not an action of ours: refused')
                assertTrue(has(whyNo, '_t_never_added'), 'says which (got: ' .. tostring(whyNo) .. ')')
            end,
        },
        {
            name = 'AddAction at coords answers the id; GetAction reads it back, mounted as a world prompt',
            fn = function()
                local id, why = add({
                    id = '_t_prompt', at = { coords = FAR, heading = 90.0 },
                    label = '[TEST] Prompt', icon = 'lock', group = '_t_ia', reach = 2.5, seeFrom = 6.0,
                    onSelect = NOOP,
                })
                assertEqual(id, '_t_prompt', 'accepted: it answers the caller\'s id (' .. tostring(why) .. ')')

                local a = get('_t_prompt')
                assertNotNil(a, 'GetAction reads it back')
                assertEqual(a.id, '_t_prompt', 'id')
                assertEqual(a.owner, 'whip_test', 'owned by the resource that added it')
                assertEqual(a.key, 'whip_test:_t_prompt', 'keyed <resource>:<id>')
                assertEqual(a.mounted, 'prompt', 'mounted as a world prompt')
                assertEqual(#a.engineIds, 1, 'one prompt')
                assertEqual(a.engineIds[1], 'act:whip_test:_t_prompt', 'called act:<resource>:<id>')
                assertEqual(a.label, '[TEST] Prompt', 'label')
                assertEqual(a.icon, 'lock', 'icon')
                assertEqual(a.group, '_t_ia', 'group')
                assertEqual(a.reach, 2.5, 'reach')
                assertEqual(a.seeFrom, 6.0, 'seeFrom')
                assertTrue(a.enabled, 'switched on')
                assertEqual(a.at.heading, 90.0, 'at.heading')
                assertEqual(a.at.coords and a.at.coords.x, 10.0, 'at.coords comes back as plain x, y, z')
                assertEqual(#a.options, 1, 'one implicit option')
                assertEqual(a.options[1].id, 'default', 'called default')
                assertEqual(a.options[1].label, '[TEST] Prompt', 'which takes the action\'s label')
                assertTrue(a.options[1].offered, 'and could be offered now (why: ' .. tostring(a.options[1].why) .. ')')
            end,
        },
        {
            name = 'The same id again replaces it in place: still one action, with the new fields',
            fn = function()
                local id, why = add({ id = '_t_prompt', at = { coords = FAR }, label = '[TEST] Prompt v2',
                                      group = '_t_ia', onSelect = NOOP })
                assertEqual(id, '_t_prompt', 'accepted, the same id (' .. tostring(why) .. ')')
                local a = get('_t_prompt')
                assertEqual(a and a.label, '[TEST] Prompt v2', 'the new label')
                assertNil(a and a.icon, 'and a field the new one left out is gone — it replaced, it did not merge')
                assertEqual(a and #a.engineIds, 1, 'still one prompt')

                local okR = exports.whip_core:RemoveAction('_t_prompt')
                assertTrue(okR, 'one RemoveAction takes it out')
                assertNil(get('_t_prompt'), 'and it is gone')
                local okAgain, why = exports.whip_core:RemoveAction('_t_prompt')
                assertFalse(okAgain, 'a second RemoveAction is refused')
                assertTrue(has(why, 'is not registered'), 'and says so (got: ' .. tostring(why) .. ')')
            end,
        },
        {
            name = 'An action with no id gets a stable one from what and where it is: the same registration, the same id',
            fn = function()
                local def = { at = { coords = vector3(11.0, 21.0, 50.0) }, label = '[TEST] auto',
                              group = '_t_ia_auto', onSelect = NOOP }
                local id1, why1 = add(def)
                local id2, why2 = add(def)
                assertType(id1, 'string', 'first accepted (' .. tostring(why1) .. ')')
                assertType(id2, 'string', 'second accepted (' .. tostring(why2) .. ')')
                assertEqual(id2, id1, 'the same registration re-run lands on the same id (so onReady replaces)')
                assertTrue(has(id1, 'auto:'), 'a made-up id says so: ' .. tostring(id1))

                def.label = '[TEST] auto, another'
                local id3, why3 = add(def)
                assertType(id3, 'string', 'third accepted (' .. tostring(why3) .. ')')
                assertNotEqual(id3, id1, 'a different registration gets a different id')

                local okG, n = exports.whip_core:RemoveActionGroup('_t_ia_auto')
                assertTrue(okG, 'group removed')
                assertEqual(n, 2, 'two actions, not three: the re-run replaced the first')
            end,
        },
        {
            name = 'UpdateAction changes the fields it is given and keeps the rest; a new `at` moves it to another engine',
            fn = function()
                assertTrue((added({ id = '_t_upd', at = { coords = FAR }, label = '[TEST] A', group = '_t_ia',
                                  reach = 2.0, onSelect = NOOP })), 'added')

                local ok, why = exports.whip_core:UpdateAction('_t_upd', { label = '[TEST] B' })
                assertTrue(ok, 'updated (' .. tostring(why) .. ')')
                local a = get('_t_upd')
                assertEqual(a.label, '[TEST] B', 'the new label')
                assertEqual(a.group, '_t_ia', 'the group it was not given is kept')
                assertEqual(a.reach, 2.0, 'and the reach')
                assertEqual(a.mounted, 'prompt', 'still a prompt')

                ok, why = exports.whip_core:UpdateAction('_t_upd', { at = { radial = true } })
                assertTrue(ok, 'moved to the wheel (' .. tostring(why) .. ')')
                a = get('_t_upd')
                assertEqual(a.mounted, 'radial', 'mounted on the wheel now')
                assertEqual(a.engineIds[1], 'act:whip_test:_t_upd', 'under the same engine id')
                assertTrue(a.at.radial, 'at is the new one')
                assertNil(a.at.coords, 'replaced whole, not merged')

                ok, why = exports.whip_core:UpdateAction('_t_upd', { at = { flying = true } })
                assertFalse(ok, 'an update to an `at` that names nothing is refused')
                assertTrue(has(why, 'at says where'), 'and says why (got: ' .. tostring(why) .. ')')
                assertEqual(get('_t_upd').mounted, 'radial', 'and the action is left as it was')

                ok, why = exports.whip_core:UpdateAction('_t_never', { label = 'x' })
                assertFalse(ok, 'updating an action you do not have is refused')
                assertTrue(has(why, 'no action "_t_never" of yours'), 'and says so (got: ' .. tostring(why) .. ')')

                ok, why = exports.whip_core:UpdateAction('_t_upd', '[TEST] not a table')
                assertFalse(ok, 'a patch that is not a table is refused')
                assertTrue(has(why, 'a patch is a table'), 'and says so (got: ' .. tostring(why) .. ')')

                assertTrue((exports.whip_core:RemoveAction('_t_upd')), 'removed')
            end,
        },
        {
            name = 'RemoveAction reaches only your own: another resource\'s action is not a name you can use',
            fn = function()
                local ok, why = exports.whip_core:RemoveAction('_t_never')
                assertFalse(ok, 'an id never added is refused')
                assertTrue(has(why, 'is not registered'), 'and says so (got: ' .. tostring(why) .. ')')

                -- whip_gunny's bench is 'workbench' — under whip_gunny. From here the same word means
                -- whip_test:workbench, which does not exist, whatever whip_gunny is doing.
                local okG, whyG = exports.whip_core:RemoveAction('workbench')
                assertFalse(okG, 'another resource\'s id cannot be removed from here')
                assertTrue(has(whyG, 'is not registered'), 'it is simply not ours (got: ' .. tostring(whyG) .. ')')
                assertNil(get('workbench'), 'nor read')
            end,
        },
        {
            name = 'RemoveActionGroup removes the group, answers how many, and leaves the rest',
            fn = function()
                for i, id in ipairs({ '_t_rm_a', '_t_rm_b' }) do
                    assertTrue((added({ id = id, at = { coords = FAR + vector3(i, 0, 0) }, label = '[TEST] ' .. id,
                                      group = '_t_ia_rm', onSelect = NOOP })), id .. ' added')
                end
                assertTrue((added({ id = '_t_rm_keep', at = { coords = FAR }, label = '[TEST] keep', onSelect = NOOP })),
                    'bystander added')

                local ok, n = exports.whip_core:RemoveActionGroup('_t_ia_rm')
                assertTrue(ok, 'removed')
                assertEqual(n, 2, 'it answers how many')
                assertNil(get('_t_rm_a'), 'the first is gone')
                assertNil(get('_t_rm_b'), 'the second is gone')
                assertNotNil(get('_t_rm_keep'), 'an action outside the group is untouched')

                local okE, whyE = exports.whip_core:RemoveActionGroup('')
                assertFalse(okE, 'an empty group name is refused')
                assertTrue(has(whyE, 'group name is required'), 'and says so (got: ' .. tostring(whyE) .. ')')
                local okZ, z = exports.whip_core:RemoveActionGroup('_t_ia_rm')
                assertTrue(okZ, 'an empty group is not an error')
                assertEqual(z, 0, 'it just removes nothing')

                assertTrue((exports.whip_core:RemoveAction('_t_rm_keep')), 'bystander removed')
            end,
        },

        -- ==========================================
        -- Labels, options and the rules that hide them
        -- ==========================================
        {
            name = 'A label and icon may be functions across the export: GetAction resolves them, with a ctx',
            fn = function()
                -- THE "[object Object]" CLASS. A function from another resource arrives as a callable
                -- reference, not `type() == 'function'`; a resolver that tested for a function sent
                -- the reference itself to the page as the text. GetAction resolves labels through the
                -- same resolveText the prompt uses, so here the text itself is checked.
                local seen = nil
                assertTrue((added({
                    id = '_t_fnlabel', at = { coords = FAR }, group = '_t_ia', onSelect = NOOP,
                    label = function(ctx)
                        seen = { id = ctx.id, owner = ctx.owner, option = ctx.option }
                        return '[TEST] computed for ' .. tostring(ctx.id)
                    end,
                    icon = function() return 'lock' end,
                })), 'added')

                local a = get('_t_fnlabel')
                assertEqual(a.options[1].label, '[TEST] computed for _t_fnlabel', 'the function was called and its text used')
                assertNil(a.label, 'GetAction lists only a TEXT label as a field')
                assertNotNil(seen, 'the label function got a ctx')
                assertEqual(seen.id, '_t_fnlabel', 'ctx.id')
                assertEqual(seen.owner, 'whip_test', 'ctx.owner')
                assertEqual(seen.option, 'default', 'ctx.option')

                -- One that throws resolves to nothing — reported once, not an error, and it does not hide
                -- the action.
                assertTrue((added({
                    id = '_t_fnlabel_boom', at = { coords = FAR }, group = '_t_ia', onSelect = NOOP,
                    label = function() error('deliberate test throw') end,
                })), 'added (throwing label)')
                local o = opt1('_t_fnlabel_boom')
                assertNil(o.label, 'a label that throws resolves to nothing')
                assertTrue(o.offered, 'and does not hide the action')
            end,
        },
        {
            name = 'Options: each has its own id, label, require, canInteract and switch, falling back to the action\'s',
            fn = function()
                assertTrue((added({
                    id = '_t_opts', at = { coords = FAR }, label = '[TEST] the action', group = '_t_ia', onSelect = NOOP,
                    options = {
                        { id = 'a', label = '[TEST] A' },
                        { id = 'b', label = '[TEST] B', canInteract = function() return false, 'not today' end },
                        { id = 'c', require = { job = '_whip_test_nojob' } },
                        { id = 'd', enabled = false },
                        { label = '[TEST] no id' },
                    },
                })), 'added')

                local a = get('_t_opts')
                assertEqual(a.mounted, 'prompt', 'mounted')
                assertEqual(#a.engineIds, 1, 'several options are ONE prompt with a list, not several prompts')
                assertEqual(#a.options, 5, 'five options')

                local o = a.options
                assertEqual(o[1].id, 'a', 'option ids are kept')
                assertEqual(o[1].label, '[TEST] A', 'with their own label')
                assertTrue(o[1].offered, 'a plain option is offered')

                assertFalse(o[2].offered, 'an option\'s own canInteract hides it')
                assertEqual(o[2].why, 'not today', 'with the reason it gave')

                assertEqual(o[3].label, '[TEST] the action', 'an option with no label takes the action\'s')
                assertFalse(o[3].offered, 'an option\'s own require hides it')
                assertEqual(o[3].why, 'job', 'with the rule that failed')

                assertFalse(o[4].offered, 'enabled = false on an option switches only that option off')
                assertEqual(o[4].why, 'switched off', 'and says so')

                assertEqual(o[5].id, 'opt5', 'an option with no id is named by its place')

                -- onSelect on an option is enough; the action need not have one.
                local ok, why = added({ id = '_t_opt_sel', at = { coords = FAR }, label = '[TEST] x', group = '_t_ia',
                                      options = { { id = 'x', onSelect = NOOP } } })
                assertTrue(ok, 'an onSelect on an option satisfies "onSelect is required" (' .. tostring(why) .. ')')
            end,
        },
        {
            name = 'canInteract: the action\'s rule, then the option\'s; its reason is the why; 0 is no; a throw hides it',
            fn = function()
                local seen = nil
                local defs = {
                    { id = '_t_can_no',   canInteract = function() return false, 'closed for lunch' end },
                    { id = '_t_can_zero', canInteract = function() return 0 end },
                    { id = '_t_can_boom', canInteract = function() error('deliberate test throw') end },
                    { id = '_t_can_ctx',  canInteract = function(ctx)
                        seen = { id = ctx.id, owner = ctx.owner, option = ctx.option }
                        return true
                    end },
                    -- The action says yes, the option says no: the option's rule must still be asked. It
                    -- was once skipped (an ipairs over { action, option } stops at a nil first slot).
                    { id = '_t_can_both', canInteract = function() return true end,
                      options = { { id = 'x', canInteract = function() return false, 'the option says no' end } } },
                    { id = '_t_can_opt_only',
                      options = { { id = 'x', canInteract = function() return false, 'only the option has a rule' end } } },
                }
                for _, d in ipairs(defs) do
                    d.at, d.label, d.group, d.onSelect = { coords = FAR }, '[TEST] ' .. d.id, '_t_ia_can', NOOP
                    assertTrue((added(d)), d.id .. ' added')
                end

                assertEqual(opt1('_t_can_no').why, 'closed for lunch', 'false, why: the why is the reason')
                assertEqual(opt1('_t_can_zero').why, 'canInteract said no', '0 is no (FiveM-truthy)')
                assertEqual(opt1('_t_can_boom').why, 'canInteract threw', 'a throw hides it, and says so')
                assertTrue(opt1('_t_can_ctx').offered, 'true is yes')
                assertEqual(seen and seen.id, '_t_can_ctx', 'canInteract got ctx.id')
                assertEqual(seen and seen.owner, 'whip_test', 'and ctx.owner')
                assertEqual(seen and seen.option, 'default', 'and ctx.option')
                assertEqual(opt1('_t_can_both').why, 'the option says no', 'the option\'s rule is asked after the action\'s yes')
                assertEqual(opt1('_t_can_opt_only').why, 'only the option has a rule',
                    'and when the action has none at all')

                local okG, n = exports.whip_core:RemoveActionGroup('_t_ia_can')
                assertTrue(okG, 'removed')
                assertEqual(n, #defs, 'all of them')
            end,
        },
        {
            name = 'require: each rule hides the action with its own reason, and passes when it is met',
            fn = function()
                local inVeh = IsPedInAnyVehicle(PlayerPedId(), false)
                local cases = {
                    { req = { vehicle = inVeh and 'out' or 'in' },               why = inVeh and 'in a vehicle' or 'not in a vehicle' },
                    { req = { vehicle = inVeh and 'in' or 'out' },               why = nil },
                    { req = { job = '_whip_test_nojob' },                         why = 'job' },
                    { req = { job = { '_whip_test_nojob', '_whip_test_nojob2' } }, why = 'job' },
                    { req = { item = '_whip_test_no_item' },                      why = 'item _whip_test_no_item' },
                    { req = { item = { item = '_whip_test_no_item', count = 2 } }, why = 'item _whip_test_no_item' },
                    { req = { item = { '_whip_test_no_item', '_whip_test_no_item2' } }, why = 'item _whip_test_no_item' },
                    { req = { zone = '_whip_test_no_zone' },                      why = 'zone' },
                    { req = { charId = -1 },                                      why = 'character' },
                    { req = { alive = false },                                    why = nil },
                }
                -- On duty anywhere? Then `onDuty` alone passes; if not, it is the reason.
                local onDuty = exports.whip_core:IsPlayerClockedOn()
                cases[#cases + 1] = { req = { onDuty = true }, why = (onDuty ~= true) and 'off duty' or nil }

                local me = exports.whip_core:GetCharId()
                if me then cases[#cases + 1] = { req = { charId = { 999999999, me } }, why = nil } end

                -- A job the tester has: named, it passes; with a permission nobody has, it does not.
                local jobs = exports.whip_core:GetPlayerJobs() or {}
                local _, job = next(jobs)
                if job and job.key then
                    cases[#cases + 1] = { req = { job = job.key }, why = nil }
                    cases[#cases + 1] = { req = { job = job.key, jobPermission = '_whip_test_no_perm' }, why = 'job' }
                end

                for i, c in ipairs(cases) do
                    local id = '_t_req_' .. i
                    assertTrue((added({ id = id, at = { coords = FAR }, label = '[TEST] ' .. id, group = '_t_ia_req',
                                      require = c.req, onSelect = NOOP })), id .. ' added')
                    local o = opt1(id)
                    if c.why then
                        assertFalse(o.offered, ('case %d is hidden'):format(i))
                        assertEqual(o.why, c.why, ('case %d says why'):format(i))
                    else
                        assertTrue(o.offered, ('case %d is offered (why: %s)'):format(i, tostring(o.why)))
                    end
                end

                -- A zone the tester stands in: whip_test's own, drawn around them.
                local pos = GetEntityCoords(PlayerPedId())
                exports.whip_core:ZoneSphere({ id = '_t_ia_zone', pos = pos, radius = 8.0 })
                -- Under pcall so the zone goes whatever happens; the failure is raised again after.
                local okZ, errZ = pcall(function()
                    assertTrue((added({ id = '_t_req_zone', at = { coords = FAR }, label = '[TEST] zone', group = '_t_ia_req',
                                      require = { zone = '_t_ia_zone' }, onSelect = NOOP })), 'zone action added')
                    assertTrue(waitFor(function() return opt1('_t_req_zone').offered == true end, 3000) == true,
                        'standing in the zone passes `zone`')
                end)
                exports.whip_core:ZoneRemove('_t_ia_zone')
                if not okZ then error(errZ, 0) end

                assertTrue((exports.whip_core:RemoveActionGroup('_t_ia_req')), 'removed')
            end,
        },
        {
            name = 'require.ace is asked of the server once: no while it asks, then the real answer',
            fn = function()
                -- The tester holds whip.devtools (/test needs it) and nobody holds the other one.
                assertTrue((added({ id = '_t_ace_yes', at = { coords = FAR }, label = '[TEST] ace yes',
                                  require = { ace = 'whip.devtools' }, onSelect = NOOP })), 'added (held)')
                assertTrue((added({ id = '_t_ace_no', at = { coords = FAR }, label = '[TEST] ace no',
                                  require = { ace = '_whip_test_no_ace' }, onSelect = NOOP })), 'added (not held)')

                assertTrue(waitFor(function() return opt1('_t_ace_yes').offered == true end, 4000) == true,
                    'an ACE the tester holds passes once the server has answered')
                Wait(1000)
                local o = opt1('_t_ace_no')
                assertFalse(o.offered, 'an ACE nobody holds stays hidden after the answer too')
                assertEqual(o.why, 'permission', 'with the reason')

                exports.whip_core:RemoveAction('_t_ace_yes')
                exports.whip_core:RemoveAction('_t_ace_no')
            end,
        },
        {
            name = 'enabled = false switches an action off; UpdateAction switches it back on',
            fn = function()
                assertTrue((added({ id = '_t_off', at = { coords = FAR }, label = '[TEST] off', group = '_t_ia',
                                  enabled = false, onSelect = NOOP })), 'added')
                local a = get('_t_off')
                assertFalse(a.enabled, 'GetAction says it is off')
                assertFalse(a.options[1].offered, 'and it is not offered')
                assertEqual(a.options[1].why, 'switched off', 'with the reason')

                assertTrue((exports.whip_core:UpdateAction('_t_off', { enabled = true })), 'switched on')
                assertTrue(opt1('_t_off').offered, 'offered again')
                exports.whip_core:RemoveAction('_t_off')
            end,
        },

        -- ==========================================
        -- The other `at` kinds of the prompt engines
        -- ==========================================
        {
            name = 'at = { entity } rides an entity; when the entity is gone the action says so',
            fn = function(ctx)
                local model = GetHashKey('prop_cs_cardbox_01')
                RequestModel(model)
                if not waitFor(function() return HasModelLoaded(model) end, 3000) then skip('the box model did not load') end
                local pos = GetEntityCoords(PlayerPedId())
                local obj = CreateObject(model, pos.x + 2.0, pos.y, pos.z - 0.9, false, false, false)
                SetModelAsNoLongerNeeded(model)
                ctx.obj = obj
                -- A native's yes is 1 on the client, not true: read it the FiveM way (nil/false/0 = no).
                -- No box is a setup failure, not a result, so it skips.
                local exists = DoesEntityExist(obj)
                if obj == 0 or not exists or exists == 0 then skip('the box to ride on could not be made') end

                local ok, why = added({ id = '_t_entity', at = { entity = obj, offset = vector3(0.0, 0.0, 0.5) },
                                      label = '[TEST] on a box', group = '_t_ia', onSelect = NOOP })
                assertTrue(ok, 'added (' .. tostring(why) .. ')')
                local a = get('_t_entity')
                assertEqual(a.mounted, 'prompt', 'a prompt')
                assertEqual(a.at.entity, obj, 'on that entity')
                assertEqual(a.at.offset and a.at.offset.z, 0.5, 'with its offset')
                assertTrue(a.options[1].offered, 'offered while the box is there')

                DeleteEntity(obj)
                ctx.obj = nil
                assertTrue(waitFor(function() return opt1('_t_entity').why == 'entity gone' end, 2000) == true,
                    'once the box is gone, GetAction says "entity gone"')
                exports.whip_core:RemoveAction('_t_entity')
            end,
        },
        {
            name = 'at = { vehiclePart } puts it on a car part\'s prompt; several options are one entry each',
            fn = function()
                local ok, why = added({ id = '_t_part', at = { vehiclePart = 'hood' }, label = '[TEST] Check the oil',
                                      icon = 'hood_open', group = '_t_ia', onSelect = NOOP })
                assertTrue(ok, 'added (' .. tostring(why) .. ')')
                local a = get('_t_part')
                assertEqual(a.mounted, 'part', 'mounted on a car part')
                assertEqual(a.engineIds[1], 'act:whip_test:_t_part', 'as act:<resource>:<id>')
                assertEqual(a.at.vehiclePart, 'hood', 'the hood')

                assertTrue((added({ id = '_t_part_multi', at = { vehiclePart = 'trunk' }, group = '_t_ia', onSelect = NOOP,
                                  options = { { id = 'a', label = '[TEST] A' }, { id = 'b', label = '[TEST] B' } } })),
                    'added (two options)')
                local m = get('_t_part_multi')
                assertEqual(m.mounted, 'part', 'mounted')
                assertEqual(#m.engineIds, 2, 'one entry per option')
                assertEqual(m.engineIds[1], 'act:whip_test:_t_part_multi#a', 'the first, named by option')
                assertEqual(m.engineIds[2], 'act:whip_test:_t_part_multi#b', 'the second')

                -- A part that does not exist must never read as live. Today AddAction accepts it and
                -- GetAction shows it did not mount; if AddAction starts refusing it, that is right too.
                local okBad, r = add({ id = '_t_part_bad', at = { vehiclePart = '_no_such_part' }, label = '[TEST] x',
                                       group = '_t_ia', onSelect = NOOP })
                if okBad then
                    local b = get('_t_part_bad')
                    assertEqual(b and b.mounted, false, 'an unknown part is not mounted, and GetAction says so')
                else
                    assertTrue(has(r, '_no_such_part'), 'or AddAction refuses it, naming the part (got: ' .. tostring(r) .. ')')
                end
            end,
        },

        -- ==========================================
        -- The live loop
        -- ==========================================
        {
            name = 'The live loop asks a prompt in front of you (with ctx.typed on its ctx), and keeps going past one whose canInteract throws',
            fn = function()
                promptsCanRun()
                local healthy = loopProbe()
                local hx, hy, hz = inFrontOfTester(1.2)
                assertTrue((added({ id = '_t_live_ok', at = { coords = vector3(hx, hy, hz) }, label = '[TEST] healthy',
                                  group = '_t_ia_live', focusMode = 'near', reach = 3.0, seeFrom = 6.0,
                                  canInteract = healthy.fn, onSelect = NOOP })), 'healthy prompt added')
                awaitLoop(healthy, hx, hy, hz)

                -- ctx.typed: what is being typed into this prompt, for a label to show. Nothing is.
                assertTrue(healthy.typedOk, 'ctx.typed is a value (text or false), not a function')
                assertEqual(healthy.typedValue, false, 'and is false while nothing is being typed')
                assertEqual(healthy.ctx.id, '_t_live_ok', 'the loop\'s ctx names the action')
                assertEqual(healthy.ctx.owner, 'whip_test', 'and its owner')

                -- NEARER than the healthy one, and throwing every time it is asked.
                local thrown = 0
                local bx, by, bz = inFrontOfTester(0.9)
                assertTrue((added({ id = '_t_live_boom', at = { coords = vector3(bx, by, bz) }, label = '[TEST] throws',
                                  group = '_t_ia_live', focusMode = 'near', reach = 3.0, seeFrom = 6.0, onSelect = NOOP,
                                  canInteract = function(c)
                                      if c and c.typed ~= nil then thrown = thrown + 1 end
                                      error('deliberate test throw')
                                  end })), 'throwing prompt added')
                assertTrue(waitFor(function() return thrown >= 2 end, 2000) == true, 'the loop reached the thrower')

                local before = healthy.loop
                assertTrue(waitFor(function() return healthy.loop >= before + 3 end, 2000) == true,
                    'after the throws the loop still asks the healthy prompt — it did not die')
                assertEqual(opt1('_t_live_boom').why, 'canInteract threw', 'and GetAction says why the thrower is hidden')

                assertTrue((exports.whip_core:RemoveActionGroup('_t_ia_live')), 'removed')
            end,
        },
    },
})
