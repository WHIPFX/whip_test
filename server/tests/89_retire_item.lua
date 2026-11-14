-- ============================================
-- RetireItem — an item taken out of the game for good (whip_core server/retired_items.lua)
--
-- One retirement, every place it has to reach: the tester's pockets (online: pushed and saved), an
-- open stash and a duffle bag inside it, and a stash whose rows are only read AFTER the retirement (it
-- must load clean and lose the rows). Each one taken is a 'lost' row carrying the reason; the definition
-- goes, and RegisterItem refuses the name until UnretireItem gives it back.
-- ============================================

local ITEM   = '_test_retire'
local REASON = 'whip_test retirement'

local function fixtureDef()
    return { name = 'Retire Fixture', desc = 'RetireItem fixture', weight = 0.1, type = 'misc',
             stack = true, maxStack = 10 }
end

local function lostRows()
    return DbQuery('SELECT `detail` FROM `activity_log` WHERE `itemKey` = ? AND `event` = ?', { ITEM, 'lost' })
end

local function makeStash(source, name)
    local c = CreateContainerNearPlayer(source, {
        name = name, type = 'stash', slots = 5, maxWeight = 50.0, prop = 'prop_cs_cardbox_01',
    })
    return c.containerId
end

RegisterTestModule({
    order    = 89,
    category = 'Retired Items',

    setup = function(source, ctx)
        -- A run that stopped half way left it retired (whip_test's own retirement): given back first.
        exports.whip_core:UnretireItem(ITEM)
        local ok, err = exports.whip_core:RegisterItem(ITEM, fixtureDef())
        if not ok then error('fixture item: ' .. tostring(err)) end
        DbQuery('DELETE FROM `activity_log` WHERE `itemKey` = ?', { ITEM })
        RemoveAllOf(source, ITEM)
    end,

    teardown = function(ctx, source)
        exports.whip_core:UnretireItem(ITEM)
        for _, id in ipairs({ ctx.openId, ctx.laterId }) do
            if id then
                if source then pcall(ClientCloseContainer, source, id, 3000) end
                pcall(exports.whip_core.DeleteContainer, exports.whip_core, id)
            end
        end
        if source then RemoveAllOf(source, ITEM) end
        DbQuery('DELETE FROM `activity_log` WHERE `itemKey` = ?', { ITEM })
    end,

    tests = {
        {
            name = 'RetireItem takes it from the pockets, an open stash and a bag in it, logged',
            fn = function(source, ctx)
                local where, err = exports.whip_core:AddItem(source, ITEM, 2, nil, { noDrop = true })
                assertOk(where, err, 'two in the pockets')

                ctx.openId = makeStash(source, '_test_retire_open')
                OpenContainerOrFail(source, ctx.openId)
                local slot, giveErr = exports.whip_core:StoreGive({ kind = 'container', id = ctx.openId, slot = 1 }, ITEM, 3)
                assertOk(slot, giveErr, 'three in the open stash')
                slot, giveErr = exports.whip_core:StoreGive({ kind = 'container', id = ctx.openId, slot = 2 },
                    'duffle_bag', 1, { slots = { [1] = { item = ITEM, amount = 1 }, [2] = { item = 'drink', amount = 1 } } })
                assertOk(slot, giveErr, 'a duffle bag holding one, beside a drink')
                FlushPersistence(source)

                local ok, retireErr = exports.whip_core:RetireItem(ITEM, REASON)
                assertOk(ok, retireErr, 'RetireItem')

                -- The sweep of what is loaded runs in its own thread.
                assertTrue(waitFor(function() return exports.whip_core:GetItemCount(source, ITEM) == 0 end, 5000),
                    'gone from the pockets')
                local read = exports.whip_core:StoreRead({ kind = 'container', id = ctx.openId })
                local items = read and read.items or {}
                assertNil(items[1], 'gone from the open stash')
                local bag = items[2]
                assertEqual(bag and bag.item, 'duffle_bag', 'the bag stays')
                local inside = bag and bag.metadata and bag.metadata.slots or {}
                assertNil(inside[1] or inside['1'], 'gone from inside the bag')
                local drink = inside[2] or inside['2']
                assertEqual(drink and drink.item, 'drink', 'the drink beside it stays')

                FlushPersistence(source)
                local player = exports.whip_core:GetPlayer(source)
                assertEqual(#DbQuery('SELECT 1 FROM `character_inventory` WHERE `charId` = ? AND `item` = ?',
                    { player.charId, ITEM }), 0, 'no pocket rows left on disk')
                assertEqual(#DbQuery('SELECT 1 FROM `container_inventory` WHERE `containerId` = ? AND `item` = ?',
                    { ctx.openId, ITEM }), 0, 'no stash rows left on disk')

                -- Pockets, stash, bag: three stacks, three 'lost' rows, each with the reason.
                local rows = waitFor(function()
                    local r = lostRows()
                    return #r >= 3 and r or nil
                end, 8000)
                assertNotNil(rows, 'three lost rows logged')
                for _, r in ipairs(rows) do
                    assertTrue(tostring(r.detail):find(REASON, 1, true) ~= nil, 'the log says why: ' .. tostring(r.detail))
                end
            end,
        },
        {
            name = 'The definition is gone, and RegisterItem refuses the name',
            fn = function(source)
                local where = exports.whip_core:AddItem(source, ITEM, 1, nil, { noDrop = true })
                assertFalse(where, 'nothing can make a new one')
                local ok, err = exports.whip_core:RegisterItem(ITEM, fixtureDef())
                assertFalse(ok, 'RegisterItem refused')
                assertTrue(tostring(err):find('retired', 1, true) ~= nil, 'and says it is retired: ' .. tostring(err))
            end,
        },
        {
            name = 'A stash read after the retirement loads clean and loses the rows',
            fn = function(source, ctx)
                ctx.laterId = makeStash(source, '_test_retire_later')
                assertFalse(exports.whip_core:__TestContainerCached(ctx.laterId), 'not loaded yet')
                -- A row left from before the retirement, as an old stash would have.
                DbQuery('INSERT INTO `container_inventory` (`containerId`, `slot`, `item`, `amount`) VALUES (?, 1, ?, 2)',
                    { ctx.laterId, ITEM })

                assertTrue(exports.whip_core:__TestLoadContainer(ctx.laterId), 'it loads')
                local read = exports.whip_core:StoreRead({ kind = 'container', id = ctx.laterId })
                assertNil(read and read.items and read.items[1], 'loaded without it')

                FlushPersistence(source)
                assertEqual(#DbQuery('SELECT 1 FROM `container_inventory` WHERE `containerId` = ?', { ctx.laterId }), 0,
                    'and the row is deleted')
                assertNotNil(waitFor(function() return #lostRows() >= 4 end, 8000), 'logged as well')
            end,
        },
        {
            name = 'Another resource\'s item cannot be retired, and nothing of it is taken',
            fn = function(source)
                local before = exports.whip_core:GetItemCount(source, 'drink')
                local ok, err = exports.whip_core:RetireItem('drink', 'whip_test must not end this')
                assertFalse(ok, "whip_core's drink: refused")
                assertTrue(tostring(err):find('only it can retire it', 1, true) ~= nil, 'and says whose: ' .. tostring(err))
                assertEqual(exports.whip_core:GetItemCount(source, 'drink'), before, 'the drinks they hold are untouched')
            end,
        },
        {
            name = 'UnretireItem frees the name again',
            fn = function()
                local ok, err = exports.whip_core:UnretireItem(ITEM)
                assertOk(ok, err, 'UnretireItem')
                ok, err = exports.whip_core:RegisterItem(ITEM, fixtureDef())
                assertOk(ok, err, 'RegisterItem takes it back')
            end,
        },
    },
})
