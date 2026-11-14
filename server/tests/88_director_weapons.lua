-- ============================================
-- Director: Fixed Weapons — a prop that is a gun: Check, shown as its gun, attached to a car, Fire Weapon
-- ============================================
--
-- On the test field. A Fixed Weapon is a prop whose page names a gun (def.weapon): each game makes that gun's world
-- model (shared/gta_weapon_models.lua). Attached to a car, it rides on it. Fire Weapon fires it for real: here a
-- pistol, at a spot well away from the tester.

local N = DK.N
local PISTOL = 'w_pi_pistol'

local function gun(id, at, over)
    local w = DK.prop(id, at, PISTOL, { weapon = 'WEAPON_PISTOL' })
    for k, v in pairs(over or {}) do w.def[k] = v end
    return w
end

local function check(doc)
    local ok, probs = exports.whip_core:CheckDirectorScenario(doc)
    local msgs = {}
    for _, p in ipairs(probs or {}) do msgs[#msgs + 1] = ('[%s] %s'):format(p.severity, tostring(p.message)) end
    return ok, table.concat(msgs, ' | ')
end

--- start -> Show Prop (its group) -> the rest; Succeed at its end.
local function showDoc(world, nodes, links)
    local all = { N('start', 'scenario.started'), N('show', 'prop.show', { prop = world[1].id, withGroup = true }) }
    for _, n in ipairs(nodes or {}) do all[#all + 1] = n end
    local l = { { 'start', 'out', 'show' } }
    for _, x in ipairs(links or {}) do l[#l + 1] = x end
    return DK.doc({ world = world, nodes = all, links = l })
end

RegisterTestModule({
    order    = 88,
    category = 'Director: Fixed Weapons',
    setup = function(source)
        local p = exports.whip_core:GetPlayer(source)
        if not (p and p.charId) then skip('the tester is not on a character') end
    end,
    teardown = function(ctx, source)
        DK.stopAll()
        DK.goHome(source)
    end,
    tests = {
        {
            name = 'Check: a gun prop passes; a melee weapon, something that is not there to ride on, and a ring do not',
            fn = function()
                local A = { x = 0, y = 0, z = 0, heading = 0 }
                local hold = { N('w', 'flow.wait', { seconds = 1 }), N('win', 'scenario.succeed') }
                local links = { { 'show', 'out', 'w' }, { 'w', 'done', 'win' } }
                local ok, why = check(showDoc({ gun('g', A) }, hold, links))
                assertTrue(ok, 'a pistol prop passes (' .. why .. ')')
                ok, why = check(showDoc({ gun('g', A, { weapon = 'WEAPON_BAT' }) }, hold, links))
                assertTrue(not ok and why:find('is not a firearm this server has', 1, true) ~= nil, 'a bat is no firearm (' .. why .. ')')
                ok, why = check(showDoc({ gun('g', A, { attach = { to = 'ghost' } }) }, hold, links))
                assertTrue(not ok and why:find('not placed in this scenario', 1, true) ~= nil, 'on nothing there (' .. why .. ')')
                ok, why = check(showDoc({ gun('a', A, { attach = { to = 'b' } }), gun('b', A, { attach = { to = 'a' } }) }, hold, links))
                assertTrue(not ok and why:find('round in a ring', 1, true) ~= nil, 'two on each other (' .. why .. ')')
            end,
        },
        {
            name = 'Shown, it is its gun\'s world model where it was placed, on the tester\'s game',
            fn = function(source, ctx)
                DK.toField(source)
                local at = DK.at(6, 3)
                local r = DK.start(source, showDoc({ gun('g', at) }, { N('hold', 'flow.wait', { seconds = 600 }), N('win', 'scenario.succeed') },
                    { { 'show', 'out', 'hold' }, { 'hold', 'done', 'win' } }))
                ctx.runId = r.runId
                local o = DK.until_(source, { model = PISTOL, at = at, radius = 1.5 }, function() return true end, 10000)
                assertNotNil(o, 'a pistol stands there')
                DK.stop(r.runId)
            end,
        },
        {
            name = 'Fire Weapon: it fires (a pistol, at a spot away from everyone), and says Fired',
            fn = function(source, ctx)
                DK.toField(source)
                local r = DK.run(source, showDoc({ gun('g', DK.at(6, 3)), DK.spot('target', DK.at(6, 30)) },
                    { N('aim', 'flow.wait', { seconds = 2 }), N('fire', 'weapon.fire', { weapon = 'g', shots = 3, gap = 0.3, at = 'a placed thing', thing = 'target' }),
                      N('fired', 'scenario.succeed', { reason = 'fired' }), N('could', 'scenario.fail', { reason = 'could not' }),
                      N('late', 'scenario.fail', { reason = 'no answer' }) },
                    { { 'show', 'out', 'aim' }, { 'aim', 'done', 'fire' }, { 'fire', 'fired', 'fired' }, { 'fire', 'failed', 'could' },
                      { 'fire', 'timeout', 'late' } }), { seconds = 40 })
                assertEqual(r.reason, 'fired', 'Fired (' .. DK.how(r) .. '; ' .. DK.said(r, 'fire') .. ')')
            end,
        },
        {
            name = 'Fire Weapon before it is shown: Could not',
            fn = function(source)
                local r = DK.run(source, DK.doc({
                    world = { gun('g', DK.at(6, 3)) },
                    nodes = { N('start', 'scenario.started'), N('fire', 'weapon.fire', { weapon = 'g' }),
                              N('could', 'scenario.succeed', { reason = 'could not' }), N('fired', 'scenario.fail', { reason = 'it fired' }),
                              N('show', 'prop.show', { prop = 'g' }) },
                    links = { { 'start', 'out', 'fire' }, { 'fire', 'failed', 'could' }, { 'fire', 'fired', 'fired' } },
                }))
                assertEqual(r.reason, 'could not', 'Could not (' .. DK.how(r) .. ')')
            end,
        },
        {
            name = 'Attached to a car: it sits on the car where it was placed beside it, and rides with it',
            fn = function(source, ctx)
                DK.toField(source)
                local carAt = DK.at(14, 6, DK.FIELD.heading)
                carAt.z = carAt.z + 0.5
                -- A metre above the car's middle: placed so, it sits so.
                local gunAt = { x = carAt.x, y = carAt.y, z = carAt.z + 1.0, heading = carAt.heading }
                local to = DK.at(22, -8, DK.FIELD.heading)
                to.z = to.z + 0.5
                local car = DK.car('car', carAt, { tasks = { list = { { k = 'w', t = 'wait', sec = 4 }, { k = 't', t = 'teleport', at = to },
                                                                        { k = 'x', t = 'wait', sec = 600 } } } })
                local r = DK.start(source, DK.doc({
                    world = { gun('g', gunAt, { attach = { to = 'car' } }), car },
                    nodes = { N('start', 'scenario.started'), N('spawn', 'vehicle.spawn', { cars = { 'car' } }), N('show', 'prop.show', { prop = 'g' }),
                              N('hold', 'flow.wait', { seconds = 600 }), N('win', 'scenario.succeed') },
                    links = { { 'start', 'out', 'spawn' }, { 'spawn', 'out', 'show' }, { 'show', 'out', 'hold' }, { 'hold', 'done', 'win' } },
                }))
                ctx.runId = r.runId
                local o = DK.until_(source, { model = PISTOL, at = gunAt, radius = 1.5 }, function() return true end, 12000)
                assertNotNil(o, 'on the car, a metre up')
                local moved = DK.until_(source, { model = PISTOL, at = { x = to.x, y = to.y, z = to.z + 1.0 }, radius = 2.0 }, function() return true end, 12000)
                assertNotNil(moved, 'and with the car once it moved')
                DK.stop(r.runId)
            end,
        },
    },
})
