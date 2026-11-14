-- ============================================
-- Test: Bank Access Control & Job Export
-- Verifies GrantBankAccess, RevokeBankAccess, GetPlayerJob
--
-- Every refusal is asserted BY ITS REASON. Bank.GrantAccess refuses for five different reasons,
-- and a test that only checks `ok == false` passes on whichever one fires first — including
-- 'Granter has no access', which says nothing about the rule the test is named after.
-- ============================================

--- The access row the grantee holds on the test account, or nil.
local function granteeRole(ctx)
    local rows = DbQuery('SELECT `role` FROM `bank_access` WHERE `accountId` = ? AND `charId` = ?',
        { ctx.accountId, ctx.granteeCharId })
    return rows[1] and rows[1].role or nil
end

RegisterTestModule({
    order    = 18,
    category = 'Bank Access',

    setup = function(source, ctx)
        local p = exports.whip_core:GetPlayer(source)
        assertNotNil(p, 'setup: GetPlayer')
        ctx.charId = p.charId

        -- Use GetDefaultBankAccount rather than scanning GetCharacterBankAccounts for
        -- `acc.isDefault == 1`. `isDefault` is TINYINT(1) and what the driver hands back
        -- for it is not something a test should depend on — GetDefaultBankAccount does the
        -- comparison in SQL (`WHERE ownerCharId = ? AND isDefault = 1`), which is why
        -- 03_bank.lua works while the hand-rolled scan here did not.
        --
        -- The export takes a PERSON now: a server id, or { charId = n } (whip's person rule,
        -- audit 3 DX-17). It took a bare charId, and this passing `source` only ever worked
        -- because the solo tester was source 1 AND charId 1.
        local defaultAccount = exports.whip_core:GetDefaultBankAccount(source)

        -- Fail loudly rather than letting every test below silently no-op. The five
        -- `if not ctx.accountId then assertTrue(true, 'SKIP') return end` guards this
        -- module used to carry turned a missing precondition into five green rows.
        assertNotNil(defaultAccount, 'setup: character has a default bank account')
        ctx.accountId = defaultAccount.accountId
        assertNotNil(ctx.accountId, 'setup: default account has an accountId')

        -- The grantee must be a REAL character. `bank_access.charId` has a foreign key to
        -- `characters.charId` (fk_access_charId), so the old `p.charId + 90000` fake id
        -- could never be inserted — every GrantAccess in this module died on the FK. That
        -- went unnoticed because the module's five `assertTrue(true, 'SKIP')` guards meant
        -- these tests never ran at all.
        --
        -- The grantee must also NOT already hold access to this account. The teardown
        -- DELETEs the access row, so granting to someone with a pre-existing grant would
        -- silently destroy real data — charId 2 already holds 'view' on the default
        -- account here, and this test would have overwritten then deleted it.
        --
        -- And ANOTHER PLAYER'S character: with Config.BlockOwnCharacterTransfers on (the default), the bank refuses
        -- to share an account with one of the tester's own other characters (audit 9, SRV-2).
        local rows = DbQuery([[
            SELECT c.`charId`
            FROM `characters` c
            LEFT JOIN `bank_access` ba
              ON ba.`charId` = c.`charId` AND ba.`accountId` = ?
            WHERE c.`charId` <> ?
              AND c.`userId` <> (SELECT `userId` FROM `characters` WHERE `charId` = ?)
              AND c.`deleted` IS NULL
              AND ba.`charId` IS NULL
            ORDER BY c.`charId` ASC
            LIMIT 1
        ]], { ctx.accountId, p.charId, p.charId })
        if not rows[1] then
            skip('needs another player\'s character with no existing access to the default account')
        end
        ctx.granteeCharId = rows[1].charId
    end,

    teardown = function(ctx, source)
        pcall(exports.whip_core.__TestFailNextQuery, exports.whip_core, nil)

        -- Clean up any test access rows. Safe: setup only picked a grantee with NO access row.
        if ctx.accountId and ctx.granteeCharId then
            pcall(DbQuery, 'DELETE FROM `bank_access` WHERE `accountId` = ? AND `charId` = ?',
                { ctx.accountId, ctx.granteeCharId })
        end

        if ctx.jobId and source then
            pcall(exports.whip_core.ClockOff, exports.whip_core, source, ctx.jobId)
            pcall(exports.whip_core.FirePlayer, exports.whip_core, source, ctx.jobId)
        end
    end,

    tests = {
        -- ==========================================
        -- GetPlayerJob
        -- ==========================================
        {
            -- WAS "returns nil or a job table", which skipped for nearly every tester: the export
            -- answers only for a job the player is CLOCKED ON to (jobs.lua, Jobs.getPlayerJob). So
            -- the tester is hired and clocked on here, and the shape is asserted for real.
            name = 'GetPlayerJob answers with the job the player is clocked on to',
            fn = function(source, ctx)
                if exports.whip_core:GetPlayerJob(source) ~= nil then
                    skip('the tester is already clocked on to a job, which GetPlayerJob would answer with instead')
                end

                local job = exports.whip_core:EnsureJob('_test_job', { name = 'Test Job', icon = 'wrench' })
                assertOk(job, nil, 'EnsureJob')
                ctx.jobId = job.jobId

                -- Already employed from an earlier run is fine; the clock-on is what matters. No role
                -- named: the lowest one. No `by`: that is the player DOING it, and checked (audit 6).
                exports.whip_core:HirePlayer(source, job.jobId, nil)
                local clocked, why = exports.whip_core:ClockOn(source, job.jobId)
                assertTrue(clocked, 'clocked on: ' .. tostring(why))

                local pj = exports.whip_core:GetPlayerJob(source)
                assertNotNil(pj, 'GetPlayerJob answers while clocked on')
                assertEqual(pj.jobId, job.jobId, 'jobId')
                assertEqual(pj.key, '_test_job', 'key')
                assertType(pj.roleLevel, 'number', 'roleLevel')
                assertType(pj.roleName, 'string', 'roleName')

                exports.whip_core:ClockOff(source, job.jobId)
                assertNil(exports.whip_core:GetPlayerJob(source), 'and nothing once clocked off')
            end,
        },

        -- ==========================================
        -- GrantAccess
        -- ==========================================
        {
            name = 'GrantBankAccessadds deposit role to account',
            fn = function(source, ctx)
                local ok, err = exports.whip_core:GrantBankAccess(
                    ctx.accountId, { charId = ctx.granteeCharId }, 'deposit', { charId = ctx.charId }
                )
                assertTrue(ok, 'GrantBankAccesssucceeded: ' .. tostring(err))
                assertDbScalar('SELECT `role` FROM `bank_access` WHERE `accountId` = ? AND `charId` = ?',
                    { ctx.accountId, ctx.granteeCharId }, 'deposit', 'the access row says deposit')
            end,
        },
        {
            name = 'GrantBankAccessrejects invalid role',
            fn = function(source, ctx)
                local ok, err = exports.whip_core:GrantBankAccess(
                    ctx.accountId, { charId = ctx.granteeCharId }, 'superadmin', { charId = ctx.charId }
                )
                assertFalse(ok, 'GrantBankAccessrejected invalid role')
                assertEqual(err, 'Invalid role: superadmin', 'refused for the role, by name')
            end,
        },
        {
            name = 'GrantBankAccessrejects granting equal or higher role than own',
            fn = function(source, ctx)
                -- Test player is owner (level 5). Cannot grant 'owner' (level 5) to someone.
                -- Bank.GrantAccess returns at the role-level check BEFORE it touches the
                -- database, so reusing the grantee here writes nothing.
                local ok, err = exports.whip_core:GrantBankAccess(
                    ctx.accountId, { charId = ctx.granteeCharId }, 'owner', { charId = ctx.charId }
                )
                assertFalse(ok, 'GrantBankAccessrejected owner grant')
                assertEqual(err, 'Cannot grant a role equal to or higher than your own',
                    'refused on the level rule, not for some other reason')
            end,
        },
        {
            -- The grant is an upsert, so granting a role to someone who already holds one REPLACES
            -- it — which let a manager "grant" the owner `view` (a demotion) and then revoke them.
            name = 'A manager cannot demote the owner, nor make another manager',
            fn = function(source, ctx)
                local ok, err = exports.whip_core:GrantBankAccess(ctx.accountId, { charId = ctx.granteeCharId }, 'manager', { charId = ctx.charId })
                assertTrue(ok, 'the grantee made a manager: ' .. tostring(err))

                ok, err = exports.whip_core:GrantBankAccess(ctx.accountId, { charId = ctx.charId }, 'view', { charId = ctx.granteeCharId })
                assertFalse(ok, "a manager's grant to the owner is refused")
                assertEqual(err, "Cannot change the owner's access", 'on the owner rule')

                ok, err = exports.whip_core:GrantBankAccess(ctx.accountId, { charId = ctx.granteeCharId }, 'manager', { charId = ctx.granteeCharId })
                assertFalse(ok, 'a manager cannot grant manager')
                assertEqual(err, 'Cannot grant a role equal to or higher than your own', 'on the level rule')

                assertDbScalar('SELECT `role` FROM `bank_access` WHERE `accountId` = ? AND `charId` = ?',
                    { ctx.accountId, ctx.charId }, 'owner', 'the owner is still the owner')
            end,
        },
        {
            -- Written with a bare pcall and "the row first, then memory" is the promise: a failed
            -- write must say so rather than report a grant nobody saved.
            name = 'A grant whose write fails is reported, and changes nothing',
            fn = function(source, ctx)
                local before = granteeRole(ctx)

                assertTrue(exports.whip_core:__TestFailNextQuery('INSERT INTO `bank_access`'), 'fault armed')
                local ok, err = exports.whip_core:GrantBankAccess(ctx.accountId, { charId = ctx.granteeCharId }, 'view', { charId = ctx.charId })
                assertNil(exports.whip_core:__TestRawFaultArmed(), 'the insert really was attempted and failed')
                assertFalse(ok, 'the grant reported failure')
                assertEqual(err, 'Could not save the access change', 'and why')
                assertEqual(granteeRole(ctx), before, 'the access row is as it was')
            end,
        },

        -- ==========================================
        -- RevokeAccess
        -- ==========================================
        {
            name = 'RevokeBankAccessremoves granted role',
            fn = function(source, ctx)
                local granted, gErr = exports.whip_core:GrantBankAccess(
                    ctx.accountId, { charId = ctx.granteeCharId }, 'deposit', { charId = ctx.charId }
                )
                assertTrue(granted, 'a role to revoke: ' .. tostring(gErr))

                local ok, err = exports.whip_core:RevokeBankAccess(
                    ctx.accountId, { charId = ctx.granteeCharId }, { charId = ctx.charId }
                )
                assertTrue(ok, 'RevokeBankAccesssucceeded: ' .. tostring(err))
                assertNil(granteeRole(ctx), 'Access row removed from DB')

                local again, againErr = exports.whip_core:RevokeBankAccess(ctx.accountId, { charId = ctx.granteeCharId }, { charId = ctx.charId })
                assertFalse(again, 'revoking twice is refused')
                assertEqual(againErr, 'Target has no access to this account', 'because there is nothing to revoke')
            end,
        },
        {
            name = 'RevokeBankAccessrejects revoking owner',
            fn = function(source, ctx)
                -- Try to revoke the test player's own owner access
                local ok, err = exports.whip_core:RevokeBankAccess(
                    ctx.accountId, { charId = ctx.charId }, { charId = ctx.charId }
                )
                assertFalse(ok, 'RevokeBankAccessrejected owner revocation')
                assertEqual(err, 'Cannot revoke owner access', 'refused on the owner rule')
            end,
        },
    }
})
