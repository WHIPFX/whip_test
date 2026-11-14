-- ============================================
-- Director API — another resource's cards, and testing them (whip_core/server/director/cards_api.lua)
-- ============================================
--
-- whip_test is "another resource" here: it adds cards of its own with Whip.card (it includes
-- @whip_core/lib/satellite.lua), runs them with TestDirectorCard for the tester, and takes them away.
-- Every run is a Test run: nothing is paid, what is handed out goes back at its end, and no script
-- hears of it. Everything added is removed in teardown.

local NS = 'wtest'
local CARDS = { NS .. '.ping', NS .. '.now', NS .. '.bell', NS .. '.boom', NS .. '.hold', NS .. '.gift' }

local function cardListed(t)
    for _, c in ipairs(exports.whip_core:GetDirectorCards({ owner = GetCurrentResourceName() }) or {}) do
        if c.type == t then return c end
    end
    return nil
end

local held = {}   -- what the hold card saw: its callId and runId, for the test that answers it

--- TestDirectorCard, skipping (not failing) when the tester is in an editor Test of their own.
local function testCard(t, props, opts)
    local r, why = exports.whip_core:TestDirectorCard(t, props, opts)
    if r == false and tostring(why):find('testing in the editor', 1, true) then skip('the tester is testing in the Director editor') end
    return r, why
end

RegisterTestModule({
    order    = 74,
    category = 'Director API',
    setup = function(source, ctx)
        local p = exports.whip_core:GetPlayer(source)
        if not (p and p.charId) then skip('the tester is not on a character') end
        Whip.card(NS .. '.ping', {
            title = '[TEST] Ping', outputs = { 'pong' },
            props = { { key = 'n', kind = 'number', label = 'N', default = 1 } },
            run = function(card) return 'pong', { twice = (card.props.n or 0) * 2, test = card.test, player = card.player } end,
        })
        Whip.card(NS .. '.now', { title = '[TEST] Now', instant = true, outputs = { 'yes', 'no' },
            run = function() return 'no', { why = 'it is late' } end })
        Whip.card(NS .. '.bell', { title = '[TEST] Bell', outputs = { 'rang' }, event = { name = NS .. '.bellRang', match = 'player' } })
        Whip.card(NS .. '.boom', { title = '[TEST] Boom', outputs = { 'done' }, run = function() error('the test card blew up') end })
        Whip.card(NS .. '.hold', { title = '[TEST] Hold', outputs = { 'done' }, timeout = 20,
            run = function(card) held.callId, held.runId = card.callId, card.runId return nil end })
        Whip.card(NS .. '.gift', { title = '[TEST] Gift', outputs = { 'given' },
            run = function(card)
                local ok, why = card:give(card.player, 'food', 1)
                return 'given', { ok = ok, why = why }
            end })
        assertTrue(waitFor(function() return cardListed(NS .. '.gift') ~= nil end, 5000) ~= nil, 'the test cards reached the palette')
    end,
    teardown = function()
        for _, t in ipairs(CARDS) do pcall(Whip.removeCard, t) end
    end,
    tests = {
        {
            name = 'Whip.card: the card is in the palette as this resource\'s, with whip_core\'s two outcomes after its own',
            fn = function()
                local c = cardListed(NS .. '.ping')
                assertNotNil(c, 'listed')
                assertEqual(c.owner, GetCurrentResourceName(), 'its owner')
                assertEqual(c.outputs[1], 'pong', 'its own outcome first')
                assertEqual(c.outputs[2], 'didntWork', "then Didn't work")
                assertEqual(c.outputs[3], 'timeout', 'then Took too long')
            end,
        },
        {
            -- The plumbing under Whip.card (__RegisterDirectorCard; RegisterDirectorCard until 14 Nov 2026),
            -- called straight: a bare definition is refused, pointing at the helper.
            name = '__RegisterDirectorCard is refused unless through Whip.card, and in whip_core\'s namespaces',
            fn = function()
                local ok, why = exports.whip_core:__RegisterDirectorCard(NS .. '.raw', { title = 'Raw', outputs = { 'x' } }, function() end)
                assertFalse(ok, 'a bare definition refused')
                assertTrue(tostring(why):find('Whip.card', 1, true) ~= nil, 'saying to use Whip.card (' .. tostring(why) .. ')')
                Whip.card('scenario.mine', { title = '[TEST] Not mine', outputs = { 'x' }, run = function() return 'x' end })
                Wait(200)
                local c
                for _, d in ipairs(exports.whip_core:GetDirectorCards() or {}) do if d.type == 'scenario.mine' then c = d end end
                assertNil(c, 'a card in whip_core\'s own namespace is not added')
                pcall(Whip.removeCard, 'scenario.mine')
            end,
        },
        {
            name = 'TestDirectorCard: its real code runs, for the tester, in a Test; the outcome and data come back',
            fn = function(source)
                local r, why = testCard(NS .. '.ping', { n = 4 }, { player = source })
                assertType(r, 'table', 'an answer (' .. tostring(why) .. ')')
                assertEqual(r.outcome, 'pong', 'its outcome')
                assertEqual(r.data and r.data.twice, 8, 'its data, from its fields')
                assertEqual(r.data and r.data.test, true, 'card.test: it ran in a Test')
                assertEqual(r.data and r.data.player, source, 'for the tester')
            end,
        },
        {
            name = 'TestDirectorCard: an instant card, an event card, and a card that fails',
            fn = function(source)
                local r = testCard(NS .. '.now', nil, { player = source })
                assertTrue(type(r) == 'table' and r.outcome == 'no' and r.data and r.data.why == 'it is late', 'instant: its outcome and data')
                r = testCard(NS .. '.bell', nil, { player = source, event = { floor = 3 } })
                assertTrue(type(r) == 'table' and r.outcome == 'rang' and r.data and r.data.floor == 3, 'event: heard the payload given')
                local ok, why = testCard(NS .. '.boom', nil, { player = source })
                assertFalse(ok, 'a failure is no answer')
                assertTrue(tostring(why):find('the test card blew up', 1, true) ~= nil, 'with its own words (' .. tostring(why) .. ')')
            end,
        },
        {
            name = 'TestDirectorCard: a give is a Test\'s: it goes back when the run ends',
            fn = function(source)
                local before = exports.whip_core:GetItemCount(source, 'food') or 0
                local r = testCard(NS .. '.gift', nil, { player = source })
                assertTrue(type(r) == 'table' and r.outcome == 'given', 'it answered')
                -- (Full pockets are the tester's, not the Director's: nothing to see then.)
                if not (r.data and r.data.ok == true) then skip('the give did not go in: ' .. tostring(r.data and r.data.why)) end
                local back = waitFor(function() return (exports.whip_core:GetItemCount(source, 'food') or 0) == before end, 5000)
                assertTrue(back ~= nil, 'taken back: the tester has what they had')
            end,
        },
        {
            name = 'A test run is no script\'s: not in GetScenarioRuns, not by its id, no run events; answered later, it goes on',
            fn = function(source)
                held.callId, held.runId = nil, nil
                -- Every run scripts were told of in the window (a real one may start meanwhile): the test's
                -- must not be among them.
                local told = {}
                local function note(p) if type(p) == 'table' and type(p.run) == 'table' then told[#told + 1] = p.run.id end end
                local h1 = AddEventHandler('whip_core:run:started', note)
                local h2 = AddEventHandler('whip_core:run:ended', note)
                local result, rwhy, done = nil, nil, false
                CreateThread(function()
                    -- (In a thread: a skip from here would never reach the runner.)
                    result, rwhy = exports.whip_core:TestDirectorCard(NS .. '.hold', nil, { player = source, seconds = 25 })
                    done = true
                end)
                local got = waitFor(function() return held.callId ~= nil or done end, 5000) and held.callId
                if not got and tostring(rwhy):find('testing in the editor', 1, true) then
                    RemoveEventHandler(h1)
                    RemoveEventHandler(h2)
                    skip('the tester is testing in the Director editor')
                end
                -- Looked at while it waits, then answered; asserted once the handlers are gone.
                local byId, listed, answered, answerWhy = nil, false, nil, nil
                if got then
                    byId = exports.whip_core:GetScenarioRun(held.runId)
                    for _, v in ipairs(exports.whip_core:GetScenarioRuns() or {}) do
                        if v.id == held.runId then listed = true end
                    end
                    answered, answerWhy = Whip.answerCard(held.callId, 'done', { note = 'later' })
                end
                waitFor(function() return done end, 8000)
                Wait(100)
                RemoveEventHandler(h1)
                RemoveEventHandler(h2)
                assertTrue(got ~= nil, 'the card was at work')
                assertFalse(byId, 'GetScenarioRun does not find it')
                assertFalse(listed, 'GetScenarioRuns leaves it out')
                assertTrue(answered == true, 'Whip.answerCard took the answer (' .. tostring(answerWhy) .. ')')
                assertTrue(type(result) == 'table' and result.outcome == 'done' and result.data and result.data.note == 'later',
                    'the answer given later is its outcome (' .. tostring(rwhy) .. ')')
                for _, id in ipairs(told) do assertNotEqual(id, held.runId, 'scripts heard nothing of the test run') end
            end,
        },
        {
            name = 'TestDirectorCard refuses: another resource\'s card, nobody named, a card nobody has',
            fn = function(source)
                local ok, why = exports.whip_core:TestDirectorCard('scenario.succeed', nil, { player = source })
                assertFalse(ok, 'whip_core\'s card')
                assertTrue(tostring(why):find('test your own', 1, true) ~= nil, 'saying whose (' .. tostring(why) .. ')')
                ok, why = testCard(NS .. '.ping', nil, {})
                assertFalse(ok, 'no player')
                assertTrue(tostring(why):find('opts.player', 1, true) ~= nil, 'saying so (' .. tostring(why) .. ')')
                ok = testCard(NS .. '.nothing', nil, { player = source })
                assertFalse(ok, 'a card nobody has')
            end,
        },
        {
            name = 'Whip.removeCard: gone from the palette, and from TestDirectorCard',
            fn = function(source)
                local ok = Whip.removeCard(NS .. '.now')
                assertTrue(ok == true, 'removed')
                assertNil(cardListed(NS .. '.now'), 'not in the palette')
                local r = testCard(NS .. '.now', nil, { player = source })
                assertFalse(r, 'not testable any more')
            end,
        },
    },
})
