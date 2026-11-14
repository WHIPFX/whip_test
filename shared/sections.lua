-- ============================================
-- whip_test — test sections
-- ============================================
--
-- The cards on the /test menu. Each section is a group of test modules that are tested together
-- when you click its card; "Run full suite" still runs every module, as /test always did.
--
-- ADDING A TEST MODULE? Put its `category` (the name in its RegisterTestModule call) into one of the
-- `modules` lists below. Forget, and it is not lost: it shows up on its own card called "Other".
--
-- Client modules are listed here too, under their own category names ('Client: Vehicles'), so a
-- section tests both halves of a feature — the server side and the player's game.
--
--   id      short name, used by `/test <id>` to run a section straight from chat
--   label   what the card says
--   desc    one line under it
--   icon    anything the page can draw — an emoji is simplest

TestSections = {
    {
        id = 'player', label = 'Player & Stats', icon = '🧍',
        desc = 'Characters, the player API, appearance, stats and effects',
        modules = {
            'Player', 'Player API', 'Appearance', 'Stats & Effects', 'Player Flags',
            'Client: Player', 'Client: Stats',
        },
    },
    {
        id = 'inventory', label = 'Inventory & Items', icon = '🎒',
        desc = 'Moving items, placing them, using them, and the store system',
        modules = {
            'Inventory', 'Item Registration', 'Item Use', 'Moves', 'Placement', 'StoreMove',
            'Place Item', 'Store Kinds', 'Admin Inventory', 'Inventory API', 'Menu & Shift-Click',
            'Client: Inventory',
        },
    },
    {
        id = 'containers', label = 'Containers & Ground', icon = '📦',
        desc = 'Stashes, crates, and items dropped on the ground',
        modules = {
            'Containers', 'Ground Items', 'Ground Drop',
        },
    },
    {
        id = 'panels', label = 'Panels', icon = '🗂️',
        desc = 'Item panels and the OpenPanel API',
        modules = {
            'Panel (OpenPanel API)', 'Panels', 'Panel Contract', 'Panel Item',
        },
    },
    {
        id = 'saving', label = 'Saving', icon = '💾',
        desc = 'What reaches the database, when, and what happens when it says no',
        modules = {
            'Persistence', 'Incremental Save', 'Write-Behind', 'Failure Paths', 'Activity Log',
        },
    },
    {
        id = 'vehicles', label = 'Vehicles', icon = '🚗',
        desc = 'Cars, keys, stats, vehicle data, the damage a car keeps, garages and temporary cars',
        modules = {
            'Vehicles', 'Vehicle Data', 'Vehicle Damage',
            'Client: Vehicles', 'Client: Garage Helper',
        },
    },
    {
        id = 'money', label = 'Money & Shops', icon = '💰',
        desc = 'Bank accounts, who can use them, paying and refunds, shops and their stock',
        modules = {
            'Bank', 'Bank Access', 'Payments', 'Shops', 'Shop Economy',
        },
    },
    {
        id = 'jobs', label = 'Jobs', icon = '💼',
        desc = 'Jobs, grades and clocking on',
        modules = {
            'Jobs',
            'Client: Jobs',
        },
    },
    {
        id = 'world', label = 'World', icon = '🌍',
        desc = 'Time and weather, zones, doors (declared doors too), properties and the camera',
        modules = {
            'Time & Weather', 'Zones (Server)', 'Doors (Server)', 'World API', 'Managed Doors', 'Property Math',
            'Properties', 'Property Packs', 'Property Admin', 'Property Wizard', 'Property Garage', 'Property Scale',
            'Property Stashes', 'Property Themes',
            'Client: Time', 'Client: Zones', 'Client: Doors', 'Client: Camera',
        },
    },
    {
        id = 'emotes', label = 'Emotes', icon = '💃',
        desc = '/e and its props, what ends an emote, walk styles and moods',
        modules = {
            'Client: Emotes',
        },
    },
    {
        id = 'voice', label = 'Voice', icon = '🎙️',
        desc = "The voice system (whip_voice or whip_voice_simple) and its items: the megaphone in hand, the radio",
        modules = {
            'Voice Items',
            'Client: Voice',
        },
    },
    {
        id = 'director', label = 'Director', icon = '🎬',
        desc = "Whole scenarios run as Tests: Check, flow, endings, player cards, world things, goals, talk, fail conditions, every task, live runs, the API",
        modules = {
            'Director API', 'Director: Check', 'Director: Flow', 'Director: Endings', 'Director: Live Runs',
            'Director: Player Cards', 'Director: World Things', 'Director: Goals', 'Director: Conversations',
            'Director: Fail Conditions', 'Director: NPC Tasks', 'Director: Car & Prop Tasks', 'Director: Security',
            'Director: Fixed Weapons',
        },
    },
    {
        id = 'interaction', label = 'Interaction & UI', icon = '👆',
        desc = 'AddAction (prompts, wheel, car parts), placed and runtime points, NPCs, overrides, the UI library',
        modules = {
            'UI From The Server', 'Interaction Points', 'Runtime Points',
            'Client: Interactions', 'Client: UI Library', 'Client: Dev Pages',
            'Client: Clean Screen', 'Client: Objectives',
        },
    },
    {
        id = 'security', label = 'Security & Framework', icon = '🛡️',
        desc = 'SecureEvent, callbacks, the Sentinel, the registration rule and the API contract',
        modules = {
            'SecureEvent', 'Callbacks', 'Sentinel', 'API Contract', 'Audit 2 Fixes',
            'Registry & Security', 'Permissions',
            'Client: Callbacks', 'Client: Registry',
        },
    },
}

--- The card for any module nobody listed above. Only shown when something is in it.
TEST_SECTION_OTHER = {
    id = 'other', label = 'Other', icon = '❔',
    desc = 'Test modules that are not in any section yet — see shared/sections.lua',
}

-- [module category] = section id, built once from the lists above.
local _sectionOf = {}
for _, section in ipairs(TestSections) do
    for _, category in ipairs(section.modules) do
        _sectionOf[category] = section.id
    end
end

--- Which section a test module (or a result row) belongs to.
---@param category string  the module's category
---@return string sectionId
function TestSectionOf(category)
    return _sectionOf[category] or TEST_SECTION_OTHER.id
end

--- The section with this id, or nil. 'other' is a real section too.
---@param id string
---@return table|nil
function TestSectionById(id)
    if id == TEST_SECTION_OTHER.id then return TEST_SECTION_OTHER end
    for _, section in ipairs(TestSections) do
        if section.id == id then return section end
    end
    return nil
end

--- Another resource's own tests get a card of their own, by its name (`/test <resource>` runs them), holding each
--- category it registers (the RegisterTestModule export, server/runner.lua).
---@param owner string
---@param category string
function AddTestSection(owner, category)
    local section
    for _, s in ipairs(TestSections) do
        if s.external and s.owner == owner then section = s break end
    end
    if not section then
        local id = TestSectionById(owner) and ('res_' .. owner) or owner   -- never one of whip_test's own ids
        section = { id = id, owner = owner, external = true, label = owner, icon = '🧩',
                    desc = owner .. '\'s own tests', modules = {} }
        TestSections[#TestSections + 1] = section
    end
    for _, c in ipairs(section.modules) do if c == category then return end end
    section.modules[#section.modules + 1] = category
    _sectionOf[category] = section.id
end

--- That resource's card goes with it.
---@param owner string
function RemoveTestSection(owner)
    for i = #TestSections, 1, -1 do
        local s = TestSections[i]
        if s.external and s.owner == owner then
            for _, c in ipairs(s.modules) do _sectionOf[c] = nil end
            table.remove(TestSections, i)
        end
    end
end
