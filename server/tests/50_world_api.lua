-- ============================================
-- World API (server) — section 9 of the API TODO (WLD-1..10, 25 Sep 2026)
-- ============================================
--
-- What section 9 changed, each from the outside, as a satellite would call it:
--
--   doors    EnsureDoors / EnsureDoor (a resource declares its doors by key), UnlinkDoors, one lock
--            path (UpdateDoor's `locked` moves the linked twin), CreateDoor's answers, IsDoorLocked's
--            nil for an unknown door, IsAuthorizedForDoor's reason, requirements.onDuty
--   zones    EnsureZone follows its declaration, zones by key, DeleteZone, trackPlayers events
--   time     the setters answer (true | false, reason), IsBlackout, weather layers checked
--   misc     StartTimedAction's reasons, GetActiveTheme
--
-- NOT COVERED here, and why:
--   * a weather layer coming off when its resource stops, and another resource being refused it:
--     both need a second resource to start and stop mid-run.
--   * a client finding a saved zone by its key (ZoneIsInside, require = { zone = key }): the zone
--     reaches the client by broadcast, and no client seam reads it back yet.

local DOOR_MODEL = GetHashKey('prop_door_01')
local SET_ID     = '_test_world'
local PAIR_SET   = '_test_world_pair'   -- the WLD-7 test's own set, so it cannot touch SET_ID's doors
local ZONE_KEY   = '_test_world_zone'
local JOB_KEY    = '_test_world_job'
local UNMET_ACE  = '_test_nonexistent_ace_permission'

local function has(s, fragment)
    return type(s) == 'string' and s:find(fragment, 1, true) ~= nil
end

-- ---- zone events, as a server resource hears them ----

local zoneEvents = {}
AddEventHandler('whip_core:zone:entered', function(e) zoneEvents[#zoneEvents + 1] = { what = 'entered', e = e } end)
AddEventHandler('whip_core:zone:exited', function(e) zoneEvents[#zoneEvents + 1] = { what = 'exited', e = e } end)

--- The first recorded event of this kind, for this zone and player.
local function zoneEvent(what, zoneId, src)
    for _, ev in ipairs(zoneEvents) do
        if ev.what == what and type(ev.e) == 'table' and ev.e.zoneId == zoneId and ev.e.source == src then
            return ev.e
        end
    end
    return nil
end

-- ---- the job fixture, for the onDuty requirement ----

--- Remove the job and whatever it opened (its business account), as 04_jobs does.
local function disposeJob(source, key)
    local job = exports.whip_core:GetJob(key)
    if not job then return end
    local accounts = exports.whip_core:GetJobBankAccounts(job.jobId) or {}
    pcall(exports.whip_core.ClockOff, exports.whip_core, source, key)
    pcall(exports.whip_core.FirePlayer, exports.whip_core, source, key)
    pcall(exports.whip_core.DeleteJob, exports.whip_core, key)
    for _, acc in ipairs(accounts) do
        if exports.whip_core:GetBankAccount(acc.accountId) then DisposeTestAccount(acc.accountId) end
        pcall(DbQuery, 'DELETE FROM `bank_access` WHERE `accountId` = ?', { acc.accountId })
    end
end

--- A spot `dx`, `dy` metres from the tester, first clearing a TEST door a crashed run left there.
local function spot(ctx, dx, dy)
    local x, y, z = ctx.pos.x + dx, ctx.pos.y + dy, ctx.pos.z
    local old = exports.whip_core:GetDoorByPosition(x, y, z, 0.6)
    if old and type(old.label) == 'string' and old.label:sub(1, 5) == '_test' then
        pcall(exports.whip_core.DeleteDoor, exports.whip_core, old.doorId)
    end
    return x, y, z
end

local function createDoor(ctx, label, dx, dy, extra)
    local x, y, z = spot(ctx, dx, dy)
    local data = { label = label, model = DOOR_MODEL, x = x, y = y, z = z, heading = 0 }
    for k, v in pairs(extra or {}) do data[k] = v end
    local door, err = exports.whip_core:CreateDoor(data)
    if door then ctx.doors[#ctx.doors + 1] = door.doorId end
    return door, err
end

RegisterTestModule({
    order    = 50,
    category = 'World API',
    setup = function(source, ctx)
        local pos = GetEntityCoords(GetPlayerPed(source))
        ctx.pos = { x = pos.x, y = pos.y, z = pos.z }
        ctx.doors = {}
        -- A declared set left by a crashed run goes before the first test sees it.
        pcall(exports.whip_core.EnsureDoors, exports.whip_core, {}, { id = SET_ID })
        pcall(exports.whip_core.EnsureDoors, exports.whip_core, {}, { id = PAIR_SET })
        pcall(exports.whip_core.DeleteZone, exports.whip_core, ZONE_KEY)
        disposeJob(source, JOB_KEY)
    end,
    teardown = function(ctx, source)
        -- An empty list is the whole set: every door the tests declared is released (deleted).
        pcall(exports.whip_core.EnsureDoors, exports.whip_core, {}, { id = SET_ID })
        pcall(exports.whip_core.EnsureDoors, exports.whip_core, {}, { id = PAIR_SET })
        -- The door that moved between sets ends in EnsureDoor's own, which the list above does not hold.
        if ctx.moverId then
            pcall(exports.whip_core.ReleaseDoor, exports.whip_core, ctx.moverId, { id = 'door:mover' })
        end
        for _, id in ipairs(ctx.doors or {}) do
            pcall(exports.whip_core.DeleteDoor, exports.whip_core, id)
        end
        pcall(exports.whip_core.DeleteZone, exports.whip_core, ZONE_KEY)
        for _, id in ipairs({ '_test_world_track', '_test_world_quiet', '_test_world_bucket' }) do
            pcall(exports.whip_core.ZoneRemove, exports.whip_core, id)
        end
        if ctx.blackoutWas ~= nil then pcall(exports.whip_core.SetBlackout, exports.whip_core, ctx.blackoutWas) end
        if source then
            pcall(exports.whip_core.ClearPlayerWeatherLayer, exports.whip_core, source, '_test_layer')
            disposeJob(source, JOB_KEY)
        end
    end,
    tests = {
        -- ==========================================
        -- Doors
        -- ==========================================
        {
            name = 'CreateDoor refuses no data, and a duplicate hands back the door in the way',
            fn = function(source, ctx)
                local ok, why = exports.whip_core:CreateDoor(nil)
                assertFalse(ok, 'CreateDoor(nil) is refused, not thrown')
                assertType(why, 'string', 'with a reason')

                local door, err = createDoor(ctx, '_test_world_dup', 30, 30)
                assertOk(door, err, 'the first door')
                local again, why2, existing = exports.whip_core:CreateDoor({
                    label = '_test_world_dup2', model = DOOR_MODEL, x = door.x, y = door.y, z = door.z,
                })
                assertFalse(again, 'a second door on the same spot is refused')
                assertTrue(has(why2, 'already exists'), 'saying why (got: ' .. tostring(why2) .. ')')
                assertEqual(existing, door.doorId, 'and naming the door in the way as a third value')
            end,
        },
        {
            name = 'IsDoorLocked is nil for an unknown door; IsAuthorizedForDoor says why it refuses',
            fn = function(source, ctx)
                assertNil(exports.whip_core:IsDoorLocked(999999999), 'an unknown door is nil, not "unlocked"')
                local ok, why = exports.whip_core:IsAuthorizedForDoor(source, 999999999)
                assertFalse(ok, 'an unknown door is refused')
                assertEqual(why, 'Door not found', 'and says so')

                local door, err = createDoor(ctx, '_test_world_ace', 32, 30, { requirements = { ace = UNMET_ACE } })
                assertOk(door, err, 'a door needing an ACE nobody holds')
                assertEqual(exports.whip_core:IsDoorLocked(door.doorId), true, 'a real door answers true or false')
                local ok2, why2 = exports.whip_core:IsAuthorizedForDoor(source, door.doorId)
                assertFalse(ok2, 'refused')
                assertTrue(has(why2, UNMET_ACE), 'with the reason the player is shown (got: ' .. tostring(why2) .. ')')
            end,
        },
        {
            name = 'A door asking for the job on duty lets an employee in only while clocked on',
            fn = function(source, ctx)
                local job, jobErr = exports.whip_core:EnsureJob(JOB_KEY, { name = 'Test World Job' })
                assertOk(job, jobErr, 'the test job')
                local roles = exports.whip_core:GetJobRoles(JOB_KEY) or {}
                local low = roles[#roles]
                if not low then skip('the test job has no roles') end
                assertOk(exports.whip_core:HirePlayer(source, JOB_KEY, low.roleId), nil, 'the tester is hired')
                pcall(exports.whip_core.ClockOff, exports.whip_core, source, JOB_KEY)

                local door, err = createDoor(ctx, '_test_world_duty', 34, 30, { requirements = { jobs = { JOB_KEY } } })
                assertOk(door, err, 'a door for the job')
                assertTrue(exports.whip_core:IsAuthorizedForDoor(source, door.doorId),
                    '`jobs` alone means a role there, on duty or not')

                assertOk(exports.whip_core:UpdateDoor(door.doorId, { requirements = { jobs = { JOB_KEY }, onDuty = true } }),
                    nil, 'now it asks for on duty')
                local ok, why = exports.whip_core:IsAuthorizedForDoor(source, door.doorId)
                assertFalse(ok, 'off duty, refused')
                assertTrue(has(why, '(on duty)'), 'saying the job is wanted on duty (got: ' .. tostring(why) .. ')')

                assertOk(exports.whip_core:ClockOn(source, JOB_KEY), nil, 'clocked on')
                assertTrue(exports.whip_core:IsAuthorizedForDoor(source, door.doorId), 'on duty, let in')
                pcall(exports.whip_core.ClockOff, exports.whip_core, source, JOB_KEY)
            end,
        },
        {
            name = 'UpdateDoor\'s locked takes the lock path: the linked twin moves too; defaultLocked is refused',
            fn = function(source, ctx)
                local d1, e1 = createDoor(ctx, '_test_world_l1', 36, 30)
                local d2, e2 = createDoor(ctx, '_test_world_l2', 38, 30)
                assertOk(d1, e1, 'door 1')
                assertOk(d2, e2, 'door 2')
                assertOk(exports.whip_core:LinkDoors(d1.doorId, d2.doorId), nil, 'linked')
                ctx.l1, ctx.l2 = d1.doorId, d2.doorId

                assertOk(exports.whip_core:UpdateDoor(d1.doorId, { locked = false }), nil, 'unlocked by update')
                assertEqual(exports.whip_core:IsDoorLocked(d1.doorId), false, 'the door opened')
                assertEqual(exports.whip_core:IsDoorLocked(d2.doorId), false, 'and its twin with it')
                assertOk(exports.whip_core:UpdateDoor(d1.doorId, { locked = true, label = '_test_world_l1b' }),
                    nil, 'locked, with a label in the same update')
                assertEqual(exports.whip_core:IsDoorLocked(d2.doorId), true, 'the twin locked too')
                assertEqual(exports.whip_core:GetDoor(d1.doorId).label, '_test_world_l1b', 'and the label was written')

                local ok, why = exports.whip_core:UpdateDoor(d1.doorId, { defaultLocked = false })
                assertFalse(ok, 'defaultLocked is no longer a field')
                assertTrue(has(why, 'defaultLocked'), 'and the refusal names it (got: ' .. tostring(why) .. ')')
            end,
        },
        {
            name = 'UnlinkDoors undoes both halves, in memory and on disk; a door not linked answers true',
            fn = function(source, ctx)
                if not (ctx.l1 and ctx.l2) then skip('the linked pair from the test above was not made') end
                assertOk(exports.whip_core:UnlinkDoors(ctx.l1), nil, 'unlinked')
                assertNil(exports.whip_core:GetDoor(ctx.l1).linkedDoorId, 'this door has no partner')
                assertNil(exports.whip_core:GetDoor(ctx.l2).linkedDoorId, 'nor has its old partner')
                local rows = DbQuery('SELECT `linkedDoorId` FROM `doors` WHERE `doorId` IN (?, ?)', { ctx.l1, ctx.l2 })
                assertEqual(#rows, 2, 'both rows read back')
                for _, row in ipairs(rows) do assertNil(row.linkedDoorId, 'no link on disk') end
                assertOk(exports.whip_core:UnlinkDoors(ctx.l1), nil, 'unlinking again is not a failure')
            end,
        },
        {
            name = 'EnsureDoors makes a keyed set once, links it by key, and a second run changes nothing',
            fn = function(source, ctx)
                local ax, ay, az = spot(ctx, 40, 32)
                local bx, by, bz = spot(ctx, 42, 32)
                ctx.list = {
                    { key = 'a', model = DOOR_MODEL, coords = vector4(ax, ay, az, 90.0), link = 'b',
                      label = '_test_world_a', requirements = { ace = UNMET_ACE } },
                    { key = 'b', model = DOOR_MODEL, coords = vector3(bx, by, bz), label = '_test_world_b' },
                }
                local res, err = exports.whip_core:EnsureDoors(ctx.list, { id = SET_ID, label = 'Test World' })
                assertOk(res, err, 'EnsureDoors')
                assertType(res.doors.a, 'number', 'door a made')
                assertType(res.doors.b, 'number', 'door b made')
                assertNil(next(res.failed or {}), 'nothing failed')
                ctx.setA, ctx.setB = res.doors.a, res.doors.b

                local a = exports.whip_core:GetDoor(ctx.setA)
                assertEqual(a.linkedDoorId, ctx.setB, 'a and b are linked, by key')
                assertEqual(a.heading, 90.0, 'a vector4 carries the heading')
                local mb = a.metadata and a.metadata.managedBy or {}
                assertEqual(mb.system, 'resource:whip_test', 'managed by this resource')
                assertEqual(mb.id, SET_ID, 'in this set')
                assertEqual(mb.key, 'a', 'under its key')
                assertFalse(exports.whip_core:IsAuthorizedForDoor(source, ctx.setA), 'its requirements applied')
                assertEqual(#exports.whip_core:GetManagedDoors(SET_ID), 2, 'two doors in the set')

                local res2, err2 = exports.whip_core:EnsureDoors(ctx.list, { id = SET_ID, label = 'Test World' })
                assertOk(res2, err2, 'the same list again')
                assertEqual(res2.doors.a, ctx.setA, 'the same door a')
                assertEqual(res2.doors.b, ctx.setB, 'the same door b')
                assertEqual(#exports.whip_core:GetManagedDoors(SET_ID), 2, 'still two doors')
            end,
        },
        {
            name = 'A declared door refuses a change from outside the list; a changed list is applied, and a dropped key is released',
            fn = function(source, ctx)
                if not ctx.setA then skip('the set from the test above was not made') end
                local ok, why = exports.whip_core:UpdateDoor(ctx.setA, { requirements = {} })
                assertFalse(ok, 'its access is the list\'s')
                assertTrue(has(why, 'belongs to'), 'saying whose (got: ' .. tostring(why) .. ')')

                local list2 = { { key = 'a', model = DOOR_MODEL, coords = ctx.list[1].coords, label = '_test_world_a2',
                                  autolock = true, autolockDelay = 7 } }
                local res, err = exports.whip_core:EnsureDoors(list2, { id = SET_ID })
                assertOk(res, err, 'the changed list')
                assertEqual(res.doors.a, ctx.setA, 'a is the same door')
                assertEqual(res.released, 1, 'b left the list, so it was released')
                assertNil(exports.whip_core:GetDoor(ctx.setB), 'and, made by the list, deleted')

                local a = exports.whip_core:GetDoor(ctx.setA)
                assertEqual(a.label, '_test_world_a2', 'the label followed the list')
                assertNil(a.linkedDoorId, 'the link went with b')
                assertTrue(a.requirements == nil or next(a.requirements) == nil, 'requirements left the list, so none')
                assertTrue(a.autolock, 'autolock on')
                assertEqual(a.autolockDelay, 7, 'after 7 seconds')
                assertTrue(exports.whip_core:IsAuthorizedForDoor(source, ctx.setA), 'and anyone may open it now')
            end,
        },
        {
            name = 'EnsureDoors checks the whole list first: one bad door and nothing is written',
            fn = function(source, ctx)
                local x, y, z = spot(ctx, 44, 32)
                local cases = {
                    { list = { { key = 'x', model = DOOR_MODEL, coords = vector3(x, y, z) },
                               { key = 'x', model = DOOR_MODEL, coords = vector3(x, y + 2, z) } }, why = 'two doors are called' },
                    { list = { { key = 'y', model = DOOR_MODEL, coords = vector3(x, y, z) },
                               { key = 'z', model = DOOR_MODEL } }, why = 'needs coords' },
                    { list = { { key = 'y', model = DOOR_MODEL, coords = vector3(x, y, z), link = 'nope' } },
                      why = 'which is not in the list' },
                    { list = { { key = 'bad key!', model = DOOR_MODEL, coords = vector3(x, y, z) } }, why = 'needs a key' },
                    { list = { { key = 'y', coords = vector3(x, y, z) } }, why = 'needs a model' },
                }
                for i, c in ipairs(cases) do
                    local ok, why = exports.whip_core:EnsureDoors(c.list, { id = SET_ID .. '_bad', prune = false })
                    assertFalse(ok, ('case %d is refused'):format(i))
                    assertTrue(has(why, c.why), ('case %d says "%s" (got: %s)'):format(i, c.why, tostring(why)))
                end
                assertNil(exports.whip_core:GetDoorByPosition(x, y, z, 0.6), 'and no door was made at the spot')
            end,
        },
        {
            name = 'EnsureDoor makes one keyed door and answers it; again, the same door',
            fn = function(source, ctx)
                local x, y, z = spot(ctx, 46, 32)
                local door, err = exports.whip_core:EnsureDoor('solo', { model = DOOR_MODEL, coords = vector3(x, y, z),
                                                                        label = '_test_world_solo' }, { id = SET_ID })
                assertOk(door, err, 'EnsureDoor')
                assertType(door.doorId, 'number', 'a door')
                local again = exports.whip_core:EnsureDoor('solo', { model = DOOR_MODEL, coords = vector3(x, y, z),
                                                                    label = '_test_world_solo' }, { id = SET_ID })
                assertEqual(again and again.doorId, door.doorId, 'the same door')
                local bad, why = exports.whip_core:EnsureDoor('solo2', { model = DOOR_MODEL }, { id = SET_ID })
                assertFalse(bad, 'no coords, refused')
                assertType(why, 'string', 'with a reason')
            end,
        },
        {
            -- ONE KEY MOVES BETWEEN EnsureDoor AND AN EnsureDoors LIST (audit 7, WLD-2). EnsureDoor keeps
            -- its door in a set of its own, 'door:<key>' (audit 6), and a resource moving that key into
            -- its EnsureDoors list was refused on every start: "already belongs to whip_test" — itself.
            -- The other side: another manager of the same resource, under a different key, is still refused.
            name = 'A key moves from EnsureDoor to an EnsureDoors list and back; another manager is still refused',
            fn = function(source, ctx)
                local x, y, z = spot(ctx, 48, 32)
                local decl = { model = DOOR_MODEL, coords = vector3(x, y, z), label = '_test_world_mover' }
                local door, err = exports.whip_core:EnsureDoor('mover', decl)
                assertOk(door, err, 'EnsureDoor, in its own set')
                ctx.moverId = door.doorId

                local listed = { key = 'mover', model = DOOR_MODEL, coords = decl.coords, label = decl.label }
                local res, resErr = exports.whip_core:EnsureDoors({ listed }, { id = SET_ID, prune = false })
                assertOk(res, resErr, 'EnsureDoors')
                assertNil(res.failed and res.failed.mover, 'the list took it (got: ' .. tostring(res.failed and res.failed.mover) .. ')')
                assertEqual(res.doors.mover, ctx.moverId, 'the same door, not a second one')
                local mb = exports.whip_core:GetDoor(ctx.moverId).metadata.managedBy
                assertEqual(mb.id, SET_ID, 'now in the list\'s set')
                assertTrue(mb.created, 'still marked as made by this resource, so a release deletes it')

                local back, backErr = exports.whip_core:EnsureDoor('mover', decl)
                assertOk(back, backErr, 'and back to EnsureDoor')
                assertEqual(back.doorId, ctx.moverId, 'the same door again')
                assertEqual(exports.whip_core:GetDoor(ctx.moverId).metadata.managedBy.id, 'door:mover', 'in EnsureDoor\'s set')

                local other, why, conflict = exports.whip_core:AdoptOrCreateDoor(
                    { model = DOOR_MODEL, x = x, y = y, z = z }, { id = '_test_world_other', key = 'other' })
                assertFalse(other, 'another manager of this resource, another key, is refused the door')
                assertTrue(has(why, 'already belongs'), 'saying whose (got: ' .. tostring(why) .. ')')
                assertEqual(conflict, ctx.moverId, 'naming the door in the way')
            end,
        },
        {
            -- THE LIST OWNS THE LINK, PRUNING OR NOT (audit 7, WLD-7). Link cleanup ran only with
            -- prune on, so a `prune = false` list whose two entries both dropped `link` stayed paired.
            name = 'A prune = false list that stops declaring a link between two of its doors unlinks them',
            fn = function(source, ctx)
                local lx, ly, lz = spot(ctx, 50, 32)
                local rx, ry, rz = spot(ctx, 52, 32)
                local function list(withLink)
                    return {
                        { key = 'l', model = DOOR_MODEL, coords = vector3(lx, ly, lz), label = '_test_world_pl',
                          link = withLink and 'r' or nil },
                        { key = 'r', model = DOOR_MODEL, coords = vector3(rx, ry, rz), label = '_test_world_pr' },
                    }
                end
                local res, err = exports.whip_core:EnsureDoors(list(true), { id = PAIR_SET, prune = false })
                assertOk(res, err, 'the pair, linked')
                assertEqual(exports.whip_core:GetDoor(res.doors.l).linkedDoorId, res.doors.r, 'l and r are linked')

                local res2, err2 = exports.whip_core:EnsureDoors(list(false), { id = PAIR_SET, prune = false })
                assertOk(res2, err2, 'the same doors, no link')
                assertNil(next(res2.failed or {}), 'nothing failed')
                assertNil(exports.whip_core:GetDoor(res.doors.l).linkedDoorId, 'l is unlinked')
                assertNil(exports.whip_core:GetDoor(res.doors.r).linkedDoorId, 'and so is r')
            end,
        },

        -- ==========================================
        -- Zones
        -- ==========================================
        {
            name = 'EnsureZone refuses what cannot be a zone, and says why',
            fn = function()
                local cases = {
                    { key = ZONE_KEY, data = nil, why = 'a zone is a table' },
                    { key = ZONE_KEY, data = { type = 'cube', pos = vector3(0, 0, 0) }, why = "type is 'box'" },
                    { key = ZONE_KEY, data = { type = 'sphere', pos = vector3(0, 0, 0) }, why = 'needs a radius' },
                    { key = ZONE_KEY, data = { type = 'box', pos = vector3(0, 0, 0) }, why = 'needs size' },
                    { key = ZONE_KEY, data = { type = 'poly', points = { { x = 0, y = 0 } } }, why = 'at least 3 points' },
                    { key = 'bad key!', data = { type = 'sphere', pos = vector3(0, 0, 0), radius = 1 }, why = 'a zone key' },
                }
                for i, c in ipairs(cases) do
                    local ok, why = exports.whip_core:EnsureZone(c.key, c.data)
                    assertFalse(ok, ('case %d is refused'):format(i))
                    assertTrue(has(why, c.why), ('case %d says "%s" (got: %s)'):format(i, c.why, tostring(why)))
                end
            end,
        },
        {
            name = 'A saved zone answers to its key; the same declaration keeps an admin\'s edit, a changed one wins',
            fn = function(source, ctx)
                local here = vector3(ctx.pos.x, ctx.pos.y, ctx.pos.z)
                local decl = { type = 'sphere', pos = here, radius = 5.0, label = '_test world' }
                local zone, err = exports.whip_core:EnsureZone(ZONE_KEY, decl)
                assertOk(zone, err, 'EnsureZone')
                assertTrue(has(zone.id, 'dbzone_'), 'a saved zone, id ' .. tostring(zone.id))

                assertTrue(exports.whip_core:ZoneContains(ZONE_KEY, here), 'ZoneContains by key')
                local def = exports.whip_core:GetZoneDef(ZONE_KEY)
                assertEqual(def and def.id, zone.id, 'GetZoneDef by key')
                local inside = false
                for _, s in ipairs(exports.whip_core:GetPlayersInZone(ZONE_KEY) or {}) do
                    if s == source then inside = true end
                end
                assertTrue(inside, 'GetPlayersInZone by key finds the tester')

                -- An admin renames it in the zone editor.
                Wait(300)
                assertTrue(ClientExecWait(source, 'whip_core:server:zeUpdateZone', 3000, zone.id, { label = '_test edited' }),
                    'the editor update was answered')
                assertEqual(exports.whip_core:GetZoneDef(ZONE_KEY).label, '_test edited', 'renamed')

                local same, sErr = exports.whip_core:EnsureZone(ZONE_KEY, decl)
                assertOk(same, sErr, 'the same declaration again')
                assertEqual(exports.whip_core:GetZoneDef(ZONE_KEY).label, '_test edited', 'the admin\'s edit stands')

                decl.radius = 6.0
                local changed, cErr = exports.whip_core:EnsureZone(ZONE_KEY, decl)
                assertOk(changed, cErr, 'a changed declaration')
                assertEqual(changed.id, zone.id, 'the same zone')
                assertEqual(changed.radius, 6.0, 'with the new radius')
                assertEqual(changed.label, '_test world', 'and the declared label back')
            end,
        },
        {
            name = 'DeleteZone removes a saved zone by key; an unknown key and a server zone are refused',
            fn = function(source, ctx)
                if not exports.whip_core:GetZoneDef(ZONE_KEY) then skip('the zone from the test above was not made') end
                assertOk(exports.whip_core:DeleteZone(ZONE_KEY), nil, 'deleted by key')
                assertNil(exports.whip_core:GetZoneDef(ZONE_KEY), 'gone')
                local ok, why = exports.whip_core:DeleteZone(ZONE_KEY)
                assertFalse(ok, 'deleting it again is refused')
                assertEqual(why, 'Zone not found', 'and says so')

                assertOk(exports.whip_core:ZoneRegister('_test_world_quiet', {
                    type = 'sphere', pos = vector3(ctx.pos.x, ctx.pos.y, ctx.pos.z), radius = 3.0,
                }), nil, 'a server zone')
                local ok2, why2 = exports.whip_core:DeleteZone('_test_world_quiet')
                assertFalse(ok2, 'DeleteZone does not remove a server zone')
                assertTrue(has(why2, 'ZoneRemove'), 'and points at what does (got: ' .. tostring(why2) .. ')')
            end,
        },
        {
            name = 'A server zone with trackPlayers announces who enters and leaves; one without stays quiet',
            fn = function(source, ctx)
                zoneEvents = {}
                local here = vector3(ctx.pos.x, ctx.pos.y, ctx.pos.z)
                assertOk(exports.whip_core:ZoneRegister('_test_world_track', {
                    type = 'sphere', pos = here, radius = 5.0, trackPlayers = true,
                }), nil, 'a tracked zone around the tester')

                local entered = waitFor(function() return zoneEvent('entered', '_test_world_track', source) end, 3500)
                assertNotNil(entered, 'whip_core:zone:entered for the tester')

                assertOk(exports.whip_core:ZoneRemove('_test_world_track'), nil, 'the zone removed')
                local exited = waitFor(function() return zoneEvent('exited', '_test_world_track', source) end, 3500)
                assertNotNil(exited, 'whip_core:zone:exited once it went')
                assertTrue(exited and exited.removed == true, 'marked removed')

                -- The quiet zone from the test above (or a fresh one) has the tester inside too.
                exports.whip_core:ZoneRegister('_test_world_quiet', { type = 'sphere', pos = here, radius = 3.0 })
                Wait(2500)
                assertNil(zoneEvent('entered', '_test_world_quiet', source), 'no event from a zone that did not ask')
            end,
        },
        {
            -- A ZONE IS A PLACE, IN ANY ROUTING BUCKET (audit 7, WLD-3). The audit-6 fix dropped every
            -- player outside bucket 0, so a satellite's zone around players it had instanced was empty,
            -- with no word in the docs. Measured, the bucket put back, then judged.
            name = 'GetPlayersInZone counts a player standing in it from another routing bucket',
            fn = function(source)
                local here = GetEntityCoords(GetPlayerPed(source))
                assertOk(exports.whip_core:ZoneRegister('_test_world_bucket', {
                    type = 'sphere', pos = here, radius = 5.0,
                }), nil, 'a zone around the tester')
                local before = GetPlayerRoutingBucket(source)
                SetPlayerRoutingBucket(source, 7771)
                local inside = exports.whip_core:GetPlayersInZone('_test_world_bucket') or {}
                SetPlayerRoutingBucket(source, before)
                pcall(exports.whip_core.ZoneRemove, exports.whip_core, '_test_world_bucket')

                local found = false
                for _, s in ipairs(inside) do if s == source then found = true end end
                assertTrue(found, 'the tester, in bucket 7771, is inside')
                assertEqual(GetPlayerRoutingBucket(source), before, 'and is back in their own bucket')
            end,
        },

        -- ==========================================
        -- Time & weather
        -- ==========================================
        {
            name = 'The time setters answer, and refuse what is not a time instead of throwing',
            fn = function(source, ctx)
                local cases = {
                    { fn = 'SetTime',      args = { nil },     why = 'hour must be a number' },
                    { fn = 'SetTime',      args = { 'noon' },  why = 'hour must be a number' },
                    { fn = 'SetTime',      args = { 8, 'x' },  why = 'minute must be a number' },
                    { fn = 'SetWeather',   args = { nil },     why = 'weather' },
                    { fn = 'SetWeather',   args = { 'NOPE' },  why = 'Invalid weather' },
                    { fn = 'SetTimeScale', args = { 'fast' },  why = 'scale must be a number' },
                }
                for i, c in ipairs(cases) do
                    local ok, why = exports.whip_core[c.fn](exports.whip_core, table.unpack(c.args, 1, 2))
                    assertFalse(ok, ('case %d (%s) is refused'):format(i, c.fn))
                    assertTrue(has(why, c.why), ('case %d says "%s" (got: %s)'):format(i, c.why, tostring(why)))
                end

                ctx.blackoutWas = exports.whip_core:IsBlackout()
                assertType(ctx.blackoutWas, 'boolean', 'IsBlackout answers')
                assertTrue(exports.whip_core:SetBlackout(not ctx.blackoutWas), 'SetBlackout answers true')
                assertEqual(exports.whip_core:IsBlackout(), not ctx.blackoutWas, 'and IsBlackout reads it back')
                assertTrue(exports.whip_core:SetBlackout(ctx.blackoutWas), 'put back')
                ctx.blackoutWas = nil
            end,
        },
        {
            name = 'A weather layer is checked before it reaches the player, and can be cleared',
            fn = function(source)
                local ok, why = exports.whip_core:SetPlayerWeatherLayer(source, '_test_layer', { weather = 'NOPE' })
                assertFalse(ok, 'a weather that does not exist is refused')
                assertTrue(has(why, 'Invalid weather'), 'saying so (got: ' .. tostring(why) .. ')')
                local ok2, why2 = exports.whip_core:SetPlayerWeatherLayer(source, '_test_layer', { hour = 'late' })
                assertFalse(ok2, 'an hour that is not a number is refused')
                assertTrue(has(why2, 'hour'), 'saying so (got: ' .. tostring(why2) .. ')')
                local ok3, why3 = exports.whip_core:SetPlayerWeatherLayer(999999, '_test_layer', { weather = 'RAIN' })
                assertFalse(ok3, 'a player who is not there is refused')
                assertType(why3, 'string', 'with a reason')

                assertOk(exports.whip_core:SetPlayerWeatherLayer(source, '_test_layer',
                    { weather = 'rain', hour = 25, priority = 5, junk = true }), nil, 'a good layer')
                local layer = (exports.whip_core:GetPlayerWeatherLayers(source) or {})._test_layer
                assertNotNil(layer, 'held for the player')
                assertEqual(layer and layer.weather, 'RAIN', 'weather upper-cased')
                assertEqual(layer and layer.hour, 1, 'the hour wrapped')
                assertNil(layer and layer.junk, 'a field a layer cannot carry is dropped')

                assertOk(exports.whip_core:ClearPlayerWeatherLayer(source, '_test_layer'), nil, 'cleared')
                assertNil((exports.whip_core:GetPlayerWeatherLayers(source) or {})._test_layer, 'gone')
            end,
        },

        -- ==========================================
        -- Timed actions, themes
        -- ==========================================
        {
            name = 'StartTimedAction says why it refused',
            fn = function(source)
                local cases = {
                    { args = { 999999, '_test', 1000 }, why = 'no loaded player' },
                    { args = { source, '', 1000 },      why = 'needs a name' },
                    { args = { source, '_test', -5 },   why = 'durationMs' },
                    { args = { source, '_test', 0/0 },  why = 'durationMs' },
                }
                for i, c in ipairs(cases) do
                    local ok, why = exports.whip_core:StartTimedAction(table.unpack(c.args, 1, 3))
                    assertFalse(ok, ('case %d is refused'):format(i))
                    assertTrue(has(why, c.why), ('case %d says "%s" (got: %s)'):format(i, c.why, tostring(why)))
                end
            end,
        },
        {
            name = 'GetActiveTheme answers the theme in force, and who set it',
            fn = function()
                local theme, owner = exports.whip_core:GetActiveTheme()
                assertTrue(theme == nil or type(theme) == 'string', 'a theme resource, or nil for the stock look')
                if owner ~= nil then
                    assertType(owner, 'string', 'an override names the resource that set it')
                    assertType(theme, 'string', 'and the theme it applied')
                end
            end,
        },
    },
})
