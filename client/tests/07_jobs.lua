-- ============================================
-- Client: Jobs
-- ============================================
--
-- The job cache is filled by the server (jobsSync, jobClockState), and the client cannot hire
-- itself. So these assert what must hold of that cache whatever it contains: the exports have to
-- AGREE with each other. They used to assert types — `== true` is always a boolean and "nil or a
-- table" is every value GetPlayerJob can return — which no cache, however wrong, could fail.
--
-- Since 09-25 a job is named by its jobId or its key here too, the cache carries each job's
-- permissions (HasJobPermission) and duty order (GetPlayerJob), and ClockOn / ClockOff answer.

RegisterClientTestModule({
    order    = 7,
    category = 'Client: Jobs',
    tests = {
        {
            name = 'IsPlayerClockedOn and HasJobPermission are false for a job that does not exist',
            fn = function()
                assertFalse(exports.whip_core:IsPlayerClockedOn(999999), 'not clocked on to a job id nobody has')
                assertFalse(exports.whip_core:IsPlayerClockedOn('_no_such_job_'), 'nor to a key nobody has')
                assertFalse(exports.whip_core:HasJobPermission(999999, 'canHire'), 'no permission at a job id nobody has')
                assertFalse(exports.whip_core:HasJobPermission('_no_such_job_', 'canHire'), 'nor at a key nobody has')
            end,
        },
        {
            name = 'GetPlayerJobs, IsPlayerClockedOn and GetPlayerJob tell the same story',
            fn = function()
                local jobs = exports.whip_core:GetPlayerJobs()
                assertType(jobs, 'table', 'GetPlayerJobs type')

                -- Every job the cache says is clocked on, IsPlayerClockedOn agrees about — by jobId
                -- and by key alike.
                local anyOn, topOrder = false, nil
                for jobId, data in pairs(jobs) do
                    local label = ('job %s'):format(tostring(data.key or jobId))
                    assertEqual(exports.whip_core:IsPlayerClockedOn(jobId), data.clockedOn == true,
                        label .. ': clockedOn and IsPlayerClockedOn(jobId) agree')
                    if data.key then
                        assertEqual(exports.whip_core:IsPlayerClockedOn(data.key), data.clockedOn == true,
                            label .. ': and IsPlayerClockedOn(key)')
                    end
                    if data.clockedOn then
                        anyOn = true
                        local order = tonumber(data.dutyOrder) or 0
                        if not topOrder or order > topOrder then topOrder = order end
                    end
                end

                -- "Clocked on to anything" matches, and an active job exists exactly when it is true.
                assertEqual(exports.whip_core:IsPlayerClockedOn(), anyOn,
                    'IsPlayerClockedOn() is true exactly when some job is clocked on')
                local active = exports.whip_core:GetPlayerJob()
                assertEqual(active ~= nil, anyOn, 'GetPlayerJob answers exactly when clocked on')
                if active then
                    assertTrue(active.clockedOn == true, 'the active job is one that is clocked on')
                    -- The most recent clock-on, as the server's GetPlayerJob says (JOB-5).
                    assertEqual(tonumber(active.dutyOrder) or 0, topOrder, 'the one clocked on most recently')
                end
            end,
        },
        {
            -- The server sends what each role may do; HasJobPermission reads it back, by either name.
            name = 'HasJobPermission answers what the job list says, by jobId and by key',
            fn = function()
                local checked = 0
                for jobId, data in pairs(exports.whip_core:GetPlayerJobs()) do
                    assertType(data.permissions, 'table', ('job %s: the list carries its permissions'):format(tostring(jobId)))
                    for _, perm in ipairs({ 'canHire', 'canFire', 'canPromote', 'canDemote', 'canManage' }) do
                        local want = data.permissions[perm] == true
                        assertEqual(exports.whip_core:HasJobPermission(jobId, perm), want,
                            ('job %s %s by jobId'):format(tostring(jobId), perm))
                        if data.key then
                            assertEqual(exports.whip_core:HasJobPermission(data.key, perm), want,
                                ('job %s %s by key'):format(data.key, perm))
                        end
                    end
                    checked = checked + 1
                end
                if checked == 0 then skip('this character has no job, so there is no list to compare against') end
            end,
        },
        {
            -- They answered nothing, so a duty button could not say why nothing happened.
            name = 'ClockOn and ClockOff answer, with the reason, for a job that does not exist',
            fn = function()
                local on, onWhy = exports.whip_core:ClockOn('_no_such_job_')
                assertFalse(on, 'no clock-on at a job nobody has')
                -- Words, not a code, since audit 3 ARC-10 (whip_core's Jobs.WHY.job).
                assertEqual(onWhy, 'No such job', 'and it says why')

                local off, offWhy = exports.whip_core:ClockOff('_no_such_job_')
                assertFalse(off, 'no clock-off either')
                assertEqual(offWhy, 'No such job', 'and it says why')
            end,
        },
    }
})
