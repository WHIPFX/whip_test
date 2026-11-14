--- Clear a door's requirements, and PROVE the clear landed.
---
--- `UpdateDoor(id, { requirements = nil })` is a no-op, and always was. In Lua that constructs an
--- EMPTY table, and Doors.update copies with `for k, v in pairs(updates)` — so the loop body
--- never runs, requirements is never cleared, and the call still returns true.
---
--- Four tests in this module reset that way between cases, which made their isolation fictional:
--- each door carried the previous test's requirements forward, and they passed only because
--- every one of them replaced `requirements` wholesale before asserting. The next test written
--- here would have failed for a reason that had nothing to do with it.
---
--- `{}` is the correct sentinel — isAuthorizedWithReason treats an empty table as "no
--- requirements" — and unlike nil it is a value the copy loop can actually see.
---@param doorId number
local function ClearDoorReqs(doorId)
    exports.whip_core:UpdateDoor(doorId, { requirements = {} })
    local d = exports.whip_core:GetDoor(doorId)
    assertTrue(d ~= nil and (d.requirements == nil or next(d.requirements) == nil),
        'door requirements were actually cleared')
end

local DOOR_MODEL = GetHashKey('prop_door_01')

--- An ACE nobody holds, for a requirement the tester cannot meet.
local UNMET_ACE = '_test_nonexistent_ace_permission'

--- Create a test door at a position, first removing a TEST door a crashed run left there.
---
--- Doors.create refuses a second door within half a metre of an existing one, so a single leaked
--- door used to fail every later run's setup at that spot — and the old DeleteDoor test, at a
--- fixed (0, 0, 50), was permanently red after its first failure.
---@return table|false door, string|nil err
local function createDoorAt(label, x, y, z)
    local old = exports.whip_core:GetDoorByPosition(x, y, z, 0.6)
    if old and type(old.label) == 'string' and old.label:sub(1, 5) == '_test' then
        exports.whip_core:DeleteDoor(old.doorId)
    end
    return exports.whip_core:CreateDoor({
        label = label, model = DOOR_MODEL, x = x, y = y, z = z, heading = 0,
    })
end

--- Press the door key from the tester's client — the player-facing path, with its distance gate
--- and authorization, rather than the SetDoorLocked export that skips both.
local function toggle(source, doorId)
    -- doorToggle is rate limited to one per 500ms; a press straight after another is refused.
    Wait(600)
    assertTrue(ClientExecWait(source, 'whip_core:server:doorToggle', 3000, doorId),
        'the server answered the door press')
end

--- A door column as a plain number. TINYINT(1) arrives from the driver as a boolean; the cast
--- makes the comparison independent of that.
local function doorColumn(column, doorId)
    return ('SELECT CAST(`%s` AS UNSIGNED) FROM `doors` WHERE `doorId` = ?'):format(column), { doorId }
end

RegisterTestModule({
    order    = 15,
    category = 'Doors (Server)',
    setup = function(source, ctx)
        local player = exports.whip_core:GetPlayer(source)
        local pos = GetEntityCoords(GetPlayerPed(source))
        ctx.charId = player.charId
        ctx.pos    = { x = pos.x, y = pos.y, z = pos.z }

        -- Near the player — inside doorToggle's reach, so the player-facing tests below work.
        local door1, err1 = createDoorAt('_test_door_1', pos.x + 2, pos.y, pos.z)
        if not door1 then error('could not create door 1: ' .. tostring(err1)) end
        ctx.doorId1 = door1.doorId

        local door2, err2 = createDoorAt('_test_door_2', pos.x + 4, pos.y, pos.z)
        if not door2 then error('could not create door 2: ' .. tostring(err2)) end
        ctx.doorId2 = door2.doorId
    end,
    teardown = function(ctx)
        pcall(exports.whip_core.__TestSetDbFaultMode, exports.whip_core, nil)
        pcall(exports.whip_core.__TestFailNextQuery, exports.whip_core, nil)
        for _, key in ipairs({ 'doorId1', 'doorId2', 'tempId', 'farId' }) do
            if ctx[key] then pcall(exports.whip_core.DeleteDoor, exports.whip_core, ctx[key]) end
        end
    end,
    tests = {
        -- ==========================================
        -- Create + Read
        -- ==========================================
        {
            name = 'CreateDoor writes the rows and returns the doors',
            fn = function(source, ctx)
                assertNotNil(ctx.doorId1, 'door1 created')
                assertNotNil(ctx.doorId2, 'door2 created')
                assertDbRowCount('SELECT `doorId` FROM `doors` WHERE `doorId` IN (?, ?)',
                    { ctx.doorId1, ctx.doorId2 }, 2, 'both doors are in the table')
            end,
        },
        {
            name = 'GetDoor returns correct data',
            fn = function(source, ctx)
                local door = exports.whip_core:GetDoor(ctx.doorId1)
                assertNotNil(door, 'GetDoor')
                assertEqual(door.doorId, ctx.doorId1, 'doorId')
                assertEqual(door.label, '_test_door_1', 'label')
                assertTrue(door.locked, 'a new door is locked')
                assertTrue(exports.whip_core:IsDoorLocked(ctx.doorId1), 'and IsDoorLocked agrees')
            end,
        },
        {
            name = 'GetDoor returns nil for invalid ID',
            fn = function()
                assertNil(exports.whip_core:GetDoor(999999), 'invalid')
            end,
        },
        {
            name = 'GetDoors includes test doors',
            fn = function(source, ctx)
                local all = exports.whip_core:GetDoors()
                assertType(all, 'table', 'type')
                local found = false
                for _, d in ipairs(all) do
                    if d.doorId == ctx.doorId1 then found = true; break end
                end
                assertTrue(found, 'test door in list')
            end,
        },
        {
            -- Was `#nearby >= 1`, which any real door in the area satisfies on its own.
            name = 'GetDoorsNearby finds the test doors, and not from far away',
            fn = function(source, ctx)
                local door = exports.whip_core:GetDoor(ctx.doorId1)

                local function ids(list)
                    local set = {}
                    for _, d in ipairs(list or {}) do set[d.doorId] = true end
                    return set
                end

                local near = ids(exports.whip_core:GetDoorsNearby(door.x, door.y, door.z, 10))
                assertTrue(near[ctx.doorId1] == true, 'door1 is within 10m of itself')
                assertTrue(near[ctx.doorId2] == true, 'door2 is 2m further along')

                local far = ids(exports.whip_core:GetDoorsNearby(door.x + 1000, door.y, door.z, 10))
                assertFalse(far[ctx.doorId1] == true, 'door1 is not within 10m of a point 1km away')
            end,
        },

        -- ==========================================
        -- Lock / Unlock
        -- ==========================================
        {
            name = 'SetDoorLocked(false) unlocks door',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:SetDoorLocked(ctx.doorId1, false), 'SetDoorLocked answered ok')
                assertFalse(exports.whip_core:IsDoorLocked(ctx.doorId1), 'unlocked')
            end,
        },
        {
            name = 'SetDoorLocked(true) locks door',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:SetDoorLocked(ctx.doorId1, true), 'SetDoorLocked answered ok')
                assertTrue(exports.whip_core:IsDoorLocked(ctx.doorId1), 'locked')
            end,
        },
        {
            -- EVERY DOOR STARTS LOCKED ON EVERY START (Josh, 2026-09-23), so lock state is not
            -- written anywhere — Doors.updateState changes memory and tells the players nearby, and
            -- a database hiccup can no longer refuse somebody a door.
            name = 'Locking and unlocking never touches the database',
            fn = function(source, ctx)
                exports.whip_core:SetDoorLocked(ctx.doorId1, true)
                -- A real update, so the row's `locked` column holds a known value first.
                assertTrue(exports.whip_core:UpdateDoor(ctx.doorId1, { label = '_test_door_1' }), 'row written')
                local q, p = doorColumn('locked', ctx.doorId1)
                assertDbScalar(q, p, 1, 'the row says locked')

                assertTrue(exports.whip_core:SetDoorLocked(ctx.doorId1, false), 'unlocked in memory')
                assertFalse(exports.whip_core:IsDoorLocked(ctx.doorId1), 'the server believes it is open')
                assertDbScalar(q, p, 1, 'and the row was not written')

                exports.whip_core:SetDoorLocked(ctx.doorId1, true)
            end,
        },

        -- ==========================================
        -- Linking
        -- ==========================================
        {
            name = 'LinkDoors links two doors, both ways, in the rows',
            fn = function(source, ctx)
                local ok = exports.whip_core:LinkDoors(ctx.doorId1, ctx.doorId2)
                assertTrue(ok, 'LinkDoors')
                local d1 = exports.whip_core:GetDoor(ctx.doorId1)
                local d2 = exports.whip_core:GetDoor(ctx.doorId2)
                assertEqual(d1.linkedDoorId, ctx.doorId2, 'door1 linked to door2')
                assertEqual(d2.linkedDoorId, ctx.doorId1, 'door2 linked to door1')

                -- The point of linkDoors is ONE transaction for the pair; half a link on disk is a
                -- door that follows its partner while the partner ignores it after a restart.
                assertDbScalar('SELECT `linkedDoorId` FROM `doors` WHERE `doorId` = ?', { ctx.doorId1 },
                    ctx.doorId2, 'door1 row')
                assertDbScalar('SELECT `linkedDoorId` FROM `doors` WHERE `doorId` = ?', { ctx.doorId2 },
                    ctx.doorId1, 'door2 row')

                local selfOk, selfErr = exports.whip_core:LinkDoors(ctx.doorId1, ctx.doorId1)
                assertFalse(selfOk, 'a door cannot be linked to itself')
                assertEqual(selfErr, 'A door cannot be linked to itself', 'and says so')
            end,
        },
        {
            name = 'Linked door state follows primary',
            fn = function(source, ctx)
                -- Unlock door1, door2 should follow. updateState is synchronous, so no wait.
                exports.whip_core:SetDoorLocked(ctx.doorId1, false)
                assertFalse(exports.whip_core:IsDoorLocked(ctx.doorId2), 'linked door unlocked')
                -- Lock door1, door2 should follow
                exports.whip_core:SetDoorLocked(ctx.doorId1, true)
                assertTrue(exports.whip_core:IsDoorLocked(ctx.doorId2), 'linked door locked')
            end,
        },
        {
            name = 'A link that fails to save leaves both doors as they were',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:__TestSetDbFaultMode('door_link'), 'fault armed')
                local ok = exports.whip_core:LinkDoors(ctx.doorId2, ctx.doorId1)
                assertFalse(ok, 'the faulted link reported failure')
                assertNil(exports.whip_core:__TestGetDbFaultMode(), 'the fault was consumed by the link')
                assertEqual(exports.whip_core:GetDoor(ctx.doorId1).linkedDoorId, ctx.doorId2,
                    'door1 still linked as before')
                assertEqual(exports.whip_core:GetDoor(ctx.doorId2).linkedDoorId, ctx.doorId1,
                    'door2 still linked as before')
            end,
        },

        -- ==========================================
        -- The player's door key (doorToggle)
        -- ==========================================
        {
            name = 'The door key toggles a door the player may use, and its linked partner with it',
            fn = function(source, ctx)
                exports.whip_core:SetDoorLocked(ctx.doorId1, true)

                toggle(source, ctx.doorId1)
                assertLastReject('whip_core:server:doorToggle', nil, 'accepted')
                assertFalse(exports.whip_core:IsDoorLocked(ctx.doorId1), 'the door unlocked')
                assertFalse(exports.whip_core:IsDoorLocked(ctx.doorId2), 'and its partner with it')

                toggle(source, ctx.doorId1)
                assertTrue(exports.whip_core:IsDoorLocked(ctx.doorId1), 'pressed again, it locked')
                assertTrue(exports.whip_core:IsDoorLocked(ctx.doorId2), 'and its partner with it')
            end,
        },
        {
            -- Authorization runs on BOTH directions: it used to sit inside `if door.locked`, so
            -- anyone could LOCK any open door, including ones they could never unlock again.
            name = 'The door key refuses a door the player may not use, in both directions',
            fn = function(source, ctx)
                exports.whip_core:UpdateDoor(ctx.doorId1, { requirements = { ace = UNMET_ACE } })
                exports.whip_core:SetDoorLocked(ctx.doorId1, true)

                toggle(source, ctx.doorId1)
                assertTrue(exports.whip_core:IsDoorLocked(ctx.doorId1), 'a locked door stayed locked')

                exports.whip_core:SetDoorLocked(ctx.doorId1, false)
                toggle(source, ctx.doorId1)
                assertFalse(exports.whip_core:IsDoorLocked(ctx.doorId1), 'an open door could not be locked either')

                ClearDoorReqs(ctx.doorId1)
                exports.whip_core:SetDoorLocked(ctx.doorId1, true)
            end,
        },
        {
            -- Only the door pressed used to be checked, and its partner was flipped with no check —
            -- so the unrestricted leaf of a double door opened the restricted one.
            name = 'The door key refuses the whole toggle when the linked partner is not allowed',
            fn = function(source, ctx)
                exports.whip_core:UpdateDoor(ctx.doorId2, { requirements = { ace = UNMET_ACE } })
                exports.whip_core:SetDoorLocked(ctx.doorId1, true)

                toggle(source, ctx.doorId1)
                assertLastReject('whip_core:server:doorToggle', 'not authorized for the linked door',
                    'refused for the partner')
                assertTrue(exports.whip_core:IsDoorLocked(ctx.doorId1), 'the door pressed did not move')
                assertTrue(exports.whip_core:IsDoorLocked(ctx.doorId2), 'nor did its partner')

                ClearDoorReqs(ctx.doorId2)
            end,
        },
        {
            name = 'The door key refuses a door out of reach',
            fn = function(source, ctx)
                local far, err = createDoorAt('_test_door_far', ctx.pos.x + 200, ctx.pos.y, ctx.pos.z)
                assertOk(far, err, 'a door 200m away')
                ctx.farId = far.doorId

                toggle(source, ctx.farId)
                assertLastReject('whip_core:server:doorToggle', 'Too far away', 'refused on distance')
                assertTrue(exports.whip_core:IsDoorLocked(ctx.farId), 'and it stayed locked')

                assertTrue(exports.whip_core:DeleteDoor(ctx.farId), 'far door removed')
                ctx.farId = nil
            end,
        },
        {
            -- Autolock is scheduled by the door key only, so it is tested through it. SetTimeout
            -- cannot be cancelled, which is why only the NEWEST timer may re-lock (doors.lua).
            name = 'Autolock re-locks a door, and its partner, after the delay',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:UpdateDoor(ctx.doorId1, { autolock = true, autolockDelay = 1 }),
                    'autolock on, one second')
                exports.whip_core:SetDoorLocked(ctx.doorId1, true)

                toggle(source, ctx.doorId1)
                assertFalse(exports.whip_core:IsDoorLocked(ctx.doorId1), 'the key opened it')

                local relocked = waitFor(function()
                    return exports.whip_core:IsDoorLocked(ctx.doorId1)
                end, 4000)
                assertTrue(relocked == true, 'it locked itself again')
                assertTrue(exports.whip_core:IsDoorLocked(ctx.doorId2), 'and so did its partner')

                exports.whip_core:UpdateDoor(ctx.doorId1, { autolock = false, autolockDelay = 10 })
            end,
        },

        -- ==========================================
        -- Authorization
        -- ==========================================
        {
            name = 'CanUseDoor returns true with no requirements',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:CanUseDoor(source, ctx.doorId1), 'no reqs = authorized')
            end,
        },
        {
            name = 'CanUseDoor returns false with unmet requirement',
            fn = function(source, ctx)
                -- Set a requirement the player definitely doesn't have
                exports.whip_core:UpdateDoor(ctx.doorId1, {
                    requirements = { ace = UNMET_ACE }
                })
                assertFalse(exports.whip_core:CanUseDoor(source, ctx.doorId1), 'unmet req = denied')
                -- Clean up
                ClearDoorReqs(ctx.doorId1)
            end,
        },
        {
            name = 'CanUseDoor returns true with empty requirements',
            fn = function(source, ctx)
                -- Empty table should be treated same as nil (the {} vs nil fix)
                exports.whip_core:UpdateDoor(ctx.doorId1, { requirements = {} })
                assertTrue(exports.whip_core:CanUseDoor(source, ctx.doorId1), 'empty reqs = authorized')
                ClearDoorReqs(ctx.doorId1)
            end,
        },
        {
            name = 'CanUseDoor passes ACE check',
            fn = function(source, ctx)
                -- whip.devtools ACE should be allowed (test player has it)
                exports.whip_core:UpdateDoor(ctx.doorId1, {
                    requirements = { ace = 'whip.devtools' }
                })
                assertTrue(exports.whip_core:CanUseDoor(source, ctx.doorId1), 'ACE match = authorized')
                ClearDoorReqs(ctx.doorId1)
            end,
        },
        {
            name = 'CanUseDoor passes charId check',
            fn = function(source, ctx)
                exports.whip_core:UpdateDoor(ctx.doorId1, {
                    requirements = { charIds = { ctx.charId } }
                })
                assertTrue(exports.whip_core:CanUseDoor(source, ctx.doorId1), 'charId match = authorized')
                ClearDoorReqs(ctx.doorId1)
            end,
        },

        -- ==========================================
        -- Update + Delete
        -- ==========================================
        {
            name = 'UpdateDoor changes fields, in memory and in the row',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:UpdateDoor(ctx.doorId1, {
                    label  = '_test_renamed',
                    folder = '_test_folder',
                }), 'UpdateDoor')
                local door = exports.whip_core:GetDoor(ctx.doorId1)
                assertEqual(door.label, '_test_renamed', 'label updated')
                assertEqual(door.folder, '_test_folder', 'folder updated')
                assertDbScalar('SELECT `label` FROM `doors` WHERE `doorId` = ?', { ctx.doorId1 },
                    '_test_renamed', 'label on disk')
                assertDbScalar('SELECT `folder` FROM `doors` WHERE `doorId` = ?', { ctx.doorId1 },
                    '_test_folder', 'folder on disk')
            end,
        },
        {
            -- No `defaultLocked` any more: the field is still in the table but nothing reads it,
            -- because every door starts locked (doors.lua rowToDoor). Asserting it round-trips
            -- tested a setting that no longer decides anything.
            name = 'UpdateDoor changes autolock settings, in memory and in the row',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:UpdateDoor(ctx.doorId1, {
                    autolock      = true,
                    autolockDelay = 5,
                }), 'UpdateDoor')
                local door = exports.whip_core:GetDoor(ctx.doorId1)
                assertTrue(door.autolock, 'autolock on')
                assertEqual(door.autolockDelay, 5, 'delay 5s')
                local q, p = doorColumn('autolock', ctx.doorId1)
                assertDbScalar(q, p, 1, 'autolock on disk')
                assertDbScalar('SELECT `autolockDelay` FROM `doors` WHERE `doorId` = ?', { ctx.doorId1 },
                    5, 'delay on disk')

                exports.whip_core:UpdateDoor(ctx.doorId1, { autolock = false, autolockDelay = 10 })
            end,
        },
        {
            -- A field the UPDATE does not name used to be written into the cache and never saved:
            -- `UpdateDoor(id, { x = 5 })` moved a door until the next restart moved it back.
            name = 'UpdateDoor refuses a field it cannot save',
            fn = function(source, ctx)
                local before = exports.whip_core:GetDoor(ctx.doorId1).x
                local ok, why = exports.whip_core:UpdateDoor(ctx.doorId1, { x = 5 })
                assertFalse(ok, 'refused')
                assertEqual(why, '"x" is not an updatable door field', 'and says which field')
                assertEqual(exports.whip_core:GetDoor(ctx.doorId1).x, before, 'the door did not move')
            end,
        },
        {
            -- THE CACHE FOLLOWS THE WRITE: a refused write must leave the server describing the door
            -- the database still has.
            name = 'An update that fails to save changes nothing',
            fn = function(source, ctx)
                local before = exports.whip_core:GetDoor(ctx.doorId1).label

                assertTrue(exports.whip_core:__TestSetDbFaultMode('door_update'), 'fault armed')
                local ok = exports.whip_core:UpdateDoor(ctx.doorId1, { label = '_test_fault' })
                assertFalse(ok, 'the faulted update reported failure')
                assertNil(exports.whip_core:__TestGetDbFaultMode(), 'the fault was consumed by the update')

                assertEqual(exports.whip_core:GetDoor(ctx.doorId1).label, before, 'memory unchanged')
                assertDbScalar('SELECT `label` FROM `doors` WHERE `doorId` = ?', { ctx.doorId1 },
                    before, 'disk unchanged')
            end,
        },
        {
            name = 'A door whose insert fails is not created',
            fn = function(source, ctx)
                local x, y, z = ctx.pos.x, ctx.pos.y + 12, ctx.pos.z
                assertTrue(exports.whip_core:__TestFailNextQuery('INSERT INTO `doors`'), 'fault armed')
                local door = createDoorAt('_test_door_fault', x, y, z)
                assertFalse(door, 'CreateDoor reported failure')
                assertNil(exports.whip_core:__TestRawFaultArmed(), 'the insert really was attempted and failed')
                assertNil(exports.whip_core:GetDoorByPosition(x, y, z, 0.6), 'and no door exists there')
            end,
        },
        {
            name = 'DeleteDoor removes the door, from memory and the table — and a failed delete removes neither',
            fn = function(source, ctx)
                local temp, err = createDoorAt('_test_temp', ctx.pos.x, ctx.pos.y + 8, ctx.pos.z)
                assertOk(temp, err, 'temp created')
                ctx.tempId = temp.doorId

                assertTrue(exports.whip_core:__TestSetDbFaultMode('door_delete'), 'fault armed')
                assertFalse(exports.whip_core:DeleteDoor(ctx.tempId), 'the faulted delete reported failure')
                assertNotNil(exports.whip_core:GetDoor(ctx.tempId), 'still in memory')
                assertDbRowCount('SELECT `doorId` FROM `doors` WHERE `doorId` = ?', { ctx.tempId }, 1,
                    'still on disk')

                assertTrue(exports.whip_core:DeleteDoor(ctx.tempId), 'DeleteDoor')
                assertNil(exports.whip_core:GetDoor(ctx.tempId), 'gone from memory')
                assertDbRowCount('SELECT `doorId` FROM `doors` WHERE `doorId` = ?', { ctx.tempId }, 0,
                    'gone from disk')
                ctx.tempId = nil
            end,
        },

        -- ==========================================
        -- Wire projection (door sync redesign)
        -- ==========================================
        {
            -- The Door Manager edits requirements/autolock/folder, so the ACE-gated getDoorAll
            -- path — which serves GetDoors' records — must keep FULL records. Ordinary
            -- clients get the Doors.wireOne projection instead; the client half of this
            -- contract is asserted in whip_test/client/tests/13_doors.lua.
            name = 'GetDoors keeps full records (Door Manager contract)',
            fn = function(source, ctx)
                exports.whip_core:UpdateDoor(ctx.doorId1, { requirements = { ace = '_test_wire' } })
                local found = nil
                for _, d in ipairs(exports.whip_core:GetDoors()) do
                    if d.doorId == ctx.doorId1 then found = d; break end
                end
                assertNotNil(found, 'test door in GetDoors')
                assertNotNil(found.requirements, 'requirements present on the full record')
                assertEqual(found.requirements.ace, '_test_wire', 'requirements content intact')
                ClearDoorReqs(ctx.doorId1)
            end,
        },
    }
})
