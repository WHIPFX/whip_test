-- ============================================
-- Registry & Security (2026-09-24) — section 5 of the API TODO
--
-- What this proves, through the same exports a resource uses (whip_test IS a satellite):
--
--   * REG-1  the one registration rule: whip_core's names cannot be taken, the same thing again is
--            fine, GetRegistrations says who holds what
--   * SEC-1  an event or callback name belongs to its first registrant; 'whip_core:' is reserved
--   * SEC-2  a satellite's TrackInvocationLock really releases on an error, with and without the name
--   * SEC-3  near.at as a fixed position, a table, 'vehicle'; no position REFUSES; allowUnknown
--   * SEC-4  the 'slot' and 'list' param types, and a satellite's 'addr' as an address
--   * SEC-6  SecureEvent / SecureCallback answer true
--   * REG-2  onReady says why it fired
--   * REG-3  lib/satellite.lua (whip_test includes it): Whip.call, Whip.isReady
--   * EVT-2  item events under their new name, one table — and the old name still fires
--
-- Not here, because they need a second resource or a restart: another satellite being refused a
-- name whip_test holds, and a stopped resource's names coming free. The Registry's own rules for
-- those are proved by the scratch harness registry_harness.lua (22 cases).
-- ============================================

local ITEM  = '_test_t46'
local ITEM2 = '_test_t46_other'

local _ran      = {}   -- [event] = how many times its handler ran
local _got      = {}   -- [event] = what its handler was handed
local _released = 0    -- TrackInvocationLock releases that ran
local _tracked  = {}   -- [event] = what TrackInvocationLock answered inside the handler

local function resetRan(name) _ran[name], _got[name] = 0, nil end

local function recorder(name)
    return function(src, player, value)
        _ran[name] = (_ran[name] or 0) + 1
        _got[name] = value
    end
end

--- Fire an event from the tester's client and wait for the SERVER's answer (see 10_secure).
local function fire(source, eventName, ...)
    assertTrue(ClientExecWait(source, eventName, 3000, ...), ('%s: the server answered'):format(eventName))
end

--- The last onReady payload whip_test heard. File scope: it has to be listening before any fire.
local _lastReady = nil
AddEventHandler('whip_core:onReady', function(info) _lastReady = info end)

--- Item events heard, for our item only (EVT-2).
local _itemEvents = {}
AddEventHandler('whip_core:item:added', function(e)
    if type(e) == 'table' and e.item == ITEM then _itemEvents[#_itemEvents + 1] = { name = 'new', e = e } end
end)

--- Whether a registration is listed as whip_test's.
local function listed(registry, key)
    for _, r in ipairs(exports.whip_core:GetRegistrations('whip_test') or {}) do
        if r.registry == registry and r.key == key then return true end
    end
    return false
end

RegisterTestModule({
    order    = 46,
    category = 'Registry & Security',

    setup = function(source, ctx)
        local p = exports.whip_core:GetPlayer(source)
        if not p then skip('no player loaded') end

        assertOk(exports.whip_core:RegisterItem(ITEM, { name = 'T46', weight = 0.1, type = 'misc', stack = true, maxStack = 10 }))
        assertOk(exports.whip_core:RegisterItem(ITEM2, { name = 'T46 Other', weight = 0.1, type = 'misc', stack = true, maxStack = 10 }))
        RemoveAllOf(source, ITEM)
        RemoveAllOf(source, ITEM2)

        -- Two free-ish slots near the end of the main pockets, for the 'slot' tests.
        local slots = exports.whip_core:GetPocketSlots('player')
        ctx.slotFull, ctx.slotEmpty = slots, slots - 1
        exports.whip_core:StoreTake(PocketAddr(source, 'player', ctx.slotEmpty))

        -- SEC-3: a spot at the tester, one far away, and a car beside them.
        local pos = GetEntityCoords(GetPlayerPed(source))
        ctx.pos = pos

        local okA = exports.whip_core:SecureEvent('_t46_near_vec', {
            rateLimit = false, near = { at = vector3(pos.x, pos.y, pos.z), range = 8.0, message = false },
        }, recorder('_t46_near_vec'))
        assertTrue(okA == true, 'SecureEvent answers true (SEC-6)')

        exports.whip_core:SecureEvent('_t46_near_table', {
            rateLimit = false, near = { at = { pos.x + 400.0, pos.y, pos.z }, range = 8.0, message = false },
        }, recorder('_t46_near_table'))
        exports.whip_core:SecureEvent('_t46_near_unknown', {
            rateLimit = false,
            near = { at = function() return nil end, range = 8.0, message = false, allowUnknown = true },
        }, recorder('_t46_near_unknown'))
        exports.whip_core:SecureEvent('_t46_near_vehicle', {
            rateLimit = false,
            near = { at = 'vehicle', range = 8.0, message = false },
            params = { { 'v', 'vehicle', { session = true } } },
        }, recorder('_t46_near_vehicle'))

        -- SEC-4
        exports.whip_core:SecureEvent('_t46_slot', {
            rateLimit = false, params = { { 's', 'slot', { item = ITEM } } },
        }, recorder('_t46_slot'))
        exports.whip_core:SecureEvent('_t46_list', {
            rateLimit = false,
            params = { { 'basket', 'list', { { 'slot', 'id', 1, 50 }, { 'index', 'int', -1, 99 } }, 3 } },
        }, recorder('_t46_list'))
        exports.whip_core:SecureEvent('_t46_addr', {
            rateLimit = false, params = { { 'a', 'addr' } },
        }, recorder('_t46_addr'))

        -- SEC-2: handlers that take a "lock" and then error.
        exports.whip_core:SecureEvent('_t46_lock_named', { rateLimit = false }, function(src)
            _tracked._t46_lock_named = exports.whip_core:TrackInvocationLock(function()
                _released = _released + 1
            end, '_t46_lock_named', src)
            error('[EXPECTED] whip_test 46 is deliberately erroring after taking a lock')
        end)
        exports.whip_core:SecureEvent('_t46_lock_bare', { rateLimit = false }, function(src)
            _tracked._t46_lock_bare = exports.whip_core:TrackInvocationLock(function()
                _released = _released + 1
            end)
            error('[EXPECTED] whip_test 46 is deliberately erroring after taking a lock')
        end)
        exports.whip_core:SecureEvent('_t46_lock_kept', { rateLimit = false }, function(src)
            _tracked._t46_lock_kept = exports.whip_core:TrackInvocationLock(function()
                _released = _released + 1
            end, '_t46_lock_kept', src)
            -- returns normally: the lock is kept
        end)
    end,

    teardown = function(ctx, source)
        if ctx and ctx.tempCar then
            pcall(exports.whip_core.DespawnVehicle, exports.whip_core, ctx.tempCar)
        end
        if source then
            RemoveAllOf(source, ITEM)
            RemoveAllOf(source, ITEM2)
        end
        DbQuery('DELETE FROM `activity_log` WHERE `itemKey` IN (?, ?)', { ITEM, ITEM2 })
    end,

    tests = {
        -- ==========================================
        -- SEC-1 / REG-1: names have owners
        -- ==========================================
        {
            name = "SEC-1: a name starting 'whip_core:' is refused to another resource",
            fn = function()
                local ok, err = exports.whip_core:SecureEvent('whip_core:server:_t46_takeover', {}, function() end)
                assertFalse(ok, 'refused')
                assertTrue(tostring(err):find('reserved', 1, true) ~= nil, ('says it is reserved (got "%s")'):format(tostring(err)))

                -- An existing core event, the one every inventory drag goes through.
                local ok2, err2 = exports.whip_core:SecureEvent('whip_core:server:storeMove', {}, function() end)
                assertFalse(ok2, 'storeMove cannot be taken over')
                assertNotNil(err2, 'with a reason')
            end,
        },
        {
            name = "SEC-1: another resource's callback is refused, naming its owner",
            fn = function()
                -- The ownership rule, not the reserved one. It used to be tried on 'atm:deposit', a
                -- whip_core callback with no prefix; since audit 5 (ARC-7) every whip_core callback is
                -- 'whip_core:'-prefixed and the reserved rule above covers them, so a satellite's is
                -- used instead.
                if GetResourceState('whip_gunny') ~= 'started' then skip('needs whip_gunny running') end
                local ok, err = exports.whip_core:SecureCallback('whip_gunny:unloadBulletsFromMag', {}, function() return true end)
                assertFalse(ok, 'refused')
                assertTrue(tostring(err):find('belongs to whip_gunny', 1, true) ~= nil,
                    ('names the owner (got "%s")'):format(tostring(err)))
            end,
        },
        {
            name = 'ARC-7: a whip_core callback is whip_core:-prefixed, so the reserved rule refuses it',
            fn = function()
                local ok, err = exports.whip_core:SecureCallback('whip_core:atm:deposit', {}, function() return true end)
                assertFalse(ok, 'refused')
                assertTrue(tostring(err):find('reserved', 1, true) ~= nil,
                    ('says it is reserved (got "%s")'):format(tostring(err)))
            end,
        },
        {
            name = 'SEC-1: registering your own event again replaces the handler',
            fn = function(source)
                resetRan('_t46_replace_a'); resetRan('_t46_replace_b')
                assertTrue(exports.whip_core:SecureEvent('_t46_replace', { rateLimit = false }, recorder('_t46_replace_a')) == true,
                    'first registration answers true')
                assertTrue(exports.whip_core:SecureEvent('_t46_replace', { rateLimit = false }, recorder('_t46_replace_b')) == true,
                    'the second answers true too')
                fire(source, '_t46_replace')
                assertEqual(_ran._t46_replace_a, 0, 'the old handler did not run')
                assertEqual(_ran._t46_replace_b, 1, 'the new one did')
                assertTrue(listed('SecureEvent', '_t46_replace'), 'GetRegistrations lists it as whip_test\'s')
            end,
        },
        {
            name = 'REG-1: the same item definition again is fine; whip_core\'s items are not ours to change',
            fn = function()
                local def = { name = 'T46', weight = 0.1, type = 'misc', stack = true, maxStack = 10 }
                local ok, err = exports.whip_core:RegisterItem(ITEM, def)
                assertOk(ok, err, 'the same definition again')
                assertTrue(listed('Item', ITEM), 'GetRegistrations lists the item as whip_test\'s')
                -- (whip_core's own items refusing us: 09_items. Its context actions: 43_inventory_api.)
            end,
        },
        {
            name = 'REG-1: an ignition key is shared — joining whip_core\'s own key is fine',
            fn = function()
                local ok, err = exports.whip_core:RegisterIgnitionKey('vehicle_key')
                assertOk(ok, err, 'vehicle_key again, from whip_test')
                assertTrue(listed('IgnitionKey', 'vehicle_key'), 'held by whip_test as well as whip_core')
            end,
        },
        {
            name = 'REG-1: ZoneRemove only removes your own zones',
            fn = function()
                local ok, err = exports.whip_core:ZoneRemove('_t46_never_registered')
                assertFalse(ok, 'a zone we never registered is not ours to remove')
                assertNotNil(err, 'with a reason')
            end,
        },
        {
            name = 'REG-1: SetActiveTheme — clearing nothing is fine, and our own override can be set and cleared',
            fn = function()
                -- The name is a resource that does not exist, so every client fails soft to the base
                -- look (html/js/theme.js) — nothing visible changes.
                -- If another resource's skin is active the first two answers are refusals, and that
                -- is the rule working — so this only runs on a server with no runtime skin.
                local before = exports.whip_core:GetRegistrations()
                for _, r in ipairs(before or {}) do
                    if r.registry == 'Theme' and r.owner ~= 'whip_test' then
                        skip('a runtime skin (' .. tostring(r.owner) .. ') holds the theme override')
                    end
                end

                local ok, err = exports.whip_core:SetActiveTheme(nil)
                assertOk(ok, err, 'clearing when nothing is set')
                ok, err = exports.whip_core:SetActiveTheme('_t46_no_such_theme')
                assertOk(ok, err, 'setting our own')
                assertTrue(listed('Theme', 'active'), 'the override is listed as whip_test\'s')
                ok, err = exports.whip_core:SetActiveTheme(nil)
                assertOk(ok, err, 'clearing our own')
            end,
        },

        -- ==========================================
        -- SEC-2: satellite locks
        -- ==========================================
        {
            name = 'SEC-2: a lock a satellite handler tracks is released when the handler errors',
            fn = function(source)
                _released = 0
                -- Both handlers print a stack trace: EXPECTED output from this test.
                fire(source, '_t46_lock_named')
                assertTrue(_tracked._t46_lock_named == true, 'TrackInvocationLock with the name answered true')
                assertEqual(_released, 1, 'and the release ran when the handler errored')

                fire(source, '_t46_lock_bare')
                assertTrue(_tracked._t46_lock_bare == true, 'without the name it found our one running handler')
                assertEqual(_released, 2, 'and released that one too')
            end,
        },
        {
            name = 'SEC-2: a handler that returns normally keeps its lock; outside a handler nothing attaches',
            fn = function(source)
                _released = 0
                fire(source, '_t46_lock_kept')
                assertTrue(_tracked._t46_lock_kept == true, 'tracked')
                assertEqual(_released, 0, 'not released: the handler returned normally')

                local ok, err = exports.whip_core:TrackInvocationLock(function() end)
                assertFalse(ok, 'outside any handler it is refused')
                assertNotNil(err, 'with a reason')
            end,
        },

        -- ==========================================
        -- SEC-3: near
        -- ==========================================
        {
            name = 'SEC-3: near.at as a fixed vector3 and as an {x, y, z} table',
            fn = function(source)
                resetRan('_t46_near_vec'); resetRan('_t46_near_table')
                fire(source, '_t46_near_vec')
                assertEqual(_ran._t46_near_vec, 1, 'at the tester: ran')
                assertLastReject('_t46_near_vec', nil, 'not refused')

                fire(source, '_t46_near_table')
                assertEqual(_ran._t46_near_table, 0, '400 m away: did not run')
                assertLastReject('_t46_near_table', 'Too far away', 'refused as too far')
            end,
        },
        {
            name = 'SEC-3: allowUnknown lets a call through when at finds no position',
            fn = function(source)
                resetRan('_t46_near_unknown')
                fire(source, '_t46_near_unknown')
                assertEqual(_ran._t46_near_unknown, 1, 'ran — the handler decides')
            end,
        },
        {
            name = "SEC-3: near.at = 'vehicle' — beside the car runs",
            fn = function(source, ctx)
                local pos = ctx.pos
                local id, err = exports.whip_core:SpawnTempVehicle('asea',
                    vector4(pos.x + 4.0, pos.y, pos.z, 0.0), { plate = 'T46NEAR' })
                assertOk(id, err, 'SpawnTempVehicle beside the tester')
                ctx.tempCar = id

                resetRan('_t46_near_vehicle')
                fire(source, '_t46_near_vehicle', id)
                assertEqual(_ran._t46_near_vehicle, 1, 'beside the car: ran')
                assertEqual(_got._t46_near_vehicle and _got._t46_near_vehicle.vehicleId, id, 'handed the car')
            end,
        },

        -- ==========================================
        -- SEC-4: param types
        -- ==========================================
        {
            name = "SEC-4: 'slot' hands over the address and a copy; refuses the wrong item and an empty slot",
            fn = function(source, ctx)
                SeedSlot(source, 'player', ctx.slotFull, ITEM, 3)
                resetRan('_t46_slot')

                fire(source, '_t46_slot', ctx.slotFull)
                local s = _got._t46_slot
                assertEqual(_ran._t46_slot, 1, 'ran for our item')
                assertEqual(s and s.item, ITEM, 'handed the item')
                assertEqual(s and s.amount, 3, 'and the amount')
                assertEqual(s and s.addr and s.addr.slot, ctx.slotFull, 'and its address')
                assertEqual(s and s.addr and s.addr.sub, 'player', 'in the main pockets')

                fire(source, '_t46_slot', ctx.slotEmpty)
                assertEqual(_ran._t46_slot, 1, 'an empty slot did not run')
                assertLastReject('_t46_slot', 's: that slot is empty', 'refused as empty')

                SeedSlot(source, 'player', ctx.slotFull, ITEM2, 1)
                fire(source, '_t46_slot', { sub = 'player', slot = ctx.slotFull })
                assertEqual(_ran._t46_slot, 1, 'the wrong item did not run')
                assertLastReject('_t46_slot', 's: not the right item', 'refused as the wrong item')
            end,
        },
        {
            name = "SEC-4: 'list' checks every entry, keeps only declared fields, and caps the length",
            fn = function(source)
                resetRan('_t46_list')
                fire(source, '_t46_list', { { slot = 1, index = 2, extra = 'x' }, { slot = 4, index = -1 } })
                local b = _got._t46_list
                assertEqual(_ran._t46_list, 1, 'a good list ran')
                assertEqual(b and #b, 2, 'two entries')
                assertNil(b and b[1] and b[1].extra, 'an undeclared field was dropped')

                fire(source, '_t46_list', { { slot = 1, index = 2 }, { slot = 0, index = 1 } })
                assertEqual(_ran._t46_list, 1, 'a bad entry refused the call')
                assertLastReject('_t46_list', 'basket[2].slot: invalid id', 'naming the entry')

                fire(source, '_t46_list', { { slot = 1, index = 1 }, { slot = 1, index = 1 }, { slot = 1, index = 1 }, { slot = 1, index = 1 } })
                assertLastReject('_t46_list', 'basket: at most 3 entries', 'over the cap refused')
            end,
        },
        {
            name = "SEC-4: a satellite's 'addr' param is an address and a copy, never whip's store",
            fn = function(source, ctx)
                SeedSlot(source, 'player', ctx.slotFull, ITEM, 2)
                resetRan('_t46_addr')
                fire(source, '_t46_addr', { kind = 'player', slot = ctx.slotFull })
                local a = _got._t46_addr
                assertEqual(_ran._t46_addr, 1, 'ran')
                assertNil(a and a.store, 'no store object')
                assertEqual(a and a.addr and a.addr.slot, ctx.slotFull, 'the address')
                assertEqual(a and a.item, ITEM, 'and what is in it')
            end,
        },

        -- ==========================================
        -- REG-2, REG-3, EVT-2
        -- ==========================================
        {
            name = 'REG-2: onReady says why it fired',
            fn = function()
                assertType(_lastReady, 'table', 'the last onReady carried a table')
                local r = _lastReady and _lastReady.reason
                assertTrue(r == 'coreStarted' or r == 'resourceStarted', ('with a reason (got %s)'):format(tostring(r)))
                if r == 'resourceStarted' then
                    assertType(_lastReady.resources, 'table', 'and which resources started')
                end
            end,
        },
        {
            name = 'REG-3: the satellite helper — Whip.isReady and Whip.call',
            fn = function()
                assertNotNil(Whip, "whip_test includes '@whip_core/lib/satellite.lua'")
                assertTrue(Whip.isReady(), 'whip_core is ready')
                local pockets = Whip.call('GetPockets')
                assertType(pockets, 'table', 'Whip.call returns what the export returns')
                local ok, err = Whip.call('_t46_no_such_export')
                assertFalse(ok, 'a call that throws answers false')
                assertNotNil(err, 'with a reason, instead of an error in our code')
            end,
        },
        {
            -- WHERE NOTHING CAN WAIT (audit 7, SEC-4 / DX-1). Whip.call's "it STARTED" answer for a
            -- waiting export could never be reached: FiveM's export call waits by itself and throws
            -- "attempt to yield" before Whip.call saw the export's answer, so the caller heard
            -- "failed" while the export ran on. A sort comparator is such a place.
            name = 'Whip.call where nothing can wait: a plain export answers, a waiting one says it STARTED',
            fn = function(source)
                local plain, waited, why
                table.sort({ 2, 1 }, function(a, b)
                    if plain == nil then
                        plain = Whip.call('GetPockets') or false
                        waited, why = Whip.call('Progress', source, { label = '[TEST] started, not waited for', duration = 400 })
                    end
                    return a < b
                end)
                Wait(900)   -- the bar runs on in whip_core; let it end before the next test
                assertType(plain, 'table', 'a plain export answers as usual')
                assertFalse(waited, 'a waiting export cannot answer here')
                assertTrue(tostring(why):find('STARTED', 1, true) ~= nil,
                    ('and says it started, not that it failed (got "%s")'):format(tostring(why)))
            end,
        },
        {
            name = 'EVT-2: item:added fires with one table',
            fn = function(source)
                RemoveAllOf(source, ITEM)
                local from = #_itemEvents
                -- The reason goes FIFTH; the fourth is metadata. (This test first passed it fourth —
                -- which AddItem now refuses, rather than storing a string as the item's metadata.)
                local bad, badErr = exports.whip_core:AddItem(source, ITEM, 1, 'whip_test 46')
                assertFalse(bad, 'a string where the metadata goes is refused')
                assertNotNil(badErr, 'saying where the reason goes')

                assertOk(exports.whip_core:AddItem(source, ITEM, 2, nil, 'whip_test 46'))
                local seen = waitFor(function()
                    for i = from + 1, #_itemEvents do
                        if _itemEvents[i].name == 'new' then return true end
                    end
                    return nil
                end, 3000)
                assertTrue(seen == true, 'item:added fired')

                local newE
                for i = from + 1, #_itemEvents do
                    if _itemEvents[i].name == 'new' then newE = _itemEvents[i].e end
                end
                assertEqual(newE and newE.source, source, 'the table has the source')
                assertEqual(newE and newE.amount, 2, 'how many arrived')
                -- The caller's words alone; who asked is `by`. (The first run got the log line,
                -- 'whip_test 46 · by whip_test' — Inventory.noteChangeReason takes it apart now.)
                assertEqual(newE and newE.reason, 'whip_test 46', 'and the reason, in the caller\'s own words')
                assertEqual(newE and newE.by, 'by whip_test', 'and who asked, separately')
            end,
        },
    },
})
