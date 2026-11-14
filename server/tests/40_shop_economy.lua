-- ============================================
-- Shop economy — catalogs, shelf prices and stock
--
-- WHY THIS MODULE EXISTS
--
-- Two different pricing models live behind these exports and nothing tested either.
--
--   * An `npc`/`infinite` shop sells from a CATALOG: a flat map of item key to price, with no
--     stock. AddCatalogItem and RemoveCatalogItem edit it.
--   * A `stocked` shop sells what is physically in a CONTAINER, and prices it per ITEM (12 Oct
--     2026; it was per shelf slot). SetShopItemPrice writes those (SetShopSlotPrice, which priced
--     the item on a slot it named, went on 14 Nov 2026).
--
-- The exports refuse across the models on purpose — GetShopPrices answers only for a stocked
-- shop, AddCatalogItem only for the other two — and those refusals are the thing most likely to
-- rot, because they are the paths a satellite hits only when it has made a mistake.
--
-- THE PRICE WRITE IS WHY THIS MATTERS MOST
--
-- setItemPrice writes the ROW before the cache, and whip_core's comment says what the other
-- order cost: "a discarded failure here priced the shelf in memory only — customers paid the
-- new price until the restart quietly restored the old one". A test that only reads the cache
-- back would pass against exactly that bug, so the price assertions here go to the database —
-- and the "row first" promise itself is tested by failing the row write (__TestFailNextQuery).
--
-- AND THE SHOP SCREEN (12 Oct 2026): a player puts goods in the basket, takes them out and buys,
-- through the screen's own events — basketAdd, basketSetQuantity, shopPurchase — and the stock and
-- the pockets are read back. Everything sold here is priced at 0, so no test needs the tester's
-- money.
-- ============================================

local KEY   = '_test_shop_econ'
local ITEM  = '_test_shop_item'
local SHELF_SLOTS = 10

--- The price row as the database holds it, which is the half that survives a restart.
---
--- `forSale` is CAST to a number here. The column is TINYINT(1), which oxmysql hands back as a
--- BOOLEAN — so `tonumber(row.forSale)` was nil for a row that correctly said "not for sale", and the
--- test failed against right code on 09-23. (15_doors' doorColumn casts for the same reason.)
local function priceOnDisk(containerId, item)
    return DbQuery('SELECT `price`, CAST(`forSale` AS UNSIGNED) AS `forSale` FROM `shop_item_prices` '
        .. 'WHERE `containerId` = ? AND `item` = ?', { containerId, item })[1]
end

--- `n` of the fixture item onto shelf slot `shelfSlot`, the way a satellite restocking a shop would:
--- seeded into a pocket, then moved with the public StoreMove.
local function stockShelf(source, ctx, shelfSlot, n)
    assertTrue(exports.whip_core:__TestLoadContainer(ctx.containerId), 'shelf contents loaded')
    local pocket = exports.whip_core:GetPocketSlots('player')
    SeedSlot(source, 'player', pocket, ITEM, n)
    local moved, err = exports.whip_core:StoreMove(
        { kind = 'player', id = source, sub = 'player', slot = pocket },
        { kind = 'container', id = ctx.containerId, slot = shelfSlot })
    assertTrue(moved, 'stock onto shelf slot ' .. shelfSlot .. ': ' .. tostring(err))
end

--- How many of the fixture item the stocked shop's shelf holds, across its slots.
local function onShelf(ctx)
    local n = 0
    for _, s in pairs(exports.whip_core:GetShopStock(ctx.stockedShopId) or {}) do
        if s.item == ITEM then n = n + (tonumber(s.amount) or 0) end
    end
    return n
end

--- The catalog as the shops row holds it.
local function catalogOnDisk(shopId)
    local rows = DbQuery('SELECT `catalog` FROM `shops` WHERE `shopId` = ?', { shopId })
    local raw = rows[1] and rows[1].catalog
    if type(raw) == 'string' then return json.decode(raw) or {} end
    return raw or {}
end

--- A shop left by an interrupted run, removed through whip_core so its cache entry goes too. A raw
--- `DELETE ... LIKE` (what this used to be) removed the rows and left ghosts in Shops.cache —
--- which then made DeleteContainer refuse the shelf, because a cached shop still pointed at it.
local function removeShopByKey(key)
    local def = exports.whip_core:GetShop({ key = key })   -- GetShopByKey until 09-24, then GetShopBy('key', ...)
    if def and def.shopId then pcall(exports.whip_core.DeleteShop, exports.whip_core, def.shopId) end
end

--- The last player slot, cleared: pockets fill from the front, so this one is the least likely to
--- be holding anything a test did not put there. (09-24: GetPocketSlots and StoreTake by address
--- replaced GetContainerSlots and RemoveItemFromSlot.)
local function claimPocket(source)
    local slot = exports.whip_core:GetPocketSlots('player')
    pcall(exports.whip_core.StoreTake, exports.whip_core, PocketAddr(source, 'player', slot))
    return slot
end

RegisterTestModule({
    order    = 40,
    category = 'Shop Economy',

    -- FILLS ctx AS IT GOES. The container used to be created and then the whole setup could skip on
    -- a failed shop — and a skip took ctx with it, so the container was never deleted.
    setup = function(source, ctx)
        exports.whip_core:RegisterItem(ITEM, {
            name = 'Shop Fixture', desc = 'shop economy fixture',
            weight = 0.1, type = 'misc', stack = true, maxStack = 20,
        })

        removeShopByKey(KEY .. '_npc')
        removeShopByKey(KEY .. '_stocked')

        local ped = GetPlayerPed(source)
        local pos = GetEntityCoords(ped)

        -- A container to be the stocked shop's shelves.
        local c = exports.whip_core:CreateContainer({
            name = '_test_shop_shelf', type = 'stash', slots = SHELF_SLOTS, maxWeight = 100.0,
            x = pos.x + 3, y = pos.y, z = pos.z, heading = 0, prop = 'prop_cs_cardbox_01',
        })
        if not c or not c.containerId then skip('could not create the shelf container') end
        ctx.containerId = c.containerId

        local npcShop = exports.whip_core:CreateShop({
            key = KEY .. '_npc', name = 'Test NPC Shop', mode = 'npc',
            x = pos.x + 4, y = pos.y, z = pos.z, catalog = {},
        })
        if npcShop then ctx.npcShopId = npcShop.shopId end

        local stockedShop = exports.whip_core:CreateShop({
            key = KEY .. '_stocked', name = 'Test Stocked Shop', mode = 'stocked',
            containerId = c.containerId,
            x = pos.x + 5, y = pos.y, z = pos.z,
        })
        if stockedShop then ctx.stockedShopId = stockedShop.shopId end

        if not ctx.npcShopId or not ctx.stockedShopId then skip('could not create the fixture shops') end
    end,

    teardown = function(ctx, source)
        pcall(exports.whip_core.__TestFailNextQuery, exports.whip_core, nil)
        if source then RemoveAllOf(source, ITEM) end
        -- The shop first: DeleteContainer refuses a container a cached shop still sells from.
        if ctx.npcShopId then pcall(exports.whip_core.DeleteShop, exports.whip_core, ctx.npcShopId) end
        if ctx.stockedShopId then pcall(exports.whip_core.DeleteShop, exports.whip_core, ctx.stockedShopId) end
        if ctx.containerId then
            -- Contents and price rows go with it (Containers.delete, one transaction).
            local ok, err = exports.whip_core:DeleteContainer(ctx.containerId)
            if not ok then
                print(('[whip_test] 40_shop_economy: shelf container %d not deleted: %s')
                    :format(ctx.containerId, tostring(err)))
            end
        end
    end,

    tests = {
        -- ==========================================
        -- Catalog shops
        -- ==========================================
        {
            name = 'AddCatalogItem puts an item on the catalog at a price',
            fn = function(source, ctx)
                local ok, err = exports.whip_core:AddCatalogItem(ctx.npcShopId, ITEM, 250)
                assertTrue(ok, 'AddCatalogItem: ' .. tostring(err))

                local catalog = exports.whip_core:GetShopCatalog(ctx.npcShopId)
                assertNotNil(catalog, 'the catalog reads back')
                assertEqual(catalog[ITEM], 250, 'at the price it was given')
                assertEqual(catalogOnDisk(ctx.npcShopId)[ITEM], 250, 'and the shops row carries it')
            end,
        },
        {
            name = 'A catalog price is FLOORED, not stored fractionally — in the row too',
            fn = function(source, ctx)
                -- Prices are money. A fractional one would be charged, displayed and banked
                -- differently depending on which of the three rounded it.
                assertTrue(exports.whip_core:AddCatalogItem(ctx.npcShopId, ITEM, 99.7), 'accepted')
                assertEqual(exports.whip_core:GetShopCatalog(ctx.npcShopId)[ITEM], 99,
                    'stored as a whole number')
                assertEqual(catalogOnDisk(ctx.npcShopId)[ITEM], 99, 'and written as one')
            end,
        },
        {
            name = 'A nonsense price or an unknown item is refused',
            fn = function(source, ctx)
                local ok1, e1 = exports.whip_core:AddCatalogItem(ctx.npcShopId, ITEM, -5)
                assertFalse(ok1, 'a negative price is refused')
                assertEqual(e1, 'Invalid price', 'and says so')

                local ok2, e2 = exports.whip_core:AddCatalogItem(ctx.npcShopId, ITEM, 'free')
                assertFalse(ok2, 'a non-numeric price is refused')
                assertEqual(e2, 'Invalid price', 'with the reason')

                local ok3, e3 = exports.whip_core:AddCatalogItem(ctx.npcShopId, '_test_no_such_item', 10)
                assertFalse(ok3, 'an unregistered item is refused')
                assertTrue(tostring(e3):lower():find('unknown item', 1, true) ~= nil,
                    ('and says so (got "%s")'):format(tostring(e3)))
            end,
        },
        {
            name = 'A catalog edit whose ROW write fails leaves the catalog as it was',
            fn = function(source, ctx)
                -- Row first, memory second. addCatalogItem hands Shops.update a COPY; editing the
                -- live catalog in place used to change the shelf even when the write failed, and
                -- report success regardless.
                assertTrue(exports.whip_core:AddCatalogItem(ctx.npcShopId, ITEM, 40), 'baseline price set')

                assertTrue(exports.whip_core:__TestFailNextQuery('UPDATE `shops`'), 'row fault armed')
                local ok, err = exports.whip_core:AddCatalogItem(ctx.npcShopId, ITEM, 400)
                assertNil(exports.whip_core:__TestRawFaultArmed(), 'the fault fired on that write')

                assertFalse(ok, 'the edit reports failure')
                assertEqual(err, DB_ERROR, 'as a database error')
                assertEqual(exports.whip_core:GetShopCatalog(ctx.npcShopId)[ITEM], 40,
                    'memory still holds the old price — it did not run ahead of the row')
                assertEqual(catalogOnDisk(ctx.npcShopId)[ITEM], 40, 'and so does the row')
            end,
        },
        {
            name = 'RemoveCatalogItem takes it off, and refuses what was never on',
            fn = function(source, ctx)
                exports.whip_core:AddCatalogItem(ctx.npcShopId, ITEM, 100)
                assertTrue(exports.whip_core:RemoveCatalogItem(ctx.npcShopId, ITEM), 'removed')
                assertNil(exports.whip_core:GetShopCatalog(ctx.npcShopId)[ITEM], 'gone from the catalog')
                assertNil(catalogOnDisk(ctx.npcShopId)[ITEM], 'and from the row')

                local ok, err = exports.whip_core:RemoveCatalogItem(ctx.npcShopId, ITEM)
                assertFalse(ok, 'removing it twice is refused')
                assertEqual(err, 'Item not in catalog', 'and says why')
            end,
        },
        {
            name = 'Catalog edits are refused on a STOCKED shop',
            fn = function(source, ctx)
                -- A stocked shop sells what is on its shelves. A catalog entry would be an
                -- item it claims to sell and has none of — priced, buyable, and backed by
                -- nothing.
                local ok, err = exports.whip_core:AddCatalogItem(ctx.stockedShopId, ITEM, 10)
                assertFalse(ok, 'refused')
                assertEqual(err, 'Shop is not infinite/npc mode', 'and names the reason')
            end,
        },

        -- ==========================================
        -- Stocked shops — shelf prices
        -- ==========================================
        {
            name = 'SetShopItemPrice writes the price ROW, not just the cache',
            fn = function(source, ctx)
                -- The row is the half that survives a restart, and the half a cache-only read
                -- would not notice was missing.
                assertTrue(exports.whip_core:SetShopItemPrice(ctx.containerId, ITEM, 175, true),
                    'the price was set')

                local row = priceOnDisk(ctx.containerId, ITEM)
                assertNotNil(row, 'a price row exists on disk')
                assertEqual(tonumber(row.price), 175, 'at the price that was set')
            end,
        },
        {
            name = 'A price whose ROW write fails is not priced in memory either',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:SetShopItemPrice(ctx.containerId, ITEM, 175, true), 'baseline')

                assertTrue(exports.whip_core:__TestFailNextQuery('`shop_item_prices`'), 'row fault armed')
                local ok, err = exports.whip_core:SetShopItemPrice(ctx.containerId, ITEM, 999, true)
                assertNil(exports.whip_core:__TestRawFaultArmed(), 'the fault fired on that write')

                assertFalse(ok, 'the price change reports failure')
                assertEqual(err, DB_ERROR, 'as a database error')
                local prices = exports.whip_core:GetShopPrices(ctx.stockedShopId) or {}
                assertEqual(prices[ITEM] and prices[ITEM].price, 175, 'customers still pay the old price')
                assertEqual(tonumber(priceOnDisk(ctx.containerId, ITEM).price), 175, 'which is what the row says')
            end,
        },
        {
            name = 'One item has one price, whichever shelf slot it is on',
            fn = function(source, ctx)
                -- Josh, 12 Oct 2026: "should be per item". Priced once, the item costs the same on
                -- every slot holding it.
                stockShelf(source, ctx, 1, 2)
                stockShelf(source, ctx, 2, 2)
                assertTrue(exports.whip_core:SetShopItemPrice(ctx.containerId, ITEM, 100, true), 'priced')

                local prices = exports.whip_core:GetShopPrices(ctx.stockedShopId)
                assertNotNil(prices, 'prices read back')
                assertEqual(prices[ITEM] and prices[ITEM].price, 100, 'the item\'s price')
                local stock = exports.whip_core:GetShopStock(ctx.stockedShopId) or {}
                assertEqual(stock[1] and stock[1].price, 100, 'slot 1 sells it at that price')
                assertEqual(stock[2] and stock[2].price, 100, 'and slot 2 sells it at the same')
            end,
        },
        {
            name = 'A price is floored and never negative',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:SetShopItemPrice(ctx.containerId, ITEM, -500, true), 'accepted')
                assertEqual(tonumber(priceOnDisk(ctx.containerId, ITEM).price), 0,
                    'a negative price is clamped to zero, not stored as a negative')

                assertTrue(exports.whip_core:SetShopItemPrice(ctx.containerId, ITEM, 12.9, true), 'accepted')
                assertEqual(tonumber(priceOnDisk(ctx.containerId, ITEM).price), 12,
                    'and a fractional price is floored')
            end,
        },
        {
            -- The export hands setItemPrice whatever a satellite passed. A non-number THREW inside
            -- math.floor; NaN survived math.max(0, NaN) as 0 and made that shelf FREE; and an
            -- unknown container or an item nobody registered was priced anyway.
            name = 'SetShopItemPrice refuses a price, container or item that is not real — and writes nothing',
            fn = function(source, ctx)
                local cid = ctx.containerId
                local cases = {
                    { args = { cid, ITEM, 'abc' },     why = 'Invalid price',     label = 'a word for a price' },
                    { args = { cid, ITEM, 0 / 0 },     why = 'Invalid price',     label = 'NaN' },
                    { args = { cid, ITEM, math.huge }, why = 'Invalid price',     label = 'infinity' },
                    { args = { 987654, ITEM, 10 },     why = 'Unknown container', label = 'an unknown container' },
                    { args = { cid, '_test_no_such_item', 10 }, why = 'Unknown item', label = 'an unknown item' },
                }
                local before = priceOnDisk(cid, ITEM)
                for _, case in ipairs(cases) do
                    local okCall, ok, why = pcall(exports.whip_core.SetShopItemPrice, exports.whip_core,
                        case.args[1], case.args[2], case.args[3], true)
                    assertTrue(okCall, case.label .. ': answered rather than threw')
                    assertFalse(ok, case.label .. ' is refused')
                    assertEqual(why, case.why, case.label .. ': with the reason')
                end

                local after = priceOnDisk(cid, ITEM)
                assertEqual(after and tonumber(after.price), before and tonumber(before.price),
                    'the bad prices wrote nothing over the real one')
                assertNil(priceOnDisk(cid, '_test_no_such_item'), 'and no row for the unknown item')
            end,
        },
        {
            name = 'forSale is stored and can be turned off without losing the price',
            fn = function(source, ctx)
                -- Taking an item off sale is not the same as pricing it at zero. Losing the
                -- distinction would make everything not for sale free.
                exports.whip_core:SetShopItemPrice(ctx.containerId, ITEM, 80, true)
                exports.whip_core:SetShopItemPrice(ctx.containerId, ITEM, 80, false)

                local prices = exports.whip_core:GetShopPrices(ctx.stockedShopId) or {}
                assertNotNil(prices[ITEM], 'the item still has a price entry')
                assertEqual(prices[ITEM].price, 80, 'and the price is intact')
                assertFalse(prices[ITEM].forSale, 'but it is no longer for sale')

                -- The cache is what setItemPrice just wrote into. The row is what a restart reads.
                local row = priceOnDisk(ctx.containerId, ITEM)
                assertNotNil(row, 'the row exists')
                assertEqual(tonumber(row.price), 80, 'the row keeps the price')
                assertEqual(tonumber(row.forSale), 0, 'and records it as not for sale')
            end,
        },
        {
            name = 'GetShopPrices and GetShopStock refuse a non-stocked shop',
            fn = function(source, ctx)
                -- ####################################################################
                -- THE REFUSAL IS REAL, AND SO IS THE REASON NOW.
                --
                -- These used to answer `(nil, 'Shop is not stocked mode')`, and the string never
                -- arrived: a FiveM export truncates its return list at the FIRST NIL IN ANY
                -- POSITION, so a satellite got nil in both variables and could not tell "wrong
                -- kind of shop" from "no such shop" from "empty shelves".
                --
                -- This test was written asserting the truncation, precisely so that fixing it
                -- would turn the test red at the moment the behaviour changed. It did. Both
                -- exports now answer `false` plus the reason, which is the rule garages.lua
                -- already stated for exactly this hazard.
                -- ####################################################################
                local p, pErr = exports.whip_core:GetShopPrices(ctx.npcShopId)
                assertFalse(p, 'prices are not a question you can ask an npc shop')
                assertEqual(pErr, 'Shop is not stocked mode', 'and the reason survives the boundary')

                local s, sErr = exports.whip_core:GetShopStock(ctx.npcShopId)
                assertFalse(s, 'nor is stock')
                assertEqual(sErr, 'Shop is not stocked mode', 'and it says why too')
            end,
        },
        {
            name = 'GetShopStock merges what is on the shelf with what it is priced at',
            fn = function(source, ctx)
                -- An empty shelf proved only that the answer is a table. Stock goes on it here —
                -- through the public StoreMove, the way a satellite restocking a shop would — and
                -- the merged view has to carry the item, the amount AND the slot's price.
                local SHELF = 6
                assertTrue(exports.whip_core:__TestLoadContainer(ctx.containerId), 'shelf contents loaded')
                local pocket = claimPocket(source)
                SeedSlot(source, 'player', pocket, ITEM, 3)

                local moved, moveErr = exports.whip_core:StoreMove(
                    { kind = 'player', id = source, sub = 'player', slot = pocket },
                    { kind = 'container', id = ctx.containerId, slot = SHELF })
                assertTrue(moved, 'stock moved onto the shelf: ' .. tostring(moveErr))
                assertTrue(exports.whip_core:SetShopItemPrice(ctx.containerId, ITEM, 55, true), 'its item priced')

                local stock, err = exports.whip_core:GetShopStock(ctx.stockedShopId)
                assertOk(stock, err, 'stock reads back')
                local line = stock[SHELF]
                assertNotNil(line, 'the stocked slot is listed')
                assertEqual(line.item, ITEM, 'with its item')
                assertEqual(line.amount, 3, 'its amount')
                assertEqual(line.price, 55, 'its price')
                assertTrue(line.forSale, 'and its for-sale flag')

                -- Back into the pockets, so the shelf ends as it began (teardown takes the pockets).
                exports.whip_core:StoreMove(
                    { kind = 'container', id = ctx.containerId, slot = SHELF },
                    { kind = 'player', id = source, sub = 'player', slot = pocket })
            end,
        },

        -- ==========================================
        -- The shop screen (12 Oct 2026): basketAdd, basketSetQuantity, shopPurchase
        -- ==========================================
        {
            name = 'A catalog shop: into the basket, some taken out, bought — and it reaches the pockets',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:AddCatalogItem(ctx.npcShopId, ITEM, 0), 'on the catalog, free')
                RemoveAllOf(source, ITEM)
                ClientCloseAllUI(source)
                -- Opened as a shop point opens it (the client openShop event went: audit 13, SEC-1)
                assertTrue(exports.whip_core:__TestOpenShop(source, ctx.npcShopId), 'opened')

                assertTrue(ClientExecWait(source, 'whip_core:server:basketAdd', 3000, ITEM, 5), 'add answered')
                assertLastReject('whip_core:server:basketAdd', nil, 'five in the basket')
                -- The first line, down to three: two leave the basket (an infinite shelf takes nothing back).
                assertTrue(ClientExecWait(source, 'whip_core:server:basketSetQuantity', 3000, 1, 3), 'set answered')
                assertLastReject('whip_core:server:basketSetQuantity', nil, 'down to three')

                assertTrue(ClientExecWait(source, 'whip_core:server:shopPurchase', 5000, 'cash', 0, 0), 'paid')
                assertLastReject('whip_core:server:shopPurchase', nil, 'the purchase went through')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 3, 'three in the pockets, not five')

                ClientExecWait(source, 'whip_core:server:closeShop', 3000)
                ClientCloseAllUI(source)
            end,
        },
        {
            name = 'The till refuses a total the player was not shown',
            fn = function(source, ctx)
                -- Prices are the shop's live price: one changed after the screen drew is refused,
                -- never charged unseen.
                assertTrue(exports.whip_core:AddCatalogItem(ctx.npcShopId, ITEM, 0), 'free')
                RemoveAllOf(source, ITEM)
                ClientCloseAllUI(source)
                assertTrue(exports.whip_core:__TestOpenShop(source, ctx.npcShopId), 'opened')
                ClientExecWait(source, 'whip_core:server:basketAdd', 3000, ITEM, 1)
                assertLastReject('whip_core:server:basketAdd', nil, 'one in the basket')

                assertTrue(ClientExecWait(source, 'whip_core:server:shopPurchase', 5000, 'cash', 0, 99), 'answered')
                assertLastReject('whip_core:server:shopPurchase', 'The prices changed. Check your basket and buy again.',
                    'refused, with the reason')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM) or 0, 0, 'and nothing was handed over')

                ClientExecWait(source, 'whip_core:server:closeShop', 3000)
                ClientCloseAllUI(source)
            end,
        },
        {
            name = 'A stocked shop: the basket holds real stock, closing puts it back, buying takes it',
            fn = function(source, ctx)
                RemoveAllOf(source, ITEM)
                assertTrue(exports.whip_core:SetShopItemPrice(ctx.containerId, ITEM, 0, true), 'priced, for sale')
                local before = onShelf(ctx)
                if before < 3 then
                    stockShelf(source, ctx, 7, 3 - before)
                    before = onShelf(ctx)
                end

                ClientCloseAllUI(source)
                assertTrue(exports.whip_core:__TestOpenShop(source, ctx.stockedShopId), 'opened')
                ClientExecWait(source, 'whip_core:server:basketAdd', 3000, ITEM, 2)
                assertLastReject('whip_core:server:basketAdd', nil, 'two in the basket')
                assertEqual(onShelf(ctx), before - 2, 'off the shelf: nobody else can buy them meanwhile')

                ClientExecWait(source, 'whip_core:server:closeShop', 3000)
                ClientCloseAllUI(source)
                assertEqual(onShelf(ctx), before, 'closing put them back')

                assertTrue(exports.whip_core:__TestOpenShop(source, ctx.stockedShopId), 'opened again')
                ClientExecWait(source, 'whip_core:server:basketAdd', 3000, ITEM, 2)
                ClientExecWait(source, 'whip_core:server:shopPurchase', 5000, 'cash', 0, 0)
                assertLastReject('whip_core:server:shopPurchase', nil, 'bought')
                assertEqual(exports.whip_core:GetItemCount(source, ITEM), 2, 'two in the pockets')
                assertEqual(onShelf(ctx), before - 2, 'and gone from the shelf for good')

                ClientExecWait(source, 'whip_core:server:closeShop', 3000)
                ClientCloseAllUI(source)
            end,
        },

        -- ==========================================
        -- Lookups
        -- ==========================================
        {
            -- GetShop({ containerId = c }) since 14 Nov 2026: it was GetShopBy('containerId', c), and
            -- GetShopByContainerId before 09-24.
            name = 'GetShop({ containerId }) finds the shop that owns a container',
            fn = function(source, ctx)
                local def = exports.whip_core:GetShop({ containerId = ctx.containerId })
                assertNotNil(def, 'the shop was found by its container')
                assertEqual(def.shopId, ctx.stockedShopId, 'and it is the right one')

                assertNil(exports.whip_core:GetShop({ containerId = 987654 }),
                    'a container no shop owns answers nil')
            end,
        },
        {
            name = 'GetShopViewers lists whoever has the shop open, and nobody once it closes',
            fn = function(source, ctx)
                -- The empty answer alone could not fail. The shop is opened here the way a shop point
                -- opens one (Shops.openFor, through the __TestOpenShop seam).
                local before = exports.whip_core:GetShopViewers(ctx.npcShopId)
                assertEqual(#before, 0, 'nobody is looking at a shop nobody opened')

                ClientCloseAllUI(source)
                assertTrue(exports.whip_core:__TestOpenShop(source, ctx.npcShopId), 'the open was accepted')

                local viewers = exports.whip_core:GetShopViewers(ctx.npcShopId)
                assertEqual(#viewers, 1, 'one viewer while it is open')
                assertEqual(viewers[1], source, 'and it is the tester')

                ClientExecWait(source, 'whip_core:server:closeShop', 3000)
                ClientCloseAllUI(source)
                assertEqual(#exports.whip_core:GetShopViewers(ctx.npcShopId), 0, 'and none once it closes')
            end,
        },
        {
            name = 'A shop delete whose ROW write fails leaves the shop standing',
            fn = function(source, ctx)
                -- Checked first, before any state is torn down: the old version closed screens and
                -- dropped the cache whatever happened to the row, so a failed delete looked
                -- complete and the shop rose again at the next restart.
                assertTrue(exports.whip_core:__TestFailNextQuery('DELETE FROM `shops`'), 'row fault armed')
                local ok, err = exports.whip_core:DeleteShop(ctx.npcShopId)
                assertNil(exports.whip_core:__TestRawFaultArmed(), 'the fault fired on that write')

                assertFalse(ok, 'the delete reports failure')
                assertEqual(err, DB_ERROR, 'as a database error')
                assertNotNil(exports.whip_core:GetShop(ctx.npcShopId), 'the shop is still in memory')
                assertDbRowCount('SELECT 1 FROM `shops` WHERE `shopId` = ?', { ctx.npcShopId }, 1,
                    'and still on disk')
            end,
        },
        {
            name = 'Every shop export refuses an unknown shopId rather than raising',
            fn = function(source, ctx)
                local GONE = 987654
                -- GetShopCatalog still answers a bare nil: it has no second return value, so
                -- there is nothing for a leading nil to truncate and no reason to change it.
                -- The other two carry a reason, so they answer false.
                assertNil(exports.whip_core:GetShopCatalog(GONE), 'catalog is nil')
                assertFalse(exports.whip_core:GetShopPrices(GONE), 'prices are refused')
                assertFalse(exports.whip_core:GetShopStock(GONE), 'stock is refused')
                assertFalse(exports.whip_core:AddCatalogItem(GONE, ITEM, 10), 'add is refused')
                assertFalse(exports.whip_core:RemoveCatalogItem(GONE, ITEM), 'remove is refused')
            end,
        },
    }
})
