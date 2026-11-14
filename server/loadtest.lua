-- ============================================
-- whip_test — LOAD TEST
-- ============================================
--
-- Answers "what does whip cost at two hundred players?" without two hundred players.
--
-- WHY THIS IS NOT ONE TEST BUT FOUR. The things that break at scale break for different reasons and
-- would hide each other if measured together, so each pressure runs on its own dial:
--
--   phantoms   fake entries in Players, so every per-player loop does 200x the work
--   db         a burst of real queries, because the periodic save fires ALL players on one tick
--   vehicles   server-spawned cars, the one cost that scales with the world instead of the roster
--   events     real events through the real SecureEvent path, rate limiter and all
--
-- WHAT IT CANNOT MEASURE, stated up front so nobody reads more into a green run than is there:
-- OneSync entity synchronisation, bandwidth, and client frame time with 200 real players streamed
-- in. Those need real bodies in real positions. Sync in particular is the engine's cost and no
-- amount of Lua tuning moves it, so it is the least useful thing to be missing.
--
-- SAFETY, because this deliberately hurts the server:
--   * Phantoms are skipped by SafeSavePlayer, so they can never reach a character row.
--   * The database burst writes to its own table, created and dropped by the run.
--   * Vehicles spawn FAR from the operator so the client never has to stream them.
--   * The run aborts itself if the server starts falling behind (see DRIFT_ABORT_MS).
--   * /testloadstop works from the SERVER CONSOLE, so a crashed client cannot strand a run.

local load = {
    running    = false,
    source     = nil,
    startedAt  = 0,
    cfg        = nil,
    stats      = nil,
    abortReason = nil,

    -- Everything this run created, so teardown can be exact rather than a sweep. A load test that
    -- cleans up by deleting "test-looking" rows is one bad pattern away from deleting real ones.
    vehicles   = {},
    items      = {},
    doors      = {},
    containers = {},
    statNames  = {},
}

--- The dials, their defaults and their ceilings, in one table.
---
--- ONE TABLE RATHER THAN EIGHT POSITIONAL ARGUMENTS. `/testload 200 50 20 200 500 8 20 30` is
--- unreadable and unmemorable, and the eighth number is the one you get wrong. Named arguments mean
--- you can set the one dial you care about and leave the rest alone.
---
--- `max` is not advice. Each one is the point past which the dial stops measuring whip and starts
--- measuring the damage the test is doing, and the parser clamps rather than warns.
local DIALS = {
    announce   = { default = 0,   max = 1,
                   help = '1: each phantom fires whip_core:player:loaded (phantom = true), so satellites do their per-player work too' },
    players    = { default = 200, max = 512,
                   help = 'phantom players in Players + Stats._cache — loads every per-player loop' },
    vehicles   = { default = 50,  max = 300,
                   help = 'server-spawned cars 1.2km away — the cost that scales with the world' },
    items      = { default = 300, max = 2000,
                   help = 'ground items — spatial grid + per-player proximity sync' },
    stats      = { default = 6,   max = 40,
                   help = 'extra decaying stats — MULTIPLIES the per-player tick by this many' },
    doors      = { default = 20,  max = 200,
                   help = 'doors, toggled during the run — state writes + cell-scoped announces' },
    containers = { default = 20,  max = 200,
                   help = 'stocked containers — loads the write-behind flush loop' },
    events     = { default = 20,  max = 100,
                   help = 'events/sec from your client — CAN GET YOU KICKED, see the note below' },
    dbrows     = { default = 200, max = 512,
                   help = 'rows per database burst, fired on the same cycle as player saves' },
    dbevery    = { default = 60,  max = 600,
                   help = 'seconds between database bursts — 60 matches Config.SaveInterval' },
    churn      = { default = 20,  max = 200,
                   help = 'objects recycled per second — standing state is not what a real server does' },
}

-- ---- Fixed limits, and why each one is where it is --------------------------------------------
--
-- The per-dial ceilings live in DIALS above. These are the ones that are not dials.

--- How far from the operator things are spawned. THIS IS THE CLIENT CRASH GUARD: an entity the
--- client never streams is one that cannot exhaust its entity pool or its memory. 1200m is
--- comfortably past any streaming range, and the server still pays full price for it, which is the
--- half being measured. Doors and containers sit closer in (400m and 600m) but still far outside
--- streaming; ground items are the deliberate exception, because their whole cost is the proximity
--- sync and moving them away would test nothing.
local VEHICLE_SPAWN_OFFSET = 1200.0

--- Vehicles per row when laying out the grid, and the gap between them. Spread out so they cannot
--- interpenetrate and start a physics fight with each other.
local GRID_STRIDE = 8.0
local GRID_WIDTH  = 20

--- The load thread asks for a 100ms sleep. If it gets back more than this, the server is not
--- keeping up and the run has stopped being a measurement — it is now the problem. Abort.
---
--- This is the safety net that matters most: a load test that keeps pushing while the server is
--- already drowning can take the whole thing down, and the operator may not be able to type.
local DRIFT_ABORT_MS = 2500

--- Renew the rate-limit bypass this often. Its TTL in whip_core is 10s, so a stalled or crashed
--- run restores normal rate limiting within seconds without anyone doing anything.
local BYPASS_RENEW_MS = 3000

local LOADTEST_TABLE = 'whip_loadtest_rows'

--- Is a load test running? For the /test runner, which refuses to start on top of one: phantoms in
--- Players and rate limiting switched off make every result meaningless.
---@return boolean
function LoadTestRunning()
    return load.running == true
end

-- ---- Small helpers ----------------------------------------------------------------------------

local function tell(msg)
    print('[whip_test:load] ' .. msg)
    if load.source and load.source > 0 then
        TriggerClientEvent('chat:addMessage', load.source, { args = { '^5[load]^0 ' .. msg } })
    end
end

--- Percentile from an unsorted array of numbers. Averages hide the exact thing a load test is
--- looking for: the run where one query in fifty took a second while the mean stayed flat.
local function percentile(list, p)
    if #list == 0 then return 0 end
    local copy = {}
    for i = 1, #list do copy[i] = list[i] end
    table.sort(copy)
    local idx = math.max(1, math.min(#copy, math.ceil(#copy * p)))
    return copy[idx]
end

--- Parse `key=value` pairs into clamped dial values, filling in defaults for anything absent.
---
--- Unknown keys are reported rather than ignored: a silent typo means you think you set a dial and
--- the run measures something else entirely, which is the worst possible failure for a measurement
--- tool. Zero is honoured (Lua's `or` treats 0 as truthy, unlike JavaScript's `||`), so `items=0`
--- really does switch that dial off.
local function parseDials(args)
    local cfg, unknown = {}, {}

    for name, spec in pairs(DIALS) do cfg[name] = spec.default end

    for _, raw in ipairs(args or {}) do
        local key, value = raw:match('^([%a_]+)=(-?%d+)$')
        if key then
            key = key:lower()
            local spec = DIALS[key]
            if spec then
                cfg[key] = math.max(0, math.min(tonumber(value), spec.max))
            else
                unknown[#unknown + 1] = key
            end
        elseif raw ~= '' then
            unknown[#unknown + 1] = raw
        end
    end

    return cfg, unknown
end

local function freshStats()
    return {
        phantoms      = 0,
        vehicles      = 0,
        items         = 0,
        doors         = 0,
        containers    = 0,
        extraStats    = 0,
        doorToggles   = 0,
        churned       = 0,
        dbPeakInFlight = 0,
        baselineMs    = 0,
        dbSent        = 0,
        dbDone        = 0,
        dbFailed      = 0,
        dbInFlight    = 0,
        dbLatencies   = {},     -- rolling window, ms
        eventsSent    = 0,
        eventsRejected = 0,
        bursts        = 0,
        worstDriftMs  = 0,
        lastDriftMs   = 0,
    }
end

-- ---- Database burst ---------------------------------------------------------------------------

--- Create the table this test writes to.
---
--- ITS OWN TABLE, DELIBERATELY. Driving the real player-save path would mean writing two hundred
--- character rows that do not exist, and pointing it at real characters would mean a load test
--- that can corrupt live data. A dedicated table measures the thing that actually matters — can
--- the pool and the database absorb a burst of N writes — with nothing at stake if it goes wrong.
local function ensureTable()
    local ok, err = pcall(MySQL.query.await, ([[
        CREATE TABLE IF NOT EXISTS `%s` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `slot` INT NOT NULL,
            `payload` JSON NULL,
            `updatedAt` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            UNIQUE KEY `slot` (`slot`)
        ) ENGINE=InnoDB
    ]]):format(LOADTEST_TABLE), {})

    if not ok then
        tell('^1could not create ' .. LOADTEST_TABLE .. ': ' .. tostring(err))
        return false
    end
    return true
end

local function dropTable()
    pcall(MySQL.query.await, ('DROP TABLE IF EXISTS `%s`'):format(LOADTEST_TABLE), {})
end

--- One burst: `n` writes fired all at once, no stagger.
---
--- THIS IS A CONTROL NOW, NOT A MODEL OF WHIP. It reproduces the shape whip's periodic save USED to
--- have — `for _, player in pairs(Players) do SafeSavePlayer(player) end` on a 60 second timer with
--- no spacing, which at one player is one invisible query and at two hundred is a two hundred query
--- burst against a connection pool about ten wide.
---
--- whip does not write that way any more: player rows and inventories are both batched into a
--- single transaction on FlushInterval. The burst is kept deliberately — it is the measurement that
--- shows what the old shape cost, and it remains an honest pool-saturation test regardless of
--- whether the framework still does this to itself.
local function dbBurst(n)
    local s = load.stats
    s.bursts = s.bursts + 1

    local payload = json.encode({ note = 'whip load test', at = GetGameTimer() })

    for i = 1, n do
        if not load.running then return end
        s.dbSent = s.dbSent + 1
        s.dbInFlight = s.dbInFlight + 1
        -- PEAK, not just the instant value. Bursts fire once a minute and drain in well under the
        -- 500ms reporting interval, so the live figure reads 0 almost always and the saturation you
        -- actually care about is never on screen. The peak is reset each report.
        if s.dbInFlight > s.dbPeakInFlight then s.dbPeakInFlight = s.dbInFlight end

        local slot = i
        local sentAt = GetGameTimer()

        -- Fire and forget, on purpose: the point is concurrency. Awaiting each one in turn would
        -- measure a queue of length one and tell us nothing about pool saturation.
        MySQL.query(('INSERT INTO `%s` (`slot`, `payload`) VALUES (?, ?) '
            .. 'ON DUPLICATE KEY UPDATE `payload` = VALUES(`payload`)'):format(LOADTEST_TABLE),
            { slot, payload },
            function(result)
                s.dbInFlight = math.max(0, s.dbInFlight - 1)
                if result == nil then
                    s.dbFailed = s.dbFailed + 1
                else
                    s.dbDone = s.dbDone + 1
                end

                local ms = GetGameTimer() - sentAt
                s.dbLatencies[#s.dbLatencies + 1] = ms
                -- Bounded window: a long run must not grow a list forever.
                if #s.dbLatencies > 2000 then table.remove(s.dbLatencies, 1) end
            end)
    end
end

-- ---- Vehicles ---------------------------------------------------------------------------------

--- Spawn `n` vehicles in a grid a long way from the operator.
---
--- Uses the public SpawnVehicle export rather than reaching into whip's internals, so this
--- exercises the same path a garage does — including the vehicle stat tick and the storage flush,
--- which are the two whip costs that scale with vehicles rather than with players.
--- Create and spawn ONE vehicle.
---
--- CreateOwnedVehicle(source, data) needs a real loaded player to own the row, which is why this
--- dial requires the operator to be in-game. It returns a bare vehicleId — the only one of whip's
--- create exports that does not hand back a table.
local function createOneVehicle(i, ox, oy, oz)
    local row = math.floor((i - 1) / GRID_WIDTH) % GRID_WIDTH
    local col = (i - 1) % GRID_WIDTH
    local x = ox + VEHICLE_SPAWN_OFFSET + (col * GRID_STRIDE)
    local y = oy + VEHICLE_SPAWN_OFFSET + (row * GRID_STRIDE)

    local ok, vehicleId = pcall(function()
        -- Made garaged; SpawnVehicle below takes it out. (`state = 'out'` without spawnAt is
        -- refused since audit 6, VEH-4.)
        return exports.whip_core:CreateOwnedVehicle(load.source, { model = 'blista' })
    end)

    if ok and type(vehicleId) == 'number' then
        -- THE MARKER /testloadclean FINDS IT BY. A run that crashes before its stop leaves these
        -- rows in the operator's garage, and a plain blista is indistinguishable from a real one.
        pcall(function() exports.whip_core:SetVehicleData(vehicleId, '_loadtest', true) end)
        pcall(function() exports.whip_core:SpawnVehicle(vehicleId, vector4(x, y, oz, 0.0)) end)
        -- Returned whether or not the SPAWN landed: the database row exists either way, and an
        -- unrecorded row is one the cleanup will not delete.
        return vehicleId
    end
    return nil
end

--- Entity and row, the way the stop removes them.
local function killVehicle(vehicleId)
    pcall(function() exports.whip_core:DespawnVehicle(vehicleId) end)
    local ok, gone = pcall(function() return exports.whip_core:__TestDeleteVehicle(vehicleId) end)
    return ok and gone
end

--- EVERY CREATE YIELDS (each is a database insert), and /testloadstop can land during one. By then
--- the stop has already emptied the lists, so the new object would be appended to a list nobody
--- will clean again — a row left behind per stop, and a throw on `load.stats`, which the stop has
--- set to nil. The spawn loops and the churn call this straight after every create.
---@param id any       what the create returned
---@param kill function
---@return boolean stopped  true when the run has stopped; the object has then been deleted
local function discardIfStopped(id, kill)
    if load.running then return false end
    if id then kill(id) end
    return true
end

local function spawnVehicles(n, originX, originY, originZ)
    for i = 1, n do
        if not load.running then return end

        local vehicleId = createOneVehicle(i, originX, originY, originZ)
        if discardIfStopped(vehicleId, killVehicle) then return end
        if vehicleId then
            load.vehicles[#load.vehicles + 1] = vehicleId
            load.stats.vehicles = #load.vehicles
        end

        -- Breathe every few spawns. Creating three hundred networked entities in one unbroken
        -- loop is itself a hitch, and a hitch during setup would poison the measurement that
        -- follows it.
        if i % 10 == 0 then Wait(0) end
    end
end

--- Remove every vehicle this run created — entity AND database row.
---
--- The row matters as much as the entity. CreateOwnedVehicle writes a real row in `vehicles`, so a
--- run that only despawned would leave three hundred cars in the operator's garage, every time.
--- __TestDeleteVehicle routes through Vehicles.delete so the cache and write-behind queue go with
--- it, rather than leaving whip believing in vehicles that are no longer in the database.
local function despawnVehicles()
    local removed = 0
    for _, vehicleId in ipairs(load.vehicles) do
        if killVehicle(vehicleId) then removed = removed + 1 end
    end

    if #load.vehicles > 0 and removed < #load.vehicles then
        tell(('^3%d of %d test vehicles could not be deleted — check the vehicles table')
            :format(#load.vehicles - removed, #load.vehicles))
    end

    load.vehicles = {}
    if load.stats then load.stats.vehicles = 0 end
end

-- ---- Ground items -----------------------------------------------------------------------------

--- Scatter `n` ground items around the operator.
---
--- WHAT THIS ACTUALLY LOADS, and it is the reason ground items earn a dial of their own: whip keeps
--- them in a spatial grid and runs a proximity sync every second for every player, diffing which
--- cells each one can see (server/events_inventory.lua). That is the only per-player loop in whip
--- whose cost also scales with how much is in the WORLD — players times items — and nothing else
--- in this test reaches it.
---
--- Scattered across roughly 300m so they land in many different grid cells. All in one cell would
--- load one bucket and leave the grid itself untested, which is the opposite of the point.
--- Create ONE ground item. The bulk spawn and the churn engine both go through here, so there is a
--- single place that knows the argument order and the return shape — the two things that were wrong
--- the first time and cost a live server 1212 orphaned rows.
---
--- THE THIRD ARGUMENT IS METADATA, NOT X. GroundItems.create takes
--- (item, amount, metadata, x, y, z, heading, createdBy) positionally, and passing coordinates from
--- the third slot shifts everything down: the x coordinate is stored AS the metadata and the item
--- lands somewhere else. It does not error — it writes a number where a table belongs, which then
--- breaks whip_core's loader on the next restart.
---
--- The marker in the metadata is how leftovers from a crashed run get found again. See
--- /testloadclean.
local function createOneGroundItem(i, ox, oy, oz)
    -- Deterministic spread, not random: a run you cannot reproduce is a run you cannot compare
    -- against the last one. Golden angle so the points do not form visible bands in one cell.
    local angle  = i * 2.39996
    local radius = 20.0 + (i % 280)
    local x = ox + math.cos(angle) * radius
    local y = oy + math.sin(angle) * radius

    local ok, data = pcall(function()
        return exports.whip_core:CreateGroundItem({ item = 'bread', amount = 1, metadata = { _loadtest = true },
            coords = vector3(x, y, oz), heading = 0.0 })
    end)

    -- Returns the item's DATA TABLE, not its id.
    if ok and type(data) == 'table' and data.id then return data.id end
    return nil
end

local function killGroundItem(id)
    pcall(function() exports.whip_core:DeleteGroundItem(id) end)
end

local function spawnGroundItems(n, ox, oy, oz)
    for i = 1, n do
        if not load.running then return end

        local id = createOneGroundItem(i, ox, oy, oz)
        if discardIfStopped(id, killGroundItem) then return end
        if id then
            load.items[#load.items + 1] = id
            load.stats.items = #load.items
        end

        if i % 25 == 0 then Wait(0) end          -- breathe: each one is a database insert
    end
end

local function removeGroundItems()
    for _, id in ipairs(load.items) do
        killGroundItem(id)
    end
    load.items = {}
    if load.stats then load.stats.items = 0 end
end

-- ---- Extra stats ------------------------------------------------------------------------------

--- Register `n` throwaway decaying stats.
---
--- THE BIGGEST MULTIPLIER IN THE WHOLE TEST. whip's stat tick walks every registered stat for every
--- cached player, twice — once for decay and once for thresholds (server/stats.lua). So its cost is
--- players x stats x 2, and this dial is the second term. Phantoms alone measure whip's current six
--- or so stats; this measures what happens when a server has thirty.
---
--- Short decay intervals on purpose, so the tick actually does work rather than skipping every pass.
local function registerExtraStats(n)
    for i = 1, n do
        local name = ('_loadtest_stat_%d'):format(i)
        -- RegisterStat's own answer, not pcall's: a refused registration used to be counted as a
        -- stat the tick was walking.
        local called, ok = pcall(function()
            return exports.whip_core:RegisterStat(name, {
                default = 100, min = 0, max = 100,
                persist = false,                  -- never written to a character row
                decay = -1, decayInterval = 1,
            })
        end)
        if called and ok then
            load.statNames[#load.statNames + 1] = name
            load.stats.extraStats = #load.statNames
        end
    end
end

local function unregisterExtraStats()
    for _, name in ipairs(load.statNames) do
        pcall(function() exports.whip_core:__TestUnregisterStat(name) end)
    end
    load.statNames = {}
    if load.stats then load.stats.extraStats = 0 end
end

-- ---- Doors ------------------------------------------------------------------------------------

--- Create `n` doors, spread out so whip's own duplicate check does not reject them.
---
--- Doors have no per-tick server cost — the load is in TOGGLING them, which writes state and
--- announces it to the players holding the door's cell (Doors.updateState via PlayersNearPoint;
--- the old broadcast-to-everyone is gone). Creation now ALSO broadcasts a projected doorCreated
--- to every client — so a run that creates its door pool exercises that fan-out too.
---
--- HONEST LIMIT: an announce is serialised per recipient, and there is only one real client
--- here — phantoms hold no cells and receive nothing. So this exercises the write and the index
--- lookup but UNDER-MEASURES the per-client send cost, which is the half that scales with a
--- crowd standing near the door.
--- Create ONE door.
---
--- `doors.model` is a BIGINT holding a model HASH, not the model name — passing the string makes
--- MySQL reject every insert with "Incorrect integer value", reported per row rather than once.
---
--- Returns the door TABLE, not an id, the same as CreateGroundItem and CreateContainer.
--- CreateOwnedVehicle is the odd one out and hands back a bare vehicleId.
local function createOneDoor(i, ox, oy, oz)
    -- 4m apart, well clear of the 0.5m duplicate rejection in Doors.create. The index keeps
    -- climbing across recycles so a replacement never lands on the corpse of the one it replaced.
    local x = ox + 400.0 + ((i % 20) * 4.0)
    local y = oy + 400.0 + (math.floor(i / 20) % 20) * 4.0

    local ok, door = pcall(function()
        return exports.whip_core:CreateDoor({
            label = ('_loadtest_door_%d'):format(i),
            model = GetHashKey('v_ilev_gc_door01'),
            x = x, y = y, z = oz, heading = 0.0, locked = true,
        })
    end)

    if ok and type(door) == 'table' and door.doorId then return door.doorId end
    return nil
end

local function killDoor(doorId)
    pcall(function() exports.whip_core:DeleteDoor(doorId) end)
end

local function spawnDoors(n, ox, oy, oz)
    for i = 1, n do
        if not load.running then return end

        local doorId = createOneDoor(i, ox, oy, oz)
        if discardIfStopped(doorId, killDoor) then return end
        if doorId then
            load.doors[#load.doors + 1] = doorId
            load.stats.doors = #load.doors
        end

        if i % 10 == 0 then Wait(0) end
    end
end

local function removeDoors()
    for _, doorId in ipairs(load.doors) do
        killDoor(doorId)
    end
    load.doors = {}
    if load.stats then load.stats.doors = 0 end
end

--- Toggle one door. Called on a rota so every door gets used rather than hammering one.
local function toggleNextDoor(index)
    if #load.doors == 0 then return end
    local doorId = load.doors[(index % #load.doors) + 1]
    pcall(function()
        exports.whip_core:SetDoorLocked(doorId, (index % 2) == 0)
    end)
    load.stats.doorToggles = load.stats.doorToggles + 1
end

-- ---- Containers -------------------------------------------------------------------------------

--- Create `n` containers.
---
--- These load the write-behind flush loop (server/stores.lua), which walks every dirty unit on a
--- one-second timer. Write-behind is the mechanism the whole persistence layer rests on, and until
--- now nothing measured what it costs with a realistic number of live units in it.
--- Create ONE container. Returns the def TABLE, not an id.
local function createOneContainer(i, ox, oy, oz)
    local ok, def = pcall(function()
        return exports.whip_core:CreateContainer({
            name = ('_loadtest_ctr_%d'):format(i),
            slots = 10, maxWeight = 50.0,
            x = ox + 600.0 + (i % 20) * 3.0,
            y = oy + 600.0 + (math.floor(i / 20) % 20) * 3.0,
            z = oz,
        })
    end)

    if ok and type(def) == 'table' and def.containerId then return def.containerId end
    return nil
end

local function killContainer(containerId)
    pcall(function() exports.whip_core:DeleteContainer(containerId) end)
end

local function spawnContainers(n, ox, oy, oz)
    for i = 1, n do
        if not load.running then return end

        local containerId = createOneContainer(i, ox, oy, oz)
        if discardIfStopped(containerId, killContainer) then return end
        if containerId then
            load.containers[#load.containers + 1] = containerId
            load.stats.containers = #load.containers
        end

        if i % 10 == 0 then Wait(0) end
    end
end

local function removeContainers()
    for _, containerId in ipairs(load.containers) do
        killContainer(containerId)
    end
    load.containers = {}
    if load.stats then load.stats.containers = 0 end
end

-- ---- Churn ------------------------------------------------------------------------------------

--- Recycle objects: delete the oldest, create a replacement, keeping the population steady.
---
--- WHY STANDING STATE IS NOT ENOUGH, and this is the difference between a load test and a
--- screenshot. Creating 300 ground items once and letting them sit measures the cost of HAVING
--- them. A real server never does that — items are dropped and picked up, containers open and
--- close, cars spawn and despawn, doors are used. All of that is create and delete traffic:
--- database writes, cache inserts and evictions, write-behind queue movement, broadcasts to
--- everyone in range. None of it happens when nothing changes.
---
--- Round-robin across the four pools rather than draining one, so no single subsystem sees an
--- artificial burst that a real server would never produce.
local RECYCLERS = {
    {
        name = 'items',
        pool = function() return load.items end,
        kill = killGroundItem,
        make = function(i, x, y, z) return createOneGroundItem(i, x, y, z) end,
    },
    {
        name = 'containers',
        pool = function() return load.containers end,
        kill = killContainer,
        make = function(i, x, y, z) return createOneContainer(i, x, y, z) end,
    },
    {
        name = 'doors',
        pool = function() return load.doors end,
        kill = killDoor,
        make = function(i, x, y, z) return createOneDoor(i, x, y, z) end,
    },
    {
        name = 'vehicles',
        pool = function() return load.vehicles end,
        kill = killVehicle,
        make = function(i, x, y, z) return createOneVehicle(i, x, y, z) end,
    },
}

--- A monotonically climbing index, so a replacement never reuses the position or the name of the
--- object it replaced. Doors in particular reject a second door within half a metre of the first.
local churnSeq = 0

local function recycleOne(slot, ox, oy, oz)
    local r = RECYCLERS[(slot % #RECYCLERS) + 1]
    local pool = r.pool()
    if #pool == 0 then return end

    -- Oldest first, so every object gets a turn rather than the same one cycling forever.
    local victim = table.remove(pool, 1)
    r.kill(victim)

    churnSeq = churnSeq + 1
    local made = r.make(1000 + churnSeq, ox, oy, oz)
    if discardIfStopped(made, r.kill) then return end
    if made then
        pool[#pool + 1] = made
    end

    load.stats.churned = load.stats.churned + 1
    load.stats.items      = #load.items
    load.stats.containers = #load.containers
    load.stats.doors      = #load.doors
    load.stats.vehicles   = #load.vehicles
end

-- ---- Synthetic events -------------------------------------------------------------------------

--- Events are fired BY THE CLIENT, not from here, and that is forced rather than chosen.
---
--- A SecureEvent reads `source` from the event context to find the player, rate-limit bucket and
--- ACE. Triggered server-side there is no source, so every one would be rejected as "no player
--- session" and the run would measure the rejection path instead of the work.
---
--- So the client fires them for real, over the network, exactly as a player's client does. Two
--- consequences worth knowing about:
---
---   * whip's own per-source rate limiter would reject nearly all of them, since one client is
---     standing in for two hundred. Hence the bypass seam, renewed while the run lives.
---   * FIVEM'S OWN net-event limiter is NOT bypassed and cannot be. Push a single client too hard
---     and the server kicks it for reliable-event overflow. That is why this dial defaults low and
---     is capped well below the others — it is the one that can end your session.
---
--- The client reports what it actually managed to send, so the panel shows the real rate rather
--- than the requested one.
RegisterNetEvent('whip_test:loadEventStat', function(sent)
    if not load.running or source ~= load.source then return end
    load.stats.eventsSent = tonumber(sent) or load.stats.eventsSent
end)

-- ---- Abort ------------------------------------------------------------------------------------

--- Put everything back. Safe to call twice, and called from every exit path including the drift
--- guard and playerDropped, because the one thing worse than a load test is a load test you
--- cannot stop.
function LoadTestStop(reason)
    if not load.running then return false end

    load.running = false
    load.abortReason = reason

    tell('stopping: ' .. tostring(reason))

    -- ORDER MATTERS ONLY IN ONE PLACE: the rate-limit bypass goes first, so that if anything below
    -- throws, the server is not left with rate limiting off. Everything else is independent.
    pcall(function() exports.whip_core:__TestRateLimitBypass(false) end)
    pcall(function() exports.whip_core:__TestPhantoms(0) end)

    unregisterExtraStats()
    despawnVehicles()
    removeGroundItems()
    removeDoors()
    removeContainers()
    dropTable()

    local leftover = 0
    pcall(function() leftover = exports.whip_core:__TestPhantomCount() end)
    tell(('cleaned up — phantoms %d, vehicles %d, items %d, doors %d, containers %d, stats %d')
        :format(leftover, #load.vehicles, #load.items, #load.doors, #load.containers, #load.statNames))

    if load.source and load.source > 0 then
        TriggerClientEvent('whip_test:loadStop', load.source)
    end

    load.source = nil
    load.stats = nil
    return true
end

--- Stop if the operator disconnects. Their client is where the panel lives, and a run nobody is
--- watching is a run nobody will stop.
AddEventHandler('playerDropped', function()
    if load.running and load.source == source then
        LoadTestStop('operator disconnected')
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and load.running then
        LoadTestStop('resource stopped')
    end
end)

-- ---- The run ----------------------------------------------------------------------------------

local function runLoad(origin)
    local s = load.stats
    local cfg = load.cfg
    local lastBypass = 0
    local lastBurst  = 0
    local lastReport = 0
    local doorTick   = 0
    local churnCarry = 0.0
    local churnSlot  = 0
    local lastTick   = GetGameTimer()

    -- CALIBRATE BEFORE MEASURING. A Wait(100) cannot return in 100ms: the server ticks on a fixed
    -- interval and the sleep resumes on the next boundary after the one you asked for. On a 20-tick
    -- server that is 150ms, so every drift reading carried a constant +50ms that looked like strain
    -- and was nothing but arithmetic.
    --
    -- Measured rather than assumed, because the tick rate is a server setting and hard-coding 50
    -- would just move the wrong answer somewhere else.
    --
    -- THE WORST SAMPLE, NOT THE BEST, and that distinction is the whole point. How long a Wait(100)
    -- actually takes depends on where in the current tick it was called: at the start of a tick it
    -- returns in 100ms, just after one it waits until the next boundary past 100ms. So the
    -- quantisation is a BAND up to one tick wide, not a fixed offset. Calibrating on the smallest
    -- sample would absorb only the luckiest phase and let the rest read as drift again — which is
    -- exactly the flat-50 reading this is fixing.
    --
    -- Taking the largest means small real drift is absorbed too. That is the right trade for an
    -- "is the server coping" indicator: no false alarms, and anything that matters is far bigger
    -- than one tick anyway.
    local baseline = 100
    do
        local worst = 0
        for _ = 1, 15 do
            local t0 = GetGameTimer()
            Wait(100)
            local d = GetGameTimer() - t0
            if d > worst then worst = d end
        end
        if worst > baseline then baseline = worst end
        s.baselineMs = baseline
    end
    lastTick = GetGameTimer()

    while load.running do
        Wait(100)

        -- DRIFT GUARD, measured against the calibrated floor rather than against the 100ms we asked
        -- for. Zero now genuinely means "keeping up".
        local now = GetGameTimer()
        local drift = (now - lastTick) - baseline
        if drift < 0 then drift = 0 end
        lastTick = now
        s.lastDriftMs = drift
        if drift > s.worstDriftMs then s.worstDriftMs = drift end

        if drift > DRIFT_ABORT_MS then
            LoadTestStop(('server fell %dms behind — aborted before it got worse'):format(drift))
            return
        end

        -- Hold the rate-limit bypass open. Stop renewing and it lapses by itself in ~10s.
        if cfg.events > 0 and now - lastBypass > BYPASS_RENEW_MS then
            lastBypass = now
            pcall(function() exports.whip_core:__TestRateLimitBypass(true) end)
        end

        if cfg.dbevery > 0 and now - lastBurst >= cfg.dbevery * 1000 then
            lastBurst = now
            dbBurst(cfg.dbrows)
        end

        -- One door per 100ms tick. Steady rather than bursty on purpose: a door toggle writes a
        -- row and announces to the players holding its cell, and firing them all at once would
        -- measure a spike nobody's server actually experiences. Players open doors continuously,
        -- not in unison.
        doorTick = doorTick + 1
        if cfg.doors > 0 then toggleNextDoor(doorTick) end

        -- CHURN. Fractional carry, so a rate that does not divide evenly into ten ticks a second
        -- still averages out instead of silently rounding to zero — churn=5 would otherwise mean
        -- 0 per tick and no churn at all.
        if cfg.churn > 0 then
            churnCarry = churnCarry + (cfg.churn / 10.0)
            while churnCarry >= 1 do
                churnCarry = churnCarry - 1
                churnSlot = churnSlot + 1
                recycleOne(churnSlot, origin.x, origin.y, origin.z)
            end
        end

        if now - lastReport >= 500 then
            lastReport = now
            if load.source and load.source > 0 then
                TriggerClientEvent('whip_test:loadUpdate', load.source, {
                    elapsed    = math.floor((now - load.startedAt) / 1000),
                    phantoms   = s.phantoms,
                    vehicles   = s.vehicles,
                    items      = s.items,
                    doors      = s.doors,
                    containers = s.containers,
                    extraStats = s.extraStats,
                    doorToggles = s.doorToggles,
                    churned    = s.churned,
                    baselineMs = s.baselineMs,
                    dbSent     = s.dbSent,
                    dbDone     = s.dbDone,
                    dbFailed   = s.dbFailed,
                    dbInFlight = s.dbPeakInFlight,
                    dbP50      = percentile(s.dbLatencies, 0.50),
                    dbP95      = percentile(s.dbLatencies, 0.95),
                    dbP99      = percentile(s.dbLatencies, 0.99),
                    dbMax      = percentile(s.dbLatencies, 1.00),
                    bursts     = s.bursts,
                    eventsSent = s.eventsSent,
                    driftMs    = s.lastDriftMs,
                    worstDrift = s.worstDriftMs,
                    ramMb      = math.floor(collectgarbage('count') / 1024),
                })

                -- Reset the peak so the next window reports its own worst, not the run's.
                s.dbPeakInFlight = 0
            end
        end
    end
end

-- ---- Commands ---------------------------------------------------------------------------------

--- whip.devtools with developer mode on (whip_core's HasDevTools, as runner.lua's devAllowed). /testloadstop
--- keeps the bare ACE: stopping a run is never refused to someone who may start one.
local function devAllowed(src)
    local ok, yes = pcall(function() return exports.whip_core:HasDevTools(src) end)
    if ok then return yes == true end
    return IsPlayerAceAllowed(src, 'whip.devtools')
end

--- /testload [dial=value ...]  — everything defaults, so bare /testload is a full run.
RegisterCommand('testload', function(source, args)
    if source == 0 then
        print('[whip_test:load] /testload must be run in-game — the live panel needs a client.')
        print('[whip_test:load] /testloadstop works from here.')
        return
    end
    if not devAllowed(source) then
        TriggerClientEvent('chat:addMessage', source, { args = { '^1You need whip.devtools, with developer mode on (/w).' } })
        return
    end
    if load.running then
        TriggerClientEvent('chat:addMessage', source, { args = { '^3A load test is already running — /testloadstop' } })
        return
    end

    load.source = source     -- set first so tell() can reach the operator

    -- `/testload help` lists the dials rather than making anyone read this file.
    if args[1] and args[1]:lower() == 'help' then
        tell('dials — /testload players=200 items=500 stats=20')
        for _, name in ipairs({ 'players', 'vehicles', 'items', 'stats', 'doors',
                                'containers', 'events', 'dbrows' }) do
            local d = DIALS[name]
            tell(('  %-11s default %-4d max %-4d  %s'):format(name, d.default, d.max, d.help))
        end
        load.source = nil
        return
    end

    local cfg, unknown = parseDials(args)
    if #unknown > 0 then
        -- Reported, not ignored. A typo that silently does nothing means you believe you set a dial
        -- and the run measures something else — the worst failure a measurement tool can have.
        tell('^3ignored unknown argument(s): ' .. table.concat(unknown, ', '))
        tell('^3try /testload help')
    end

    load.cfg = cfg

    load.running   = true
    load.startedAt = GetGameTimer()
    load.stats     = freshStats()
    load.vehicles, load.items, load.doors, load.containers, load.statNames = {}, {}, {}, {}, {}
    load.abortReason = nil

    tell(('starting — %d players, %d vehicles, %d items, %d stats, %d doors, %d containers, '
          .. '%d events/s, %d churn/s, %d row bursts every %ds')
        :format(cfg.players, cfg.vehicles, cfg.items, cfg.stats, cfg.doors,
                cfg.containers, cfg.events, cfg.churn, cfg.dbrows, cfg.dbevery))
    tell('vehicles, doors and containers spawn hundreds of metres away — your client never streams them')

    TriggerClientEvent('whip_test:loadStart', source, {
        eventsPerSec = cfg.events,
        maxEventRate = DIALS.events.max,
    })

    CreateThread(function()
        local ped = GetPlayerPed(source)
        local c = (ped and ped ~= 0) and GetEntityCoords(ped) or vector3(0.0, 0.0, 72.0)

        if cfg.dbrows > 0 and not ensureTable() then
            LoadTestStop('database table could not be created')
            return
        end

        if cfg.players > 0 then
            local made = 0
            pcall(function() made = exports.whip_core:__TestPhantoms(cfg.players, cfg.announce == 1) end)
            load.stats.phantoms = made
            tell(('phantom players: %d'):format(made))
            if made == 0 then
                tell('^3none created — is Config.EnableTestSeams true?')
            end
        end

        if cfg.stats > 0 then
            registerExtraStats(cfg.stats)
            tell(('extra stats registered: %d (per-player tick now walks %d more each pass)')
                :format(#load.statNames, #load.statNames))
        end

        if cfg.vehicles > 0 then
            tell(('spawning %d vehicles...'):format(cfg.vehicles))
            spawnVehicles(cfg.vehicles, c.x, c.y, c.z)
            tell(('vehicles out: %d'):format(#load.vehicles))
        end

        if cfg.items > 0 then
            tell(('scattering %d ground items...'):format(cfg.items))
            spawnGroundItems(cfg.items, c.x, c.y, c.z)
            tell(('ground items: %d'):format(#load.items))
        end

        if cfg.doors > 0 then
            tell(('creating %d doors...'):format(cfg.doors))
            spawnDoors(cfg.doors, c.x, c.y, c.z)
            tell(('doors: %d'):format(#load.doors))
        end

        if cfg.containers > 0 then
            tell(('creating %d containers...'):format(cfg.containers))
            spawnContainers(cfg.containers, c.x, c.y, c.z)
            tell(('containers: %d'):format(#load.containers))
        end

        tell('^2setup complete — calibrating tick baseline, then running')
        runLoad(c)
    end)
end, true)

--- /testloadclean [confirm] — find and remove leftovers from a run that did not clean up after itself.
---
--- WHY THIS IS NEEDED AT ALL. A run tracks everything it creates and deletes it on stop, but that
--- only works if the ids were recorded correctly. The first version of the ground-item dial read
--- the wrong return value — CreateGroundItem hands back the item's DATA TABLE, not its id — so it
--- created hundreds of rows and recorded none of them. They survived every stop, every restart, and
--- were only noticed when whip_core failed to load them.
---
--- REPORTS FIRST, DELETES ONLY ON `confirm`. A cleanup that guesses which rows are "test-looking"
--- and removes them unasked is one bad pattern away from deleting real player property. You see the
--- counts, then you decide.
---
--- What it looks for:
---   * the marker this test now writes into every item it creates, and into every vehicle's data
---   * ground metadata that is a bare number, which is what the broken version produced and what
---     breaks whip_core's ground loader
---   * doors and containers by their _loadtest_ names
RegisterCommand('testloadclean', function(source, args)
    if source ~= 0 and not devAllowed(source) then
        TriggerClientEvent('chat:addMessage', source, { args = { '^1You need whip.devtools, with developer mode on (/w).' } })
        return
    end

    local confirm = (args[1] or ''):lower() == 'confirm'
    local say = function(msg)
        print('[whip_test:loadclean] ' .. msg)
        if source and source > 0 then
            TriggerClientEvent('chat:addMessage', source, { args = { '^5[loadclean]^0 ' .. msg } })
        end
    end

    CreateThread(function()
        local targets = {
            {
                what  = 'ground items marked as load-test',
                count = 'SELECT COUNT(*) AS n FROM `ground_items` WHERE `metadata` LIKE ?',
                del   = 'DELETE FROM `ground_items` WHERE `metadata` LIKE ?',
                args  = { '%_loadtest%' },
            },
            {
                -- The broken version wrote a coordinate — a bare NUMBER — where the metadata
                -- belongs, and that is what makes the loader throw.
                --
                -- NOT "anything that is not an object", which is what this used to match: an empty
                -- metadata table is encoded as '[]' (GroundItems.create), so every real item
                -- dropped with no metadata matched too, and `confirm` deleted players' property.
                -- A JSON array or null is a legitimate shape; only a scalar is the fingerprint.
                what  = 'ground items whose metadata is a bare number or string (these break whip_core on load)',
                count = "SELECT COUNT(*) AS n FROM `ground_items` WHERE `metadata` IS NOT NULL "
                     .. "AND `metadata` <> '' AND `metadata` NOT LIKE '{%' "
                     .. "AND `metadata` NOT LIKE '[%' AND `metadata` <> 'null'",
                del   = "DELETE FROM `ground_items` WHERE `metadata` IS NOT NULL "
                     .. "AND `metadata` <> '' AND `metadata` NOT LIKE '{%' "
                     .. "AND `metadata` NOT LIKE '[%' AND `metadata` <> 'null'",
                args  = {},
            },
            {
                -- Found by the marker createOneVehicle writes, and deleted ONE BY ONE through
                -- whip_core rather than by SQL: a vehicle has a cache, storage and a write-behind
                -- queue, and a raw DELETE leaves whip believing in a car that is gone.
                what   = 'load-test vehicles',
                count  = "SELECT COUNT(*) AS n FROM `vehicles` WHERE JSON_EXTRACT(`vehData`, '$._loadtest') IS NOT NULL",
                ids    = "SELECT `vehicleId` AS id FROM `vehicles` WHERE JSON_EXTRACT(`vehData`, '$._loadtest') IS NOT NULL",
                delEach = killVehicle,
                args   = {},
            },
            {
                what  = 'load-test doors',
                count = 'SELECT COUNT(*) AS n FROM `doors` WHERE `label` LIKE ?',
                del   = 'DELETE FROM `doors` WHERE `label` LIKE ?',
                args  = { '_loadtest_door_%' },
            },
            {
                what  = 'load-test containers',
                count = 'SELECT COUNT(*) AS n FROM `containers` WHERE `name` LIKE ?',
                -- Contents first, or deleting the container strands its rows in
                -- container_inventory with nothing pointing at them. DeleteContainer does this
                -- properly; raw SQL has to be told.
                predel = 'DELETE FROM `container_inventory` WHERE `containerId` IN '
                      .. '(SELECT `containerId` FROM `containers` WHERE `name` LIKE ?)',
                del   = 'DELETE FROM `containers` WHERE `name` LIKE ?',
                args  = { '_loadtest_ctr_%' },
            },
        }

        local total = 0
        for _, t in ipairs(targets) do
            local ok, rows = pcall(MySQL.query.await, t.count, t.args)
            local n = (ok and rows and rows[1] and rows[1].n) or 0
            total = total + n
            say(('%5d  %s'):format(n, t.what))
        end

        if total == 0 then
            say('^2nothing to clean up')
            return
        end

        if not confirm then
            say(('^3%d rows would be deleted. Run /testloadclean confirm to do it.'):format(total))
            return
        end

        for _, t in ipairs(targets) do
            if t.delEach then
                local ok, rows = pcall(MySQL.query.await, t.ids, t.args)
                if not ok then
                    say('^1failed: ' .. t.what .. ' — ' .. tostring(rows))
                else
                    for _, row in ipairs(rows or {}) do
                        if not t.delEach(row.id) then
                            say(('^1could not delete %s #%s'):format(t.what, tostring(row.id)))
                        end
                    end
                end
            else
                if t.predel then
                    local okPre, errPre = pcall(MySQL.query.await, t.predel, t.args)
                    if not okPre then say('^1failed (dependents): ' .. t.what .. ' — ' .. tostring(errPre)) end
                end
                local ok, err = pcall(MySQL.query.await, t.del, t.args)
                if not ok then say('^1failed: ' .. t.what .. ' — ' .. tostring(err)) end
            end
        end

        say(('^2deleted %d rows'):format(total))
        say('^3restart whip_core — its caches still hold what was just removed')
    end)
end, true)

--- /testloadstop — works from the server console on purpose.
---
--- If the client crashed, the operator has no chat and no panel. The console is the only place
--- left to type, so this is the one command that must never require a player.
RegisterCommand('testloadstop', function(source)
    if source ~= 0 and not IsPlayerAceAllowed(source, 'whip.devtools') then
        TriggerClientEvent('chat:addMessage', source, { args = { '^1You need whip.devtools permission.' } })
        return
    end

    if not LoadTestStop(source == 0 and 'stopped from console' or 'stopped by operator') then
        local msg = 'No load test is running.'
        if source == 0 then print('[whip_test:load] ' .. msg)
        else TriggerClientEvent('chat:addMessage', source, { args = { '^3' .. msg } }) end
    end
end, true)
