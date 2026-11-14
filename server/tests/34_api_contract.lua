-- ============================================
-- API CONTRACT — does the type file describe the exports that actually exist?
--
-- WHY THIS MODULE EXISTS. An outside review of whip found five classes of problem, and the one
-- underneath all of them was that the public API did not consistently do what it said. Two of the
-- findings were code (a move that never persisted, a flush that could split a transfer) and both
-- are now covered by tests in 25_storemove and 29_writebehind. The rest were DOCUMENTATION drift:
-- nine exports with no type stub, a handler whose annotated signature was wrong from its third
-- parameter on, and a stub for an export that had been removed.
--
-- Those were all fixed by hand, and by hand they would drift again by the end of the month. An
-- annotation is not checked by anything: it compiles whatever it claims, and the editor repeats
-- the claim confidently to whoever reads it next. The only thing that keeps a type file honest is
-- something that fails when it stops being true.
--
-- HOW IT READS THE EXPORTS. There is no runtime way to enumerate exports registered with
-- `exports('Name', fn)` — the manifest's `export` metadata only covers ones declared there, and
-- whip_core declares none that way. So this reads the source: GetResourceMetadata gives the
-- server_scripts list from the manifest, LoadResourceFile gives each file, and a pattern finds the
-- registrations. Reading source in a test is ugly; shipping a type file nobody checks is worse.
--
-- WHAT THE SOURCE READ CANNOT SEE, AND THE RUNTIME CHECK THAT COVERS IT. An export can be in the
-- source and still never register — the file throws at load before reaching its exports() line.
-- So every name is also looked up for real: indexing a missing export raises "No such export".
-- ============================================

local CORE = 'whip_core'

--- Exports whose absence from the type file is deliberate. Test seams (__Test*) are handled by
--- isTestSeam below; this is for anything else.
local UNTYPED_ON_PURPOSE = {}

--- Type stubs with no matching export, where that is deliberate.
local TYPED_ON_PURPOSE = {
    -- Kept as a SIGNPOST rather than deleted, carrying @deprecated and an explanation. It was the
    -- only public entry point in whip with no schema, no session check, no rate limit and no Event
    -- Monitor entry. An editor silently losing a completion is a worse way to discover that than
    -- being told why, so the stub stays and this test knows about it.
    RegisterCallback = true,
}

--- Manifest globs this module cannot expand on a server without io.popen, and why that is fine.
---
--- The `items` folders are expanded by their own naming rule (see expandGlob). Nothing similar
--- exists for these, and a server-side Lua state has no other way to list a folder — so without
--- this, the glob test SKIPPED on every run (09-23), which is noise that teaches people to ignore
--- skips. Each entry says why its files cannot hold an export; if that stops being true, remove
--- the entry and the test will say so. Checked 09-23: no file in tools/panel_sections calls exports().
local GLOBS_WITHOUT_EXPORTS = {
    ['tools/panel_sections/*.lua'] = 'client wiring for /whip sections; each file registers into '
        .. 'PanelSections and exposes nothing',
}

--- Exports whose real parameter list is deliberately longer than the stub's.
local ARITY_ON_PURPOSE = {
    -- Three trailing positional parameters exist only for callers still on the deprecated
    -- six-argument form; the stub documents the table form everyone should use.
    StoreMove = true,
}

--- Exports whose parameters are deliberately NAMED differently in the stub.
local NAMES_ON_PURPOSE = {
    -- Takes a table (the form to write) or the old positional list, so the export's own
    -- parameters are a..h; the stub names what each slot is in the positional form.
    CreateGroundItem = true,
}

--- Remove Lua comments, so an `exports('X'` written inside one — an example, a note about a
--- removed export — is not counted as a real registration.
local function stripComments(src)
    src = src:gsub('%-%-%[(=*)%[.-%]%1%]', '')
    src = src:gsub('%-%-[^\n]*', '')
    return src
end

--- Files matching a manifest glob such as 'server/items/*.lua'.
---
--- LoadResourceFile cannot list a directory, and this used to skip every glob entry silently —
--- so an export added under server/items/ would never have been checked. Listed through the OS
--- where the runtime allows it; otherwise, for an `items` folder, by the rule that folder follows
--- (one file per item, named after its key). A glob neither can expand is returned as
--- unexpanded, and the test that reads these files says so as a SKIP rather than passing.
---@param glob string
---@return string[] paths, boolean expanded
local function expandGlob(glob)
    local dir, pattern = glob:match('^(.*)/([^/]*%*[^/]*)$')
    if not dir then return {}, false end

    local paths = {}
    local okList = pcall(function()
        local root = GetResourcePath(CORE)
        -- FXServer's Lua has no `package` to ask: a drive letter or a backslash in the path says Windows
        local windows = root:match('^%a:') ~= nil or root:find('\\', 1, true) ~= nil
        if not windows and os and os.getenv then windows = os.getenv('OS') == 'Windows_NT' end
        local cmd = windows
            and ('dir /b "%s\\%s\\%s" 2>nul'):format(root:gsub('/', '\\'), dir:gsub('/', '\\'), pattern)
            or ('ls -1 "%s/%s" 2>/dev/null'):format(root, dir)
        local pipe = io.popen(cmd)
        if not pipe then return end
        local luaPattern = '^' .. pattern:gsub('%.', '%%.'):gsub('%*', '.*') .. '$'
        for line in pipe:lines() do
            local name = line:match('([^/\\]+)$')
            if name and name:match(luaPattern) then paths[#paths + 1] = dir .. '/' .. name end
        end
        pipe:close()
    end)
    if okList and #paths > 0 then return paths, true end

    if dir:match('items$') then
        for key in pairs(exports.whip_core:GetAllItemDefs() or {}) do
            local path = dir .. '/' .. key .. '.lua'
            if LoadResourceFile(CORE, path) then paths[#paths + 1] = path end
        end
        if #paths > 0 then return paths, true end
    end

    return {}, false
end

--- Every file a manifest script list names, with globs expanded.
---@param kind string  'server_script' | 'client_script'
---@return string[] paths, string[] unexpanded
local function scriptFiles(kind)
    local paths, unexpanded = {}, {}
    local n = GetNumResourceMetadata(CORE, kind) or 0
    for i = 0, n - 1 do
        local path = GetResourceMetadata(CORE, kind, i)
        -- @-prefixed entries belong to another resource (oxmysql's MySQL.lua).
        if path and path:sub(1, 1) ~= '@' then
            if path:find('*', 1, true) then
                local found, ok = expandGlob(path)
                if not ok then unexpanded[#unexpanded + 1] = path end
                for _, p in ipairs(found) do paths[#paths + 1] = p end
            else
                paths[#paths + 1] = path
            end
        end
    end
    return paths, unexpanded
end

--- Helpers in whip_core that call exports(name, ...) for the name they are given, so the export has no
--- exports('Name' line of its own: client/zones.lua's zoneSetter('ZoneSetCondition', fn) (review 8, 5 Oct
--- 2026). Without this the scan called the ten ZoneSet* / ZoneUpdate* stubs stale. A new helper of the
--- kind goes here.
local EXPORT_HELPERS = { 'zoneSetter' }

--- Every `exports('Name', ...)` across whip_core's scripts of one side, with the parameter list
--- when the export is an inline `function(...)`.
---@param kind string  'server_script' | 'client_script'
---@return table<string, string|false> found  name -> parameter list, or false when not inline
---@return string[] unexpanded
local function realExports(kind)
    local found = {}
    local paths, unexpanded = scriptFiles(kind)

    -- AND THE SHARED SCRIPTS, whose exports exist on BOTH sides. shared/registry.lua exports
    -- GetRegistrations to the server and the client from one line (09-24); read only server_script
    -- and client_script, and its stubs looked like stubs for nothing.
    local shared, sharedUnexpanded = scriptFiles('shared_script')
    for _, p in ipairs(shared) do paths[#paths + 1] = p end
    for _, g in ipairs(sharedUnexpanded) do unexpanded[#unexpanded + 1] = g end

    for _, path in ipairs(paths) do
        local src = LoadResourceFile(CORE, path)
        if src then
            src = stripComments(src)
            for _, q in ipairs({ "'", '"' }) do
                for name in src:gmatch('exports%s*%(%s*' .. q .. '([A-Za-z_][A-Za-z0-9_]*)' .. q) do
                    if found[name] == nil then found[name] = false end
                end
                for name, params in src:gmatch('exports%s*%(%s*' .. q .. '([A-Za-z_][A-Za-z0-9_]*)' .. q
                        .. '%s*,%s*function%s*%(([^)]*)%)') do
                    found[name] = params
                end
                -- Exports a helper registers by name (EXPORT_HELPERS): real, but no exports('Name' line.
                for _, helper in ipairs(EXPORT_HELPERS) do
                    for name in src:gmatch(helper .. '%s*%(%s*' .. q .. '([A-Za-z_][A-Za-z0-9_]*)' .. q) do
                        if found[name] == nil then found[name] = false end
                    end
                end
            end
        end
    end
    return found, unexpanded
end

--- Every `function whip_core:Name(...)` in a type file, with its parameter list.
---@param file string
---@return table<string, string>
local function typedExports(file)
    local found = {}
    local src = LoadResourceFile(CORE, file)
    if not src then return found end
    src = stripComments(src)

    for name, params in src:gmatch('function%s+whip_core:([A-Za-z_][A-Za-z0-9_]*)%s*%(([^)]*)%)') do
        found[name] = params
    end
    return found
end

local function isTestSeam(name)
    return name:sub(1, 6) == '__Test'
end

--- Number of parameters in a list, or nil for a variadic one (which cannot be compared).
local function arity(params)
    if params:find('...', 1, true) then return nil end
    local n = 0
    for p in params:gmatch('[^,]+') do
        if p:match('%S') then n = n + 1 end
    end
    return n
end

--- The parameter names of a list, in order.
local function paramNames(params)
    local out = {}
    for p in params:gmatch('[^,]+') do
        local name = p:match('^%s*(.-)%s*$')
        if name ~= '' then out[#out + 1] = name end
    end
    return out
end

--- Exports and stubs of one side whose parameter counts disagree: { 'Name (export n, stub m)' }.
local function arityMismatches(real, typed)
    local wrong = {}
    for name, params in pairs(real) do
        local stub = typed[name]
        if params and stub and not ARITY_ON_PURPOSE[name] then
            local a, b = arity(params), arity(stub)
            if a and b and a ~= b then
                wrong[#wrong + 1] = ('%s (export %d, stub %d)'):format(name, a, b)
            end
        end
    end
    table.sort(wrong)
    return wrong
end

--- Exports and stubs of one side whose parameter NAMES disagree, position by position. A stub
--- whose names drift from the code is how a reader ends up passing a reason where options go.
local function nameMismatches(real, typed)
    local wrong = {}
    for name, params in pairs(real) do
        local stub = typed[name]
        if params and stub and not NAMES_ON_PURPOSE[name] and arity(params) and arity(stub) then
            local a, b = paramNames(params), paramNames(stub)
            for i = 1, math.max(#a, #b) do
                if a[i] ~= b[i] then
                    wrong[#wrong + 1] = ('%s (#%d: export %s, stub %s)'):format(name, i, tostring(a[i]), tostring(b[i]))
                    break
                end
            end
        end
    end
    table.sort(wrong)
    return wrong
end

--- Sorted, so a failure message reads the same way twice and can be diffed against a previous run.
local function sortedKeys(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out)
    return out
end

--- Names in `real` with no stub in `typed`, and stubs in `typed` with no name in `real`.
local function compare(real, typed)
    local missing, stale = {}, {}
    for name in pairs(real) do
        if typed[name] == nil and not isTestSeam(name) and not UNTYPED_ON_PURPOSE[name] then
            missing[name] = true
        end
    end
    for name in pairs(typed) do
        if real[name] == nil and not TYPED_ON_PURPOSE[name] then
            stale[name] = true
        end
    end
    return sortedKeys(missing), sortedKeys(stale)
end

RegisterTestModule({
    order    = 34,
    category = 'API Contract',

    tests = {
        {
            name = 'the export list can be read at all',
            fn = function()
                -- A guard on the tests below rather than a thing worth testing for its own sake: if
                -- the source read silently returned nothing, they would all pass by finding no
                -- discrepancies, and this module would go green while checking nothing.
                local real = realExports('server_script')
                local typed = typedExports('types/server.lua')
                -- Into a local, NOT straight into next(): realExports returns TWO values, and
                -- `next(realExports(...))` handed the second (the unexpanded-glob list) to next as a
                -- starting key — "invalid key to 'next'" (09-23).
                local realClient = realExports('client_script')

                assertTrue(next(real) ~= nil,
                    'found at least one exports() call in whip_core — if this fails the reader is '
                    .. 'broken, not the API')
                assertTrue(next(typed) ~= nil,
                    'found at least one stub in types/server.lua')
                assertTrue(next(realClient) ~= nil,
                    'found at least one exports() call in whip_core\'s client scripts')
                assertTrue(next(typedExports('types/client.lua')) ~= nil,
                    'found at least one stub in types/client.lua')
            end,
        },
        {
            name = 'every manifest glob was read',
            fn = function()
                -- A glob that cannot be expanded is a directory of files whose exports nothing
                -- checks. That is not a pass.
                local _, serverGlobs = realExports('server_script')
                local _, clientGlobs = realExports('client_script')
                local all = {}
                for _, list in ipairs({ serverGlobs, clientGlobs }) do
                    for _, g in ipairs(list) do
                        -- A known folder with no exports in it (GLOBS_WITHOUT_EXPORTS) is not a gap.
                        if not GLOBS_WITHOUT_EXPORTS[g] then all[#all + 1] = g end
                    end
                end
                if #all > 0 then
                    skip('could not list ' .. table.concat(all, ', ')
                        .. ' — exports in those files are unchecked (io.popen unavailable?)')
                end
                assertEqual(#all, 0, 'every glob expanded')
            end,
        },
        {
            name = 'every server export has a type stub',
            fn = function()
                local missing = compare(realExports('server_script'), typedExports('types/server.lua'))
                assertEqual(#missing, 0,
                    'exports with no entry in types/server.lua: ' .. table.concat(missing, ', ')
                    .. ' — an export nobody can autocomplete is invisible to anyone discovering '
                    .. 'the API through their editor')
            end,
        },
        {
            name = 'every server type stub has a real export behind it',
            fn = function()
                local _, stale = compare(realExports('server_script'), typedExports('types/server.lua'))
                assertEqual(#stale, 0,
                    'stubs in types/server.lua with no export: ' .. table.concat(stale, ', ')
                    .. ' — autocomplete offering a call that does not exist is worse than offering '
                    .. 'nothing, because it is believed')
            end,
        },
        {
            name = 'every client export has a stub, and every client stub an export',
            fn = function()
                -- The same comparison for the other side. The client exports are read from the
                -- same manifest, as source; there is no runtime check here because a client export
                -- only exists in the client's Lua state.
                local missing, stale = compare(realExports('client_script'), typedExports('types/client.lua'))
                assertEqual(#missing, 0, 'client exports with no entry in types/client.lua: '
                    .. table.concat(missing, ', '))
                assertEqual(#stale, 0, 'stubs in types/client.lua with no client export: '
                    .. table.concat(stale, ', '))
            end,
        },
        {
            name = 'every server export in the source is actually registered',
            fn = function()
                -- The source says exports('X', ...); this asks the runtime. A file that throws
                -- while loading never reaches its exports() lines, and the source read above cannot
                -- tell that from a file that loaded.
                local unregistered = {}
                for name in pairs(realExports('server_script')) do
                    local ok = pcall(function() return exports.whip_core[name] end)
                    if not ok then unregistered[name] = true end
                end
                local list = sortedKeys(unregistered)
                assertEqual(#list, 0, 'in the source but not registered at runtime: ' .. table.concat(list, ', ')
                    .. ' — did the file that declares them fail to load?')
            end,
        },
        {
            name = 'every stub takes as many parameters as its export',
            fn = function()
                -- The drift that started this module included a handler whose annotated signature
                -- was wrong from its third parameter on. Only inline `function(...)` exports can be
                -- compared, and variadic ones are skipped. Both sides: the client stubs drift the
                -- same way (the client was left out until 09-25).
                local server = arityMismatches(realExports('server_script'), typedExports('types/server.lua'))
                local client = arityMismatches(realExports('client_script'), typedExports('types/client.lua'))
                assertEqual(#server, 0, 'server parameter counts disagree: ' .. table.concat(server, ', '))
                assertEqual(#client, 0, 'client parameter counts disagree: ' .. table.concat(client, ', '))
            end,
        },
        {
            name = 'every stub names its parameters as its export does',
            fn = function()
                -- The same count can still hide a swap: a stub saying `reason` where the export takes
                -- `opts`, or `containerId` where it takes a container OR a shop. Compared position by
                -- position; a deliberate difference is listed in NAMES_ON_PURPOSE with its reason.
                local server = nameMismatches(realExports('server_script'), typedExports('types/server.lua'))
                local client = nameMismatches(realExports('client_script'), typedExports('types/client.lua'))
                assertEqual(#server, 0, 'server parameter names disagree: ' .. table.concat(server, ', '))
                assertEqual(#client, 0, 'client parameter names disagree: ' .. table.concat(client, ', '))
            end,
        },
        {
            name = 'test seams stay out of the public type files',
            fn = function()
                -- The other direction of the same rule. __Test* exports are real and callable, and
                -- they must never appear in the stubs a satellite developer reads — a seam that
                -- fakes a database failure has no business being suggested by an editor.
                local leaked = {}
                for _, file in ipairs({ 'types/server.lua', 'types/client.lua' }) do
                    for name in pairs(typedExports(file)) do
                        if isTestSeam(name) then leaked[name] = true end
                    end
                end

                local list = sortedKeys(leaked)
                assertEqual(#list, 0,
                    'test seams leaked into the type files: ' .. table.concat(list, ', '))
            end,
        },
    },
})
