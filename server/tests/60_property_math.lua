-- ============================================
-- Property maths — the transform every property is built on
--
-- WHY THIS MODULE EXISTS
--
-- A property is described ONCE, relative to its interior, and every placement of that interior is
-- the same description moved and turned (whip_core/shared/property_math.lua). If that transform is
-- wrong by a sign, every sign, door and piece of furniture on the server is wrong by the same sign —
-- quietly, on every placement at once. These tests pin it: the round trip, the heading convention,
-- the door hash's sign, and containment on both kinds of shape.
--
-- The two files are read straight out of whip_core and run here: they are pure maths, so the test
-- runs the real code rather than a copy of it. Read with LoadResourceFile rather than listed in
-- this resource's manifest, so the test needs nothing but itself.
-- ============================================

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

--- whip_core's shared maths, loaded into this resource. Returns why not, if it could not be.
local function loadPropertyMath()
    for _, file in ipairs({ 'shared/shapes.lua', 'shared/property_math.lua' }) do
        local src = LoadResourceFile('whip_core', file)
        if not src then return 'could not read whip_core/' .. file end
        local chunk, err = load(src, '@whip_core/' .. file, 't')
        if not chunk then return err end
        local ok, runErr = pcall(chunk)
        if not ok then return runErr end
    end
    return nil
end

local loadError = loadPropertyMath()

-- 60 and up are the Properties rebuild's modules, kept clear of the rest of the suite's numbers.
RegisterTestModule({
    order    = 60,
    category = 'Property Math',

    tests = {
        {
            name = 'whip_core\'s shared property maths loads',
            fn = function()
                assertNil(loadError, 'loading shared/shapes.lua and shared/property_math.lua')
                assertType(PropertyMath, 'table', 'PropertyMath')
                assertType(Shapes, 'table', 'Shapes')
            end,
        },
        {
            name = 'A pack\'s unsigned door hash becomes the signed one the game answers with',
            fn = function()
                -- 2455748208 is whippy_mega_apartments' unit entry door, written unsigned in its
                -- doors.lua. GetEntityModel answers -1839219088 for the same object.
                assertEqual(PropertyMath.signedHash(2455748208), -1839219088, 'unsigned -> signed')
                assertEqual(PropertyMath.signedHash(-1839219088), -1839219088, 'signed stays signed')
                assertEqual(PropertyMath.signedHash('2455748208'), -1839219088, 'numeric string')
                assertEqual(PropertyMath.signedHash('adder'), GetHashKey('adder'), 'a name is hashed')
                assertNil(PropertyMath.signedHash(''), 'empty string refused')
            end,
        },
        {
            name = 'Local to world and back is exact at any yaw',
            fn = function()
                for _, yaw in ipairs({ 0, 90, 188.99, 270, -45 }) do
                    local place = { x = -980.12, y = -1300.44, z = 18.2, yaw = yaw }
                    local wx, wy, wz = PropertyMath.toWorld(place, 3.5, -2.25, 1.1)
                    local lx, ly, lz = PropertyMath.toLocal(place, wx, wy, wz)
                    assertTrue(near(lx, 3.5, 1e-6) and near(ly, -2.25, 1e-6) and near(lz, 1.1, 1e-6),
                        'round trip at yaw ' .. yaw)
                end
            end,
        },
        {
            name = 'A placement\'s local forward points the way GTA\'s heading does',
            fn = function()
                -- GTA heading 90 faces west. A placement at yaw 90 must carry its local +Y there,
                -- or every interior-relative heading is off by the placement's own turn.
                local wx, wy = PropertyMath.toWorld({ x = 0, y = 0, z = 0, yaw = 90 }, 0, 1, 0)
                assertTrue(near(wx, -1) and near(wy, 0), 'local +Y at yaw 90 is west')
                assertTrue(near(PropertyMath.headingToWorld({ yaw = 350 }, 20), 10), 'headings wrap')
                assertTrue(near(PropertyMath.angleDelta(359, 1), -2), 'delta across north')
            end,
        },
        {
            name = 'Boxes and polygons contain what they should, with slack where asked',
            fn = function()
                local box = Shapes.prepare({ type = 'box', pos = { x = 10, y = 10, z = 5 },
                    size = { x = 4, y = 2, z = 3 }, heading = 90 })
                assertTrue(Shapes.contains(box, 10, 11.9, 5), 'inside a turned box')
                assertFalse(Shapes.contains(box, 11.5, 10, 5), 'outside its narrow side')
                assertTrue(Shapes.contains(box, 11.2, 10, 5, 0.3), 'slack widens it')

                local l = Shapes.prepare({ type = 'poly', minZ = 0, maxZ = 3, points = {
                    { x = 0, y = 0 }, { x = 4, y = 0 }, { x = 4, y = 1 },
                    { x = 1, y = 1 }, { x = 1, y = 4 }, { x = 0, y = 4 } } })
                assertTrue(Shapes.contains(l, 0.5, 3, 1), 'inside an L')
                assertFalse(Shapes.contains(l, 3, 3, 1), 'in the L\'s notch')
                assertTrue(near(Shapes.area(l), 7), 'L area')
            end,
        },
        {
            name = 'A whole unit moves into world space together',
            fn = function()
                local w = PropertyMath.unitToWorld({ x = 100, y = 200, z = 30, yaw = 90 }, {
                    space = { { type = 'box', center = { x = 2, y = 0, z = 1.5 },
                                size = { x = 4, y = 3, z = 3 }, heading = 0 } },
                    doors = { { key = 'entry', role = 'entrance', model = 2455748208,
                                pos = { x = 0, y = 0, z = 0.1 }, heading = 90 } },
                    sign  = { pos = { x = -0.5, y = 0.4, z = 1.6 }, heading = 270 },
                })
                assertEqual(#w.shapes, 1, 'one shape')
                assertTrue(near(w.shapes[1].pos.y, 202) and near(w.shapes[1].heading, 90), 'shape moved and turned')
                assertEqual(w.doors[1].model, -1839219088, 'door model signed')
                assertTrue(near(w.doors[1].heading, 180), 'door heading turned')
                assertTrue(near(w.sign.heading, 0), 'sign heading turned')
                assertTrue(Shapes.contains(w.shapes[1], w.visit.x, w.visit.y, w.visit.z), 'visit point inside')
            end,
        },
    },
})
