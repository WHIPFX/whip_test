-- ============================================
-- RegisterPanelItem — the declarative storage hooks
--
-- WHY THIS MODULE EXISTS
--
-- RegisterPanelItem is whip's answer to "my item holds other items". Before this module it
-- had ONE test, in 13_external.lua, which registers an item that FAILS to register and then
-- asserts only that the failure did not throw. Nothing anywhere checked that a registered
-- panel item opens, stores, restores, or refuses anything.
--
-- That mattered little while the API could express exactly one shape. It matters a lot now:
-- read/onValidate/write/onChange exist so whip_gunny and whip_phone can stop hand-writing
-- move handlers, and a projection API that silently mis-projects loses items.
--
-- THE FIRST TEST IS THE ONE THAT COULD SINK THE DESIGN
--
-- The hooks are FUNCTIONS INSIDE A TABLE crossing a resource export boundary. whip_core's own
-- source carries the warning — "avoids function-in-table stripping" — which says someone has
-- already been bitten by exactly this. If FiveM does not carry those functions across, no
-- amount of correct logic behind them matters and the API needs a different shape entirely.
--
-- So test one asks the cheapest possible version of that question, and every other test in
-- this module is downstream of its answer.
--
-- WHY A CUSTOM SHAPE, NOT A SLOT ARRAY
--
-- The fixture deliberately stores its contents as `meta.cargo = { item, count }` — a single
-- record, not a list of slots. That is the shape a magazine and a SIM card actually have, and
-- the shape the old API could not express. A fixture that stored a plain slot array would
-- pass identically with the hooks removed and prove nothing.
-- ============================================

local HOST    = '_test_panelitem_host'
local CARGO   = '_test_panelitem_cargo'
local BANNED  = '_test_panelitem_banned'
local ACTION  = '_test_panelitem_open'
local PLAIN   = '_test_panelitem_plain'
local PLAIN_ACTION = '_test_panelitem_plain_open'
local BROKEN  = '_test_panelitem_broken'          -- a host whose write() always errors (27 Sep 2026)
local BROKEN_ACTION = '_test_panelitem_broken_open'
local SLOT    = 6

--- Records what each hook saw, so a test can assert a hook RAN rather than inferring it from
--- a side effect that something else might also have produced.
local seen = {}

local function resetSeen()
    seen = { read = 0, validate = 0, write = 0, change = 0, lastHostItem = nil, lastReason = nil,
        -- What onValidate / onChange found in their one ctx (09-24: ctx.host and ctx.items).
        validateHostItem = nil, changeHostItem = nil, changeItems = nil,
        -- And the host's address (09-24: host.addr), which GetItemAt must find the host at.
        changeHostAddr = nil }
end

local function openPanel(source)
    return ClientExecWait(source, 'whip_core:server:customContextAction', 3000, ACTION, 'player', SLOT)
end

--- The id whip gave OUR panel, asked for rather than rebuilt.
---
--- This module used to address the panel as `ACTION .. '_' .. source`, which was the id
--- RegisterPanelItem minted until panels learned to stack. It is now built from the action, the
--- player, the container AND the slot — because two wallets in two slots would otherwise share
--- an id, and _panelInstances is keyed on that id, so both grids would have shown the same
--- contents.
---
--- The old spelling did not fail loudly. `Stores.fromWire` looks the id up in the player's own
--- session set and refuses anything not in it, so the move was rejected before the handler ran:
--- nothing reached the panel and no hook fired. The tests then reported "the drag reached the
--- panel: expected non-nil" and "onValidate ran: expected true, got false" — two symptoms of an
--- address that no longer named anything.
---
--- Reconstructing a private format is what caused that, so this asks instead. GetOpenStores lists
--- every open panel with its id for exactly this (GetOpenPanels did, until 09-24).
---
--- EVERY PANEL CALL IN THIS MODULE PASSES THE ID IT GETS FROM HERE. The unqualified forms of
--- UpdatePanelSlot and GetPanelItems answered for "the" panel only while exactly ONE was open, and
--- nil the moment there were two — so a single panel leaked by a failed test used to turn every
--- later call into a nil, and each test after it failed claiming its panel was empty.
--- (09-24: both are gone, and a panel address always carries its id. ClosePanel without an id
--- closes EVERY panel the tester has open, which is why closePanel below names ours.)
---@param action string|nil  defaults to this module's host action
local function panelIdFor(source, action)
    for _, p in ipairs(exports.whip_core:GetOpenStores(source) or {}) do
        if p.kind == 'panel' and tostring(p.id):find(action or ACTION, 1, true) then return p.id end
    end
    return nil
end

--- Close OUR panel(s) by name, leaving anything else alone.
local function closePanel(source, action)
    local pid = panelIdFor(source, action)
    if pid then exports.whip_core:ClosePanel(source, pid) end
end

--- Open the host's panel and hand back its id, failing the test if it did not really open.
--- The context action's ack only says the server ANSWERED; the id says a panel exists.
local function openAndName(source)
    assertTrue(openPanel(source), 'the context action was answered')
    local pid = panelIdFor(source)
    assertNotNil(pid, 'the panel actually opened (it is in GetOpenStores)')
    return pid
end

--- Put `amount` of `item` into slot 1 of panel `pid`, the way a resource does: StoreGive on the
--- panel's address, which answers the slot it filled. (09-24: this was UpdatePanelSlot.) Slot 1 is
--- empty here — every test seeds a fresh host — so a give is the whole write.
---
--- A server write reads the item's CURRENT contents first, as UpdatePanelSlot did: Stores.fromAddr
--- refreshes a RegisterPanelItem panel from its host before the write lands.
local function giveToPanel(pid, item, amount)
    local slot, err = exports.whip_core:StoreGive({ kind = 'panel', id = pid, slot = 1 }, item, amount)
    assertOk(slot, err, 'the panel slot was filled')
    assertEqual(slot, 1, 'in the slot named')
end

--- What panel `pid` holds, keyed by slot: StoreRead's `.items`. nil plus the reason when the panel
--- is not open. (09-24: this was GetPanelItems(source, pid).)
local function panelItems(pid)
    local store, err = exports.whip_core:StoreRead({ kind = 'panel', id = pid })
    if not store then return nil, err end
    return store.items
end

local function hostMeta(source)
    -- 09-24: GetItemAt by address (GetSlotData was removed).
    local d = exports.whip_core:GetItemAt(PocketAddr(source, 'player', SLOT))
    return d and d.metadata or nil
end

--- The host row's metadata as it is ON DISK, decoded. FlushPersistence first.
---
--- Decoded rather than searched: `find('cargo')` matched the PREVIOUS test's row just as happily
--- as this one's — every test here seeds the same slot — so a write that never happened read as
--- one that did. Only the value tells the two apart.
local function storedHostMeta(charId)
    FlushPersistence()
    local rows = DbQuery(
        'SELECT `metadata` FROM `character_inventory` WHERE `charId` = ? AND `container` = ? AND `slot` = ?',
        { charId, 'player', SLOT })
    if not rows[1] or not rows[1].metadata then return nil end
    -- A JSON column arrives as text today; take it either way rather than pin the driver.
    if type(rows[1].metadata) == 'table' then return rows[1].metadata end
    local ok, meta = pcall(json.decode, rows[1].metadata)
    return ok and meta or nil
end

RegisterTestModule({
    order    = 30,
    category = 'Panel Item',

    setup = function(source, ctx)
        resetSeen()

        exports.whip_core:RegisterItem(CARGO, {
            name = 'Panel Cargo', desc = 'goes inside the fixture',
            weight = 0.1, type = 'misc', stack = true, maxStack = 20,
        })
        exports.whip_core:RegisterItem(BANNED, {
            name = 'Panel Contraband', desc = 'must never fit',
            weight = 0.1, type = 'misc', stack = true, maxStack = 20,
        })
        -- The host MUST declare a defaultAction: RegisterPanelItem hangs the panel off it,
        -- and refuses to register without one.
        exports.whip_core:RegisterItem(HOST, {
            name = 'Panel Host', desc = 'declarative panel fixture',
            weight = 1.0, type = 'misc', stack = false, maxStack = 1,
            defaultAction = ACTION,
        })

        local registered = exports.whip_core:RegisterPanelItem(HOST, {
            slots = 1,
            label = 'Panel Fixture',

            -- Custom shape: ONE record, not a slot array.
            read = function(host)
                seen.read = seen.read + 1
                seen.lastHostItem = host.item
                local c = host.metadata and host.metadata.cargo
                if not c then return {} end
                return { [1] = { item = c.item, amount = c.count } }
            end,

            -- 09-24: ONE table, the same shape an OpenPanel panel's hooks get; the item is c.host.
            -- It was onValidate(host, ctx).
            onValidate = function(c)
                seen.validate = seen.validate + 1
                seen.validateHostItem = c.host and c.host.item
                if c.direction ~= 'in' then return true end
                if c.item == BANNED then
                    return false, 'Contraband does not fit'
                end
                return true
            end,

            write = function(host, items)
                seen.write = seen.write + 1
                local first = items and items[1]
                host.metadata.cargo = first and { item = first.item, count = first.amount } or nil
                return host.metadata
            end,

            -- 09-24: ONE table here too; the item is c.host and the panel's contents c.items. It
            -- was onChange(host, items, ctx).
            onChange = function(c)
                seen.change = seen.change + 1
                seen.changeHostItem = c.host and c.host.item
                seen.changeHostAddr = c.host and c.host.addr
                seen.changeItems = c.items
            end,
        })

        if not registered then
            skip('RegisterPanelItem refused the fixture — cannot test the hooks')
        end

        local p = exports.whip_core:GetPlayer(source)
        assertNotNil(p, 'setup: GetPlayer')
        ctx.charId = p.charId
        RemoveAllOf(source, CARGO)
        RemoveAllOf(source, BANNED)
        RemoveAllOf(source, HOST)
    end,

    teardown = function(ctx, source)
        if not source then return end
        pcall(closePanel, source)
        pcall(closePanel, source, PLAIN_ACTION)
        pcall(closePanel, source, BROKEN_ACTION)
        RemoveAllOf(source, CARGO)
        RemoveAllOf(source, BANNED)
        RemoveAllOf(source, HOST)
        RemoveAllOf(source, PLAIN)
        RemoveAllOf(source, BROKEN)
    end,

    tests = {
        {
            name = 'Hooks SURVIVE the export boundary',
            fn = function(source, ctx)
                -- The question the whole design rests on. The hooks are functions nested in a
                -- config table passed across a resource boundary, and whip_core's own source
                -- warns about "function-in-table stripping". If read() never runs, the
                -- functions did not make the crossing and the API needs a different shape —
                -- every other test here would then be failing for a reason that has nothing to
                -- do with its own subject.
                SeedSlot(source, 'player', SLOT, HOST, 1)
                resetSeen()

                openAndName(source)

                assertTrue(seen.read > 0,
                    'read() never ran — the hook functions did not survive the export boundary')
                assertEqual(seen.lastHostItem, HOST,
                    'read() received the HOST item, not something else')

                closePanel(source)
            end,
        },
        {
            name = 'An empty host opens an empty panel',
            fn = function(source, ctx)
                SeedSlot(source, 'player', SLOT, HOST, 1)
                local pid = openAndName(source)

                -- NAMED, and required to be a table. `GetPanelItems(source) or {}` read as an
                -- empty panel both when the panel never opened and when two were open (the
                -- unqualified form answered nil for both) — so this passed on either failure.
                -- (09-24: read by id through StoreRead; GetPanelItems was removed.)
                local items = panelItems(pid)
                assertType(items, 'table', 'the panel answered with its contents')
                assertNil(items[1], 'a host with no cargo shows nothing')

                closePanel(source)
            end,
        },
        {
            name = 'write() folds the panel into the host CUSTOM shape',
            fn = function(source, ctx)
                -- The projection. A slot array would have been stored at meta.slots by the old
                -- path whether or not write() ran; meta.cargo can only exist if it did.
                SeedSlot(source, 'player', SLOT, HOST, 1)
                local pid = openAndName(source)

                giveToPanel(pid, CARGO, 3)
                resetSeen()
                closePanel(source)

                assertTrue(seen.write > 0, 'write() ran on close')

                local meta = hostMeta(source)
                assertNotNil(meta, 'host still exists')
                assertNotNil(meta.cargo, 'contents were folded into meta.cargo, the custom shape')
                assertEqual(meta.cargo.item, CARGO, 'cargo item recorded')
                assertEqual(meta.cargo.count, 3, 'cargo count recorded')
                assertNil(meta.slots,
                    'a declared write() must REPLACE the storageKey path, not run alongside it')
            end,
        },
        {
            name = 'read() restores what write() stored — a full round trip',
            fn = function(source, ctx)
                -- Store, close, reopen. If the two hooks disagree about the shape, this is
                -- where an item quietly disappears.
                SeedSlot(source, 'player', SLOT, HOST, 1)
                local pid = openAndName(source)
                giveToPanel(pid, CARGO, 4)
                closePanel(source)

                pid = openAndName(source)
                local items = panelItems(pid) or {}
                assertNotNil(items[1], 'the contents came back')
                assertEqual(items[1].item, CARGO, 'same item')
                assertEqual(items[1].amount, 4, 'same amount')

                closePanel(source)
            end,
        },
        {
            -- Renamed from "survives a save and reload": nothing is reloaded, and the claim that
            -- matters is narrower and testable — the fold lands in the host's ROW.
            name = 'Closing folds the contents into the host row ON DISK',
            fn = function(source, ctx)
                -- Panels hold items outside any store, so "it is in the session table" and
                -- "it is on disk" are very different facts. The host item carries the cargo,
                -- so the host's own row is what has to contain it.
                SeedSlot(source, 'player', SLOT, HOST, 1)
                local pid = openAndName(source)
                giveToPanel(pid, CARGO, 2)
                closePanel(source)

                local stored = storedHostMeta(ctx.charId)
                assertNotNil(stored, 'the host row is on disk')
                assertNotNil(stored.cargo, 'the cargo reached the database')
                assertEqual(stored.cargo.item, CARGO, 'the right item')
                -- 2, and no other test here uses 2 — a row left over from the test before
                -- (same slot, 4) cannot pass for this one.
                assertEqual(stored.cargo.count, 2, 'THIS fold, not an earlier one')

                -- And the row is THIS host's, not a previous one that happened to sit in the slot.
                local live = hostMeta(source) or {}
                if live.uid then
                    assertEqual(stored.uid, live.uid, 'the row on disk is the host in the pocket now')
                end
            end,
        },
        {
            name = 'Contents are on disk while the panel is STILL OPEN',
            fn = function(source, ctx)
                -- The hole write-on-change closed. Before it, an item dragged into a panel had
                -- left the inventory (persisted) and existed ONLY in the session table — so
                -- losing the server with the screen up lost the item, and the window was
                -- however long someone left it up.
                --
                -- Nothing is closed here, deliberately. Close it and this test passes under the
                -- old behaviour too, and proves nothing.
                SeedSlot(source, 'player', SLOT, HOST, 1)
                local pid = openAndName(source)
                giveToPanel(pid, CARGO, 6)

                local stored = storedHostMeta(ctx.charId)
                assertNotNil(stored, 'the host row is on disk')
                assertNotNil(stored.cargo, 'the contents are durable WITHOUT the panel closing')
                assertEqual(stored.cargo.count, 6, 'and they are THIS update\'s contents')

                closePanel(source)
            end,
        },
        {
            name = 'A player DRAG folds into the host immediately',
            fn = function(source, ctx)
                -- StoreGive above is the server-initiated path (UpdatePanelSlot until 09-24). This
                -- is the one a player actually takes, and it lands somewhere completely different
                -- in whip_core — the panel kind's afterMove. Both have to fold, or the same panel is
                -- durable or not depending on who moved the item.
                SeedSlot(source, 'player', SLOT, HOST, 1)
                SeedSlot(source, 'player', 7, CARGO, 3)
                local pid = openAndName(source)
                resetSeen()

                ClientExecWait(source, 'whip_core:server:storeMove', 3000,
                    { kind = 'player', slot = 7 },
                    { kind = 'panel', id = pid, slot = 1 },
                    2, 'move', 0)

                assertLastReject('whip_core:server:storeMove', nil, 'the drag was accepted')
                local items = panelItems(pid) or {}
                assertNotNil(items[1], 'the drag reached the panel')
                assertEqual(items[1].amount, 2, 'the requested amount moved')

                -- Still open. The host must already know.
                local meta = hostMeta(source)
                assertNotNil(meta and meta.cargo,
                    'the drag was folded into the host before any close')
                assertEqual(meta.cargo.count, 2, 'and folded the right amount')
                assertTrue(seen.change > 0, 'onChange fired for the drag')

                -- 09-24: onChange takes one ctx. The host and the contents are fields of it now, so
                -- check they arrived: the old (host, items, ctx) arguments are what this replaced.
                assertEqual(seen.changeHostItem, HOST, 'onChange was handed the host as ctx.host')
                assertEqual(seen.changeItems and seen.changeItems[1] and seen.changeItems[1].amount, 2,
                    'and the panel contents after the move as ctx.items')

                -- host.addr is a real address: the address calls find the host there.
                assertType(seen.changeHostAddr, 'table', 'ctx.host carries its address')
                local atAddr = seen.changeHostAddr and exports.whip_core:GetItemAt(seen.changeHostAddr)
                assertEqual(atAddr and atAddr.item, HOST, 'GetItemAt(ctx.host.addr) is the host')

                closePanel(source)
            end,
        },
        {
            name = 'onValidate REFUSES a move, and its reason reaches the player',
            fn = function(source, ctx)
                -- The rule allowedItems cannot express, and the reason that used to be thrown
                -- away: every rejection reached the player as a generic "Move rejected" until
                -- beforeMove started propagating a second return value.
                SeedSlot(source, 'player', SLOT, HOST, 1)
                SeedSlot(source, 'player', 7, BANNED, 2)
                local pid = openAndName(source)
                resetSeen()

                ClientExecWait(source, 'whip_core:server:storeMove', 3000,
                    { kind = 'player', slot = 7 },
                    { kind = 'panel', id = pid, slot = 1 },
                    1, 'move', 0)

                assertTrue(seen.validate > 0, 'onValidate ran')
                -- 09-24: onValidate takes one ctx; the host it judges by is ctx.host.
                assertEqual(seen.validateHostItem, HOST, 'onValidate was handed the host as ctx.host')

                local items = panelItems(pid) or {}
                assertNil(items[1], 'the refused item did NOT enter the panel')
                assertEqual(exports.whip_core:GetItemCount(source, BANNED), 2,
                    'and it is still in the inventory — refused, not eaten')

                -- Asserted hard, and EXACTLY. Until beforeMove began propagating a second
                -- return value, EVERY refusal reached the player as a generic "Move rejected"
                -- — and a test that tolerated a missing reason would never have noticed.
                assertLastReject('whip_core:server:storeMove', 'Contraband does not fit',
                    'the refusal carried onValidate\'s own reason')

                closePanel(source)
            end,
        },
        {
            name = 'A host with NO hooks still behaves exactly as before',
            fn = function(source, ctx)
                -- The backwards-compatibility guarantee. Every hook is optional, and a wallet
                -- registered before any of this existed must be untouched: contents in a plain
                -- slot array at meta[storageKey], no read/write involved.
                exports.whip_core:RegisterItem(PLAIN, {
                    name = 'Plain Panel', desc = 'no hooks',
                    weight = 1.0, type = 'misc', stack = false, maxStack = 1,
                    defaultAction = PLAIN_ACTION,
                })
                assertTrue(exports.whip_core:RegisterPanelItem(PLAIN, { slots = 2 }),
                    'a hookless registration is still accepted')

                RemoveAllOf(source, PLAIN)
                SeedSlot(source, 'player', 8, PLAIN, 1)

                assertTrue(ClientExecWait(source, 'whip_core:server:customContextAction', 3000,
                    PLAIN_ACTION, 'player', 8), 'the context action was answered')
                local pid = panelIdFor(source, PLAIN_ACTION)
                assertNotNil(pid, 'the plain panel actually opened')
                giveToPanel(pid, CARGO, 1)
                closePanel(source, PLAIN_ACTION)

                -- THE CONTENTS, not the key. A hookless registration installs a metadata generator
                -- that gives every such item `slots = {}` the moment it is created — so "meta.slots
                -- exists" was true from birth, and this assertion passed whether or not the close
                -- wrote anything at all.
                -- (09-24: GetItemAt by address; GetSlotData was removed.)
                local d = exports.whip_core:GetItemAt(PocketAddr(source, 'player', 8))
                local meta = d and d.metadata or {}
                local first = type(meta.slots) == 'table' and meta.slots[1] or nil
                assertNotNil(first, 'with no write() declared, the contents landed in the storageKey array')
                assertEqual(first.item, CARGO, 'the right item')
                assertEqual(first.amount, 1, 'the right amount')
            end,
        },
        {
            -- A BROKEN write() BLOCKS A MOVE; IT DOES NOT CORRUPT ONE (Josh, 27 Sep 2026: "this framework
            -- is for everyone else who is going to create with whip"). The write() folded the panel into
            -- its item AFTER the move had landed, so one that errored left the move standing and the
            -- item not knowing — a copy on every reopen, or a loss. It is tried on the result first now.
            name = 'A panel item whose write() errors refuses the drag, and nothing moves',
            fn = function(source, ctx)
                exports.whip_core:RegisterItem(BROKEN, {
                    name = 'Broken Panel', desc = 'write() errors', weight = 1.0, type = 'misc',
                    stack = false, maxStack = 1, defaultAction = BROKEN_ACTION,
                })
                assertTrue(exports.whip_core:RegisterPanelItem(BROKEN, {
                    slots = 1, label = 'Broken Fixture',
                    write = function() error('this write() is broken on purpose (whip_test 30)') end,
                }), 'registered with a write() that always errors')

                RemoveAllOf(source, BROKEN)
                RemoveAllOf(source, CARGO)
                SeedSlot(source, 'player', 8, BROKEN, 1)
                SeedSlot(source, 'player', 7, CARGO, 3)
                assertTrue(ClientExecWait(source, 'whip_core:server:customContextAction', 3000,
                    BROKEN_ACTION, 'player', 8), 'the context action was answered')
                local pid = panelIdFor(source, BROKEN_ACTION)
                assertNotNil(pid, 'the broken panel opened')

                ClientExecWait(source, 'whip_core:server:storeMove', 3000,
                    { kind = 'player', slot = 7 }, { kind = 'panel', id = pid, slot = 1 }, 2, 'move', 0)
                local why = exports.whip_core:__TestLastReject('whip_core:server:storeMove')
                local items = panelItems(pid) or {}
                closePanel(source, BROKEN_ACTION)

                assertTrue(type(why) == 'string' and why:find('could not take that', 1, true) ~= nil,
                    'the drag was refused, saying the item could not take it (got: ' .. tostring(why) .. ')')
                assertNil(items[1], 'nothing entered the panel')
                assertEqual(exports.whip_core:GetItemCount(source, CARGO), 3, 'all 3 are still in the pockets')
            end,
        },
    },
})
