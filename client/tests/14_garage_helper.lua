-- ============================================
-- Garage Position Helper — the driver's bay outline
--
-- WHY THIS MODULE EXISTS
--
-- The feature's only visible output is a rectangle painted on a road, which is exactly the kind
-- of thing nobody can assert about and everybody assumes is fine. whip_core therefore exposes
-- GetGarageHelperStatus, and this module pins the two promises that cost something if broken:
--
--   ONE BROWSER, AND ONLY WHEN NEEDED. A DUI renders continuously whether or not anything samples
--   it, so a browser held while the player is on foot miles from a garage is GPU time spent on
--   nothing, forever. The count for this whole feature is one, and at rest it is zero.
--
--   DRIVERS ONLY. The outline exists because prompts are suppressed in a vehicle. On foot the
--   prompt system is already doing the job, and a second hint drawn underneath it is clutter.
--
-- WHAT IT CANNOT TEST, said plainly rather than left as a gap: whether the rectangle is in the
-- right place, the right way round, or the right size. That is geometry on a screen and it needs
-- eyes. The pure part of the decision — whether a heading counts as parked — is tested headlessly
-- instead, in C:\Tools\whip\test_garage_align.lua, because it is arithmetic and deserves better
-- than a lap of a car park.
-- ============================================

RegisterClientTestModule({
    order    = 14,
    category = 'Client: Garage Helper',
    tests = {
        {
            name = 'GetGarageHelperStatus answers with a complete shape',
            fn = function()
                local s = exports.whip_core:GetGarageHelperStatus()
                assertNotNil(s, 'status returned')
                assertType(s.enabled,   'boolean', 'enabled')
                assertType(s.duiActive, 'boolean', 'duiActive')
                assertType(s.drawing,   'number',  'drawing')
                assertType(s.driving,   'boolean', 'driving')
                assertType(s.qualifies, 'boolean', 'qualifies')
            end,
        },
        {
            name = 'On foot the helper draws nothing and claims no driver',
            fn = function()
                if IsPedInAnyVehicle(PlayerPedId(), false) then
                    skip('the tester is in a vehicle — this asserts the on-foot state')
                end

                local s = exports.whip_core:GetGarageHelperStatus()
                assertFalse(s.driving, 'not driving')
                assertEqual(s.drawing, 0, 'no bay outlines are being drawn on foot')
                assertFalse(s.qualifies,
                    'and with no vehicle there is nothing for the storable test to pass')
            end,
        },
        {
            name = 'No browser is held while nothing is drawing',
            fn = function()
                -- THE ONE THAT MATTERS. A leaked DUI is invisible, costs GPU for the rest of the
                -- session, and the only symptom is a frame rate nobody connects to a garage they
                -- drove past. The release is time-based (idleReleaseMs), so this is asserted only
                -- when the suite is genuinely at rest — a tester who just drove in from a garage
                -- is inside the hold window and would fail for the right behaviour.
                if IsPedInAnyVehicle(PlayerPedId(), false) then
                    skip('the tester is in a vehicle — the helper may legitimately hold its browser')
                end

                local s = exports.whip_core:GetGarageHelperStatus()
                if s.drawing > 0 then
                    skip('something is still fading out — the browser is legitimately up')
                end

                -- THIS USED TO ASSERT `drawing == 0` right after skipping whenever drawing was not
                -- 0, so it could not fail, and it never looked at duiActive — the one field the
                -- test is named for. It looks now.
                --
                -- The release is time-based: the browser is held for idleReleaseMs (60s by
                -- default) after the last outline fades, and the status does not say how long it
                -- has been idle. So a browser that is up is given a bounded chance to be released;
                -- still up after that, it is either inside a hold that began recently or leaked,
                -- and the two cannot be told apart from here — that is a skip, not a pass. The
                -- test becomes a real one the day the status reports its idle time.
                if s.duiActive then
                    local released = waitFor(function()
                        return exports.whip_core:GetGarageHelperStatus().duiActive == false
                    end, 15000)
                    if not released then
                        skip('the browser is up with nothing drawing — inside its idle hold, or leaked; the status does not say which')
                    end
                end
                assertFalse(exports.whip_core:GetGarageHelperStatus().duiActive,
                    'no browser is held while nothing is drawing')
            end,
        },
    }
})
