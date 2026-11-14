RegisterTestModule({
    order    = 8,
    category = 'Shops',
    setup = function(source, ctx)
        local shop, shopErr = exports.whip_core:EnsureShop('_test_shop', {
            name = 'Test Shop',
            mode = 'npc',
            x = 0, y = 0, z = 50, heading = 0,
        })
        if not shop then error('Failed to create test shop: ' .. tostring(shopErr)) end
        ctx.shopId = shop.shopId

        -- A REAL job to link the shop to. 04_jobs keeps _test_job between runs; EnsureJob makes it
        -- if this module runs on its own.
        local job = exports.whip_core:GetJob('_test_job')
            or exports.whip_core:EnsureJob('_test_job', { name = 'Test Job', icon = 'wrench' })
        ctx.jobId = job and job.jobId or nil
    end,
    teardown = function(ctx)
        pcall(exports.whip_core.__TestFailNextQuery, exports.whip_core, nil)
        if ctx.shopId then
            pcall(exports.whip_core.DeleteShop, exports.whip_core, ctx.shopId)
        end
        -- The delete test's own shop, if that test failed before (or during) its delete.
        local temp = exports.whip_core:GetShop({ key = '_test_shop_del' })
        if temp then pcall(exports.whip_core.DeleteShop, exports.whip_core, temp.shopId) end
    end,
    tests = {
        {
            -- ON DISK. "ctx.shopId is not nil" was true the moment setup finished, so it could only
            -- ever repeat setup's own check. The row is the thing EnsureShop promises.
            name = 'EnsureShop creates shop, and its row',
            fn = function(source, ctx)
                assertNotNil(ctx.shopId, 'shopId')
                local rows = DbQuery('SELECT `name`, `mode` FROM `shops` WHERE `shopId` = ?', { ctx.shopId })
                assertNotNil(rows[1], 'the shop row is on disk')
                assertEqual(rows[1].name, 'Test Shop', 'with its name')
                assertEqual(rows[1].mode, 'npc', 'and its mode')
            end,
        },
        {
            name = 'GetShop returns shop def',
            fn = function(source, ctx)
                local shop = exports.whip_core:GetShop(ctx.shopId)
                assertNotNil(shop, 'GetShop')
                assertEqual(shop.name, 'Test Shop', 'shop.name')
            end,
        },
        {
            -- GetShop({ key = k }) since 14 Nov 2026: it was GetShopBy('key', k), and GetShopByKey before 09-24.
            name = 'GetShop({ key }) finds by key',
            fn = function(source, ctx)
                local shop = exports.whip_core:GetShop({ key = '_test_shop' })
                assertNotNil(shop, 'GetShop({ key })')
                assertEqual(shop.shopId, ctx.shopId, 'shopId')
            end,
        },
        {
            name = 'GetShops includes test shop',
            fn = function(source, ctx)
                local all = exports.whip_core:GetShops()
                assertType(all, 'table', 'GetShops')
                local found = false
                for _, s in ipairs(all) do
                    if s.shopId == ctx.shopId then found = true; break end
                end
                assertTrue(found, 'test shop in GetShops')
            end,
        },
        {
            name = 'UpdateShop updates fields, in memory and on disk',
            fn = function(source, ctx)
                local ok, err = exports.whip_core:UpdateShop(ctx.shopId, { name = 'Updated Test Shop' })
                assertOk(ok, err, 'UpdateShop')
                local shop = exports.whip_core:GetShop(ctx.shopId)
                assertEqual(shop.name, 'Updated Test Shop', 'updated name')
                assertDbScalar('SELECT `name` FROM `shops` WHERE `shopId` = ?', { ctx.shopId },
                    'Updated Test Shop', 'and on disk')
            end,
        },
        {
            -- ROW FIRST, MEMORY SECOND (Shops.update). This used to change the cache, broadcast the
            -- new shop to every client and throw the write result away — a failed write left the
            -- server believing in a shop the database never heard of.
            name = 'A shop update whose write fails changes nothing',
            fn = function(source, ctx)
                local before = exports.whip_core:GetShop(ctx.shopId).name

                assertTrue(exports.whip_core:__TestFailNextQuery('UPDATE `shops`'), 'fault armed')
                local ok, err = exports.whip_core:UpdateShop(ctx.shopId, { name = '_test should not stick' })
                -- Read, then disarm AT ONCE: a fault that did not fire would otherwise sit armed for
                -- ten seconds and fail whatever unrelated write matched it next.
                local stillArmed = exports.whip_core:__TestRawFaultArmed()
                exports.whip_core:__TestFailNextQuery(nil)
                assertNil(stillArmed, 'the fault fired on the update\'s own write')
                assertFalse(ok, 'the update reports failure')
                assertEqual(err, DB_ERROR, 'with its reason')

                assertEqual(exports.whip_core:GetShop(ctx.shopId).name, before, 'unchanged in memory')
                assertDbScalar('SELECT `name` FROM `shops` WHERE `shopId` = ?', { ctx.shopId }, before,
                    'and on disk')
            end,
        },
        {
            -- UpdateShop(id, { catalog = ... }) since 09-24 (UpdateShopCatalog, which was that call
            -- with the field in its name, was removed).
            name = 'UpdateShop sets the catalog',
            fn = function(source, ctx)
                -- A MAP of item key to price — the shape Shops.priceFor reads. This used to pass a
                -- LIST of { item, price, label } rows, which saved "successfully" and then sold
                -- nothing, because the shop looks prices up by item key. The catalog is validated
                -- on the way in now, so the wrong shape is refused rather than stored.
                local catalog = { food = 10, drink = 5 }
                local ok, err = exports.whip_core:UpdateShop(ctx.shopId, { catalog = catalog })
                assertTrue(ok, 'UpdateShop catalog: ' .. tostring(err))
                assertEqual(exports.whip_core:GetShopCatalog(ctx.shopId).food, 10, 'price readable by item key')
            end,
        },
        {
            name = 'UpdateShop refuses a list-shaped catalog and a negative price',
            fn = function(source, ctx)
                local okList = exports.whip_core:UpdateShop(ctx.shopId, { catalog = {
                    { item = 'food', price = 10 },
                } })
                assertFalse(okList, 'a list of rows is not a catalog')

                local okNeg = exports.whip_core:UpdateShop(ctx.shopId, { catalog = { food = -5 } })
                assertFalse(okNeg, 'a negative price is refused')

                assertEqual(exports.whip_core:GetShopCatalog(ctx.shopId).food, 10,
                    'and the catalog that was there survives both refusals')
            end,
        },
        {
            -- Idempotent in the SHOP, not in every field: an existing shop is returned as it is,
            -- except that EnsureShop brings its name up to date (Shops.ensureShop), which is how a
            -- resource renames its own shop on the next start.
            name = 'EnsureShop is idempotent (returns existing, name brought up to date)',
            fn = function(source, ctx)
                local shop2 = exports.whip_core:EnsureShop('_test_shop', { name = 'Different Name', x = 0, y = 0, z = 50 })
                assertNotNil(shop2, 'EnsureShop idempotent')
                assertEqual(shop2.shopId, ctx.shopId, 'same shopId returned')
                assertEqual(exports.whip_core:GetShop(ctx.shopId).name, 'Different Name', 'the name followed')
            end,
        },
        {
            -- DX-17: EnsureShop followed only `name`, so a resource that changed its catalog in code
            -- sold the old one forever. The EnsureZone rule now: a CHANGED declaration is applied;
            -- the SAME declaration again leaves the shop as the admin panel last left it.
            name = 'EnsureShop follows a changed declaration, and not an unchanged one',
            fn = function(source, ctx)
                local decl = { name = 'Different Name', x = 0, y = 0, z = 50, catalog = { food = 7 } }
                local shop, err = exports.whip_core:EnsureShop('_test_shop', decl)
                assertOk(shop, err, 'EnsureShop with a catalog')
                assertEqual(exports.whip_core:GetShopCatalog(ctx.shopId).food, 7, 'the catalog followed the code')

                local edited, eErr = exports.whip_core:UpdateShop(ctx.shopId, { catalog = { food = 9 } })
                assertOk(edited, eErr, 'an admin edit')
                exports.whip_core:EnsureShop('_test_shop', decl)
                assertEqual(exports.whip_core:GetShopCatalog(ctx.shopId).food, 9,
                    'the same declaration leaves the edit alone')

                decl.catalog = { food = 8 }
                exports.whip_core:EnsureShop('_test_shop', decl)
                assertEqual(exports.whip_core:GetShopCatalog(ctx.shopId).food, 8, 'a changed one is applied')
                assertDbRowCount("SELECT 1 FROM `shops` WHERE `shopId` = ? AND JSON_EXTRACT(`catalog`, '$.food') = 8",
                    { ctx.shopId }, 1, 'and saved')
            end,
        },
        {
            -- GetShops({ job = j }) since 14 Nov 2026: it was GetShopBy('job', j), and GetShopsByJob before
            -- 09-24. A job's shops are a LIST.
            name = 'GetShops({ job }) returns empty for no job',
            fn = function(source, ctx)
                local shops = exports.whip_core:GetShops({ job = 999999 })
                assertType(shops, 'table', 'GetShops({ job }) type')
                assertEqual(#shops, 0, 'no shops for fake job')
            end,
        },
        {
            -- THE POSITIVE CASE, and the way back. `false` clears a link to NULL (nil still means
            -- "not mentioned") — before that existed, the panel sent 0, the id sanitiser turned it
            -- into nil, and a shop could never be unlinked from a job while the panel said
            -- "updated".
            name = 'GetShops({ job }) finds a linked shop, and UpdateShop(false) unlinks it',
            fn = function(source, ctx)
                assertNotNil(ctx.jobId, 'setup found or made a job to link to')

                local linked, lErr = exports.whip_core:UpdateShop(ctx.shopId, { jobId = ctx.jobId })
                assertOk(linked, lErr, 'linked to the job')
                local found = false
                for _, s in ipairs(exports.whip_core:GetShops({ job = ctx.jobId }) or {}) do
                    if s.shopId == ctx.shopId then found = true break end
                end
                assertTrue(found, 'GetShops({ job }) lists it')
                assertDbScalar('SELECT `jobId` FROM `shops` WHERE `shopId` = ?', { ctx.shopId }, ctx.jobId,
                    'the link is on disk')

                local cleared, cErr = exports.whip_core:UpdateShop(ctx.shopId, { jobId = false })
                assertOk(cleared, cErr, 'unlinked')
                assertNil(exports.whip_core:GetShop(ctx.shopId).jobId, 'no job in memory')
                for _, s in ipairs(exports.whip_core:GetShops({ job = ctx.jobId }) or {}) do
                    assertNotEqual(s.shopId, ctx.shopId, 'no longer listed under the job')
                end
                assertDbRowCount('SELECT 1 FROM `shops` WHERE `shopId` = ? AND `jobId` IS NULL', { ctx.shopId }, 1,
                    'and NULL on disk')
            end,
        },
        {
            -- CHECKED AND FIRST (Shops.delete): a delete whose row survives must not look complete,
            -- or the shop rises again at the next restart with every client told it was gone.
            name = 'A shop delete whose write fails leaves the shop in place',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:__TestFailNextQuery('DELETE FROM `shops`'), 'fault armed')
                local ok, err = exports.whip_core:DeleteShop(ctx.shopId)
                local stillArmed = exports.whip_core:__TestRawFaultArmed()
                exports.whip_core:__TestFailNextQuery(nil)
                assertNil(stillArmed, 'the fault fired on the delete\'s own write')
                assertFalse(ok, 'the delete reports failure')
                assertEqual(err, DB_ERROR, 'with its reason')
                assertNotNil(exports.whip_core:GetShop(ctx.shopId), 'still in memory')
                assertNotNil(exports.whip_core:GetShop({ key = '_test_shop' }), 'still reachable by key')
                assertDbRowCount('SELECT 1 FROM `shops` WHERE `shopId` = ?', { ctx.shopId }, 1, 'and on disk')
            end,
        },
        {
            name = 'DeleteShop removes shop, and its row',
            fn = function(source, ctx)
                -- EnsureShop answers `false, reason` on a failure since 09-24 (INV-17; it was a bare nil).
                local temp, tempErr = exports.whip_core:EnsureShop('_test_shop_del', { name = 'To Delete', x = 0, y = 0, z = 50 })
                assertOk(temp, tempErr, 'create temp shop')
                local ok, err = exports.whip_core:DeleteShop(temp.shopId)
                assertOk(ok, err, 'DeleteShop')
                assertNil(exports.whip_core:GetShop({ key = '_test_shop_del' }), 'deleted shop should be nil')
                assertNil(exports.whip_core:GetShop(temp.shopId), 'and gone by id')
                assertDbRowCount('SELECT 1 FROM `shops` WHERE `shopId` = ?', { temp.shopId }, 0,
                    'the row is gone from disk')
            end,
        },
    }
})
