-- ============================================
-- Jobs — the job API (rebuilt 25 Sep 2026)
-- ============================================
--
-- Every job export names a job by jobId or key, a person by source or { charId = n }, a role by
-- roleId or name, and answers a value or `false, reason`. These tests drive the exports that way:
-- the tester is named by their source, the fixtures by key.
--
-- Three fixtures, each kept apart on purpose:
--   _test_job        the rank tests. The tester must NOT own it — the owner holds the top role.
--   _test_owned_job  a job the tester owns (its business account, the owner hand-over, delete).
--   _test_perm_job   a job declared the way a job resource declares one: its own roles and its own
--                    permissions.

local OWNED_KEY = '_test_owned_job'
local PERM_KEY  = '_test_perm_job'

--- What the Jobs exports answer when they say no — whip_core's Jobs.WHY (server/jobs.lua), copied
--- because a test cannot read another resource's tables. They were codes (WHY.job, ...) until
--- audit 3 ARC-10; they are sentences a player can read now.
local WHY = {
    job         = 'No such job',
    role        = 'No such role at that job',
    key         = 'A job key is letters, digits and _ (starting with a letter or _), up to 50',
    player      = 'No player with that server id is online (for a character, pass { charId = n })',
    character   = 'No such character',
    notEmployed = 'They do not work there',
    employed    = 'They already work there',
    offDuty     = 'They are not on duty',
    rank        = 'They (or that role) outrank you',
    hasAccount  = 'This job has a business account, which needs an owner — set a new owner instead of clearing it',
    moneyLeft   = 'Empty the job\'s business account first',
    permission  = 'Your role is not allowed to do that',
    byNobody    = 'opts.by names nobody (a source, or { charId = n })',
    roleUsed    = 'Move the people in that role to another role first',
    topRole     = 'The job needs a level 100 role: its owner holds it',
    selfClock   = 'This job puts people on duty itself',
    power       = 'That rank can do more than yours: you cannot give more than you have',
}

--- Every whip_core:job:* event on a fixture, newest last. File scope, so the handlers are
--- registered once per resource start rather than once per run.
local _jobEvents = {}
for _, name in ipairs({ 'hired', 'fired', 'roleChanged', 'clockedOn', 'clockedOff', 'created', 'updated', 'deleted' }) do
    AddEventHandler('whip_core:job:' .. name, function(e)
        if type(e) == 'table' and type(e.key) == 'string' and e.key:sub(1, 6) == '_test_' then
            _jobEvents[#_jobEvents + 1] = { name = name, e = e }
        end
    end)
end

--- The events named `name` recorded since `mark`, for this job key.
local function eventsSince(mark, name, key)
    local out = {}
    for i = mark + 1, #_jobEvents do
        local rec = _jobEvents[i]
        if rec.name == name and rec.e.key == key then out[#out + 1] = rec.e end
    end
    return out
end

--- Delete a job fixture and its business account, whatever state it was left in. Deleting a job
--- closes its business account and refuses while the account holds money, so it is drained first.
--- Any account still open afterwards is closed here, and its access rows go too (one may belong to
--- another character after the hand-over test).
local function disposeJob(source, key)
    local job = exports.whip_core:GetJob(key)
    if not job then return end
    local accounts = exports.whip_core:GetJobBankAccounts(job.jobId) or {}
    for _, acc in ipairs(accounts) do
        if (tonumber(acc.balance) or 0) > 0 then
            pcall(exports.whip_core.BankSystemWithdraw, exports.whip_core, acc.accountId, acc.balance, '_test cleanup')
        end
    end
    pcall(exports.whip_core.ClockOff, exports.whip_core, source, key)
    pcall(exports.whip_core.DeleteJob, exports.whip_core, key)
    for _, acc in ipairs(accounts) do
        if exports.whip_core:GetBankAccount(acc.accountId) then DisposeTestAccount(acc.accountId) end
        pcall(DbQuery, 'DELETE FROM `bank_access` WHERE `accountId` = ?', { acc.accountId })
    end
end

--- Create the owned job on first use, filling ctx as it goes so teardown can always find it.
local function ensureOwnedJob(source, ctx)
    if ctx.ownedJobId then return end
    disposeJob(source, OWNED_KEY)

    -- The owner as a PERSON (a source), the shape every job export takes now.
    local job, why = exports.whip_core:EnsureJob(OWNED_KEY, { name = 'Test Owned Job', owner = source })
    assertOk(job, why, 'EnsureJob with an owner')
    ctx.ownedJobId = job.jobId
    assertEqual(exports.whip_core:GetJob(OWNED_KEY).ownerCharId, ctx.charId,
        'the fixture is owned by the tester (a stale one could not be removed if this fails)')

    local roles = exports.whip_core:GetJobRoles(OWNED_KEY)   -- highest level first
    ctx.ownedLowRoleId = roles[#roles] and roles[#roles].roleId
    ctx.ownedTopLevel  = roles[1] and roles[1].level

    local accs = exports.whip_core:GetJobBankAccounts(job.jobId) or {}
    ctx.ownedAccountId = accs[1] and accs[1].accountId
end

local GHOST_KEY = '_test_ghost_job'

--- A throwaway character on the tester's account, for the character-deletion test (ARC-7). Alive
--- when made — a business's owner has to be — and soft-deleted by the test before the event fires.
--- Teardown removes the row outright.
local function makeGhost(source)
    local charId = exports.whip_core:GetPlayer(source).charId
    local userId = MySQL.scalar.await('SELECT `userId` FROM `characters` WHERE `charId` = ?', { charId })
    return MySQL.insert.await(
        "INSERT INTO `characters` (`userId`, `firstName`, `lastName`, `dateOfBirth`) VALUES (?, '_test', '_ghost', '1990-01-01')",
        { userId })
end

--- The access-list role this character holds on an account, or nil.
local function accessRole(accountId, charId)
    for _, entry in ipairs(exports.whip_core:GetBankAccessList(accountId) or {}) do
        if tonumber(entry.charId) == charId then return entry.role end
    end
    return nil
end

--- Is this charId in a GetClockedOnEmployees answer?
local function onDutyList(rows, charId)
    for _, row in ipairs(rows or {}) do
        if row.charId == charId then return row end
    end
    return nil
end

RegisterTestModule({
    order    = 4,
    category = 'Jobs',
    setup = function(source, ctx)
        local player = exports.whip_core:GetPlayer(source)
        ctx.charId = player.charId

        local job, why = exports.whip_core:EnsureJob('_test_job', { name = 'Test Job', icon = 'wrench' })
        if not job then error('Failed to create test job: ' .. tostring(why)) end
        ctx.jobId = job.jobId

        -- THE OWNER HOLDS THE TOP ROLE (Jobs.getPlayerRole). If the tester owns _test_job — an admin
        -- set it in the Job Manager, say — every rank below would read level 100 and the tests would
        -- fail against correct code. Say so instead of producing a page of misleading red.
        if job.ownerCharId == player.charId then
            skip('you own _test_job, so you hold its top role and the rank tests cannot run — clear its owner in the Job Manager')
        end

        -- The roles by level, from the export a satellite would use (it used to read job_roles).
        local roleMap, nameMap = {}, {}
        for _, r in ipairs(exports.whip_core:GetJobRoles('_test_job') or {}) do
            roleMap[r.level] = r.roleId
            nameMap[r.level] = r.name
        end
        ctx.employeeRoleId = roleMap[1]
        ctx.managerRoleId  = roleMap[50]
        ctx.managerName    = nameMap[50]
        ctx.ownerRoleId    = roleMap[100]

        -- A crashed earlier run can leave the tester employed or on duty.
        pcall(exports.whip_core.ClockOff, exports.whip_core, source)
        pcall(exports.whip_core.FirePlayer, exports.whip_core, source, '_test_job')
    end,
    teardown = function(ctx, source)
        pcall(exports.whip_core.__TestFailNextQuery, exports.whip_core, nil)
        if source then
            pcall(exports.whip_core.ClockOff, exports.whip_core, source)
            pcall(exports.whip_core.FirePlayer, exports.whip_core, source, '_test_job')
            disposeJob(source, OWNED_KEY)
            disposeJob(source, PERM_KEY)
            disposeJob(source, GHOST_KEY)
        end
        if ctx.ghostCharId then
            pcall(DbQuery, 'DELETE FROM `characters` WHERE `charId` = ?', { ctx.ghostCharId })
        end
        if ctx.rankGhostCharId then
            pcall(exports.whip_core.FirePlayer, exports.whip_core, { charId = ctx.rankGhostCharId }, '_test_job')
            DisposeStranger(ctx.rankGhostUserId)   -- the character goes with its account row
        end
    end,
    tests = {
        {
            -- ARC-7 (Josh, 26 Sep 2026): deleting a character sends what they held back to stock.
            -- A business they OWN has no owner and keeps running; its business account stays as it
            -- is, and moves to whoever an admin names as the new owner.
            name = "A deleted owner's business has no owner and keeps running",
            fn = function(source, ctx)
                disposeJob(source, GHOST_KEY)
                local ghost = makeGhost(source)
                assertNotNil(ghost, 'a throwaway character')
                ctx.ghostCharId = ghost

                local job, why = exports.whip_core:EnsureJob(GHOST_KEY, { name = 'Test Ghost Job', owner = { charId = ghost } })
                assertOk(job, why, 'a business the throwaway character owns')
                local accounts = #(exports.whip_core:GetJobBankAccounts(job.jobId) or {})

                DbQuery('UPDATE `characters` SET `deleted` = CURRENT_TIMESTAMP WHERE `charId` = ?', { ghost })
                -- The seam, not the event: the event is news only since audit 5 (ARC-1).
                assertOk(exports.whip_core:__TestRunCharacterDeleted(ghost))

                assertTrue(waitFor(function()
                    local j = exports.whip_core:GetJob(GHOST_KEY)
                    return j ~= nil and j.ownerCharId == nil
                end, 3000) == true, 'the business has no owner')
                assertEqual(#(exports.whip_core:GetJobBankAccounts(job.jobId) or {}), accounts,
                    'and still has its business account')
                assertDbRowCount('SELECT 1 FROM `jobs` WHERE `jobId` = ? AND `ownerCharId` IS NULL', { job.jobId }, 1,
                    'on disk too')
            end,
        },
        -- ==========================================
        -- Jobs, by key
        -- ==========================================
        {
            name = 'EnsureJob creates job with default roles, and GetJobRoles lists them highest first',
            fn = function(source, ctx)
                local job = exports.whip_core:GetJob(ctx.jobId)
                assertNotNil(job, 'GetJob by jobId')
                assertEqual(job.key, '_test_job', 'job.key')
                assertNotNil(ctx.employeeRoleId, 'Employee role (level 1) exists')
                assertNotNil(ctx.managerRoleId, 'Manager role (level 50) exists')
                assertNotNil(ctx.ownerRoleId, 'Owner role (level 100) exists')

                local roles = exports.whip_core:GetJobRoles(ctx.jobId)
                assertType(roles, 'table', 'GetJobRoles by jobId')
                for i = 2, #roles do
                    assertTrue(roles[i - 1].level >= roles[i].level, 'highest level first')
                end
            end,
        },
        {
            -- GetJobByKey was removed: GetJob takes a key.
            name = 'GetJob finds a job by key, and says nil for one that does not exist',
            fn = function(source, ctx)
                local job = exports.whip_core:GetJob('_test_job')
                assertNotNil(job, 'GetJob by key')
                assertEqual(job.jobId, ctx.jobId, 'jobId')
                assertNil(exports.whip_core:GetJob('_no_such_job_'), 'an unknown key')
                local roles, why = exports.whip_core:GetJobRoles('_no_such_job_')
                assertFalse(roles, 'GetJobRoles of an unknown job')
                assertEqual(why, WHY.job, 'says why')
            end,
        },
        {
            name = 'EnsureJob is idempotent, and refuses a key that is not an identifier',
            fn = function(source, ctx)
                local job2 = exports.whip_core:EnsureJob('_test_job', { name = 'Test Job' })
                assertEqual(job2.jobId, ctx.jobId, 'same jobId')

                local bad, why = exports.whip_core:EnsureJob('bad key!', { name = 'Nope' })
                assertFalse(bad, 'a key with a space and a ! is refused')
                assertEqual(why, WHY.key, 'with its reason (it answered nil before)')
            end,
        },

        -- ==========================================
        -- Hire + Permission Hierarchy
        -- ==========================================
        {
            -- ROW FIRST. Jobs.hire writes the employee row and only then touches the cache, so a
            -- failed insert must leave the character exactly as unemployed as before.
            name = 'A hire whose write fails reports it, and hires nobody',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:__TestFailNextQuery('INSERT INTO `job_employees`'), 'fault armed')
                local ok, err = exports.whip_core:HirePlayer(source, '_test_job', ctx.employeeRoleId)
                -- Read, then disarm AT ONCE: a fault that did not fire would otherwise sit armed for
                -- ten seconds and fail whatever unrelated write matched it next.
                local stillArmed = exports.whip_core:__TestRawFaultArmed()
                exports.whip_core:__TestFailNextQuery(nil)
                assertNil(stillArmed, 'the fault fired on the hire\'s own write')
                assertFalse(ok, 'the hire reports failure')
                assertEqual(err, DB_ERROR, 'with its reason')
                assertNil((exports.whip_core:GetJobEmployees('_test_job') or {})[ctx.charId], 'not in the cache')
                assertNil(exports.whip_core:GetPlayerRole(source, '_test_job'), 'and holds no role')
            end,
        },
        {
            name = 'HirePlayer as Employee (level 1) reaches disk, and announces whip_core:job:hired',
            fn = function(source, ctx)
                local mark = #_jobEvents
                -- No `by`: the tester hires themselves as the test's own code, not as a player. Since
                -- audit 6 (PLY-1) `by` is CHECKED, and a tester who works nowhere may hire nobody; the
                -- hiredBy record is covered by the rank test below.
                local ok, err = exports.whip_core:HirePlayer(source, '_test_job', ctx.employeeRoleId)
                assertOk(ok, err, 'HirePlayer as employee')
                assertDbScalar('SELECT `roleId` FROM `job_employees` WHERE `jobId` = ? AND `charId` = ?',
                    { ctx.jobId, ctx.charId }, ctx.employeeRoleId, 'the employee row, with the role')

                local hired = eventsSince(mark, 'hired', '_test_job')
                assertEqual(#hired, 1, 'one hired event')
                assertEqual(hired[1] and hired[1].charId, ctx.charId, 'for the tester')
                assertEqual(hired[1] and hired[1].source, source, 'with their source')
                assertEqual(hired[1] and hired[1].roleId, ctx.employeeRoleId, 'and the role')
            end,
        },
        {
            name = 'HirePlayer refuses someone already employed, a role the job lacks, and nobody',
            fn = function(source, ctx)
                local again, againErr = exports.whip_core:HirePlayer(source, '_test_job', ctx.employeeRoleId)
                assertFalse(again, 'a second hire is refused')
                assertEqual(againErr, WHY.employed, 'and says why')

                local bad, badErr = exports.whip_core:HirePlayer(source, '_test_job', 0)
                assertFalse(bad, 'a role that is not this job\'s is refused')
                assertEqual(badErr, WHY.role, 'and says why')

                local noName, noNameErr = exports.whip_core:HirePlayer(source, '_test_job', '_no such role_')
                assertFalse(noName, 'a role name the job lacks is refused')
                assertEqual(noNameErr, WHY.role, 'and says why')

                local ghost, ghostErr = exports.whip_core:HirePlayer({ charId = 2000000000 }, '_test_job')
                assertFalse(ghost, 'a character that does not exist is refused (it used to be hired)')
                assertEqual(ghostErr, WHY.character, 'and says why')

                local nobody, nobodyErr = exports.whip_core:HirePlayer(65000, '_test_job')
                assertFalse(nobody, 'a source with no player is refused')
                assertEqual(nobodyErr, WHY.player, 'and says why')

                local noJob, noJobErr = exports.whip_core:HirePlayer(source, '_no_such_job_')
                assertFalse(noJob, 'an unknown job is refused')
                assertEqual(noJobErr, WHY.job, 'and says why')
            end,
        },
        {
            -- BY KEY. The employee list is a MAP of charId -> record.
            name = 'GetJobEmployees includes the hired player, with role and duty',
            fn = function(source, ctx)
                local emps = exports.whip_core:GetJobEmployees('_test_job')
                assertType(emps, 'table', 'type')
                local me = emps[ctx.charId]
                assertNotNil(me, 'player in employees')
                assertEqual(me.roleId, ctx.employeeRoleId, 'with the role they were hired at')
                assertEqual(me.roleLevel, 1, 'its level')
                assertType(me.roleName, 'string', 'its name')
                assertFalse(me.onDuty, 'off duty')
                assertEqual(me.source, source, 'and their source while online')
            end,
        },
        {
            name = 'GetPlayerRole returns Employee role, by source and by { charId }',
            fn = function(source, ctx)
                local role = exports.whip_core:GetPlayerRole(source, '_test_job')
                assertNotNil(role, 'GetPlayerRole')
                assertEqual(role.level, 1, 'level is 1')
                local byChar = exports.whip_core:GetPlayerRole({ charId = ctx.charId }, ctx.jobId)
                assertEqual(byChar and byChar.roleId, role.roleId, 'the same role named the other two ways')
            end,
        },
        {
            name = 'Employee has NO canHire permission',
            fn = function(source, ctx)
                assertFalse(exports.whip_core:HasJobPermission(source, '_test_job', 'canHire'), 'canHire = false')
                assertFalse(exports.whip_core:HasJobPermission(source, '_test_job', 'canFire'), 'canFire = false')
            end,
        },
        {
            -- The role by NAME, the job by KEY.
            name = 'Promote to Manager by role name, reaching disk, announcing whip_core:job:roleChanged',
            fn = function(source, ctx)
                if not ctx.managerName then skip('_test_job has no level-50 role — its roles were edited') end
                local mark = #_jobEvents
                local ok, err = exports.whip_core:SetPlayerRole(source, '_test_job', ctx.managerName)
                assertOk(ok, err, 'SetPlayerRole to manager, by name')
                local role = exports.whip_core:GetPlayerRole(source, '_test_job')
                assertNotNil(role, 'role after promote')
                assertEqual(role.level, 50, 'level is 50')
                assertDbScalar('SELECT `roleId` FROM `job_employees` WHERE `jobId` = ? AND `charId` = ?',
                    { ctx.jobId, ctx.charId }, ctx.managerRoleId, 'the new role on disk')

                local changed = eventsSince(mark, 'roleChanged', '_test_job')
                assertEqual(#changed, 1, 'one roleChanged event')
                assertEqual(changed[1] and changed[1].oldRoleId, ctx.employeeRoleId, 'with the old role')
                assertEqual(changed[1] and changed[1].roleId, ctx.managerRoleId, 'and the new')
            end,
        },
        {
            name = 'Manager HAS canHire permission',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:HasJobPermission(source, '_test_job', 'canHire'), 'canHire = true')
                assertTrue(exports.whip_core:HasJobPermission(source, '_test_job', 'canFire'), 'canFire = true')
            end,
        },
        {
            -- PLY-1 (audit 6): `opts.by` is the player doing it, and whip checks their rank and their
            -- role's permission. It was "for the record" only while the docs promised the rank rule,
            -- so a boss menu built on the exports let a Manager make themselves Owner.
            name = 'opts.by is checked: a Manager hires and fires below them, and cannot promote themselves or a peer',
            fn = function(source, ctx)
                if not ctx.ownerRoleId then skip('_test_job has no level-100 role — its roles were edited') end
                local self, selfErr = exports.whip_core:SetPlayerRole(source, '_test_job', ctx.ownerRoleId, { by = source })
                assertFalse(self, 'a Manager cannot promote themselves to Owner')
                assertEqual(selfErr, WHY.rank, 'and says why')
                assertEqual((exports.whip_core:GetPlayerRole(source, '_test_job') or {}).level, 50, 'still a Manager')

                -- On ANOTHER player account: the tester's own alt is refused at a job the tester works at
                -- (Config.JobOneCharacterPerAccount, on by default — audit 9 SRV-3).
                local ghost, ghostUser = MakeStranger()
                assertNotNil(ghost, 'a throwaway character to hire, on another player account')
                ctx.rankGhostCharId, ctx.rankGhostUserId = ghost, ghostUser
                local hired, hErr = exports.whip_core:HirePlayer({ charId = ghost }, '_test_job', ctx.employeeRoleId, { by = source })
                assertOk(hired, hErr, 'a Manager hires an Employee')
                assertDbScalar('SELECT `hiredBy` FROM `job_employees` WHERE `jobId` = ? AND `charId` = ?',
                    { ctx.jobId, ghost }, ctx.charId, 'hiredBy is the Manager')

                local up, upErr = exports.whip_core:SetPlayerRole({ charId = ghost }, '_test_job', ctx.managerRoleId, { by = source })
                assertFalse(up, 'nor makes anyone their peer')
                assertEqual(upErr, WHY.rank, 'and says why')

                local fired, fErr = exports.whip_core:FirePlayer({ charId = ghost }, '_test_job', { by = source })
                assertOk(fired, fErr, 'and fires below them')

                local nobody, nobodyErr = exports.whip_core:HirePlayer({ charId = ghost }, '_test_job', nil, { by = 65000 })
                assertFalse(nobody, 'a `by` naming nobody is refused')
                assertType(nobodyErr, 'string', 'with a reason')
            end,
        },
        {
            -- A DEMOTION THAT LOWERS BANK ACCESS REACHES THE ACCOUNTS FIRST (audit 7, PLY-2). A failed read
            -- of the job's accounts looked like "no accounts": the role changed, SetPlayerRole answered
            -- true, and the demoted Manager kept withdraw access to the business account. Now the demotion
            -- is refused and they keep their role — never more access than the role they hold.
            name = 'A demotion whose bank access cannot be lowered is refused, and the role stays',
            fn = function(source, ctx)
                if not (ctx.managerRoleId and ctx.employeeRoleId) then skip('_test_job roles were edited') end
                local rank = { none = 0, view = 1, deposit = 2, withdraw = 3, manager = 4 }
                local access = {}
                for _, r in ipairs(exports.whip_core:GetJobRoles('_test_job') or {}) do
                    access[r.roleId] = rank[(r.permissions or {}).bankAccess or 'none'] or 0
                end
                if not ((access[ctx.managerRoleId] or 0) > (access[ctx.employeeRoleId] or 0)) then
                    skip('a Manager here has no more bank access than an Employee — nothing to lower')
                end

                assertTrue(exports.whip_core:__TestFailNextQuery('FROM `bank_accounts` WHERE `jobId`'), 'fault armed')
                local ok, err = exports.whip_core:SetPlayerRole(source, '_test_job', ctx.employeeRoleId)
                local stillArmed = exports.whip_core:__TestRawFaultArmed()
                exports.whip_core:__TestFailNextQuery(nil)

                assertNil(stillArmed, 'the fault fired on the accounts read')
                assertFalse(ok, 'the demotion is refused')
                assertType(err, 'string', 'with a reason')
                assertEqual((exports.whip_core:GetPlayerRole(source, '_test_job') or {}).level, 50,
                    'and they are still a Manager — not demoted with the old access left in place')
                assertDbScalar('SELECT `roleId` FROM `job_employees` WHERE `jobId` = ? AND `charId` = ?',
                    { ctx.jobId, ctx.charId }, ctx.managerRoleId, 'on disk too')
            end,
        },

        -- ==========================================
        -- Clock On/Off
        -- ==========================================
        {
            name = 'HasJobPermission with { onDuty = true } needs duty; without it, it does not',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:HasJobPermission(source, '_test_job', 'canHire'),
                    'off duty, the permission holds')
                assertFalse(exports.whip_core:HasJobPermission(source, '_test_job', 'canHire', { onDuty = true }),
                    'but not with onDuty while off duty')
            end,
        },
        {
            name = 'ClockOn clocks the player in, and announces whip_core:job:clockedOn once',
            fn = function(source, ctx)
                local mark = #_jobEvents
                local ok, why = exports.whip_core:ClockOn(source, '_test_job')
                assertOk(ok, why, 'ClockOn')
                assertTrue(exports.whip_core:IsPlayerClockedOn(source, '_test_job'), 'clocked on (by key)')
                assertTrue(exports.whip_core:IsPlayerClockedOn(source, ctx.jobId), 'clocked on (by jobId)')
                assertTrue(exports.whip_core:IsPlayerClockedOn(source), 'on duty somewhere')
                assertTrue(exports.whip_core:HasJobPermission(source, '_test_job', 'canHire', { onDuty = true }),
                    'onDuty holds now')

                -- Clocking on again where they already are is not a change.
                assertOk(exports.whip_core:ClockOn(source, '_test_job'), nil, 'a second ClockOn')
                assertEqual(#eventsSince(mark, 'clockedOn', '_test_job'), 1, 'one clockedOn event for two calls')
            end,
        },
        {
            name = 'GetPlayerJob answers the job they are on duty at, and the statebag agrees',
            fn = function(source, ctx)
                local active = exports.whip_core:GetPlayerJob(source)
                assertNotNil(active, 'on duty, so there is an active job')
                assertEqual(active.jobId, ctx.jobId, 'the job just clocked on at (the most recent)')
                assertEqual(active.key, '_test_job', 'key')
                assertEqual(active.roleLevel, 50, 'the role they hold there')
                assertEqual(Player(source).state.whipJob, '_test_job', 'the whipJob statebag names it too')
            end,
        },
        {
            name = 'GetClockedOnEmployees lists the player with their source',
            fn = function(source, ctx)
                local row = onDutyList(exports.whip_core:GetClockedOnEmployees('_test_job'), ctx.charId)
                assertNotNil(row, 'in the on-duty list')
                assertEqual(row and row.source, source, 'with their source')
            end,
        },
        {
            -- JOB-5: the current job is the most recent clock-on — for GetPlayerJob and the statebag
            -- alike, and after a clock-off, the most recent of what is left. With
            -- Config.JobDutyOneAtATime the second clock-on clocks the first job off instead.
            name = 'Two jobs on duty: the most recent is current, and clocking it off falls back',
            fn = function(source, ctx)
                ensureOwnedJob(source, ctx)
                assertOk(exports.whip_core:ClockOn(source, OWNED_KEY), nil, 'ClockOn at the owned job')

                if not exports.whip_core:IsPlayerClockedOn(source, '_test_job') then
                    -- Config.JobDutyOneAtATime is on: the first job went off duty.
                    assertEqual(exports.whip_core:GetPlayerJob(source).key, OWNED_KEY, 'one at a time: the new job')
                    assertEqual(Player(source).state.whipJob, OWNED_KEY, 'and the statebag')
                    assertOk(exports.whip_core:ClockOff(source, OWNED_KEY), nil, 'ClockOff')
                    assertOk(exports.whip_core:ClockOn(source, '_test_job'), nil, 'back on at _test_job')
                    return
                end

                assertEqual(exports.whip_core:GetPlayerJob(source).key, OWNED_KEY, 'the newer clock-on is current')
                assertEqual(Player(source).state.whipJob, OWNED_KEY, 'and the statebag names it')

                assertOk(exports.whip_core:ClockOff(source, OWNED_KEY), nil, 'ClockOff the current job')
                assertEqual(exports.whip_core:GetPlayerJob(source).key, '_test_job', 'the other job is current again')
                assertEqual(Player(source).state.whipJob, '_test_job', 'and the statebag falls back to it')
            end,
        },
        {
            name = 'ClockOff takes the player off, announces it, and refuses when off already',
            fn = function(source, ctx)
                local mark = #_jobEvents
                local ok, why = exports.whip_core:ClockOff(source, '_test_job')
                assertOk(ok, why, 'ClockOff')
                assertFalse(exports.whip_core:IsPlayerClockedOn(source, '_test_job'), 'not clocked on')
                assertEqual(#eventsSince(mark, 'clockedOff', '_test_job'), 1, 'one clockedOff event')

                local again, againWhy = exports.whip_core:ClockOff(source, '_test_job')
                assertFalse(again, 'off duty already')
                assertEqual(againWhy, WHY.offDuty, 'says why (it was a bare false)')
            end,
        },

        -- ==========================================
        -- GetPlayerJobs + Fire
        -- ==========================================
        {
            name = 'GetPlayerJobs includes test job, with the role and what it may do',
            fn = function(source, ctx)
                local jobs = exports.whip_core:GetPlayerJobs(source)
                assertType(jobs, 'table', 'type')
                -- Returns map { [jobId] = {jobId, key, name, ...} } not array
                assertNotNil(jobs[ctx.jobId], 'test job in player jobs')
                assertEqual(jobs[ctx.jobId].roleLevel, 50, 'with the role they hold')
                assertTrue(jobs[ctx.jobId].permissions and jobs[ctx.jobId].permissions.canHire == true,
                    'and its permissions (what the client offers from)')
            end,
        },
        {
            -- ROW FIRST, the same promise as the hire: a fire whose delete fails leaves them
            -- employed, in memory and on disk, so a retry can finish it.
            name = 'A fire whose write fails reports it, and fires nobody',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:__TestFailNextQuery('DELETE FROM `job_employees`'), 'fault armed')
                local ok, err = exports.whip_core:FirePlayer(source, '_test_job')
                local stillArmed = exports.whip_core:__TestRawFaultArmed()
                exports.whip_core:__TestFailNextQuery(nil)
                assertNil(stillArmed, 'the fault fired on the fire\'s own write')
                assertFalse(ok, 'the fire reports failure')
                assertEqual(err, DB_ERROR, 'with its reason')
                assertNotNil((exports.whip_core:GetJobEmployees('_test_job') or {})[ctx.charId], 'still employed in memory')
                assertDbRowCount('SELECT 1 FROM `job_employees` WHERE `jobId` = ? AND `charId` = ?',
                    { ctx.jobId, ctx.charId }, 1, 'and on disk')
            end,
        },
        {
            name = 'FirePlayer removes from job, the row goes with it, and whip_core:job:fired fires',
            fn = function(source, ctx)
                local mark = #_jobEvents
                local ok, err = exports.whip_core:FirePlayer(source, '_test_job')
                assertOk(ok, err, 'FirePlayer')
                local jobs = exports.whip_core:GetPlayerJobs(source)
                assertNil(jobs[ctx.jobId], 'not in jobs after fire')
                assertDbRowCount('SELECT 1 FROM `job_employees` WHERE `jobId` = ? AND `charId` = ?',
                    { ctx.jobId, ctx.charId }, 0, 'the employee row is gone from disk')
                assertEqual(#eventsSince(mark, 'fired', '_test_job'), 1, 'one fired event')

                local again, againErr = exports.whip_core:FirePlayer(source, '_test_job')
                assertFalse(again, 'firing someone who is not employed is refused')
                assertEqual(againErr, WHY.notEmployed, 'and says why')
            end,
        },
        {
            -- The default role: HirePlayer with no role starts them at the lowest.
            name = 'HirePlayer with no role hires at the lowest role, by { charId }',
            fn = function(source, ctx)
                local ok, err = exports.whip_core:HirePlayer({ charId = ctx.charId }, '_test_job')
                assertOk(ok, err, 'HirePlayer with no role')
                assertEqual(exports.whip_core:GetPlayerRole(source, '_test_job').level, 1, 'at level 1')
                assertOk(exports.whip_core:FirePlayer({ charId = ctx.charId }, '_test_job'), nil, 'fired again')
            end,
        },

        -- ==========================================
        -- A job declared by its resource: its own roles and permissions
        -- ==========================================
        {
            name = 'EnsureJob declares roles and its own permissions; HasJobPermission answers them',
            fn = function(source, ctx)
                disposeJob(source, PERM_KEY)
                local job, why = exports.whip_core:EnsureJob(PERM_KEY, {
                    name  = 'Test Perm Job',
                    roles = {
                        { name = 'Boss',    level = 100 },
                        { name = 'Officer', level = 20, permissions = { cuff = true, bankAccess = 'view' } },
                        { name = 'Cadet',   level = 1 },
                    },
                    permissions = { cuff = 'Cuff suspects' },
                })
                assertOk(job, why, 'EnsureJob with roles and permissions')

                local roles = exports.whip_core:GetJobRoles(PERM_KEY)
                assertEqual(#roles, 3, 'its own three roles, not the config defaults')
                assertEqual(roles[1].name, 'Boss', 'highest first')
                assertTrue(roles[2].permissions.cuff == true, 'Officer holds cuff')
                assertEqual(roles[2].permissions.bankAccess, 'view', 'and its bank access')

                assertOk(exports.whip_core:HirePlayer(source, PERM_KEY, 'officer'), nil, 'hired as Officer (any case)')
                assertTrue(exports.whip_core:HasJobPermission(source, PERM_KEY, 'cuff'), 'the job\'s own permission')
                assertFalse(exports.whip_core:HasJobPermission(source, PERM_KEY, 'canHire'), 'not a built-in it lacks')
                local entry = exports.whip_core:GetPlayerJobs(source)[job.jobId] or {}
                assertTrue((entry.permissions or {}).cuff == true, 'in the job list too')
            end,
        },
        {
            name = 'EnsureJob again adds missing roles, updates permissions, and never changes a role that exists',
            fn = function(source, ctx)
                local job, why = exports.whip_core:EnsureJob(PERM_KEY, {
                    name  = 'Test Perm Job',
                    roles = {
                        { name = 'Officer', level = 99, permissions = {} },   -- exists: must not change
                        { name = 'Sergeant', level = 50, permissions = { cuff = true } },
                    },
                    permissions = { cuff = 'Cuff a suspect', impound = 'Impound cars' },
                })
                assertOk(job, why, 'EnsureJob again')

                local byName = {}
                for _, r in ipairs(exports.whip_core:GetJobRoles(PERM_KEY)) do byName[r.name] = r end
                assertNotNil(byName.Sergeant, 'the new role was added')
                assertEqual(byName.Officer and byName.Officer.level, 20, 'the existing role kept its level')
                assertTrue(byName.Officer and byName.Officer.permissions.cuff == true, 'and its permissions')

                local perms = exports.whip_core:GetJob(PERM_KEY).settings.permissions
                assertEqual(perms.cuff, 'Cuff a suspect', 'a permission label follows the code')
                assertEqual(perms.impound, 'Impound cars', 'a new permission is declared')

                local bad, badWhy = exports.whip_core:EnsureJob(PERM_KEY, { permissions = { canHire = 'mine' } })
                assertFalse(bad, 'a built-in permission cannot be redeclared')
                assertType(badWhy, 'string', 'and says why')

                local badRole, badRoleWhy = exports.whip_core:EnsureJob(PERM_KEY, { roles = { { name = 'X', level = 500 } } })
                assertFalse(badRole, 'a role level outside 1-100 is refused before anything is written')
                assertType(badRoleWhy, 'string', 'and says why')

                assertOk(exports.whip_core:FirePlayer(source, PERM_KEY), nil, 'fired from the perm job')
            end,
        },

        -- ==========================================
        -- Roles: CreateJobRole / UpdateJobRole / DeleteJobRole (8 Oct 2026)
        -- ==========================================
        {
            name = 'Role exports as code: create, change keeping the job\'s own permissions, delete',
            fn = function(source, ctx)
                local role, why = exports.whip_core:CreateJobRole(PERM_KEY, {
                    name = 'Detective', level = 30, permissions = { cuff = true, bankAccess = 'deposit' },
                })
                assertOk(role, why, 'CreateJobRole')
                assertEqual(role.level, 30, 'at its level')
                assertTrue(role.permissions.cuff == true, 'with the job\'s own permission')
                assertEqual(role.permissions.bankAccess, 'deposit', 'and its bank access')

                local dup, dupWhy = exports.whip_core:CreateJobRole(PERM_KEY, { name = 'detective', level = 10 })
                assertFalse(dup, 'a name the job has (any case) is refused')
                assertEqual(dupWhy, 'There is already a role called Detective', 'and says why')
                local typo, typoWhy = exports.whip_core:CreateJobRole(PERM_KEY, { name = 'Typo', level = 10, permissions = { canhire = true } })
                assertFalse(typo, 'a permission the job does not have is refused, not dropped')
                assertType(typoWhy, 'string', 'and says why')
                local high, highWhy = exports.whip_core:CreateJobRole(PERM_KEY, { name = 'Too High', level = 101 })
                assertFalse(high, 'a level above 100 is refused')
                assertType(highWhy, 'string', 'and says why')

                assertOk(exports.whip_core:UpdateJobRole(PERM_KEY, 'Detective', { permissions = { canHire = true } }),
                    nil, 'a permission added')
                local byName = {}
                for _, r in ipairs(exports.whip_core:GetJobRoles(PERM_KEY)) do byName[r.name] = r end
                local det = byName.Detective or { permissions = {} }
                assertTrue(det.permissions.canHire == true, 'it has the new one')
                assertTrue(det.permissions.cuff == true, 'and kept the job\'s own')
                assertEqual(det.permissions.bankAccess, 'deposit', 'and its bank access')

                assertOk(exports.whip_core:UpdateJobRole(PERM_KEY, role.roleId, {
                    name = 'Inspector', level = 35, permissions = { cuff = false, bankAccess = 'none' },
                }), nil, 'renamed, moved, a permission and the bank access taken away')
                byName = {}
                for _, r in ipairs(exports.whip_core:GetJobRoles(PERM_KEY)) do byName[r.name] = r end
                assertNil(byName.Detective, 'the old name is gone')
                local insp = byName.Inspector or { permissions = {} }
                assertEqual(insp.level, 35, 'the new level')
                assertNil(insp.permissions.cuff, 'cuff taken away')
                assertNil(insp.permissions.bankAccess, 'no bank access')
                assertTrue(insp.permissions.canHire == true, 'canHire untouched')

                assertOk(exports.whip_core:HirePlayer(source, PERM_KEY, 'Inspector'), nil, 'the tester holds it')
                local used, usedWhy = exports.whip_core:DeleteJobRole(PERM_KEY, 'Inspector')
                assertFalse(used, 'a role someone holds is not deleted')
                assertEqual(usedWhy, WHY.roleUsed, 'and says why')
                assertOk(exports.whip_core:FirePlayer(source, PERM_KEY), nil, 'fired')
                assertOk(exports.whip_core:DeleteJobRole(PERM_KEY, 'Inspector'), nil, 'DeleteJobRole')
                local gone = exports.whip_core:UpdateJobRole(PERM_KEY, 'Inspector', { level = 2 })
                assertFalse(gone, 'and it is gone')
            end,
        },
        {
            name = 'Role exports with opts.by: canManage, the rank rule, and the level 100 role stays',
            fn = function(source, ctx)
                local by = { by = source }
                assertOk(exports.whip_core:HirePlayer(source, PERM_KEY, 'Sergeant'), nil, 'the tester is a Sergeant (50)')

                local noPerm, noPermWhy = exports.whip_core:CreateJobRole(PERM_KEY, { name = 'Clerk', level = 10 }, by)
                assertFalse(noPerm, 'without canManage, refused')
                assertEqual(noPermWhy, WHY.permission, 'and says why')
                local nobody, nobodyWhy = exports.whip_core:CreateJobRole(PERM_KEY, { name = 'Clerk', level = 10 }, { by = 65000 })
                assertFalse(nobody, 'a by naming nobody is refused')
                assertEqual(nobodyWhy, WHY.byNobody, 'and says why')

                assertOk(exports.whip_core:UpdateJobRole(PERM_KEY, 'Sergeant', { permissions = { canManage = true } }),
                    nil, 'Sergeants may manage now (as code)')

                local peer, peerWhy = exports.whip_core:CreateJobRole(PERM_KEY, { name = 'Clerk', level = 50 }, by)
                assertFalse(peer, 'a role at their own level is refused')
                assertEqual(peerWhy, WHY.rank, 'and says why')
                local clerk, clerkWhy = exports.whip_core:CreateJobRole(PERM_KEY, { name = 'Clerk', level = 40 }, by)
                assertOk(clerk, clerkWhy, 'a role below them is made')

                -- Never more than they have (Josh, 8 Oct 2026): a Sergeant holds cuff and canManage, no bank access.
                local more, moreWhy = exports.whip_core:CreateJobRole(PERM_KEY, { name = 'Hirer', level = 10, permissions = { canHire = true } }, by)
                assertFalse(more, 'a role that may hire, from someone who may not, is refused')
                assertEqual(moreWhy, WHY.power, 'and says why')
                local bank, bankWhy = exports.whip_core:UpdateJobRole(PERM_KEY, 'Clerk', { permissions = { bankAccess = 'view' } }, by)
                assertFalse(bank, 'bank access they do not have themselves is refused')
                assertEqual(bankWhy, WHY.power, 'and says why')
                assertOk(exports.whip_core:UpdateJobRole(PERM_KEY, 'Clerk', { permissions = { cuff = true } }, by), nil,
                    'one they hold is fine')

                local own, ownWhy = exports.whip_core:UpdateJobRole(PERM_KEY, 'Sergeant', { level = 60 }, by)
                assertFalse(own, 'their own role is not theirs to change')
                assertEqual(ownWhy, WHY.rank, 'and says why')
                local raise, raiseWhy = exports.whip_core:UpdateJobRole(PERM_KEY, 'Clerk', { level = 60 }, by)
                assertFalse(raise, 'a role is not raised to their level or past it')
                assertEqual(raiseWhy, WHY.rank, 'and says why')
                assertOk(exports.whip_core:UpdateJobRole(PERM_KEY, 'Clerk', { level = 45 }, by), nil, 'a change below them is made')
                local boss, bossWhy = exports.whip_core:DeleteJobRole(PERM_KEY, 'Boss', by)
                assertFalse(boss, 'a role above them is not theirs to delete')
                assertEqual(bossWhy, WHY.rank, 'and says why')
                assertOk(exports.whip_core:DeleteJobRole(PERM_KEY, 'Clerk', by), nil, 'one below them is')

                -- At level 100 the rank rule lets them do anything, but the job keeps a level 100 role.
                assertOk(exports.whip_core:SetPlayerRole(source, PERM_KEY, 'Boss'), nil, 'the tester is the Boss (100)')
                local lower, lowerWhy = exports.whip_core:UpdateJobRole(PERM_KEY, 'Boss', { level = 90 }, by)
                assertFalse(lower, 'the only level 100 role is not lowered')
                assertEqual(lowerWhy, WHY.topRole, 'and says why')
                local del, delWhy = exports.whip_core:DeleteJobRole(PERM_KEY, 'Boss', by)
                assertFalse(del, 'nor deleted')
                assertEqual(delWhy, WHY.topRole, 'and says why')
                assertOk(exports.whip_core:CreateJobRole(PERM_KEY, { name = 'Co-Boss', level = 100 }, by), nil,
                    'a second level 100 role')
                assertOk(exports.whip_core:UpdateJobRole(PERM_KEY, 'Co-Boss', { level = 90 }, by), nil,
                    'which can be lowered, with Boss still at 100')
                assertOk(exports.whip_core:DeleteJobRole(PERM_KEY, 'Co-Boss', by), nil, 'and deleted')

                assertOk(exports.whip_core:FirePlayer(source, PERM_KEY), nil, 'fired from the perm job')
            end,
        },
        {
            -- The phone's Business app clocks a player on through the export, as the player: the job's
            -- selfClockOn = false holds there as it does for the client's ClockOn.
            name = 'ClockOn with opts.by: only yourself, and only where the job lets you',
            fn = function(source, ctx)
                assertOk(exports.whip_core:HirePlayer(source, PERM_KEY, 'Cadet'), nil, 'the tester is a Cadet')
                local other, otherWhy = exports.whip_core:ClockOn(source, PERM_KEY, { by = { charId = 2000000000 } })
                assertFalse(other, 'someone else cannot clock you on as a player')
                assertEqual(otherWhy, 'A player clocks only themselves on', 'and says why')
                assertOk(exports.whip_core:ClockOn(source, PERM_KEY, { by = source }), nil, 'yourself: on')
                assertOk(exports.whip_core:ClockOff(source, PERM_KEY), nil, 'and off')

                assertOk(exports.whip_core:EnsureJob(PERM_KEY, { name = 'Test Perm Job', selfClockOn = false }), nil, 'the job now puts people on duty itself')
                local self, selfWhy = exports.whip_core:ClockOn(source, PERM_KEY, { by = source })
                assertFalse(self, 'a player cannot clock themselves on there')
                assertEqual(selfWhy, WHY.selfClock, 'and says why')
                assertOk(exports.whip_core:ClockOn(source, PERM_KEY), nil, 'the job\'s own code still can')
                assertOk(exports.whip_core:ClockOff(source, PERM_KEY), nil, 'off')

                assertOk(exports.whip_core:EnsureJob(PERM_KEY, { name = 'Test Perm Job', selfClockOn = true }), nil, 'back to self clock-on')
                assertOk(exports.whip_core:FirePlayer(source, PERM_KEY), nil, 'fired from the perm job')
            end,
        },

        -- ==========================================
        -- Ownership — the owner holds the top role (Josh, 2026-09-23)
        -- ==========================================
        {
            -- Ownership used to mean only the business bank account: an owner who had not also
            -- been hired into the Owner role could not hire, price stock or clock on at their own
            -- business. It is resolved in Jobs.getPlayerRole now — no employee row involved.
            name = 'A job\'s owner holds its top role without being on the payroll',
            fn = function(source, ctx)
                ensureOwnedJob(source, ctx)

                assertNil((exports.whip_core:GetJobEmployees(OWNED_KEY) or {})[ctx.charId],
                    'the owner is not an employee')

                local role = exports.whip_core:GetPlayerRole(source, OWNED_KEY)
                assertNotNil(role, 'but has a role')
                assertEqual(role.level, ctx.ownedTopLevel, 'the job\'s top role')
                assertTrue(exports.whip_core:HasJobPermission(source, OWNED_KEY, 'canHire'),
                    'with its permissions')

                local jobs = exports.whip_core:GetPlayerJobs(source)
                assertNotNil(jobs[ctx.ownedJobId], 'and the job is in their job list')
                assertEqual(jobs[ctx.ownedJobId].roleLevel, ctx.ownedTopLevel, 'shown at the top role')
            end,
        },
        {
            name = 'The owner can clock on at their own business, and counts as on duty',
            fn = function(source, ctx)
                ensureOwnedJob(source, ctx)
                assertOk(exports.whip_core:ClockOn(source, OWNED_KEY), nil, 'ClockOn at their own job')
                assertTrue(exports.whip_core:IsPlayerClockedOn(source, OWNED_KEY), 'clocked on')
                assertNotNil(onDutyList(exports.whip_core:GetClockedOnEmployees(OWNED_KEY), ctx.charId),
                    'listed as on duty, employed there or not')
                assertOk(exports.whip_core:ClockOff(source, OWNED_KEY), nil, 'ClockOff')
            end,
        },
        {
            -- Also the positive case of GetJobBankAccounts, which 03_bank can only test empty.
            name = 'An owned job opens a business account, with the owner holding it',
            fn = function(source, ctx)
                ensureOwnedJob(source, ctx)
                local accs = exports.whip_core:GetJobBankAccounts(ctx.ownedJobId)
                assertEqual(#accs, 1, 'exactly one business account')
                assertEqual(accs[1].ownerCharId, ctx.charId, 'owned by the job\'s owner')
                assertEqual(accs[1].type, 'business', 'of the business type')
                assertEqual(accessRole(accs[1].accountId, ctx.charId), 'owner', 'with owner access')

                local closed, closeWhy = exports.whip_core:CloseBankAccount(accs[1].accountId, source)
                assertFalse(closed, 'the owner cannot close it as a player')
                assertEqual(closeWhy, 'A job\'s account closes with the job', 'and is told why')
            end,
        },
        {
            -- THE 'owner' ANSWER OF ForceRevokeAccess, which is not a failure. Hiring someone syncs
            -- their account access to their role and firing them revokes it — and neither may take
            -- the account from its owner.
            name = 'Hiring and firing the owner never takes their account away',
            fn = function(source, ctx)
                ensureOwnedJob(source, ctx)
                assertNotNil(ctx.ownedAccountId, 'the job has a business account')
                assertNotNil(ctx.ownedLowRoleId, 'the job has a lowest role')

                local hired, hErr = exports.whip_core:HirePlayer(source, OWNED_KEY, ctx.ownedLowRoleId)
                assertOk(hired, hErr, 'the owner hired at the lowest role')
                assertEqual(accessRole(ctx.ownedAccountId, ctx.charId), 'owner', 'still the account\'s owner')
                assertEqual(exports.whip_core:GetPlayerRole(source, OWNED_KEY).level, ctx.ownedTopLevel,
                    'and ownership still outranks the employee row')

                local fired, fErr = exports.whip_core:FirePlayer(source, OWNED_KEY)
                assertOk(fired, fErr, 'the owner fired from their own payroll')
                assertEqual(accessRole(ctx.ownedAccountId, ctx.charId), 'owner', 'the account survives the fire')
                assertNil((exports.whip_core:GetJobEmployees(OWNED_KEY) or {})[ctx.charId], 'no longer employed')
            end,
        },
        {
            -- The account keeps its owner either way, so the job would read "no owner" while the old
            -- one still held the money. Refused inside Jobs.update — every path, not only the panel.
            name = 'UpdateJob refuses to clear the owner of a job with a business account',
            fn = function(source, ctx)
                ensureOwnedJob(source, ctx)
                local ok, why = exports.whip_core:UpdateJob(OWNED_KEY, { owner = false })
                assertFalse(ok, 'refused')
                assertEqual(why, WHY.hasAccount, 'and says why')
                assertEqual(exports.whip_core:GetJob(OWNED_KEY).ownerCharId, ctx.charId, 'still the owner in memory')
                assertDbScalar('SELECT `ownerCharId` FROM `jobs` WHERE `jobId` = ?', { ctx.ownedJobId },
                    ctx.charId, 'and on disk')
            end,
        },
        {
            -- The Job Manager's blank owner box sends 0. The panel used to hold the owner rules itself;
            -- it is a thin Jobs.update call now, so it must meet the same refusal.
            name = 'The Job Manager\'s blank owner box meets the same rule',
            fn = function(source, ctx)
                ensureOwnedJob(source, ctx)
                assertTrue(ClientExecWait(source, 'whip_core:server:jmUpdateJob', 5000, ctx.ownedJobId, { ownerCharId = 0 }),
                    'the server answered')
                assertEqual(exports.whip_core:GetJob(OWNED_KEY).ownerCharId, ctx.charId, 'still the owner')
                assertEqual(exports.whip_core:GetPlayerRole(source, OWNED_KEY).level, ctx.ownedTopLevel,
                    'with the top role')
            end,
        },
        {
            -- ROW FIRST, MEMORY SECOND (Jobs.update). A write that fails must leave the job as the
            -- server already believed it — not renamed in memory until the next restart undoes it.
            name = 'A job update whose write fails changes nothing, and says so',
            fn = function(source, ctx)
                ensureOwnedJob(source, ctx)
                local before = exports.whip_core:GetJob(OWNED_KEY).name

                assertTrue(exports.whip_core:__TestFailNextQuery('UPDATE `jobs`'), 'fault armed')
                local ok, why = exports.whip_core:UpdateJob(OWNED_KEY, { name = '_test renamed' })
                local stillArmed = exports.whip_core:__TestRawFaultArmed()
                exports.whip_core:__TestFailNextQuery(nil)
                assertNil(stillArmed, 'the fault fired on the update\'s own write')
                assertFalse(ok, 'the update reports failure')
                assertEqual(why, DB_ERROR, 'with its reason')

                assertEqual(exports.whip_core:GetJob(OWNED_KEY).name, before, 'the name is unchanged in memory')
                assertDbScalar('SELECT `name` FROM `jobs` WHERE `jobId` = ?', { ctx.ownedJobId }, before,
                    'and on disk')
            end,
        },
        {
            name = 'UpdateJob refuses an owner who does not exist',
            fn = function(source, ctx)
                ensureOwnedJob(source, ctx)
                local ok, why = exports.whip_core:UpdateJob(OWNED_KEY, { owner = { charId = 2000000000 } })
                assertFalse(ok, 'refused')
                assertEqual(why, WHY.character, 'and says why')
                assertEqual(exports.whip_core:GetJob(OWNED_KEY).ownerCharId, ctx.charId, 'the owner is unchanged')
            end,
        },
        {
            -- OWNERSHIP MOVES AS ONE THING. The new owner takes the top role and the account; the old
            -- one loses both at once — including the manager access SetAccountOwner steps them down
            -- to, which on a business account is still enough to empty it (ECO1). Through the export
            -- now: the rules live in Jobs.update, where every path meets them.
            name = 'Handing the job to someone else moves the top role and the account with it',
            fn = function(source, ctx)
                ensureOwnedJob(source, ctx)
                -- Not deleted: a new owner must be a real character (Jobs.update refuses anyone else).
                local rows = DbQuery('SELECT `charId` FROM `characters` WHERE `charId` <> ? AND `deleted` IS NULL LIMIT 1', { ctx.charId })
                if not rows[1] then skip('this database holds only one character — nobody to hand the job to') end
                local OTHER = tonumber(rows[1].charId)

                local mark = #_jobEvents
                local ok, why = exports.whip_core:UpdateJob(OWNED_KEY, { owner = { charId = OTHER } })
                assertOk(ok, why, 'UpdateJob to a new owner')

                assertEqual(exports.whip_core:GetJob(OWNED_KEY).ownerCharId, OTHER, 'the job has its new owner')
                assertNil(exports.whip_core:GetPlayerRole(source, OWNED_KEY), 'the old owner holds no role')
                assertFalse(exports.whip_core:HasJobPermission(source, OWNED_KEY, 'canHire'), 'and no powers')
                assertNil((exports.whip_core:GetPlayerJobs(source) or {})[ctx.ownedJobId], 'nor the job in their list')

                assertEqual(accessRole(ctx.ownedAccountId, OTHER), 'owner', 'the account follows the job')
                assertNil(accessRole(ctx.ownedAccountId, ctx.charId), 'and the old owner keeps no access to it')
                assertDbScalar('SELECT `ownerCharId` FROM `bank_accounts` WHERE `accountId` = ?',
                    { ctx.ownedAccountId }, OTHER, 'the account\'s owner on disk')

                local updated = eventsSince(mark, 'updated', OWNED_KEY)
                assertEqual(#updated, 1, 'one updated event')
                assertEqual(updated[1] and updated[1].oldOwnerCharId, ctx.charId, 'naming the old owner')
                assertEqual(updated[1] and updated[1].ownerCharId, OTHER, 'and the new')
            end,
        },
        {
            -- J-B4: a deleted job's business account used to stay open, linked to nothing.
            name = 'DeleteJob refuses while the business account holds money, then closes it with the job',
            fn = function(source, ctx)
                ensureOwnedJob(source, ctx)
                if not ctx.ownedAccountId then skip('the owned job has no business account') end

                assertOk(exports.whip_core:BankSystemDeposit(ctx.ownedAccountId, 5, '_test float'), nil, 'money in')
                local refused, why = exports.whip_core:DeleteJob(OWNED_KEY)
                assertFalse(refused, 'refused while the account holds money')
                assertEqual(why, WHY.moneyLeft, 'and says why')
                assertNotNil(exports.whip_core:GetJob(OWNED_KEY), 'the job is still there')

                assertOk(exports.whip_core:BankSystemWithdraw(ctx.ownedAccountId, 5, '_test float back'), nil, 'money out')
                local mark = #_jobEvents
                local ok, delWhy = exports.whip_core:DeleteJob(OWNED_KEY)
                assertOk(ok, delWhy, 'DeleteJob')
                assertNil(exports.whip_core:GetJob(OWNED_KEY), 'the job is gone')
                assertNil(exports.whip_core:GetBankAccount(ctx.ownedAccountId), 'and its account closed with it')
                assertEqual(#eventsSince(mark, 'deleted', OWNED_KEY), 1, 'one deleted event, with its key')

                -- Nothing left for teardown; clear the fixture ids so it does not look for them.
                pcall(DbQuery, 'DELETE FROM `bank_access` WHERE `accountId` = ?', { ctx.ownedAccountId })
                ctx.ownedJobId, ctx.ownedAccountId = nil, nil
            end,
        },
        {
            name = 'A job another running resource declares cannot be changed or deleted from here',
            fn = function()
                local theirs
                for _, job in pairs(exports.whip_core:GetJobs() or {}) do
                    local by = type(job.settings) == 'table' and job.settings.declaredBy or nil
                    if by and by ~= GetCurrentResourceName() and GetResourceState(by) == 'started' then theirs = job; break end
                end
                if not theirs then skip('no running resource declares a job') end
                local by = theirs.settings.declaredBy

                local ok, why = exports.whip_core:UpdateJob(theirs.key, { name = '_test must not stick' })
                assertFalse(ok, 'UpdateJob on ' .. by .. "'s job: refused")
                assertTrue(tostring(why):find(by, 1, true) ~= nil, 'and names whose it is: ' .. tostring(why))
                assertEqual(exports.whip_core:GetJob(theirs.key).name, theirs.name, 'the name is unchanged')

                local okDel, whyDel = exports.whip_core:DeleteJob(theirs.key)
                assertFalse(okDel, 'DeleteJob: refused (' .. tostring(whyDel) .. ')')
                assertNotNil(exports.whip_core:GetJob(theirs.key), 'the job is still there')
            end,
        },
    }
})
