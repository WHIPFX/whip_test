-- ============================================
-- Voice Items — the voice system's megaphone and radio, as whip knows them
-- ============================================
--
-- The keys belong to "the voice system" (whip_voice/server/items.lua, whip_voice_simple/server/items.lua):
-- whichever voice system runs registers them the same, so these checks hold for either. What they DO is
-- tested in the player's game ('Client: Voice') and by whip_voice's own harnesses.
--
-- WHICH ONE RUNS is whip_core's answer (GetVoiceSystem, 13 Oct 2026): whip_voice or whip_voice_simple.

--- The voice resource running, or a skip.
local function voiceRes()
    local v = exports.whip_core:GetVoiceSystem()
    if type(v) ~= 'table' or GetResourceState(v.resource) ~= 'started' then
        skip('needs a voice system running (whip_voice or whip_voice_simple)')
    end
    return v.resource
end

RegisterTestModule({
    order    = 70,
    category = 'Voice Items',
    tests = {
        {
            name = 'One voice system is running, and says what it can do',
            fn = function()
                local res = voiceRes()
                local v = exports.whip_core:GetVoiceSystem()
                assertTrue(res == 'whip_voice' or res == 'whip_voice_simple', 'it is one of whip\'s: ' .. tostring(res))
                assertType(v.features, 'table', 'its features')
                assertTrue(v.features.lines == true, 'it carries voice lines (whip_phone\'s calls)')
                assertTrue(v.features.sounds == 'full' or v.features.sounds == 'basic', 'sounds is full or basic')
            end,
        },
        {
            name = 'The megaphone is a usable, single tool that drops as a megaphone',
            fn = function()
                voiceRes()
                local def = exports.whip_core:GetItemDef('megaphone')
                assertNotNil(def, 'megaphone is registered')
                assertEqual(def.name, 'Megaphone', 'its name')
                assertTrue(def.usable == true, 'usable (the use holds it up and puts it down)')
                assertTrue(def.stack == false, 'one to a slot')
                assertEqual(def.prop, 'prop_megaphone_01', 'what it looks like on the ground')
            end,
        },
        {
            name = 'The radio is a usable, single tool that drops as a walkie-talkie',
            fn = function()
                voiceRes()
                local def = exports.whip_core:GetItemDef('radio')
                assertNotNil(def, 'radio is registered')
                assertEqual(def.name, 'Radio', 'its name')
                assertTrue(def.usable == true, 'usable (the use opens the radio)')
                assertTrue(def.stack == false, 'one to a slot')
                assertEqual(def.prop, 'prop_cs_walkie_talkie', 'what it looks like on the ground')
            end,
        },
        {
            name = 'The items\' pictures and the megaphone model are in the voice resource',
            fn = function()
                local res = voiceRes()
                -- whip finds a picture named after the item in the resource that registered it.
                assertNotNil(LoadResourceFile(res, 'html/img/items/radio.png'), 'html/img/items/radio.png')
                assertNotNil(LoadResourceFile(res, 'html/img/items/megaphone.png'), 'html/img/items/megaphone.png')
                assertNotNil(LoadResourceFile(res, 'stream/prop_megaphone_01.ydr'), 'stream/prop_megaphone_01.ydr (the megaphone in the hand)')
            end,
        },
        {
            name = 'Every file the 3D radio loads is on the server and sent to players (whip_voice)',
            fn = function()
                if voiceRes() ~= 'whip_voice' then skip('only whip_voice has the 3D radio') end
                -- A file missing from the manifest's files {} 404s inside the page: the radio would
                -- not come up. These are the ones html/index.html and js/walkie.js load.
                local listed = {}
                for i = 0, GetNumResourceMetadata('whip_voice', 'file') - 1 do
                    listed[GetResourceMetadata('whip_voice', 'file', i)] = true
                end
                for _, f in ipairs({
                    'html/index.html', 'html/js/walkie.js', 'html/radio3d/radio.js', 'html/radio3d/lcd.js',
                    'html/radio3d/radio.glb', 'html/radio3d/lib/build/three.module.min.js',
                    'html/radio3d/lib/examples/jsm/controls/OrbitControls.js',
                    'html/radio3d/lib/examples/jsm/environments/RoomEnvironment.js',
                    'html/radio3d/lib/examples/jsm/loaders/GLTFLoader.js',
                    'html/radio3d/lib/examples/jsm/utils/BufferGeometryUtils.js',
                }) do
                    assertTrue(listed[f] == true, f .. ' is in the manifest\'s files')
                    assertNotNil(LoadResourceFile('whip_voice', f), f .. ' is there')
                end
            end,
        },
    },
})
