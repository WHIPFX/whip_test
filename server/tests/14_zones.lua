-- ============================================
-- Zones (server)
--
-- Two registries live behind these exports, and the tests have to keep them apart:
--
--   serverZones  memory only — ZoneRegister, plus zones clients MIRROR up to the server
--   dbZones      the `zones` table — EnsureZone and the zone editor; loaded at boot, synced to
--                every client, and removed only by the editor's delete (zeDeleteZone)
--
-- ZoneRemove only knows the first. The EnsureZone test used to "clean up" with it, which
-- removed nothing: every run's zone stayed in the table, reloaded at every restart and went to
-- every player who connected. It is now deleted the way the editor deletes one.
-- ============================================

local ENSURE_KEY = '_test_ensure_zone'

--- Delete a database zone the way the zone editor does, as the tester (who holds whip.devtools).
---@param source number
---@param zoneId string  'dbzone_<n>'
---@return boolean answered
local function editorDelete(source, zoneId)
    -- zeDeleteZone is rate limited to one per 250ms; a delete straight after another is refused.
    Wait(300)
    return ClientExecWait(source, 'whip_core:server:zeDeleteZone', 3000, zoneId)
end

--- The rows in `zones` carrying our key.
local function ensureRows()
    return #DbQuery('SELECT `zoneId` FROM `zones` WHERE `key` = ?', { ENSURE_KEY })
end

RegisterTestModule({
    order    = 14,
    category = 'Zones (Server)',
    setup = function(source, ctx)
        exports.whip_core:ZoneRegister('_test_srv_box', {
            type = 'box', pos = vector3(100, 100, 30),
            size = vector3(20, 20, 10), heading = 0,
            group = '_test_zones', label = 'Test Box',
        })
        exports.whip_core:ZoneRegister('_test_srv_sphere', {
            type = 'sphere', pos = vector3(200, 200, 30),
            radius = 15.0, group = '_test_zones', label = 'Test Sphere',
        })
        exports.whip_core:ZoneRegister('_test_srv_poly', {
            type = 'poly',
            points = { {x=300,y=300}, {x=320,y=300}, {x=320,y=320}, {x=300,y=320} },
            minZ = 25, maxZ = 40, group = '_test_zones', label = 'Test Poly',
        })

        -- The EnsureZone test must start from nothing to be a test of CREATING one. Earlier runs
        -- leaked one into the table (see the header), and EnsureZone then returned the old row, so
        -- the creation path had not actually run since the first time.
        for _, z in ipairs(exports.whip_core:GetAllZones() or {}) do
            if z.key == ENSURE_KEY and z.id then editorDelete(source, z.id) end
        end
    end,
    teardown = function(ctx, source)
        pcall(exports.whip_core.__TestFailNextQuery, exports.whip_core, nil)

        for _, id in ipairs({ '_test_srv_box', '_test_srv_sphere', '_test_srv_poly',
                              '_test_srv_here', '_test_srv_far', '_test_srv_veh', '_test_srv_temp',
                              '_test_client_zone' }) do
            pcall(exports.whip_core.ZoneRemove, exports.whip_core, id)
        end

        if ctx.ensureZoneId and source then
            pcall(editorDelete, source, ctx.ensureZoneId)
        end
    end,
    tests = {
        {
            -- Zones.loadAll runs once, from the boot sequence. A zone saved but not loaded exists
            -- on disk and nowhere else — no client ever hears of it.
            name = 'Every row in the zones table is loaded',
            fn = function()
                local rows = #DbQuery('SELECT `zoneId` FROM `zones`')
                -- The saved zones are the ones with a zoneId; a zone a script made at runtime has none.
                local saved = 0
                for _, z in ipairs(exports.whip_core:GetAllZones() or {}) do
                    if z.zoneId then saved = saved + 1 end
                end
                assertEqual(saved, rows, 'the cache holds exactly the zones on disk')
            end,
        },
        -- ZoneRegister
        {
            -- The shape is read as a client's report is (the Director plan's F5, 2 Oct 2026).
            name = 'ZoneRegister refuses a shape nothing could be inside, saying what is wrong',
            fn = function()
                local cases = {
                    { data = { type = 'circle', pos = vector3(0, 0, 0), radius = 5 },               why = "type is 'sphere'" },
                    { data = { type = 'sphere', pos = vector3(0, 0, 0) },                           why = 'radius' },
                    { data = { type = 'box', pos = vector3(0, 0, 0), size = vector3(1, 0, 1) },     why = 'size' },
                    { data = { type = 'poly', points = { { x = 0, y = 0 }, { x = 1, y = 0 } } },    why = '3 to' },
                    { data = { type = 'sphere', pos = vector3(0, 0, 99999), radius = 5 },           why = 'off the map' },
                }
                for i, c in ipairs(cases) do
                    local ok, why = exports.whip_core:ZoneRegister('_test_srv_bad' .. i, c.data)
                    assertFalse(ok, ('case %d is refused'):format(i))
                    assertTrue(tostring(why):find(c.why, 1, true) ~= nil, ('case %d says "%s" (got: %s)'):format(i, c.why, tostring(why)))
                    assertNil(exports.whip_core:GetZoneDef('_test_srv_bad' .. i), ('case %d was not stored'):format(i))
                end
                local tag = ('_t14_area:%d'):format(GetGameTimer())
                assertOk(exports.whip_core:ZoneRegister('_test_srv_tagged', {
                    type = 'sphere', pos = vector3(0, 0, 30), radius = 5, tag = tag }))
                local okR, n = exports.whip_core:ReleaseTag(tag)
                assertTrue(okR and n == 1, 'ReleaseTag removes a tagged zone')
                assertNil(exports.whip_core:GetZoneDef('_test_srv_tagged'), 'it is gone')
            end,
        },
        {
            name = 'ZoneRegister creates zone',
            fn = function()
                local def = exports.whip_core:GetZoneDef('_test_srv_box')
                assertNotNil(def, 'box registered')
                assertEqual(def.type, 'box', 'type')
                assertEqual(def.label, 'Test Box', 'label')
            end,
        },
        -- ZoneContains — box
        {
            name = 'ZoneContains box: inside center',
            fn = function()
                assertTrue(exports.whip_core:ZoneContains('_test_srv_box', vector3(100, 100, 30)), 'center inside')
            end,
        },
        {
            name = 'ZoneContains box: outside',
            fn = function()
                assertFalse(exports.whip_core:ZoneContains('_test_srv_box', vector3(500, 500, 30)), 'far outside')
            end,
        },
        {
            name = 'ZoneContains box: above height',
            fn = function()
                assertFalse(exports.whip_core:ZoneContains('_test_srv_box', vector3(100, 100, 50)), 'above')
            end,
        },
        -- ZoneContains — sphere
        {
            name = 'ZoneContains sphere: inside',
            fn = function()
                assertTrue(exports.whip_core:ZoneContains('_test_srv_sphere', vector3(200, 200, 30)), 'center')
                assertTrue(exports.whip_core:ZoneContains('_test_srv_sphere', vector3(210, 200, 30)), '10m from the centre')
            end,
        },
        {
            name = 'ZoneContains sphere: outside',
            fn = function()
                assertFalse(exports.whip_core:ZoneContains('_test_srv_sphere', vector3(200, 220, 30)), 'outside radius')
            end,
        },
        -- ZoneContains — poly
        {
            name = 'ZoneContains poly: inside',
            fn = function()
                assertTrue(exports.whip_core:ZoneContains('_test_srv_poly', vector3(310, 310, 32)), 'inside')
            end,
        },
        {
            name = 'ZoneContains poly: outside bounds',
            fn = function()
                assertFalse(exports.whip_core:ZoneContains('_test_srv_poly', vector3(330, 330, 32)), 'outside xy')
                assertFalse(exports.whip_core:ZoneContains('_test_srv_poly', vector3(310, 310, 50)), 'above maxZ')
                assertFalse(exports.whip_core:ZoneContains('_test_srv_poly', vector3(310, 310, 20)), 'below minZ')
            end,
        },
        -- ZoneContains — invalid zone
        {
            name = 'ZoneContains returns false for invalid zone',
            fn = function()
                assertFalse(exports.whip_core:ZoneContains('_nonexistent', vector3(0, 0, 0)), 'invalid')
            end,
        },
        -- GetPlayersInZone — was a type check, which passes for an export that returns {} always.
        {
            name = 'GetPlayersInZone finds the tester in a zone around them, and not in one far away',
            fn = function(source)
                local c = GetEntityCoords(GetPlayerPed(source))
                exports.whip_core:ZoneRegister('_test_srv_here', {
                    type = 'sphere', pos = vector3(c.x, c.y, c.z), radius = 5.0,
                })
                exports.whip_core:ZoneRegister('_test_srv_far', {
                    type = 'sphere', pos = vector3(c.x + 500.0, c.y, c.z), radius = 5.0,
                })

                local function has(list, src)
                    for _, s in ipairs(list or {}) do
                        if tonumber(s) == src then return true end
                    end
                    return false
                end

                assertTrue(has(exports.whip_core:GetPlayersInZone('_test_srv_here'), source),
                    'the tester is in the zone around them')
                assertFalse(has(exports.whip_core:GetPlayersInZone('_test_srv_far'), source),
                    'and not in the one 500m away')
                assertEqual(#(exports.whip_core:GetPlayersInZone('_nonexistent') or {}), 0,
                    'an unknown zone holds nobody')
            end,
        },
        -- GetVehiclesInZone
        {
            name = 'GetVehiclesInZone is empty for a zone with no vehicles in it',
            fn = function()
                exports.whip_core:ZoneRegister('_test_srv_far', {
                    type = 'sphere', pos = vector3(-9000.0, -9000.0, 0.0), radius = 1.0,
                })
                assertEqual(#(exports.whip_core:GetVehiclesInZone('_test_srv_far') or {}), 0,
                    'nothing parked off the edge of the map')
            end,
        },
        {
            name = 'GetVehiclesInZone finds a vehicle standing inside the zone',
            fn = function()
                local veh = GetAllVehicles()[1]
                if not veh then skip('no vehicle entity exists anywhere on the server to aim a zone at') end

                local c = GetEntityCoords(veh)
                exports.whip_core:ZoneRegister('_test_srv_veh', {
                    type = 'sphere', pos = vector3(c.x, c.y, c.z), radius = 2.0,
                })
                -- Each entry is { vehicleId, entity } now (WLD-3); vehicleId is nil for an untracked car.
                local found
                for _, e in ipairs(exports.whip_core:GetVehiclesInZone('_test_srv_veh') or {}) do
                    if type(e) == 'table' and e.entity == veh then found = e break end
                end
                assertNotNil(found, 'the vehicle at the centre is listed, as { vehicleId, entity }')
                if found.vehicleId ~= nil then
                    assertType(found.vehicleId, 'number', 'a tracked car carries its vehicleId')
                end
            end,
        },
        -- GetAllZones
        {
            name = 'GetAllZones includes test zones',
            fn = function()
                local all = exports.whip_core:GetAllZones()
                assertType(all, 'table', 'type')
                local found = false
                for _, z in ipairs(all) do
                    if z.id == '_test_srv_box' then found = true; break end
                end
                assertTrue(found, 'box in list')
            end,
        },
        -- GetZoneDef
        {
            name = 'GetZoneDef returns correct data',
            fn = function()
                local def = exports.whip_core:GetZoneDef('_test_srv_sphere')
                assertNotNil(def, 'exists')
                assertEqual(def.type, 'sphere', 'type')
                assertEqual(def.radius, 15.0, 'radius')
            end,
        },
        {
            name = 'GetZoneDef returns nil for invalid',
            fn = function()
                assertNil(exports.whip_core:GetZoneDef('_nonexistent'), 'nil')
            end,
        },
        -- The client mirror. Server-registered zones are what server code trusts, so no client
        -- report may replace or remove one (zones.lua, zoneRegistered / zoneRemoved).
        {
            name = 'A client report cannot overwrite or remove a server-registered zone',
            fn = function(source)
                assertTrue(ClientExecWait(source, 'whip_core:server:zoneRegistered', 3000,
                    '_test_srv_box', { type = 'sphere', pos = vector3(0.0, 0.0, 0.0), radius = 1.0 }),
                    'the server answered the report')
                local def = exports.whip_core:GetZoneDef('_test_srv_box')
                assertEqual(def and def.type, 'box', 'still the box the server registered')
                assertTrue(exports.whip_core:ZoneContains('_test_srv_box', vector3(100, 100, 30)),
                    'with its own geometry')

                assertTrue(ClientExecWait(source, 'whip_core:server:zoneRemoved', 3000, '_test_srv_box'),
                    'the server answered the removal')
                assertNotNil(exports.whip_core:GetZoneDef('_test_srv_box'), 'and a client cannot remove it')
            end,
        },
        {
            name = 'A client report of a database zone id, or of malformed geometry, is refused',
            fn = function(source)
                local c = GetEntityCoords(GetPlayerPed(source))
                -- The answer is asserted before the reason: a refusal left over from an earlier run
                -- would otherwise satisfy the reason check for a report that never arrived.
                assertTrue(ClientExecWait(source, 'whip_core:server:zoneRegistered', 3000,
                    'dbzone_999999', { type = 'sphere', pos = vector3(c.x, c.y, c.z), radius = 3.0 }),
                    'the server answered the first report')
                assertLastReject('whip_core:server:zoneRegistered', 'reserved zone id',
                    "'dbzone_' ids belong to the database")

                assertTrue(ClientExecWait(source, 'whip_core:server:zoneRegistered', 3000,
                    '_test_client_zone', { type = 'sphere', pos = vector3(c.x, c.y, c.z), radius = -5.0 }),
                    'the server answered the second report')
                -- The reason names what is wrong since 96e99f6 (server zones are checked by the same reader).
                assertLastReject('whip_core:server:zoneRegistered',
                    'zone data failed validation: radius is a number of metres, above 0 and at most 2000',
                    'a negative radius is refused')
                assertNil(exports.whip_core:GetZoneDef('_test_client_zone'), 'and nothing was registered')
            end,
        },
        {
            name = "A client's valid report is mirrored, and its removal drops it",
            fn = function(source)
                local c = GetEntityCoords(GetPlayerPed(source))
                assertTrue(ClientExecWait(source, 'whip_core:server:zoneRegistered', 3000,
                    '_test_client_zone', { type = 'sphere', pos = vector3(c.x, c.y, c.z), radius = 3.0 }),
                    'the server answered the report')
                assertLastReject('whip_core:server:zoneRegistered', nil, 'accepted')
                assertTrue(exports.whip_core:ZoneContains('_test_client_zone', vector3(c.x, c.y, c.z)),
                    'the server can now answer for it')

                assertTrue(ClientExecWait(source, 'whip_core:server:zoneRemoved', 3000, '_test_client_zone'),
                    'the server answered the removal')
                assertNil(exports.whip_core:GetZoneDef('_test_client_zone'),
                    'its only reporter took it away')
            end,
        },
        -- EnsureZone
        {
            name = 'EnsureZone creates a database zone once, and returns it after',
            fn = function(source, ctx)
                assertEqual(ensureRows(), 0, 'no zone with this key before the test')

                local zone, err = exports.whip_core:EnsureZone(ENSURE_KEY, {
                    type = 'sphere', pos = vector3(400, 400, 30),
                    radius = 10, label = 'Ensured Zone',
                })
                assertOk(zone, err, 'EnsureZone created it')
                ctx.ensureZoneId = zone.id
                assertEqual(zone.key, ENSURE_KEY, 'key')
                assertEqual(ensureRows(), 1, 'one row in the zones table')

                -- Again, with a different declaration: the resource changed its zone, and the zone
                -- follows (WLD-2). It used to come back unchanged, whatever the resource said.
                local zone2, err2 = exports.whip_core:EnsureZone(ENSURE_KEY, {
                    type = 'sphere', pos = vector3(0, 0, 0), radius = 99,
                })
                assertOk(zone2, err2, 'a changed declaration is applied')
                assertEqual(zone2.id, zone.id, 'the same zone')
                assertEqual(zone2.radius, 99, 'with the new geometry')
                assertEqual(ensureRows(), 1, 'and no second row was written')
            end,
        },
        {
            -- "Checked, as update already is": a failed delete used to drop the zone from memory,
            -- report "Zone deleted", and bring it back at the next restart (zones.lua deleteFromDb).
            name = 'A zone whose delete fails in the database stays, in memory and on disk',
            fn = function(source, ctx)
                assertNotNil(ctx.ensureZoneId, 'the test above created a zone')

                assertTrue(exports.whip_core:__TestFailNextQuery('DELETE FROM `zones`'), 'fault armed')
                editorDelete(source, ctx.ensureZoneId)
                assertNil(exports.whip_core:__TestRawFaultArmed(), 'the delete really was attempted and failed')

                assertNotNil(exports.whip_core:GetZoneDef(ctx.ensureZoneId), 'still in memory')
                assertEqual(ensureRows(), 1, 'still on disk')
            end,
        },
        {
            name = "The zone editor's delete removes a database zone, row and cache",
            fn = function(source, ctx)
                assertNotNil(ctx.ensureZoneId, 'a zone to delete')

                editorDelete(source, ctx.ensureZoneId)
                assertNil(exports.whip_core:GetZoneDef(ctx.ensureZoneId), 'gone from memory')
                assertEqual(ensureRows(), 0, 'gone from disk')
                ctx.ensureZoneId = nil
            end,
        },
        -- ZoneRemove
        {
            name = 'ZoneRemove removes zone',
            fn = function()
                exports.whip_core:ZoneRegister('_test_srv_temp', {
                    type = 'sphere', pos = vector3(0, 0, 30), radius = 5,
                })
                assertNotNil(exports.whip_core:GetZoneDef('_test_srv_temp'), 'exists')
                exports.whip_core:ZoneRemove('_test_srv_temp')
                assertNil(exports.whip_core:GetZoneDef('_test_srv_temp'), 'removed')
            end,
        },
    }
})
