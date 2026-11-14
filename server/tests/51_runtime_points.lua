-- ============================================
-- Runtime Points & NPCs (server) — the Director's first foundations (2 Oct 2026)
-- ============================================
--
-- Two whip_core modules a resource drives from the server, both owned by their caller and released
-- with a run's tag:
--
--   * RUNTIME POINTS (server/runtime_points.lua): AddPoint / UpdatePoint / RemovePoint / ListPoints.
--     A press is the tester's own (ClientExecWait on whip_core:server:useRuntimePoint), so the
--     distance, audience and requirement checks are the real ones, and onUse is whip_test's function
--     crossing back over the export.
--   * NPCS (server/npcs.lua): SpawnNpc / GetNpc / ListNpcs / SetNpcState / DespawnNpc, and a point
--     riding an NPC by netId.
--
-- Each run uses a fresh tag: a released tag stays closed to its owner until that owner stops.
--
-- NOT COVERED, and what it would need:
--   * the point mounted on the client, and the NPC's brain applied there (a client module that
--     reads whip_core's own actions and the ped's tasks);
--   * the NPC fighting, dying and its killer (a second player, or a damage seam).

local uses = {}

local function has(s, fragment)
    return type(s) == 'string' and s:find(fragment, 1, true) ~= nil
end

local function onUse(src, use)
    uses[#uses + 1] = { src = src, use = use }
    if use.option == 'refuse' then return false, '[TEST] refused by onUse' end
    if use.option == 'throw' then error('deliberate onUse throw') end
end

--- Press E on a runtime point, as the tester: one press per 500 ms, then wait for the answer.
local function press(source, pointId, optionId)
    Wait(600)
    assertTrue(ClientExecWait(source, 'whip_core:server:useRuntimePoint', 3000, pointId, optionId or ''),
        'the server answered the press')
end

--- AddPoint, remembered for teardown.
local function add(ctx, def)
    local id, why = exports.whip_core:AddPoint(def)
    if id then ctx.points[#ctx.points + 1] = id end
    return id, why
end

local function near(ctx, over)
    local d = {
        at = { coords = vector3(ctx.pos.x + 0.5, ctx.pos.y, ctx.pos.z) },
        label = '[TEST] point', reach = 3.0, onUse = onUse,
        options = { { id = 'ok', label = 'OK' }, { id = 'refuse', label = 'Refuse' }, { id = 'throw', label = 'Throw' } },
    }
    for k, v in pairs(over or {}) do d[k] = v end
    return d
end

RegisterTestModule({
    order    = 51,
    category = 'Runtime Points',
    setup = function(source, ctx)
        local pos = GetEntityCoords(GetPlayerPed(source))
        ctx.pos = { x = pos.x, y = pos.y, z = pos.z }
        ctx.points = {}
        ctx.tag = ('_test_rp:%d'):format(GetGameTimer())
    end,
    teardown = function(ctx)
        for _, id in ipairs(ctx.points or {}) do pcall(exports.whip_core.RemovePoint, exports.whip_core, id) end
        if ctx.npc then pcall(exports.whip_core.DespawnNpc, exports.whip_core, ctx.npc) end
        if ctx.tag then pcall(exports.whip_core.ReleaseTag, exports.whip_core, ctx.tag) end
    end,
    tests = {
        {
            name = 'AddPoint refuses what it cannot use, and says why',
            fn = function(_, ctx)
                local here = vector3(ctx.pos.x, ctx.pos.y, ctx.pos.z)
                local cases = {
                    { def = { at = { coords = here } },                                              why = 'onUse' },
                    { def = { at = { coords = here, netId = 1 }, onUse = onUse },                     why = 'one place' },
                    { def = { at = { coords = vector3(0, 0, 99999) }, onUse = onUse },                why = 'on the map' },
                    { def = near(ctx, { require = { jobs = 'police' } }),                             why = 'require.jobs' },
                    { def = near(ctx, { require = { zone = '_whip_test_no_zone' } }),                 why = 'not a saved zone' },
                    { def = near(ctx, { options = { { id = 'a' }, { id = 'a' } } }),                   why = 'two options' },
                    { def = near(ctx, { audience = { people = { 'someone' } } }),                     why = 'a person is' },
                    { def = near(ctx, { icon = 'not a glyph!' }),                                     why = 'glyph' },
                }
                for i, c in ipairs(cases) do
                    local id, why = add(ctx, c.def)
                    assertFalse(id, ('case %d is refused'):format(i))
                    assertTrue(has(why, c.why), ('case %d says "%s" (got: %s)'):format(i, c.why, tostring(why)))
                end
            end,
        },
        {
            name = 'A press runs onUse on the server with the point, the option and a useId; its answer reaches the player',
            fn = function(source, ctx)
                local id, why = add(ctx, near(ctx, { tag = ctx.tag }))
                assertOk(id, why, 'AddPoint')
                assertTrue(id > 4294967296, 'a runtime id is above 2^32')
                ctx.pointA = id

                local before = #uses
                press(source, id, 'ok')
                assertLastReject('whip_core:server:useRuntimePoint', nil, 'the press was accepted')
                assertEqual(#uses, before + 1, 'onUse ran once')
                local u = uses[#uses]
                assertEqual(u.src, source, 'with the player\'s source')
                assertEqual(u.use.pointId, id, 'the point')
                assertEqual(u.use.option, 'ok', 'the option chosen')
                assertType(u.use.useId, 'number', 'and a useId')

                press(source, id, 'refuse')
                assertLastReject('whip_core:server:useRuntimePoint', '[TEST] refused by onUse', 'onUse answering false, why')
                press(source, id, 'throw')
                assertLastReject('whip_core:server:useRuntimePoint', 'Something went wrong', 'onUse throwing')
                press(source, id, 'nope')
                assertLastReject('whip_core:server:useRuntimePoint', 'That is not available', 'an option it does not have')
                press(source, id, '')
                assertLastReject('whip_core:server:useRuntimePoint', 'That is not available', 'no option named, of three')
            end,
        },
        {
            name = 'The audience, requirements and reach are the server\'s: each refuses with its reason',
            fn = function(source, ctx)
                local id = ctx.pointA
                if not id then skip('the point from the test above was not made') end

                assertTrue((exports.whip_core:UpdatePoint(id, { audience = { people = { { charId = 999999999 } } } })), 'audience: someone else')
                press(source, id, 'ok')
                assertLastReject('whip_core:server:useRuntimePoint', 'That is not for you', 'not in the audience')
                assertTrue((exports.whip_core:UpdatePoint(id, { audience = { people = { source } } })), 'audience: the tester')
                press(source, id, 'ok')
                assertLastReject('whip_core:server:useRuntimePoint', nil, 'in the audience')

                local onFoot = GetVehiclePedIsIn(GetPlayerPed(source), false) == 0
                assertTrue((exports.whip_core:UpdatePoint(id, { require = { vehicle = onFoot and 'in' or 'out' } })), 'a requirement')
                press(source, id, 'ok')
                assertLastReject('whip_core:server:useRuntimePoint',
                    onFoot and 'You need to be in a vehicle' or 'Get out of the vehicle first', 'the point\'s requirement')
                assertTrue((exports.whip_core:UpdatePoint(id, { require = false })), 'requirement cleared')

                assertTrue((exports.whip_core:UpdatePoint(id, {
                    options = { { id = 'ok', label = 'OK', require = { item = '_whip_test_no_item' } } } })), 'an option requirement')
                press(source, id, 'ok')
                assertLastReject('whip_core:server:useRuntimePoint', 'You need _whip_test_no_item', 'the option\'s requirement')
                assertTrue((exports.whip_core:UpdatePoint(id, { options = { { id = 'ok', label = 'OK' } } })), 'option cleared')

                assertTrue((exports.whip_core:UpdatePoint(id, {
                    at = { coords = vector3(ctx.pos.x + 12.0, ctx.pos.y, ctx.pos.z) }, reach = 1.0 })), 'moved away')
                press(source, id, 'ok')
                assertLastReject('whip_core:server:useRuntimePoint', 'Too far away', 'beyond its reach')
                assertTrue((exports.whip_core:UpdatePoint(id, {
                    at = { coords = vector3(ctx.pos.x + 0.5, ctx.pos.y, ctx.pos.z) }, reach = 3.0 })), 'moved back')

                assertTrue((exports.whip_core:UpdatePoint(id, { enabled = false })), 'switched off')
                press(source, id, 'ok')
                assertLastReject('whip_core:server:useRuntimePoint', 'That is not available', 'a switched-off point')
                assertTrue((exports.whip_core:UpdatePoint(id, { enabled = true })), 'switched on')
                press(source, id, 'ok')
                assertLastReject('whip_core:server:useRuntimePoint', nil, 'and it works again')

                local okT, whyT = exports.whip_core:UpdatePoint(id, { tag = '_test_other' })
                assertFalse(okT, 'the tag cannot change')
                assertTrue(has(whyT, 'tag'), 'and it says so (got: ' .. tostring(whyT) .. ')')
            end,
        },
        {
            name = 'ListPoints by tag; ReleaseTag removes them and closes the tag; RemovePoint, then a press is refused',
            fn = function(source, ctx)
                local id = ctx.pointA
                if not id then skip('the point from the tests above was not made') end

                local list = exports.whip_core:ListPoints({ tag = ctx.tag })
                assertEqual(#list, 1, 'ListPoints by tag finds it')
                assertEqual(list[1].pointId, id, 'by its id')
                assertNil(list[1].onUse, 'without its onUse')

                local untagged, why = add(ctx, near(ctx))
                assertOk(untagged, why, 'an untagged point')
                local ok, n = exports.whip_core:ReleaseTag(ctx.tag)
                assertTrue(ok, 'ReleaseTag answered')
                assertTrue((n or 0) >= 1, 'and removed what was tagged')
                press(source, id, 'ok')
                assertLastReject('whip_core:server:useRuntimePoint', 'That is not available', 'a released point')
                local again, whyAgain = exports.whip_core:AddPoint(near(ctx, { tag = ctx.tag }))
                assertFalse(again, 'a released tag refuses new points')
                assertTrue(has(whyAgain, 'has ended'), 'and says so (got: ' .. tostring(whyAgain) .. ')')
                ctx.tag = nil

                press(source, untagged, 'ok')
                assertLastReject('whip_core:server:useRuntimePoint', nil, 'the untagged point was left alone')
                assertTrue((exports.whip_core:RemovePoint(untagged)), 'RemovePoint')
                press(source, untagged, 'ok')
                assertLastReject('whip_core:server:useRuntimePoint', 'That is not available', 'a removed point')
                local okR = exports.whip_core:RemovePoint(untagged)
                assertFalse(okR, 'removing it again is refused')
            end,
        },
        {
            name = 'NPCs: SpawnNpc refuses bad definitions; spawns one, GetNpc and ListNpcs read it, SetNpcState changes it',
            fn = function(_, ctx)
                local here = { x = ctx.pos.x + 1.5, y = ctx.pos.y, z = ctx.pos.z, heading = 0.0 }
                local cases = {
                    { def = { model = 'bad model!', coords = here },                             why = 'model' },
                    { def = { model = 's_m_y_dealer_01' },                                        why = 'coords' },
                    { def = { model = 's_m_y_dealer_01', coords = here, behaviour = 'dance' },   why = 'behaviour' },
                    { def = { model = 's_m_y_dealer_01', coords = here, weapon = 'pistol' },      why = 'WEAPON_' },
                }
                for i, c in ipairs(cases) do
                    local id, why = exports.whip_core:SpawnNpc(c.def)
                    assertFalse(id, ('case %d is refused'):format(i))
                    assertTrue(has(why, c.why), ('case %d says "%s" (got: %s)'):format(i, c.why, tostring(why)))
                end
                local idE, whyE = exports.whip_core:SpawnNpc({ model = 's_m_y_dealer_01', coords = here }, { hostileTo = 'everyone' })
                assertFalse(idE, 'an NPC is never hostile to everyone')
                assertTrue(has(whyE, 'everyone'), 'and it says so (got: ' .. tostring(whyE) .. ')')

                local npcId, netId = exports.whip_core:SpawnNpc({ model = 's_m_y_dealer_01', coords = here, behaviour = 'stand',
                    conditions = { invincible = true } })
                assertOk(npcId, netId, 'SpawnNpc')
                ctx.npc, ctx.npcNet = npcId, netId
                local info = exports.whip_core:GetNpc(npcId)
                assertNotNil(info, 'GetNpc reads it')
                assertEqual(info.owner, 'whip_test', 'as ours')
                assertEqual(info.netId, netId, 'with its netId')
                assertTrue(info.alive, 'alive')
                assertEqual(info.conditions.invincible, true, 'with its conditions')
                assertEqual(exports.whip_core:GetNpcBy('netId', netId), npcId, 'GetNpcBy finds it by netId')

                local mine = false
                for _, n in ipairs(exports.whip_core:ListNpcs()) do if n.npcId == npcId then mine = true end end
                assertTrue(mine, 'ListNpcs lists it')

                local ok, why = exports.whip_core:SetNpcState(npcId, { behaviour = 'guard' })
                assertTrue(ok, 'SetNpcState (' .. tostring(why) .. ')')
                assertEqual(exports.whip_core:GetNpc(npcId).behaviour, 'guard', 'the change is read back')
                local okB = exports.whip_core:SetNpcState(npcId, { behaviour = 'fly' })
                assertFalse(okB, 'a bad change is refused')
            end,
        },
        {
            name = 'A point riding an NPC by netId is pressed where the NPC is; DespawnNpc removes the NPC',
            fn = function(source, ctx)
                if not ctx.npc then skip('the NPC from the test above was not made') end
                local id, why = add(ctx, { at = { netId = ctx.npcNet, offset = vector3(0.0, 0.0, 0.3) },
                    label = '[TEST] talk', reach = 3.0, onUse = onUse })
                assertOk(id, why, 'AddPoint on the NPC')
                local before = #uses
                press(source, id, '')
                assertLastReject('whip_core:server:useRuntimePoint', nil, 'the press on the NPC was accepted')
                assertEqual(#uses, before + 1, 'onUse ran')
                assertEqual(uses[#uses].use.netId, ctx.npcNet, 'and was told which entity')
                assertEqual(uses[#uses].use.option, 'default', 'a point with no options has the one, "default"')

                -- A conversation, opened from that press (the dialog capsule shows for a moment).
                local useId = uses[#uses].use.useId
                local okN, whyN = exports.whip_core:StartConversation(source, { npcId = ctx.npc, line = 'x',
                    options = { { id = 'a', label = 'A' } } })
                assertFalse(okN, 'a conversation without a press is refused')
                assertTrue(has(whyN, 'not from an interaction'), 'and says so (got: ' .. tostring(whyN) .. ')')
                local chose, ended = {}, {}
                local convId, whyC = exports.whip_core:StartConversation(source, {
                    fromUse = useId, npcId = ctx.npc, speaker = '[TEST]', line = '[TEST] Got the goods?',
                    options = { { id = 'yes', label = 'Here.' }, { id = 'bye', label = 'Leave', ends = true } },
                    next = { yes = { line = '[TEST] Let me see.', options = { { id = 'bye', label = 'Leave', ends = true } } } },
                    onChoose = function(_, answer) chose[#chose + 1] = answer end,
                    onEnd = function(_, why) ended[#ended + 1] = why end,
                })
                assertOk(convId, whyC, 'StartConversation from the press')
                local conv = exports.whip_core:GetConversation(convId)
                assertEqual(conv and conv.line, '[TEST] Got the goods?', 'GetConversation reads what is said')
                Wait(300)
                assertTrue(ClientExecWait(source, 'whip_core:server:conversationChoice', 3000, convId, 'yes'), 'the answer was heard')
                assertLastReject('whip_core:server:conversationChoice', nil, 'an answer on screen is accepted')
                assertEqual(chose[#chose], 'yes', 'onChoose heard it')
                assertEqual(exports.whip_core:GetConversation(convId).line, '[TEST] Let me see.', 'the reply sent ahead is now said')
                Wait(300)
                assertTrue(ClientExecWait(source, 'whip_core:server:conversationChoice', 3000, convId, 'nope'), 'answered')
                assertLastReject('whip_core:server:conversationChoice', 'That is not an answer now', 'an answer not on screen')
                Wait(300)
                assertTrue(ClientExecWait(source, 'whip_core:server:conversationChoice', 3000, convId, 'bye'), 'answered')
                assertNil(exports.whip_core:GetConversation(convId), 'an answer that ends it ends it')
                assertTrue(waitFor(function() return ended[1] ~= nil end, 2000) == true, 'onEnd was told')
                assertEqual(ended[1], 'chose', 'that it ended on an answer')

                assertTrue((exports.whip_core:DespawnNpc(ctx.npc)), 'DespawnNpc')
                assertNil(exports.whip_core:GetNpc(ctx.npc), 'GetNpc no longer reads it')
                ctx.npc = nil
                local gone = waitFor(function()
                    return NetworkGetEntityFromNetworkId(ctx.npcNet) == 0 or not DoesEntityExist(NetworkGetEntityFromNetworkId(ctx.npcNet))
                end, 5000)
                assertTrue(gone == true, 'the ped leaves the world within the retire\'s 3 s')
                press(source, id, '')
                assertLastReject('whip_core:server:useRuntimePoint', 'That is not available', 'and a point on it is refused')
            end,
        },
    },
})
