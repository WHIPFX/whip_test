RegisterClientTestModule({
    order    = 12,
    category = 'Client: Zones',
    teardown = function()
        pcall(exports.whip_core.RemoveZoneGroup, exports.whip_core, '_test_zones')
        pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_box')
        pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_sphere')
        pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_poly')
        pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_dynamic')
        pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_cond')
        pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_rules')
        pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_nearby1')
        pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_nearby2')
        pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_detect_box')
        pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_detect_sphere')
        pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_detect_poly')
        pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_detect_poly_far')
        pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_untyped')
        pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_wx')
        pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_fall')
        pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_fall2')
        -- Removing a zone the tester is inside clears its weather layer; one left over from a
        -- failure while outside is cleared by name.
        pcall(exports.whip_core.ClearWeatherLayer, exports.whip_core, 'zone:_test_cz_wx')
    end,
    tests = {
        -- ==========================================
        -- Create: RegisterZone, the shape in its `type` (ZoneBox, ZoneSphere and ZonePoly until 14 Nov 2026)
        -- ==========================================
        {
            name = "RegisterZone { type = 'box' } creates and returns string ID",
            fn = function()
                local id = exports.whip_core:RegisterZone({
                    type = 'box', id = '_test_cz_box', pos = vector3(9999, 9999, 30),
                    size = vector3(10, 10, 5), group = '_test_zones', label = 'Test Box',
                })
                assertType(id, 'string', 'returns string')
                assertEqual(id, '_test_cz_box', 'correct ID')
            end,
        },
        {
            name = "RegisterZone { type = 'sphere' } creates the sphere it was given",
            fn = function()
                local id = exports.whip_core:RegisterZone({
                    type = 'sphere', id = '_test_cz_sphere', pos = vector3(9990, 9990, 30),
                    radius = 15.0, group = '_test_zones', label = 'Test Sphere',
                })
                assertEqual(id, '_test_cz_sphere', 'returns the given id')
                local def = exports.whip_core:GetZone(id)
                assertNotNil(def, 'the zone exists')
                assertEqual(def.type, 'sphere', 'type')
                assertEqual(def.radius, 15.0, 'radius')
            end,
        },
        {
            name = "RegisterZone { type = 'poly' } creates the polygon it was given",
            fn = function()
                local id = exports.whip_core:RegisterZone({
                    type = 'poly', id = '_test_cz_poly',
                    points = { vector2(9980, 9980), vector2(9990, 9980), vector2(9990, 9990), vector2(9980, 9990) },
                    minZ = 25, maxZ = 40, group = '_test_zones', label = 'Test Poly',
                })
                assertEqual(id, '_test_cz_poly', 'returns the given id')
                local def = exports.whip_core:GetZone(id)
                assertNotNil(def, 'the zone exists')
                assertEqual(def.type, 'poly', 'type')
                assertEqual(#def.points, 4, 'all four points')
                assertEqual(def.minZ, 25, 'minZ')
                assertEqual(def.maxZ, 40, 'maxZ')
            end,
        },
        {
            -- The shape is the table's `type`, so a zone's data without one (what ZoneBox, ZoneSphere or
            -- ZonePoly took) is the likely mistake: refused, saying the three shapes.
            name = 'RegisterZone refuses a zone with no type it knows, and makes nothing',
            fn = function()
                local id, why = exports.whip_core:RegisterZone({
                    id = '_test_cz_untyped', pos = vector3(9970, 9970, 30), radius = 2.0,
                })
                assertFalse(id, 'refused')
                assertEqual(why, "RegisterZone needs { type = 'box', pos, size }, { type = 'sphere', pos, radius } or { type = 'poly', points }",
                    'saying the shapes')
                assertNil(exports.whip_core:GetZone('_test_cz_untyped'), 'and made nothing')
            end,
        },

        -- ==========================================
        -- Query (6 exports)
        -- ==========================================
        {
            name = 'IsPointInZone: true for point inside box',
            fn = function()
                assertTrue(exports.whip_core:IsPointInZone('_test_cz_box', vector3(9999, 9999, 30)), 'inside')
            end,
        },
        {
            name = 'IsPointInZone: false for point outside',
            fn = function()
                assertFalse(exports.whip_core:IsPointInZone('_test_cz_box', vector3(0, 0, 0)), 'outside')
            end,
        },
        {
            name = 'IsPointInZone: false for invalid zone ID',
            fn = function()
                assertFalse(exports.whip_core:IsPointInZone('_nonexistent', vector3(0, 0, 0)), 'invalid')
            end,
        },
        {
            name = 'IsInZone: false when player not in zone',
            fn = function()
                assertFalse(exports.whip_core:IsInZone('_test_cz_box'), 'not inside')
            end,
        },
        {
            name = 'GetZonesInside lists only zones IsInZone agrees with',
            fn = function()
                -- The positive case (the tester's own zone appearing here) is in the sphere
                -- detection test below; this pins that the two readers of the inside set agree.
                local inside = exports.whip_core:GetZonesInside()
                assertType(inside, 'table', 'table')
                for _, id in ipairs(inside) do
                    assertTrue(exports.whip_core:IsInZone(id), ('IsInZone agrees about %s'):format(tostring(id)))
                end
                assertFalse(exports.whip_core:IsInZone('_test_cz_box'), 'the far test box is not in it')
            end,
        },
        {
            name = 'GetZone returns zone data',
            fn = function()
                local def = exports.whip_core:GetZone('_test_cz_box')
                assertNotNil(def, 'exists')
                assertEqual(def.type, 'box', 'type')
                assertEqual(def.label, 'Test Box', 'label')
                assertNotNil(def.pos, 'has pos')
                assertNotNil(def.size, 'has size')
            end,
        },
        {
            name = 'GetZone returns nil for invalid',
            fn = function()
                assertNil(exports.whip_core:GetZone('_nonexistent'), 'nil')
            end,
        },
        {
            name = 'GetZonesNearby finds zones within radius',
            fn = function()
                exports.whip_core:RegisterZone({
                    type = 'sphere', id = '_test_cz_nearby1', pos = vector3(8000, 8000, 30), radius = 5,
                })
                exports.whip_core:RegisterZone({
                    type = 'sphere', id = '_test_cz_nearby2', pos = vector3(8010, 8000, 30), radius = 5,
                })
                local nearby = exports.whip_core:GetZonesNearby(vector3(8005, 8000, 30), 20)
                assertType(nearby, 'table', 'table')
                assertGte(#nearby, 2, 'found both')
                -- Should be sorted by distance
                assertTrue(nearby[1].dist <= nearby[2].dist, 'sorted by distance')
            end,
        },
        {
            name = 'GetZonesNearby returns empty for far point',
            fn = function()
                local nearby = exports.whip_core:GetZonesNearby(vector3(-9999, -9999, 30), 10)
                assertEqual(#nearby, 0, 'empty')
            end,
        },

        -- ==========================================
        -- Modify: UpdateZone, one patch of keys (a setter each until 14 Nov 2026)
        -- ==========================================
        {
            name = 'UpdateZone { pos } moves zone',
            fn = function()
                local id = exports.whip_core:RegisterZone({
                    type = 'sphere', id = '_test_cz_dynamic', pos = vector3(9950, 9950, 30), radius = 5.0,
                })
                assertFalse(exports.whip_core:IsPointInZone(id, vector3(100, 100, 30)), 'outside before')
                exports.whip_core:UpdateZone(id, { pos = vector3(100, 100, 30) })
                assertTrue(exports.whip_core:IsPointInZone(id, vector3(100, 100, 30)), 'inside after')
            end,
        },
        {
            name = 'UpdateZone { size } resizes zone',
            fn = function()
                -- Sphere at (100,100,30) radius 5 — point at 108 should be outside
                assertFalse(exports.whip_core:IsPointInZone('_test_cz_dynamic', vector3(108, 100, 30)), 'outside before resize')
                -- Resize to radius 20
                exports.whip_core:UpdateZone('_test_cz_dynamic', { size = vector3(20, 0, 0) })
                assertTrue(exports.whip_core:IsPointInZone('_test_cz_dynamic', vector3(108, 100, 30)), 'inside after resize')
            end,
        },
        {
            name = 'UpdateZone { condition } attaches and clears the gate',
            fn = function()
                -- The old name was "updates without error", and that was the honest description
                -- of a test whose body ended in "-- Verify no crash". A condition gates the
                -- enter/exit events inside the poll loop, and nothing exposed whether one was
                -- attached — so GetZone now reports `hasCondition` and the claim is checkable.
                exports.whip_core:RegisterZone({
                    type = 'sphere', id = '_test_cz_cond', pos = vector3(9940, 9940, 30), radius = 5.0,
                })

                local def = exports.whip_core:GetZone('_test_cz_cond')
                assertNotNil(def, 'the zone exists')
                assertFalse(def.hasCondition, 'a new zone carries no condition')

                exports.whip_core:UpdateZone('_test_cz_cond', { condition = function() return false end })
                assertTrue(exports.whip_core:GetZone('_test_cz_cond').hasCondition,
                    'the condition is attached')

                -- IsPointInZone is GEOMETRY and must stay that way: a caller asking "is this
                -- point in the box" is not asking "would the player be allowed in today".
                -- Pinned here because the two are easy to conflate once conditions exist.
                assertTrue(exports.whip_core:IsPointInZone('_test_cz_cond', vector3(9940, 9940, 30)),
                    'a false condition does NOT change what the zone geometrically contains')

                -- false, not nil: a nil in the patch is no key at all.
                exports.whip_core:UpdateZone('_test_cz_cond', { condition = false })
                assertFalse(exports.whip_core:GetZone('_test_cz_cond').hasCondition,
                    'passing false clears it again')
            end,
        },
        {
            name = 'UpdateZone { debug } toggles without error',
            fn = function()
                exports.whip_core:UpdateZone('_test_cz_box', { debug = true })
                local def = exports.whip_core:GetZone('_test_cz_box')
                assertTrue(def.debug, 'debug on')
                exports.whip_core:UpdateZone('_test_cz_box', { debug = false })
                def = exports.whip_core:GetZone('_test_cz_box')
                assertFalse(def.debug, 'debug off')
            end,
        },
        {
            name = 'UpdateZone { label } changes label',
            fn = function()
                exports.whip_core:UpdateZone('_test_cz_box', { label = 'Renamed Box' })
                local def = exports.whip_core:GetZone('_test_cz_box')
                assertEqual(def.label, 'Renamed Box', 'label changed')
            end,
        },
        {
            name = 'UpdateZone { priority } changes priority',
            fn = function()
                exports.whip_core:UpdateZone('_test_cz_box', { priority = 42 })
                local def = exports.whip_core:GetZone('_test_cz_box')
                assertEqual(def.priority, 42, 'priority changed')
            end,
        },
        {
            name = 'UpdateZone { notify } changes notify flag',
            fn = function()
                exports.whip_core:UpdateZone('_test_cz_box', { notify = true })
                local def = exports.whip_core:GetZone('_test_cz_box')
                assertTrue(def.notify, 'notify on')
                exports.whip_core:UpdateZone('_test_cz_box', { notify = false })
            end,
        },
        {
            name = 'UpdateZone { rules } applies rules table',
            fn = function()
                exports.whip_core:RegisterZone({
                    type = 'sphere', id = '_test_cz_rules', pos = vector3(9920, 9920, 30), radius = 5.0,
                })
                exports.whip_core:UpdateZone('_test_cz_rules', { rules = { noWeapons = true, noPvP = true } })
                local def = exports.whip_core:GetZone('_test_cz_rules')
                assertNotNil(def.rules, 'rules exist')
                assertTrue(def.rules.noWeapons, 'noWeapons')
                assertTrue(def.rules.noPvP, 'noPvP')
            end,
        },

        {
            -- Every key is checked before any is applied, so a patch with one bad key changes nothing.
            name = 'UpdateZone refuses a key it does not know, and applies none of the patch',
            fn = function()
                local before = exports.whip_core:GetZone('_test_cz_box').label
                local ok, why = exports.whip_core:UpdateZone('_test_cz_box', { label = '_test never', colour = 'red' })
                assertFalse(ok, 'refused')
                assertEqual(why, 'UpdateZone: no key "colour" (pos, size, condition, debug, trackVehicles, label, priority, notify, rules)',
                    'naming the key')
                assertEqual(exports.whip_core:GetZone('_test_cz_box').label, before, 'and the label beside it was not applied')
            end,
        },

        -- ==========================================
        -- Control: a rule flipped is a new rules table (ZoneToggleRule went on 14 Nov 2026)
        -- ==========================================
        {
            name = 'UpdateZone { rules } with one rule flipped turns it off and on; false takes the rules off',
            fn = function()
                exports.whip_core:UpdateZone('_test_cz_rules', { rules = { noWeapons = false, noPvP = true } })
                local def = exports.whip_core:GetZone('_test_cz_rules')
                assertFalse(def.rules.noWeapons, 'toggled off')
                assertTrue(def.rules.noPvP, 'the other rule kept')
                exports.whip_core:UpdateZone('_test_cz_rules', { rules = { noWeapons = true, noPvP = true } })
                def = exports.whip_core:GetZone('_test_cz_rules')
                assertTrue(def.rules.noWeapons, 'toggled back on')
                assertTrue(exports.whip_core:UpdateZone('_test_cz_rules', { rules = false }), 'the rules taken off')
                assertNil(exports.whip_core:GetZone('_test_cz_rules').rules, 'and none are left')
            end,
        },

        -- ==========================================
        -- Live Detection
        -- ==========================================
        --
        -- THE ZONE MOVES, NOT THE PLAYER. These used to teleport the tester 50-100m sideways at the
        -- same height with nothing frozen — into a wall, off a roof, into the sea — and then wait a
        -- fixed 500ms against a 300ms poll (Config.ZonePollInterval). Moving the zone with
        -- UpdateZone { pos } exercises the same containment test against the same live position,
        -- and nobody falls. Each wait polls instead, with room for several passes.
        {
            name = 'Box zone detects player inside, and outside once it moves away',
            fn = function()
                local startPos = GetEntityCoords(PlayerPedId())
                local id = exports.whip_core:RegisterZone({
                    type = 'box', id = '_test_cz_detect_box',
                    pos = startPos,
                    size = vector3(10, 10, 5),
                    debug = true,
                })
                assertTrue(waitFor(function() return exports.whip_core:IsInZone(id) end, 2000) == true,
                    'player inside box')

                exports.whip_core:UpdateZone(id, { pos = startPos + vector3(100.0, 0.0, 0.0) })
                assertTrue(waitFor(function() return not exports.whip_core:IsInZone(id) end, 2000) == true,
                    'player outside box once it moved away')

                exports.whip_core:UpdateZone(id, { pos = startPos })
                assertTrue(waitFor(function() return exports.whip_core:IsInZone(id) end, 2000) == true,
                    'player inside box again once it came back')

                exports.whip_core:RemoveZone(id)
            end,
        },
        {
            name = 'Sphere zone detects player inside, and GetZonesInside lists it',
            fn = function()
                local startPos = GetEntityCoords(PlayerPedId())
                local id = exports.whip_core:RegisterZone({
                    type = 'sphere', id = '_test_cz_detect_sphere',
                    pos = startPos,
                    radius = 10.0,
                    debug = true,
                })
                assertTrue(waitFor(function() return exports.whip_core:IsInZone(id) end, 2000) == true,
                    'player inside sphere')

                local listed = false
                for _, zid in ipairs(exports.whip_core:GetZonesInside()) do
                    if zid == id then listed = true end
                end
                assertTrue(listed, 'GetZonesInside lists the zone the player is in')
                assertTrue(exports.whip_core:GetZone(id).inside, 'and GetZone says so too')

                exports.whip_core:UpdateZone(id, { pos = startPos + vector3(50.0, 0.0, 0.0) })
                assertTrue(waitFor(function() return not exports.whip_core:IsInZone(id) end, 2000) == true,
                    'player outside sphere once it moved away')

                exports.whip_core:UpdateZone(id, { pos = startPos })
                assertTrue(waitFor(function() return exports.whip_core:IsInZone(id) end, 2000) == true,
                    'player inside sphere again once it came back')

                exports.whip_core:RemoveZone(id)
                assertFalse(exports.whip_core:IsInZone(id), 'removing the zone takes it out of the inside set at once')
            end,
        },
        {
            name = 'Poly zone detects player inside one polygon and outside another',
            fn = function()
                -- A poly cannot be MOVED: UpdateZone { pos } changes a poly's pos but not its points,
                -- and containment reads the points (client/zones.lua, updatePosition). So instead of
                -- moving one polygon, this places two: one around the tester, one 50m off.
                local startPos = GetEntityCoords(PlayerPedId())
                local function square(cx, cy)
                    return {
                        vector2(cx - 10, cy - 10), vector2(cx + 10, cy - 10),
                        vector2(cx + 10, cy + 10), vector2(cx - 10, cy + 10),
                    }
                end

                local id = exports.whip_core:RegisterZone({
                    type = 'poly', id = '_test_cz_detect_poly',
                    points = square(startPos.x, startPos.y),
                    minZ = startPos.z - 5,
                    maxZ = startPos.z + 5,
                    debug = true,
                })
                local far = exports.whip_core:RegisterZone({
                    type = 'poly', id = '_test_cz_detect_poly_far',
                    points = square(startPos.x + 50, startPos.y),
                    minZ = startPos.z - 5,
                    maxZ = startPos.z + 5,
                })
                assertTrue(waitFor(function() return exports.whip_core:IsInZone(id) end, 2000) == true,
                    'player inside the polygon drawn around them')
                -- By now at least one full pass has run with both zones in range.
                assertFalse(exports.whip_core:IsInZone(far), 'and not inside the one 50m away')

                exports.whip_core:RemoveZone(id)
                exports.whip_core:RemoveZone(far)
            end,
        },

        -- ==========================================
        -- Enter and exit EDGES (what a zone DOES)
        -- ==========================================
        {
            name = 'Entering a zone applies its effect, leaving undoes it, and removing it undoes it',
            fn = function()
                -- The detection tests above only ask "am I in it", and that kept working through
                -- the bug that killed every enter and exit edge (the insideZones aliasing,
                -- client/zones.lua). What a zone DOES happens on the edges: onEnter/onExit, rules,
                -- notify, zone weather. Two of those are readable from here with certainty — the
                -- zone's own callbacks, and the weather layer named after it.
                --
                -- NOT a rule test. Most rules act through natives whose read-back is not certain to
                -- reflect the write (noPvP's SetEntityInvincible). noFallDamage is the exception since
                -- INT-7 — it sets the collision proof, which reads back — and has its own test below.
                local startPos = GetEntityCoords(PlayerPedId())
                local layer = 'zone:_test_cz_wx'
                local entered, exited = 0, 0
                local function weatherOwner()
                    return exports.whip_core:GetWeatherLayers().owners.weather
                end

                exports.whip_core:RegisterZone({
                    type = 'sphere', id = '_test_cz_wx', pos = startPos, radius = 10.0,
                    priority = 800,   -- layer priority 810: above anything whip itself stacks
                    weather = 'THUNDER',
                    onEnter = function() entered = entered + 1 end,
                    onExit  = function() exited = exited + 1 end,
                })

                assertTrue(waitFor(function() return entered == 1 end, 2000) == true, 'onEnter fired once on entry')
                assertEqual(weatherOwner(), layer, 'entering applied the zone\'s weather layer')
                assertEqual(exports.whip_core:GetWeather(), 'THUNDER', 'and it is the weather now')

                exports.whip_core:UpdateZone('_test_cz_wx', { pos = startPos + vector3(60.0, 0.0, 0.0) })
                assertTrue(waitFor(function() return exited == 1 end, 2000) == true, 'onExit fired once on leaving')
                assertNotEqual(weatherOwner(), layer, 'leaving took the weather layer off')

                exports.whip_core:UpdateZone('_test_cz_wx', { pos = startPos })
                assertTrue(waitFor(function() return entered == 2 end, 2000) == true, 'onEnter fired again on re-entry')
                assertEqual(weatherOwner(), layer, 'and the weather came back with it')

                -- Removal while inside is the path that used to undo nothing.
                exports.whip_core:RemoveZone('_test_cz_wx')
                assertEqual(exited, 2, 'removing the zone while inside fires onExit')
                assertNotEqual(weatherOwner(), layer, 'and takes the weather layer off')
            end,
        },
        {
            name = 'noFallDamage: collision-proof inside (no other proof touched); off on leaving, unless another zone has it',
            fn = function()
                -- INT-7 (25 Sep 2026). The rule set ped config flag 32 — WillFlyThroughWindscreen —
                -- which does nothing for a fall. It now sets the collision proof (fall damage is
                -- collision damage), and flips only that one, so it can be read back here.
                local function proofs()
                    local function yes(v) return v == true or v == 1 end
                    local _, bullet, fire, explosion, collision, melee, steam, p7, drown = GetEntityProofs(PlayerPedId())
                    return { bullet = yes(bullet), fire = yes(fire), explosion = yes(explosion), collision = yes(collision),
                             melee = yes(melee), steam = yes(steam), p7 = yes(p7), drown = yes(drown) }
                end
                local before = proofs()
                if before.collision then skip('the ped is already collision-proof (downed, or in a zone with the rule)') end
                local startPos = GetEntityCoords(PlayerPedId())

                -- Under pcall so both zones go whatever happens; a failure is raised again after.
                local ok, err = pcall(function()
                    exports.whip_core:RegisterZone({ type = 'sphere', id = '_test_cz_fall', pos = startPos, radius = 10.0,
                                                   rules = { noFallDamage = true } })
                    assertTrue(waitFor(function() return proofs().collision end, 3000) == true,
                        'inside, the ped is collision-proof')
                    local during = proofs()
                    for _, k in ipairs({ 'bullet', 'fire', 'explosion', 'melee', 'steam', 'p7', 'drown' }) do
                        assertEqual(during[k], before[k], 'the ' .. k .. ' proof is left as it was')
                    end

                    -- A second zone with the same rule: leaving the first must not take the proof off.
                    exports.whip_core:RegisterZone({ type = 'sphere', id = '_test_cz_fall2', pos = startPos, radius = 10.0,
                                                   rules = { noFallDamage = true } })
                    assertTrue(waitFor(function() return exports.whip_core:IsInZone('_test_cz_fall2') end, 2000) == true,
                        'inside the second zone too')
                    exports.whip_core:UpdateZone('_test_cz_fall', { pos = startPos + vector3(60.0, 0.0, 0.0) })
                    assertTrue(waitFor(function() return not exports.whip_core:IsInZone('_test_cz_fall') end, 2000) == true,
                        'left the first zone')
                    Wait(500)
                    assertTrue(proofs().collision, 'still collision-proof: the zone still around has the rule')

                    exports.whip_core:RemoveZone('_test_cz_fall2')
                    assertTrue(waitFor(function() return not proofs().collision end, 3000) == true,
                        'out of both, the proof is off again')
                end)
                pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_fall')
                pcall(exports.whip_core.RemoveZone, exports.whip_core, '_test_cz_fall2')
                if not ok then error(err, 0) end
            end,
        },

        -- ==========================================
        -- Remove (2 exports)
        -- ==========================================
        {
            name = 'RemoveZone removes zone',
            fn = function()
                local id = exports.whip_core:RegisterZone({
                    type = 'sphere', pos = vector3(9910, 9910, 30), radius = 3.0,
                })
                assertTrue(exports.whip_core:IsPointInZone(id, vector3(9910, 9910, 30)), 'exists')
                exports.whip_core:RemoveZone(id)
                assertFalse(exports.whip_core:IsPointInZone(id, vector3(9910, 9910, 30)), 'removed')
            end,
        },
        {
            name = 'RemoveZoneGroup removes all in group',
            fn = function()
                exports.whip_core:RemoveZoneGroup('_test_zones')
                -- Test zones should be gone
                assertNil(exports.whip_core:GetZone('_test_cz_box'), 'box gone')
                assertNil(exports.whip_core:GetZone('_test_cz_sphere'), 'sphere gone')
                assertNil(exports.whip_core:GetZone('_test_cz_poly'), 'poly gone')
            end,
        },
    }
})
