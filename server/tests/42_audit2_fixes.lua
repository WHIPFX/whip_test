-- ============================================
-- Audit 2 (2026-09-23) — the export-level fixes
--
-- WHY THIS MODULE EXISTS
--
-- The second audit's fixes were made without a test run behind them. The ones that can be proved
-- through exports alone are proved here; the ones that need a second player, a real disconnect or
-- a car in the world are in-game checks and are listed in the audit's plan file instead.
--
--   * UpdateShop could not CLEAR a link. `false` now means "clear it" (nil still means "not
--     mentioned"), and the row has to say NULL, not just the cache. It also writes the ROW before
--     memory, which only a failed write can prove (__TestFailNextQuery).
--   * DeleteContainer used to delete a shop's stock container out from under it.
--   * A catalog could carry fractional prices or the old `{ price = n }` shape. Both are stored as
--     plain whole numbers now.
--   * SetVehicleData (one key, or a table of several: SetVehicleDataMany until 14 Nov 2026) and
--     ClearAllVehicleData reported success when the row write failed. They now report the failure and put the block back.
-- ============================================

local KEY   = '_test_audit2'
local ITEM  = '_test_audit2_item'
local ITEM2 = '_test_audit2_item2'
local PLATE = 'TAU2'

local function shopRow(shopId)
    return DbQuery('SELECT `containerId`, `key`, `name`, `catalog` FROM `shops` WHERE `shopId` = ?', { shopId })[1]
end

local function vehDataOnDisk(vehicleId)
    local rows = DbQuery('SELECT `vehData` FROM `vehicles` WHERE `vehicleId` = ?', { vehicleId })
    local raw = rows[1] and rows[1].vehData
    if type(raw) == 'string' then return json.decode(raw) or {} end
    if type(raw) == 'table' then return raw end
    return {}
end

--- Through whip_core, so the cache entry goes with the row. A raw `DELETE ... LIKE` left the shop in
--- Shops.cache, where it kept its container linked and made DeleteContainer refuse the shelf.
--- (GetShop({ key = ... }) since 14 Nov 2026; GetShopBy('key', ...) from 09-24, when GetShopByKey was removed.)
local function removeShopByKey(key)
    local def = exports.whip_core:GetShop({ key = key })
    if def and def.shopId then pcall(exports.whip_core.DeleteShop, exports.whip_core, def.shopId) end
end

local function removeFixtureVehicle()
    -- A vehicle reference (VEH-1): DeleteVehicle takes `{ plate = ... }` itself, no lookup first.
    pcall(exports.whip_core.DeleteVehicle, exports.whip_core, { plate = PLATE })
    DbQuery('DELETE FROM `vehicles` WHERE `plate` = ?', { PLATE })
end

RegisterTestModule({
    order    = 42,
    category = 'Audit 2 Fixes',

    -- FILLS ctx AS IT GOES. The container used to be created before a skip that lost ctx, so a
    -- failed shop create leaked the container for good.
    setup = function(source, ctx)
        local p = exports.whip_core:GetPlayer(source)
        if not p then skip('no player loaded') end

        -- Leftovers from an interrupted run would collide on the keys and the plate.
        removeShopByKey(KEY .. '_stocked')
        removeShopByKey(KEY .. '_catalog')
        removeFixtureVehicle()

        local pos = GetEntityCoords(GetPlayerPed(source))
        ctx.pos = pos

        local c = exports.whip_core:CreateContainer({
            name = '_test_audit2_shelf', type = 'stash', slots = 5, maxWeight = 50.0,
            x = pos.x + 3, y = pos.y, z = pos.z, heading = 0, prop = 'prop_cs_cardbox_01',
        })
        if not c or not c.containerId then skip('could not create the shelf container') end
        ctx.containerId = c.containerId

        local shop = exports.whip_core:CreateShop({
            key = KEY .. '_stocked', name = 'Audit2 Stocked', mode = 'stocked',
            containerId = c.containerId, x = pos.x + 4, y = pos.y, z = pos.z,
        })
        if not shop or not shop.shopId then skip('could not create the stocked shop') end
        ctx.shopId = shop.shopId

        local vehicleId = exports.whip_core:CreateOwnedVehicle(source, {
            model = 'asea', plate = PLATE, state = 'garaged',
        })
        ctx.vehicleId = (vehicleId and vehicleId ~= false) and vehicleId or nil
    end,

    teardown = function(ctx, source)
        pcall(exports.whip_core.__TestSetDbFaultMode, exports.whip_core, nil)
        pcall(exports.whip_core.__TestFailNextQuery, exports.whip_core, nil)
        if ctx.shopId then pcall(exports.whip_core.DeleteShop, exports.whip_core, ctx.shopId) end
        if ctx.catalogShopId then pcall(exports.whip_core.DeleteShop, exports.whip_core, ctx.catalogShopId) end
        removeShopByKey(KEY .. '_stocked')
        removeShopByKey(KEY .. '_catalog')
        if ctx.containerId then
            local ok, err = exports.whip_core:DeleteContainer(ctx.containerId)
            if not ok then
                print(('[whip_test] 42_audit2_fixes: shelf container %d not deleted: %s')
                    :format(ctx.containerId, tostring(err)))
            end
        end
        if ctx.vehicleId then
            pcall(exports.whip_core.ClearAllVehicleData, exports.whip_core, ctx.vehicleId)
            pcall(exports.whip_core.DeleteVehicle, exports.whip_core, ctx.vehicleId)
        end
        removeFixtureVehicle()
    end,

    tests = {
        {
            name = 'DeleteContainer refuses a container a shop sells from',
            fn = function(source, ctx)
                -- Linked in setup; make sure, in case an earlier test here unlinked it.
                assertTrue(exports.whip_core:UpdateShop(ctx.shopId, { containerId = ctx.containerId }), 'linked')
                local ok, err = exports.whip_core:DeleteContainer(ctx.containerId)
                assertFalse(ok, 'the delete is refused')
                assertTrue(tostring(err):find('uses this container for its stock', 1, true) ~= nil,
                    ('with the reason (got "%s")'):format(tostring(err)))

                -- The CONTAINER is what the refusal protects. DeleteContainer never touches the
                -- shop, so asserting the shop's link survived could not have failed; the container
                -- itself, in memory and on disk, can.
                assertNotNil(exports.whip_core:GetContainer(ctx.containerId), 'the container still exists')
                assertDbRowCount('SELECT 1 FROM `containers` WHERE `containerId` = ?', { ctx.containerId }, 1,
                    'and so does its row')
            end,
        },
        {
            name = 'UpdateShop with false clears the stock container, in memory and on disk',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:UpdateShop(ctx.shopId, { containerId = ctx.containerId }), 'linked first')
                assertTrue(exports.whip_core:UpdateShop(ctx.shopId, { containerId = false }), 'the clear is accepted')
                assertNil(exports.whip_core:GetShop(ctx.shopId).containerId, 'the cache has no container')
                local row = shopRow(ctx.shopId)
                assertNotNil(row, 'the row exists')
                assertNil(row.containerId, 'and the row says NULL')
            end,
        },
        {
            name = 'UpdateShop with nil leaves a field alone, and false clears the key',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:UpdateShop(ctx.shopId, { name = 'Audit2 Renamed' }), 'rename accepted')
                assertEqual(exports.whip_core:GetShop(ctx.shopId).key, KEY .. '_stocked', 'the key was not mentioned, so it stays')
                assertTrue(exports.whip_core:UpdateShop(ctx.shopId, { key = false }), 'the key clear is accepted')
                assertNil(exports.whip_core:GetShop(ctx.shopId).key, 'the cache has no key')
                assertNil(shopRow(ctx.shopId).key, 'and the row says NULL')
                -- Put it back so a rerun's leftover sweep can still find it by key.
                assertTrue(exports.whip_core:UpdateShop(ctx.shopId, { key = KEY .. '_stocked' }), 'key restored')
            end,
        },
        {
            name = 'An UpdateShop whose ROW write fails changes nothing in memory',
            fn = function(source, ctx)
                -- Row first, memory second. The old version mutated the cache, broadcast the change
                -- to every client and threw the write result away — a failed write left the server
                -- believing in a shop the database never heard of.
                assertTrue(exports.whip_core:UpdateShop(ctx.shopId, { name = 'Audit2 Before' }), 'baseline name')

                assertTrue(exports.whip_core:__TestFailNextQuery('UPDATE `shops`'), 'row fault armed')
                local ok, err = exports.whip_core:UpdateShop(ctx.shopId, { name = 'Audit2 After' })
                assertNil(exports.whip_core:__TestRawFaultArmed(), 'the fault fired on that write')

                assertFalse(ok, 'the update reports failure')
                assertEqual(err, DB_ERROR, 'as a database error')
                assertEqual(exports.whip_core:GetShop(ctx.shopId).name, 'Audit2 Before', 'memory kept the old name')
                assertEqual(shopRow(ctx.shopId).name, 'Audit2 Before', 'which is what the row says')
            end,
        },
        {
            name = 'A catalog is stored as whole-number prices, whatever shape it arrives in',
            fn = function(source, ctx)
                local shop = exports.whip_core:CreateShop({
                    key = KEY .. '_catalog', name = 'Audit2 Catalog', mode = 'npc',
                    x = ctx.pos.x + 5, y = ctx.pos.y, z = ctx.pos.z,
                    catalog = { [ITEM] = 9.99, [ITEM2] = { price = 5 } },
                })
                assertOk(shop and shop.shopId, 'CreateShop returned nothing', 'the shop was created')
                ctx.catalogShopId = shop.shopId

                local cat = exports.whip_core:GetShop(shop.shopId).catalog
                assertEqual(cat[ITEM], 9, 'a fractional price is floored')
                assertEqual(cat[ITEM2], 5, 'the { price = n } shape becomes a plain number')

                local onDisk = json.decode(shopRow(shop.shopId).catalog or '{}') or {}
                assertEqual(tonumber(onDisk[ITEM]), 9, 'and the row holds the whole number')
                assertEqual(tonumber(onDisk[ITEM2]), 5, 'for both entries')
            end,
        },
        {
            name = 'A vehicle-data write that fails is reported and undone',
            fn = function(source, ctx)
                if not ctx.vehicleId then skip('no fixture vehicle') end
                assertTrue(exports.whip_core:__TestSetDbFaultMode('vehicle_data'), 'fault armed')

                local ok = exports.whip_core:SetVehicleData(ctx.vehicleId, 'audit2', 'kept?')
                assertNil(exports.whip_core:__TestGetDbFaultMode(), 'the fault fired on that write')

                assertFalse(ok, 'the failure is reported')
                assertNil(exports.whip_core:GetVehicleData(ctx.vehicleId, 'audit2'), 'the value was put back')
                assertNil(vehDataOnDisk(ctx.vehicleId).audit2, 'and never reached the row')

                -- And a normal write still works afterwards.
                assertTrue(exports.whip_core:SetVehicleData(ctx.vehicleId, 'audit2', 'yes'), 'a clean write lands')
                assertEqual(vehDataOnDisk(ctx.vehicleId).audit2, 'yes', 'on disk')
            end,
        },
        {
            name = 'A batch vehicle-data write that fails is undone WHOLE',
            fn = function(source, ctx)
                if not ctx.vehicleId then skip('no fixture vehicle') end
                assertTrue(exports.whip_core:ClearAllVehicleData(ctx.vehicleId), 'start empty')
                assertTrue(exports.whip_core:SetVehicleData(ctx.vehicleId, 'base', 1), 'baseline value')

                assertTrue(exports.whip_core:__TestSetDbFaultMode('vehicle_data'), 'fault armed')
                local written, err = exports.whip_core:SetVehicleData(ctx.vehicleId, { base = 2, extra = 3 })
                assertNil(exports.whip_core:__TestGetDbFaultMode(), 'the fault fired on that write')

                assertFalse(written, 'nothing is reported written (false, since DX-19 — it was 0, which is true)')
                assertNotNil(err, 'with a reason')
                assertEqual(exports.whip_core:GetVehicleData(ctx.vehicleId, 'base'), 1,
                    'an overwritten key got its old value back')
                assertNil(exports.whip_core:GetVehicleData(ctx.vehicleId, 'extra'),
                    'and a new key is gone again')
                local stored = vehDataOnDisk(ctx.vehicleId)
                assertEqual(stored.base, 1, 'the row still holds the old value')
                assertNil(stored.extra, 'and never got the new key')
            end,
        },
        {
            name = 'A ClearAll that fails to write keeps the data',
            fn = function(source, ctx)
                if not ctx.vehicleId then skip('no fixture vehicle') end
                assertTrue(exports.whip_core:SetVehicleData(ctx.vehicleId, 'base', 1), 'something to clear')

                assertTrue(exports.whip_core:__TestSetDbFaultMode('vehicle_data'), 'fault armed')
                local ok = exports.whip_core:ClearAllVehicleData(ctx.vehicleId)
                assertNil(exports.whip_core:__TestGetDbFaultMode(), 'the fault fired on that write')

                assertFalse(ok, 'the failure is reported')
                assertEqual(exports.whip_core:GetVehicleData(ctx.vehicleId, 'base'), 1,
                    'the block was put back — a kit is not uninstalled by a failed write')
                assertEqual(vehDataOnDisk(ctx.vehicleId).base, 1, 'and the row still has it')
            end,
        },
    },
})
