-- ============================================
-- Appearance sanitizer — the saveAppearance shape contract
--
-- WHY THIS MODULE EXISTS
--
-- saveAppearance used to take `'any'` plus a byte cap, so whatever a modified
-- client sent became characters.metadata.appearance forever. The sanitizer
-- (server/events_misc.lua, exported as SanitizeAppearance) now stands between
-- the wire and the row: structural wrongness rejects, out-of-range values
-- clamp, unknown keys vanish. These tests pin that contract — especially the
-- SHAPE guarantees the client apply path depends on: string-keyed
-- components/props and a dense 20-float faceFeatures array.
-- ============================================

local function canonical()
    local overlays = {}
    for _, name in ipairs({ 'blemishes', 'ageing', 'complexion', 'sunDamage', 'moles' }) do
        overlays[name] = { type = 1, opacity = 0.5 }
    end
    for _, name in ipairs({ 'beard', 'eyebrows', 'chestHair', 'makeup', 'blush', 'lipstick' }) do
        overlays[name] = { type = 2, opacity = 0.8, color = 3, color2 = 4 }
    end

    local ff = {}
    for i = 1, 20 do ff[i] = 0.25 end

    local components = {}
    for i = 0, 11 do components[tostring(i)] = { drawable = 1, texture = 1 } end

    return {
        model = 'mp_m_freemode_01',
        headBlend = { mom = 21, dad = 4, grandparent = 0, faceWeight = 0.5, skinWeight = 0.5, thirdWeight = 0.0 },
        faceFeatures = ff,
        eyeColor = 3,
        hair = { style = 5, texture = 1, color = 10, highlight = 2 },
        overlays = overlays,
        components = components,
        props = {
            ['0'] = { drawable = 2, texture = 0 }, ['1'] = { drawable = -1, texture = 0 },
            ['2'] = { drawable = -1, texture = 0 }, ['6'] = { drawable = 0, texture = 1 },
            ['7'] = { drawable = -1, texture = 0 },
        },
    }
end

RegisterTestModule({
    order    = 33,
    category = 'Appearance',

    tests = {
        {
            name = 'The canonical shape passes through intact',
            fn = function()
                -- BOOLEAN FIRST, since 19 Sep 2026. The export used to answer (table|nil, err),
                -- and the err never arrived: FiveM truncates a cross-resource return that leads
                -- with nil, so a rejection was indistinguishable from no answer. It now answers
                -- (ok, resultOrReason) — see the wrapper in whip_core/server/events_misc.lua.
                local a = canonical()
                local ok, out = exports.whip_core:SanitizeAppearance(a)
                assertTrue(ok, 'the canonical shape is accepted')
                assertNotNil(out, 'sanitized table returned')
                assertEqual(out.model, 'mp_m_freemode_01', 'model survives')
                assertEqual(out.headBlend.mom, 21, 'headBlend ids survive')
                assertEqual(out.eyeColor, 3, 'eyeColor survives')
                assertEqual(out.hair.style, 5, 'hair survives')
                assertEqual(#out.faceFeatures, 20, 'faceFeatures stays dense 20')
                assertEqual(out.components['11'].drawable, 1, 'components keep STRING keys')
                assertEqual(out.props['1'].drawable, -1, 'props keep -1 (none)')
                assertEqual(out.overlays.beard.color, 3, 'colored overlay keeps color')
                assertNil(out.overlays.blemishes.color, 'plain overlay gains no color field')
            end,
        },
        {
            name = 'Structural wrongness rejects, and the reasons name the field',
            fn = function()
                -- `ok` is false and the SECOND return carries the reason. Asserting the reason is
                -- the whole point of this test: a validator that refuses without saying why sends
                -- whoever called it looking at the wrong field.
                --
                -- THE EXACT REASON, not just "a reason". The export substitutes 'invalid appearance'
                -- when the validator gives none, so asserting non-nil passed even for a validator that
                -- had lost every one of its messages.
                local function rejects(a, reason, label)
                    local ok, why = exports.whip_core:SanitizeAppearance(a)
                    assertFalse(ok, label .. ' rejected')
                    assertEqual(why, reason, label .. ': the reason names the field')
                end

                rejects('not a table', 'not a table', 'non-table')

                local a = canonical()
                a.model = 'player_zero'
                rejects(a, 'bad model', 'non-freemode model')

                a = canonical()
                a.headBlend = nil
                rejects(a, 'missing headBlend', 'missing headBlend')

                a = canonical()
                a.faceFeatures[20] = nil
                rejects(a, 'faceFeatures must be 20 entries', '19-entry faceFeatures')

                a = canonical()
                a.faceFeatures[7] = 'wide'
                rejects(a, 'faceFeatures must be numbers', 'non-numeric face feature')

                a = canonical()
                a.hair = 'bald'
                rejects(a, 'missing hair', 'non-table hair')

                a = canonical()
                a.overlays = nil
                rejects(a, 'missing overlays', 'missing overlays')

                a = canonical()
                a.components = nil
                rejects(a, 'missing components', 'missing components')

                a = canonical()
                a.props = nil
                rejects(a, 'missing props', 'missing props')
            end,
        },
        {
            -- (This used to end by asserting the caller's table was not mutated. It could not fail:
            -- everything crossing an export is a copy, so the sanitizer never sees the caller's
            -- table at all. The no-mutation rule is still whip_core's — see sanitizeAppearance —
            -- but only an in-process caller can observe it.)
            name = 'Out-of-range values clamp; unknown keys vanish',
            fn = function()
                local a = canonical()
                a.headBlend.mom = 999
                a.headBlend.faceWeight = 3.5
                a.faceFeatures[1] = -7.0
                a.eyeColor = 99
                a.hair.color = 200
                a.props['0'].drawable = -5
                a.hair.style = 0 / 0   -- NaN: sails through math.min/max, then breaks json.encode
                a.totallyNotAppearance = { evil = true }
                a.overlays.warpaint = { type = 1, opacity = 1.0 }

                local ok, out = exports.whip_core:SanitizeAppearance(a)
                assertTrue(ok, 'clamping never rejects')
                assertEqual(out.headBlend.mom, 45, 'parent id clamps to 45')
                assertEqual(out.headBlend.faceWeight, 1.0, 'blend weight clamps to 1.0')
                assertEqual(out.faceFeatures[1], -1.0, 'face feature clamps to -1')
                assertEqual(out.eyeColor, 31, 'eyeColor clamps to 31')
                assertEqual(out.hair.color, 63, 'hair color clamps to 63')
                assertEqual(out.props['0'].drawable, -1, 'prop drawable floor is -1')
                assertEqual(out.hair.style, 0, 'a NaN falls back to the default')
                assertNil(out.totallyNotAppearance, 'unknown top-level key dropped')
                assertNil(out.overlays.warpaint, 'unknown overlay dropped')
            end,
        },
        {
            -- Tattoos (7 Oct 2026): names, so the check is exact — the list is whip_core's
            -- shared/tattoo_list.lua. A wrong one is dropped, never the whole save.
            name = 'Tattoos: listed names kept, in order and the list spelling; the rest dropped',
            fn = function()
                local a = canonical()
                local ok, out = exports.whip_core:SanitizeAppearance(a)
                assertTrue(ok, 'no tattoos field is fine (saves from before tattoos)')
                assertNil(out.tattoos, 'and stores no tattoos key')

                a.tattoos = 'sleeve'
                ok, out = exports.whip_core:SanitizeAppearance(a)
                assertFalse(ok, 'tattoos that are not a list are refused')
                assertEqual(out, 'tattoos must be a list', 'the reason names the field')

                a.tattoos = {
                    { collection = 'MPBEACH_OVERLAYS', overlay = 'mp_bea_m_back_000' },           -- odd case
                    { collection = 'mpBiker_overlays', overlay = 'MP_MP_Biker_Tat_000_F' },      -- the female body's
                    { collection = 'mpBeach_overlays', overlay = 'FM_Hair_Fuzz' },               -- a hair fade
                    { collection = 'mpBiker_overlays', overlay = 'MP_Bea_M_Back_000' },          -- wrong collection
                    'junk',
                    { collection = 'multiplayer_overlays', overlay = 'FM_Tat_Award_M_003' },
                    { collection = 'mpBeach_overlays', overlay = 'MP_Bea_M_Back_000' },          -- twice
                }
                ok, out = exports.whip_core:SanitizeAppearance(a)
                assertTrue(ok, 'a wrong tattoo never refuses the save')
                assertEqual(#out.tattoos, 2, 'only the two real male tattoos are kept')
                assertEqual(out.tattoos[1].collection, 'mpBeach_overlays', "the list's spelling of the collection")
                assertEqual(out.tattoos[1].overlay, 'MP_Bea_M_Back_000', "the list's spelling of the overlay")
                assertEqual(out.tattoos[2].overlay, 'FM_Tat_Award_M_003', 'the order put on is kept')

                a.model = 'mp_f_freemode_01'
                a.tattoos = { { collection = 'mpBiker_overlays', overlay = 'MP_MP_Biker_Tat_000_F' } }
                ok, out = exports.whip_core:SanitizeAppearance(a)
                assertEqual(out.tattoos and #out.tattoos, 1, "the female body's tattoo on the female body")
            end,
        },
        {
            -- Hair fades: one at most, a name whip_core's shared/hair_fades.lua lists for the body.
            name = "Hair fade: a listed one kept in the list's spelling; another body's or an unknown one dropped",
            fn = function()
                local a = canonical()
                local ok, out = exports.whip_core:SanitizeAppearance(a)
                assertNil(out.hairFade, 'no fade: no key')

                a.hairFade = { collection = 'MULTIPLAYER_OVERLAYS', overlay = 'ng_m_hair_001' }
                ok, out = exports.whip_core:SanitizeAppearance(a)
                assertTrue(ok, 'a fade never refuses the save')
                assertEqual(out.hairFade and out.hairFade.overlay, 'NG_M_Hair_001', "the list's spelling of the overlay")
                assertEqual(out.hairFade and out.hairFade.collection, 'multiplayer_overlays', "the list's spelling of the collection")

                a.hairFade = { collection = 'multiplayer_overlays', overlay = 'NG_F_Hair_001' }
                ok, out = exports.whip_core:SanitizeAppearance(a)
                assertNil(out.hairFade, "the female body's fade is dropped on the male body")

                a.hairFade = { collection = 'mpBeach_overlays', overlay = 'MP_Bea_M_Back_000' }
                ok, out = exports.whip_core:SanitizeAppearance(a)
                assertNil(out.hairFade, 'a tattoo is not a fade')

                a.hairFade = 'buzz'
                ok, out = exports.whip_core:SanitizeAppearance(a)
                assertTrue(ok, 'a fade that is not a table is dropped, not refused')
                assertNil(out.hairFade, 'and stores no key')

                a.model = 'mp_f_freemode_01'
                a.hairFade = { collection = 'mpBeach_overlays', overlay = 'FM_Hair_Fuzz' }
                ok, out = exports.whip_core:SanitizeAppearance(a)
                assertEqual(out.hairFade and out.hairFade.overlay, 'FM_Hair_Fuzz', 'a fade for both bodies, on the female body')
            end,
        },
    },
})
