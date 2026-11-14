-- ============================================
-- Permissions — rights given to an account in game (whip_core/server/permissions.lua, Director slice 4)
-- ============================================
--
-- Against the real database and the real gate. The tester is a full admin (/test needs whip.devtools),
-- and full admins hold every permission — so these use permissions declared with devtools = false,
-- which only a grant gives. Everything given is taken back in teardown.

local PERM, GATE = '_test.perm', '_test.gate'

local function userOf(source)
    local p = exports.whip_core:GetPlayer(source)
    return p and p.userId or nil
end

RegisterTestModule({
    order    = 72,
    category = 'Permissions',
    setup = function(source, ctx)
        ctx.userId = userOf(source)
        if not ctx.userId then skip('no account for the tester') end
        local ok, why = exports.whip_core:RegisterPermission(PERM, { label = 'Test permission', devtools = false })
        assertTrue(ok == true, 'declared (' .. tostring(why) .. ')')
        exports.whip_core:RegisterPermission(GATE, { label = 'Test gate', devtools = false })
        -- A callback only a holder of GATE may call (and a dead one may not: no whileDead).
        exports.whip_core:SecureCallback('_test_perm_gated', { rateLimit = false, permission = GATE },
            function() return 'through' end)
    end,
    teardown = function(ctx)
        if ctx.userId then
            pcall(exports.whip_core.RevokePermission, exports.whip_core, { userId = ctx.userId }, PERM)
            pcall(exports.whip_core.RevokePermission, exports.whip_core, { userId = ctx.userId }, GATE)
        end
    end,
    tests = {
        {
            name = 'whip\'s own: the Director\'s two levels are declared, and a full admin holds them',
            fn = function(source)
                assertTrue(exports.whip_core:HasPermission(source, 'director.build') == true, 'builder')
                assertTrue(exports.whip_core:HasPermission(source, 'director.admin') == true, 'Director admin')
            end,
        },
        {
            name = 'A permission full admins do not hold: none until given, then held, then gone when taken away',
            fn = function(source, ctx)
                assertFalse(exports.whip_core:HasPermission(source, PERM), 'not held before')
                -- A person, as everywhere: the tester's own server id names their account
                local ok, why = exports.whip_core:GrantPermission(source, PERM)
                assertTrue(ok == true, 'given (' .. tostring(why) .. ')')
                assertTrue(exports.whip_core:HasPermission(source, PERM), 'held after')
                assertDbRowCount('SELECT 1 FROM `whip_permissions` WHERE `userId` = ? AND `permission` = ?', { ctx.userId, PERM }, 1, 'on record')
                local holders = exports.whip_core:GetPermissionHolders(PERM)
                local mine = false
                for _, h in ipairs(holders or {}) do if h.userId == ctx.userId then mine = true end end
                assertTrue(mine, 'listed among its holders')
                ok = exports.whip_core:RevokePermission({ userId = ctx.userId }, PERM)
                assertTrue(ok == true, 'taken away')
                assertFalse(exports.whip_core:HasPermission(source, PERM), 'not held after')
                assertDbRowCount('SELECT 1 FROM `whip_permissions` WHERE `userId` = ? AND `permission` = ?', { ctx.userId, PERM }, 0, 'off record')
            end,
        },
        {
            name = 'GrantPermission refuses a permission nobody declared',
            fn = function(_, ctx)
                local ok, why = exports.whip_core:GrantPermission({ userId = ctx.userId }, '_test.never_declared')
                assertFalse(ok, 'refused')
                assertNotNil(why, 'with a reason')
            end,
        },
        {
            name = 'A SecureCallback with `permission`: refused without it, answered with it',
            fn = function(source, ctx)
                local answered, res = ClientCallback(source, '_test_perm_gated', 12000)
                assertTrue(answered, 'the client answered')
                assertTrue(res and res[1] == false, 'refused without the permission')
                assertTrue(res and type(res[2]) == 'string' and res[2]:find('Test gate', 1, true) ~= nil,
                    'saying which permission (' .. tostring(res and res[2]) .. ')')
                exports.whip_core:GrantPermission(source, GATE)
                answered, res = ClientCallback(source, '_test_perm_gated', 12000)
                assertTrue(answered and res and res[1] == 'through', 'answered with it')
                exports.whip_core:RevokePermission(source, GATE)
            end,
        },
        {
            name = 'The /whip panel opens every section for a full admin',
            fn = function(source)
                local answered, res = ClientCallback(source, 'whip_core:panel:access', 12000)
                assertTrue(answered and res and type(res[1]) == 'table', 'answered')
                assertTrue(res[1].all == true, 'all sections')
            end,
        },
    },
})
