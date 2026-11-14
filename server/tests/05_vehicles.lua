-- ============================================
-- Vehicle Lifecycle Tests
-- Create → Spawn → Key → Lock → Fuel → Trunk → Store → Delete
--
-- Every step is a public export, so this suite proves the API a satellite calls rather than a
-- screen only an admin can reach. No ACE required.
-- ============================================

local _testVehicleId = nil

--- A PLATE PER RUN. This was the literal 'TEST', so a run that crashed before its delete left a
--- car wearing it, and every later run then found THAT car by plate — the lookup tests passed
--- against the wrong vehicle, and the create collided with it. 'WT' plus six digits is eight
--- characters, the most a GTA plate shows, and is set in setup.
local _testPlate = nil

--- Wait until the tester is out of the test vehicle, or say how long that took to not happen.
local function waitUntilOut(source)
    return waitFor(function()
        return not exports.whip_core:IsPlayerInVehicle(source, _testVehicleId)
    end, 5000) and true or false
end

--- One slot of the test car's storage, as an address — what StoreGive, StoreTake and GetItemAt take.
---
--- (09-24) PlaceItemAt and TakeItemFrom took the literal 'container', meaning "whatever this player
--- has open", and found the store by scanning the open-lock table. That idea was removed with them:
--- the address names the car and the compartment, so it cannot land in the wrong one.
---@param sub string  'trunk' | 'glovebox' | 'key'
---@param slot number
---@return table
local function carSlot(sub, slot)
    return { kind = 'vehicle', id = _testVehicleId, sub = sub, slot = slot }
end

--- Does the tester have ANY vehicle storage open — a boot, a glovebox, an ignition?
---
--- (09-24) GetOpenVehicleStorage was removed. It answered with ONE of the player's open stores,
--- whichever pairs() reached first; GetOpenStores lists them all, as addresses.
---@param source number
---@return boolean
local function vehicleStorageOpen(source)
    for _, addr in ipairs(exports.whip_core:GetOpenStores(source) or {}) do
        if addr.kind == 'vehicle' then return true end
    end
    return false
end

RegisterTestModule({
    order    = 5,
    category = 'Vehicles',
    setup = function(source, ctx)
        local player = exports.whip_core:GetPlayer(source)
        ctx.charId = player.charId
        _testVehicleId = nil
        _testPlate = ('WT%06d'):format(os.time() % 1000000)
    end,
    teardown = function(ctx, source)
        -- Make sure player leaves vehicle first
        if source then
            ClientLeaveVehicle(source, 5000)
            if _testVehicleId then waitUntilOut(source) end
        end
        -- EVERY KEY, EVEN AFTER THE DELETE TEST. The delete test used to set _testVehicleId to nil
        -- "to prevent a double delete", which also skipped this — so the key stayed in the tester's
        -- pocket every run. RemoveVehicleKey matches the vehicleId in the key's metadata, so it
        -- works whether or not the car still exists. Looped because each call takes one key.
        if _testVehicleId and source then
            for _ = 1, 5 do
                if not exports.whip_core:RemoveVehicleKey(source, _testVehicleId) then break end
            end
        end
        -- Clean up: delete the vehicle. Through the export, so a failed run does not leave a car
        -- behind AND does not depend on a dev tool to tidy up after itself. Harmless if the delete
        -- test already did it (the export answers 'Vehicle not found').
        if _testVehicleId and not ctx.deleted then
            pcall(exports.whip_core.DeleteVehicle, exports.whip_core, _testVehicleId)
        end
        if source then RemoveAllOf(source, 'food') end
        _testVehicleId = nil
    end,
    tests = {
        -- ==========================================
        -- Phase 1: Create vehicle in DB
        -- ==========================================
        -- THROUGH THE PUBLIC API, NOT AN ADMIN TOOL.
        --
        -- These drive the same exports a satellite calls, so a pass here means the API works
        -- rather than meaning one screen works.
        {
            name = 'CreateOwnedVehicle creates a vehicle',
            fn = function(source, ctx)
                -- `(vehicleId|false, err)` — the same shape every other producer in the vehicle
                -- API returns. The second value is the error and only the error; the plate is a
                -- field of the vehicle, asserted below.
                local vehicleId, err = exports.whip_core:CreateOwnedVehicle(source, {
                    model = 'asea',
                    plate = _testPlate,
                    state = 'garaged',
                })
                assertOk(vehicleId, err, 'CreateOwnedVehicle')
                assertEqual(type(vehicleId), 'number', 'returns a vehicleId, not a table')
                _testVehicleId = vehicleId
                assertDbScalar('SELECT `plate` FROM `vehicles` WHERE `vehicleId` = ?', { vehicleId },
                    _testPlate, 'the row is on disk with its plate')
            end,
        },
        {
            -- THE CONTRACT, TESTED. A failure must return `false` plus a reason — not nil, which a
            -- FiveM export would truncate the reason away with, and not a plate.
            name = 'CreateOwnedVehicle reports failure as (false, err)',
            fn = function(source)
                local id, err = exports.whip_core:CreateOwnedVehicle(source, { model = '' })
                assertFalse(id, 'no vehicle for an empty model')
                assertType(err, 'string', 'a reason came back with it')
            end,
        },
        {
            name = 'GetVehicle returns the created vehicle',
            fn = function(source, ctx)
                assertNotNil(_testVehicleId, 'vehicleId from previous test')
                local v = exports.whip_core:GetVehicle(_testVehicleId)
                assertNotNil(v, 'GetVehicle')
                assertEqual(v.model, 'asea', 'model')
                assertEqual(v.plate, _testPlate, 'plate')
                assertEqual(v.owner.charId, ctx.charId, 'owner.charId')
                assertEqual(v.state, 'garaged', 'state is garaged')
                assertFalse(v.session, 'not a session vehicle')
            end,
        },
        -- 'GetVehicle returns a copy, not the live record' lived here and could not fail: every
        -- value crossing an export is a copy, so editing what came back could never reach
        -- whip_core however GetVehicle was written. The guarantee is FiveM's, not the export's.
        {
            name = 'GetVehicleBy plate finds it',
            fn = function()
                local v = exports.whip_core:GetVehicleBy('plate', _testPlate)
                assertNotNil(v, 'GetVehicleBy plate')
                assertEqual(v.vehicleId, _testVehicleId, 'same vehicle')
            end,
        },
        {
            -- The person rule (DX-17): a server id, or { charId = n }. A bare charId is not a person.
            name = 'GetVehiclesOf includes test vehicle, by source and by { charId }',
            fn = function(source, ctx)
                for _, who in ipairs({ source, { charId = ctx.charId } }) do
                    local owned = exports.whip_core:GetVehiclesOf(who)
                    assertType(owned, 'table', 'owned type')
                    local found = false
                    for _, v in ipairs(owned) do
                        if v.vehicleId == _testVehicleId then found = true; break end
                    end
                    assertTrue(found, 'test vehicle in owned list (' .. type(who) .. ')')
                end
                local none, why = exports.whip_core:GetVehiclesOf(0)
                assertEqual(#none, 0, 'nobody owns nothing')
                assertNotNil(why, 'and says why')
            end,
        },

        -- ==========================================
        -- Phase 2: Spawn vehicle into world
        -- ==========================================
        {
            name = 'RetrieveVehicle + SpawnVehicle put it in the world',
            fn = function(source)
                assertNotNil(_testVehicleId, 'vehicleId needed')

                -- Two calls, because they answer different questions: retrieve decides the car may
                -- come out, spawn decides where.
                local ok, err = exports.whip_core:RetrieveVehicle(_testVehicleId)
                assertTrue(ok, 'RetrieveVehicle: ' .. tostring(err))

                local ped = GetPlayerPed(source)
                local pos = GetEntityCoords(ped)
                local netId, sErr = exports.whip_core:SpawnVehicle(
                    _testVehicleId, pos.x + 5, pos.y, pos.z, GetEntityHeading(ped) or 0.0)
                assertOk(netId, sErr, 'SpawnVehicle')

                local v = exports.whip_core:GetVehicle(_testVehicleId)
                assertNotNil(v, 'GetVehicle after spawn')
                assertEqual(v.state, 'out', 'state is out after spawn')
                assertTrue(v.spawned, 'spawned flag')
                assertNotNil(v.netId, 'netId present once out')
            end,
        },

        -- ==========================================
        -- Phase 3: Test vehicle operations
        -- ==========================================
        {
            -- owner and session used to be their own exports. They are fields now, and this is the
            -- test that says so.
            name = 'GetVehicle carries owner and session',
            fn = function(source, ctx)
                local v = exports.whip_core:GetVehicle(_testVehicleId)
                assertNotNil(v, 'GetVehicle')
                assertEqual(v.owner.charId, ctx.charId, 'owner charId')
                assertTrue(v.owner.online, 'owner is online')
                assertFalse(v.session, 'not a session vehicle')
            end,
        },
        {
            -- The scan of every player is opt-in. Absent unless asked for, present when asked.
            name = 'Occupants are opt-in',
            fn = function()
                local quiet = exports.whip_core:GetVehicle(_testVehicleId)
                assertNil(quiet.occupants, 'no occupants unless asked')

                local asked = exports.whip_core:GetVehicle(_testVehicleId, { occupants = true })
                assertType(asked.occupants, 'table', 'occupants when asked')
            end,
        },
        {
            -- Fuel through the ORDINARY stat API: fuel is whip_fuel's stat, written and read as any other.
            name = 'SetVehicleStat + GetVehicleStat (fuel, with whip_fuel)',
            fn = function()
                if GetResourceState('whip_fuel') ~= 'started' then skip('whip_fuel is not running (fuel is its stat)') end
                exports.whip_core:SetVehicleStat(_testVehicleId, 'fuel', 42.0, 'whip_test')
                local fuel = exports.whip_core:GetVehicleStat(_testVehicleId, 'fuel')
                assertNotNil(fuel, 'fuel not nil')
                assertTrue(fuel >= 41 and fuel <= 43, 'fuel ~ 42, got ' .. tostring(fuel))
            end,
        },
        {
            -- A stat with no special history, proving the path is generic rather than something
            -- that only happens to work for fuel.
            name = 'a non-fuel stat uses the identical path',
            fn = function()
                exports.whip_core:RegisterVehicleStat('_test_nos', {
                    default = 100, min = 0, max = 100, persist = false,
                })
                exports.whip_core:SetVehicleStat(_testVehicleId, '_test_nos', 55.0, 'whip_test')
                local nos = exports.whip_core:GetVehicleStat(_testVehicleId, '_test_nos')
                assertNotNil(nos, 'nos not nil')
                assertTrue(nos >= 54 and nos <= 56, 'nos ~ 55, got ' .. tostring(nos))

                local all = exports.whip_core:GetAllVehicleStats(_testVehicleId)
                assertType(all, 'table', 'GetAllVehicleStats returns a table')
                assertNotNil(all.engine, 'engine present in the stat block')
                assertNotNil(all._test_nos, 'nos sits in the same block as engine')
            end,
        },
        {
            -- Write with the verb, read the field. SetVehicleLocked returns (ok, err) like every
            -- other verb now, and the test checks it rather than assuming.
            --
            -- FROM UNLOCKED. A car comes out of the garage locked, so "lock it and check it is
            -- locked" passed whether or not the lock did anything. And to disk: `locked` is a
            -- column, and a lock that only lived in memory would open itself at the next restart.
            name = 'SetVehicleLocked(true) locks an unlocked vehicle, on disk too',
            fn = function()
                local off, offErr = exports.whip_core:SetVehicleLocked(_testVehicleId, false)
                assertOk(off, offErr, 'unlocked first')
                assertFalse(exports.whip_core:GetVehicle(_testVehicleId).locked, 'reads unlocked')

                local ok, err = exports.whip_core:SetVehicleLocked(_testVehicleId, true)
                assertOk(ok, err, 'SetVehicleLocked')
                assertTrue(exports.whip_core:GetVehicle(_testVehicleId).locked, 'locked')
                assertDbScalar('SELECT IF(`locked` <> 0, 1, 0) FROM `vehicles` WHERE `vehicleId` = ?',
                    { _testVehicleId }, 1, 'locked on disk')
            end,
        },
        {
            name = 'SetVehicleLocked(false) unlocks vehicle, on disk too',
            fn = function()
                local ok, err = exports.whip_core:SetVehicleLocked(_testVehicleId, false)
                assertOk(ok, err, 'SetVehicleLocked')
                assertFalse(exports.whip_core:GetVehicle(_testVehicleId).locked, 'unlocked')
                assertDbScalar('SELECT IF(`locked` <> 0, 1, 0) FROM `vehicles` WHERE `vehicleId` = ?',
                    { _testVehicleId }, 0, 'unlocked on disk')
            end,
        },
        {
            -- VEH-8. A lock done through the export used to fire no event at all: only the key fob
            -- and the lockpick announced one, so a satellite listening for locks missed the rest.
            name = 'SetVehicleLocked announces a change on lockChanged, and only a change',
            fn = function()
                local heard = {}
                local function listen(eventName)
                    return AddEventHandler(eventName, function(data)
                        if type(data) == 'table' and data.vehicleId == _testVehicleId then
                            heard[#heard + 1] = { name = eventName, locked = data.locked }
                        end
                    end)
                end
                local onChanged = listen('whip_core:vehicle:lockChanged')

                -- The handlers are removed whatever happens, so a failed assert cannot leave them
                -- listening through the rest of the run.
                local ok, err = pcall(function()
                    assertOk(exports.whip_core:SetVehicleLocked(_testVehicleId, false), nil, 'start unlocked')
                    for i = #heard, 1, -1 do heard[i] = nil end

                    assertOk(exports.whip_core:SetVehicleLocked(_testVehicleId, true), nil, 'lock')
                    waitFor(function() return #heard >= 1 end, 1000)
                    Wait(200)
                    assertEqual(#heard, 1, 'locking is announced once')
                    for _, h in ipairs(heard) do
                        assertTrue(h.locked == true, ('%s says locked = true'):format(h.name))
                    end

                    for i = #heard, 1, -1 do heard[i] = nil end
                    assertOk(exports.whip_core:SetVehicleLocked(_testVehicleId, true), nil, 'lock again')
                    Wait(200)
                    assertEqual(#heard, 0, 'locking a car that is already locked announces nothing')

                    assertOk(exports.whip_core:SetVehicleLocked(_testVehicleId, false), nil, 'unlock')
                    waitFor(function() return #heard >= 1 end, 1000)
                    Wait(200)
                    assertEqual(#heard, 1, 'unlocking is announced too, once')
                    for _, h in ipairs(heard) do
                        assertTrue(h.locked == false, ('%s says locked = false'):format(h.name))
                    end
                end)

                RemoveEventHandler(onChanged)
                if not ok then error(err, 0) end
            end,
        },
        {
            -- CREATION DOES NOT HAND OUT A KEY, and this test used to claim it did.
            --
            -- It passed only because the suite used to create vehicles through the Vehicle
            -- Manager's vm* events, and the admin tool gave one. Driving the public export
            -- instead exposed the assertion as false: CreateOwnedVehicle mints a vehicle and
            -- nothing else unless asked (`{ giveKey = true }`, the one call whip_dealership_example uses).
            --
            -- So the test now does what a real satellite does, and proves the export it names.
            name = 'GiveVehicleKey puts a key in the owner\'s pocket',
            fn = function(source)
                assertFalse(exports.whip_core:HasVehicleKey(source, _testVehicleId),
                    'no key before one is given')

                local ok, err = exports.whip_core:GiveVehicleKey(source, _testVehicleId)
                assertTrue(ok, 'GiveVehicleKey: ' .. tostring(err))

                assertTrue(exports.whip_core:HasVehicleKey(source, _testVehicleId),
                    'has key after being given one')

                -- One key, not one per call: a second give is refused rather than stacking copies.
                local again, againErr = exports.whip_core:GiveVehicleKey(source, _testVehicleId)
                assertFalse(again, 'a second key is refused')
                assertEqual(againErr, 'Already has a key for this vehicle', 'and says why')
            end,
        },
        {
            name = 'GetPlayerVehicleKeys includes test vehicle',
            fn = function(source)
                local keys = exports.whip_core:GetPlayerVehicleKeys(source)
                assertType(keys, 'table', 'keys type')
                assertNotNil(keys[_testVehicleId], 'test vehicle in keys')
            end,
        },
        {
            name = 'RemoveVehicleKey + HasVehicleKey returns false',
            fn = function(source)
                assertTrue(exports.whip_core:RemoveVehicleKey(source, _testVehicleId), 'a key was removed')
                assertFalse(exports.whip_core:HasVehicleKey(source, _testVehicleId), 'key removed')
            end,
        },
        {
            name = 'GiveVehicleKey re-gives key',
            fn = function(source)
                local ok, err = exports.whip_core:GiveVehicleKey(source, _testVehicleId)
                assertTrue(ok, 'GiveVehicleKey: ' .. tostring(err))
                assertTrue(exports.whip_core:HasVehicleKey(source, _testVehicleId), 'has key again')
            end,
        },

        -- ==========================================
        -- Phase 3b: Vehicle lookup exports
        -- ==========================================
        {
            -- ONE SHAPE, ASSERTED. This accepted a number OR a table, branching to a different
            -- assertion for each — which meant it could not tell the two apart, and would have
            -- stayed green through a change from one to the other. A test that accepts every
            -- answer is not testing the answer.
            --
            -- The contract is `(vehicleId|false, err)`, the same as every other producer.
            name = 'AdoptVehicle returns a vehicleId by plate',
            fn = function(source)
                local v = exports.whip_core:GetVehicle(_testVehicleId)
                assertNotNil(v, 'GetVehicle for plate lookup')

                local result, err = exports.whip_core:AdoptVehicle(v.plate)
                assertEqual(type(result), 'number', 'a vehicleId, not a table: ' .. tostring(err))
                assertEqual(result, _testVehicleId, 'vehicleId matches')
            end,
        },
        {
            -- `false` plus a reason, not nil. A FiveM export truncates its return list at the
            -- first nil, so a producer that failed with nil would take its own error message
            -- with it and the caller would learn nothing about why.
            name = 'AdoptVehicle returns (false, err) for a nonexistent plate',
            fn = function()
                local vehicleId, err = exports.whip_core:AdoptVehicle('ZZZZZZ99')
                assertFalse(vehicleId, 'no vehicle for a fake plate')
                assertType(err, 'string', 'a reason came back with it')
            end,
        },
        {
            name = 'GetVehicleBy netId returns nil for an invalid netId',
            fn = function()
                assertNil(exports.whip_core:GetVehicleBy('netId', 999999), 'nil for nonexistent netId')
            end,
        },
        {
            -- An unknown lookup kind must answer nil rather than guessing.
            name = 'GetVehicleBy rejects an unknown kind',
            fn = function()
                assertNil(exports.whip_core:GetVehicleBy('nonsense', 1), 'nil for unknown kind')
            end,
        },

        -- ==========================================
        -- Phase 4: Trunk + Glovebox
        -- (Player must leave vehicle to access trunk)
        -- ==========================================
        {
            -- ASSERTS WHAT IT ESTABLISHES. These steps used to assert nothing at all: they ran an
            -- action, reported green, and if the action failed the NEXT test failed instead with a
            -- message about something unrelated. Five of them in this module, each one a pass in
            -- the count that proved nothing.
            name = 'Player leaves vehicle for trunk access',
            fn = function(source)
                ClientLeaveVehicle(source, 5000)
                assertTrue(waitUntilOut(source), 'player is out of the vehicle')
            end,
        },
        {
            name = 'Unlock vehicle for trunk access',
            fn = function(source)
                -- The return was discarded entirely, on the one call whose whole job is to say
                -- whether it worked.
                local ok, err = exports.whip_core:SetVehicleLocked(_testVehicleId, false)
                assertTrue(ok, 'SetVehicleLocked: ' .. tostring(err))
                assertFalse(exports.whip_core:GetVehicle(_testVehicleId).locked, 'reads unlocked')

                -- ####################################################################
                -- PUT THE TESTER BACK BESIDE THE CAR BEFORE THE BOOT PHASE.
                --
                -- The vehicle was spawned five metres from wherever the player happened to be
                -- standing when the spawn test ran, several tests ago. The tester is a LIVE
                -- PLAYER and can walk while the suite runs, so by the time the boot is opened
                -- the distance is whatever it is — which made this phase pass or fail on where
                -- somebody was standing rather than on whether vehicle storage works.
                --
                -- It also failed in a thoroughly misleading place. The boot would open, the
                -- viewer would be registered, and then the client's own range check would close
                -- the inventory and the server would drop the viewer — so the failure surfaced
                -- two tests later as "No container open" out of TakeItemFrom, pointing at a
                -- function that had done nothing wrong. (TakeItemFrom was removed 09-24. The take
                -- is by address now and does not need the boot open, but the viewer check in front
                -- of it does, so the tester still has to be standing beside the car.)
                --
                -- Entering and leaving is the cheapest guarantee of adjacency: the client is
                -- teleported into the seat and set down beside the car on the way out. Both
                -- helpers are already used earlier in this module.
                --
                -- Both halves ASSERTED now: an enter that silently failed left the tester wherever
                -- they were, and the distance problem above came straight back.
                -- ####################################################################
                ClientEnterVehicle(source, _testPlate, -1, 5000)
                assertTrue(waitFor(function()
                    return exports.whip_core:IsPlayerInVehicle(source, _testVehicleId)
                end, 5000) and true or false, 'the tester got into the car')
                ClientLeaveVehicle(source, 5000)
                assertTrue(waitUntilOut(source), 'and back out beside it')
            end,
        },
        {
            -- VEH-6. The server never fired vehicle:exited, and its vehicle:entered meant "driver
            -- only" while the client's meant any seat. Both now carry `seat` (-1 = driver).
            -- Ends with the tester set down beside the car, which the boot tests below need.
            name = 'The server announces vehicle:entered AND vehicle:exited, with the seat, for driver and passenger',
            fn = function(source)
                local heard = {}
                local function listen(eventName)
                    return AddEventHandler(eventName, function(data)
                        if type(data) == 'table' and data.vehicleId == _testVehicleId and data.source == source then
                            heard[#heard + 1] = { name = eventName, seat = data.seat }
                        end
                    end)
                end
                local onIn  = listen('whip_core:vehicle:entered')
                local onOut = listen('whip_core:vehicle:exited')

                local ok, err = pcall(function()
                    -- Wait for one announcement, and take it off the list so it is counted once.
                    local function expect(name, seat, what)
                        local got = waitFor(function()
                            for i, h in ipairs(heard) do
                                if h.name == name and h.seat == seat then
                                    table.remove(heard, i)
                                    return true
                                end
                            end
                        end, 5000)
                        assertTrue(got and true or false, what)
                    end

                    ClientEnterVehicle(source, _testPlate, -1, 5000)
                    expect('whip_core:vehicle:entered', -1, 'getting into the driver seat is announced with seat -1')
                    ClientLeaveVehicle(source, 5000)
                    assertTrue(waitUntilOut(source), 'out of the car')
                    expect('whip_core:vehicle:exited', -1, 'and getting out is announced — the server never did this before')

                    -- A REAR seat, not the front passenger's. GTA moves a front passenger across into an
                    -- empty driver's seat on its own, which would make this a test of that instead.
                    ClientEnterVehicle(source, _testPlate, 1, 5000)
                    expect('whip_core:vehicle:entered', 1, 'a PASSENGER seat is announced too, with its seat (1)')
                    ClientLeaveVehicle(source, 5000)
                    assertTrue(waitUntilOut(source), 'out again')
                    expect('whip_core:vehicle:exited', 1, 'and leaving it, with seat 1')

                    -- The driver seat is reported twice (the seat report and the ignition check);
                    -- the server's seat record keeps that to one announcement.
                    Wait(1500)
                    local dupes = 0
                    for _, h in ipairs(heard) do
                        if h.name == 'whip_core:vehicle:entered' then dupes = dupes + 1 end
                    end
                    assertEqual(dupes, 0, 'no duplicate entered announcements')
                end)

                RemoveEventHandler(onIn)
                RemoveEventHandler(onOut)
                if not ok then error(err, 0) end
            end,
        },
        {
            -- THE ACCESSORY KEY AND THE UNLOCK (Josh, 26 Sep 2026). A key in the accessory strip
            -- goes into the empty ignition when its holder takes the driver's seat, and back to the
            -- slot it left when they get out; getting out unlocks the car; a passenger's key stays put.
            -- (5 Nov 2026: there is no Key slot any more; any strip slot will do.)
            -- Measured, put back, then judged, so a failure cannot leave the tester in the car or the
            -- key in the ignition for the boot tests below.
            name = 'A strip key goes into the ignition for the driver and back on the way out; getting out unlocks',
            fn = function(source)
                -- The last empty strip slot that takes a key, so the slot it comes back to is not
                -- simply "the first empty one".
                local keySlot
                for slot, def in pairs(exports.whip_core:GetAccessorySlots() or {}) do
                    if (not def.accepts or def.accepts == 'vehicle_key') and (not keySlot or slot > keySlot)
                        and not exports.whip_core:GetItemAt(PocketAddr(source, 'accessory', slot)) then
                        keySlot = slot
                    end
                end
                if not keySlot then skip('no empty accessory slot takes a vehicle key — empty one to run this test') end
                local keyAddr = PocketAddr(source, 'accessory', keySlot)
                if exports.whip_core:GetItemAt(carSlot('key', 1)) then skip('the test car already has a key in it') end

                -- The test car's key (GiveVehicleKey, above) is in the main pockets: into the strip.
                local pocketKey
                for slot = 1, exports.whip_core:GetPocketSlots('player') or 0 do
                    local s = exports.whip_core:GetItemAt(PocketAddr(source, 'player', slot))
                    if s and s.item == 'vehicle_key' and s.metadata and tonumber(s.metadata.vehicleId) == _testVehicleId then
                        pocketKey = slot
                        break
                    end
                end
                if not pocketKey then skip('the test car\'s key is not in the main pockets') end
                assertOk(exports.whip_core:StoreMove(PocketAddr(source, 'player', pocketKey), keyAddr), nil,
                    'the key into the strip')

                local function keyIn(addr)
                    local s = exports.whip_core:GetItemAt(addr)
                    return s ~= nil and s.item == 'vehicle_key' and s.metadata ~= nil
                        and tonumber(s.metadata.vehicleId) == _testVehicleId
                end
                local seen = {}
                local ok, err = pcall(function()
                    assertOk(exports.whip_core:SetVehicleLocked(_testVehicleId, true), nil, 'locked before getting in')

                    ClientEnterVehicle(source, _testPlate, -1, 5000)
                    seen.inCar = waitFor(function() return exports.whip_core:IsPlayerInVehicle(source, _testVehicleId) end, 5000) and true or false
                    seen.inIgnition = waitFor(function() return keyIn(carSlot('key', 1)) end, 5000) and true or false
                    seen.slotEmptied = exports.whip_core:GetItemAt(keyAddr) == nil

                    ClientLeaveVehicle(source, 5000)
                    seen.out = waitUntilOut(source)
                    seen.backInSlot = waitFor(function() return keyIn(keyAddr) end, 5000) and true or false
                    seen.ignitionEmptied = exports.whip_core:GetItemAt(carSlot('key', 1)) == nil
                    seen.unlocked = waitFor(function()
                        return exports.whip_core:GetVehicle(_testVehicleId).locked == false
                    end, 3000) and true or false

                    -- A rear seat (GTA slides a front passenger across into an empty driver's seat).
                    ClientEnterVehicle(source, _testPlate, 1, 5000)
                    waitFor(function() return exports.whip_core:IsPlayerInVehicle(source, _testVehicleId) end, 5000)
                    Wait(2000)   -- longer than the driver's key took to move
                    seen.passengerKeptKey = keyIn(keyAddr) and exports.whip_core:GetItemAt(carSlot('key', 1)) == nil
                    ClientLeaveVehicle(source, 5000)
                    waitUntilOut(source)
                end)

                -- Put things back whatever happened: out of the car, the key back in the main pockets.
                ClientLeaveVehicle(source, 5000)
                waitUntilOut(source)
                for _, addr in ipairs({ keyAddr, carSlot('key', 1) }) do
                    if keyIn(addr) then
                        pcall(exports.whip_core.StoreMove, exports.whip_core, addr, { kind = 'player', id = source, sub = 'player' })
                    end
                end
                pcall(exports.whip_core.SetVehicleLocked, exports.whip_core, _testVehicleId, false)
                if not ok then error(err, 0) end

                assertTrue(seen.inCar, 'the tester got into the driver\'s seat')
                assertTrue(seen.inIgnition, 'the strip key went into the ignition')
                assertTrue(seen.slotEmptied, 'and left its slot')
                assertTrue(seen.out, 'the tester got out')
                assertTrue(seen.backInSlot, 'the key came back to the slot it left')
                assertTrue(seen.ignitionEmptied, 'and left the ignition')
                assertTrue(seen.unlocked, 'getting out unlocked the car')
                assertTrue(seen.passengerKeptKey, 'a passenger\'s strip key stays with them')
            end,
        },
        {
            name = 'Open trunk + place item in',
            fn = function(source)
                -- (No AddItem first. StoreGive CREATES the item in the named store — it is not a
                -- move from the pockets — so the food this used to hand the player first was never
                -- used and was left in the inventory.)
                --
                -- Assert the SERVER opened the trunk, not merely that the client replied: the
                -- take and the close below are about the boot this player has open.
                --
                -- BY ADDRESS (09-24). This was PlaceItemAt(source, 'container', ...), which found
                -- the trunk by scanning the open-lock table, so an open that failed left it aiming
                -- at nothing. StoreGive names the trunk and would reach it opened or not; the open
                -- is still asserted because the player's own path to the boot is half of this phase.
                OpenVehicleStorageOrFail(source, _testVehicleId, 'trunk')
                local placed, err = exports.whip_core:StoreGive(carSlot('trunk', 1), 'food', 2)
                assertOk(placed, err, 'StoreGive into the trunk')
                assertEqual(placed, 1, 'and it landed in the slot it was aimed at')
            end,
        },
        {
            name = 'StoreTake from the trunk',
            fn = function(source)
                -- ####################################################################
                -- THE PRECONDITION IS ASSERTED SEPARATELY, ON PURPOSE.
                --
                -- TakeItemFrom with 'container' resolved its target from the player's OPEN VIEW
                -- set. If the trunk had quietly stopped being open, the export answered "No
                -- container open" — which read as a failure of the TAKE, and sent the last
                -- investigation looking at the wrong function entirely.
                --
                -- The previous test ends by proving the viewer exists (OpenVehicleStorageOrFail
                -- asserts it), so if it is missing here it was lost BETWEEN two tests, and that
                -- is a different defect from anything the take does. Naming it separately
                -- makes the next failure say which of the two happened.
                --
                -- (09-24) The take is StoreTake by address now and no longer needs the boot open,
                -- so this no longer guards it. It stays for the defect it names: a viewer that
                -- vanishes between two tests is still a bug, whatever the next call needs.
                -- ####################################################################
                local storeId = ('vehicle:%s:trunk'):format(tostring(_testVehicleId))
                assertTrue(exports.whip_core:__TestIsViewer(source, storeId),
                    'the trunk is still open for this player when the take begins')

                -- StoreTake answers what it took, `{ item, amount, metadata }`, or `false, reason`.
                -- (TakeItemFrom answered `true, false, removed`.)
                local removed, err = exports.whip_core:StoreTake(carSlot('trunk', 1), 1)
                assertOk(removed, err, 'StoreTake from the trunk')
                assertEqual(removed.amount, 1, 'exactly one taken, of the two placed')
            end,
        },
        {
            name = 'Close trunk',
            fn = function(source)
                ClientCloseVehicleStorage(source, _testVehicleId, 'trunk', 3000)
                assertTrue(waitFor(function()
                    return not vehicleStorageOpen(source)
                end, 3000) and true or false, 'no vehicle storage left open')
            end,
        },
        {
            -- THE GLOVEBOX IS REACHED FROM THE SEAT, not from an id.
            --
            -- This test used to run straight after 'Player leaves vehicle for trunk access' and
            -- never got back in — which passed only while the server took the vehicleId on trust.
            -- It now reads which vehicle the player is sitting in, so a player standing on the
            -- pavement has no glovebox to open, correctly.
            --
            -- The helper sends 0 as the id on purpose: if the server were still trusting the wire
            -- this test would pass for the wrong reason.
            name = 'Open glovebox from the driver seat + place item in',
            fn = function(source)
                OpenVehicleStorageOrFail(source, _testVehicleId, 'glovebox', _testPlate, -1)
                -- By address (09-24; this was PlaceItemAt(source, 'container', ...)).
                local placed, err = exports.whip_core:StoreGive(carSlot('glovebox', 1), 'food', 1)
                assertOk(placed, err, 'StoreGive into the glovebox')
            end,
        },
        {
            -- Folded into one operation with its own effect assertion. As two tests it only ever
            -- checked that a call returned true, and the second half depended on the first
            -- having left something in slot 1 — so a failure in either read as a failure of both.
            name = 'StoreTake REMOVES from the glovebox and does not credit the player',
            fn = function(source)
                -- TAKING IS NOT A MOVE. StoreTake clears the store slot and hands the removed
                -- descriptor back to the CALLER as its answer — it never touches the player's
                -- inventory. The satellite that called it decides where the item goes, and if it
                -- ignores that answer the item is simply destroyed. (This was TakeItemFrom, removed
                -- 09-24, which handed it back as its third value; the rule is the same.)
                --
                -- This test asserted `before + 1`, i.e. that the unit landed on the player. It
                -- does not, and that expectation would have made a real conservation bug —
                -- crediting the player as well as returning the descriptor, which IS a dupe —
                -- look like the intended behaviour.
                --
                -- The address names the glovebox. TakeItemFrom needed a private
                -- `_vehicleLockKey` option to say which of the player's open stores it meant.
                local before = exports.whip_core:GetItemCount(source, 'food')
                local removed, err = exports.whip_core:StoreTake(carSlot('glovebox', 1), 1)
                assertOk(removed, err, 'StoreTake from the glovebox')

                assertEqual(removed.item, 'food', 'the removed unit is handed back, naming what was taken')
                assertEqual(removed.amount, 1, 'and how much')

                assertEqual(exports.whip_core:GetItemCount(source, 'food'), before,
                    'the player was NOT credited — taking is not moving')

                -- (09-24) The slot can simply be READ now. This used to prove it empty only by
                -- taking from it again, because GetSlotData read the player's pockets alone and
                -- would have reported on pocket slot 1 instead. GetItemAt reads any store address.
                assertNil(exports.whip_core:GetItemAt(carSlot('glovebox', 1)), 'the glovebox slot is empty')

                -- And a second take still finds nothing, and says so.
                local again, againErr = exports.whip_core:StoreTake(carSlot('glovebox', 1), 1)
                assertFalse(again, 'a second take finds nothing')
                assertEqual(againErr, 'Empty slot', 'and says so, rather than failing vaguely')
            end,
        },
        {
            -- THE POINT OF THE CHANGE: a passenger is not the driver, and used to be refused.
            --
            -- Their client cannot resolve a vehicleId at all — GetVehicleIdByEntity only knows
            -- vehicles you own, hold a key for, or registered yourself — so the glovebox silently
            -- did nothing for anyone but the driver. Seat 0 is the front passenger.
            name = 'A PASSENGER can open the glovebox too',
            fn = function(source)
                ClientCloseVehicleStorage(source, _testVehicleId, 'glovebox', 3000)
                waitFor(function() return not vehicleStorageOpen(source) end, 3000)
                OpenVehicleStorageOrFail(source, _testVehicleId, 'glovebox', _testPlate, 0)
                assertTrue(exports.whip_core:__TestIsViewer(source, 'vehicle:' .. _testVehicleId .. ':glovebox'),
                    'a passenger is a viewer of the glovebox')
            end,
        },
        {
            -- The other half of the same rule, and the one that closes the old hole: proximity
            -- used to be enough, so anyone standing beside a LOCKED car could open its glovebox.
            name = 'The glovebox CANNOT be opened from outside the car',
            fn = function(source)
                ClientCloseVehicleStorage(source, _testVehicleId, 'glovebox', 3000)
                waitFor(function() return not vehicleStorageOpen(source) end, 3000)
                ClientLeaveVehicle(source, 5000)
                assertTrue(waitUntilOut(source), 'standing outside the car')
                -- Waits for the SERVER's answer now, so the viewer check below reads this open's
                -- outcome rather than racing it.
                ClientOpenVehicleStorage(source, _testVehicleId, 'glovebox', 5000)
                assertFalse(exports.whip_core:__TestIsViewer(source, 'vehicle:' .. _testVehicleId .. ':glovebox'),
                    'standing outside is not being inside')
                -- Back in the car so the close step below has something to close.
                ClientEnterVehicle(source, _testPlate, -1, 5000)
                OpenVehicleStorageOrFail(source, _testVehicleId, 'glovebox', _testPlate, -1)
            end,
        },
        {
            name = 'Close glovebox',
            fn = function(source)
                ClientCloseVehicleStorage(source, _testVehicleId, 'glovebox', 3000)
                assertTrue(waitFor(function()
                    return not vehicleStorageOpen(source)
                end, 3000) and true or false, 'no vehicle storage left open')
            end,
        },

        -- ==========================================
        -- Phase 5: Leave vehicle + store + delete
        -- ==========================================
        {
            name = 'Player leaves vehicle',
            fn = function(source)
                ClientLeaveVehicle(source, 5000)
                assertTrue(waitUntilOut(source), 'player is out before the vehicle is stored')
            end,
        },
        {
            -- THE REGRESSION TEST FOR THE GARAGE BUG, and it has to read the DATABASE.
            --
            -- Storing must clear the position as well as the state: a row saying 'garaged' next to
            -- a set of coordinates is what the boot restore reads as a car belonging in the street.
            --
            -- ASSERTING THIS FROM GetVehicle WOULD PROVE NOTHING. Vehicles.persist moves the record
            -- FIRST and unconditionally, then writes the row — so a failed write leaves memory
            -- already showing the new state, and every in-memory assertion below would pass while
            -- the database still held the old one. That is the exact failure this test exists to
            -- catch, so it has to ask the disk.
            name = 'StoreVehicle garages it AND clears its position ON DISK',
            fn = function(source)
                -- A REAL GARAGE KEY, from the export a satellite would use. The vehicle was
                -- created with no garage, and StoreVehicle refuses without one.
                local garages = exports.whip_core:GetGarages()
                local garageKey = next(garages or {})
                if not garageKey then
                    skip('no garages configured on this server — nothing to store into')
                end

                local ok, err = exports.whip_core:StoreVehicle(_testVehicleId, garageKey)
                assertTrue(ok, 'StoreVehicle: ' .. tostring(err))

                FlushPersistence(source)

                local rows = DbQuery(
                    'SELECT `state`, `garage`, `x`, `y`, `z` FROM `vehicles` WHERE `vehicleId` = ?',
                    { _testVehicleId })
                assertNotNil(rows[1], 'the row is still there')
                assertEqual(rows[1].state, 'garaged', 'state is garaged ON DISK')
                assertEqual(rows[1].garage, garageKey, 'garage recorded ON DISK')
                assertNil(rows[1].x, 'x cleared ON DISK')
                assertNil(rows[1].y, 'y cleared ON DISK')
                assertNil(rows[1].z, 'z cleared ON DISK')

                -- And the in-memory view agrees with the disk, which is the other half.
                local v = exports.whip_core:GetVehicle(_testVehicleId)
                assertNotNil(v, 'GetVehicle after store')
                assertEqual(v.state, 'garaged', 'state is garaged in memory')
                assertNil(v.coords, 'position cleared in memory')
                assertFalse(v.spawned, 'no longer in the world')
            end,
        },
        {
            -- EVERYTHING GOES, AND ON DISK. DeleteVehicle promises the row, the trunk, the glovebox
            -- and the ignition together; the trunk still holds the food the take left behind, so
            -- a delete that forgot the storage rows is visible here.
            name = 'DeleteVehicle removes it, its row and its storage',
            fn = function(source, ctx)
                local ok, err = exports.whip_core:DeleteVehicle(_testVehicleId)
                assertTrue(ok, 'DeleteVehicle: ' .. tostring(err))
                ctx.deleted = true   -- teardown still removes the key; see there

                assertNil(exports.whip_core:GetVehicle(_testVehicleId), 'vehicle gone')
                assertDbRowCount('SELECT 1 FROM `vehicles` WHERE `vehicleId` = ?', { _testVehicleId }, 0,
                    'the vehicle row is gone from disk')
                assertDbRowCount('SELECT 1 FROM `vehicle_inventory` WHERE `vehicleId` = ?', { _testVehicleId }, 0,
                    'and so is everything that was in it')

                local again, againErr = exports.whip_core:DeleteVehicle(_testVehicleId)
                assertFalse(again, 'a second delete finds nothing')
                assertEqual(againErr, 'Vehicle not found', 'and says so')
            end,
        },
    }
})
