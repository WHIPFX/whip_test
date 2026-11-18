-- ============================================
-- whip_test — Server Test Runner
-- ============================================

-- ============================================
-- THE DYNAMIC-REGISTRATION BAR TEST (slot registry)
-- ============================================
--
-- The whole point of the slot registry is that a satellite can reshape the accessory strip
-- with zero NUI edits — the same contract RegisterStat carries. A test run does it:
--
--   a run starts  → slot 4 relabels to "Medkit" on every LIVE client and accepts only a
--                   bandage (server-enforced — drag anything else in and the STORE refuses,
--                   not just the UI). whip's own strip has no typed slot, and 24_placement and
--                   25_storemove need one.
--   it finishes   → slot 4 goes back to whip's own plain slot, live (ReleaseTag), before the
--                   tester's inventory is put back. Stopping whip_test does the same.
--
-- Only for a run: whip_test is ensured on both servers, and a slot that refuses everything
-- but a bandage all day is not the strip Josh plays with (5 Nov 2026: every slot takes
-- anything).
local _stripTag, _stripRuns = nil, 0

--- Make slot 4 the Medkit slot for this run. Each run has its own tag: a released one stays closed.
local function typeTestSlot()
    _stripRuns = _stripRuns + 1
    _stripTag = ('whip_test:strip:%d:%d'):format(os.time(), _stripRuns)
    local ok, why = exports.whip_core:RegisterAccessorySlot({
        slot    = 4,
        accepts = 'bandage',
        label   = 'Medkit',
        tag     = _stripTag,
    })
    if not ok then print(('[whip_test] no Medkit slot for this run: %s'):format(tostring(why))) end
end

--- Give slot 4 back to whip's own plain slot.
local function untypeTestSlot()
    if not _stripTag then return end
    pcall(exports.whip_core.ReleaseTag, exports.whip_core, _stripTag)
    _stripTag = nil
end

local running      = false
local testSource   = nil
local results      = {}
local startTime    = 0

-- Endurance test state
local enduranceRunning = false
local enduranceSource  = nil

-- ============================================
-- Assert Helpers (global for test modules)
-- ============================================

--- How many checks the current test has made.
---
--- The runner zeroes it before each test and FAILS a test that finishes having checked nothing.
--- A test body that never reaches an assertion — an early return, a loop over an empty list, an
--- `if` that is never true — used to report as a pass, and nothing in the report could tell it
--- apart from a test that proved something.
AssertCount = 0

local function counted()
    AssertCount = AssertCount + 1
end

function assertEqual(actual, expected, label)
    counted()
    if actual ~= expected then
        error(('%s: expected %s, got %s'):format(label or 'assertEqual', tostring(expected), tostring(actual)), 2)
    end
end

function assertNotEqual(actual, notExpected, label)
    counted()
    if actual == notExpected then
        error(('%s: expected NOT %s'):format(label or 'assertNotEqual', tostring(notExpected)), 2)
    end
end

function assertType(value, expectedType, label)
    counted()
    if type(value) ~= expectedType then
        error(('%s: expected type %s, got %s'):format(label or 'assertType', expectedType, type(value)), 2)
    end
end

--- NOTE: `false` is not nil, so this passes on an export that answered (false, reason). For a
--- create/insert export use assertOk, which fails on both and prints the reason.
function assertNotNil(value, label)
    counted()
    if value == nil then
        error(('%s: expected non-nil'):format(label or 'assertNotNil'), 2)
    end
end

function assertNil(value, label)
    counted()
    if value ~= nil then
        error(('%s: expected nil, got %s'):format(label or 'assertNil', tostring(value)), 2)
    end
end

function assertTrue(value, label)
    counted()
    if value ~= true then
        error(('%s: expected true, got %s'):format(label or 'assertTrue', tostring(value)), 2)
    end
end

function assertFalse(value, label)
    counted()
    if value ~= false then
        error(('%s: expected false, got %s'):format(label or 'assertFalse', tostring(value)), 2)
    end
end

function assertGt(value, threshold, label)
    counted()
    if not (value > threshold) then
        error(('%s: expected > %s, got %s'):format(label or 'assertGt', tostring(threshold), tostring(value)), 2)
    end
end

function assertGte(value, threshold, label)
    counted()
    if not (value >= threshold) then
        error(('%s: expected >= %s, got %s'):format(label or 'assertGte', tostring(threshold), tostring(value)), 2)
    end
end

--- Assert an export SUCCEEDED, for the whip_core shape `value` or `false/nil, reason`.
---
--- assertNotNil was used for this across the suite and passes on `false` — so a CreateDoor that
--- answered (false, 'Door already exists') read as a created door, and the test then failed three
--- lines later indexing a boolean, naming the wrong problem. This fails on both, with the reason.
---@param value any   the export's first return
---@param err any     the export's second return (the reason), if any
---@param label string
function assertOk(value, err, label)
    counted()
    if value == nil or value == false then
        error(('%s: failed — %s'):format(label or 'assertOk', tostring(err or 'no reason given')), 2)
    end
end

--- The reason whip_core answers when the database refused a write — its DB_ERROR (server/helpers.lua),
--- copied because a test cannot read another resource's globals. It was the code 'db_error' until
--- audit 3 ARC-10; whip answers in words everywhere now.
DB_ERROR = 'Could not save that (database error)'

--- Assert how SecureEvent (or a handler through RecordEventRejection) last answered an event.
---
--- `expected` is the exact refusal reason, or nil to assert the event was NOT refused. Call it
--- after ClientExecWait, which waits for the server's outcome, so the answer is this call's and not
--- one left over from an earlier test.
---@param eventName string   e.g. 'whip_core:server:storeMove', or 'cb:<name>' for a callback
---@param expected string|nil
---@param label string
function assertLastReject(eventName, expected, label)
    counted()
    local reason = exports.whip_core:__TestLastReject(eventName)
    if reason ~= expected then
        if expected == nil then
            error(('%s: expected %s to be accepted, but it was refused: %s')
                :format(label or 'assertLastReject', eventName, tostring(reason)), 2)
        end
        error(('%s: expected %s to be refused with "%s", got %s')
            :format(label or 'assertLastReject', eventName, expected,
                reason and ('"' .. reason .. '"') or 'no refusal'), 2)
    end
end

-- ============================================
-- Skip — a real one
-- ============================================
--
-- The runner has always had a `skipped` bucket in its report, but nothing ever set
-- `r.skipped`, so every "can't run this here" guard in the suite took the form of an
-- early return — which the runner counted as a PASS. A test that silently opts out
-- and reports green is worse than no test at all.

SKIP_SENTINEL = '__whip_test_skip__'

--- Abort the current test and record it as SKIPPED rather than passed.
---@param reason string
function skip(reason)
    error({ [SKIP_SENTINEL] = true, reason = reason or 'no reason given' }, 2)
end

--- True if a pcall error came from skip(), or from another resource's WhipTest.skip (lib/kit.lua), which can only
--- send its skip across as text carrying the sentinel.
---@param err any
---@return boolean
function IsSkip(err)
    if type(err) == 'string' then return err:find(SKIP_SENTINEL, 1, true) ~= nil end
    return type(err) == 'table' and err[SKIP_SENTINEL] == true
end

--- A skip's reason, from either kind.
---@param err any
---@return string
function SkipReason(err)
    if type(err) == 'string' then return err:match(SKIP_SENTINEL .. ':([^\n]*)') or 'skipped' end
    return type(err) == 'table' and tostring(err.reason) or 'skipped'
end

-- ============================================
-- Durable-state assertions
-- ============================================
--
-- Everything the suite asserted used to be read back out of the same in-memory cache the
-- call under test had just written — so no assertion could ever disagree with the code.
-- These are the independent oracle: they go to the database.
--
-- Route EVERY durable-state assertion through these. No test should issue a raw MySQL
-- query or a bare Wait(N) before reading the DB. When Stage 2 of the framework refactor
-- introduces write-behind persistence, the only edit needed is inside FlushPersistence()
-- below — not at forty assertion sites.

--- Force pending writes to disk, and REFUSE TO CONTINUE if they did not land.
---
--- This is the oracle behind every DB assertion in the suite, and it was quietly lying.
---
--- It used to fall back to `Wait(150)` whenever the flush seam was unavailable OR returned false.
--- Both halves of that are now wrong:
---
---   * 150ms is not a settle. Every store the suite touches is write-behind now — player
---     (stores.lua), container and vehicle all declare durability = 'writeBehind' — and the flush
---     thread runs on Config.FlushInterval, which is 1000. The sleep was roughly seven times too
---     short, so an assertDbScalar following it read the row as it was BEFORE the change.
---
---   * A false return is not a timing problem. flushAll answers false when a unit is still owed —
---     quarantined after a failed write, or skipped during backoff. That became a NORMAL,
---     reachable state when the rollback was deleted: a failed save now leaves the mutation
---     standing and the unit dirty rather than undoing it. Swallowing that into a sleep turns
---     "the write never landed" into "the assertion failed for no stated reason".
---
--- So it errors instead. A test that cannot establish durable state should say so rather than
--- assert against whatever the database happened to hold.
---@param source number|nil
--- RETRIES A TRANSIENT FAILURE, AND ONLY A TRANSIENT ONE.
---
--- A single attempt was right when nothing else wrote to the same rows. It is not any more:
--- `character_inventory.charId` is a foreign key onto `characters.charId`, so a DELETE from the
--- inventory takes a shared lock on the parent row while a character-row write holds an exclusive
--- one — and two transactions doing that in either order is a textbook InnoDB deadlock. MariaDB's
--- own advice for one is the word "retry".
---
--- Stores already handles it: the unit is quarantined and re-flushed a couple of seconds later, so
--- nothing is lost. What broke was this helper insisting everything be on disk in the same instant,
--- which turned a routine retry into a red test.
---
--- Bounded on purpose. A genuinely stuck unit — a constraint violation, a malformed row, a fault
--- the suite armed — never clears, so it still fails and still says how many are owed. The only
--- thing this tolerates is slow.
---@param source number|nil
function FlushPersistence(source)
    local ATTEMPTS = 4
    local owed = 0

    for attempt = 1, ATTEMPTS do
        local ok, flushed = pcall(exports.whip_core.__TestFlushPersistence, exports.whip_core, source)
        if not ok then
            -- SAY WHAT WENT WRONG. An export that THROWS lands here as well as one that is missing,
            -- and this used to blame the seams either way — on 09-23 it sent the reader to check
            -- Config.EnableTestSeams (which was on) while the real fault was a crash in the flush.
            error(('FlushPersistence: __TestFlushPersistence failed (%s). If that says the export does '
                .. 'not exist, Config.EnableTestSeams must be true; otherwise the flush itself errored.')
                :format(tostring(flushed)), 2)
        end

        if flushed then return end

        local okCount, n = pcall(exports.whip_core.__TestDirtyCount, exports.whip_core)
        owed = okCount and (n or 0) or 0

        -- Longer than the Stores retry backoff, so the next attempt lands after it rather than
        -- during it. Retrying inside the backoff window measures nothing and just burns the budget.
        if attempt < ATTEMPTS then Wait(2500) end
    end

    error(('FlushPersistence: %d unit(s) still unwritten after %d forced flushes — quarantined, '
        .. 'not merely slow'):format(owed, ATTEMPTS), 2)
end

--- Poll until fn() returns truthy, or timeout. Returns the value (or nil on timeout).
--- Use instead of a fixed Wait when waiting on state you can actually observe.
---@param fn function
---@param timeoutMs number|nil
---@return any
function waitFor(fn, timeoutMs)
    local deadline = GetGameTimer() + (timeoutMs or 3000)
    while GetGameTimer() < deadline do
        local ok, value = pcall(fn)
        if ok and value then return value end
        Wait(50)
    end
    return nil
end

--- Run a SELECT and return its rows. Fails the test loudly if the query itself errors —
--- a broken oracle must never read as a pass.
---@param query string
---@param params table|nil
---@return table rows
function DbQuery(query, params)
    local ok, rows = pcall(MySQL.query.await, query, params or {})
    if not ok then
        error(('DbQuery failed: %s (%s)'):format(tostring(rows), query), 2)
    end
    return rows or {}
end

--- Assert a scalar SELECT equals an expected value, flushing first.
---@param query string   must select exactly one column
---@param params table
---@param expected any
---@param label string
function assertDbScalar(query, params, expected, label)
    counted()
    FlushPersistence()
    local ok, value = pcall(MySQL.scalar.await, query, params or {})
    if not ok then
        error(('%s: DB query failed: %s'):format(label or 'assertDbScalar', tostring(value)), 2)
    end
    if value ~= expected then
        error(('%s: DB expected %s, got %s'):format(label or 'assertDbScalar', tostring(expected), tostring(value)), 2)
    end
end

-- ============================================
-- Fixture helpers
-- ============================================

--- Remove every unit of an item the player is carrying.
---
--- Do NOT use `RemoveItem(item, 9999)` for this — it is a guaranteed no-op.
--- Inventory.removeItemAcrossContainers totals the item first and returns
--- 'Not enough items' WITHOUT removing anything when the total is short of the amount
--- asked for. Roughly twenty teardowns across the suite used that idiom, which is why
--- items leaked between modules and later tests found their target slots occupied.
---@param source number
---@param item string
---@return number removed
function RemoveAllOf(source, item)
    local n = exports.whip_core:GetItemCount(source, item) or 0
    if n > 0 then
        pcall(exports.whip_core.RemoveItem, exports.whip_core, source, item, n)
    end
    return n
end

--- Fully dispose of an account a test created: drain it, delete its transactions, close it.
---
--- Closing alone is not enough, twice over. Bank.CloseAccount refuses a non-zero balance, so
--- a test that leaves money behind silently fails to close and leaks the row. And a closed
--- account keeps every transaction it ever recorded — the endurance loop deposits and
--- withdraws once every 5 seconds, which had accrued 14,444 rows and made bank_transactions
--- fifty times larger than any other table in the schema. Both are pure test residue.
---@param accountId number|nil
---@return boolean disposed
function DisposeTestAccount(accountId)
    if not accountId then return false end

    local acc = exports.whip_core:GetBankAccount(accountId)
    if acc and (acc.balance or 0) > 0 then
        -- A SYSTEM withdrawal (24 Sep 2026): cleanup is the framework's business, not a character's.
        -- This used the owner's own BankWithdraw, which needed their permission — fine for a personal
        -- account, and a leak for a job account with no owner (CloseBankAccount then refuses an
        -- account that is not empty).
        -- pcall's own flag first, then the export's answer: a refused withdrawal answers
        -- `false, why` without throwing, and reading only pcall's flag took that for success.
        local called, drained, drainErr = pcall(exports.whip_core.BankSystemWithdraw, exports.whip_core,
            accountId, acc.balance, { reason = '_test cleanup' })
        if not called or not drained then
            print(('[whip_test] could not drain test account %s: %s')
                :format(tostring(accountId), tostring(called and drainErr or drained)))
        end
    end

    -- Child side of fk_tx_from / fk_tx_to, so this is safe to delete directly.
    pcall(MySQL.query.await,
        'DELETE FROM `bank_transactions` WHERE `fromAccountId` = ? OR `toAccountId` = ?',
        { accountId, accountId })

    local called, closed, closeErr = pcall(exports.whip_core.CloseBankAccount, exports.whip_core, accountId)
    if not called or not closed then
        print(('[whip_test] could not close test account %s — it will leak (%s)')
            :format(tostring(accountId), tostring(called and closeErr or closed)))
        return false
    end
    return true
end

--- A throwaway character on ANOTHER player account: somebody who is not the tester.
---
--- whip refuses some things between two characters of one player (Josh, 8 Oct 2026): money between
--- them and access to each other's accounts (Config.BlockOwnCharacterTransfers), and a second
--- character at a job (Config.JobOneCharacterPerAccount). So a test that needs "someone else" must
--- not borrow one of the tester's own characters, as "any other character in the database" often is.
--- A users row is made for it; hand its userId to DisposeStranger in teardown (the character goes
--- with it, ON DELETE CASCADE).
---@return number|nil charId
---@return number|nil userId
function MakeStranger()
    local ok, userId = pcall(MySQL.insert.await, "INSERT INTO `users` (`license`, `name`) VALUES (?, '_test stranger')",
        { ('_test:stranger:%d:%d'):format(os.time(), math.random(1, 1000000000)) })
    if not ok or not userId then return nil end
    local ok2, charId = pcall(MySQL.insert.await,
        "INSERT INTO `characters` (`userId`, `firstName`, `lastName`, `dateOfBirth`) VALUES (?, '_test', '_stranger', '1990-01-01')",
        { userId })
    if not ok2 or not charId then
        pcall(MySQL.query.await, 'DELETE FROM `users` WHERE `userId` = ?', { userId })
        return nil
    end
    return charId, userId
end

--- Remove MakeStranger's account row and its character. Dispose of anything that keeps a record of
--- the character first (a test bank account: DisposeTestAccount), or this is refused and says so.
---@param userId number|nil
function DisposeStranger(userId)
    if not userId then return end
    -- Only a row MakeStranger made (its license): a wrong id from a test, or any other resource calling the export,
    -- must never delete a real account and its characters with it (ON DELETE CASCADE).
    local ok, err = pcall(MySQL.query.await,
        "DELETE FROM `users` WHERE `userId` = ? AND `license` LIKE '\\_test:stranger:%'", { userId })
    if not ok then print(('[whip_test] could not remove test stranger %s: %s'):format(tostring(userId), tostring(err))) end
end

--- Open a container and assert it ACTUALLY opened.
---
--- ClientOpenContainer returns true when the CLIENT acknowledged, which it does after a fixed
--- delay whether or not the server agreed. So a container placed out of reach still "opens" as
--- far as that return value goes, and every later assertion then aims at nothing.
---
--- ASKS ABOUT THE NAMED CONTAINER, not about "the" open one. This used to compare
--- GetOpenContainer(source) to the id it wanted, which worked while a container had at most one
--- viewer and a player at most one container. Neither is true now: a player can be inside several
--- stores at once, so GetOpenContainer returns whichever membership pairs() reaches first, and
--- comparing to it asserts iteration order. A membership test asks the question that survives.
---
--- "Held by someone else" is gone from the message because that outcome no longer exists —
--- Containers.tryOpen always admits the caller.
---@param source number
---@param containerId number
function OpenContainerOrFail(source, containerId)
    counted()
    ClientOpenContainer(source, containerId)
    if not exports.whip_core:__TestIsViewer(source, 'container:' .. tostring(containerId)) then
        -- NAME WHAT IS ALREADY OPEN. The most common cause of this failure is not distance or
        -- access at all — it is an EARLIER test that failed partway and never reached its close,
        -- because the client refuses to open a second inventory UI over the first. That reports
        -- here as a fresh defect in an innocent test while the real failure is somewhere above.
        local ok, open = pcall(exports.whip_core.__TestViewsOf, exports.whip_core, source)
        local leaked = (ok and open and #open > 0)
            and ('; player still has open: ' .. table.concat(open, ', ')
                 .. ' — an earlier test probably failed before its close')
            or ''
        error(('container %s did not open — too far away, no access, or its contents would not load%s')
            :format(tostring(containerId), leaked), 2)
    end
end

--- Open a vehicle storage and assert it ACTUALLY opened.
---
--- Same trap as OpenContainerOrFail: ClientOpenVehicleStorage returns true when the CLIENT
--- acknowledged, which it does after a fixed delay regardless of what the server decided.
---
--- THE TWO KINDS OF STORAGE ARE NOW REACHED DIFFERENTLY, and the helper has to know that.
---
--- A boot is opened from outside and still names its vehicle, so it keeps a distance check.
--- The glovebox and the ignition are only reachable from inside, so whip_core reads which
--- vehicle the player is SITTING IN and ignores the id on the wire entirely. Sending 0 for those
--- is deliberate: it proves the server resolved the vehicle itself rather than passing by
--- accident because the id we sent happened to be right.
---
--- Asserts membership of the named store rather than comparing against GetOpenVehicleStorage,
--- which — like GetOpenContainer — now returns an arbitrary one of however many stores the player
--- is inside.
---@param source number
---@param vehicleId number
---@param storageType string  'trunk' | 'glovebox' | 'key'
---@param plate string|nil  required for glovebox/key: the player must be seated first
---@param seat number|nil   -1 driver (default), 0 passenger
function OpenVehicleStorageOrFail(source, vehicleId, storageType, plate, seat)
    counted()
    if storageType == 'trunk' then
        ClientOpenVehicleStorage(source, vehicleId, storageType, 5000)
    else
        if not plate then
            error(('OpenVehicleStorageOrFail: "%s" needs a plate — it is only reachable from inside the vehicle')
                :format(tostring(storageType)), 2)
        end
        ClientEnterVehicle(source, plate, seat or -1, 5000)
        ClientOpenVehicleStorage(source, 0, storageType, 5000)
    end

    local storeId = ('vehicle:%s:%s'):format(tostring(vehicleId), tostring(storageType))
    if not exports.whip_core:__TestIsViewer(source, storeId) then
        error(('vehicle %s storage "%s" did not open — %s')
            :format(tostring(vehicleId), tostring(storageType),
                storageType == 'trunk' and 'out of range or locked?' or 'not seated in that vehicle?'), 2)
    end
end

--- Create a container within reach of the player, so the open distance check passes.
--- Containers created at the world origin cannot be opened and every downstream assertion
--- in that test then aims at nothing.
---@param source number
---@param def table  CreateContainer fields; x/y/z are supplied
---@return table container
--- RETURNS THE CONTAINER DEFINITION, NOT AN ID. The id is `.containerId` on it.
---
--- Worth stating because "create" reads like it hands back a handle, and passing the whole table
--- on to something expecting a number fails a long way from the call — the insert has already
--- yielded, so the error surfaces inside oxmysql's stack with no mention of the test that caused
--- it. That has now caught two callers.
---@param source number
---@param def table
---@return table containerDef
function CreateContainerNearPlayer(source, def)
    local ped = GetPlayerPed(source)
    local pos = GetEntityCoords(ped)
    def.x = pos.x + 2.0
    def.y = pos.y
    def.z = pos.z
    def.heading = def.heading or 0.0
    local c, err = exports.whip_core:CreateContainer(def)
    if not c then
        error(('CreateContainerNearPlayer failed: %s'):format(tostring(err)), 2)
    end
    return c
end

--- Put a known quantity of an item in a specific slot, clearing whatever is there first.
--- Tests must not assume a slot is free: modules run in order and leak into low slots.
---@param source number
---@param container string
---@param slot number
---@param item string
---@param amount number
function SeedSlot(source, container, slot, item, amount)
    -- By address, through the same calls a resource uses (09-24: RemoveItemFromSlot and PlaceItemAt
    -- were removed). Clearing an empty slot answers false, which is fine here.
    local addr = PocketAddr(source, container, slot)
    exports.whip_core:StoreTake(addr)
    local ok, err = exports.whip_core:StoreGive(addr, item, amount)
    if not ok then
        error(('SeedSlot(%s[%d] = %s x%d) failed: %s')
            :format(container, slot, item, amount, tostring(err)), 2)
    end
end

--- The whip address of one of a player's pocket slots: `{ kind = 'player', id, sub, slot }` — what
--- GetItemAt, StoreTake, StoreGive and SetItemMetadata take. `container` is the pocket
--- ('player' | 'accessory'); leave the slot out for the whole pocket.
---@param source number
---@param container string|nil  default 'player'
---@param slot number|nil
---@return table
function PocketAddr(source, container, slot)
    return { kind = 'player', id = source, sub = container or 'player', slot = slot }
end

--- Assert a query returns exactly `count` rows, flushing first.
---@param query string
---@param params table
---@param count number
---@param label string
function assertDbRowCount(query, params, count, label)
    counted()
    FlushPersistence()
    local rows = DbQuery(query, params)
    if #rows ~= count then
        error(('%s: expected %d row(s), got %d'):format(label or 'assertDbRowCount', count, #rows), 2)
    end
end

-- ============================================
-- Client Exec Helper — ask client to fire a
-- whip_core event and wait for confirmation
-- ============================================

-- Every wait helper used to share ONE `_execDone` boolean, so a late ack from an already
-- timed-out call satisfied the NEXT wait — a timeout could silently look like a success on
-- the following operation. Each request now carries a monotonic token and only the matching
-- ack counts; stale acks are discarded.
local _execToken     = 0
local _execDoneToken = nil
local _cbResults     = nil   -- what the last ClientCallback's callback answered

RegisterNetEvent('whip_test:clientExecDone', function(token)
    if source == testSource then
        _execDoneToken = token
    end
end)

-- The ack for ClientCallback, carrying the callback's answer. Results are stored BEFORE the token,
-- so the waiting side never sees its token with the previous call's results.
RegisterNetEvent('whip_test:clientCallbackDone', function(token, results)
    if source == testSource then
        _cbResults     = results
        _execDoneToken = token
    end
end)

--- How many outcomes whip_core has recorded for a secure event; nil when it is not one.
---@param serverEvent string|nil
---@return number|nil
local function eventSeq(serverEvent)
    if not serverEvent then return nil end
    local ok, n = pcall(function() return exports.whip_core:__TestEventSeq(serverEvent) end)
    return ok and n or nil
end

--- How long to wait for the server to finish a request once the client has sent it. Handlers
--- that wait on the database finish in milliseconds; this only has to outlast a slow disk.
local SERVER_OUTCOME_MS = 5000

--- Issue a client request and block until its OWN ack arrives — and, when it fires a whip_core
--- secure event, until the SERVER has finished with it.
---
--- THE ACK ALONE MEANT "THE CLIENT WAITED HALF A SECOND". The client fires the event, sleeps a
--- fixed 500ms and says done, so a handler still waiting on the database was often mid-flight when
--- the test read the result — and a refusal read through __TestLastReject could be the previous
--- test's. The outcome counter (__TestEventSeq) moves when the handler returns or the event is
--- refused, so waiting for it to move is waiting for the answer to THIS request.
---
--- Events that are not secure events (the callback transport, whip_test's own) have no counter and
--- keep the old ack-only behaviour.
---@param source number
---@param eventName string          whip_test event to fire on the client
---@param timeout number|nil
---@param serverEvent string|nil    the whip_core event the client will fire, to wait on its outcome
---@param ... any
---@return boolean completed  false when the client never acked, or the server never answered
local function execAndWait(source, eventName, timeout, serverEvent, ...)
    _execToken = _execToken + 1
    local myToken = _execToken
    _execDoneToken = nil

    local before = eventSeq(serverEvent)

    TriggerClientEvent(eventName, source, myToken, ...)

    local deadline = GetGameTimer() + (timeout or 5000)
    local acked = false
    while GetGameTimer() < deadline do
        if _execDoneToken == myToken then acked = true break end
        Wait(50)
    end
    if not acked then return false end
    if before == nil then return true end

    return waitFor(function()
        local n = eventSeq(serverEvent)
        return n ~= nil and n > before
    end, SERVER_OUTCOME_MS) and true or false
end

--- Ask client to fire a whip_core event and wait until the server has finished with it.
---
--- A true return means the server ANSWERED — accepted or refused. Read which with
--- assertLastReject; do not treat true as "it worked".
---@return boolean completed
function ClientExecWait(source, eventName, timeout, ...)
    return execAndWait(source, 'whip_test:clientExecWait', timeout, eventName, eventName, ...)
end

--- Ask client to fire an event (no wait).
function ClientExec(source, eventName, ...)
    TriggerClientEvent('whip_test:clientExec', source, eventName, ...)
end

--- Ask client to open a container and wait for the server's answer.
--- NOTE: a true return means the server answered, not that it agreed. Use OpenContainerOrFail,
--- which checks the player is actually a viewer.
function ClientOpenContainer(source, containerId, timeout)
    return execAndWait(source, 'whip_test:openContainer', timeout or 5000,
        'whip_core:server:openContainer', containerId)
end

--- Ask client to close a container and wait.
function ClientCloseContainer(source, containerId, timeout)
    return execAndWait(source, 'whip_test:closeContainer', timeout or 3000, nil, containerId)
end

--- Ask the client to close any open inventory UI, and wait for it.
---
--- whip_core refuses to open a UI over an existing one and releases the server session it
--- was asked to display when it does. Anything that opens a session — the admin inventory
--- inspect especially — must therefore start from a closed UI, or the session it just
--- created is torn down before the test can use it.
---@param source number
---@param timeout number|nil
function ClientCloseAllUI(source, timeout)
    return execAndWait(source, 'whip_test:closeAllUI', timeout or 3000, nil)
end

--- Ask client to leave vehicle and wait.
function ClientLeaveVehicle(source, timeout)
    return execAndWait(source, 'whip_test:leaveVehicle', timeout or 5000, nil)
end

--- Press "cancel" on the progress bar a test put up with the server Progress export, and wait.
---
--- A bar the server shows belongs to the resource that asked for it — whip_test — so whip_test's
--- client may cancel it (CancelProgress only cancels the caller's own bar).
function ClientCancelProgress(source, timeout)
    return execAndWait(source, 'whip_test:cancelProgress', timeout or 3000, nil)
end

--- Ask client to get INTO a vehicle by plate, and wait.
---
--- Needed because whip_core resolves the glovebox and the ignition from the seat the player is
--- sitting in rather than from an id sent over the wire — so a test that wants either of them
--- has to put the player in the car first. Takes a plate rather than a vehicleId because the
--- CLIENT has to find the entity, and a plate is the one identifier both sides agree on.
---@param source number
---@param plate string
---@param seat number|nil  -1 driver (default), 0 front passenger
---@param timeout number|nil
function ClientEnterVehicle(source, plate, seat, timeout)
    return execAndWait(source, 'whip_test:enterVehicle', timeout or 5000, nil, plate, seat or -1)
end

--- Ask client to open vehicle storage and wait for the server's answer.
function ClientOpenVehicleStorage(source, vehicleId, storageType, timeout)
    return execAndWait(source, 'whip_test:openVehicleStorage', timeout or 5000,
        'whip_core:server:openVehicleStorage', vehicleId, storageType)
end

--- Ask client to close vehicle storage and wait.
function ClientCloseVehicleStorage(source, vehicleId, storageType, timeout)
    return execAndWait(source, 'whip_test:closeVehicleStorage', timeout or 3000, nil, vehicleId, storageType)
end

--- Ask the client to run a whip_core SecureCallback as the real tester, and hand back what it
--- answered.
---
--- The only way a server test can reach a callback: they answer the client that asked, and a
--- callback's rules (rate limit, ACE, the dead gate, params) are enforced on that path alone.
---@param source number
---@param name string       the callback name, without 'cb:'
---@param timeout number|nil
---@param ... any           its arguments
---@return boolean answered  false on timeout
---@return table|nil results  table.pack of what the callback returned
function ClientCallback(source, name, timeout, ...)
    _cbResults = nil
    -- Past the client's own 10 s callback timeout, so a callback the server never answers comes
    -- back as "answered with nothing" rather than as a timeout here.
    local answered = execAndWait(source, 'whip_test:clientCallback', timeout or 12000, nil, name, ...)
    return answered, _cbResults
end

-- ============================================
-- Test Module Registry
-- ============================================

TestModules = {}

function RegisterTestModule(mod)
    TestModules[#TestModules + 1] = mod
end

-- ============================================
-- The kit for other resources' tests (lib/kit.lua)
-- ============================================
--
-- A resource's own tests, run by /test on its own card: exports.whip_test:RegisterTestModule({ category, tests =
-- { { name, fn(source) } }, setup?, teardown? }), through lib/kit.lua's WhipTest.module, which counts the
-- assertions each test made and answers them. The same category again replaces it; a resource's modules and card go
-- when it stops. ctx is a copy on the resource's side: keep a module's state in its own locals.
exports('RegisterTestModule', function(mod)
    local owner = GetInvokingResource() or GetCurrentResourceName()
    if type(mod) ~= 'table' or type(mod.category) ~= 'string' or mod.category == '' or type(mod.tests) ~= 'table' then
        return false, 'a test module is { category = "...", tests = { { name = "...", fn = function(source) end } } }'
    end
    for i, t in ipairs(mod.tests) do
        if type(t) ~= 'table' or type(t.name) ~= 'string' or t.fn == nil then return false, ('test %d needs a name and fn'):format(i) end
    end
    for i = #TestModules, 1, -1 do
        if TestModules[i]._owner == owner and TestModules[i].category == mod.category then table.remove(TestModules, i) end
    end
    mod._external, mod._owner = true, owner
    mod.order = tonumber(mod.order) or 1000
    RegisterTestModule(mod)
    AddTestSection(owner, mod.category)
    return true
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then return end
    for i = #TestModules, 1, -1 do
        if TestModules[i]._owner == res then table.remove(TestModules, i) end
    end
    RemoveTestSection(res)
end)

--- A throwaway account and character in the database, for a test that needs someone who is not you (a key given,
--- a payment sent): (charId, userId), or nil. Test seams only. DisposeStranger(userId) removes both.
exports('MakeStranger', function()
    local ok, on = pcall(function() return exports.whip_core:__TestSeamsEnabled() end)
    if not (ok and on) then return nil end
    return MakeStranger()
end)
exports('DisposeStranger', function(userId)
    local ok, on = pcall(function() return exports.whip_core:__TestSeamsEnabled() end)   -- as MakeStranger
    if not (ok and on) then return false end
    DisposeStranger(userId)
    return true
end)

-- ============================================
-- Inventory Cleanup — remove all test items
-- ============================================

-- Snapshot of the tester's real inventory, captured before a run and restored after it.
--
-- This used to be a blind "nuke every slot in every container" loop with no _test_ filter,
-- run three times per /test. It destroyed the invoking character's ENTIRE inventory —
-- weapons, ammo, phone, everything — and because it ran both before and after the suite,
-- an empty inventory looked like the normal post-test state rather than data loss.
local _inventorySnapshot = nil

--- The containers to snapshot and restore, ASKED FOR rather than listed.
---
--- This was `{ 'player', 'backpack', 'accessory' }`. A hardcoded list here is worse than
--- elsewhere: the snapshot/restore pair is what protects the tester's real inventory, so a
--- container missing from it is silently NOT restored — the suite would run, wipe its scratch
--- items from a container it never captured, and hand back an inventory short of whatever had
--- been in there. It fails as data loss, not as a red test.
---
--- pcall'd to match ContainerSlotCount below: an older whip_core without the export degrades
--- to the historic list rather than erroring the whole runner.
local TEST_CONTAINERS = (function()
    local ok, list = pcall(function()
        return exports.whip_core:GetPockets()
    end)
    if ok and type(list) == 'table' and #list > 0 then return list end
    return { 'player', 'accessory' }
end)()

--- Real slot count for a player pocket, falling back to a safe upper bound. pcall'd so a whip_core
--- that cannot answer degrades rather than erroring the runner. (Note: `exports.x:Y` is only valid
--- AS A CALL; it cannot be tested for existence as a value.)
---@param container string
---@return number
local function ContainerSlotCount(container)
    local ok, n = pcall(function()
        return exports.whip_core:GetPocketSlots(container)
    end)
    if ok and type(n) == 'number' and n > 0 then return n end
    return 50
end

--- Capture the tester's inventory, including metadata, so it can be put back exactly.
---@param source number
---@return table|nil snapshot
function SnapshotInventory(source)
    local inv = exports.whip_core:GetInventory(source)
    if not inv then return nil end

    local snap = {}
    for _, container in ipairs(TEST_CONTAINERS) do
        snap[container] = {}
        local maxSlots = ContainerSlotCount(container)
        for slot = 1, maxSlots do
            local data = inv[container] and inv[container][slot]
            if data and data.item then
                snap[container][slot] = { item = data.item, amount = data.amount, metadata = data.metadata }
            end
        end
    end
    return snap
end

--- Restore the tester's inventory from a snapshot, discarding anything the suite added.
--- Only clears the slots it is about to rewrite plus any the suite left behind — it never
--- touches a container it did not snapshot.
---@param source number
---@param snap table
---
--- EVERY PUT-BACK IS CHECKED. This used to read only pcall's status, which is true whenever the
--- export did not THROW — and the put-back refuses by returning (false, reason). A refused slot was
--- cleared above and never refilled: one of the tester's real items, gone, with nothing said. (The
--- run's Medkit slot made one such refusal itself, until CleanupTestItems gave slot 4 back first.)
---
--- Metadata goes in WITH the item. Placing first and then calling SetItemMetadata ran the item's
--- metadata generator in between, minting a fresh serial or uid that was then overwritten.
---
--- A refused slot falls back to AddItem: any free slot, or the ground at the tester's feet when
--- there is none. If that fails too, the item is printed in full so it can be given back by hand.
local function RestoreInventory(source, snap)
    for _, container in ipairs(TEST_CONTAINERS) do
        local maxSlots = ContainerSlotCount(container)
        for slot = 1, maxSlots do
            pcall(exports.whip_core.StoreTake, exports.whip_core, PocketAddr(source, container, slot))
        end
        for slot, data in pairs(snap[container] or {}) do
            local called, placed, why = pcall(exports.whip_core.StoreGive, exports.whip_core,
                PocketAddr(source, container, slot), data.item, data.amount, data.metadata, 'whip_test restore')
            if not (called and placed) then
                local addCalled, added = pcall(exports.whip_core.AddItem, exports.whip_core,
                    source, data.item, data.amount, data.metadata)
                if addCalled and added then
                    print(('[whip_test] %s x%d could not go back into %s slot %d (%s) — given back through AddItem instead (a free slot, or the ground if full)')
                        :format(data.item, data.amount, container, slot, tostring(called and why or placed)))
                else
                    print(('[whip_test] ^1COULD NOT RESTORE %s x%d (was %s slot %d, metadata %s) — give it back by hand^7')
                        :format(data.item, data.amount, container, slot,
                            data.metadata and json.encode(data.metadata) or 'none'))
                end
            end
        end
    end
end

--- Empty the tester's containers so the suite starts from a known state.
--- ONLY safe once a snapshot exists — otherwise this is the old data-destroying nuke.
---@param source number
function ClearTesterInventory(source)
    if not _inventorySnapshot then
        print('[whip_test] ClearTesterInventory called with no snapshot — refusing to empty a real inventory')
        return
    end
    for _, container in ipairs(TEST_CONTAINERS) do
        local maxSlots = ContainerSlotCount(container)
        for slot = 1, maxSlots do
            pcall(exports.whip_core.StoreTake, exports.whip_core, PocketAddr(source, container, slot))
        end
    end
end

--- Put the tester's inventory back the way the suite found it.
---
--- REFUSES to do anything if no snapshot was taken. Losing the suite's leftovers is a
--- cosmetic problem; deleting a real player's items is not, so when in doubt we do nothing.
---@param source number
function CleanupTestItems(source)
    if not _inventorySnapshot then
        print('[whip_test] CleanupTestItems called with no snapshot — refusing to touch the inventory')
        untypeTestSlot()
        return
    end
    untypeTestSlot()   -- first, so whatever the tester had in slot 4 can go back into it
    RestoreInventory(source, _inventorySnapshot)
    _inventorySnapshot = nil   -- consumed; a later stray call must not re-apply a stale snapshot

    -- Close inventory if open
    pcall(function()
        TriggerClientEvent('whip_test:cleanup', source)
    end)
end

--- Take the snapshot. Call once at the start of a run, before any test touches items.
---@param source number
---@return boolean ok
function BeginInventoryProtection(source)
    _inventorySnapshot = SnapshotInventory(source)
    if not _inventorySnapshot then
        print('[whip_test] could not snapshot inventory — aborting rather than risk item loss')
        return false
    end
    return true
end

-- ============================================
-- Chat Output
-- ============================================

local function chatMsg(source, text)
    TriggerClientEvent('chat:addMessage', source, { args = { '[TEST]', text } })
end

-- ============================================
-- Run Server Tests
-- ============================================

--- The server-wide switches as they were when the run started (__TestHarnessState). A module that
--- leaves one different is reported and the switch is put back — see the leak check below.
local _harnessBaseline = nil

--- Put back whatever server-wide switch a module left flipped, and say which.
---@param source number
---@return table leaked  descriptions, empty when nothing was out of place
local function restoreHarnessState(source)
    local leaked = {}
    if not _harnessBaseline then return leaked end

    local okS, now = pcall(function() return exports.whip_core:__TestHarnessState(source) end)
    if not okS or type(now) ~= 'table' then return leaked end

    if now.faultArmed then
        leaked[#leaked + 1] = ('a database fault still armed ("%s")'):format(tostring(now.faultArmed))
        pcall(function() exports.whip_core:__TestSetDbFaultMode(nil) end)
    end
    if now.rawFaultArmed then
        leaked[#leaked + 1] = ('a raw-query fault still armed ("%s")'):format(tostring(now.rawFaultArmed))
        pcall(function() exports.whip_core:__TestFailNextQuery(nil) end)
    end
    if now.flushPaused and not _harnessBaseline.flushPaused then
        leaked[#leaked + 1] = 'the flush thread left PAUSED'
        pcall(function() exports.whip_core:__TestPauseFlushThread(false) end)
    end
    for kindId, field in pairs({ player = 'playerDurability', container = 'containerDurability' }) do
        if now[field] ~= _harnessBaseline[field] then
            leaked[#leaked + 1] = ('%s durability left as %s'):format(kindId, tostring(now[field]))
            pcall(function() exports.whip_core:__TestSetDurability(kindId, _harnessBaseline[field]) end)
        end
    end
    if now.rateLimitBypass and not _harnessBaseline.rateLimitBypass then
        leaked[#leaked + 1] = 'rate limiting left switched off'
        pcall(function() exports.whip_core:__TestRateLimitBypass(false) end)
    end
    if (now.phantoms or 0) > (_harnessBaseline.phantoms or 0) then
        leaked[#leaked + 1] = ('%d phantom player(s) left in Players'):format(now.phantoms)
        pcall(function() exports.whip_core:__TestPhantoms(0) end)
    end
    if now.dead and not _harnessBaseline.dead then
        leaked[#leaked + 1] = 'the tester left flagged DEAD'
        pcall(function() exports.whip_core:__TestSetDeadFlag(source, false) end)
    end
    return leaked
end

--- Anything left in the tester's pockets. The run starts from an EMPTY inventory (ClearTesterInventory),
--- so after a module's teardown every item there is one that module forgot — and the next module,
--- finding a slot it assumed was free, turns a move into a swap and fails for a reason that is not
--- its own.
---@param source number
---@return string|nil description
local function leftoverItems(source)
    local okI, inv = pcall(function() return exports.whip_core:GetInventory(source) end)
    if not okI or type(inv) ~= 'table' then return nil end

    local found = {}
    for _, container in ipairs(TEST_CONTAINERS) do
        for slot = 1, ContainerSlotCount(container) do
            local data = inv[container] and inv[container][slot]
            if data and data.item then
                found[#found + 1] = ('%s x%s (%s %d)'):format(data.item, tostring(data.amount), container, slot)
            end
        end
    end
    if #found == 0 then return nil end
    return table.concat(found, ', ')
end

--- Is this module part of the run? Every module when no section was picked (the full suite);
--- otherwise only the modules shared/sections.lua puts in that section.
---@param mod table
---@param sectionId string|nil
---@return boolean
local function inRun(mod, sectionId)
    return sectionId == nil or TestSectionOf(mod.category) == sectionId
end

---@param source number
---@param sectionId string|nil  one section from the /test menu, or nil for the full suite
local function RunServerTests(source, sectionId)
    -- Sort modules by filename order (they register via glob)
    table.sort(TestModules, function(a, b) return (a.order or 99) < (b.order or 99) end)

    for _, mod in ipairs(TestModules) do
        if not running then break end

        -- A SECTION RUN LEAVES OUT EVERY MODULE OUTSIDE IT. The label is the last thing in the loop
        -- body, so this jump does not enter the scope of the locals declared below it.
        if not inRun(mod, sectionId) then goto nextModule end

        -- THE RUNNER OWNS ctx, AND HANDS IT TO SETUP TO FILL. Setup used to build its own and
        -- return it, so a setup that created a container and then threw (or skipped) lost the
        -- only record of it: teardown got an empty table and the container stayed in the
        -- database for good. A setup that fills this as it goes can always be cleaned up after.
        -- A setup that still RETURNS a table is honoured, so old modules keep working.
        local ctx = {}
        local setupFailed  = nil
        local setupSkipped = nil

        -- Setup
        if mod.setup then
            local ok, result = pcall(mod.setup, source, ctx)
            if not ok then
                if IsSkip(result) then
                    -- A module may legitimately declare its preconditions unmet (e.g. it
                    -- needs a second character on the server). That is a skip, not a failure.
                    setupSkipped = SkipReason(result)
                    chatMsg(source, ('^3- %s > SETUP SKIPPED: %s'):format(mod.category, setupSkipped))
                else
                    setupFailed = tostring(result)
                    chatMsg(source, ('^1✗ %s > SETUP FAILED: %s'):format(mod.category, setupFailed))
                end
            elseif type(result) == 'table' then
                ctx = result
            end
        end

        if setupFailed or setupSkipped then
            -- Emit one result PER TEST, not a single 'SETUP' row.
            -- A single row silently removed the module's whole test list from the report,
            -- so a run where three modules died in setup still read "284 passed" and there
            -- was no way to tell that from "284 of 340".
            for _, test in ipairs(mod.tests) do
                results[#results + 1] = {
                    category = mod.category,
                    name     = ('%s: %s'):format(setupSkipped and 'SETUP SKIPPED' or 'SETUP FAILED', test.name),
                    passed   = false,
                    skipped  = setupSkipped and true or nil,
                    error    = setupSkipped or setupFailed,
                    duration = 0,
                    side     = 'server',
                }
            end
        else
            -- Run tests
            for _, test in ipairs(mod.tests) do
                if not running then break end

                local start = GetGameTimer()
                AssertCount = 0
                local ok, err = pcall(test.fn, source, ctx)
                local duration = GetGameTimer() - start

                -- Another resource's test (RegisterTestModule export) counts its own assertions in its own Lua and
                -- answers the count (lib/kit.lua wraps each test so).
                if ok and mod._external and type(err) == 'number' then AssertCount = err; err = nil end

                -- A test that ran to the end without checking anything proved nothing.
                if ok and AssertCount == 0 then
                    ok, err = false, 'no assertion ran — this test cannot fail as written'
                end

                local wasSkipped = (not ok) and IsSkip(err)
                -- Written out: `ok and nil or X` is always X, so a PASS carried the error "nil".
                local errText = nil
                if not ok then errText = wasSkipped and SkipReason(err) or tostring(err) end

                results[#results + 1] = {
                    category = mod.category,
                    name     = test.name,
                    passed   = ok,
                    skipped  = wasSkipped or nil,
                    error    = errText,
                    duration = duration,
                    side     = 'server',
                }

                if ok then
                    chatMsg(source, ('^2✓ %s > %s ^7(%dms)'):format(mod.category, test.name, duration))
                elseif wasSkipped then
                    chatMsg(source, ('^3- %s > %s ^7(skipped: %s)'):format(mod.category, test.name, SkipReason(err)))
                else
                    chatMsg(source, ('^1✗ %s > %s^7: %s'):format(mod.category, test.name, tostring(err)))
                end

                Wait(50)
            end
        end

        -- Teardown — ALWAYS runs, including after a failed setup, and a failure here is a
        -- real recorded failure rather than a yellow chat line nobody reads. Teardowns are
        -- written to tolerate a partially-populated (or nil) ctx.
        if mod.teardown then
            -- `ctx or {}`: teardown now runs even when setup failed, and most teardowns
            -- index ctx directly. Passing an empty table lets their `if ctx.foo then`
            -- guards work instead of erroring on a nil index.
            local ok2, err2 = pcall(mod.teardown, ctx or {}, source)
            if not ok2 then
                results[#results + 1] = {
                    category = mod.category,
                    name     = 'TEARDOWN',
                    passed   = false,
                    error    = tostring(err2),
                    duration = 0,
                    side     = 'server',
                    meta     = true,   -- not one of the module's tests; see SendReport's count
                }
                chatMsg(source, ('^1✗ %s > TEARDOWN FAILED: %s'):format(mod.category, tostring(err2)))
            end
        end

        -- ####################################################################
        -- LEAK CHECK — BLAME THE MODULE THAT LEAKED, NOT THE ONE THAT TRIPPED OVER IT.
        --
        -- Open panels and open store views are SESSION state: they outlive the test that made
        -- them, and the client refuses to open a second inventory UI over the first. So one
        -- test failing before its close does not cost one result, it costs every later test
        -- that needs to open something — and those failures name the innocent module, with a
        -- message about distance or access that sends you looking at the wrong subsystem.
        --
        -- This has bitten the suite twice for real: a container left open by 07 broke the two
        -- tests after it, and a vehicle boot dropped between two tests in 05 surfaced as "No
        -- container open" inside TakeItemFrom, which had done nothing wrong.
        --
        -- Detecting it HERE, between modules, means the report says which module leaked and
        -- what it leaked. Clearing it means the next module starts from a known state instead
        -- of inheriting the mess. Both halves matter: without the clear this would report the
        -- same leak for every remaining module.
        -- ####################################################################
        if source then
            local leaked = {}

            -- Panels are among the stores a player has open (GetOpenStores; GetOpenPanels is gone).
            local okP, open = pcall(exports.whip_core.GetOpenStores, exports.whip_core, source)
            local ids = {}
            for _, s in ipairs(okP and type(open) == 'table' and open or {}) do
                if s.kind == 'panel' then ids[#ids + 1] = tostring(s.id) end
            end
            if #ids > 0 then
                leaked[#leaked + 1] = 'panel(s) left open: ' .. table.concat(ids, ', ')
                pcall(exports.whip_core.ClosePanel, exports.whip_core, source)
            end

            local okV, views = pcall(exports.whip_core.__TestViewsOf, exports.whip_core, source)
            if okV and type(views) == 'table' and #views > 0 then
                leaked[#leaked + 1] = 'store view(s) left open: ' .. table.concat(views, ', ')
                pcall(exports.whip_core.__TestReleaseViews, exports.whip_core, source)
            end

            -- Server-wide switches: an armed fault, a paused flush thread, a flipped durability.
            -- Worse leaks than an open panel — each one changes what EVERY later module is testing.
            for _, what in ipairs(restoreHarnessState(source)) do
                leaked[#leaked + 1] = what
            end

            local items = leftoverItems(source)
            if items then
                leaked[#leaked + 1] = 'items left in the tester\'s inventory: ' .. items
                ClearTesterInventory(source)
            end

            if #leaked > 0 then
                results[#results + 1] = {
                    category = mod.category,
                    name     = 'LEAKED STATE',
                    passed   = false,
                    error    = table.concat(leaked, '; ')
                               .. ' — a test almost certainly failed before its close, or a teardown '
                               .. 'missed it. Cleared before the next module, so later failures are '
                               .. 'not caused by this.',
                    duration = 0,
                    side     = 'server',
                    meta     = true,   -- not one of the module's tests; see SendReport's count
                }
                chatMsg(source, ('^1✗ %s > LEAKED STATE: %s'):format(
                    mod.category, table.concat(leaked, '; ')))
            end
        end

        ::nextModule::
    end
end

-- ============================================
-- Receive Client Results & Send Report
-- ============================================

--- Which half of the run is in progress: 'server', 'client', or nil when nothing is. The client half
--- ends with the client's results arriving — or the deadline below — and /teststop needs to know
--- which half it is interrupting.
local phase = nil

--- Bumped by every /test, so a deadline armed by an earlier run can never end a later one.
local runId = 0

--- os.time() when the run started, for removing the run's own activity-log rows afterwards.
local runStartedAt = 0

--- How long the client half may take. It has no timeout of its own: a client test that hangs never
--- sends its results, and the run then sat "running" with the tester's inventory unrestored until
--- someone typed /teststop.
local CLIENT_PHASE_MS = 180000

--- What the client said it ran: { expected = n, orders = { ... } }. Checked in SendReport.
local clientInfo = nil

--- The section this run is testing (a shared/sections.lua id), or nil for the full suite.
local runSection = nil

--- How each section did the last time it ran, for the coloured status on its /test menu card:
--- [section id] = { passed, failed, skipped, at = os.time(), partial }. Memory only — a restart of
--- whip_test forgets it, and the cards simply read "not run yet" again.
local lastSectionResults = {}

RegisterNetEvent('whip_test:clientResults', function(clientResults, info)
    local src = source
    if src ~= testSource or phase ~= 'client' then return end

    for _, r in ipairs(clientResults) do
        results[#results + 1] = r
    end
    clientInfo = info

    SendReport(src)
end)

--- Remove the rows this run wrote into the tester's own activity timeline.
---
--- Every run clears the tester's inventory and puts it back, and both halves are logged — so each
--- real item the tester owned gained a "lost, by whip_test" and a "gained, by whip_test" row per
--- run, kept for thirty days, plus a row for every item a test handed out. The tester's timeline
--- became mostly test noise.
---
--- Narrow on purpose: this character, since this run started, and only rows whip_core attributed
--- to whip_test. Anything the tester's client did through the ordinary events is left alone.
---@param source number
local function purgeRunActivity(source)
    local player = exports.whip_core:GetPlayer(source)
    if not player or not player.charId then return end

    local okF = pcall(function() return exports.whip_core:FlushActivityLog() end)
    if not okF then return end

    local ok, res = pcall(MySQL.query.await,
        'DELETE FROM `activity_log` WHERE `charId` = ? AND `ts` >= ? AND `detail` LIKE ?',
        { player.charId, runStartedAt, '%by whip_test%' })
    if ok and res and (res.affectedRows or 0) > 0 then
        print(('[whip_test] removed %d activity-log row(s) this run wrote to your timeline')
            :format(res.affectedRows))
    end
end

function SendReport(source)
    -- ONCE PER RUN. The client's results and the client deadline can both arrive; whichever is
    -- second finds the phase already closed.
    if phase == nil then return end
    phase = nil

    local totalTime = GetGameTimer() - startTime
    local passed = 0
    local failed = 0
    local skipped = 0

    for _, r in ipairs(results) do
        if r.passed then passed = passed + 1
        elseif r.skipped then skipped = skipped + 1
        else failed = failed + 1 end
    end

    -- Expected total, so a run that quietly loses whole modules is visible.
    -- Previously a module whose setup died contributed one row instead of N, and the report
    -- had no way to show that "284 passed" was 284 of 340.
    -- Only the modules this run included: a section run is expected to leave the rest out.
    local expectedServer = 0
    for _, mod in ipairs(TestModules) do
        if inRun(mod, runSection) then
            expectedServer = expectedServer + #(mod.tests or {})
        end
    end
    -- `meta` rows (TEARDOWN, LEAKED STATE) are real failures but not tests, so they stay out of
    -- this count. LEAKED STATE used to be counted, which raised a false "modules were lost" — or,
    -- worse, cancelled out a module that really had been lost.
    local serverResults = 0
    for _, r in ipairs(results) do
        if r.side == 'server' and not r.meta then serverResults = serverResults + 1 end
    end

    local clientRows = 0
    for _, r in ipairs(results) do
        if r.side == 'client' and not r.meta then clientRows = clientRows + 1 end
    end
    -- Lost modules are a failed run, not a pass with a footnote: "ALL 284 TESTS PASSED" over a warning
    -- read as green when 56 tests never ran.
    local lost = serverResults ~= expectedServer
        or (clientInfo ~= nil and clientRows ~= (clientInfo.expected or clientRows))

    chatMsg(source, '')
    chatMsg(source, ('^7═══════════════════════════════════'):format())
    if failed == 0 and skipped == 0 and not lost then
        chatMsg(source, ('^2  ALL %d TESTS PASSED ^7(%.1fs)'):format(passed, totalTime / 1000))
    else
        chatMsg(source, ('^2  %d passed  ^1%d failed  ^3%d skipped%s  ^7(%.1fs)')
            :format(passed, failed, skipped, lost and '  ^1INCOMPLETE' or '', totalTime / 1000))
    end
    if serverResults ~= expectedServer then
        chatMsg(source, ('^1  ⚠ expected %d server results, got %d — modules were lost')
            :format(expectedServer, serverResults))
    end

    -- The same check for the client half, which the client has to tell us about: only it knows
    -- what registered. A client test FILE that throws while loading never registers at all, so the
    -- only trace it leaves is a gap in the module order numbers.
    if clientInfo then
        if clientRows ~= (clientInfo.expected or clientRows) then
            chatMsg(source, ('^1  ⚠ expected %d client results, got %d'):format(clientInfo.expected, clientRows))
        end

        -- The gap check needs every module's order, so it only means something on a full run: a
        -- section run leaves gaps on purpose.
        if runSection == nil then
            local have, highest = {}, 0
            for _, o in ipairs(clientInfo.orders or {}) do
                have[o] = true
                if o > highest then highest = o end
            end
            for o = 1, highest do
                if not have[o] then
                    chatMsg(source, ('^1  ⚠ no client test module with order %d — did its file fail to load?'):format(o))
                end
            end
        end
    end
    chatMsg(source, ('^7═══════════════════════════════════'):format())

    -- REMEMBERED PER SECTION, for the menu cards. A full run updates every section it touched; a
    -- section run only its own. TEARDOWN and LEAKED STATE rows count as failures here, because they
    -- are real ones even though they are not tests.
    local tally = {}
    for _, r in ipairs(results) do
        local sid = TestSectionOf(r.category)
        local t = tally[sid]
        if not t then
            t = { passed = 0, failed = 0, skipped = 0 }
            tally[sid] = t
        end
        if r.passed then t.passed = t.passed + 1
        elseif r.skipped then t.skipped = t.skipped + 1
        else t.failed = t.failed + 1 end
    end
    for sid, t in pairs(tally) do
        t.at      = os.time()
        t.partial = not running
        lastSectionResults[sid] = t
    end

    -- Post-test cleanup, THEN the log rows it wrote: restoring the inventory is itself logged.
    CleanupTestItems(source)
    purgeRunActivity(source)

    -- Send to NUI. The title says what was tested, so a section's report cannot be mistaken for a
    -- full run's.
    local section = runSection and TestSectionById(runSection)
    local report = {
        results   = results,
        passed    = passed,
        failed    = failed,
        skipped   = skipped,
        totalTime = totalTime,
        partial   = not running,
        title     = section and ('whip_core Test Report — ' .. section.label) or 'whip_core Test Report — Full Suite',
    }
    TriggerClientEvent('whip_test:showReport', source, report)
    -- Server-side too, for whatever started the run from code (StartTestRun): whip_devlink waits on it.
    TriggerEvent('whip_test:runFinished', source, report)

    running    = false
    testSource = nil
    runSection = nil
end

-- ============================================
-- Commands
-- ============================================

--- whip.devtools WITH DEVELOPER MODE ON (whip_core's HasDevTools, Josh 16 Oct 2026): the ACE alone only
--- lets a player turn developer mode on, and a run without it would be refused by every gated event it
--- fires. The ACE alone when whip_core is not running.
local function devAllowed(src)
    local ok, yes = pcall(function() return exports.whip_core:HasDevTools(src) end)
    if ok then return yes == true end
    return IsPlayerAceAllowed(src, 'whip.devtools')
end

local DEV_NEEDED = '^1You need whip.devtools, with developer mode on (/w).'

--- Every command in this file hands out items or drives dev machinery. Gated on the devtools
--- ACE the way /test and /testlong always were: "whip_test is not ensured in production" is a
--- convention, not a guard, and wherever the resource WAS running, /lootcrate and friends
--- were usable by any connected player, repeatedly.
local function demoAllowed(source)
    if source == 0 then return false end
    if not devAllowed(source) then
        exports.whip_core:NotifyPlayer(source, 'Dev only (developer mode on, /w)', 'error')
        return false
    end
    return true
end

--- Start a run: the full suite (sectionId nil) or one section of the /test menu.
---
--- Everything here used to be the body of /test itself. It is a function now because two things
--- start runs — the command (`/test all`, `/test vehicles`) and the menu's cards — and both must go
--- through exactly the same checks and the same inventory protection.
--- Says why in chat when it refuses, and answers (false, why) for StartTestRun's caller as well.
---@param source number
---@param sectionId string|nil  a shared/sections.lua id, or nil for every module
---@return boolean started, string|nil why
local function StartRun(source, sectionId)
    if running then
        chatMsg(source, '^3Tests are already running.')
        return false, 'Tests are already running.'
    end

    -- ONE THING AT A TIME. The endurance run holds the same inventory snapshot this would
    -- overwrite, and the load test fills Players with phantoms and switches rate limiting off —
    -- a /test on top of either tests a server nobody would run.
    if enduranceRunning then
        chatMsg(source, '^3The endurance test is running — /teststop it first.')
        return false, 'The endurance test is running.'
    end
    if LoadTestRunning and LoadTestRunning() then
        chatMsg(source, '^3The load test is running — stop it first.')
        return false, 'The load test is running.'
    end

    -- Without the seams nothing can be checked on disk, and every seam answers false or -1 when
    -- they are off — which reads as a failure of whatever was being tested, seconds later.
    local seamsOk, seamsOn = pcall(function() return exports.whip_core:__TestSeamsEnabled() end)
    if not (seamsOk and seamsOn) then
        chatMsg(source, '^1Config.EnableTestSeams is not true in whip_core — the suite cannot run without it.')
        return false, 'Config.EnableTestSeams is not true in whip_core.'
    end

    -- Put back anything a crashed earlier run left switched, THEN take the baseline the leak check
    -- compares against — otherwise a paused flush thread would become "normal" for this run.
    pcall(function() exports.whip_core:__TestSetDbFaultMode(nil) end)
    pcall(function() exports.whip_core:__TestFailNextQuery(nil) end)
    pcall(function() exports.whip_core:__TestPauseFlushThread(false) end)
    _harnessBaseline = exports.whip_core:__TestHarnessState(source)

    -- A DEAD TESTER FAILS HALF THE SUITE FOR A REASON THAT IS NOT A BUG. The framework refuses
    -- almost everything a dead player sends, so every test driven through the client would fail
    -- with a message about distance, access or a missing row.
    if _harnessBaseline.dead then
        chatMsg(source, '^1You are dead. Respawn or get revived, then run /test again.')
        return false, 'The tester is dead.'
    end

    testSource   = source
    results      = {}
    startTime    = GetGameTimer()
    runStartedAt = os.time()
    running      = true
    phase        = 'server'
    clientInfo   = nil
    runId        = runId + 1
    runSection   = sectionId

    local section = sectionId and TestSectionById(sectionId)
    if section then
        chatMsg(source, ('^7Testing %s...'):format(section.label))
    else
        chatMsg(source, '^7Starting the full whip_core test suite...')
    end

    -- Protect the tester's inventory BEFORE anything runs. The suite adds, removes and
    -- moves items on the invoking character; without a snapshot to restore from, cleanup
    -- has no way to tell the suite's leftovers from the player's own belongings.
    if not BeginInventoryProtection(source) then
        chatMsg(source, '^1Could not read your inventory — aborting so nothing gets lost.')
        running = false
        phase   = nil
        return false, 'Could not read the tester\'s inventory.'
    end
    chatMsg(source, '^7Inventory snapshotted — it will be restored when the run finishes.')
    untypeTestSlot()   -- a run that never reached its cleanup
    typeTestSlot()

    local myRun = runId

    CreateThread(function()
        -- Start on foot with nothing open: several tests need both, and a UI left up from before
        -- the run makes the client refuse to open anything the tests ask for.
        ClientCloseAllUI(source)
        ClientLeaveVehicle(source)

        -- Clear the tester's items so tests start from a known-empty inventory.
        -- Safe now: the snapshot above is what gets put back afterwards.
        ClearTesterInventory(source)
        Wait(200)
        chatMsg(source, '')

        -- Phase 1: Server tests
        RunServerTests(source, sectionId)

        -- Phase 2: Client tests (if not stopped) — the same section's, or all of them.
        if running then
            phase = 'client'
            chatMsg(source, '')
            chatMsg(source, '^7Running client tests...')
            TriggerClientEvent('whip_test:runClientTests', source, sectionId)
            -- Client will send results back via whip_test:clientResults — or not, if a client
            -- test hangs, so the run is closed from here after CLIENT_PHASE_MS either way.
            SetTimeout(CLIENT_PHASE_MS, function()
                if runId ~= myRun or phase ~= 'client' then return end
                results[#results + 1] = {
                    category = 'Client',
                    name     = 'CLIENT PHASE TIMED OUT',
                    passed   = false,
                    error    = ('no client results after %ds — a client test is probably stuck')
                        :format(CLIENT_PHASE_MS // 1000),
                    duration = 0,
                    side     = 'client',
                    meta     = true,
                }
                SendReport(source)
            end)
        else
            SendReport(source)
        end
    end)
    return true
end

--- The /test menu: every section, how many server tests it holds, and how it did last time. The
--- client adds its own tests to each card's count, because only it knows what registered there.
---@param source number
local function OpenTestMenu(source)
    if running then
        chatMsg(source, '^3Tests are already running.')
        return
    end

    local counts = {}
    for _, mod in ipairs(TestModules) do
        local sid = TestSectionOf(mod.category)
        counts[sid] = (counts[sid] or 0) + #(mod.tests or {})
    end

    -- "ago" rather than a timestamp, so the page never has to agree with the server's clock.
    local now = os.time()
    local function card(section)
        local last = lastSectionResults[section.id]
        return {
            id     = section.id,
            label  = section.label,
            desc   = section.desc,
            icon   = section.icon,
            server = counts[section.id] or 0,
            last   = last and {
                passed  = last.passed,
                failed  = last.failed,
                skipped = last.skipped,
                partial = last.partial,
                ago     = now - last.at,
            } or nil,
        }
    end

    local cards = {}
    for _, section in ipairs(TestSections) do cards[#cards + 1] = card(section) end
    -- Always sent; the client leaves the card out when neither side has anything in it.
    cards[#cards + 1] = card(TEST_SECTION_OTHER)

    TriggerClientEvent('whip_test:openMenu', source, { sections = cards })
end

--- The same gate /test always had.
local function testerAllowed(source)
    if source == 0 then
        print('Use this in-game.')
        return false
    end
    if not devAllowed(source) then
        chatMsg(source, DEV_NEEDED)
        return false
    end
    return true
end

--- /test            opens the menu
--- /test all        runs the full suite straight away, as /test used to
--- /test vehicles   runs one section straight away (any id from shared/sections.lua)
RegisterCommand('test', function(source, args)
    if not testerAllowed(source) then return end

    local arg = args[1] and args[1]:lower() or nil
    if not arg then
        OpenTestMenu(source)
    elseif arg == 'all' then
        StartRun(source, nil)
    elseif TestSectionById(arg) then
        StartRun(source, arg)
    else
        local ids = {}
        for _, section in ipairs(TestSections) do ids[#ids + 1] = section.id end
        chatMsg(source, ('^3No section called "%s". Type /test for the menu, /test all for everything, '
            .. 'or /test with one of: %s'):format(arg, table.concat(ids, ', ')))
    end
end, false)

-- The menu's two buttons. Both are client requests, so both check the ace again rather than trusting
-- that the menu was only ever shown to someone allowed to see it.
RegisterNetEvent('whip_test:requestMenu', function()
    local src = source
    if not devAllowed(src) then return end
    OpenTestMenu(src)
end)

RegisterNetEvent('whip_test:runSection', function(sectionId)
    local src = source
    if not devAllowed(src) then return end

    if sectionId == 'all' then
        StartRun(src, nil)
    elseif type(sectionId) == 'string' and TestSectionById(sectionId) then
        StartRun(src, sectionId)
    end
end)

RegisterCommand('teststop', function(source)
    if not demoAllowed(source) then return end
    if not running and not enduranceRunning then
        chatMsg(source, '^3No tests running.')
        return
    end

    -- STOPPING IS A REQUEST, NOT A CLEANUP. This used to restore the inventory right here, while
    -- the runner thread was still inside a test — which then carried on against an inventory that
    -- had just been put back, and whose own teardown ran afterwards. Each loop ends at its next
    -- check of the flag and cleans up from there, after the test in progress has finished.
    if running then
        chatMsg(source, '^3Stopping tests — the test in progress finishes first...')
        running = false
        -- The client half has no loop of ours to notice the flag; close it from here.
        if phase == 'client' then SendReport(testSource or source) end
    end
    if enduranceRunning then
        chatMsg(source, '^3Stopping endurance test...')
        enduranceRunning = false
    end
end, false)

-- ============================================
-- Endurance Test — runs cycles until /teststop
-- ============================================

local _enduranceBankAccountId = nil

local enduranceSystems = {
    {
        name = 'Inventory',
        interval = 3,  -- run every N ticks
        fn = function(source)
            -- noDrop: full pockets refuse rather than drop the food at the tester's feet, where the
            -- RemoveItem below cannot reach it (it used to leave three on the ground every cycle,
            -- and report the REMOVE as the failure). Both carry a reason for the activity log.
            local where, addErr = exports.whip_core:AddItem(source, 'food', 3, nil,
                { reason = '_endurance', noDrop = true })
            if not where then return false, 'AddItem failed: ' .. tostring(addErr) end
            local ok2, remErr = exports.whip_core:RemoveItem(source, 'food', 3, nil, { reason = '_endurance' })
            if not ok2 then return false, 'RemoveItem failed: ' .. tostring(remErr) end
            return true
        end,
    },
    {
        name = 'Ground',
        interval = 5,
        fn = function(source)
            local ped = GetPlayerPed(source)
            local pos = GetEntityCoords(ped)
            local gItem = exports.whip_core:CreateGroundItem('food', 1, nil, pos.x, pos.y, pos.z + 1, 0, nil)
            if not gItem then return false, 'CreateGroundItem failed' end
            local nearby = exports.whip_core:GetGroundItemsNearby(pos.x, pos.y, pos.z, 50)
            if not nearby then return false, 'GetNearby failed' end
            exports.whip_core:DeleteGroundItem(gItem.id)
            return true
        end,
    },
    {
        name = 'Bank',
        interval = 5,
        fn = function(source)
            local player = exports.whip_core:GetPlayer(source)
            if not player then return false, 'GetPlayer nil' end
            if not _enduranceBankAccountId then
                local acc = exports.whip_core:CreateBankAccount(source, '_endurance_account', { type = 'personal' })
                if not acc then return false, 'CreateBankAccount failed' end
                _enduranceBankAccountId = acc.accountId
            end
            -- The actor is a person: `source` (whip's person rule, audit 3 DX-17).
            local ok1 = exports.whip_core:BankDeposit(_enduranceBankAccountId, 100, source, { reason = '_endurance' })
            if not ok1 then return false, 'BankDeposit failed' end
            local ok2 = exports.whip_core:BankWithdraw(_enduranceBankAccountId, 100, source, { reason = '_endurance' })
            if not ok2 then return false, 'BankWithdraw failed' end
            return true
        end,
    },
    {
        name = 'Callback',
        interval = 2,
        fn = function(source)
            -- Just verify callback registration is stable (actual round-trip is client-side)
            local player = exports.whip_core:GetPlayer(source)
            if not player then return false, 'GetPlayer nil' end
            local count = exports.whip_core:GetItemCount(source, 'food')
            if type(count) ~= 'number' then return false, 'GetItemCount bad type' end
            return true
        end,
    },
    {
        name = 'Container',
        interval = 8,
        fn = function(source)
            local ped = GetPlayerPed(source)
            local pos = GetEntityCoords(ped)
            local c = exports.whip_core:CreateContainer({
                name = '_endurance_ctr', slots = 5, maxWeight = 20.0,
                x = pos.x + 1, y = pos.y, z = pos.z,
            })
            if not c then return false, 'CreateContainer failed' end
            local def = exports.whip_core:GetContainer(c.containerId)
            if not def then
                exports.whip_core:DeleteContainer(c.containerId)
                return false, 'GetContainer nil'
            end
            exports.whip_core:DeleteContainer(c.containerId)
            return true
        end,
    },
    {
        name = 'Vehicle',
        interval = 10,
        fn = function(source)
            local player = exports.whip_core:GetPlayer(source)
            if not player then return false, 'GetPlayer nil' end
            local owned = exports.whip_core:GetVehiclesOf(source)
            if type(owned) ~= 'table' then return false, 'GetVehiclesOf bad type' end
            -- Cycle the lock on the first owned vehicle, if any — and put it back as it was, and READ
            -- the answers (`true | false, reason`): this ignored both, always passed, and left the
            -- player's car unlocked.
            if #owned > 0 then
                local vId = owned[1].vehicleId
                local wasLocked = owned[1].locked and true or false
                local ok1, err1 = exports.whip_core:SetVehicleLocked(vId, not wasLocked)
                local ok2, err2 = exports.whip_core:SetVehicleLocked(vId, wasLocked)
                if not ok1 then return false, 'SetVehicleLocked: ' .. tostring(err1) end
                if not ok2 then return false, 'SetVehicleLocked (restore): ' .. tostring(err2) end
            end
            return true
        end,
    },
}

RegisterCommand('testlong', function(source)
    if source == 0 then print('Use this in-game.') return end
    if not devAllowed(source) then
        chatMsg(source, DEV_NEEDED)
        return
    end
    if running or enduranceRunning then
        chatMsg(source, '^3A test is already running.')
        return
    end

    -- Same protection as /test: the endurance loop adds and removes items on the invoking
    -- character every few ticks, and the cleanup at the end used to be the blind nuke.
    if not BeginInventoryProtection(source) then
        chatMsg(source, '^1Could not read your inventory — aborting so nothing gets lost.')
        return
    end

    enduranceRunning = true
    enduranceSource  = source

    -- Reset endurance state
    _enduranceBankAccountId = nil

    chatMsg(source, '^7Starting endurance test... use /teststop to stop')
    chatMsg(source, '^7Inventory snapshotted — it will be restored when the run finishes.')

    -- Tell client to show HUD
    TriggerClientEvent('whip_test:enduranceStart', source)

    CreateThread(function()
        local tick         = 0
        local totalCycles  = 0
        local totalErrors  = 0
        local sysStats     = {}
        local lastReport   = GetGameTimer()
        local startRam     = collectgarbage('count')

        for _, sys in ipairs(enduranceSystems) do
            sysStats[sys.name] = { cycles = 0, errors = 0, totalMs = 0, lastErr = nil }
        end

        while enduranceRunning do
            tick = tick + 1

            for _, sys in ipairs(enduranceSystems) do
                if not enduranceRunning then break end
                if tick % sys.interval == 0 then
                    local start = GetGameTimer()
                    local ok, ret1, ret2 = pcall(sys.fn, source)
                    local duration = GetGameTimer() - start

                    local stat = sysStats[sys.name]
                    stat.cycles = stat.cycles + 1
                    stat.totalMs = stat.totalMs + duration
                    totalCycles = totalCycles + 1

                    if not ok then
                        -- pcall error (exception)
                        stat.errors = stat.errors + 1
                        stat.lastErr = tostring(ret1)
                        totalErrors = totalErrors + 1
                    elseif ret1 == false then
                        -- fn returned false, errMsg
                        stat.errors = stat.errors + 1
                        stat.lastErr = tostring(ret2 or 'unknown')
                        totalErrors = totalErrors + 1
                    end
                end
            end

            -- Send HUD update every 5 seconds
            if GetGameTimer() - lastReport >= 5000 then
                lastReport = GetGameTimer()
                local elapsed = (GetGameTimer() - (startTime > 0 and startTime or GetGameTimer())) / 1000
                local ramNow = collectgarbage('count')
                local ramDelta = ramNow - startRam

                -- Build per-system stats
                local sysData = {}
                for _, sys in ipairs(enduranceSystems) do
                    local s = sysStats[sys.name]
                    sysData[#sysData + 1] = {
                        name   = sys.name,
                        cycles = s.cycles,
                        errors = s.errors,
                        avgMs  = s.cycles > 0 and math.floor(s.totalMs / s.cycles) or 0,
                    }
                end

                TriggerClientEvent('whip_test:enduranceUpdate', source, {
                    elapsed     = math.floor((GetGameTimer() - startTime) / 1000),
                    totalCycles = totalCycles,
                    totalErrors = totalErrors,
                    ramMB       = math.floor(ramNow / 1024 * 10) / 10,
                    ramDeltaMB  = math.floor(ramDelta / 1024 * 10) / 10,
                    systems     = sysData,
                })
            end

            Wait(1000) -- 1 tick per second
        end

        -- Cleanup endurance-specific resources
        if _enduranceBankAccountId then
            -- The Bank system runs a deposit AND a withdraw every 5 seconds, so a 30-minute
            -- run alone writes ~720 transaction rows. Closing the account left every one of
            -- them on disk: 14,444 had accumulated here since March.
            DisposeTestAccount(_enduranceBankAccountId)
            _enduranceBankAccountId = nil
        end

        CleanupTestItems(source)
        TriggerClientEvent('whip_test:enduranceStop', source)

        -- Build endurance report card
        local totalTime = GetGameTimer() - startTime
        local ramNow = collectgarbage('count')
        local ramDelta = ramNow - startRam
        local endResults = {}

        for _, sys in ipairs(enduranceSystems) do
            local s = sysStats[sys.name]
            local avgMs = s.cycles > 0 and math.floor(s.totalMs / s.cycles) or 0
            -- Each system becomes a "test" in the report
            endResults[#endResults + 1] = {
                category = 'Endurance',
                name     = sys.name .. ' (' .. s.cycles .. ' cycles, avg ' .. avgMs .. 'ms)',
                passed   = s.errors == 0,
                error    = s.errors > 0 and (s.errors .. ' errors — last: ' .. (s.lastErr or 'unknown')) or nil,
                duration = avgMs,
                side     = 'server',
            }
        end

        -- Add RAM summary as a test result
        endResults[#endResults + 1] = {
            category = 'Endurance',
            name     = 'RAM stability (delta: ' .. (math.floor(ramDelta / 1024 * 10) / 10) .. ' MB)',
            passed   = ramDelta / 1024 < 50,
            error    = ramDelta / 1024 >= 50 and ('RAM grew by ' .. (math.floor(ramDelta / 1024 * 10) / 10) .. ' MB — possible leak') or nil,
            duration = 0,
            side     = 'server',
        }

        local passed = 0
        local failed = 0
        for _, r in ipairs(endResults) do
            if r.passed then passed = passed + 1 else failed = failed + 1 end
        end

        TriggerClientEvent('whip_test:showReport', source, {
            results   = endResults,
            passed    = passed,
            failed    = failed,
            skipped   = 0,
            totalTime = totalTime,
            partial   = false,
        })

        chatMsg(source, '^7Endurance test stopped. ' .. totalCycles .. ' cycles, ' .. totalErrors .. ' errors.')
        enduranceRunning = false
        enduranceSource  = nil
    end)

    startTime = GetGameTimer()
end, false)

-- ============================================
-- Quick Panel Test Command
-- ============================================

RegisterCommand('testpanel', function(source)
    if not demoAllowed(source) then return end

    exports.whip_core:OpenPanel(source, {
        id           = 'test_panel',
        label        = 'Test Panel',
        slots        = 6,
        items        = {
            [1] = { item = 'food', amount = 3 },
            [3] = { item = 'drink', amount = 2 },
        },
        maxWeight    = 10,
        allowedItems = { 'food', 'drink', 'bandage', 'cash' },
        readOnly     = false,

        -- When the last viewer leaves: ctx = { panel, source, items } (a copy of what is left).
        onClose = function(ctx)
            local count = 0
            for _ in pairs(ctx.items or {}) do count = count + 1 end
            print(('[whip_test] Panel closed — %d items remaining'):format(count))
        end,
    })
end, false)

RegisterCommand('testpanelro', function(source)
    if not demoAllowed(source) then return end

    exports.whip_core:OpenPanel(source, {
        id       = 'test_readonly',
        label    = 'Read-Only Panel',
        slots    = 4,
        items    = {
            [1] = { item = 'food', amount = 5 },
            [2] = { item = 'drink', amount = 10 },
        },
        readOnly = true,
    })
end, false)

-- A panel's hooks are part of its OpenPanel config (09-24): onValidate(ctx) before a move — return
-- false, 'why' to refuse — onChange(ctx) after it, onClose(ctx) when the last viewer leaves. They
-- belong to the panel, whoever is looking. (SetPanelOnMove / SetPanelOnClose, per viewer, are gone,
-- and TestPanelWatchMoves with them — nothing called it. /testpanel's close print moved into its
-- onClose above; the per-panel whip_core:panelClose:<id> event it listened to is gone.)

-- ============================================
-- Panel Framework Examples (10 demos)
-- ============================================

-- 1. /dumpster — Search a dumpster, random junk inside
RegisterCommand('dumpster', function(source)
    if not demoAllowed(source) then return end
    local junk = { 'food', 'drink', 'cash', 'bandage' }
    local items = {}
    for i = 1, math.random(2, 5) do
        items[i] = { item = junk[math.random(#junk)], amount = math.random(1, 3) }
    end
    exports.whip_core:OpenPanel(source, {
        id = 'dumpster_' .. GetGameTimer(), label = 'Dumpster', slots = 6, items = items,
    })
end, false)

-- 2. /lootcrate — Open a heavy loot crate with weight limit
RegisterCommand('lootcrate', function(source)
    if not demoAllowed(source) then return end
    exports.whip_core:OpenPanel(source, {
        id = 'lootcrate_' .. source, label = 'Supply Crate', slots = 8,
        maxWeight = 15,
        items = {
            [1] = { item = 'bandage', amount = 10 },
            [3] = { item = 'food', amount = 5 },
            [5] = { item = 'drink', amount = 5 },
            [7] = { item = 'jerry_can', amount = 1 },
        },
    })
end, false)

-- 3. /medkit — Medical kit, only medical items allowed
RegisterCommand('medkit', function(source)
    if not demoAllowed(source) then return end
    exports.whip_core:OpenPanel(source, {
        id = 'medkit_' .. source, label = 'Medical Kit', slots = 4,
        maxWeight = 5,
        allowedItems = { 'bandage', 'damage_reducer' },
        items = {
            [1] = { item = 'bandage', amount = 5 },
            [2] = { item = 'damage_reducer', amount = 1 },
        },
    })
end, false)

-- 4. /evidence — Evidence locker, view-only (detective reviewing)
RegisterCommand('evidence', function(source)
    if not demoAllowed(source) then return end
    exports.whip_core:OpenPanel(source, {
        id = 'evidence_locker', label = 'Evidence Locker #7', slots = 10,
        readOnly = true,
        items = {
            [1] = { item = 'lockpick', amount = 1 },
            [3] = { item = 'cash', amount = 500 },
            [5] = { item = 'id_card', amount = 1, metadata = { name = 'John Doe' } },
            [8] = { item = 'hacked_vehicle_key', amount = 1 },
        },
    })
end, false)

-- 5. /vendingmachine — Vending machine, take drinks, no putting stuff back
RegisterCommand('vendingmachine', function(source)
    if not demoAllowed(source) then return end
    local vendId = 'vending_' .. GetGameTimer()
    exports.whip_core:OpenPanel(source, {
        id = vendId, label = 'Vending Machine', slots = 6,
        items = {
            [1] = { item = 'drink', amount = 10 },
            [2] = { item = 'drink', amount = 10 },
            [3] = { item = 'drink', amount = 10 },
            [4] = { item = 'food', amount = 5 },
            [5] = { item = 'food', amount = 5 },
            [6] = { item = 'food', amount = 5 },
        },
        -- Take only. The reason is shown to the player. (The SetPanelOnMove this replaced returned
        -- nothing, so it ALLOWED putting items back despite what it said.)
        onValidate = function(ctx)
            if ctx.direction == 'in' then return false, 'You can\'t put items in a vending machine' end
        end,
    })
end, false)

-- 6. /toolbox — Mechanic toolbox, only tools allowed
RegisterCommand('toolbox', function(source)
    if not demoAllowed(source) then return end
    exports.whip_core:OpenPanel(source, {
        id = 'toolbox_' .. source, label = 'Toolbox', slots = 6,
        maxWeight = 25,
        allowedItems = { 'jerry_can', 'lockpick' },
        items = {
            [1] = { item = 'jerry_can', amount = 1 },
            [3] = { item = 'lockpick', amount = 3 },
        },
    })
end, false)

-- 7. /dropoff — Drop-off point, put items in and they disappear (rewarded with cash)
RegisterCommand('dropoff', function(source)
    if not demoAllowed(source) then return end
    local dropId = 'dropoff_' .. GetGameTimer()
    exports.whip_core:OpenPanel(source, {
        id = dropId, label = 'Drop-Off Point', slots = 4,
        items = {},
        -- AFTER the item landed, so nobody is paid for a drop that was then refused. (This was
        -- SetPanelOnMove, which paid before the move had happened.)
        onChange = function(ctx)
            if ctx.direction == 'in' then
                local reward = math.random(10, 50)
                -- The answer is read: a refused payment leaves the item in the panel, so they can take
                -- it back. Full pockets are not a refusal: PayPlayer puts the notes that do not fit at
                -- their feet (AddPlayerCash, until 14 Nov 2026, refused them).
                local paid, why = exports.whip_core:PayPlayer(ctx.source, reward, { method = 'cash', reason = 'drop-off reward' })
                if paid then
                    local where = paid.placement == 'ground' and ' (at your feet: your pockets are full)' or ''
                    exports.whip_core:NotifyPlayer(ctx.source,
                        'Dropped off ' .. (ctx.item or '?') .. ' — earned $' .. reward .. where, 'success')
                else
                    exports.whip_core:NotifyPlayer(ctx.source,
                        'Not paid: ' .. tostring(why) .. ' — take it back out', 'error')
                end
            end
        end,
        -- Items left in the panel are gone when it closes — the default — so they are logged as
        -- leaving the game. LogActivity takes the item as a copy here: it is no longer in any
        -- slot to give the address of, and its uid (when it has one) keeps its timeline joined up.
        -- (An AddEventHandler used to sit here and leaked: a permanent handler for a
        -- GetGameTimer()-suffixed event name that could never fire again, once per /dropoff.)
        onClose = function(ctx)
            for _, data in pairs(ctx.items or {}) do
                exports.whip_core:LogActivity(ctx.source, 'destroyed', { detail = 'left at a drop-off point', slotData = data })
            end
        end,
    })
end, false)

-- 8. /safebox — Personal safe with heavy weight limit
RegisterCommand('safebox', function(source)
    if not demoAllowed(source) then return end
    exports.whip_core:OpenPanel(source, {
        id = 'safe_' .. source, label = 'Personal Safe', slots = 12,
        maxWeight = 50,
        items = {},
        -- The panel's own onClose, not AddEventHandler: it goes with the panel. The event handler it
        -- replaced was added again on every /safebox and all N copies fired on each close.
        onClose = function(ctx)
            local count = 0
            for _ in pairs(ctx.items) do count = count + 1 end
            exports.whip_core:NotifyPlayer(ctx.source,
                'Safe locked — ' .. count .. ' item(s) secured', 'success')
        end,
    })
end, false)

-- 9. /trashcan — Destroy items by putting them in (confirmation via close callback)
RegisterCommand('trashcan', function(source)
    if not demoAllowed(source) then return end
    local trashId = 'trash_' .. GetGameTimer()
    exports.whip_core:OpenPanel(source, {
        id = trashId, label = 'Trash Can', slots = 4,
        items = {},
        -- onClose for the same reason as /safebox: the old per-invocation AddEventHandler leaked one
        -- permanent handler per /trashcan, each bound to an id that never recurs.
        onClose = function(ctx)
            local destroyed = 0
            for _, data in pairs(ctx.items) do
                destroyed = destroyed + (data.amount or 1)
                -- Gone from the game, so logged as such (a copy: see /dropoff).
                exports.whip_core:LogActivity(ctx.source, 'destroyed', { detail = 'thrown in a trash can', slotData = data })
            end
            if destroyed > 0 then
                exports.whip_core:NotifyPlayer(ctx.source,
                    'Destroyed ' .. destroyed .. ' item(s)', 'success')
            end
            -- Items left in the panel are simply gone — not returned
        end,
    })
end, false)

-- 10. /showcase — Display case, shows valuable items but can't be touched
RegisterCommand('showcase', function(source)
    if not demoAllowed(source) then return end
    exports.whip_core:OpenPanel(source, {
        id = 'showcase_' .. source, label = 'Display Case', slots = 8,
        readOnly = true,
        items = {
            [1] = { item = 'vehicle_key', amount = 1, metadata = { plate = 'GOLD1', model = 'adder' } },
            [3] = { item = 'jerry_can', amount = 1, metadata = { fuel = 100 } },
            [4] = { item = 'wallet', amount = 1 },
            [6] = { item = 'lockpick', amount = 1 },
            [8] = { item = 'bandage', amount = 3 },
        },
    })
end, false)

-- Export running state so client can check
exports('IsRunning', function() return running or enduranceRunning end)

--- Start a run from code, as `/test <section>` does for this player: the same dev gate and checks.
--- The report comes as the server event `whip_test:runFinished` (source, report) when it is done.
---@param source number  the tester, a player in game
---@param sectionId string|nil  'all' or nil for the full suite, else a shared/sections.lua id
---@return boolean started, string|nil why
exports('StartTestRun', function(source, sectionId)
    source = tonumber(source)
    if not source or source <= 0 or not GetPlayerName(source) then return false, 'No such player.' end
    if not devAllowed(source) then return false, 'The tester needs whip.devtools with developer mode on (/w).' end
    if sectionId == 'all' then sectionId = nil end
    if sectionId ~= nil and not (type(sectionId) == 'string' and TestSectionById(sectionId)) then
        return false, ('No section called "%s".'):format(tostring(sectionId))
    end
    return StartRun(source, sectionId)
end)

--- The sections a run can name, for a caller that builds a menu or checks a name.
---@return { id: string, label: string }[]
exports('GetTestSections', function()
    local out = {}
    for _, section in ipairs(TestSections) do out[#out + 1] = { id = section.id, label = section.label } end
    return out
end)
