-- ============================================
-- RegisterStoreKind — the satellite-facing store API
--
-- WHY THIS MODULE EXISTS
--
-- RegisterStoreKind (exported as DefineStoreKind until 09-24, when that name was removed) is how
-- a satellite gives whip a kind of storage whip has never heard of: a fuel pump's tank, a
-- evidence locker, a drug press's hopper. It is the single widest extension
-- point in the framework — whatever is defined here becomes addressable by the same moves,
-- hooks and persistence as a stash — and it had NO tests at all.
--
-- THE FAILURE MODE IT WAS WRITTEN AGAINST IS NOT HYPOTHETICAL
--
-- Every function in a kind definition crosses a resource export boundary, and FiveM does not
-- carry a Lua `function` across: it arrives as a callable whose `type()` is something else.
-- whip_core's own source records what that cost — the guard here used to check the type and so
-- rejected EVERY satellite kind with "missing required function 'resolve'" while resolve was
-- sitting right there in the table.
--
-- That is exactly the bug a test written inside whip_core cannot catch, because a kind defined
-- in whip_core never crosses a boundary. It has to be defined from another resource. This
-- module is another resource.
--
-- THE KIND DEFINED HERE OUTLIVES THE MODULE, deliberately. Kinds are dropped when their owning
-- resource stops (whip_core watches onResourceStop), and there is no undefine — so `_test_kind`
-- stays registered until whip_test restarts. It resolves only ids this file put in `boxes`,
-- which is emptied in teardown, so a stale kind cannot resolve anything.
-- ============================================

local KIND = '_test_kind'
local ITEM = '_test_kind_item'
local SLOT = 8

--- The backing storage this kind is a view of. A real satellite would have a database table or
--- an entity's state bag; the shape does not matter, which is the point of the API.
local boxes = {}

--- A complete, valid definition. Built fresh each time so a test can break one field without
--- the next test inheriting the damage.
--- ############################################################################
--- THE HANDLE CARRIES AN ID, NEVER A LIVE TABLE. This is the trap in the whole API.
---
--- `resolve` runs in THIS resource and its return value crosses the export boundary back into
--- whip_core, so FiveM COPIES it. A handle built as `{ id = id, box = boxes[id] }` therefore
--- hands whip_core a copy of the box — and when whip_core later calls `set(h, ...)`, `h` is
--- copied again on the way in, so the write lands in a copy of a copy. The satellite's real
--- storage is never touched.
---
--- It fails silently and it loses items: the move reports success, the item leaves the player,
--- and nothing arrives. That is exactly what this module's first run did.
---
--- The working shape is the one below — the handle is an identifier, and `get`/`set`/`clear`
--- look their own storage up from it. Those three run inside this resource, where `boxes` is
--- the real table, so their reads and writes are real.
--- ############################################################################
local function definition(overrides)
    local def = {
        resolve = function(key)
            if type(key) ~= 'table' then return nil end
            local id = tostring(key.id or '')
            if not boxes[id] then return nil end
            -- An id, and nothing else. See the note above.
            return { id = id }
        end,

        instanceId = function(_, h) return KIND .. ':' .. h.id end,
        unitKey    = function(_, h) return KIND .. ':' .. h.id end,
        label      = function(_, h) return 'Test Box ' .. h.id end,

        slots     = function(_) return 5 end,
        maxWeight = function(_) return 100.0 end,

        get   = function(h, slot)
            local box = boxes[h.id]
            return box and box.slots[slot] or nil
        end,
        set   = function(h, slot, item, amount, metadata)
            local box = boxes[h.id]
            if not box then return false end
            box.slots[slot] = { item = item, amount = amount, metadata = metadata }
            return true
        end,
        clear = function(h, slot)
            local box = boxes[h.id]
            if box then box.slots[slot] = nil end
        end,
    }

    for k, v in pairs(overrides or {}) do
        -- false means "remove this field", which a nil cannot express in a table literal.
        if v == false then def[k] = nil else def[k] = v end
    end
    return def
end

local function define(overrides, kindId)
    return exports.whip_core:RegisterStoreKind(kindId or KIND, definition(overrides))
end

local function bAddr(id, slot, kind) return { kind = kind or KIND, id = id, slot = slot } end

--- What the client-addressable test kind's authorize() answers. A satellite would decide this
--- from its own state ("does this player have the box open?"); the test just flips it.
local authAllowed = false
local AUTH_KIND = '_test_kind_auth'

--- The player address for the EXPORT, which is server-trusted and therefore takes the server id
--- explicitly rather than inferring one from a caller it does not have. Every pocket read and write
--- in this file goes through it since 09-24 (StoreGive / StoreTake / GetItemAt replaced PlaceItemAt,
--- RemoveItemFromSlot and GetSlotData), built on the runner's PocketAddr.
local function pAddr(src, slot) return PocketAddr(src, 'player', slot) end

RegisterTestModule({
    order    = 36,
    category = 'Store Kinds',

    setup = function(source, ctx)
        exports.whip_core:RegisterItem(ITEM, {
            name = 'Store Kind Fixture', desc = 'store kind fixture',
            weight = 0.1, type = 'misc', stack = true, maxStack = 20,
        })

        boxes['box1'] = { slots = {} }

        -- The player address needs the server id, and the export is server-trusted so it takes
        -- it rather than inferring one.
        ctx.src = source
    end,

    teardown = function(ctx, source)
        boxes = {}
        authAllowed = false
        if source then RemoveAllOf(source, ITEM) end
    end,

    tests = {
        -- ==========================================
        -- Definition validation
        -- ==========================================
        {
            name = 'A complete definition is accepted ACROSS the export boundary',
            fn = function(source, ctx)
                -- The headline test. Every function in the table below arrives here as a
                -- callable rather than a Lua 'function', and a type check on any of them
                -- rejects the whole definition. If this goes red with "missing required
                -- function", the boundary guard has regressed to checking types.
                local ok, err = define()
                assertTrue(ok, 'RegisterStoreKind accepted the definition: ' .. tostring(err))
            end,
        },
        {
            name = 'The SAME resource may redefine its own kind',
            fn = function(source, ctx)
                -- Reloading a satellite in development redefines its kinds. Refusing that
                -- would make every hot reload a restart.
                assertTrue(define(), 'first definition stands')
                local ok, err = define()
                assertTrue(ok, 'redefinition by the owner is allowed: ' .. tostring(err))
            end,
        },
        {
            name = "whip_core's own kind names are reserved",
            fn = function(source, ctx)
                -- Shadowing 'container' would not fail loudly — fromWire has its own branch for
                -- that name, so a satellite kind claiming it would pass its own authorize and
                -- then fall into whip_core's branch anyway. Refusing the name is the only place
                -- that can be caught.
                -- 'accessory' and 'target' are not kinds a satellite would think of as whip's, which
                -- is exactly why they are here: fromWire branches on both names (a pocket, and the
                -- admin inspect path), so a satellite claiming one would fall into that branch.
                for _, reserved in ipairs({ 'player', 'container', 'vehicle', 'panel', 'shop', 'basket',
                                            'accessory', 'target' }) do
                    local ok, err = define(nil, reserved)
                    assertFalse(ok, ('"%s" must be refused'):format(reserved))
                    assertNotNil(err, 'and the refusal says why')
                    assertTrue(tostring(err):lower():find('reserved', 1, true) ~= nil,
                        ('the reason names the problem for "%s" (got "%s")'):format(reserved, tostring(err)))
                end
            end,
        },
        {
            name = 'Every required function is actually required',
            fn = function(source, ctx)
                -- Checked one at a time rather than trusting the list: a guard that loops over
                -- a hardcoded array is exactly the kind that grows a typo and stops checking
                -- one of them, silently.
                for _, required in ipairs({ 'resolve', 'instanceId', 'slots',
                                            'maxWeight', 'get', 'set', 'clear' }) do
                    local ok, err = define({ [required] = false }, '_test_kind_missing')
                    assertFalse(ok, ('a definition without "%s" must be refused'):format(required))
                    assertTrue(tostring(err):find(required, 1, true) ~= nil,
                        ('the error names the missing function (wanted "%s", got "%s")')
                            :format(required, tostring(err)))
                end

                -- unitKey left the list 09-24 (INV-16): left out, it defaults to instanceId, so a
                -- definition without it is ACCEPTED. Its own instance names, so nothing keyed on
                -- them can mistake this kind's boxes for _test_kind's.
                local okU, errU = define({
                    unitKey    = false,
                    instanceId = function(_, h) return '_test_kind_nounit:' .. h.id end,
                }, '_test_kind_nounit')
                assertTrue(okU, 'a definition without unitKey is accepted: ' .. tostring(errU))
            end,
        },
        {
            name = 'Malformed arguments are refused rather than half-registered',
            fn = function(source, ctx)
                local ok1, e1 = exports.whip_core:RegisterStoreKind('', definition())
                assertFalse(ok1, 'an empty kindId is refused')
                assertNotNil(e1, 'with a reason')

                local ok2, e2 = exports.whip_core:RegisterStoreKind('_test_kind_bad', 'not a table')
                assertFalse(ok2, 'a non-table definition is refused')
                assertNotNil(e2, 'with a reason')

                local ok3, e3 = define({ durability = 'occasionally' }, '_test_kind_bad')
                assertFalse(ok3, 'an unknown durability is refused')
                assertTrue(tostring(e3):find('durability', 1, true) ~= nil, 'and says so')

                -- A STRING is definitely not callable, whichever side of an export it came
                -- from — which is why this one case can be checked when "is it a function"
                -- cannot.
                local ok4, e4 = define({ authorize = 'yes please' }, '_test_kind_bad')
                assertFalse(ok4, 'a non-callable authorize is refused')
                assertTrue(tostring(e4):find('authorize', 1, true) ~= nil, 'and says so')
            end,
        },
        {
            name = 'Both durability settings are accepted',
            fn = function(source, ctx)
                assertTrue(define({ durability = 'writeThrough' }, '_test_kind_wt'),
                    'writeThrough accepted')
                assertTrue(define({ durability = 'writeBehind' }, '_test_kind_wb'),
                    'writeBehind accepted')
            end,
        },

        -- ==========================================
        -- The kind actually working
        -- ==========================================
        {
            name = 'An item MOVES into a satellite kind, and the satellite sees it',
            fn = function(source, ctx)
                -- Acceptance is worth little on its own: a kind that registers and then cannot
                -- be moved into is a kind that does not work. This drives a real move through
                -- the public StoreMove export and then asserts against the SATELLITE's own
                -- table — not whip's copy of it — because `set` landing somewhere whip can read
                -- but the owner cannot is the failure that would look fine from inside whip.
                RemoveAllOf(source, ITEM)
                boxes['box1'] = { slots = {} }
                assertTrue(define(), 'kind defined')

                local seeded, seedErr = exports.whip_core:StoreGive(pAddr(source, SLOT), ITEM, 3)
                assertOk(seeded, seedErr, 'seeded the player')

                local ok, err = exports.whip_core:StoreMove(pAddr(source, SLOT), bAddr('box1', 2))
                assertTrue(ok, 'StoreMove into the custom kind: ' .. tostring(err))

                local landed = boxes['box1'].slots[2]
                assertNotNil(landed, "the satellite's own table received the item")
                assertEqual(landed.item, ITEM, 'the right item')
                assertEqual(landed.amount, 3, 'the whole stack')
                assertNil(exports.whip_core:GetItemAt(pAddr(source, SLOT)),
                    'and it left the player')
            end,
        },
        {
            name = 'And moves back OUT again, into the player',
            fn = function(source, ctx)
                -- The return leg exercises `get` and `clear`, which the leg above did not.
                --
                -- Seeded directly rather than leaning on the previous test's leftovers: a test
                -- that starts from its predecessor's end state reports THAT test's failure as
                -- its own, and this file already has enough ways to go red without inventing
                -- another. Writing into `boxes` is what the satellite itself would do.
                RemoveAllOf(source, ITEM)
                pcall(exports.whip_core.StoreTake, exports.whip_core, pAddr(source, SLOT))
                boxes['box1'] = { slots = { [2] = { item = ITEM, amount = 3 } } }
                assertTrue(define(), 'kind defined')

                local ok, err = exports.whip_core:StoreMove(bAddr('box1', 2), pAddr(source, SLOT))
                assertTrue(ok, 'StoreMove out of the custom kind: ' .. tostring(err))

                assertNil(boxes['box1'].slots[2], "the satellite's slot was cleared")
                local back = exports.whip_core:GetItemAt(pAddr(source, SLOT))
                assertNotNil(back, 'the item returned to the player')
                assertEqual(back.amount, 3, 'with the whole stack intact')

                pcall(exports.whip_core.StoreTake, exports.whip_core, pAddr(source, SLOT))
            end,
        },
        {
            name = 'An instance that does not resolve is refused, not invented',
            fn = function(source, ctx)
                -- resolve() answering nil means "this store does not exist right now". Treating
                -- that as an empty store is how an item gets moved into nothing.
                RemoveAllOf(source, ITEM)
                local seeded, seedErr = exports.whip_core:StoreGive(pAddr(source, SLOT), ITEM, 1)
                assertOk(seeded, seedErr, 'seeded the player')

                local ok, err = exports.whip_core:StoreMove(pAddr(source, SLOT), bAddr('no_such_box', 1))

                assertFalse(ok, 'a move into an unresolvable instance is refused')
                assertNotNil(err, 'with a reason')
                assertNotNil(exports.whip_core:GetItemAt(pAddr(source, SLOT)),
                    'and the item never left the player')

                pcall(exports.whip_core.StoreTake, exports.whip_core, pAddr(source, SLOT))
            end,
        },
        {
            name = 'A kind with no authorize() is SERVER-ONLY — a client cannot address it',
            fn = function(source, ctx)
                -- The security half of the API, and the one a satellite author gets wrong by
                -- omission rather than by mistake. Defining a kind must not make it reachable
                -- from a client: whip_core cannot know what "this player has that open" means
                -- for somebody else's storage, so with no authorize the answer is no. (Since 09-24
                -- the one other road in is the server showing it with OpenStore, which makes the
                -- player a viewer; nobody has opened box1 here, so that road is closed.)
                boxes['box1'] = { slots = {} }
                assertTrue(define(), 'kind defined without authorize')

                RemoveAllOf(source, ITEM)
                local seeded, seedErr = exports.whip_core:StoreGive(pAddr(source, SLOT), ITEM, 1)
                assertOk(seeded, seedErr, 'seeded the player')

                -- Straight down the wire, exactly as a modded client would send it.
                assertTrue(ClientExecWait(source, 'whip_core:server:storeMove', 3000,
                    { kind = 'player', slot = SLOT },
                    bAddr('box1', 1),
                    0, 'move', 0), 'the server answered the wire move')

                -- The exact reason: the address was refused at the boundary for being server-only,
                -- not for anything else a refusal might also have been.
                assertLastReject('whip_core:server:storeMove', ('to: store kind "%s" is server-only'):format(KIND),
                    'refused for being server-only')

                assertNil(boxes['box1'].slots[1], 'nothing reached the satellite store')
                assertNotNil(exports.whip_core:GetItemAt(pAddr(source, SLOT)),
                    'and the item is still in the inventory')

                pcall(exports.whip_core.StoreTake, exports.whip_core, pAddr(source, SLOT))
            end,
        },
        {
            name = 'A kind WITH authorize() is reachable from a client exactly when it says yes',
            fn = function(source, ctx)
                -- The other half of the contract above. authorize(src, addr) is the satellite's
                -- answer to "does this player have that open?", and whip_core has to obey it both
                -- ways: a yes lets the drag through to the satellite's own storage, a no stops it
                -- at the boundary with the item still in the pocket.
                boxes['box1'] = { slots = {} }
                -- Its own instance and unit names, so nothing keyed on them (viewers, the write
                -- queue) can mistake this kind's box1 for _test_kind's.
                assertTrue(define({
                    authorize  = function(src, addr) return authAllowed end,
                    instanceId = function(_, h) return AUTH_KIND .. ':' .. h.id end,
                    unitKey    = function(_, h) return AUTH_KIND .. ':' .. h.id end,
                }, AUTH_KIND), 'client-addressable kind defined')

                RemoveAllOf(source, ITEM)
                local seeded, seedErr = exports.whip_core:StoreGive(pAddr(source, SLOT), ITEM, 2)
                assertOk(seeded, seedErr, 'seeded the player')

                authAllowed = false
                assertTrue(ClientExecWait(source, 'whip_core:server:storeMove', 3000,
                    { kind = 'player', slot = SLOT }, bAddr('box1', 1, AUTH_KIND), 0, 'move', 0),
                    'the server answered the refused move')
                assertLastReject('whip_core:server:storeMove',
                    ('to: you do not have that %s open'):format(AUTH_KIND), 'authorize() said no')
                assertNil(boxes['box1'].slots[1], 'nothing reached the satellite store')
                assertNotNil(exports.whip_core:GetItemAt(pAddr(source, SLOT)), 'the item stayed')

                authAllowed = true
                assertTrue(ClientExecWait(source, 'whip_core:server:storeMove', 3000,
                    { kind = 'player', slot = SLOT }, bAddr('box1', 1, AUTH_KIND), 0, 'move', 0),
                    'the server answered the allowed move')
                assertLastReject('whip_core:server:storeMove', nil, 'authorize() said yes')
                local landed = boxes['box1'].slots[1]
                assertNotNil(landed, "the satellite's own table received the item")
                assertEqual(landed.amount, 2, 'the whole stack')
                assertNil(exports.whip_core:GetItemAt(pAddr(source, SLOT)), 'and it left the player')

                authAllowed = false
                boxes['box1'] = { slots = {} }
            end,
        },
        {
            name = 'A set() that throws REFUSES the move and leaves the item where it was',
            fn = function(source, ctx)
                -- A satellite's set runs inside the move. One that errored after the destination
                -- was touched used to throw straight out of the mover with the item half-moved; it
                -- is shielded now, and a throw counts as a refusal the movers undo.
                boxes['box1'] = { slots = {} }
                assertTrue(define({
                    set = function() error('[EXPECTED] whip_test 36_storekind set() is deliberately erroring') end,
                    instanceId = function(_, h) return '_test_kind_throw:' .. h.id end,
                    unitKey    = function(_, h) return '_test_kind_throw:' .. h.id end,
                }, '_test_kind_throw'), 'kind with a throwing set() defined')

                RemoveAllOf(source, ITEM)
                local seeded, seedErr = exports.whip_core:StoreGive(pAddr(source, SLOT), ITEM, 4)
                assertOk(seeded, seedErr, 'seeded the player')

                local ok, err = exports.whip_core:StoreMove(pAddr(source, SLOT), bAddr('box1', 1, '_test_kind_throw'))
                assertFalse(ok, 'the move is refused: ' .. tostring(err))
                local back = exports.whip_core:GetItemAt(pAddr(source, SLOT))
                assertNotNil(back, 'the item is still in the pocket')
                assertEqual(back.amount, 4, 'all of it')
                assertNil(boxes['box1'].slots[1], 'and nothing reached the satellite store')
            end,
        },
    }
})
