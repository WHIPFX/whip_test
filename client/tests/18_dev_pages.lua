-- ============================================
-- Client: Dev Pages — a resource's own page in /w (RegisterDevPage / RefreshDevPage / RemoveDevPage)
-- ============================================
--
-- Checks the exports' answers from a satellite's side: what is taken, what is refused and why, and that a
-- page is the registering resource's own. Drawing the page is checked by eye in /w.

local ID = 'whip_test_page'

--- An export call that may refuse: ok and why, never a throw out of the test.
local function call(name, ...)
    local fn = exports.whip_core[name]
    local ok, a, b = pcall(fn, exports.whip_core, ...)
    if not ok then return false, 'threw: ' .. tostring(a) end
    return a, b
end

local function page(extra)
    local def = {
        label    = 'whip_test page',
        desc     = 'A page /test made; it goes when the test ends.',
        rows     = function() return { { id = 'one', label = 'One' } } end,
        onSelect = function() end,
    }
    for k, v in pairs(extra or {}) do def[k] = v end
    return def
end

RegisterClientTestModule({
    order    = 18,
    category = 'Client: Dev Pages',
    teardown = function()
        call('RemoveDevPage', ID)
    end,
    tests = {
        {
            name = 'A page is taken, refreshed, replaced and removed',
            fn = function()
                local ok, why = call('RegisterDevPage', ID, page())
                assertTrue(ok, ('RegisterDevPage answered true (why: %s)'):format(tostring(why)))
                ok, why = call('RefreshDevPage', ID)
                assertTrue(ok, ('RefreshDevPage answered true (why: %s)'):format(tostring(why)))
                ok, why = call('RegisterDevPage', ID, page({ label = 'whip_test page, again' }))
                assertTrue(ok, ('the same id again replaces it (why: %s)'):format(tostring(why)))
                ok, why = call('RemoveDevPage', ID)
                assertTrue(ok, ('RemoveDevPage answered true (why: %s)'):format(tostring(why)))
                ok, why = call('RemoveDevPage', ID)
                assertEqual(ok, false, 'removing it twice is refused')
                assertTrue(type(why) == 'string', 'with a reason')
                ok = call('RefreshDevPage', ID)
                assertEqual(ok, false, 'a removed page cannot be refreshed')
            end,
        },
        {
            name = 'A page without what it needs is refused, saying why',
            fn = function()
                local cases = {
                    { 'a bad id', 'has spaces', page() },
                    { 'no label', ID, page({ label = false }) },
                    { 'no rows', ID, page({ rows = false }) },
                    { 'rows as a string', ID, page({ rows = 'rows' }) },
                    { 'no onSelect', ID, page({ onSelect = false }) },
                    { 'onBack not a function', ID, page({ onBack = 3 }) },
                }
                for _, c in ipairs(cases) do
                    -- `false` stands in for "left out": a table built with nil would not carry the key at all.
                    local def = c[3]
                    for k, v in pairs(def) do if v == false then def[k] = nil end end
                    local ok, why = call('RegisterDevPage', c[2], def)
                    assertEqual(ok, false, c[1] .. ' is refused')
                    assertTrue(type(why) == 'string' and why ~= '', c[1] .. ': says why (' .. tostring(why) .. ')')
                end
                call('RemoveDevPage', ID)
            end,
        },
        {
            name = 'Another resource\'s page is not this one\'s to refresh or remove',
            fn = function()
                -- whip_core keys a page by the resource that registered it, so an id this resource never
                -- registered is refused even if another resource uses it (whip_scenes' 'scenes').
                local ok = call('RefreshDevPage', 'scenes')
                assertEqual(ok, false, 'RefreshDevPage on an id this resource never registered is refused')
                ok = call('RemoveDevPage', 'scenes')
                assertEqual(ok, false, 'RemoveDevPage on it is refused too')
            end,
        },
    },
})
