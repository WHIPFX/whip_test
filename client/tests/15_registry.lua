-- ============================================
-- Client: Registry (2026-09-24) — section 5 of the API TODO, the client half
--
--   * REG-1  item flags, stat displays and appearance holds follow the one registration rule:
--            whip_core's own flag cannot be taken, ours can be registered again, only the owner
--            removes; GetRegistrations on the client
--   * SEC-5  a callback with no answer to give says why
--   * REG-3  the satellite helper works on the client too
-- ============================================

local FLAG = '_t46_flag'

local function listed(registry, key)
    for _, r in ipairs(exports.whip_core:GetRegistrations(GetCurrentResourceName()) or {}) do
        if r.registry == registry and r.key == key then return true end
    end
    return false
end

RegisterClientTestModule({
    order    = 15,
    category = 'Client: Registry',
    tests = {
        {
            name = "REG-1: whip_core's own item flag cannot be taken; ours registers twice",
            fn = function()
                local ok, err = exports.whip_core:RegisterItemFlag('lockpick')
                assertFalse(ok, "whip_core's lockpick flag is refused")
                assertTrue(tostring(err):find('belongs to whip_core', 1, true) ~= nil,
                    ('naming the owner (got "%s")'):format(tostring(err)))

                local ok1, err1 = exports.whip_core:RegisterItemFlag(FLAG, 'drink')
                assertTrue(ok1, 'our flag registers: ' .. tostring(err1))
                local ok2, err2 = exports.whip_core:RegisterItemFlag(FLAG, 'drink')
                assertTrue(ok2, 'and again: ' .. tostring(err2))
                assertTrue(listed('ItemFlag', FLAG), 'GetRegistrations lists it as ours')
            end,
        },
        {
            name = 'REG-1: a stat display is removed only by its owner',
            fn = function()
                local ok, err = exports.whip_core:ClearVehicleStatDisplay('_t46_no_display')
                assertFalse(ok, 'clearing a display nobody set is refused')
                assertNotNil(err, 'with a reason')

                local ok1, err1 = exports.whip_core:SetVehicleStatDisplay('_t46_stat', function() return nil end)
                assertTrue(ok1, 'ours sets: ' .. tostring(err1))
                assertTrue(listed('VehicleStatDisplay', '_t46_stat'), 'listed as ours')
                local ok2, err2 = exports.whip_core:ClearVehicleStatDisplay('_t46_stat')
                assertTrue(ok2, 'and we can clear it: ' .. tostring(err2))
            end,
        },
        {
            name = 'REG-1: releasing an appearance hold nobody holds is fine',
            fn = function()
                -- A vehicle id no hold names. Releasing it is true: the answer the caller wanted.
                local ok, err = exports.whip_core:HoldVehicleAppearance(999999, false)
                assertTrue(ok, 'release of nothing answers true: ' .. tostring(err))
            end,
        },
        {
            name = "SEC-5: an unknown callback answers false, 'Unknown callback'",
            fn = function()
                local result, why = exports.whip_core:Callback('_t46_no_such_callback')
                assertEqual(result, false, 'false')
                assertEqual(why, 'Unknown callback', 'and why')
            end,
        },
        {
            name = 'REG-3: the satellite helper on the client',
            fn = function()
                assertNotNil(Whip, "whip_test includes '@whip_core/lib/satellite.lua'")
                assertTrue(Whip.isReady(), "whip_core's client is ready")
                local ok, err = Whip.call('_t46_no_such_export')
                assertFalse(ok, 'a failing call answers false')
                assertNotNil(err, 'with a reason')
            end,
        },
    },
})
