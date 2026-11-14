-- ============================================
-- Properties — the server core
-- ============================================
--
-- WHY THIS MODULE EXISTS
--
-- A property's whole security is its front door: the door's requirements say who opens it, and
-- server/properties.lua writes them. Get that list wrong and a stranger walks into somebody's
-- home, or an owner is locked out of their own. So these tests read the DOOR, not the property:
-- after every change of owner or key, what does the door itself now say?
--
-- The fixture is a property in world space (no interior), built next to the tester through the
-- __TestPropertyFixture seam, because the Configurator that will normally make them does not exist
-- yet. It needs Config.EnableTestSeams.

local DOOR_MODEL = GetHashKey('prop_door_01')

local function near(a, b, eps) return math.abs(a - b) <= (eps or 0.01) end

--- The same maths as shared/property_math.lua's toWorld, written out again so the test does not
--- trust the code it is checking.
local function toWorld(place, lx, ly, lz)
    local t = math.rad(place.yaw)
    local c, s = math.cos(t), math.sin(t)
    return place.x + lx * c - ly * s, place.y + lx * s + ly * c, place.z + lz
end

local function doorOf(propertyId, key)
    local p = exports.whip_core:GetProperty(propertyId)
    local id = p and p.doorIds and p.doorIds[key]
    return id and exports.whip_core:GetDoor(id) or nil, id
end

local function charIdsOn(door)
    local req = door and door.requirements
    return (type(req) == 'table' and req.charIds) or nil
end

--- A unit: a 6 x 4 m room, a managed entrance, and an interior door that must be left alone.
local UNIT = {
    label = '_test unit',
    base = {
        space = { { type = 'box', center = { x = 0, y = 0, z = 1.5 }, size = { x = 6, y = 4, z = 3 }, heading = 0 } },
        doors = {
            { key = 'front', role = 'entrance', model = DOOR_MODEL, pos = { x = 3.0, y = 0.0, z = 0.0 }, heading = 90 },
            { key = 'bedroom', role = 'interior', model = DOOR_MODEL, pos = { x = -1.0, y = 0.5, z = 0.0 }, heading = 0 },
        },
        sign  = { pos = { x = 3.2, y = 0.8, z = 1.6 }, heading = 90 },
    },
}

RegisterTestModule({
    order    = 62,
    category = 'Properties',

    setup = function(source, ctx)
        -- A run that crashed never reached its teardown; clear what it left first.
        pcall(exports.whip_core.__TestPropertySweep, exports.whip_core)
        local player = exports.whip_core:GetPlayer(source)
        ctx.charId = player.charId
        local pos = GetEntityCoords(GetPlayerPed(source))

        -- Two placements of the same unit, clear of the other door modules' spots. The second
        -- stands where an admin's door already is, to be adopted.
        ctx.placeA = { x = pos.x + 20, y = pos.y + 20, z = pos.z, yaw = 30.0 }
        ctx.placeB = { x = pos.x + 20, y = pos.y + 35, z = pos.z, yaw = 0.0 }

        -- Somebody else to hand a key to: any other LIVE character in the database (a deleted one is
        -- refused a key since audit 6, WLD-19).
        ctx.otherCharId = MySQL.scalar.await(
            'SELECT `charId` FROM `characters` WHERE `charId` <> ? AND `deleted` IS NULL ORDER BY `charId` LIMIT 1',
            { ctx.charId })

        -- The admin's door at B's front-door spot, with a requirement of its own.
        local bx, by, bz = toWorld(ctx.placeB, 3.0, 0.0, 0.0)
        local old = exports.whip_core:GetDoorByPosition(bx, by, bz, 0.6)
        if old and type(old.label) == 'string' and old.label:sub(1, 5) == '_test' then
            exports.whip_core:DeleteDoor(old.doorId)
        end
        local admin, aerr = exports.whip_core:CreateDoor({
            label = '_test_admin_front', model = DOOR_MODEL, x = bx, y = by, z = bz, heading = 90,
        })
        if not admin then error('could not create the admin door: ' .. tostring(aerr)) end
        exports.whip_core:UpdateDoor(admin.doorId, { requirements = { ace = 'whip.devtools' } })
        ctx.adminDoorId = admin.doorId

        local fx, err = exports.whip_core:__TestPropertyFixture({
            templateKey = '_test:properties:' .. tostring(os.time()),
            units = { a = UNIT },
            properties = {
                { unitKey = 'a', name = '_test Property A', building = '_test', place = ctx.placeA },
                { unitKey = 'a', name = '_test Property B', building = '_test', place = ctx.placeB },
            },
        })
        if not fx then error('fixture: ' .. tostring(err) .. ' (Config.EnableTestSeams must be true)') end
        ctx.templateId = fx.templateId
        ctx.idA, ctx.idB = fx.propertyIds[1], fx.propertyIds[2]
    end,

    teardown = function(ctx)
        for _, id in ipairs({ ctx.stashA or false, ctx.stashB or false }) do
            if id then pcall(exports.whip_core.DeleteContainer, exports.whip_core, id) end
        end
        if ctx.templateId then pcall(exports.whip_core.__TestPropertyTeardown, exports.whip_core, ctx.templateId) end
        if ctx.adminDoorId then pcall(exports.whip_core.DeleteDoor, exports.whip_core, ctx.adminDoorId) end
    end,

    tests = {
        {
            name = 'A property makes its front door where its interior puts it, and leaves the bedroom door alone',
            fn = function(source, ctx)
                local door, doorId = doorOf(ctx.idA, 'front')
                assertNotNil(door, 'the front door exists')
                local x, y, z = toWorld(ctx.placeA, 3.0, 0.0, 0.0)
                assertTrue(near(door.x, x) and near(door.y, y) and near(door.z, z), 'at the unit\'s spot, turned with the placement')
                local mb = door.metadata and door.metadata.managedBy
                assertTrue(mb ~= nil and mb.system == 'property' and tostring(mb.id) == tostring(ctx.idA),
                    'managed by the property')
                assertTrue(mb.created == true, 'made for it')

                local p = exports.whip_core:GetProperty(ctx.idA)
                assertNil(p.doorIds.bedroom, 'the interior door is not managed')
                assertTrue(doorId ~= nil, 'door id recorded')
            end,
        },
        {
            name = 'An unowned property is locked to everyone, not open to everyone',
            fn = function(source, ctx)
                local door = doorOf(ctx.idA, 'front')
                local ids = charIdsOn(door)
                assertNotNil(ids, 'the door has a charIds list')
                assertEqual(#ids, 0, 'and nobody is on it')
                assertFalse(exports.whip_core:CanUseDoor(source, door.doorId), 'the tester cannot open it')
            end,
        },
        {
            name = 'The space answers "which property is this", and nothing outside it does',
            fn = function(source, ctx)
                local x, y, z = toWorld(ctx.placeA, 1.0, 1.0, 1.0)
                local at = exports.whip_core:GetPropertyAt(x, y, z)
                assertTrue(at ~= nil and at.id == ctx.idA, 'a point in the room')
                local ox, oy, oz = toWorld(ctx.placeA, 5.0, 0.0, 1.0)
                assertNil(exports.whip_core:GetPropertyAt(ox, oy, oz), 'a point 2 m past the wall')
            end,
        },
        {
            name = 'An owner is written onto the door, and only the owner',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:SetPropertyOwner(ctx.idA, { charId = ctx.charId }), 'owner set')
                local door = doorOf(ctx.idA, 'front')
                local ids = charIdsOn(door)
                assertTrue(ids and #ids == 1 and ids[1] == ctx.charId, 'the door lists the owner')
                assertTrue(exports.whip_core:CanUseDoor(source, door.doorId), 'who can now open it')
                assertTrue(door.locked, 'and it was locked as it changed hands')
                assertTrue(exports.whip_core:HasPropertyAccess(ctx.idA, { charId = ctx.charId }), 'access')
                local mine = exports.whip_core:GetCharacterProperties(ctx.charId)
                local found = false
                for _, id in ipairs(mine.owned) do if id == ctx.idA then found = true end end
                assertTrue(found, 'listed as owned')
            end,
        },
        {
            name = 'A key adds its holder to the door, and taking it back removes them',
            fn = function(source, ctx)
                if not ctx.otherCharId then
                    assertTrue(true, 'no second character in the database — skipped')
                    return
                end
                assertTrue(exports.whip_core:GivePropertyKey(ctx.idA, { charId = ctx.otherCharId }), 'key given')
                local ids = charIdsOn(doorOf(ctx.idA, 'front'))
                assertTrue(ids and #ids == 2 and ids[1] == ctx.charId and ids[2] == ctx.otherCharId,
                    'owner first, then the keyholder')
                local ok, why = exports.whip_core:GivePropertyKey(ctx.idA, { charId = ctx.charId })
                assertFalse(ok, 'the owner cannot be given a key')
                assertEqual(why, 'They already own this property', 'and is told why')

                assertTrue(exports.whip_core:RemovePropertyKey(ctx.idA, { charId = ctx.otherCharId }), 'key taken back')
                ids = charIdsOn(doorOf(ctx.idA, 'front'))
                assertTrue(ids and #ids == 1 and ids[1] == ctx.charId, 'only the owner again')
            end,
        },
        {
            -- A HOUSE STASH OPENS FOR THE HOUSE (Josh, 26 Sep 2026): `property` is the owner and
            -- keyholders; the tester owns A (the test above) and has no key to B.
            name = 'A container with requirements.property opens for the owner, not for someone without access',
            fn = function(source, ctx)
                local pos = GetEntityCoords(GetPlayerPed(source))
                local function stash(propertyId, label)
                    local c, err = exports.whip_core:CreateContainer({
                        name = label, slots = 5, maxWeight = 10.0, x = pos.x + 2, y = pos.y, z = pos.z,
                        requirements = { property = propertyId },
                    })
                    assertOk(c, err, label .. ' made')
                    return c.containerId
                end
                ctx.stashA = stash(ctx.idA, '_test_stash_A')
                ctx.stashB = stash(ctx.idB, '_test_stash_B')

                -- Measured, closed, then judged: an open stash left behind blocks the next module's.
                local okA, whyA = exports.whip_core:OpenStore(source, { kind = 'container', id = ctx.stashA }, { skipDistance = true })
                if okA then
                    ClientCloseContainer(source, ctx.stashA, 3000)
                    waitFor(function() return not exports.whip_core:__TestIsViewer(source, 'container:' .. ctx.stashA) end, 3000)
                end
                local okB, whyB = exports.whip_core:OpenStore(source, { kind = 'container', id = ctx.stashB }, { skipDistance = true })
                if okB then
                    ClientCloseContainer(source, ctx.stashB, 3000)
                    waitFor(function() return not exports.whip_core:__TestIsViewer(source, 'container:' .. ctx.stashB) end, 3000)
                end

                assertOk(okA, whyA, 'the owner of A opens A\'s stash')
                assertFalse(okB, 'nobody with access to B opens B\'s stash — not the tester')
                assertTrue(type(whyB) == 'string' and whyB:find('property', 1, true) ~= nil,
                    'and is told it is the property (got: ' .. tostring(whyB) .. ')')
            end,
        },
        {
            name = 'Furniture inside the space saves, in the interior\'s own coordinates; outside is refused',
            fn = function(source, ctx)
                local cat = exports.whip_core:__GetPropCatalog()
                local model = cat and cat.props and cat.props[1] and cat.props[1].model
                if not model then
                    assertTrue(true, 'the prop catalogue is empty — skipped')
                    return
                end

                -- Inside: local (1, -1, 0.1), turned 45 degrees within the room. A save names the version
                -- of the room it was made over (P-011, 3 Oct 2026).
                local x, y, z = toWorld(ctx.placeA, 1.0, -1.0, 0.1)
                local v0 = exports.whip_core:__GetPropertyObjectVersion(ctx.idA)

                -- THE FURNISHER'S LOCK FIRST, as opening the furnisher takes it: a save is taken only from
                -- the one furnishing the property (audit 8, WLD-2). Let go at the end, as closing it does.
                local answered, res = ClientCallback(source, 'whip_core:property:furnishLock', 5000, ctx.idA)
                local lock = answered and res and res[1]
                assertTrue(type(lock) == 'table' and lock.ok == true,
                    'the furnisher\'s lock is taken (' .. tostring(type(lock) == 'table' and lock.why or lock) .. ')')

                assertTrue(ClientExecWait(source, 'whip_core:server:propertyObjectsSave', 5000, ctx.idA, {
                    { model = model, x = x, y = y, z = z, rx = 0, ry = 0, rz = (ctx.placeA.yaw + 45.0) % 360 },
                }, v0), 'the server answered the save')
                assertEqual(exports.whip_core:__GetPropertyObjectCount(ctx.idA), 1, 'one piece saved')
                assertEqual(exports.whip_core:__GetPropertyObjectVersion(ctx.idA), v0 + 1, 'and the room\'s version moved on')
                assertDbScalar('SELECT ROUND(`lx`, 2) FROM `property_objects` WHERE `propertyId` = ?', { ctx.idA }, 1.0,
                    'stored relative to the interior (lx)')
                assertDbScalar('SELECT ROUND(`rz`) FROM `property_objects` WHERE `propertyId` = ?', { ctx.idA }, 45,
                    'and its turn relative to the interior (rz)')

                -- Outside: 3 m past the end wall. Refused whole, so the room keeps its one piece.
                Wait(4100)   -- the save is rate limited to one per 4 s
                local ox, oy, oz = toWorld(ctx.placeA, 6.0, 0.0, 0.1)
                ClientExecWait(source, 'whip_core:server:propertyObjectsSave', 5000, ctx.idA, {
                    { model = model, x = x, y = y, z = z, rx = 0, ry = 0, rz = 0 },
                    { model = model, x = ox, y = oy, z = oz, rx = 0, ry = 0, rz = 0 },
                }, exports.whip_core:__GetPropertyObjectVersion(ctx.idA))
                assertEqual(exports.whip_core:__GetPropertyObjectCount(ctx.idA), 1, 'the save with one outside was refused')

                -- P-011: an editor opened on an older (or failed, empty) copy of the room cannot save
                -- over it. Its version is behind, so the whole save is refused and the room keeps its piece.
                Wait(4100)
                ClientExecWait(source, 'whip_core:server:propertyObjectsSave', 5000, ctx.idA, {}, v0)
                assertEqual(exports.whip_core:__GetPropertyObjectCount(ctx.idA), 1,
                    'an empty save over an old version of the room is refused — the furniture stays')
                ClientExecWait(source, 'whip_core:server:propertyFurnishClosed', 3000, ctx.idA)   -- the lock goes
            end,
        },
        {
            name = 'A new owner starts with no guests',
            fn = function(source, ctx)
                if not ctx.otherCharId then
                    assertTrue(true, 'no second character in the database — skipped')
                    return
                end
                exports.whip_core:GivePropertyKey(ctx.idA, { charId = ctx.otherCharId })
                assertTrue(exports.whip_core:SetPropertyOwner(ctx.idA, nil), 'made unowned')
                assertEqual(#exports.whip_core:GetProperty(ctx.idA).keys, 0, 'every key went with the owner')
                local ids = charIdsOn(doorOf(ctx.idA, 'front'))
                assertEqual(#ids, 0, 'locked to everyone again')
                assertDbRowCount('SELECT `charId` FROM `property_keys` WHERE `propertyId` = ?', { ctx.idA }, 0,
                    'and no key rows are left')
            end,
        },
        {
            name = 'Nobody but the property may change who its door opens for',
            fn = function(source, ctx)
                local door = doorOf(ctx.idA, 'front')
                local ok = exports.whip_core:UpdateDoor(door.doorId, { requirements = {} })
                assertFalse(ok, 'an ordinary UpdateDoor is refused')
                assertEqual(#charIdsOn(exports.whip_core:GetDoor(door.doorId)), 0, 'the list is untouched')
            end,
        },
        {
            name = 'A door already standing where the unit wants one is adopted, not duplicated',
            fn = function(source, ctx)
                local door = doorOf(ctx.idB, 'front')
                assertNotNil(door, 'property B has a front door')
                assertEqual(door.doorId, ctx.adminDoorId, 'the admin\'s door, not a second one')
                local mb = door.metadata and door.metadata.managedBy
                assertTrue(mb and mb.adopted == true, 'marked adopted')
                assertEqual(#charIdsOn(door), 0, 'its old requirement replaced by the property\'s list')
            end,
        },
        {
            -- Josh, 13 Oct 2026: an MLO update changed its doors and setting them up again was
            -- glitchy. The old door went AFTER the new one was made, so where the model changed the
            -- new door was refused by the old one standing there, then the old one was deleted:
            -- no door at all until a restart.
            name = 'A door of another model where the old one stood replaces it at once',
            fn = function(source, ctx)
                local _, oldId = doorOf(ctx.idA, 'front')
                assertNotNil(oldId, 'A has its front door')
                local other = GetHashKey('v_ilev_ph_door01')
                local doors = {
                    { key = 'front', role = 'entrance', model = other, pos = { x = 3.0, y = 0.0, z = 0.0 }, heading = 90 },
                }
                assertTrue(exports.whip_core:__TestPropertyUpdate(ctx.idA, { overrides = { doors = doors } }), 'doors set again')
                local door, newId = doorOf(ctx.idA, 'front')
                assertNotNil(door, 'a front door now, not none')
                assertEqual(door.model, other, 'of the new model')   -- GetHashKey is signed, as doors are stored
                assertNotEqual(newId, oldId, 'a new door')
                assertNil(exports.whip_core:GetDoor(oldId), 'the old one gone')
                local p = exports.whip_core:GetProperty(ctx.idA)
                assertTrue(p.status ~= 'attention', 'nothing for the admin to fix: ' .. tostring(p.statusReason))

                -- And back to the unit's own door, the same way.
                assertTrue(exports.whip_core:__TestPropertyUpdate(ctx.idA, { overrides = false }), 'own doors again')
                door = doorOf(ctx.idA, 'front')
                assertTrue(door ~= nil and door.model == DOOR_MODEL, 'the unit\'s model back')
                assertNil(exports.whip_core:GetDoor(newId), 'and the other one gone')
            end,
        },
        {
            name = 'Moving a placement moves its door with it',
            fn = function(source, ctx)
                local _, oldId = doorOf(ctx.idA, 'front')
                local moved = { x = ctx.placeA.x + 4.0, y = ctx.placeA.y, z = ctx.placeA.z, yaw = 30.0 }
                assertTrue(exports.whip_core:__TestPropertyUpdate(ctx.idA, { place = moved }), 're-bound')
                local door, newId = doorOf(ctx.idA, 'front')
                local x, y = toWorld(moved, 3.0, 0.0, 0.0)
                assertTrue(door ~= nil and near(door.x, x) and near(door.y, y), 'the door is at the new spot')
                assertNotEqual(newId, oldId, 'a new door')
                assertNil(exports.whip_core:GetDoor(oldId), 'and the one it made at the old spot is gone')
                ctx.placeA = moved
            end,
        },
        {
            name = 'Deleting a property gives its doors back: a made door goes, an adopted one is restored',
            fn = function(source, ctx)
                local _, madeId = doorOf(ctx.idA, 'front')
                assertTrue(exports.whip_core:__TestPropertyDelete(ctx.idA), 'A deleted')
                assertNil(exports.whip_core:GetProperty(ctx.idA), 'A is gone')
                assertNil(exports.whip_core:GetDoor(madeId), 'with the door it made')

                assertTrue(exports.whip_core:__TestPropertyDelete(ctx.idB), 'B deleted')
                local admin = exports.whip_core:GetDoor(ctx.adminDoorId)
                assertNotNil(admin, 'the admin\'s door survives')
                assertNil(admin.metadata and admin.metadata.managedBy, 'nobody manages it now')
                assertEqual(admin.label, '_test_admin_front', 'its name back')
                assertEqual(admin.requirements and admin.requirements.ace, 'whip.devtools', 'its requirement back')
            end,
        },
    },
})
