-- ============================================
-- Container Lifecycle Tests
-- Create → Open → Place Item → Take Item → Close → Delete
-- ============================================

local _testContainerId = nil

--- Close a container for the tester and wait until the server agrees it is closed.
---@return boolean closed
local function closeAndWait(source, containerId)
    ClientCloseContainer(source, containerId, 3000)
    return waitFor(function()
        return not exports.whip_core:__TestIsViewer(source, 'container:' .. containerId)
    end, 3000) and true or false
end

RegisterTestModule({
    order    = 7,
    category = 'Containers',
    setup = function(source, ctx)
        -- (No food handed out here any more. Every placement below is StoreGive (PlaceItemAt until
        -- 09-24), which CREATES the item in the container — it is not a move from the pockets — so
        -- the five food this used to add were never used, only left behind.)
        local player = exports.whip_core:GetPlayer(source)
        ctx.charId = player.charId
        _testContainerId = nil
    end,
    teardown = function(ctx, source)
        pcall(exports.whip_core.__TestFailNextQuery, exports.whip_core, nil)

        -- EVERY CONTAINER THIS MODULE MADE, not only the main one. The weight and allowed-items
        -- tests used to delete their own containers on their last line, so a failed assertion
        -- left the container in the database — and left it OPEN, which made the client refuse the
        -- next module's first open as well.
        --
        -- AND SAY WHICH ONE WOULD NOT CLOSE. On 09-23 the runner caught a container view still open
        -- after this teardown (container:36599) — but by then the container was deleted, so the
        -- report could not say whether it was the main one, the tiny one or the restricted one.
        -- Naming it here, as a TEARDOWN failure, is what the next run needs to find the cause.
        local stuck = {}
        for _, entry in ipairs({
            { 'main', _testContainerId }, { 'tiny', ctx.tinyId }, { 'restricted', ctx.restrictedId },
            { 'ensured', ctx.ensuredId }, { 'ghost locker', ctx.ghostLockerId },
            { 'alive locker', ctx.aliveLockerId }, { 'card locker', ctx.cardLockerId },
            { 'run box', ctx.runBoxId },
        }) do
            local label, id = entry[1], entry[2]
            if id then
                if source then
                    local ran, closed = pcall(closeAndWait, source, id)
                    if not (ran and closed) then stuck[#stuck + 1] = ('%s #%d'):format(label, id) end
                end
                pcall(exports.whip_core.DeleteContainer, exports.whip_core, id)
            end
        end
        if source then
            RemoveAllOf(source, 'food')
            RemoveAllOf(source, 'drink')
        end
        _testContainerId = nil
        if ctx.ghostCharId then
            pcall(DbQuery, 'DELETE FROM `characters` WHERE `charId` = ?', { ctx.ghostCharId })
        end
        if ctx.aliveCharId then
            pcall(DbQuery, 'DELETE FROM `characters` WHERE `charId` = ?', { ctx.aliveCharId })
        end

        if #stuck > 0 then
            error('still a viewer after its close: ' .. table.concat(stuck, ', ')
                .. ' — the client\'s close did not release it on the server')
        end
    end,
    tests = {
        -- ==========================================
        -- Phase 1: Create container
        -- ==========================================
        {
            name = 'CreateContainer returns container def',
            fn = function(source, ctx)
                -- Place near player so open distance check passes
                local ped = GetPlayerPed(source)
                local pos = GetEntityCoords(ped)
                local c, err = exports.whip_core:CreateContainer({
                    name      = '_test_stash',
                    type      = 'stash',
                    slots     = 10,
                    maxWeight = 50.0,
                    x         = pos.x + 2,
                    y         = pos.y,
                    z         = pos.z,
                    heading   = 0,
                    prop      = 'prop_cs_cardbox_01',
                })
                assertOk(c, err, 'CreateContainer')
                assertType(c.containerId, 'number', 'containerId type')
                assertEqual(c.name, '_test_stash', 'name')
                assertEqual(c.slots, 10, 'slots')
                _testContainerId = c.containerId
                assertDbScalar('SELECT `name` FROM `containers` WHERE `containerId` = ?', { c.containerId },
                    '_test_stash', 'the row is on disk')
            end,
        },
        {
            name = 'GetContainerDef returns correct data',
            fn = function()
                assertNotNil(_testContainerId, 'containerId from create')
                local c = exports.whip_core:GetContainerDef(_testContainerId)
                assertNotNil(c, 'GetContainerDef')
                assertEqual(c.containerId, _testContainerId, 'containerId match')
                assertEqual(c.slots, 10, 'slots')
            end,
        },
        {
            name = 'UpdateContainer changes a field, in memory and on disk',
            fn = function()
                assertNotNil(_testContainerId, 'containerId from create')
                -- `true` or `false, reason` since 09-24 (it was a bare false); the reason is in the label.
                local ok, err = exports.whip_core:UpdateContainer(_testContainerId, { name = '_test_stash_renamed' })
                assertTrue(ok, 'UpdateContainer: ' .. tostring(err))
                assertEqual(exports.whip_core:GetContainerDef(_testContainerId).name, '_test_stash_renamed',
                    'renamed in memory')
                assertDbScalar('SELECT `name` FROM `containers` WHERE `containerId` = ?', { _testContainerId },
                    '_test_stash_renamed', 'and on disk')
            end,
        },
        {
            -- ROW FIRST, MEMORY SECOND — the promise Shops.update and Jobs.update keep. A write that
            -- fails must leave the container as the server already believed it; otherwise every
            -- client is told about a name (or a size, or an owner) the database never got, and the
            -- next restart silently undoes it.
            --
            -- EXPECTED TO FAIL until Containers.update (server/containers.lua) is reordered: it
            -- writes every field into the cached def BEFORE the UPDATE, and returns false on a
            -- failed write with the cache already changed.
            name = 'A container update whose write fails changes nothing',
            fn = function()
                assertNotNil(_testContainerId, 'containerId from create')
                local before = exports.whip_core:GetContainerDef(_testContainerId).name

                assertTrue(exports.whip_core:__TestFailNextQuery('UPDATE `containers`'), 'fault armed')
                local ok, err = exports.whip_core:UpdateContainer(_testContainerId, { name = '_test_should_not_stick' })
                -- Read, then disarm AT ONCE: a fault that did not fire would otherwise sit armed for
                -- ten seconds and fail whatever unrelated write matched it next.
                local stillArmed = exports.whip_core:__TestRawFaultArmed()
                exports.whip_core:__TestFailNextQuery(nil)
                assertNil(stillArmed, 'the fault fired on the update\'s own write')
                assertFalse(ok, 'the update reports failure')
                -- The reason crosses the export since 09-24, as UpdateShop's does (08_shops).
                assertEqual(err, DB_ERROR, 'with its reason')

                assertEqual(exports.whip_core:GetContainerDef(_testContainerId).name, before,
                    'the name is unchanged in memory')
                assertDbScalar('SELECT `name` FROM `containers` WHERE `containerId` = ?', { _testContainerId },
                    before, 'and on disk')
            end,
        },

        -- ==========================================
        -- Phase 2: Open container + item manipulation
        -- ==========================================
        {
            -- The server used to take an exclusive LOCK, and this test's subject was that it had.
            -- There is no lock: opening joins a viewer set and can never be refused for
            -- occupancy. What remains worth asserting is membership of THIS container's set —
            -- the thing every later assertion in the module depends on.
            name = 'Opening a container makes you a viewer of it',
            fn = function(source)
                assertNotNil(_testContainerId, 'need containerId')
                OpenContainerOrFail(source, _testContainerId)

                local sid = 'container:' .. _testContainerId
                assertTrue(exports.whip_core:__TestIsViewer(source, sid),
                    'the opener joined this container\'s viewer set')
                assertEqual(exports.whip_core:__TestViewerCount(sid), 1,
                    'exactly one viewer')
            end,
        },
        {
            -- NAMES THE STORE, and checks the effect rather than the answer.
            --
            -- By ADDRESS since 09-24: StoreGive replaced PlaceItemAt, whose 'container' meant
            -- "whatever this player has open", picked by pairs() from their viewer memberships —
            -- so a leaked membership from an earlier module could place this food into a car boot
            -- and the test would pass. An address cannot be guessed at.
            -- And a failed write still does not refuse: StoreGive prints and answers the slot,
            -- because the mutation stands and the write is merely owed.
            name = 'StoreGive lands in the named container, and reaches disk',
            fn = function(source)
                local slot, err = exports.whip_core:StoreGive(
                    { kind = 'container', id = _testContainerId, slot = 1 }, 'food', 2)
                assertOk(slot, err, 'StoreGive into the container')

                -- Keyed by slot NUMBER since 24 Sep 2026 (INV-19); GetContainerItems (removed 09-24,
                -- now StoreRead's .items) handed back the NUI's string-keyed serializer before that,
                -- so `inv[1]` was always nil.
                local read, readErr = exports.whip_core:StoreRead({ kind = 'container', id = _testContainerId })
                assertOk(read, readErr, 'container contents readable')
                local inv = read.items
                assertEqual(inv[1] and inv[1].item, 'food', 'landed in THIS container')
                assertEqual(inv[1] and inv[1].amount, 2, 'with the right amount')
                assertNil(inv['1'], 'and not under a string key')

                assertDbScalar(
                    'SELECT `amount` FROM `container_inventory` WHERE `containerId` = ? AND `slot` = 1',
                    { _testContainerId }, 2, 'row on disk')
            end,
        },
        {
            -- StoreTake since 09-24 (TakeItemFrom was removed). It answers what it TOOK, a table, or
            -- `false, reason`.
            name = 'StoreTake leaves the remainder, and reaches disk',
            fn = function(source)
                local taken, err = exports.whip_core:StoreTake(
                    { kind = 'container', id = _testContainerId, slot = 1 }, 1)
                assertOk(taken, err, 'StoreTake from the container')

                local read = exports.whip_core:StoreRead({ kind = 'container', id = _testContainerId })
                local inv = read and read.items
                assertEqual(inv and inv[1] and inv[1].amount, 1,
                    'one food left in the container')

                assertDbScalar(
                    'SELECT `amount` FROM `container_inventory` WHERE `containerId` = ? AND `slot` = 1',
                    { _testContainerId }, 1, 'remainder on disk')
            end,
        },
        {
            -- Closing is the load-bearing half of the viewer model now, and none of it was
            -- asserted: the old test checked only that the CLIENT replied.
            --
            -- A membership that is not removed pins the container's cache for the rest of the
            -- session, because unloadInventory refuses to drop a cache anyone is still in.
            name = 'Closing releases the viewer and drops the cache',
            fn = function(source)
                assertTrue(closeAndWait(source, _testContainerId), 'viewer released')

                local sid = 'container:' .. _testContainerId
                assertEqual(exports.whip_core:__TestViewerCount(sid), 0, 'viewer set empty')
                assertFalse(exports.whip_core:__TestContainerCached(_testContainerId),
                    'cache dropped once the last viewer left')
            end,
        },
        {
            -- THE BEHAVIOUR THAT ACTUALLY CHANGED, and it had no coverage anywhere.
            --
            -- A second player opening the same container used to be refused outright. Now they
            -- join, both are viewers, and the cache survives one of them leaving.
            name = 'A SECOND player can open the same container',
            fn = function(source)
                local other = nil
                for src in pairs(exports.whip_core:GetPlayers() or {}) do
                    local id = tonumber(src)
                    -- Not a load-test phantom (900001+): they have no client and no ped.
                    if id and id ~= source and id < 900000 then other = id break end
                end
                if not other then skip('needs a second player online') end

                -- ####################################################################
                -- MEASURE, CLOSE, THEN ASSERT — AND THE ORDER IS THE WHOLE POINT.
                --
                -- This test opens a container for OUR player and only closed it on the way out,
                -- after four assertions. A failing assertion RAISES, so when the second player
                -- was refused, the close never ran and our player was left viewing the container
                -- for the rest of the module.
                --
                -- That is not a cosmetic leak. The client refuses to open a second inventory UI
                -- over the first, so the next two tests could not open THEIR containers either,
                -- and both reported "container N did not open — too far away, no access..." as
                -- though they had found a fresh defect. One failing test, three red results, and
                -- the two innocent ones pointing at the wrong subsystem.
                --
                -- Every observation is taken first, the view is released unconditionally, and
                -- only then is anything judged. A failure here now costs exactly one result.
                -- ####################################################################
                local sid = 'container:' .. _testContainerId
                OpenContainerOrFail(source, _testContainerId)

                -- ####################################################################
                -- skipDistance, BECAUSE PROXIMITY IS NOT WHAT THIS TEST IS ABOUT.
                --
                -- The container is created next to the TESTER. A second player is wherever they
                -- happen to be standing, which on a live server is anywhere on the map — so the
                -- open was refused with "Too far away" and the test reported it as the second
                -- player being REFUSED ADMISSION, which is a completely different claim and
                -- pointed at the viewer-set rule that had not failed at all.
                --
                -- The subject here is that a container's viewer set admits more than one player
                -- and survives one of them leaving. Access and distance are separate gates with
                -- their own coverage, and whip_core's own comment beside them says the same
                -- thing: "ACCESS IS NOT THE SAME AS BEING A VIEWER". Skipping both asks the
                -- question this test means to ask.
                -- ####################################################################
                local stash = { kind = 'container', id = _testContainerId }
                local admitted, why = exports.whip_core:OpenStore(other, stash,
                    { skipDistance = true, skipAccess = true })
                local bothViewing = exports.whip_core:__TestViewerCount(sid)

                -- One leaving must NOT evict the cache from under the other.
                closeAndWait(source, _testContainerId)
                local remaining   = exports.whip_core:__TestViewerCount(sid)
                local stillCached = exports.whip_core:__TestContainerCached(_testContainerId)

                -- Put the other player back where we found them. The close is the half of the open
                -- that did not exist until this test needed it: without it a test could add a viewer
                -- to somebody else's session and had no way to remove one. OpenStore / CloseStore
                -- since 09-24 (OpenContainer / CloseContainer were removed); CloseStore also takes
                -- the stash off the other player's screen, which CloseContainer never did. Its
                -- answer is not asserted: it is false, 'That is not open' if they were never
                -- admitted, and that failure is reported below as the admission's.
                pcall(exports.whip_core.CloseStore, exports.whip_core, other, stash)
                pcall(exports.whip_core.__TestUnloadContainer, exports.whip_core, _testContainerId)

                assertTrue(admitted, 'the second player was admitted, not refused: ' .. tostring(why))
                assertEqual(bothViewing, 2, 'both are viewers')
                assertEqual(remaining, 1, 'one viewer remains')
                assertTrue(stillCached, 'the cache survived the first close')
            end,
        },

        -- ==========================================
        -- Phase 3: Weight enforcement
        -- ==========================================
        {
            name = 'Weight limit enforced on container (reject heavy item)',
            fn = function(source, ctx)
                local ped = GetPlayerPed(source)
                local pos = GetEntityCoords(ped)
                -- Create a tiny container (maxWeight 0.5 kg)
                local c, err = exports.whip_core:CreateContainer({
                    name = '_test_tiny', slots = 5, maxWeight = 0.5,
                    x = pos.x + 4, y = pos.y, z = pos.z,
                })
                assertOk(c, err, 'tiny container created')
                ctx.tinyId = c.containerId   -- teardown closes and deletes it, pass or fail
                -- NOT OPENED any more (09-24). The open was only there for PlaceItemAt, whose
                -- 'container' meant "whatever this player has open"; StoreGive names the container
                -- by address and loads it on demand, so the weight rule is asked about directly.
                local function at(slot) return { kind = 'container', id = c.containerId, slot = slot } end
                -- food weighs 0.3kg each — 1 should fit
                local ok1, e1 = exports.whip_core:StoreGive(at(1), 'food', 1)
                assertOk(ok1, e1, 'first food fits (0.3 <= 0.5)')
                -- second food = 0.6kg total, exceeds 0.5kg
                local ok2 = exports.whip_core:StoreGive(at(2), 'food', 1)
                assertFalse(ok2, 'second food rejected (0.6 > 0.5)')
                local read, readErr = exports.whip_core:StoreRead({ kind = 'container', id = c.containerId })
                assertOk(read, readErr, 'contents readable')
                assertNil(read.items[2], 'and nothing landed in slot 2')
            end,
        },

        -- ==========================================
        -- Phase 4: Allowed items enforcement
        -- ==========================================
        {
            name = 'Allowed items restriction rejects disallowed item',
            fn = function(source, ctx)
                local ped = GetPlayerPed(source)
                local pos = GetEntityCoords(ped)
                -- (09-24: the tiny container is no longer closed first, and this one is not opened.
                -- Both were for PlaceItemAt's 'container', which only one open store could be;
                -- StoreGive names this container by address.)

                local c, err = exports.whip_core:CreateContainer({
                    name = '_test_restricted', slots = 5, maxWeight = 50.0,
                    x = pos.x + 1, y = pos.y, z = pos.z,
                    allowedItems = { food = {} },
                })
                assertOk(c, err, 'restricted container')
                ctx.restrictedId = c.containerId
                local function at(slot) return { kind = 'container', id = c.containerId, slot = slot } end
                local ok1, e1 = exports.whip_core:StoreGive(at(1), 'food', 1)
                local ok2 = exports.whip_core:StoreGive(at(2), 'drink', 1)
                assertOk(ok1, e1, 'food allowed')
                -- NOTE: StoreGive should reject items not in allowedItems (it places through
                -- Stores.place, as a drag does). If this fails, the container kind's allows check
                -- needs fixing.
                assertFalse(ok2, 'drink rejected by allowedItems')
                -- (Deleted in teardown, which runs whether or not the asserts pass.)
            end,
        },

        -- ==========================================
        -- Phase 4b: Declared by key (EnsureContainer, audit 3 DX-14)
        -- ==========================================
        {
            -- A container could only be CREATED, so a stash made at resource start gained a twin
            -- with its own contents on every restart.
            name = 'EnsureContainer makes once, then finds the same one, by key',
            fn = function(source, ctx)
                -- A leftover from a run that died before its teardown.
                local stale = exports.whip_core:GetContainerBy('key', '_test:ensured')
                if stale then exports.whip_core:DeleteContainer(stale.containerId) end

                local decl = { name = '_test_ensured', slots = 10, maxWeight = 50.0, x = 0, y = 0, z = 50 }
                local a, aErr = exports.whip_core:EnsureContainer('_test:ensured', decl)
                assertOk(a, aErr, 'EnsureContainer made it')
                ctx.ensuredId = a.containerId
                assertEqual(a.key, '_test:ensured', 'with its key')
                assertDbScalar('SELECT `key` FROM `containers` WHERE `containerId` = ?', { a.containerId },
                    '_test:ensured', 'the key is on disk')

                local b, bErr = exports.whip_core:EnsureContainer('_test:ensured', decl)
                assertOk(b, bErr, 'EnsureContainer again')
                assertEqual(b.containerId, a.containerId, 'the same container, not a twin')
                assertEqual(exports.whip_core:GetContainerBy('key', '_test:ensured').containerId, a.containerId,
                    "GetContainerBy('key') finds it")
                assertDbRowCount("SELECT 1 FROM `containers` WHERE `key` = '_test:ensured'", {}, 1, 'one row')

                local bad = exports.whip_core:EnsureContainer('has spaces', decl)
                assertFalse(bad, 'a key with spaces is refused')
            end,
        },
        {
            name = 'EnsureContainer follows a changed declaration, and not an unchanged one',
            fn = function(source, ctx)
                assertNotNil(ctx.ensuredId, 'the ensured container exists')
                local decl = { name = '_test_ensured', slots = 12, maxWeight = 50.0, x = 0, y = 0, z = 50 }
                assertOk(exports.whip_core:EnsureContainer('_test:ensured', decl))
                assertEqual(exports.whip_core:GetContainerDef(ctx.ensuredId).slots, 12, 'the new size followed the code')

                local renamed, rErr = exports.whip_core:UpdateContainer(ctx.ensuredId, { name = '_test_admin_name' })
                assertOk(renamed, rErr, 'an admin edit')
                assertOk(exports.whip_core:EnsureContainer('_test:ensured', decl))
                assertEqual(exports.whip_core:GetContainerDef(ctx.ensuredId).name, '_test_admin_name',
                    'the same declaration leaves the edit alone')
            end,
        },
        {
            -- Shrunk under an item, the stash kept the row but offered no slot to reach it.
            name = 'Fewer slots are refused while an item sits above the new count',
            fn = function(source, ctx)
                assertNotNil(ctx.ensuredId, 'the ensured container exists')
                local at12 = { kind = 'container', id = ctx.ensuredId, slot = 12 }
                assertOk(exports.whip_core:StoreGive(at12, 'food', 1))

                local decl = { name = '_test_ensured', slots = 10, maxWeight = 50.0, x = 0, y = 0, z = 50 }
                local shrunk, why = exports.whip_core:EnsureContainer('_test:ensured', decl)
                assertFalse(shrunk, 'refused while slot 12 holds food')
                assertNotNil(why, 'with a reason')
                assertEqual(exports.whip_core:GetContainerDef(ctx.ensuredId).slots, 12, 'still 12 slots')

                assertOk(exports.whip_core:StoreTake(at12, 1))
                assertOk(exports.whip_core:EnsureContainer('_test:ensured', decl))
                assertEqual(exports.whip_core:GetContainerDef(ctx.ensuredId).slots, 10, 'and 10 once it is empty')
                assertDbScalar('SELECT `slots` FROM `containers` WHERE `containerId` = ?', { ctx.ensuredId },
                    10, 'on disk')
            end,
        },
        {
            -- A JOB LOCKER IS ONE FIELD (audit 6, DX-5): `requirements`, in the doors' shape and checked
            -- by the doors' code. It took a lock, an action, an event and a skipAccess open, and both
            -- "locker" examples in the docs were open to anyone.
            name = 'A container with requirements opens only for who they name; a bad shape is refused',
            fn = function(source, ctx)
                assertNotNil(ctx.ensuredId, 'the ensured container exists')
                local base = { name = '_test_ensured', slots = 10, maxWeight = 50.0, x = 0, y = 0, z = 50 }
                local function with(req)
                    local d = {}
                    for k, v in pairs(base) do d[k] = v end
                    d.requirements = req
                    return d
                end

                assertOk(exports.whip_core:EnsureContainer('_test:ensured', with({ jobs = '_test_nojob', onDuty = true })))
                local req = exports.whip_core:GetContainerDef(ctx.ensuredId).requirements
                assertEqual(req and req.jobs and req.jobs[1], '_test_nojob', 'stored in the one shape (jobs a list)')
                assertDbRowCount('SELECT 1 FROM `containers` WHERE `containerId` = ? AND `requirements` IS NOT NULL',
                    { ctx.ensuredId }, 1, 'on disk')

                local addr = { kind = 'container', id = ctx.ensuredId }
                local opened, why = exports.whip_core:OpenStore(source, addr, { skipDistance = true })
                assertFalse(opened, 'someone without the job is refused')
                assertTrue(type(why) == 'string' and why:find('_test_nojob', 1, true) ~= nil,
                    'and told which job it needs: ' .. tostring(why))

                local bad, badWhy = exports.whip_core:EnsureContainer('_test:ensured', with({ jobz = 'police' }))
                assertFalse(bad, 'a requirement a door would not take is refused')
                assertNotNil(badWhy, 'with a reason')
                local picked = exports.whip_core:EnsureContainer('_test:ensured', with({ lockpick = true }))
                assertFalse(picked, 'lockpick is a door\'s, refused on a container')

                assertOk(exports.whip_core:EnsureContainer('_test:ensured', base))
                assertNil(exports.whip_core:GetContainerDef(ctx.ensuredId).requirements,
                    'declared no more, so cleared')
                local reopened, reWhy = exports.whip_core:OpenStore(source, addr, { skipDistance = true })
                assertOk(reopened, reWhy, 'and anyone may open it again')
                assertTrue(closeAndWait(source, ctx.ensuredId), 'closed again')
            end,
        },
        {
            -- ITEMS ARE BACK (the Director's decision 3, 2 Oct 2026; Josh's 26 Sep "by permission only"
            -- reversed). What took them away (audit 7, INV-1) was a card put down inside its own locker,
            -- locking the player out: that is now refused wherever an item goes into a container, a
            -- script's StoreGive included. Lockpick stays a door's, and a property must exist.
            name = 'A container takes an item rule, but never the item inside it; lockpick and a missing property are refused',
            fn = function(source, ctx)
                local base = { name = '_test_card_locker', slots = 5, maxWeight = 10.0, x = 0, y = 0, z = 50 }
                local function with(req)
                    local d = {}
                    for k, v in pairs(base) do d[k] = v end
                    d.requirements = req
                    return d
                end
                local made, why = exports.whip_core:CreateContainer(with({ items = 'food' }))
                assertOk(made, why, 'a container that wants an item carried (food, as its keycard)')
                ctx.cardLockerId = made.containerId
                local req = exports.whip_core:GetContainerDef(made.containerId).requirements
                assertTrue(req and req.items and req.items[1] and req.items[1].key == 'food', 'stored in the doors\' shape')

                local slot, giveWhy = exports.whip_core:StoreGive({ kind = 'container', id = made.containerId }, 'food', 1)
                assertFalse(slot, 'the item it wants is never put inside it, not even by a script: ' .. tostring(giveWhy))
                local other, otherWhy = exports.whip_core:StoreGive({ kind = 'container', id = made.containerId }, 'drink', 1)
                assertOk(other, otherWhy, 'anything else still goes in')

                local cases = {
                    { req = { lockpick = true },                     why = 'lockpick' },
                    { req = { property = '_test_no_such_property' }, why = 'no property' },
                }
                for i, c in ipairs(cases) do
                    local bad, badWhy = exports.whip_core:CreateContainer(with(c.req))
                    if bad then pcall(exports.whip_core.DeleteContainer, exports.whip_core, bad.containerId) end
                    assertFalse(bad, ('case %d is refused'):format(i))
                    assertTrue(type(badWhy) == 'string' and badWhy:find(c.why, 1, true) ~= nil,
                        ('case %d says "%s" (got: %s)'):format(i, c.why, tostring(badWhy)))
                end
            end,
        },
        {
            -- An action's word on a stash (dev review D10): one rule reads the same either way; two would
            -- mean "all" on an action and "any one" here, so they are refused rather than left open.
            name = 'A container given require takes it for one rule and refuses two',
            fn = function(source, ctx)
                local base = { name = '_test_require_locker', slots = 5, maxWeight = 10.0, x = 0, y = 0, z = 50 }
                local function with(req)
                    local d = {}
                    for k, v in pairs(base) do d[k] = v end
                    d.require = req
                    return d
                end
                local made, why = exports.whip_core:CreateContainer(with({ job = 'police', onDuty = true }))
                assertOk(made, why, 'one rule: a job on duty')
                local req = exports.whip_core:GetContainerDef(made.containerId).requirements
                pcall(exports.whip_core.DeleteContainer, exports.whip_core, made.containerId)
                assertTrue(req and req.jobs and req.jobs[1] == 'police' and req.onDuty == true,
                    'stored as requirements = { jobs = police, onDuty }')

                local two, twoWhy = exports.whip_core:CreateContainer(with({ job = 'police', item = 'food' }))
                if two then pcall(exports.whip_core.DeleteContainer, exports.whip_core, two.containerId) end
                assertFalse(two, 'two rules: refused, never a locker either one opens')
                assertTrue(tostring(twoWhy):find('one rule', 1, true) ~= nil, 'and says why: ' .. tostring(twoWhy))

                local both = with({ job = 'police' })
                both.requirements = { jobs = 'ems' }
                local b, bWhy = exports.whip_core:CreateContainer(both)
                if b then pcall(exports.whip_core.DeleteContainer, exports.whip_core, b.containerId) end
                assertFalse(b, 'require and requirements together: refused (' .. tostring(bWhy) .. ')')
            end,
        },
        {
            -- A RUN'S CONTAINER (the Director's slice 3, 4 Oct 2026): never saved, made with what it holds,
            -- gone with its tag, and a released tag makes no more.
            name = 'CreateContainer persist = false: its items, no row, gone with ReleaseTag',
            fn = function(source, ctx)
                local tag = 'test:runbox:' .. tostring(GetGameTimer())
                local made, why = exports.whip_core:CreateContainer({
                    persist = false, tag = tag, name = '_test_run_box', slots = 5, maxWeight = 10.0,
                    x = 0, y = 0, z = 50, prop = false, items = { { item = 'food', amount = 2 } },
                })
                assertOk(made, why, 'a run container')
                ctx.runBoxId = made.containerId
                assertTrue(made.containerId >= 4294967296, 'its id is above every row\'s')
                assertEqual(exports.whip_core:StoreCount({ kind = 'container', id = made.containerId }, 'food'), 2,
                    'it holds what it was made with')
                assertDbScalar('SELECT COUNT(*) FROM `containers` WHERE `containerId` = ?', { made.containerId }, 0,
                    'and has no row')

                local okR, n = exports.whip_core:ReleaseTag(tag)
                assertTrue(okR == true and (tonumber(n) or 0) >= 1, 'ReleaseTag counts it')
                assertNil(exports.whip_core:GetContainerDef(made.containerId), 'and it is gone')
                ctx.runBoxId = nil

                local again, aWhy = exports.whip_core:CreateContainer({ persist = false, tag = tag, x = 0, y = 0, z = 50 })
                assertFalse(again, 'a released tag makes no more')
                assertTrue(type(aWhy) == 'string' and aWhy:find('ended', 1, true) ~= nil, 'saying it has ended: ' .. tostring(aWhy))
                local keyed = exports.whip_core:CreateContainer({ persist = false, key = '_test:runbox', x = 0, y = 0, z = 50 })
                assertFalse(keyed, 'a container that is never saved has no key')
            end,
        },

        {
            -- ARC-7 (Josh, 26 Sep 2026): a deleted character's stash goes back to stock — what is
            -- in it stays, and its owner and one-person lock are cleared. It stayed locked to a
            -- character nobody could play.
            name = "A deleted character's stash keeps its contents and loses its lock",
            fn = function(source, ctx)
                local me = exports.whip_core:GetPlayer(source).charId
                local userId = MySQL.scalar.await('SELECT `userId` FROM `characters` WHERE `charId` = ?', { me })
                local ghost = MySQL.insert.await(
                    "INSERT INTO `characters` (`userId`, `firstName`, `lastName`, `dateOfBirth`, `deleted`) VALUES (?, '_test', '_ghost', '1990-01-01', CURRENT_TIMESTAMP)",
                    { userId })
                assertNotNil(ghost, 'a throwaway (already soft-deleted) character')
                ctx.ghostCharId = ghost

                local c, err = exports.whip_core:CreateContainer({
                    name = '_test_ghost_locker', slots = 5, maxWeight = 10.0, x = 0, y = 0, z = 50,
                    ownerCharId = ghost, accessCharId = ghost,
                })
                assertOk(c, err, 'a locker only the throwaway character can open')
                ctx.ghostLockerId = c.containerId
                assertOk(exports.whip_core:StoreGive({ kind = 'container', id = c.containerId, slot = 1 }, 'food', 2))

                -- The seam, not the event: the event is news only since audit 5 (ARC-1).
                assertOk(exports.whip_core:__TestRunCharacterDeleted(ghost))

                assertTrue(waitFor(function()
                    local d = exports.whip_core:GetContainerDef(c.containerId)
                    return d ~= nil and d.accessCharId == nil
                end, 3000) == true, 'the one-person lock is gone')
                assertNil(exports.whip_core:GetContainerDef(c.containerId).ownerCharId, 'and the owner')
                local read = exports.whip_core:StoreRead({ kind = 'container', id = c.containerId })
                assertEqual(read and read.items[1] and read.items[1].amount, 2, 'what was in it stayed')
                assertDbRowCount('SELECT 1 FROM `containers` WHERE `containerId` = ? AND `ownerCharId` IS NULL AND `accessCharId` IS NULL',
                    { c.containerId }, 1, 'on disk too')
            end,
        },

        {
            -- ARC-1 (audit 5): the release is core's own hook, run by the delete itself. The public
            -- event is news: any resource firing it for a LIVE character used to take their stash,
            -- home, keys and jobs for good. Fired at a throwaway character that is NOT deleted (never
            -- the tester's own, in case this ever regresses), it must change nothing.
            name = 'A fired character:deleted event takes nothing from a character that is not deleted',
            fn = function(source, ctx)
                local userId = MySQL.scalar.await('SELECT `userId` FROM `characters` WHERE `charId` = ?', { ctx.charId })
                local alive = MySQL.insert.await(
                    "INSERT INTO `characters` (`userId`, `firstName`, `lastName`, `dateOfBirth`) VALUES (?, '_test', '_alive', '1990-01-01')",
                    { userId })
                assertNotNil(alive, 'a throwaway character, not deleted')
                ctx.aliveCharId = alive

                local c, err = exports.whip_core:CreateContainer({
                    name = '_test_alive_locker', slots = 5, maxWeight = 10.0, x = 0, y = 0, z = 50,
                    ownerCharId = alive, accessCharId = alive,
                })
                assertOk(c, err, 'a locker only that character can open')
                ctx.aliveLockerId = c.containerId

                TriggerEvent('whip_core:character:deleted', { charId = alive })
                Wait(500)

                local d = exports.whip_core:GetContainerDef(c.containerId)
                assertEqual(d and d.ownerCharId, alive, 'still theirs')
                assertEqual(d and d.accessCharId, alive, 'and still locked to them')

                -- And the seam refuses a character that is not deleted.
                local ran = exports.whip_core:__TestRunCharacterDeleted(alive)
                assertFalse(ran, '__TestRunCharacterDeleted refuses a live character')
            end,
        },

        -- ==========================================
        -- Phase 5: Delete + verify gone
        -- ==========================================
        {
            -- ON DISK, both tables. The delete promises the contents go with the definition — it
            -- used to delete the containers row alone, and 237 orphaned container_inventory rows
            -- had built up before anyone looked. The main container still holds the one food the
            -- take left, so an orphan would show here.
            name = 'DeleteContainer removes container, and its contents, from disk',
            fn = function()
                assertNotNil(_testContainerId, 'containerId for delete')
                assertDbRowCount('SELECT 1 FROM `container_inventory` WHERE `containerId` = ?',
                    { _testContainerId }, 1, 'the container holds a row before the delete')

                local ok, err = exports.whip_core:DeleteContainer(_testContainerId)
                assertOk(ok, err, 'DeleteContainer')
                assertNil(exports.whip_core:GetContainerDef(_testContainerId), 'container deleted from cache')
                assertDbRowCount('SELECT 1 FROM `containers` WHERE `containerId` = ?',
                    { _testContainerId }, 0, 'the containers row is gone')
                assertDbRowCount('SELECT 1 FROM `container_inventory` WHERE `containerId` = ?',
                    { _testContainerId }, 0, 'and so are its contents')
                _testContainerId = nil -- Prevent teardown double-delete
            end,
        },
        {
            name = 'GetContainerDef returns nil for invalid ID',
            fn = function()
                assertNil(exports.whip_core:GetContainerDef(999999), 'invalid containerId')
            end,
        },
    }
})
