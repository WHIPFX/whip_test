-- ============================================
-- Stats and effects
--
-- WHY THIS MODULE EXISTS
--
-- Stats are whip's numeric player state — hunger, thirst, stress, and whatever a satellite
-- declares. Effects are timed modifiers layered on top: a painkiller that halves incoming
-- damage, a stimulant that drains thirst faster. Eight exports, no tests.
--
-- TWO PROPERTIES ARE WORTH MORE THAN THE REST
--
--   1. A REGISTERED stat CLAMPS to its declared min and max, and an UNREGISTERED one is REFUSED.
--      Clamping is what stops a satellite writing hunger = 5000 and a HUD bar rendering off the
--      side of the screen. The unregistered path used to store the value unvalidated, which this
--      module once pinned as deliberate — but it was never SAVED (saving walks the registry), so a
--      counter kept that way vanished at logout and a typo looked like it worked. Refused since
--      24 Sep 2026 (STAT-3); a satellite wanting a counter registers it with a wide range.
--
--   2. Effects combine MULTIPLICATIVELY into the damage modifier that reaches the statebag.
--      That modifier is read by other clients to scale outgoing damage, which is exactly why
--      it is Sentinel-watched — whip_core's own comment calls a spoofed one "a self-service
--      damage-resistance cheat". An effect that failed to remove, or a modifier that failed to
--      recombine after removal, is permanent invulnerability that nothing would report.
--
-- Nothing here touches health or armour: they are whip_core's own reserved stats, and driving
-- them on a live tester is a good way to kill the person running the suite.
-- ============================================

local STAT   = '_test_stat_fuel'
local FREE   = '_test_stat_unregistered'
local CARRY  = '_test_stat_carry'
local EFFECT = '_test_effect_armour'

--- OnStatChange listeners (STAT-4) cannot be taken back off — they go when whip_test stops — so
--- every one this module registers reads this first and does nothing unless a test is running it.
--- `calls` collects what they heard.
local _listen = { on = false, calls = {} }

--- Start hearing: clear what was heard and switch the listeners on.
local function listenStart()
    _listen.calls = {}
    _listen.on = true
end

--- The calls heard for one player and stat, in order — only those from listener `via`.
local function heard(source, name, via)
    local out = {}
    for _, c in ipairs(_listen.calls) do
        if c.source == source and c.key == name and c.via == via then out[#out + 1] = c end
    end
    return out
end

--- A positional listener that records into _listen under `via` while listening is on.
local function recorder(via, name)
    return function(src, value, old, reason)
        if not _listen.on then return end
        _listen.calls[#_listen.calls + 1] = { via = via, source = src, key = name, value = value, old = old, reason = reason }
    end
end

--- The damage-modifier statebag key (shared/statebags.lua PLAYER_DMGMOD_KEY). A string here
--- because whip_core's globals do not cross into this resource.
local DMG_KEY = 'whipDamageMod'

--- One stat out of the tester's `statuses` column, flushed first.
local function statusOnDisk(charId, name)
    FlushPersistence()
    local rows = DbQuery(
        ("SELECT JSON_UNQUOTE(JSON_EXTRACT(`statuses`, '$.%s')) AS v FROM `characters` WHERE `charId` = ?"):format(name),
        { charId })
    return rows[1] and tonumber(rows[1].v) or nil
end

--- Take CARRY back out of the tester's row for good.
---
--- A persisted stat that is then unregistered is CARRIED FORWARD on every save — that is the rule
--- under test — so simply unregistering it would leave it in the tester's `statuses` forever.
--- Re-registered as persist = false it is dropped on the next row write; unregistered after that,
--- nothing remembers it.
local function purgeCarry(source)
    pcall(exports.whip_core.RegisterStat, exports.whip_core, CARRY,
        { type = 'custom', default = 0, min = 0, max = 100, persist = false })
    pcall(exports.whip_core.SetPlayerMetadata, exports.whip_core, source, '_test_carry_mark', GetGameTimer())
    pcall(FlushPersistence)
    pcall(exports.whip_core.SetPlayerMetadata, exports.whip_core, source, '_test_carry_mark', nil)
    pcall(exports.whip_core.__TestUnregisterStat, exports.whip_core, CARRY)
end

RegisterTestModule({
    order    = 39,
    category = 'Stats & Effects',

    setup = function(source, ctx)
        -- (A `if not exports.whip_core.RegisterStat then skip() end` guard used to open this. It
        -- could never fire — indexing a missing export raises rather than answering nil.)

        -- EVERY value test below depends on this player having a stats cache. Without one SetStat
        -- answers `false, 'Player not loaded'` and GetAllStats `{}, 'Player not loaded'`, so the whole
        -- module would fail on assertions about clamping and deltas while the real problem was that
        -- the tester had no cache at all. Ask once, here, and say so plainly.
        local _, noCache = exports.whip_core:GetAllStats(source)
        if noCache then
            skip('this player has no stats cache — nothing below can be measured')
        end

        -- persist = false: this is a fixture, and a stat that writes itself into the tester's
        -- character row would outlive the run.
        local ok, err = exports.whip_core:RegisterStat(STAT, {
            type = 'custom', default = 50, min = 0, max = 100, persist = false,
        })
        if ok == false then
            -- A previous run in this session registered it too — the same owner, which the registry
            -- answers true for. A refusal here is a DIFFERENT owner holding the name (or a bad
            -- definition): a real clash, which should stop the module rather than be tested around.
            skip('could not register the fixture stat: ' .. tostring(err))
        end

        ctx.charId = exports.whip_core:GetPlayer(source).charId
    end,

    teardown = function(ctx, source)
        _listen.on = false
        if source then
            pcall(exports.whip_core.RemoveEffect, exports.whip_core, source, EFFECT)
            pcall(exports.whip_core.RemoveEffect, exports.whip_core, source, EFFECT .. '_2')
            pcall(exports.whip_core.SetStat, exports.whip_core, source, STAT, 50)

            -- (FREE, the unregistered name, needs no cleanup any more: since STAT-3 a write to an
            -- unregistered stat is refused and never cached, so there is nothing to clear.)

            if ctx.carryUsed then purgeCarry(source) end
        end
    end,

    tests = {
        -- ==========================================
        -- Registration
        -- ==========================================
        {
            name = 'A stat registers, and re-registering by the SAME owner is allowed',
            fn = function(source, ctx)
                -- Re-registration by the owner is how a satellite reload works. Refusing it
                -- would make every hot reload a full restart.
                local ok, err = exports.whip_core:RegisterStat(STAT, {
                    type = 'custom', default = 50, min = 0, max = 100, persist = false,
                })
                assertTrue(ok, 'the owner may re-register its own stat: ' .. tostring(err))
            end,
        },
        {
            name = "whip_core's reserved stats cannot be redefined by a satellite",
            fn = function(source, ctx)
                -- health and armour are the two the engine itself applies to the ped. A
                -- satellite redefining their min/max would be redefining what "dead" means.
                for _, reserved in ipairs({ 'health', 'armour' }) do
                    local ok, err = exports.whip_core:RegisterStat(reserved, { min = 0, max = 1 })
                    assertFalse(ok, ('"%s" is refused'):format(reserved))
                    assertTrue(tostring(err):find('whip_core', 1, true) ~= nil,
                        ('and names the owner (got "%s")'):format(tostring(err)))
                end
            end,
        },
        {
            name = 'A malformed stat registration is refused with a reason',
            fn = function(source, ctx)
                local ok1, e1 = exports.whip_core:RegisterStat('', { min = 0, max = 1 })
                assertFalse(ok1, 'an empty name is refused')
                assertNotNil(e1, 'with a reason')

                local ok2, e2 = exports.whip_core:RegisterStat('_test_stat_nocfg', 'not a table')
                assertFalse(ok2, 'a non-table config is refused')
                assertNotNil(e2, 'with a reason')
            end,
        },

        -- ==========================================
        -- Values
        -- ==========================================
        {
            name = 'SetStat then GetStat round-trips',
            fn = function(source, ctx)
                exports.whip_core:SetStat(source, STAT, 70)
                assertEqual(exports.whip_core:GetStat(source, STAT), 70, 'the value reads back')
            end,
        },
        {
            name = 'AddStat applies a delta rather than assigning',
            fn = function(source, ctx)
                exports.whip_core:SetStat(source, STAT, 40)
                exports.whip_core:AddStat(source, STAT, 15)
                assertEqual(exports.whip_core:GetStat(source, STAT), 55, 'delta added')

                exports.whip_core:AddStat(source, STAT, -20)
                assertEqual(exports.whip_core:GetStat(source, STAT), 35, 'and a negative delta subtracts')
            end,
        },
        {
            name = 'A REGISTERED stat clamps to its declared range',
            fn = function(source, ctx)
                -- The reason min/max are on the registration at all. Without this a satellite
                -- writing 5000 leaves a HUD bar rendering off the edge of the screen, and a
                -- negative value can make a threshold comparison behave backwards.
                exports.whip_core:SetStat(source, STAT, 100000)
                assertEqual(exports.whip_core:GetStat(source, STAT), 100, 'clamped to max')

                exports.whip_core:SetStat(source, STAT, -100000)
                assertEqual(exports.whip_core:GetStat(source, STAT), 0, 'clamped to min')

                -- AddStat goes through the same clamp — a satellite adding in a loop must not
                -- be able to walk past the ceiling one step at a time.
                exports.whip_core:SetStat(source, STAT, 95)
                exports.whip_core:AddStat(source, STAT, 50)
                assertEqual(exports.whip_core:GetStat(source, STAT), 100, 'AddStat clamps too')
            end,
        },
        {
            -- STAT-3, 24 Sep 2026. This test used to pin the opposite ("stored unvalidated —
            -- deliberately"). The value was cached and shown but never saved, so it lasted one
            -- session: a satellite's counter vanished at logout, and a typo looked like it worked.
            name = 'An UNREGISTERED stat is refused, not kept for one session',
            fn = function(source, ctx)
                local ok, err = exports.whip_core:SetStat(source, FREE, 4321)
                assertFalse(ok, 'SetStat on a name nobody registered is refused')
                assertEqual(err, ('no stat named "%s" (RegisterStat it first)'):format(FREE), 'saying what to do')
                assertNil(exports.whip_core:GetStat(source, FREE), 'and nothing was stored')

                local ok2 = exports.whip_core:AddStat(source, FREE, 1)
                assertFalse(ok2, 'AddStat is refused the same way')
            end,
        },
        {
            name = 'SetStat, AddStat and RemoveEffect answer, and refuse what they cannot use',
            fn = function(source, ctx)
                -- They returned nothing (STAT-3), and a bad value threw inside the CALLER.
                assertOk(exports.whip_core:SetStat(source, STAT, 70, 't39 reason'))
                assertOk(exports.whip_core:AddStat(source, STAT, 5, 't39 reason'))
                assertEqual(exports.whip_core:GetStat(source, STAT), 75, 'both landed')

                local cases = {
                    { call = function() return exports.whip_core:SetStat(source, STAT, 'abc') end, why = 'value must be a number',  label = 'a string value' },
                    { call = function() return exports.whip_core:SetStat(source, STAT, 0/0) end,   why = 'value must be a number',  label = 'NaN' },
                    { call = function() return exports.whip_core:SetStat(source, STAT, math.huge) end, why = 'value must be a number', label = 'infinity' },
                    { call = function() return exports.whip_core:AddStat(source, STAT, nil) end,   why = 'amount must be a number', label = 'a nil delta' },
                    { call = function() return exports.whip_core:SetStat(99999, STAT, 1) end,       why = 'Player not loaded',       label = 'a player who is not here' },
                }
                for _, case in ipairs(cases) do
                    local ok, why = case.call()
                    assertFalse(ok, case.label .. ' is refused')
                    assertEqual(why, case.why, case.label .. ' says why')
                end
                assertEqual(exports.whip_core:GetStat(source, STAT), 75, 'and none of them moved the value')

                local okR, whyR = exports.whip_core:RemoveEffect(source, '_test_effect_never_applied')
                assertFalse(okR, 'removing an effect the player does not have answers false')
                assertNotNil(whyR, 'with a reason')
                assertTrue(exports.whip_core:ApplyEffect(source, EFFECT, { duration = 60 }), 'applied')
                assertTrue(exports.whip_core:RemoveEffect(source, EFFECT), 'and a real removal answers true')
            end,
        },
        {
            name = 'GetAllStats includes what was set',
            fn = function(source, ctx)
                exports.whip_core:SetStat(source, STAT, 60)
                local all = exports.whip_core:GetAllStats(source)
                assertNotNil(all, 'the stat set reads back')
                assertEqual(all[STAT], 60, 'and carries the fixture stat')
            end,
        },
        {
            -- A satellite being stopped must not cost every player its saved value: a persisted
            -- stat whose owner is not registered right now is CARRIED FORWARD on each save. The
            -- carry-forward used to read only what the column held at LOGIN — so a stat first saved
            -- this session had nothing to carry, and the next save after its resource stopped
            -- wrote the column without it.
            name = 'A persisted stat first saved this session survives its owner unregistering',
            fn = function(source, ctx)
                ctx.carryUsed = true
                local ok, err = exports.whip_core:RegisterStat(CARRY,
                    { type = 'custom', default = 0, min = 0, max = 100, persist = true })
                assertTrue(ok ~= false, 'fixture stat registered as persisted: ' .. tostring(err))

                exports.whip_core:SetStat(source, CARRY, 42)
                assertEqual(statusOnDisk(ctx.charId, CARRY), 42, 'the value reached the row while registered')

                -- The owner "stops": the stat leaves the registry (and the seam drops the cached
                -- value too, so only the carry-forward can put it back).
                assertTrue(exports.whip_core:__TestUnregisterStat(CARRY), 'unregistered')

                -- Something else changes the row, so it is written again without the stat registered.
                assertTrue(exports.whip_core:SetPlayerMetadata(source, '_test_carry_mark', GetGameTimer()),
                    'row marked for another write')
                assertEqual(statusOnDisk(ctx.charId, CARRY), 42,
                    'the next save CARRIED the value forward rather than dropping it')

                purgeCarry(source)
                ctx.carryUsed = false
                assertNil(statusOnDisk(ctx.charId, CARRY), 'and the fixture is out of the row again')
            end,
        },

        -- ==========================================
        -- Listening on the server (STAT-4)
        -- ==========================================
        {
            -- The server had no way to hear a stat change; a satellite had to poll.
            name = 'OnStatChange hears a change on the server: who, the new value, the old, and why',
            fn = function(source, ctx)
                assertOk(exports.whip_core:SetStat(source, STAT, 40))
                assertOk(exports.whip_core:OnStatChange(STAT, recorder('named', STAT), '_t39_named'))

                listenStart()
                assertOk(exports.whip_core:SetStat(source, STAT, 55, 't39 set'))
                local got = heard(source, STAT, 'named')
                _listen.on = false
                assertEqual(#got, 1, 'called once, before SetStat returned (it runs inside the change)')
                assertEqual(got[1] and got[1].value, 55, 'with the new value')
                assertEqual(got[1] and got[1].old, 40, 'the old one')
                assertEqual(got[1] and got[1].reason, 't39 set', 'and the reason given')

                listenStart()
                assertOk(exports.whip_core:SetStat(source, STAT, 55))
                assertEqual(#heard(source, STAT, 'named'), 0, 'setting the value it already holds is not a change')
                assertOk(exports.whip_core:AddStat(source, STAT, 1))
                local g2 = heard(source, STAT, 'named')
                _listen.on = false
                assertEqual(g2[1] and g2[1].reason, 'by whip_test', 'with no reason given, it says who')
            end,
        },
        {
            name = "OnStatChange('*', ..., { table = true }) hears every stat, as one table",
            fn = function(source, ctx)
                assertOk(exports.whip_core:OnStatChange('*', function(change)
                    if not _listen.on or type(change) ~= 'table' then return end
                    _listen.calls[#_listen.calls + 1] = { via = 'star', source = change.source, key = change.key,
                        value = change.value, old = change.old, reason = change.reason }
                end, '_t39_star', { table = true }))

                assertOk(exports.whip_core:SetStat(source, STAT, 20))
                listenStart()
                assertOk(exports.whip_core:SetStat(source, STAT, 30, 't39 star'))
                local got = heard(source, STAT, 'star')
                _listen.on = false
                assertEqual(#got, 1, 'the wildcard heard it')
                assertEqual(got[1] and got[1].key, STAT, 'the table names the stat')
                assertEqual(got[1] and got[1].value, 30, 'the value')
                assertEqual(got[1] and got[1].old, 20, 'the old value')
                assertEqual(got[1] and got[1].reason, 't39 star', 'and the reason')
            end,
        },
        {
            name = 'OnStatChange { now = true } is called once straight away with what is there',
            fn = function(source, ctx)
                assertOk(exports.whip_core:SetStat(source, STAT, 33))
                listenStart()
                assertOk(exports.whip_core:OnStatChange(STAT, recorder('now', STAT), '_t39_now', { now = true }))
                local first = waitFor(function()
                    for _, c in ipairs(heard(source, STAT, 'now')) do
                        if c.reason == 'now' then return c end
                    end
                end, 2000)
                _listen.on = false
                assertNotNil(first, 'the listener was called without anything changing')
                assertEqual(first and first.value, 33, 'with the current value')
                assertNil(first and first.old, 'and no old value')
            end,
        },
        {
            name = 'A listener setting the stat it listens to is not called again for it — and the set lands',
            fn = function(source, ctx)
                -- Otherwise a listener that clamps its own stat calls itself for as long as the
                -- value keeps moving.
                assertOk(exports.whip_core:OnStatChange(STAT, function(src, value)
                    if not _listen.on or not _listen.clamp then return end
                    _listen.calls[#_listen.calls + 1] = { via = 'clamp', source = src, key = STAT, value = value }
                    if value > 90 then exports.whip_core:SetStat(src, STAT, 90, 't39 clamp') end
                end, '_t39_clamp'))

                assertOk(exports.whip_core:SetStat(source, STAT, 50))
                listenStart()
                _listen.clamp = true
                assertOk(exports.whip_core:SetStat(source, STAT, 95))
                _listen.clamp = false
                local got = heard(source, STAT, 'clamp')
                _listen.on = false
                assertEqual(exports.whip_core:GetStat(source, STAT), 90, "the listener's own set landed")
                assertEqual(#got, 1, 'and it was called once, not again for its own change')
            end,
        },
        {
            name = 'OnStatChange again with the same id REPLACES the listener; bad arguments are refused',
            fn = function(source, ctx)
                assertOk(exports.whip_core:OnStatChange(STAT, recorder('named', STAT), '_t39_named'))
                assertOk(exports.whip_core:OnStatChange(STAT, recorder('named2', STAT), '_t39_named'))
                assertOk(exports.whip_core:SetStat(source, STAT, 10))
                listenStart()
                assertOk(exports.whip_core:SetStat(source, STAT, 12))
                local old, new = heard(source, STAT, 'named'), heard(source, STAT, 'named2')
                _listen.on = false
                assertEqual(#old, 0, 'the first listener is gone')
                assertEqual(#new, 1, 'the second heard it, once')

                local ok1, e1 = exports.whip_core:OnStatChange('', function() end)
                assertFalse(ok1, 'an empty name is refused')
                assertNotNil(e1, 'with a reason')
                local ok2, e2 = exports.whip_core:OnStatChange(STAT, nil)
                assertFalse(ok2, 'no callback is refused')
                assertNotNil(e2, 'with a reason')
            end,
        },

        -- ==========================================
        -- Effects
        -- ==========================================
        {
            name = 'ApplyEffect makes HasEffect true, and RemoveEffect makes it false again',
            fn = function(source, ctx)
                exports.whip_core:ApplyEffect(source, EFFECT, { duration = 60, magnitude = 1 })
                assertTrue(exports.whip_core:HasEffect(source, EFFECT), 'the effect is active')

                exports.whip_core:RemoveEffect(source, EFFECT)
                assertFalse(exports.whip_core:HasEffect(source, EFFECT), 'and gone once removed')
            end,
        },
        {
            name = 'GetEffects lists the active effect and its magnitude',
            fn = function(source, ctx)
                exports.whip_core:ApplyEffect(source, EFFECT, { duration = 60, magnitude = 3 })

                local effects = exports.whip_core:GetEffects(source)
                assertNotNil(effects, 'effects read back')
                assertNotNil(effects[EFFECT], 'the applied effect is listed')
                assertEqual(effects[EFFECT].magnitude, 3, 'with the magnitude it was given')

                exports.whip_core:RemoveEffect(source, EFFECT)
            end,
        },
        {
            name = 'GetEffects is plain data — never anyone\'s callbacks (STAT-7)',
            fn = function(source, ctx)
                -- It handed out the internal table: every effect's onApply/onTick/onRemove, from
                -- every resource, callable by whoever asked.
                assertTrue(exports.whip_core:ApplyEffect(source, EFFECT, {
                    duration = 60, magnitude = 2, tickRate = 5,
                    onTick = function() end, onApply = function() end, onRemove = function() end,
                }), 'applied with all three callbacks')
                local e = (exports.whip_core:GetEffects(source) or {})[EFFECT]
                assertNotNil(e, 'listed')
                assertNil(e and e.onTick, 'no onTick')
                assertNil(e and e.onApply, 'no onApply')
                assertNil(e and e.onRemove, 'no onRemove')
                assertEqual(e and e.duration, 60, 'the duration')
                assertEqual(e and e.tickRate, 5, 'the tick rate')
                assertType(e and e.remaining, 'number', 'and the time left')
                exports.whip_core:RemoveEffect(source, EFFECT)
            end,
        },
        {
            name = 'An effect is always the CALLER\'s — a resource named in the config is ignored (STAT-6)',
            fn = function(source, ctx)
                -- A caller could claim to be whip_core (whose callbacks get the live player object)
                -- or another resource (so the effect was swept with THAT one, not its real owner).
                assertTrue(exports.whip_core:ApplyEffect(source, EFFECT, { duration = 60, resource = 'whip_core' }),
                    'applied (the field is ignored, not refused)')
                local e = (exports.whip_core:GetEffects(source) or {})[EFFECT]
                assertEqual(e and e.resource, 'whip_test', 'it is recorded as whip_test\'s')
                exports.whip_core:RemoveEffect(source, EFFECT)
            end,
        },
        {
            name = "'stackable' is refused, and replaceSilently replaces without the old onRemove (STAT-9)",
            fn = function(source, ctx)
                exports.whip_core:RemoveEffect(source, EFFECT)
                local ok, why = exports.whip_core:ApplyEffect(source, EFFECT, { duration = 60, stackable = true })
                assertFalse(ok, 'the old name is refused — it never stacked')
                assertTrue(tostring(why):find('replaceSilently', 1, true) ~= nil,
                    ('pointing at the new name (got "%s")'):format(tostring(why)))
                assertFalse(exports.whip_core:HasEffect(source, EFFECT), 'and nothing was applied')

                local removedFired = false
                assertTrue(exports.whip_core:ApplyEffect(source, EFFECT, {
                    duration = 60, magnitude = 1, onRemove = function() removedFired = true end,
                }), 'first application')
                assertTrue(exports.whip_core:ApplyEffect(source, EFFECT, { duration = 60, magnitude = 7, replaceSilently = true }),
                    'the silent replacement')
                assertFalse(removedFired, "the replaced instance's onRemove did NOT run")
                local e = (exports.whip_core:GetEffects(source) or {})[EFFECT]
                assertEqual(e and e.magnitude, 7, 'and the second one is what is active')
                exports.whip_core:RemoveEffect(source, EFFECT)
            end,
        },
        {
            name = 'An effect REPLACES itself by default — its onRemove runs and its modifier comes off',
            fn = function(source, ctx)
                -- The default. Eating two painkillers should not stack two damage reductions
                -- — and the replacement has to be a real remove, or the old one's onRemove
                -- never runs and its modifier never comes off.
                --
                -- So the FIRST application carries both, and the second carries neither. Two plain
                -- applications (what this used to do) could not see either half of that bug.
                exports.whip_core:RemoveEffect(source, EFFECT)
                local base = exports.whip_core:GetDamageModifier(source)

                local removedFired = false
                assertTrue(exports.whip_core:ApplyEffect(source, EFFECT, {
                    duration = 60, magnitude = 1, damageModifier = 0.5,
                    onRemove = function() removedFired = true end,
                }), 'first application accepted')
                assertEqual(exports.whip_core:GetDamageModifier(source), base * 0.5, 'its modifier is on')

                assertTrue(exports.whip_core:ApplyEffect(source, EFFECT, { duration = 60, magnitude = 9 }),
                    'second application accepted')

                assertTrue(removedFired, 'the replaced instance\'s onRemove ran')
                local effects = exports.whip_core:GetEffects(source) or {}
                assertNotNil(effects[EFFECT], 'the effect is present')
                assertEqual(effects[EFFECT].magnitude, 9,
                    'and it is the SECOND application, not the first left in place')
                assertEqual(exports.whip_core:GetDamageModifier(source), base,
                    'the first instance\'s modifier came off with it')
                assertEqual(exports.whip_core:SentinelGetTruth(source, DMG_KEY), base ~= 1.0 and base or nil,
                    'and so did the watched statebag value other clients read')

                exports.whip_core:RemoveEffect(source, EFFECT)
                assertFalse(exports.whip_core:HasEffect(source, EFFECT),
                    'one remove clears it — there is no hidden second copy')
            end,
        },
        {
            name = 'Damage modifiers COMBINE across effects, and come back off — on the statebag too',
            fn = function(source, ctx)
                -- This number reaches other clients through a Sentinel-watched statebag and
                -- scales the damage they deal to this player. An effect that failed to unwind
                -- is permanent damage resistance, which nothing else in the suite would catch.
                --
                -- GetDamageModifier recomputes from the effect table every time, so it cannot show a
                -- bag left behind. The truth the Sentinel holds for the bag is checked alongside it.
                exports.whip_core:RemoveEffect(source, EFFECT)
                exports.whip_core:RemoveEffect(source, EFFECT .. '_2')

                local base = exports.whip_core:GetDamageModifier(source)
                assertType(base, 'number', 'the modifier is a number')
                local function bagFor(v) return v ~= 1.0 and v or nil end   -- absent when exactly 1.0

                exports.whip_core:ApplyEffect(source, EFFECT, { duration = 60, damageModifier = 0.5 })
                assertEqual(exports.whip_core:GetDamageModifier(source), base * 0.5,
                    'one effect halves it')
                assertEqual(exports.whip_core:SentinelGetTruth(source, DMG_KEY), bagFor(base * 0.5),
                    'and the watched bag says so')

                exports.whip_core:ApplyEffect(source, EFFECT .. '_2', { duration = 60, damageModifier = 0.5 })
                assertEqual(exports.whip_core:GetDamageModifier(source), base * 0.25,
                    'two effects multiply rather than replacing one another')
                assertEqual(exports.whip_core:SentinelGetTruth(source, DMG_KEY), bagFor(base * 0.25),
                    'and the bag follows')

                exports.whip_core:RemoveEffect(source, EFFECT)
                exports.whip_core:RemoveEffect(source, EFFECT .. '_2')
                assertEqual(exports.whip_core:GetDamageModifier(source), base,
                    'and removing both puts it back exactly where it started')
                assertEqual(exports.whip_core:SentinelGetTruth(source, DMG_KEY), bagFor(base),
                    'the bag too — no resistance left behind')
                assertEqual(Player(source).state[DMG_KEY], bagFor(base), 'on the real statebag as well')
            end,
        },
        {
            name = 'An effect config that would never expire, or break the tick, is refused with a reason',
            fn = function(source, ctx)
                -- A string duration errored inside the stat tick; a tickRate of 0 is truthy in Lua
                -- and never counted down, so the effect — and any modifier on it — was permanent.
                local cases = {
                    { cfg = { duration = '10' },              why = 'duration must be a positive number of seconds, or nil' },
                    { cfg = { duration = 10, tickRate = 0 },  why = 'tickRate must be a positive number of seconds' },
                    { cfg = { duration = 10, magnitude = 'x' }, why = 'magnitude must be a number' },
                    { cfg = { duration = 10, damageModifier = 0 }, why = 'damageModifier must be a positive number' },
                    { cfg = { duration = 10, meleeModifier = -1 }, why = 'meleeModifier must be a positive number' },
                }
                for i, case in ipairs(cases) do
                    local ok, why = exports.whip_core:ApplyEffect(source, EFFECT, case.cfg)
                    assertFalse(ok, ('bad config %d refused'):format(i))
                    assertEqual(why, case.why, ('bad config %d names the problem'):format(i))
                    assertFalse(exports.whip_core:HasEffect(source, EFFECT), ('bad config %d left nothing active'):format(i))
                end

                local ok, why = exports.whip_core:ApplyEffect(source, EFFECT, 'not a table')
                assertFalse(ok, 'a non-table config is refused')
                assertEqual(why, 'an effect needs a config table', 'with the reason')
            end,
        },
        {
            name = 'A timed effect expires on its own, and its modifier goes with it',
            fn = function(source, ctx)
                -- The tick is what takes a one-second painkiller away again. If it stopped counting
                -- down, every damage reduction in the game would become permanent.
                exports.whip_core:RemoveEffect(source, EFFECT)
                local base = exports.whip_core:GetDamageModifier(source)

                assertTrue(exports.whip_core:ApplyEffect(source, EFFECT, { duration = 1, damageModifier = 0.5 }),
                    'one-second effect applied')
                assertTrue(exports.whip_core:HasEffect(source, EFFECT), 'active straight away')

                local gone = waitFor(function()
                    return not exports.whip_core:HasEffect(source, EFFECT)
                end, 5000)
                assertTrue(gone == true, 'it expired within a few ticks')
                assertEqual(exports.whip_core:GetDamageModifier(source), base, 'and its modifier came off')
            end,
        },
        {
            name = 'HasEffect is false for something never applied',
            fn = function(source, ctx)
                assertFalse(exports.whip_core:HasEffect(source, '_test_effect_never_applied'),
                    'an effect nobody applied is not active')
            end,
        },
    }
})
