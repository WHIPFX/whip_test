-- ============================================
-- Managed doors — a door that belongs to the system that sets its access
-- ============================================
--
-- WHY THIS MODULE EXISTS
--
-- A property's front door opens for the property's owner and keyholders, and the property writes
-- that list. If an admin could change it in the Door Manager, the property would write its own back
-- at the next reconcile and the change would vanish without a word; if two properties could claim
-- one door, each would overwrite the other at every boot. server/doors.lua's "Managed doors" rules
-- stop both, and adopting a door an admin had already set up must give it back exactly as it was.
--
-- Everything here goes through the exports, so this resource is the manager, and the door system
-- names it 'resource:whip_test' whatever it passes in. They are the plumbing a satellite's EnsureDoors
-- and EnsureDoor run on (__AdoptOrCreateDoor, __ReleaseManagedDoor: whip_core's own since 14 Nov 2026,
-- when AdoptOrCreateDoor and the managed ReleaseDoor stopped being public), called directly so each
-- rule can be asked on its own: any manager, how a door was taken, the door in the way.
--
-- Also here: a door model written unsigned, the way the map packs list them, is stored signed,
-- because the game only ever answers signed.

local DOOR_MODEL  = GetHashKey('prop_door_01')
local OTHER_MODEL = GetHashKey('v_ilev_gc_door01')
local UNMET_ACE   = '_test_nonexistent_ace_permission'
local ME          = 'resource:' .. GetCurrentResourceName()

local MANAGER_1 = { id = 1, key = 'entrance', label = '_test manager 1' }
local MANAGER_2 = { id = 2, key = 'entrance', label = '_test manager 2' }

--- Remove every door this module can have left behind: its own managed doors, and any _test_mdoor.
local function sweep()
    for _, d in ipairs(exports.whip_core:GetDoors() or {}) do
        local mb = d.metadata and d.metadata.managedBy
        if mb and mb.system == ME then
            exports.whip_core:__ReleaseManagedDoor(d.doorId, { id = mb.id })
        end
    end
    for _, d in ipairs(exports.whip_core:GetDoors() or {}) do
        if type(d.label) == 'string' and d.label:sub(1, 11) == '_test_mdoor' then
            exports.whip_core:DeleteDoor(d.doorId)
        end
    end
end

local function managerOf(doorId)
    local d = exports.whip_core:GetDoor(doorId)
    return d and d.metadata and d.metadata.managedBy or nil
end

RegisterTestModule({
    order    = 61,
    category = 'Managed Doors',

    setup = function(source, ctx)
        sweep()
        local pos = GetEntityCoords(GetPlayerPed(source))
        local player = exports.whip_core:GetPlayer(source)
        ctx.charId = player.charId
        -- Clear of module 15's spots (+2/+4 on x, +8/+12 on y).
        ctx.spotA = { x = pos.x - 6, y = pos.y - 6, z = pos.z }
        ctx.spotB = { x = pos.x - 6, y = pos.y - 9, z = pos.z }
        ctx.spotC = { x = pos.x - 6, y = pos.y - 12, z = pos.z }
        ctx.spotD = { x = pos.x - 6, y = pos.y - 15, z = pos.z }
    end,
    teardown = function(ctx)
        sweep()
    end,

    tests = {
        {
            name = 'A door model written unsigned is stored signed',
            fn = function(source, ctx)
                -- 2455748208 is whippy_mega_apartments' unit door as its doors.lua lists it;
                -- GetEntityModel answers -1839219088 for it.
                local door, err = exports.whip_core:CreateDoor({
                    label = '_test_mdoor_signed', model = 2455748208,
                    x = ctx.spotD.x, y = ctx.spotD.y, z = ctx.spotD.z, heading = 0,
                })
                assertOk(door, err, 'created')
                assertEqual(door.model, -1839219088, 'signed in memory')
                assertDbScalar('SELECT `model` FROM `doors` WHERE `doorId` = ?', { door.doorId },
                    -1839219088, 'signed on disk')
                assertTrue(exports.whip_core:DeleteDoor(door.doorId), 'cleaned up')
            end,
        },
        {
            name = '__AdoptOrCreateDoor makes a door where there is none, marked as made for its manager',
            fn = function(source, ctx)
                local door, how = exports.whip_core:__AdoptOrCreateDoor({
                    label = '_test_mdoor_made', model = DOOR_MODEL,
                    x = ctx.spotA.x, y = ctx.spotA.y, z = ctx.spotA.z, heading = 0,
                }, MANAGER_1)
                assertOk(door, how, 'made')
                assertEqual(how, 'created', 'how')
                ctx.madeId = door.doorId

                local mb = managerOf(ctx.madeId)
                assertNotNil(mb, 'managed')
                assertEqual(mb.system, ME, 'the manager is this resource, whatever it passed')
                assertEqual(tostring(mb.id), '1', 'manager id')
                assertTrue(mb.created == true, 'marked created')
            end,
        },
        {
            name = 'Asking again for the same door changes nothing',
            fn = function(source, ctx)
                local door, how = exports.whip_core:__AdoptOrCreateDoor({
                    label = '_test_mdoor_made', model = DOOR_MODEL,
                    x = ctx.spotA.x, y = ctx.spotA.y + 0.1, z = ctx.spotA.z, heading = 0,
                }, MANAGER_1)
                assertOk(door, how, 'answered')
                assertEqual(how, 'already', 'how')
                assertEqual(door.doorId, ctx.madeId, 'the same door')
            end,
        },
        {
            name = 'Only its manager may change a managed door\'s access, or delete it',
            fn = function(source, ctx)
                local ok, why = exports.whip_core:UpdateDoor(ctx.madeId, { requirements = { ace = UNMET_ACE } })
                assertFalse(ok, 'an unmanaged caller is refused the requirements')
                assertTrue(type(why) == 'string' and why:find('belongs to', 1, true) ~= nil, 'and told whose it is')

                assertFalse(exports.whip_core:UpdateDoor(ctx.madeId, { autolock = true }), 'and the autolock')
                assertFalse(exports.whip_core:DeleteDoor(ctx.madeId), 'and the delete')
                assertNotNil(exports.whip_core:GetDoor(ctx.madeId), 'the door is still there')

                assertTrue(exports.whip_core:UpdateDoor(ctx.madeId, { label = '_test_mdoor_renamed' }),
                    'its name is anybody\'s')

                assertTrue(exports.whip_core:UpdateDoor(ctx.madeId, { requirements = { charIds = { ctx.charId } } },
                    MANAGER_1), 'its manager sets the access')
                local d = exports.whip_core:GetDoor(ctx.madeId)
                assertEqual(d.requirements.charIds[1], ctx.charId, 'access written')
            end,
        },
        {
            name = 'A second manager is refused a door the first one holds',
            fn = function(source, ctx)
                local door, why, conflictId = exports.whip_core:__AdoptOrCreateDoor({
                    model = DOOR_MODEL, x = ctx.spotA.x, y = ctx.spotA.y, z = ctx.spotA.z,
                }, MANAGER_2)
                assertFalse(door, 'refused')
                assertTrue(type(why) == 'string' and why:find('already belongs', 1, true) ~= nil, 'says why')
                assertEqual(conflictId, ctx.madeId, 'and which door is in the way')
                assertEqual(tostring(managerOf(ctx.madeId).id), '1', 'the door is still the first manager\'s')
            end,
        },
        {
            name = 'An update cannot hand a door to a manager',
            fn = function(source, ctx)
                local door, err = exports.whip_core:CreateDoor({
                    label = '_test_mdoor_plain', model = DOOR_MODEL,
                    x = ctx.spotC.x, y = ctx.spotC.y, z = ctx.spotC.z, heading = 0,
                })
                assertOk(door, err, 'plain door')
                ctx.plainId = door.doorId
                local ok = exports.whip_core:UpdateDoor(ctx.plainId, {
                    metadata = { managedBy = { system = 'property', id = 9 } },
                })
                assertFalse(ok, 'refused')
                assertNil(managerOf(ctx.plainId), 'still nobody\'s')
            end,
        },
        {
            name = 'A different model at the spot is a conflict, not an adoption',
            fn = function(source, ctx)
                local door, why, conflictId = exports.whip_core:__AdoptOrCreateDoor({
                    model = OTHER_MODEL, x = ctx.spotC.x, y = ctx.spotC.y, z = ctx.spotC.z,
                }, MANAGER_1)
                assertFalse(door, 'refused')
                assertTrue(type(why) == 'string' and why:find('different model', 1, true) ~= nil, 'says why')
                assertEqual(conflictId, ctx.plainId, 'names the door')
                assertTrue(exports.whip_core:DeleteDoor(ctx.plainId), 'cleaned up')
                ctx.plainId = nil
            end,
        },
        {
            name = 'An adopted door is given back exactly as it was',
            fn = function(source, ctx)
                local before, err = exports.whip_core:CreateDoor({
                    label = '_test_mdoor_admin', model = DOOR_MODEL,
                    x = ctx.spotB.x, y = ctx.spotB.y, z = ctx.spotB.z, heading = 0,
                })
                assertOk(before, err, 'an admin\'s door')
                ctx.adoptId = before.doorId
                assertTrue(exports.whip_core:UpdateDoor(ctx.adoptId, {
                    requirements = { ace = UNMET_ACE }, autolock = true, autolockDelay = 7,
                }), 'set up by the admin')

                local door, how = exports.whip_core:__AdoptOrCreateDoor({
                    label = '_test_mdoor_adopted', folder = '_test_properties', model = DOOR_MODEL,
                    x = ctx.spotB.x, y = ctx.spotB.y, z = ctx.spotB.z,
                    requirements = { charIds = { ctx.charId } },
                }, MANAGER_1)
                assertOk(door, how, 'adopted')
                assertEqual(how, 'adopted', 'how')
                assertEqual(door.doorId, ctx.adoptId, 'the same door, not a second one')
                local d = exports.whip_core:GetDoor(ctx.adoptId)
                assertEqual(d.label, '_test_mdoor_adopted', 'renamed')
                assertEqual(d.folder, '_test_properties', 'filed')
                assertEqual(d.requirements.charIds[1], ctx.charId, 'access is the manager\'s')

                assertTrue(exports.whip_core:__ReleaseManagedDoor(ctx.adoptId, MANAGER_1), 'released')
                d = exports.whip_core:GetDoor(ctx.adoptId)
                assertNotNil(d, 'an adopted door survives its release')
                assertNil(d.metadata and d.metadata.managedBy, 'nobody\'s again')
                assertEqual(d.label, '_test_mdoor_admin', 'its name back')
                assertNil(d.folder, 'no folder, as before')
                assertEqual(d.requirements and d.requirements.ace, UNMET_ACE, 'its requirements back')
                assertTrue(d.autolock == true and d.autolockDelay == 7, 'its autolock back')
                assertDbScalar('SELECT `label` FROM `doors` WHERE `doorId` = ?', { ctx.adoptId },
                    '_test_mdoor_admin', 'and on disk')
            end,
        },
        {
            name = 'A door made for its manager is deleted when released, and only by that manager',
            fn = function(source, ctx)
                local list = exports.whip_core:GetManagedDoors(1)
                assertEqual(#list, 1, 'one door held by manager 1')
                assertEqual(list[1].doorId, ctx.madeId, 'the one it made')

                assertFalse(exports.whip_core:__ReleaseManagedDoor(ctx.madeId, MANAGER_2), 'not by another manager')
                assertTrue(exports.whip_core:__ReleaseManagedDoor(ctx.madeId, MANAGER_1), 'released')
                assertNil(exports.whip_core:GetDoor(ctx.madeId), 'gone from memory')
                assertDbRowCount('SELECT `doorId` FROM `doors` WHERE `doorId` = ?', { ctx.madeId }, 0, 'and disk')
            end,
        },
    },
})
