-- ============================================
-- Client: Doors
-- ============================================
--
-- EVERY DOOR THIS MODULE CREATES IS A REAL `doors` ROW, synced to every client on the server. A
-- test that failed between its create and its delete used to leave one behind for good, so each
-- test now runs its body under pcall and deletes on the way out whatever happened, and the module
-- teardown sweeps any `_test_` door still in the cache.
--
-- The editor events are ACE-gated (whip.devtools, which /test already requires) and rate-limited
-- per event — doorCreate and doorDelete at one per 250ms — so every call goes through `fire`,
-- which spaces them out rather than having the second of two quick deletes silently refused.

local _lastFired = {}

--- Fire a door editor event, no sooner than 300ms after the last one of the same name.
local function fire(eventName, ...)
    local since = GetGameTimer() - (_lastFired[eventName] or 0)
    if since < 300 then Wait(300 - since) end
    _lastFired[eventName] = GetGameTimer()
    TriggerServerEvent(eventName, ...)
end

--- The cached door with this label, or nil.
local function doorByLabel(label)
    for _, d in ipairs(exports.whip_core:GetLoadedDoors()) do
        if d.label == label then return d end
    end
    return nil
end

--- Create a door through the editor event and wait for the create broadcast to reach the cache.
---@return table|nil door
local function createTestDoor(fields)
    fire('whip_core:server:doorCreate', fields)
    return waitFor(function() return doorByLabel(fields.label) end, 3000)
end

--- Delete a door and wait for the cache to let go of it.
---@return boolean gone
local function deleteTestDoor(doorId)
    if not doorId then return true end
    fire('whip_core:server:doorDelete', doorId)
    return waitFor(function() return exports.whip_core:GetDoor(doorId) == nil end, 3000) == true
end

RegisterClientTestModule({
    order    = 13,
    category = 'Client: Doors',
    teardown = function()
        -- Anything a failed test left, by the name every door here is given.
        for _, d in ipairs(exports.whip_core:GetLoadedDoors()) do
            if type(d.label) == 'string' and d.label:sub(1, 6) == '_test_' then
                deleteTestDoor(d.doorId)
            end
        end
    end,
    tests = {
        {
            name = 'Lookups answer nothing for a door that does not exist',
            fn = function()
                -- An unknown door is nil, not false: false would say "unlocked" (WLD-7).
                assertNil(exports.whip_core:IsDoorLocked(999999), 'IsDoorLocked of an unknown id is nil')
                assertNil(exports.whip_core:GetDoor(999999), 'GetDoor of an unknown id')
                assertNil(exports.whip_core:GetDoor({ entity = 0 }), 'GetDoor({ entity }) of no entity')
            end,
        },

        -- ==========================================
        -- Door sync transport (push model)
        -- ==========================================
        --
        -- These three are the only coverage the sync layer has: the module above them tests the
        -- export surface against an empty cache and passes whatever the transport does. They
        -- drive the ACE-gated editor events, so the test client must hold whip.devtools — the
        -- same assumption the Door Manager tests make. Failure mode reads accordingly.
        {
            name = 'Synced door carries no requirements (wire projection), and the lookups find it',
            fn = function()
                local pos = GetEntityCoords(PlayerPedId())
                local door = createTestDoor({
                    label = '_test_wire_proj', model = GetHashKey('prop_door_01'),
                    x = pos.x + 2.0, y = pos.y + 2.0, z = pos.z, heading = 0,
                    requirements = { ace = '_test_wire' },
                })

                local ok, err = pcall(function()
                    assertNotNil(door, 'door reached the cache (is whip.devtools granted to this client?)')

                    -- The seven wire fields, and nothing the server keeps to itself.
                    assertNotNil(door.doorId, 'doorId on the wire')
                    assertNotNil(door.model, 'model on the wire')
                    assertNotNil(door.x, 'x on the wire')
                    assertTrue(door.locked, 'locked on the wire (new doors lock)')
                    assertNil(door.requirements, 'requirements withheld')
                    assertNil(door.autolock, 'autolock withheld')
                    assertNil(door.folder, 'folder withheld')

                    -- The lookups that used to be tested against an empty cache, now against a
                    -- door that is really there, ~2.8m from the tester.
                    assertTrue(exports.whip_core:IsDoorLocked(door.doorId), 'IsDoorLocked reads the cache')
                    assertNotNil(exports.whip_core:GetDoor(door.doorId), 'GetDoor finds it by id')
                    local within, tooNear = false, false
                    for _, d in ipairs(exports.whip_core:GetDoorsNearby(10.0)) do
                        if d.doorId == door.doorId then within = true end
                    end
                    for _, d in ipairs(exports.whip_core:GetDoorsNearby(1.0)) do
                        if d.doorId == door.doorId then tooNear = true end
                    end
                    assertTrue(within, 'GetDoorsNearby(10) includes a door 3m away')
                    assertFalse(tooNear, 'GetDoorsNearby(1) does not')
                end)

                local gone = deleteTestDoor(door and door.doorId)
                if not ok then error(err, 0) end
                assertTrue(gone, 'cleanup: door removed')
            end,
        },
        {
            name = 'Far door still enters cache (create broadcast is global)',
            fn = function()
                local pos = GetEntityCoords(PlayerPedId())
                local door = createTestDoor({
                    label = '_test_far_door', model = GetHashKey('prop_door_01'),
                    x = pos.x + 300.0, y = pos.y + 300.0, z = pos.z, heading = 0,
                })

                local gone = deleteTestDoor(door and door.doorId)
                assertNotNil(door, 'far door reached the cache without any proximity query')
                assertTrue(gone, 'cleanup: door removed')
            end,
        },
        {
            -- The end-to-end gap test for the whole redesign: a toggle we were too far away to
            -- hear must reach us as we come back into the door's cell (doorStatesBatch, fired
            -- by the ground sweep on cell gain).
            --
            -- The ped is FROZEN for the trip — teleported ~850m at the same height it would
            -- otherwise fall, drown or land in a wall — and put back, unfrozen, on every exit
            -- path. Coming back is polled rather than slept.
            name = 'Cell re-entry refreshes stale lock state',
            fn = function()
                local ped = PlayerPedId()
                local origin = GetEntityCoords(ped)

                local door = createTestDoor({
                    label = '_test_cell_refresh', model = GetHashKey('prop_door_01'),
                    x = origin.x - 3.0, y = origin.y - 3.0, z = origin.z, heading = 0,
                })
                local doorId = door and door.doorId

                -- Everything between the teleports runs guarded, so an assertion mid-flight
                -- cannot strand the ped 850m away for every test after this one.
                local ok, err = pcall(function()
                    assertNotNil(doorId, 'test door created')
                    assertTrue(exports.whip_core:IsDoorLocked(doorId), 'starts locked')

                    -- Out of the door's cell neighbourhood, and wait out a sweep. Leaving a cell has
                    -- nothing to observe from here, so this one stays a fixed wait (the sweep is 1s).
                    FreezeEntityPosition(ped, true)
                    SetEntityCoords(ped, origin.x + 600.0, origin.y + 600.0, origin.z, false, false, false, false)
                    Wait(2500)

                    -- Server unlocks while we are far away. The announce is cell-scoped, so our
                    -- copy must NOT hear it — that staleness is the design, not the bug.
                    fire('whip_core:server:doorSetLocked', doorId, false)
                    Wait(1000)
                    assertTrue(exports.whip_core:IsDoorLocked(doorId),
                        'far client did not hear the toggle (announce is cell-scoped)')

                    -- Come back. Re-gaining the cell must hand us the current state.
                    SetEntityCoords(ped, origin.x, origin.y, origin.z, false, false, false, false)
                    assertTrue(waitFor(function()
                        return exports.whip_core:IsDoorLocked(doorId) == false
                    end, 5000) == true, 'cell re-entry delivered the missed unlock (doorStatesBatch)')
                end)

                SetEntityCoords(ped, origin.x, origin.y, origin.z, false, false, false, false)
                FreezeEntityPosition(ped, false)
                local gone = deleteTestDoor(doorId)
                if not ok then error(err, 0) end
                assertTrue(gone, 'cleanup: door removed')
            end,
        },
    }
})
