-- ============================================
-- The WhipPlayer method-equivalent exports
--
-- WHY THIS MODULE EXISTS
--
-- These exports were added when GetPlayer stopped handing out a live object. FiveM copies
-- values between resources and a metatable does not survive the copy, so `player:getCash()` —
-- which the docs taught for a long time — was never going to work for a satellite. The object
-- became a serialized sheet, and every method it lost was given an export instead.
--
-- Ten exports went in. Nothing tested any of them. An API surface that exists precisely BECAUSE
-- the old one silently did not work is the last place to take "it compiles" as evidence.
--
-- CASH IS THE REASON THIS IS NEAR THE TOP OF THE LIST
--
-- Cash is not a column. It is the `cash` item counted across the player's containers, so paying
-- it (PayPlayer) and taking it (ChargePlayer) with method = 'cash' are inventory writes (they were
-- AddPlayerCash and RemovePlayerCash until 14 Nov 2026) — and they persist through
-- `Inventory.save`, the pre-stores path that fourteen call sites still use. That path had to be
-- taught about transaction groups, because adding cash to somebody who was half-way through a
-- deferred transfer would otherwise write their side of it alone and duplicate the item. So
-- these tests cover the money API and that repair at the same time.
--
-- NOTHING HERE MAY LEAVE THE TESTER RICHER OR POORER. Every balance is measured first and put
-- back, and the restores run before the assertions that could raise past them.
-- ============================================

local META_KEY = '_test_player_api'

--- Always in cash: PayPlayer and ChargePlayer would otherwise pick the method themselves ('auto').
local CASH = { method = 'cash', reason = '_test player api' }

--- PayPlayer in cash, staged only where the notes fit: full pockets drop them at the tester's feet
--- (placement 'ground'), where neither the balance nor a put-back can see them. Skipped then, as
--- the old AddPlayerCash refused.
local function payCash(source, amount)
    if not exports.whip_core:CanFitItem(source, 'cash', amount) then
        skip(('no room in the pockets for $%d — inventory full?'):format(amount))
    end
    return exports.whip_core:PayPlayer(source, amount, CASH)
end

--- Cash on DISK for this character, summed across containers. Cash can occupy several slots,
--- so a single-slot read would pass or fail on how the stack happened to land.
local function cashOnDisk(charId)
    local rows = DbQuery(
        'SELECT SUM(`amount`) AS total FROM `character_inventory` WHERE `charId` = ? AND `item` = ?',
        { charId, 'cash' })
    return (rows[1] and tonumber(rows[1].total)) or 0
end

--- The metadata JSON on disk, decoded.
local function metaOnDisk(charId)
    local rows = DbQuery('SELECT `metadata` FROM `characters` WHERE `charId` = ?', { charId })
    local raw = rows[1] and rows[1].metadata
    if type(raw) == 'string' then return json.decode(raw) or {} end
    if type(raw) == 'table' then return raw end
    return {}
end

RegisterTestModule({
    order    = 35,
    category = 'Player API',

    setup = function(source, ctx)
        local p = exports.whip_core:GetPlayer(source)
        if not p then skip('no player loaded') end
        ctx.charId    = p.charId
        ctx.startCash = exports.whip_core:GetPlayerCash(source)
    end,

    teardown = function(ctx, source)
        -- Put the balance back whatever happened above. Compared rather than assumed: a test
        -- that failed midway may have left it either side of where it started.
        if ctx and ctx.startCash and source then
            local now = exports.whip_core:GetPlayerCash(source)
            if now > ctx.startCash then
                pcall(exports.whip_core.ChargePlayer, exports.whip_core, source, now - ctx.startCash, CASH)
            elseif now < ctx.startCash then
                pcall(exports.whip_core.PayPlayer, exports.whip_core, source, ctx.startCash - now, CASH)
            end
        end
        if source then
            pcall(exports.whip_core.SetPlayerMetadata, exports.whip_core, source, META_KEY, nil)
        end
    end,

    tests = {
        -- ==========================================
        -- Cash
        -- ==========================================
        {
            name = 'GetPlayerCash counts the cash ITEM, and the sheet agrees',
            fn = function(source, ctx)
                -- Cash is not a column; it is the `cash` item counted across the pockets. Comparing
                -- the export with the sheet alone could never fail — both call player:getCash() —
                -- so the money goes in through the ITEM path here, and the balance has to follow.
                --
                -- 09-24: AddItem answers WHERE it went, 'inventory' or 'ground', or `false, reason`.
                -- Only 'inventory' is put back here: notes that went to the floor are not in the
                -- pockets, and RemoveItem would take 123 of the tester's own cash instead.
                local before = exports.whip_core:GetPlayerCash(source)
                local where, err = exports.whip_core:AddItem(source, 'cash', 123)
                local after = exports.whip_core:GetPlayerCash(source)
                local sheet = exports.whip_core:GetPlayer(source)
                if where == 'inventory' then
                    pcall(exports.whip_core.RemoveItem, exports.whip_core, source, 'cash', 123)
                end

                assertEqual(where, 'inventory', 'cash item added to the pockets: ' .. tostring(err))
                assertEqual(after, before + 123, 'GetPlayerCash counts banknotes given as an item')
                assertNotNil(sheet, 'the sheet is readable')
                assertEqual(sheet.cash, after, 'the sheet reports the same balance')
            end,
        },
        {
            name = 'PayPlayer in cash raises the balance, and it reaches disk',
            fn = function(source, ctx)
                local before = exports.whip_core:GetPlayerCash(source)

                local paid, why = payCash(source, 250)
                local after = exports.whip_core:GetPlayerCash(source)

                -- Measured, then put back, then judged — a raise below must not strand the money.
                if paid then pcall(exports.whip_core.ChargePlayer, exports.whip_core, source, 250, CASH) end

                assertType(paid, 'table', 'PayPlayer returned its result: ' .. tostring(why))
                assertEqual(paid.placement, 'inventory', 'the notes went into the pockets')
                assertEqual(after, before + 250, 'the balance rose by exactly the amount paid')
                assertEqual(exports.whip_core:GetPlayerCash(source), before,
                    'and the restore put it back')
            end,
        },
        {
            name = 'Paid cash is DURABLE — it survives to the database',
            fn = function(source, ctx)
                -- PayPlayer's cash persists through the player store, flushed immediately (it used to
                -- be Inventory.save, the pre-stores path). Asserting only the in-memory balance
                -- would pass even if that write never happened, and the money would vanish on the
                -- next restart.
                local beforeDisk = cashOnDisk(ctx.charId)

                local paid, why = payCash(source, 300)
                FlushPersistence(source)
                local afterDisk = cashOnDisk(ctx.charId)

                if paid then
                    pcall(exports.whip_core.ChargePlayer, exports.whip_core, source, 300, CASH)
                    FlushPersistence(source)
                end

                assertType(paid, 'table', 'PayPlayer returned its result: ' .. tostring(why))
                assertEqual(afterDisk, beforeDisk + 300,
                    'the database shows the paid cash, not just the cache')
                assertEqual(cashOnDisk(ctx.charId), beforeDisk,
                    'and the restore reached disk too')
            end,
        },
        {
            name = 'ChargePlayer in cash lowers the balance by exactly the amount',
            fn = function(source, ctx)
                local paid = payCash(source, 500)
                if not paid then skip('could not stage cash — inventory full?') end

                local before  = exports.whip_core:GetPlayerCash(source)
                local receipt, why = exports.whip_core:ChargePlayer(source, 200, CASH)
                local after   = exports.whip_core:GetPlayerCash(source)

                -- Whatever is left of the staged 500 goes back.
                local staged = after - (before - 500)
                if staged > 0 then
                    pcall(exports.whip_core.ChargePlayer, exports.whip_core, source, staged, CASH)
                end

                assertType(receipt, 'table', 'ChargePlayer returned a receipt: ' .. tostring(why))
                assertEqual(receipt.method, 'cash', 'taken in cash')
                assertEqual(after, before - 200, 'the balance fell by exactly the amount charged')
            end,
        },
        {
            name = 'ChargePlayer in cash REFUSES more than they hold, and takes nothing',
            fn = function(source, ctx)
                -- The half that matters. A charge that reports failure but has already taken
                -- part of the money is how a failed purchase costs the player anyway.
                local before  = exports.whip_core:GetPlayerCash(source)
                local receipt = exports.whip_core:ChargePlayer(source, before + 1000000, CASH)
                local after   = exports.whip_core:GetPlayerCash(source)

                assertFalse(receipt, 'taking more than they hold is refused')
                assertEqual(after, before, 'and the balance is untouched — refused, not partly taken')
            end,
        },
        {
            name = 'Negative amounts are refused by both cash calls; 0 moves nothing',
            fn = function(source, ctx)
                -- A negative "pay" that fell through to the charge path would be a free way to
                -- delete someone's money, and a negative "charge" a free way to mint it.
                --
                -- 0 is not refused: PayPlayer and ChargePlayer take it as "nothing to pay" and still
                -- answer (a free thing needs no special case). AddPlayerCash and RemovePlayerCash, which
                -- these replaced on 14 Nov 2026, refused it.
                local before = exports.whip_core:GetPlayerCash(source)

                local paid = exports.whip_core:PayPlayer(source, 0, CASH)
                assertType(paid, 'table', 'pay 0 answers')
                assertEqual(paid.amount, 0, 'and paid nothing')
                local receipt = exports.whip_core:ChargePlayer(source, 0, CASH)
                assertType(receipt, 'table', 'charge 0 answers')
                assertEqual(receipt.amount, 0, 'and took nothing')
                local okPay, payWhy = exports.whip_core:PayPlayer(source, -100, CASH)
                assertFalse(okPay, 'pay -100 refused')
                assertEqual(payWhy, 'Amount must be a whole number of 0 or more', 'with the amount rule')
                assertFalse(exports.whip_core:ChargePlayer(source, -100, CASH), 'charge -100 refused')

                assertEqual(exports.whip_core:GetPlayerCash(source), before,
                    'and none of the four moved the balance')
            end,
        },
        {
            name = 'Amounts that are not a whole number of notes are refused, not thrown or minted',
            fn = function(source, ctx)
                -- A satellite passes whatever it has. `amount <= 0` was the only check, so a
                -- non-numeric string THREW inside the export, NaN (which is not <= 0) became a stack
                -- of NaN banknotes, infinity an infinite one, and 0.5 floored to a zero-note success.
                local before = exports.whip_core:GetPlayerCash(source)

                for label, bad in pairs({ ['a word'] = 'abc', ['NaN'] = 0 / 0,
                                          ['infinity'] = math.huge, ['half a note'] = 0.5 }) do
                    local okP, paid = pcall(exports.whip_core.PayPlayer, exports.whip_core, source, bad, CASH)
                    assertTrue(okP, 'pay ' .. label .. ' answered rather than threw')
                    assertFalse(paid, 'pay ' .. label .. ' refused')
                    local okC, receipt = pcall(exports.whip_core.ChargePlayer, exports.whip_core, source, bad, CASH)
                    assertTrue(okC, 'charge ' .. label .. ' answered rather than threw')
                    assertFalse(receipt, 'charge ' .. label .. ' refused')
                end

                assertEqual(exports.whip_core:GetPlayerCash(source), before, 'and the balance never moved')
            end,
        },

        -- ==========================================
        -- Metadata
        -- ==========================================
        {
            name = 'SetPlayerMetadata round-trips through GetPlayerMetadata',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:SetPlayerMetadata(source, META_KEY, { n = 7, tag = 'x' }),
                    'SetPlayerMetadata reported success')

                local got = exports.whip_core:GetPlayerMetadata(source, META_KEY)
                assertNotNil(got, 'the key reads back')
                assertEqual(got.n, 7, 'the value survived intact')
                assertEqual(got.tag, 'x', 'including the nested string')
            end,
        },
        {
            name = 'GetCharId, IsPlayerLoaded, IsPlayerDead and HasExport answer from memory',
            fn = function(source)
                local sheet = exports.whip_core:GetPlayer(source)
                assertEqual(exports.whip_core:GetCharId(source), sheet.charId, 'GetCharId is the sheet\'s charId')
                assertTrue(exports.whip_core:IsPlayerLoaded(source), 'loaded')
                assertFalse(exports.whip_core:IsPlayerLoaded(65000), 'nobody: not loaded')
                assertEqual(exports.whip_core:IsPlayerDead(source), sheet.isDead == true, 'IsPlayerDead is the sheet\'s')
                assertTrue(exports.whip_core:HasExport('GetPlayer'), 'HasExport: a real one')
                assertFalse(exports.whip_core:HasExport('_no_such_export'), 'HasExport: one that is not')
            end,
        },
        {
            name = 'SetPlayerMetadata refuses whip\'s own keys and says what to call yours; the value is untouched',
            fn = function(source, ctx)
                local before = exports.whip_core:GetPlayerMetadata(source, 'mood')
                local ok, why = exports.whip_core:SetPlayerMetadata(source, 'mood', 'whip_test was here')
                assertFalse(ok, "'mood' is whip_core's own: refused")
                assertTrue(type(why) == 'string' and why:find('whip_test_mood', 1, true) ~= nil,
                    'the reason names a key of your own (got: ' .. tostring(why) .. ')')
                assertEqual(exports.whip_core:GetPlayerMetadata(source, 'mood'), before, 'whip\'s value is as it was')
                assertFalse((exports.whip_core:SetPlayerMetadata(source, 'appearance', {})), "'appearance' too")
            end,
        },
        {
            name = 'Metadata set through the export reaches the characters row',
            fn = function(source, ctx)
                -- setMetadata is the ONLY route to the database now — the sweep that used to
                -- write every player's row unconditionally is gone. A satellite assigning to
                -- the sheet it got back from GetPlayer would find its change lasts until the
                -- next restart and no further, so the export has to be the thing that persists.
                exports.whip_core:SetPlayerMetadata(source, META_KEY, { n = 42 })
                FlushPersistence(source)

                local onDisk = metaOnDisk(ctx.charId)
                assertNotNil(onDisk[META_KEY], 'the key is in the stored metadata JSON')
                assertEqual(onDisk[META_KEY].n, 42, 'with the value that was set')
            end,
        },
        {
            name = 'An unset metadata key reads nil rather than erroring',
            fn = function(source, ctx)
                assertNil(exports.whip_core:GetPlayerMetadata(source, '_test_never_set_key'),
                    'an unknown key is nil, not an empty table')
            end,
        },

        -- ==========================================
        -- Position, save, and the no-such-player contract
        -- ==========================================
        {
            name = 'GetPlayerCoords returns where the ped actually is',
            fn = function(source, ctx)
                -- The tester's ped exists, so this checks the live read, not the documented fallback
                -- to the last known position — that only runs when there is no ped, which one
                -- player online cannot arrange.
                local c = exports.whip_core:GetPlayerCoords(source)
                assertNotNil(c, 'coords returned')
                assertType(c.x, 'number', 'x is a number')
                assertType(c.y, 'number', 'y is a number')
                assertType(c.z, 'number', 'z is a number')
                local ped = GetEntityCoords(GetPlayerPed(source))
                assertTrue(#(vector3(c.x, c.y, c.z) - ped) < 5.0, 'within a few metres of the ped')
            end,
        },
        {
            name = 'SavePlayer writes the character row itself, before it returns',
            fn = function(source, ctx)
                -- A return value alone proved nothing: the flush thread writes a dirty row within a
                -- second anyway. So the database is read straight after the call, WITHOUT
                -- FlushPersistence — the value can only be there if SavePlayer put it there (or the
                -- thread happened to run inside those few milliseconds, which can make this pass
                -- early but never fail wrongly).
                local stamp = ('save-%d'):format(GetGameTimer())
                assertTrue(exports.whip_core:SetPlayerMetadata(source, META_KEY, { stamp = stamp }), 'metadata set')
                assertTrue(exports.whip_core:SavePlayer(source), 'SavePlayer reported success')

                local rows = DbQuery('SELECT `metadata` FROM `characters` WHERE `charId` = ?', { ctx.charId })
                local raw = rows[1] and rows[1].metadata
                local meta = type(raw) == 'string' and (json.decode(raw) or {}) or (raw or {})
                assertEqual(meta[META_KEY] and meta[META_KEY].stamp, stamp, 'the row holds the value just saved')
            end,
        },
        {
            name = 'Every player export answers safely for a source with no player',
            fn = function(source, ctx)
                -- A satellite calling with a stale source — someone who dropped mid-request — is
                -- ordinary, not exotic. These must answer rather than raise, and the answers are
                -- part of the contract: a nil from GetPlayerCash would arithmetic-error in the
                -- caller, so it is 0, and every mutator reports that it did nothing.
                local GONE = 99999

                assertEqual(exports.whip_core:GetPlayerCash(GONE), 0, 'cash reads 0, not nil')
                assertFalse(exports.whip_core:PayPlayer(GONE, 10, CASH), 'pay reports failure')
                assertFalse(exports.whip_core:ChargePlayer(GONE, 10, CASH), 'charge reports failure')
                assertNil(exports.whip_core:GetPlayerMetadata(GONE, META_KEY), 'metadata reads nil')
                assertFalse(exports.whip_core:SetPlayerMetadata(GONE, META_KEY, 1), 'set reports failure')
                assertNil(exports.whip_core:GetPlayerCoords(GONE), 'coords read nil')
                assertFalse(exports.whip_core:SavePlayer(GONE), 'save reports failure')
            end,
        },
    }
})
