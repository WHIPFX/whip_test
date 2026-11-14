-- ============================================
-- Vehicle data, vehicle stats, and ownership transfer
--
-- WHY THIS MODULE EXISTS
--
-- Three APIs that write to a vehicle's ROW, none of which had a single test.
--
--   * SetVehicleData is the satellite-facing "attach something to this car" store — which
--     distances a kit was tuned to, whose phone is paired to it, how many times it has been
--     repaired. It rides a statebag to every client in scope AND persists to `vehicles.vehData`.
--   * SetVehicleStats is the numeric half of the same idea: fuel, body condition, a turbo's heat.
--   * TransferVehicle changes who owns a car. It is the one call in the vehicle API that can
--     take somebody's property away.
--
-- WHAT MAKES THE DATA API WORTH TESTING CAREFULLY
--
-- It has real ceilings — 32 keys, 40-character keys, 8 KB serialized — and they exist because
-- the block is re-sent to every client with the car in scope. A ceiling that is enforced late,
-- or enforced but leaves the oversized value behind, is worse than no ceiling: the refusal
-- would be a lie and the block would keep growing. whip_core's own comment records that this
-- happened once already, where the trim "merely counted and logged after writing everything —
-- the block sailed past the ceiling with a note in the console".
--
-- THE VEHICLE HERE IS THIS MODULE'S OWN and is never spawned into the world. Everything under
-- test is row state, so there is nothing to be near, and 05_vehicles owns the fixture that has
-- to be stood next to.
-- ============================================

local PLATE = 'TDAT'

--- A second car, for the CreateOwnedVehicle tests (VEH-3). Made and removed inside each test.
local PLATE2 = 'TDAT2'

--- The stored data block, read straight from the row rather than the cache.
local function vehDataOnDisk(vehicleId)
    local rows = DbQuery('SELECT `vehData` FROM `vehicles` WHERE `vehicleId` = ?', { vehicleId })
    local raw = rows[1] and rows[1].vehData
    if type(raw) == 'string' then return json.decode(raw) or {} end
    if type(raw) == 'table' then return raw end
    return {}
end

local function ownerOnDisk(vehicleId)
    local rows = DbQuery('SELECT `ownerCharId` FROM `vehicles` WHERE `vehicleId` = ?', { vehicleId })
    return rows[1] and tonumber(rows[1].ownerCharId) or nil
end

--- A spot beside the tester with no car or player on it, for a temp car whose doors are checked (it must
--- be near enough for the tester's game to take it). A fixed spot failed whenever a parked car stood there
--- ("Something is already parked in that spot", 2 Oct 2026). Nil when all eight are taken.
local function clearSpotBeside(source)
    local pos = GetEntityCoords(GetPlayerPed(source))
    for _, o in ipairs({ { 6, 0 }, { -6, 0 }, { 0, 6 }, { 0, -6 }, { 9, 9 }, { -9, 9 }, { 9, -9 }, { -9, -9 } }) do
        local at = vector3(pos.x + o[1], pos.y + o[2], pos.z)
        local free = true
        for _, veh in ipairs(GetAllVehicles()) do
            if #(GetEntityCoords(veh) - at) < 4.5 then free = false; break end
        end
        if free and #(pos - at) >= 3.0 then return vector4(at.x, at.y, at.z, 0.0) end
    end
end

--- One stat out of the vehStats JSON on disk, as a number.
local function vehStatOnDisk(vehicleId, name)
    FlushPersistence()
    local rows = DbQuery(
        ("SELECT JSON_UNQUOTE(JSON_EXTRACT(`vehStats`, '$.%s')) AS v FROM `vehicles` WHERE `vehicleId` = ?"):format(name),
        { vehicleId })
    return rows[1] and tonumber(rows[1].v) or nil
end

--- Remove the car wearing one plate, through whip_core first (a raw DELETE leaves the record cached,
--- and the cache is what the plate check reads), then by SQL for a row the cache never loaded.
local function clearPlate(source, plate)
    -- A vehicle REFERENCE (VEH-1): every vehicle export takes `{ plate = ... }` itself, so there is no
    -- plate → id lookup to do first. (A plate on no car makes each call answer false, harmlessly.)
    local car = { plate = plate }
    -- The second car can carry a key into the tester's pockets; take it back with the car.
    if source then pcall(exports.whip_core.RemoveVehicleKey, exports.whip_core, source, car) end
    pcall(exports.whip_core.DespawnVehicle, exports.whip_core, car)
    pcall(exports.whip_core.DeleteVehicle, exports.whip_core, car)
    DbQuery('DELETE FROM `vehicles` WHERE `plate` = ?', { plate })
end

--- Remove BOTH cars — for setup and teardown only, where an interrupted run may have left either.
local function clearFixture(source)
    clearPlate(source, PLATE)
    clearPlate(source, PLATE2)
end

--- Remove only the second car. What the tests themselves call: clearFixture there would also delete
--- the module's own car out from under every test after it (09-23's run lost five tests to that).
local function clearSecondCar(source)
    clearPlate(source, PLATE2)
end

--- The last `whip_core:vehicle:released` announced for each vehicleId, for the temp-car tests that
--- check WHY a car went. At file scope, so it is registered once per resource start, not per run.
local _released = {}
AddEventHandler('whip_core:vehicle:released', function(data)
    if type(data) == 'table' and data.vehicleId then _released[data.vehicleId] = data end
end)

--- An item key for the delete-logging test. Only ever a row in `vehicle_inventory` and the log.
local DELETE_ITEM = '_test_vehdel'

RegisterTestModule({
    order    = 37,
    category = 'Vehicle Data',

    setup = function(source, ctx)
        local p = exports.whip_core:GetPlayer(source)
        if not p then skip('no player loaded') end
        ctx.charId = p.charId

        clearFixture(source)

        -- A stat must be registered before a satellite can write it (VEH-4), so this module
        -- registers the ones it uses, the way a satellite would. They go when whip_test stops.
        for _, name in ipairs({ '_test_heat', '_test_wear', '_test_ok', '_test_bad' }) do
            local ok, regErr = exports.whip_core:RegisterVehicleStat(name, {
                default = 0, min = 0, max = 1000, persist = true,
            })
            if not ok then skip(('could not register %s: %s'):format(name, tostring(regErr))) end
        end

        local vehicleId, err = exports.whip_core:CreateOwnedVehicle(source, {
            model = 'asea', plate = PLATE, state = 'garaged',
        })
        if not vehicleId or vehicleId == false then
            skip('could not create the fixture vehicle: ' .. tostring(err))
        end
        ctx.vehicleId = vehicleId
    end,

    teardown = function(ctx, source)
        -- Every temp car a failed test left behind (it would otherwise last until whip_test stops,
        -- and one spawned for the player leaves its key in their pockets). ALL of them: this held one
        -- id, so a second failing test overwrote the first's and its key leaked (first run, 09-24).
        -- DespawnVehicle on one already gone just answers false.
        for _, id in ipairs(ctx.temps or {}) do
            pcall(exports.whip_core.DespawnVehicle, exports.whip_core, id)
        end
        if ctx.vehicleId then
            -- ITS KEYS FIRST, by id, while the car exists: clearFixture below clears keys by PLATE, and
            -- a plate names no car once the delete has run — a key a test gave this car stayed in the
            -- tester's pockets (09-26). Looped: each call takes one key.
            if source then
                for _ = 1, 5 do
                    local ran, took = pcall(exports.whip_core.RemoveVehicleKey, exports.whip_core, source, ctx.vehicleId)
                    if not (ran and took) then break end
                end
            end
            pcall(exports.whip_core.ClearAllVehicleData, exports.whip_core, ctx.vehicleId)
            pcall(exports.whip_core.DespawnVehicle, exports.whip_core, ctx.vehicleId)
            pcall(exports.whip_core.DeleteVehicle, exports.whip_core, ctx.vehicleId)
        end
        clearFixture(source)
    end,

    tests = {
        -- ==========================================
        -- Vehicle data — the basics
        -- ==========================================
        {
            name = 'SetVehicleData round-trips through GetVehicleData',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:SetVehicleData(ctx.vehicleId, 'tuneKit', 'stage2'),
                    'the value was accepted')
                assertEqual(exports.whip_core:GetVehicleData(ctx.vehicleId, 'tuneKit'), 'stage2',
                    'and reads back unchanged')
            end,
        },
        {
            name = 'A table value survives whole, not flattened',
            fn = function(source, ctx)
                -- The block is JSON on the way to the row, so a nested value is where a naive
                -- encode/decode loses its shape.
                assertTrue(exports.whip_core:SetVehicleData(ctx.vehicleId, 'kit',
                    { name = 'turbo', level = 3, tags = { 'a', 'b' } }), 'accepted')

                local got = exports.whip_core:GetVehicleData(ctx.vehicleId, 'kit')
                assertNotNil(got, 'reads back')
                assertEqual(got.name, 'turbo', 'string field intact')
                assertEqual(got.level, 3, 'number field intact')
                assertEqual(got.tags and got.tags[2], 'b', 'nested array intact')
            end,
        },
        {
            -- VEH-11. `false` is a value; it must not read back as "not set".
            name = 'A stored false reads back as false, not nil',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:SetVehicleData(ctx.vehicleId, 'flagOff', false), 'false accepted')
                assertTrue(exports.whip_core:GetVehicleData(ctx.vehicleId, 'flagOff') == false,
                    'and reads back as false')
                exports.whip_core:ClearVehicleData(ctx.vehicleId, 'flagOff')
            end,
        },
        {
            name = 'An absent key reads nil — there are no registered defaults here',
            fn = function(source, ctx)
                assertNil(exports.whip_core:GetVehicleData(ctx.vehicleId, 'neverSet'),
                    'absent means absent; nothing declares what data a vehicle ought to have')
            end,
        },
        {
            name = 'SetVehicleData with a table writes the batch and reports how many landed',
            fn = function(source, ctx)
                exports.whip_core:ClearAllVehicleData(ctx.vehicleId)

                local written = exports.whip_core:SetVehicleData(ctx.vehicleId, {
                    alpha = 1, bravo = 'two', charlie = { x = 3 },
                })
                assertEqual(written, 3, 'three keys reported written')

                local all = exports.whip_core:GetVehicleData(ctx.vehicleId)
                assertNotNil(all, 'the whole block reads back')
                assertEqual(all.alpha, 1, 'alpha')
                assertEqual(all.bravo, 'two', 'bravo')
                assertEqual(all.charlie and all.charlie.x, 3, 'charlie')
            end,
        },
        -- (A test that GetVehicleData returns a COPY lived here. It could not fail: everything
        -- crossing an export is a copy, so writing into the answer never reached the vehicle
        -- whatever VehicleData.getAll handed back. Only an in-core caller could observe that rule.)
        {
            name = 'ClearVehicleData removes one key; ClearAllVehicleData removes the rest, on disk too',
            fn = function(source, ctx)
                exports.whip_core:SetVehicleData(ctx.vehicleId, { keepMe = 1, dropMe = 2 })

                assertTrue(exports.whip_core:ClearVehicleData(ctx.vehicleId, 'dropMe'), 'clear reported success')
                assertNil(exports.whip_core:GetVehicleData(ctx.vehicleId, 'dropMe'), 'the key is gone')
                assertEqual(exports.whip_core:GetVehicleData(ctx.vehicleId, 'keepMe'), 1,
                    'and its neighbour is untouched')
                local stored = vehDataOnDisk(ctx.vehicleId)
                assertNil(stored.dropMe, 'the cleared key is gone from the row')
                assertEqual(stored.keepMe, 1, 'and the neighbour is still in it')

                assertTrue(exports.whip_core:ClearAllVehicleData(ctx.vehicleId), 'clearAll reported success')
                local all = exports.whip_core:GetVehicleData(ctx.vehicleId) or {}
                assertNil(next(all), 'clearAll left nothing behind')

                -- The row is written with NULL for an empty block, not '[]' — absent means absent,
                -- on disk as on the entity.
                assertDbScalar('SELECT `vehData` IS NULL FROM `vehicles` WHERE `vehicleId` = ?',
                    { ctx.vehicleId }, 1, 'clearAll reached the row as NULL')
            end,
        },
        {
            -- EMPTY MUST REPLICATE AS ABSENT. An emptied block put on the entity as `{}` serialises
            -- as `[]`, which the Sentinel's truth (empty -> nil) reads as a value the server never
            -- wrote — and three of those kicked players for taking their own car out of a garage.
            name = 'The data block rides the entity statebag, and an emptied block is ABSENT, not []',
            fn = function(source, ctx)
                -- Spawned a long way off, like the load test's cars: the entity exists on the server
                -- whether or not any client streams it, and the bag is what is under test.
                local pos = GetEntityCoords(GetPlayerPed(source))
                local netId, err = exports.whip_core:SpawnVehicle(ctx.vehicleId, vector4(pos.x + 1200.0, pos.y + 1200.0, pos.z, 0.0))
                if not netId then skip('could not spawn the fixture vehicle: ' .. tostring(err)) end
                ctx.spawned = true

                local entity = waitFor(function()
                    local e = NetworkGetEntityFromNetworkId(netId)
                    return (e and e ~= 0 and DoesEntityExist(e)) and e or nil
                end, 3000)
                assertNotNil(entity, 'the spawned entity exists')

                assertTrue(exports.whip_core:SetVehicleData(ctx.vehicleId, 'rep', 'seen'), 'value set')
                local bag = Entity(entity).state.whipVehData
                assertEqual(bag and bag.rep, 'seen', 'the value is on the entity bag')

                assertTrue(exports.whip_core:ClearAllVehicleData(ctx.vehicleId), 'clearAll reported success')
                assertNil(Entity(entity).state.whipVehData, 'the emptied block is ABSENT from the bag, not []')

                exports.whip_core:DespawnVehicle(ctx.vehicleId)
            end,
        },

        -- ==========================================
        -- Vehicle data — the ceilings
        -- ==========================================
        {
            name = 'Keys that could carry a JSON path are refused',
            fn = function(source, ctx)
                -- Keys reach SQL as a JSON path. A key carrying a dot, a quote or a bracket is
                -- not a naming-convention argument, it is the injection surface.
                for _, bad in ipairs({ '', 'has.dot', 'has"quote', 'has space', 'has$dollar',
                                       'has[bracket]', string.rep('x', 41) }) do
                    local ok = exports.whip_core:SetVehicleData(ctx.vehicleId, bad, 1)
                    assertFalse(ok, ('key %q must be refused'):format(bad))
                end

                -- And the shape that IS allowed, so the guard is not simply refusing everything.
                assertTrue(exports.whip_core:SetVehicleData(ctx.vehicleId, 'good_KEY_9', 1),
                    'letters, digits and underscore are accepted')
                exports.whip_core:ClearVehicleData(ctx.vehicleId, 'good_KEY_9')
            end,
        },
        {
            name = 'An oversized value is refused AND LEAVES NO TRACE',
            fn = function(source, ctx)
                -- The contract is apply, measure, and only then keep. A refusal that left the
                -- value in place would be a lie, and the block would be over the ceiling that
                -- the refusal claimed to be protecting.
                exports.whip_core:ClearAllVehicleData(ctx.vehicleId)
                exports.whip_core:SetVehicleData(ctx.vehicleId, 'before', 'small')

                local ok, err = exports.whip_core:SetVehicleData(ctx.vehicleId, 'huge',
                    string.rep('x', 9000))
                assertFalse(ok, 'a value past the 8 KB block ceiling is refused')
                assertNotNil(err, 'with a reason')

                assertNil(exports.whip_core:GetVehicleData(ctx.vehicleId, 'huge'),
                    'the refused value is NOT on the vehicle')
                assertEqual(exports.whip_core:GetVehicleData(ctx.vehicleId, 'before'), 'small',
                    'and the key that was already there is undamaged')
            end,
        },
        {
            name = 'The 32-key ceiling holds, and the 33rd key is refused',
            fn = function(source, ctx)
                exports.whip_core:ClearAllVehicleData(ctx.vehicleId)

                local batch = {}
                for i = 1, 32 do batch['k' .. i] = i end
                assertEqual(exports.whip_core:SetVehicleData(ctx.vehicleId, batch), 32,
                    'all thirty-two fit')

                local ok = exports.whip_core:SetVehicleData(ctx.vehicleId, 'k33', 1)
                assertFalse(ok, 'the thirty-third NEW key is refused')
                assertNil(exports.whip_core:GetVehicleData(ctx.vehicleId, 'k33'), 'and is not stored')

                -- Overwriting an EXISTING key must still work at the ceiling: the limit is on
                -- how many keys a vehicle carries, not on how often they change.
                assertTrue(exports.whip_core:SetVehicleData(ctx.vehicleId, 'k1', 'changed'),
                    'an existing key can still be updated at the ceiling')
                assertEqual(exports.whip_core:GetVehicleData(ctx.vehicleId, 'k1'), 'changed', 'and it took')

                exports.whip_core:ClearAllVehicleData(ctx.vehicleId)
            end,
        },
        {
            name = 'setMany TRIMS at the ceiling rather than refusing the whole batch',
            fn = function(source, ctx)
                -- The documented behaviour, and the half that was once only a comment: keys
                -- that fit are written, the overflow is skipped.
                exports.whip_core:ClearAllVehicleData(ctx.vehicleId)

                local batch = {}
                for i = 1, 40 do batch['m' .. i] = i end
                local written = exports.whip_core:SetVehicleData(ctx.vehicleId, batch)

                assertEqual(written, 32, 'exactly the ceiling was written, not all forty')

                local all = exports.whip_core:GetVehicleData(ctx.vehicleId) or {}
                local n = 0
                for _ in pairs(all) do n = n + 1 end
                assertEqual(n, 32, 'and the block really holds thirty-two, not more')

                exports.whip_core:ClearAllVehicleData(ctx.vehicleId)
            end,
        },
        {
            name = 'An unknown vehicle is refused by every data export',
            fn = function(source, ctx)
                local GONE = 987654
                local ok, err = exports.whip_core:SetVehicleData(GONE, 'x', 1)
                assertFalse(ok, 'set is refused')
                assertNotNil(err, 'with a reason')
                -- `false, why` when nothing is written (DX-19, 09-25) — it was `0`, which is TRUE in Lua.
                local many, manyErr = exports.whip_core:SetVehicleData(GONE, { x = 1 })
                assertFalse(many, 'a batch writes nothing, and says so with false')
                assertNotNil(manyErr, 'with a reason')
                assertNil(exports.whip_core:GetVehicleData(GONE, 'x'), 'get answers nil')
            end,
        },
        {
            -- VEH-10. The data and stat exports indexed the record table with whatever they were
            -- handed, so a vehicleId that arrived as a string silently found nothing.
            name = 'A vehicleId given as a string works; 0, negatives and junk are refused with a reason',
            fn = function(source, ctx)
                local asText = tostring(ctx.vehicleId)

                assertTrue(exports.whip_core:SetVehicleData(asText, 'strId', 1), 'SetVehicleData takes "12"')
                assertEqual(exports.whip_core:GetVehicleData(asText, 'strId'), 1, 'GetVehicleData takes it too')
                assertTrue(exports.whip_core:SetVehicleStat(asText, '_test_ok', 3), 'SetVehicleStat takes "12"')
                assertEqual(exports.whip_core:GetVehicleStat(asText, '_test_ok'), 3, 'GetVehicleStat takes it too')
                exports.whip_core:ClearVehicleData(ctx.vehicleId, 'strId')

                for _, bad in ipairs({ 0, -1, 1.5, 'abc' }) do
                    local ok, err = exports.whip_core:SetVehicleData(bad, 'x', 1)
                    assertFalse(ok, ('SetVehicleData refuses %s'):format(tostring(bad)))
                    assertEqual(err, 'Invalid vehicleId', 'with the reason')
                    local sOk, sErr = exports.whip_core:SetVehicleStat(bad, '_test_ok', 1)
                    assertFalse(sOk, ('SetVehicleStat refuses %s'):format(tostring(bad)))
                    assertEqual(sErr, 'Invalid vehicleId', 'with the reason')
                end
            end,
        },
        {
            name = 'Vehicle data is DURABLE — it reaches the vehicles row',
            fn = function(source, ctx)
                -- Everything above asserts the cache. This is the half that decides whether a
                -- kit is still fitted after a restart.
                exports.whip_core:ClearAllVehicleData(ctx.vehicleId)
                assertTrue(exports.whip_core:SetVehicleData(ctx.vehicleId, 'persisted', 'yes'),
                    'value accepted')

                local stored = vehDataOnDisk(ctx.vehicleId)
                assertEqual(stored.persisted, 'yes', 'the vehicles row carries it')

                exports.whip_core:ClearVehicleData(ctx.vehicleId, 'persisted')
                assertNil(vehDataOnDisk(ctx.vehicleId).persisted,
                    'and clearing it reaches the row too')
            end,
        },

        -- ==========================================
        -- Vehicle data — who owns a key (VEH-2)
        -- ==========================================
        -- A key belongs to the resource that first wrote it. The "other resource" here is
        -- __TestSetVehicleDataAs, because a test run only has whip_test to call from.
        {
            name = "Another resource's key can be READ but not overwritten or cleared",
            fn = function(source, ctx)
                exports.whip_core:ClearAllVehicleData(ctx.vehicleId)
                assertTrue(exports.whip_core:__TestSetVehicleDataAs(ctx.vehicleId, 'theirs', 'kit A', 'fake_satellite'),
                    'the other resource wrote its key')

                assertEqual(exports.whip_core:GetVehicleData(ctx.vehicleId, 'theirs'), 'kit A',
                    'anyone can read it')

                local ok, err = exports.whip_core:SetVehicleData(ctx.vehicleId, 'theirs', 'hijacked')
                assertFalse(ok, 'overwriting it is refused')
                assertTrue(tostring(err):find('fake_satellite', 1, true) ~= nil,
                    ('and the reason names the owner (got "%s")'):format(tostring(err)))

                local cleared = exports.whip_core:ClearVehicleData(ctx.vehicleId, 'theirs')
                assertFalse(cleared, 'clearing it is refused')

                -- One foreign key refuses the whole batch, so nothing half-lands.
                local written, batchErr = exports.whip_core:SetVehicleData(ctx.vehicleId,
                    { theirs = 'x', mineToo = 1 })
                assertFalse(written, 'a batch touching it writes nothing (false, since DX-19)')
                assertNotNil(batchErr, 'with a reason')
                assertNil(exports.whip_core:GetVehicleData(ctx.vehicleId, 'mineToo'),
                    'not even the key that was ours to write')

                assertEqual(exports.whip_core:GetVehicleData(ctx.vehicleId, 'theirs'), 'kit A',
                    'and their value is untouched')

                exports.whip_core:__TestSetVehicleDataAs(ctx.vehicleId, 'theirs', nil, 'fake_satellite')
            end,
        },
        {
            name = "ClearAllVehicleData takes away only the caller's own keys",
            fn = function(source, ctx)
                exports.whip_core:ClearAllVehicleData(ctx.vehicleId)
                exports.whip_core:__TestSetVehicleDataAs(ctx.vehicleId, 'theirs', 1, 'fake_satellite')
                assertTrue(exports.whip_core:SetVehicleData(ctx.vehicleId, { mineA = 1, mineB = 2 }) == 2,
                    'two keys of our own')

                assertTrue(exports.whip_core:ClearAllVehicleData(ctx.vehicleId), 'clearAll reported success')
                assertNil(exports.whip_core:GetVehicleData(ctx.vehicleId, 'mineA'), 'our first key went')
                assertNil(exports.whip_core:GetVehicleData(ctx.vehicleId, 'mineB'), 'our second key went')
                assertEqual(exports.whip_core:GetVehicleData(ctx.vehicleId, 'theirs'), 1,
                    "the other resource's key is still there")
                assertEqual(vehDataOnDisk(ctx.vehicleId).theirs, 1, 'on disk too')

                exports.whip_core:__TestSetVehicleDataAs(ctx.vehicleId, 'theirs', nil, 'fake_satellite')
            end,
        },
        {
            name = 'Who owns a key is SAVED with the data, and never shown to readers',
            fn = function(source, ctx)
                exports.whip_core:ClearAllVehicleData(ctx.vehicleId)
                exports.whip_core:__TestSetVehicleDataAs(ctx.vehicleId, 'theirs', 1, 'fake_satellite')
                exports.whip_core:SetVehicleData(ctx.vehicleId, 'mine', 2)

                -- On disk, so a restart does not hand the key to whoever writes first.
                local owners = vehDataOnDisk(ctx.vehicleId)['@owners']
                assertNotNil(owners, 'the row carries the owners note')
                assertEqual(owners and owners.theirs, 'fake_satellite', 'their key is recorded as theirs')
                assertEqual(owners and owners.mine, GetCurrentResourceName(), 'ours is recorded as ours')

                -- Readers never see it: not in the export, not on the entity bag.
                local all = exports.whip_core:GetVehicleData(ctx.vehicleId) or {}
                assertNil(all['@owners'], 'GetVehicleData does not include the owners note')

                exports.whip_core:ClearAllVehicleData(ctx.vehicleId)
                exports.whip_core:__TestSetVehicleDataAs(ctx.vehicleId, 'theirs', nil, 'fake_satellite')
                assertDbScalar('SELECT `vehData` IS NULL FROM `vehicles` WHERE `vehicleId` = ?',
                    { ctx.vehicleId }, 1, 'with every key gone, the row is NULL again, owners and all')
            end,
        },
        {
            name = 'The 32-key budget is PER RESOURCE',
            fn = function(source, ctx)
                exports.whip_core:ClearAllVehicleData(ctx.vehicleId)
                exports.whip_core:__TestSetVehicleDataAs(ctx.vehicleId, 'theirs', 1, 'fake_satellite')

                -- Before, the other resource's one key would have left room for only 31 of ours.
                local batch = {}
                for i = 1, 32 do batch['b' .. i] = i end
                assertEqual(exports.whip_core:SetVehicleData(ctx.vehicleId, batch), 32,
                    "all 32 of ours fit alongside the other resource's key")

                exports.whip_core:ClearAllVehicleData(ctx.vehicleId)
                exports.whip_core:__TestSetVehicleDataAs(ctx.vehicleId, 'theirs', nil, 'fake_satellite')
            end,
        },

        -- ==========================================
        -- Vehicle stats
        -- ==========================================
        {
            name = 'SetVehicleStats writes a batch that reads back — and reaches the row',
            fn = function(source, ctx)
                local written = exports.whip_core:SetVehicleStats(ctx.vehicleId, {
                    _test_heat = 42, _test_wear = 7,
                })
                assertEqual(written, 2, 'both stats reported written')

                local stored = exports.whip_core:GetVehicleStats(ctx.vehicleId, { stored = true })
                assertNotNil(stored, 'stored stats read back')
                assertEqual(stored._test_heat, 42, 'first stat')
                assertEqual(stored._test_wear, 7, 'second stat')

                -- GetVehicleStats { stored = true } reads the cache. Stats are write-behind on their own
                -- fifteen-second queue, which FlushPersistence now drains, so the row can be asked.
                assertEqual(vehStatOnDisk(ctx.vehicleId, '_test_heat'), 42, 'the first stat is on disk')
                assertEqual(vehStatOnDisk(ctx.vehicleId, '_test_wear'), 7, 'the second stat is on disk')
            end,
        },
        {
            name = 'Non-numeric stat values are skipped, not stored as junk',
            fn = function(source, ctx)
                -- A stat is a number by definition. Storing a string would survive the write
                -- and fail much later, wherever something did arithmetic on it.
                local written = exports.whip_core:SetVehicleStats(ctx.vehicleId, {
                    _test_ok = 5, _test_bad = 'not a number',
                })
                assertEqual(written, 1, 'only the numeric one was written')

                local stored = exports.whip_core:GetVehicleStats(ctx.vehicleId, { stored = true }) or {}
                assertEqual(stored._test_ok, 5, 'the good value landed')
                assertNil(stored._test_bad, 'the bad value did not')
            end,
        },
        {
            name = 'AddVehicleStat applies a delta to what is already there',
            fn = function(source, ctx)
                exports.whip_core:SetVehicleStats(ctx.vehicleId, { _test_heat = 10 })
                exports.whip_core:AddVehicleStat(ctx.vehicleId, '_test_heat', 15)

                local stored = exports.whip_core:GetVehicleStats(ctx.vehicleId, { stored = true }) or {}
                assertEqual(stored._test_heat, 25, 'the delta was added, not assigned')
                assertEqual(vehStatOnDisk(ctx.vehicleId, '_test_heat'), 25, 'and the sum is what reached disk')
            end,
        },
        {
            -- VEH-4. A typo used to succeed and be saved on the car forever.
            name = 'An UNREGISTERED stat name is refused by every stat setter, with a reason',
            fn = function(source, ctx)
                local ok, err = exports.whip_core:SetVehicleStat(ctx.vehicleId, '_test_feul', 50)
                assertFalse(ok, 'SetVehicleStat refuses it')
                assertTrue(tostring(err):find('RegisterVehicleStat', 1, true) ~= nil,
                    ('and says how to fix it (got "%s")'):format(tostring(err)))

                local addOk, addErr = exports.whip_core:AddVehicleStat(ctx.vehicleId, '_test_feul', 5)
                assertFalse(addOk, 'AddVehicleStat refuses it')
                assertNotNil(addErr, 'with a reason')

                local none, noneErr = exports.whip_core:SetVehicleStats(ctx.vehicleId, { _test_feul = 1 })
                assertEqual(none, false, 'a batch of only unknown names writes nothing (false)')
                assertNotNil(noneErr, 'and says why')

                -- In a mixed batch the known names still land; the unknown one is skipped.
                local some = exports.whip_core:SetVehicleStats(ctx.vehicleId, { _test_ok = 9, _test_feul = 1 })
                assertEqual(some, 1, 'the registered stat in a mixed batch was written')

                local stored = exports.whip_core:GetVehicleStats(ctx.vehicleId, { stored = true }) or {}
                assertNil(stored._test_feul, 'the typo is not on the car')
                assertEqual(stored._test_ok, 9, 'the real stat is')
                assertNil(vehStatOnDisk(ctx.vehicleId, '_test_feul'), 'and the typo never reached the row')
            end,
        },
        {
            -- VEH-11. Every "no" says why. SetVehicleStats answered (0, reason) until audit 3 DX-19;
            -- 0 is true in Lua, so it answers (false, reason) like everything else now.
            name = 'Stat setters say WHY they refused, and SetVehicleStats answers (false, reason)',
            fn = function(source, ctx)
                local GONE = 987654

                local ok, err = exports.whip_core:SetVehicleStat(GONE, '_test_ok', 1)
                assertFalse(ok, 'an unknown car is refused')
                assertNotNil(err, 'with a reason (this used to be a bare false)')

                local nOk, nErr = exports.whip_core:SetVehicleStat(ctx.vehicleId, '_test_ok', 'lots')
                assertFalse(nOk, 'a value that is not a number is refused')
                assertNotNil(nErr, 'with a reason')

                local cOk, cErr = exports.whip_core:ClearVehicleStat(GONE, '_test_ok')
                assertFalse(cOk, 'clearing on an unknown car is refused')
                assertNotNil(cErr, 'with a reason')

                local none, noneErr = exports.whip_core:SetVehicleStats(GONE, { _test_ok = 1 })
                assertEqual(none, false, 'SetVehicleStats answers false when nothing was written')
                assertNotNil(noneErr, 'and the reason second')

                local empty, emptyErr = exports.whip_core:SetVehicleStats(ctx.vehicleId, { _test_ok = 'x' })
                assertEqual(empty, false, 'nothing numeric, nothing written')
                assertNotNil(emptyErr, 'and it says so')

                local noData, noDataErr = exports.whip_core:SetVehicleData(GONE, { k = 1 })
                assertEqual(noData, false, 'SetVehicleData with a table answers false the same way')
                assertNotNil(noDataErr, 'with a reason')
            end,
        },
        {
            -- VEH-12. One table with the same names on both sides, and the current value on subscribe.
            name = 'OnVehicleStatChanged { table, now }: the current value first, then each change as one table',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:SetVehicleStat(ctx.vehicleId, '_test_heat', 5), 'a value to start from')

                local got = {}
                exports.whip_core:OnVehicleStatChanged('_test_heat', function(change)
                    if change.vehicleId == ctx.vehicleId then got[#got + 1] = change end
                end, 'veh12', { table = true, now = true })

                local ok, err = pcall(function()
                    assertTrue(waitFor(function() return #got >= 1 end, 3000) and true or false,
                        '`now` delivered what the car already carries')
                    assertEqual(got[1].key, '_test_heat', 'as a table naming the stat')
                    assertEqual(got[1].value, 5, 'with its current value')

                    exports.whip_core:SetVehicleStat(ctx.vehicleId, '_test_heat', 7)
                    assertTrue(waitFor(function() return #got >= 2 end, 3000) and true or false, 'the change arrived')
                    assertEqual(got[2].value, 7, 'the new value')
                    assertEqual(got[2].old, 5, 'and the old one')
                    assertFalse(got[2].cleared, 'not cleared')
                end)

                -- No unregister export: re-registering under the same id replaces it with a no-op.
                exports.whip_core:OnVehicleStatChanged('_test_heat', function() end, 'veh12')
                if not ok then error(err, 0) end
            end,
        },
        {
            -- '*' hears every stat with its name, so an add-on can follow another resource's stats.
            name = 'OnVehicleStatChanged \'*\': every stat, with its name, and `now` hands over what cars carry',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:SetVehicleStat(ctx.vehicleId, '_test_wear', 3), 'a value to start from')
                assertTrue(exports.whip_core:SetVehicleStat(ctx.vehicleId, '_test_heat', 40), 'and another')

                local got = {}
                exports.whip_core:OnVehicleStatChanged('*', function(vehicleId, name, value, previous)
                    if vehicleId == ctx.vehicleId then got[#got + 1] = { name = name, value = value, previous = previous } end
                end, 'star', { now = true })

                local ok, err = pcall(function()
                    local function heard(name, value)
                        for _, g in ipairs(got) do
                            if g.name == name and g.value == value then return g end
                        end
                    end
                    assertNotNil(waitFor(function() return heard('_test_wear', 3) end, 3000),
                        '`now` named a stat the car already carries')

                    exports.whip_core:SetVehicleStat(ctx.vehicleId, '_test_heat', 41)
                    local change = waitFor(function() return heard('_test_heat', 41) end, 3000)
                    assertNotNil(change, 'a change to another stat arrived, named')
                    assertEqual(change and change.previous, 40, 'with its old value')
                end)

                -- Taken off again: whip_test keeps running, and a '*' left behind hears every stat on the server.
                local removed = exports.whip_core:__TestRemoveVehicleStatListener('*', 'star')
                if not ok then error(err, 0) end
                assertTrue(removed, 'the test listener came off')
            end,
        },
        {
            name = 'OnVehicleDataChanged { table, now }: the current value first, then set and clear with old values',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:SetVehicleData(ctx.vehicleId, 'listenKey', 1), 'a value to start from')

                local got = {}
                exports.whip_core:OnVehicleDataChanged('listenKey', function(change)
                    if change.vehicleId == ctx.vehicleId then got[#got + 1] = change end
                end, 'veh12', { table = true, now = true })

                local ok, err = pcall(function()
                    assertTrue(waitFor(function() return #got >= 1 end, 3000) and true or false,
                        '`now` delivered what the car already carries')
                    assertEqual(got[1].key, 'listenKey', 'as a table naming the key')
                    assertEqual(got[1].value, 1, 'with its current value')

                    exports.whip_core:SetVehicleData(ctx.vehicleId, 'listenKey', 2)
                    assertTrue(waitFor(function() return #got >= 2 end, 3000) and true or false, 'the change arrived')
                    assertEqual(got[2].value, 2, 'the new value')
                    assertEqual(got[2].old, 1, 'and the old one — the server supplies it now')

                    exports.whip_core:ClearVehicleData(ctx.vehicleId, 'listenKey')
                    assertTrue(waitFor(function() return #got >= 3 end, 3000) and true or false, 'the clear arrived')
                    assertTrue(got[3].cleared == true, 'marked cleared')
                    assertEqual(got[3].old, 2, 'with what it was')
                end)

                exports.whip_core:OnVehicleDataChanged('listenKey', function() end, 'veh12')
                exports.whip_core:ClearVehicleData(ctx.vehicleId, 'listenKey')
                if not ok then error(err, 0) end
            end,
        },

        -- ==========================================
        -- CreateOwnedVehicle in one call (VEH-3)
        -- ==========================================
        {
            name = 'CreateOwnedVehicle with giveKey + spawnAt makes, spawns and keys the car in ONE call',
            fn = function(source, ctx)
                if not exports.whip_core:CanFitItem(source, 'vehicle_key', 1) then
                    skip('no room in your pockets for a key')
                end

                -- A long way off, like the statebag test: the entity is what is under test, not
                -- whether any client streams it.
                local pos = GetEntityCoords(GetPlayerPed(source))
                local at = vector4(pos.x + 1200.0, pos.y + 1200.0, pos.z, 90.0)

                local id, err = exports.whip_core:CreateOwnedVehicle(source,
                    { model = 'asea', plate = PLATE2 }, { giveKey = true, spawnAt = at })
                assertOk(id, err, 'CreateOwnedVehicle')

                local v = exports.whip_core:GetVehicle(id)
                assertEqual(v and v.plate, PLATE2, 'the plate asked for')
                assertTrue(v and v.spawned == true, 'it is already in the world')
                assertNotNil(v and v.netId, 'with a netId, from GetVehicle')
                assertEqual(v and v.state, 'out', 'and the row says out')
                assertTrue(exports.whip_core:HasVehicleKey(source, id), 'the key is in their pockets')

                clearSecondCar(source)
            end,
        },
        {
            name = 'A bad spawnAt is refused BEFORE any car is made',
            fn = function(source, ctx)
                clearSecondCar(source)
                local id, err = exports.whip_core:CreateOwnedVehicle(source,
                    { model = 'asea', plate = PLATE2 }, { spawnAt = 'over there' })
                assertFalse(id, 'refused')
                assertNotNil(err, 'with a reason')
                assertDbScalar('SELECT COUNT(*) FROM `vehicles` WHERE `plate` = ?', { PLATE2 }, 0,
                    'and no row was written')
            end,
        },
        {
            name = 'Without a vehType, the entity type comes from the vehicle catalog',
            fn = function(source, ctx)
                -- A motorbike built as a car is broken on its first spawn. The dealership used to
                -- carry its own class table to avoid that; whip now reads the catalog itself.
                local model
                for m, row in pairs(exports.whip_core:GetVehicleCatalog() or {}) do
                    if tonumber(row.class) == 8 then model = m break end
                end
                if not model then skip('the vehicle catalog has no motorbike in it to try') end

                clearSecondCar(source)
                local id, err = exports.whip_core:CreateOwnedVehicle(source, { model = model, plate = PLATE2 })
                assertOk(id, err, 'CreateOwnedVehicle ' .. model)
                assertDbScalar('SELECT `vehType` FROM `vehicles` WHERE `vehicleId` = ?', { id }, 'bike',
                    ('%s is written as a bike before it is ever spawned'):format(model))
                clearSecondCar(source)
            end,
        },

        -- ==========================================
        -- Garage reads (VEH-14)
        -- ==========================================
        {
            name = 'GetNearestGarage honours maxRange, and GetGarageVehicles answers in the GetVehicle shape',
            fn = function(source, ctx)
                -- A PUBLIC garage: GetNearestGarage skips private ones (a property's), and next() handed
                -- back whichever came first, so the test failed whenever that was a property garage.
                local key, g
                for k, def in pairs(exports.whip_core:GetGarages() or {}) do
                    if not def.private then key, g = k, def break end
                end
                if not key then skip('no public garages on this server') end

                local found, dist = exports.whip_core:GetNearestGarage(g.x, g.y, g.z, 5.0)
                assertNotNil(found, 'standing on a garage marker finds a garage within 5m')
                assertTrue((dist or 99) <= 5.0, 'and says how far')
                assertNil(exports.whip_core:GetNearestGarage(g.x + 5000.0, g.y + 5000.0, g.z, 10.0),
                    'miles from anything, with a 10m range, finds nothing')

                -- GetGarageVehicles is "what is STORED here". So: assigned here but out — not listed;
                -- then put away here — listed.
                --
                -- OUT FIRST (17 Oct 2026). This assumed the statebag test above left the fixture 'out', as
                -- a despawn did when it was written. Since 10 Oct (9842980c) a despawn files the car in its
                -- garage, so it arrived garaged and StoreVehicle (DespawnVehicle with a garage since 14 Nov 2026)
                -- rightly said "Vehicle is already stored".
                -- Spawned far off, as the reference test below does, it is out whatever came before.
                local function listed()
                    for _, v in ipairs(exports.whip_core:GetGarageVehicles(key)) do
                        if v.vehicleId == ctx.vehicleId then return v end
                    end
                    return nil
                end

                if (exports.whip_core:GetVehicle(ctx.vehicleId) or {}).state ~= 'out' then
                    local pos = GetEntityCoords(GetPlayerPed(source))
                    local netId, sErr = exports.whip_core:SpawnVehicle(ctx.vehicleId, vector4(pos.x + 1200.0, pos.y + 1220.0, pos.z, 0.0))
                    if not netId then skip('could not bring the fixture out: ' .. tostring(sErr)) end
                    waitFor(function()
                        local e = NetworkGetEntityFromNetworkId(netId)
                        return (e and e ~= 0 and DoesEntityExist(e)) and e or nil
                    end, 3000)
                end

                local ok, err = exports.whip_core:SetVehicleGarage(ctx.vehicleId, key)
                assertOk(ok, err, 'SetVehicleGarage')
                if (exports.whip_core:GetVehicle(ctx.vehicleId) or {}).state == 'out' then
                    assertNil(listed(), 'a car that is out is not listed, even assigned to this garage')
                end

                local stored, storeErr = exports.whip_core:DespawnVehicle(ctx.vehicleId, { garage = key, refuseOccupied = true })
                assertOk(stored, storeErr, 'DespawnVehicle into this garage')
                local mine = listed()
                assertNotNil(mine, 'the fixture is listed in its garage')
                assertEqual(mine and mine.plate, PLATE, 'with its plate')
                assertEqual(mine and mine.owner and mine.owner.charId, ctx.charId,
                    'and the owner block every GetVehicle snapshot has')
                assertEqual(mine and mine.garage, key, 'and the garage it is in')
            end,
        },

        {
            -- VEH-1. One way to name a car on both sides: { id } { plate } { entity } { netId }.
            name = 'Every vehicle export takes a vehicle REFERENCE, and says why when it names no car',
            fn = function(source, ctx)
                local id = ctx.vehicleId

                assertEqual((exports.whip_core:GetVehicle({ id = id }) or {}).vehicleId, id, '{ id = } finds it')
                assertEqual((exports.whip_core:GetVehicle({ plate = PLATE }) or {}).vehicleId, id, '{ plate = } finds it')

                assertTrue(exports.whip_core:SetVehicleData({ plate = PLATE }, 'refKey', 'x'), 'a data write by plate')
                assertEqual(exports.whip_core:GetVehicleData({ id = id }, 'refKey'), 'x', 'reads back by id')
                exports.whip_core:ClearVehicleData(id, 'refKey')

                assertTrue(exports.whip_core:SetVehicleStat({ plate = PLATE }, '_test_ok', 4), 'a stat write by plate')
                assertEqual(exports.whip_core:GetVehicleStat(id, '_test_ok'), 4, 'reads back by bare id')

                -- In the world, so the entity and netId forms have something to find.
                local pos = GetEntityCoords(GetPlayerPed(source))
                local netId, err = exports.whip_core:SpawnVehicle(id, vector4(pos.x + 1200.0, pos.y + 1220.0, pos.z, 0.0))
                if not netId then skip('could not spawn the fixture: ' .. tostring(err)) end
                local ok, spawnErr = pcall(function()
                    local entity = waitFor(function()
                        local e = NetworkGetEntityFromNetworkId(netId)
                        return (e and e ~= 0 and DoesEntityExist(e)) and e or nil
                    end, 3000)
                    assertNotNil(entity, 'the entity exists')
                    assertEqual((exports.whip_core:GetVehicle({ netId = netId }) or {}).vehicleId, id, '{ netId = } finds it')
                    assertEqual((exports.whip_core:GetVehicle({ entity = entity }) or {}).vehicleId, id, '{ entity = } finds it')
                end)
                exports.whip_core:DespawnVehicle(id)
                if not ok then error(spawnErr, 0) end

                local nOk, nErr = exports.whip_core:SetVehicleData({ plate = '_NOPLT_' }, 'k', 1)
                assertFalse(nOk, 'a plate on no car is refused')
                assertEqual(nErr, 'Vehicle not found', 'and says so')

                local bOk, bErr = exports.whip_core:SetVehicleData({ colour = 'red' }, 'k', 1)
                assertFalse(bOk, 'a table that names nothing is refused')
                assertEqual(bErr, 'Invalid vehicle reference', 'and says so')
            end,
        },
        {
            -- VEH-16. EnsureVehicle never created anything, so it got the name that says so — and the
            -- old name was removed 24 Sep 2026 (whip is unreleased: one name).
            name = 'AdoptVehicle adopts by plate; the old name EnsureVehicle is gone',
            fn = function(source, ctx)
                assertEqual(exports.whip_core:AdoptVehicle(PLATE), ctx.vehicleId,
                    'a plate whip already knows answers with its vehicleId')
                assertFalse(pcall(function() return exports.whip_core:EnsureVehicle(PLATE) end),
                    'EnsureVehicle no longer exists')

                local ok, err = exports.whip_core:AdoptVehicle('_NOPLT_')
                assertFalse(ok, 'a plate on no car is refused')
                assertNotNil(err, 'with a reason')
            end,
        },
        {
            -- audit 3, VEH-6: a plate is text a driver can change, so the car itself can be passed.
            name = 'AdoptVehicle takes the car itself: { entity = } and { netId = }',
            fn = function(source, ctx)
                local pos = GetEntityCoords(GetPlayerPed(source))
                local netId, err = exports.whip_core:SpawnVehicle(ctx.vehicleId, vector4(pos.x + 1200.0, pos.y + 1240.0, pos.z, 0.0))
                if not netId then skip('could not spawn the fixture: ' .. tostring(err)) end
                local ok, runErr = pcall(function()
                    local entity = waitFor(function()
                        local e = NetworkGetEntityFromNetworkId(netId)
                        return (e and e ~= 0 and DoesEntityExist(e)) and e or nil
                    end, 3000)
                    assertNotNil(entity, 'the entity exists')
                    assertEqual(exports.whip_core:AdoptVehicle({ entity = entity }), ctx.vehicleId,
                        'a car whip already tracks answers with its vehicleId, by entity')
                    assertEqual(exports.whip_core:AdoptVehicle({ netId = netId }), ctx.vehicleId, 'and by netId')
                end)
                exports.whip_core:DespawnVehicle(ctx.vehicleId)
                if not ok then error(runErr, 0) end

                local nOk, nErr = exports.whip_core:AdoptVehicle({ entity = 0 })
                assertFalse(nOk, 'no car there is refused')
                assertEqual(nErr, 'No vehicle there', 'and says so')
            end,
        },
        {
            -- A GONE STREET CAR'S PLATE MAKES A NEW RECORD, AND IT COUNTS (audit 7, VEH-2). Since
            -- audit 6 (VEH-17) a street car whose car has gone is dropped and a new record made for the
            -- next car wearing its plate. The two callers still asked "was there a record for this
            -- plate?" BEFORE the call, got yes, skipped the per-player cap and never counted the new
            -- one: delete your car, re-plate a fresh one, repeat, for any number of pinned cars.
            -- Driven through resolveVehicle as the tester's own client, the path that counts.
            name = 'A fresh car wearing a gone street car\'s plate is a new record, counted against the player',
            fn = function(source)
                local STREET = 'TSTREET'
                local pos = GetEntityCoords(GetPlayerPed(source))
                local function streetCar()
                    local e = CreateVehicleServerSetter(GetHashKey('asea'), 'automobile', pos.x + 6.0, pos.y + 3.0, pos.z, 0.0)
                    if not waitFor(function() return e and e ~= 0 and DoesEntityExist(e) end, 3000) then return nil end
                    SetVehicleNumberPlateText(e, STREET)
                    waitFor(function()
                        return (GetVehicleNumberPlateText(e) or ''):gsub('%s+', '') == STREET
                    end, 3000)
                    return e
                end
                local function resolve(e)
                    local answered, res = ClientCallback(source, 'whip_core:resolveVehicle', 5000,
                        STREET, 'asea', NetworkGetNetworkIdFromEntity(e), 'automobile')
                    return answered and res and res[1] or nil
                end

                local e1 = streetCar()
                if not e1 then skip('could not make a street car beside you') end
                local id1, holder1, e2, id2, holder2
                local ok, runErr = pcall(function()
                    id1 = resolve(e1)
                    holder1 = id1 and exports.whip_core:__TestStreetCarHolder(id1)
                    DeleteEntity(e1)
                    waitFor(function() return not DoesEntityExist(e1) end, 3000)
                    Wait(600)   -- resolveVehicle's rate limit is 500 ms
                    e2 = streetCar()
                    id2 = e2 and resolve(e2)
                    holder2 = id2 and exports.whip_core:__TestStreetCarHolder(id2)
                end)
                -- Cleaned up before anything is judged: a street car whip holds is pinned in the world.
                for _, id in ipairs({ id1, id2 }) do
                    if id then pcall(exports.whip_core.DespawnVehicle, exports.whip_core, id) end
                end
                for _, e in ipairs({ e1, e2 }) do
                    if e and DoesEntityExist(e) then DeleteEntity(e) end
                end
                if not ok then error(runErr, 0) end

                assertNotNil(id1, 'the first street car resolved to an id')
                assertEqual(holder1, source, 'and counts against the tester')
                assertNotNil(id2, 'the fresh car wearing its plate resolved too')
                assertTrue(id2 ~= id1, 'as a NEW record — the gone car\'s was dropped (VEH-17)')
                assertEqual(holder2, source, 'and that new record counts against the tester too')
            end,
        },

        -- ==========================================
        -- Temporary cars (VEH-7)
        -- ==========================================
        {
            name = 'SpawnTempVehicle: in the world, NO row, keyed to the player, and DespawnVehicle removes it whole',
            fn = function(source, ctx)
                if not exports.whip_core:CanFitItem(source, 'vehicle_key', 1) then
                    skip('no room in your pockets for a key')
                end
                -- BESIDE THE TESTER, not 1200 m off like the other spawns here. The doors are checked
                -- below, and a lock reaches a car's doors through the game that has the car loaded:
                -- the server's lock is carried out by the client that owns the car, and only then does
                -- the server's door read have an answer. 1200 m away no game has the car, so the doors
                -- read 0 ("unknown") whatever whip did — which is how this failed on its first run
                -- (09-24), testing nothing. Next to the player their game takes the car and reports.
                local spot = clearSpotBeside(source)
                if not spot then skip('cars all around you — stand somewhere with room for one beside you') end
                local id, err = exports.whip_core:SpawnTempVehicle('asea', spot, { forSource = source, plate = 'TTMP1' })
                assertOk(id, err, 'SpawnTempVehicle')
                ctx.temps = ctx.temps or {}
                ctx.temps[#ctx.temps + 1] = id

                local v = exports.whip_core:GetVehicle(id)
                assertTrue(v and v.session == true, 'a session vehicle')
                assertTrue(v and v.temp == true, 'that GetVehicle says is TEMPORARY, not street traffic')
                assertTrue(v and v.spawned == true, 'in the world')
                assertEqual(v and v.plate, 'TTMP1', 'with the plate asked for')
                assertDbScalar('SELECT COUNT(*) FROM `vehicles` WHERE `plate` = ?', { 'TTMP1' }, 0,
                    'and no database row')
                assertTrue(exports.whip_core:HasVehicleKey(source, id), 'the player was given a key')
                assertTrue(exports.whip_core:SetVehicleData(id, 'rental', 'yes'),
                    'it carries vehicle data like any other car')

                -- LOCKED (AI build test, 09-24). A temp car used to be asked its lock state like
                -- street traffic, and a car the server built a moment ago always answered "open".
                assertTrue(v and v.locked == true, 'it spawned locked')
                -- Waited for: 0 until the tester's game has the car and has reported its doors.
                local doors = v and v.entity and waitFor(function()
                    local s = GetVehicleDoorLockStatus(v.entity)
                    return s ~= 0 and s or nil
                end, 5000)
                assertEqual(doors, 2, 'and once a game has the car, its doors are locked')
                assertFalse(exports.whip_core:GetVehicle(ctx.vehicleId).temp, 'an owned car is not temp')

                local ok, dErr = exports.whip_core:DespawnVehicle(id)
                assertOk(ok, dErr, 'DespawnVehicle')
                assertNil(exports.whip_core:GetVehicle(id), 'the car is forgotten')
                assertFalse(exports.whip_core:HasVehicleKey(source, id), 'and its key was taken back')
                assertEqual(_released[id] and _released[id].reason, 'despawned', 'released, saying why')
                assertTrue(_released[id] and _released[id].temp == true, 'and that it was a temp car')
            end,
        },
        {
            -- The Director's run cars (3 Oct 2026): a tag, released with the run; secure, which the
            -- lockpick and the ignition hack refuse (events_vehicles.lua).
            name = 'SpawnTempVehicle: tag (gone with ReleaseTag, then refused) and secure',
            fn = function(source, ctx)
                local spot = clearSpotBeside(source)
                if not spot then skip('cars all around you — stand somewhere with room for one beside you') end
                local tag = 'test:runcar:' .. tostring(GetGameTimer())
                local id, err = exports.whip_core:SpawnTempVehicle('asea', spot, { tag = tag, secure = true, plate = 'TRUN1' })
                assertOk(id, err, 'SpawnTempVehicle with a tag')
                ctx.temps = ctx.temps or {}
                ctx.temps[#ctx.temps + 1] = id
                local v = exports.whip_core:GetVehicle(id)
                assertTrue(v and v.secure == true, 'GetVehicle says it is secure')
                assertTrue(v and v.temp == true, 'and temporary')

                local okR, released = exports.whip_core:ReleaseTag(tag)
                assertTrue(okR == true and (tonumber(released) or 0) >= 1, 'ReleaseTag counts the car')
                local gone = waitFor(function() return exports.whip_core:GetVehicle(id) == nil end, 5000)
                assertTrue(gone == true, 'and the car is gone with the tag')

                local again, aErr = exports.whip_core:SpawnTempVehicle('asea', spot, { tag = tag })
                assertFalse(again, 'a car asked for under a released tag is refused')
                assertTrue(type(aErr) == 'string' and aErr:find('ended', 1, true) ~= nil, 'saying the tag has ended: ' .. tostring(aErr))
            end,
        },
        {
            name = 'SpawnTempVehicle options: locked = false, keyInIgnition, idleDespawn = false',
            fn = function(source, ctx)
                -- Beside the tester, for the doors — see the test above.
                local spot = clearSpotBeside(source)
                if not spot then skip('cars all around you — stand somewhere with room for one beside you') end
                local id, err = exports.whip_core:SpawnTempVehicle('asea', spot,
                    { locked = false, keyInIgnition = true, idleDespawn = false })
                assertOk(id, err, 'SpawnTempVehicle')
                ctx.temps = ctx.temps or {}
                ctx.temps[#ctx.temps + 1] = id

                local v = exports.whip_core:GetVehicle(id)
                assertTrue(v and v.locked == false, 'locked = false stands open')

                -- THE DOORS ARE NOT LOCKED — which is the promise, rather than one particular number.
                -- GTA has two "open" values, 0 (no lock) and 1 (unlocked), and on its second run
                -- (09-24) an open car read 0 on the server for the whole five seconds while the
                -- locked car above read 2 at once. So: wait for the tester's game to take the car
                -- (it gets an owner), watch for a lock that should not come, then check it is open.
                local owned = v and v.entity and waitFor(function()
                    return NetworkGetEntityOwner(v.entity) ~= -1
                end, 5000)
                assertTrue(owned == true, 'a game took the car')
                local sawLock = waitFor(function() return GetVehicleDoorLockStatus(v.entity) == 2 end, 1500)
                assertTrue(not sawLock, 'its doors never read locked')
                local status = GetVehicleDoorLockStatus(v.entity)
                assertTrue(status == 0 or status == 1,
                    ('and they read open (status %s: 0 no lock, 1 unlocked)'):format(tostring(status)))

                local inIgnition = exports.whip_core:__TestKeyInIgnition(id)
                if inIgnition == nil then skip('test seams are off (Config.EnableTestSeams)') end
                assertTrue(inIgnition, 'keyInIgnition put a fitting key in its ignition')

                -- No despawnAfter and no idle sweep: only DespawnVehicle (or whip_test stopping)
                -- ends it. The sweep's ten minutes cannot be waited out here; the option reaching
                -- the car is what can be checked.
                local ok, dErr = exports.whip_core:DespawnVehicle(id)
                assertOk(ok, dErr, 'DespawnVehicle')
            end,
        },
        {
            name = 'SpawnTempVehicle despawnAfter removes the car when the time runs out',
            fn = function(source, ctx)
                local pos = GetEntityCoords(GetPlayerPed(source))
                local id, err = exports.whip_core:SpawnTempVehicle('asea',
                    vector4(pos.x + 1200.0, pos.y + 1210.0, pos.z, 0.0), { despawnAfter = 1 })
                assertOk(id, err, 'SpawnTempVehicle')
                ctx.temps = ctx.temps or {}
                ctx.temps[#ctx.temps + 1] = id

                assertNotNil(exports.whip_core:GetVehicle(id), 'there to begin with')
                local gone = waitFor(function() return exports.whip_core:GetVehicle(id) == nil end, 4000)
                assertTrue(gone and true or false, 'gone once its second is up')
                assertEqual(_released[id] and _released[id].reason, 'expired',
                    'released with the reason a rental script needs: its time ran out')
            end,
        },
        {
            -- VEH-9. GetVehicleStorage handed back whip's internal store object, which nothing
            -- outside whip_core could use. It was made to answer StoreRead's plain data, and then
            -- (09-24) removed in favour of StoreRead itself. So this now pins that a VEHICLE
            -- ADDRESS reads back in that plain shape — by vehicleId, and by a vehicle reference
            -- such as { plate }, the same forms every other vehicle export takes (VEH-1).
            name = 'StoreRead answers a vehicle address with plain data, by id or by reference',
            fn = function(source, ctx)
                local trunk, err = exports.whip_core:StoreRead({ kind = 'vehicle', id = ctx.vehicleId, sub = 'trunk' })
                assertOk(trunk, err, 'StoreRead of the trunk')
                assertType(trunk.slots, 'number', 'it says how big the trunk is')
                assertType(trunk.items, 'table', 'and what is in it')
                assertEqual(trunk.kind, 'vehicle', 'as a vehicle store')
                assertEqual(trunk.id, ctx.vehicleId, 'of this car')
                assertEqual(trunk.sub, 'trunk', 'the trunk')

                -- A reference as the address id: the answer names the car by its vehicleId,
                -- whichever way it was asked for.
                local byPlate, plateErr = exports.whip_core:StoreRead({ kind = 'vehicle', id = { plate = PLATE }, sub = 'trunk' })
                assertOk(byPlate, plateErr, 'StoreRead by { plate = }')
                assertEqual(byPlate.id, ctx.vehicleId, 'finds the same car')
                assertEqual(byPlate.slots, trunk.slots, 'and agrees about it')

                local bad, badErr = exports.whip_core:StoreRead({ kind = 'vehicle', id = ctx.vehicleId, sub = 'roof' })
                assertFalse(bad, 'a compartment a car does not have is refused')
                assertNotNil(badErr, 'with a reason')

                local none, noneErr = exports.whip_core:StoreRead({ kind = 'vehicle', id = { plate = '_NOPLT_' }, sub = 'trunk' })
                assertFalse(none, 'a plate on no car is refused')
                assertEqual(noneErr, 'Vehicle not found', 'and says so')
            end,
        },
        {
            -- House rule 9 (AI build test, 09-24): deleting an owned car took its trunk, glovebox and
            -- ignition rows with it and wrote nothing. The row here is put in the DATABASE, on a car
            -- whose storage has never been loaded, so the delete has to read it before it can log it.
            name = 'DeleteVehicle logs everything in the car as lost',
            fn = function(source, ctx)
                clearSecondCar(source)
                local id, err = exports.whip_core:CreateOwnedVehicle(source, {
                    model = 'asea', plate = PLATE2, state = 'garaged',
                })
                assertOk(id, err, 'CreateOwnedVehicle')

                DbQuery('INSERT INTO `vehicle_inventory` (`vehicleId`, `storageType`, `slot`, `item`, `amount`) '
                    .. 'VALUES (?, ?, ?, ?, ?)', { id, 'trunk', 1, DELETE_ITEM, 3 })
                assertTrue(exports.whip_core:FlushActivityLog(), 'earlier rows out before clearing')
                DbQuery('DELETE FROM `activity_log` WHERE `itemKey` = ?', { DELETE_ITEM })

                local ok, dErr = exports.whip_core:DeleteVehicle(id)
                assertOk(ok, dErr, 'DeleteVehicle')
                assertTrue(exports.whip_core:FlushActivityLog(), 'activity log flushed')

                local rows = DbQuery(
                    'SELECT `event`, `charId`, `amount`, `detail` FROM `activity_log` WHERE `itemKey` = ?',
                    { DELETE_ITEM })
                DbQuery('DELETE FROM `activity_log` WHERE `itemKey` = ?', { DELETE_ITEM })
                assertEqual(#rows, 1, 'one row for what was in the trunk')
                assertEqual(rows[1] and rows[1].event, 'lost', 'logged as lost')
                assertEqual(rows[1] and rows[1].amount, 3, 'the whole stack')
                assertEqual(rows[1] and tonumber(rows[1].charId), ctx.charId, "on the owner's timeline")
                assertTrue(rows[1] and tostring(rows[1].detail):find('deleted', 1, true) ~= nil,
                    ('saying why (got "%s")'):format(tostring(rows[1] and rows[1].detail)))
                assertDbScalar('SELECT COUNT(*) FROM `vehicle_inventory` WHERE `vehicleId` = ?', { id }, 0,
                    'and the trunk row went with the car')
            end,
        },

        -- ==========================================
        -- Ownership transfer
        -- ==========================================
        {
            name = 'TransferVehicle REFUSES to transfer a car to the character that owns it',
            fn = function(source, ctx)
                -- The safety property. A self-transfer that "succeeded" would be a free way to
                -- launder ownership history and, with revokeOldKeys on, to strip and reissue
                -- keys on a car nothing actually changed about.
                local ok, err = exports.whip_core:TransferVehicle(ctx.vehicleId, source)
                assertFalse(ok, 'refused')
                assertTrue(tostring(err):lower():find('already owned', 1, true) ~= nil,
                    ('and says why (got "%s")'):format(tostring(err)))

                assertEqual(ownerOnDisk(ctx.vehicleId), ctx.charId,
                    'the row still names the original owner')
            end,
        },
        {
            name = 'TransferVehicle refuses a malformed or unknown request',
            fn = function(source, ctx)
                local ok1, e1 = exports.whip_core:TransferVehicle(0, source)
                assertFalse(ok1, 'vehicleId 0 refused')
                assertNotNil(e1, 'with a reason')

                -- A bare number is a server id, and one nobody is on is refused (a character offline is { charId })
                local ok2, e2 = exports.whip_core:TransferVehicle(ctx.vehicleId, 99999)
                assertFalse(ok2, 'a server id nobody is on is refused')
                assertTrue(tostring(e2):lower():find('online', 1, true) ~= nil,
                    ('and says so (got "%s")'):format(tostring(e2)))

                local ok2b, e2b = exports.whip_core:TransferVehicle(ctx.vehicleId, { charId = 987654321 })
                assertFalse(ok2b, 'a character who is not playing is refused')
                assertNotNil(e2b, 'with a reason')

                local ok3, e3 = exports.whip_core:TransferVehicle(987654, source)
                assertFalse(ok3, 'an unknown vehicle is refused')
                assertNotNil(e3, 'with a reason')

                assertEqual(ownerOnDisk(ctx.vehicleId), ctx.charId,
                    'and none of the three changed the owner')
            end,
        },
        {
            name = 'TransferVehicle moves ownership to another player',
            fn = function(source, ctx)
                -- The success path genuinely needs a second loaded character: the export
                -- resolves the new owner through Players[source], and transferring to the
                -- current owner is refused by design (above). Skipped rather than faked,
                -- because a transfer to oneself proves the opposite of what this claims.
                -- Load-test phantoms (sources above 900000) live in Players too, and have no
                -- character behind them: picked as "other", the transfer is refused as an invalid
                -- character and reported as a failure rather than a skip.
                local other = nil
                for src in pairs(exports.whip_core:GetPlayers() or {}) do
                    local id = tonumber(src)
                    if id and id ~= source and id <= 900000 then other = id break end
                end
                if not other then skip('needs a second player online to receive the vehicle') end

                local otherPlayer = exports.whip_core:GetPlayer(other)
                if not otherPlayer then skip('the second player has no character loaded') end

                local ok, err = exports.whip_core:TransferVehicle(ctx.vehicleId, other,
                    { giveKey = false, revokeOldKeys = false })
                assertTrue(ok, 'TransferVehicle: ' .. tostring(err))
                assertEqual(ownerOnDisk(ctx.vehicleId), otherPlayer.charId,
                    'the row names the new owner')

                -- Put it back, so teardown deletes a car this character still owns.
                exports.whip_core:TransferVehicle(ctx.vehicleId, source,
                    { giveKey = false, revokeOldKeys = false })
                assertEqual(ownerOnDisk(ctx.vehicleId), ctx.charId, 'and it transfers back')
            end,
        },
        {
            -- A REPORT IS HELD BACK ONLY WHERE THE RECORD STORES A VALUE (audit 7, VEH-3). A car made
            -- with no colours (every dealership car) "held back" eleven fields on every exit, and the
            -- console named the driver for paint they never touched.
            name = 'An exit report is held back only for what the car\'s record stores',
            fn = function(source, ctx)
                local report = { color1 = 12, color2 = 5, pearlescentColor = 3, dirtLevel = 2.0 }
                -- Seeded from what the fixture already stores, so a colour it keeps is compared fairly.
                local stored = (exports.whip_core:GetVehicle(ctx.vehicleId) or {}).properties or {}
                if stored.color1 ~= nil then skip('the fixture car already stores a colour') end
                local before = exports.whip_core:__TestHeldBack(ctx.vehicleId, report)
                assertTrue(before == nil or #before == 0, 'nothing stored, nothing held back (got: '
                    .. (before and table.concat(before, ', ') or 'nil') .. ')')

                assertOk(exports.whip_core:SetVehicleAppearance(ctx.vehicleId, { color1 = 7 }), nil, 'a colour set by the server')
                local after = exports.whip_core:__TestHeldBack(ctx.vehicleId, report) or {}
                local named = table.concat(after, ', ')
                assertTrue(named:find('color1', 1, true) ~= nil, 'a different color1 than the stored one is held back')
                assertTrue(named:find('color2', 1, true) == nil, 'and color2, which the record does not store, is not')
            end,
        },
        {
            -- THE LOOK AND ITS DATA IN ONE WRITE (3 Oct 2026). A Whiplash order with tuning AND parts was
            -- two writes: a crash between kept the money and the tuning but lost the parts.
            name = 'SetVehicleAppearance with data: the look and the data land together, or neither does',
            fn = function(source, ctx)
                local function tintOnDisk()
                    local rows = DbQuery('SELECT `properties` FROM `vehicles` WHERE `vehicleId` = ?', { ctx.vehicleId })
                    local raw = rows[1] and rows[1].properties
                    local props = type(raw) == 'string' and json.decode(raw) or raw or {}
                    return props.windowTint
                end
                local function tint() return ((exports.whip_core:GetVehicle(ctx.vehicleId) or {}).properties or {}).windowTint end

                assertOk(exports.whip_core:SetVehicleAppearance(ctx.vehicleId, { windowTint = 1 },
                    { data = { lookKit = 'a', lookOld = 1 } }), nil, 'the look and two keys')
                assertEqual(tint(), 1, 'the look is on the record')
                assertEqual(exports.whip_core:GetVehicleData(ctx.vehicleId, 'lookKit'), 'a', 'the data too')
                assertEqual(tintOnDisk(), 1, 'the look is on disk')
                assertEqual(vehDataOnDisk(ctx.vehicleId).lookKit, 'a', 'and the data, in the same row')

                assertTrue(exports.whip_core:__TestSetDbFaultMode('vehicle_row'), 'fault armed')
                local ok, err = exports.whip_core:SetVehicleAppearance(ctx.vehicleId, { windowTint = 2 },
                    { data = { lookKit = 'b' }, clearData = { 'lookOld' } })
                assertNil(exports.whip_core:__TestGetDbFaultMode(), 'the fault fired on that write')
                assertFalse(ok, 'a failed write is reported')
                assertNotNil(err, 'with a reason')
                assertEqual(tint(), 1, 'the look went back')
                assertEqual(exports.whip_core:GetVehicleData(ctx.vehicleId, 'lookKit'), 'a', 'the set key went back')
                assertEqual(exports.whip_core:GetVehicleData(ctx.vehicleId, 'lookOld'), 1, 'the cleared key went back')
                assertEqual(tintOnDisk(), 1, 'the row kept the old look')
                assertEqual(vehDataOnDisk(ctx.vehicleId).lookKit, 'a', 'and the old data')

                assertOk(exports.whip_core:SetVehicleAppearance(ctx.vehicleId, {}, { clearData = { 'lookKit', 'lookOld' } }),
                    nil, 'keys removed with no change to the look')
                assertNil(exports.whip_core:GetVehicleData(ctx.vehicleId, 'lookKit'), 'gone from the record')
                assertNil(vehDataOnDisk(ctx.vehicleId).lookOld, 'and from disk')
                assertEqual(tintOnDisk(), 1, 'the look untouched')

                local refused = exports.whip_core:SetVehicleAppearance(ctx.vehicleId, { windowTint = 3 },
                    { data = { lookKit = 'c' }, clearData = { 'lookKit' } })
                assertFalse(refused, 'a key both set and cleared is refused')
                assertEqual(tint(), 1, 'and nothing changed')
            end,
        },
        {
            -- A CAR WITH ITS OWN KEY INSIDE COMES OUT UNLOCKED (Josh, 26 Sep 2026; audit 7, VEH-1).
            -- Retrieve always locked it, so a car stored with its key in the ignition came out locked
            -- with the key inside, and the owner could not get back in. Without a key inside, it still
            -- comes out locked. Last in the module: it moves the fixture car in and out of a garage.
            name = 'A car garaged with its own key in the ignition comes out unlocked; without one, locked',
            fn = function(source, ctx)
                local garageKey = next(exports.whip_core:GetGarages() or {})
                if not garageKey then skip('no garages configured on this server') end
                local ign = { kind = 'vehicle', id = ctx.vehicleId, sub = 'key', slot = 1 }
                -- Into THIS test's garage. DespawnVehicle files a car in its own garage now (10 Oct 2026), so after it
                -- the car may already be garaged — elsewhere: out of there and into this one.
                local function garage()
                    local v = exports.whip_core:GetVehicle(ctx.vehicleId)
                    if v and v.state ~= 'garaged' then
                        pcall(exports.whip_core.DespawnVehicle, exports.whip_core, ctx.vehicleId)
                    end
                    v = exports.whip_core:GetVehicle(ctx.vehicleId)
                    if v and v.state == 'garaged' and v.garage ~= garageKey then
                        assertOk(exports.whip_core:RetrieveVehicle(ctx.vehicleId, v.garage))
                        v = exports.whip_core:GetVehicle(ctx.vehicleId)
                    end
                    if v and v.state ~= 'garaged' then
                        assertOk(exports.whip_core:DespawnVehicle(ctx.vehicleId, { garage = garageKey, refuseOccupied = true }))
                    end
                end

                garage()
                assertNil(exports.whip_core:GetItemAt(ign), 'the ignition is empty')
                assertOk(exports.whip_core:RetrieveVehicle(ctx.vehicleId, garageKey))
                assertTrue(exports.whip_core:GetVehicle(ctx.vehicleId).locked, 'with no key inside it comes out locked')

                garage()
                pcall(exports.whip_core.GiveVehicleKey, exports.whip_core, source, ctx.vehicleId)
                local pocket
                for slot = 1, exports.whip_core:GetPocketSlots('player') or 0 do
                    local s = exports.whip_core:GetItemAt(PocketAddr(source, 'player', slot))
                    if s and s.item == 'vehicle_key' and s.metadata and tonumber(s.metadata.vehicleId) == ctx.vehicleId then
                        pocket = slot
                        break
                    end
                end
                if not pocket then skip('could not give the fixture car a key') end
                assertOk(exports.whip_core:StoreMove(PocketAddr(source, 'player', pocket), ign), nil, 'its key into the ignition')

                local ok, err = exports.whip_core:RetrieveVehicle(ctx.vehicleId, garageKey)
                local locked = exports.whip_core:GetVehicle(ctx.vehicleId).locked
                -- The test's key goes, from the ignition and from the pockets (if the move above did
                -- not happen). It was handed back to the pockets at first, and teardown — which deletes
                -- the car before clearing keys by its plate — left it there (first run, 09-26).
                pcall(exports.whip_core.StoreTake, exports.whip_core, ign)
                pcall(exports.whip_core.RemoveVehicleKey, exports.whip_core, source, ctx.vehicleId)

                assertOk(ok, err, 'retrieved')
                assertFalse(locked, 'with its own key in the ignition it comes out unlocked')
            end,
        },
    }
})
