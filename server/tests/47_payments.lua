-- ============================================
-- Payments — ChargePlayer / RefundPlayer (MON-1)
--
-- WHY THIS MODULE EXISTS
--
-- "Take the money, do the thing, give it back if the thing failed" was written by hand five times
-- (fuel, shops, the ATM, the dealership, whip_autos) and the copies disagreed. ChargePlayer and
-- RefundPlayer are the one way now, so they carry every payment in whip — and a refund is the one
-- place whip pays money out with no permission check. The properties worth pinning:
--
--   * money moves exactly once each way, cash or bank, and a refund goes back where it came from;
--   * a receipt is checked against whip's OWN record: a forged or edited table pays nothing;
--   * a partial refund can never add up to more than was taken;
--   * a player can only pay from an account they may withdraw from.
--
-- The tester's own cash is touched, so setup records it and teardown puts it back exactly. The bank
-- side runs on a test account this module opens and closes.
-- ============================================

local COIN = '_t47_coin'   -- a currency item, as a shop trading in something other than banknotes uses

--- The tester's cash, as the export reads it.
local function cash(source) return exports.whip_core:GetPlayerCash(source) or 0 end

--- An account's balance.
local function balance(accountId)
    local acc = exports.whip_core:GetBankAccount(accountId)
    return acc and acc.balance or nil
end

RegisterTestModule({
    order    = 47,
    category = 'Payments',

    setup = function(source, ctx)
        local player = exports.whip_core:GetPlayer(source)
        ctx.charId = player.charId
        ctx.cashBefore = cash(source)

        -- Some cash to spend, whatever the tester was carrying.
        local paid, payWhy = exports.whip_core:PayPlayer(source, 100, { method = 'cash', reason = '_test payments' })
        assertEqual(paid and paid.placement, 'inventory', 'setup: $100 to spend, in the pockets (' .. tostring(payWhy) .. ')')

        local acc, err = exports.whip_core:CreateBankAccount(source, '_test_payments', { type = 'personal' })
        if not acc then error('Setup failed: ' .. tostring(err)) end
        ctx.accountId = acc.accountId
        local funded, fErr = exports.whip_core:BankSystemDeposit(acc.accountId, 1000, { reason = '_test_payments_fund' })
        if not funded then error('Setup failed to fund the account: ' .. tostring(fErr)) end

        exports.whip_core:RegisterItem(COIN, {
            name = 'Test Coin', desc = 'payments fixture', weight = 0, type = 'misc', stack = true, maxStack = 1000,
        })
    end,

    teardown = function(ctx, source)
        if source then
            -- Back to exactly what they had.
            local diff = cash(source) - (ctx.cashBefore or 0)
            if diff > 0 then
                pcall(exports.whip_core.ChargePlayer, exports.whip_core, source, diff, { method = 'cash', reason = '_test payments cleanup' })
            elseif diff < 0 then
                pcall(exports.whip_core.PayPlayer, exports.whip_core, source, -diff, { method = 'cash', reason = '_test payments cleanup' })
            end
            RemoveAllOf(source, COIN)
        end
        DisposeTestAccount(ctx.accountId)
        if ctx.otherAccountId then
            DisposeTestAccount(ctx.otherAccountId)
            pcall(DbQuery, 'DELETE FROM `bank_access` WHERE `accountId` = ?', { ctx.otherAccountId })
        end
        DisposeStranger(ctx.strangerUserId)   -- after its account: its character goes with it
    end,

    tests = {
        {
            name = 'Cash: ChargePlayer takes it once, and RefundPlayer puts it back',
            fn = function(source, ctx)
                local c0 = cash(source)
                local receipt, err = exports.whip_core:ChargePlayer(source, 30, { method = 'cash', reason = '_t47 cash' })
                assertNotNil(receipt, 'charged: ' .. tostring(err))
                assertEqual(receipt.method, 'cash', 'paid in cash')
                assertEqual(receipt.amount, 30, 'for 30')
                assertEqual(cash(source), c0 - 30, 'the cash left their pockets, once')

                assertOk(exports.whip_core:RefundPlayer(receipt))
                assertEqual(cash(source), c0, 'and came back, once')
            end,
        },
        {
            name = 'Not enough cash is refused with a reason the player can read, and takes nothing',
            fn = function(source, ctx)
                local c0 = cash(source)
                local receipt, err = exports.whip_core:ChargePlayer(source, c0 + 1000000, { method = 'cash' })
                assertFalse(receipt, 'refused')
                assertTrue(tostring(err):find('Not enough cash (have $', 1, true) == 1,
                    ('says how much they have and need (got "%s")'):format(tostring(err)))
                assertEqual(cash(source), c0, 'nothing was taken')
            end,
        },
        {
            name = 'Bank: from the account chosen, on the statement, and refunded to the same account',
            fn = function(source, ctx)
                local b0 = balance(ctx.accountId)
                local receipt, err = exports.whip_core:ChargePlayer(source, 200,
                    { method = 'bank', accountId = ctx.accountId, reason = '_t47_bank' })
                assertNotNil(receipt, 'charged: ' .. tostring(err))
                assertEqual(receipt.accountId, ctx.accountId, 'from the chosen account')
                assertEqual(balance(ctx.accountId), b0 - 200, 'the account paid')
                assertDbRowCount('SELECT 1 FROM `bank_transactions` WHERE `fromAccountId` = ? AND `message` = ?',
                    { ctx.accountId, '_t47_bank' }, 1, 'the reason is on the statement')

                assertOk(exports.whip_core:RefundPlayer(receipt))
                assertEqual(balance(ctx.accountId), b0, 'and got it back')
                assertDbRowCount('SELECT 1 FROM `bank_transactions` WHERE `toAccountId` = ? AND `message` = ?',
                    { ctx.accountId, 'Refund: _t47_bank' }, 1, 'as a refund row')
            end,
        },
        {
            name = 'Partial refunds add up to what was taken, and never to more',
            fn = function(source, ctx)
                local b0 = balance(ctx.accountId)
                local receipt = exports.whip_core:ChargePlayer(source, 100, { method = 'bank', accountId = ctx.accountId })
                assertNotNil(receipt, 'charged')

                assertOk(exports.whip_core:RefundPlayer(receipt, 30))
                local over, overErr = exports.whip_core:RefundPlayer(receipt, 80)
                assertFalse(over, 'more than is left is refused')
                assertEqual(overErr, 'Only $70 of that payment is left to refund', 'and says how much is left')
                assertOk(exports.whip_core:RefundPlayer(receipt))   -- the other 70
                assertEqual(balance(ctx.accountId), b0, 'exactly what was taken came back')

                assertOk(exports.whip_core:RefundPlayer(receipt))   -- nothing left: answers true, moves nothing
                assertEqual(balance(ctx.accountId), b0, 'a spent receipt moves nothing more')
            end,
        },
        {
            -- The one path in whip that pays out with no permission check, so it must not trust the
            -- caller's table: a receipt is only a pointer to whip's own record.
            name = 'A forged or edited receipt pays nothing it should not',
            fn = function(source, ctx)
                local b0 = balance(ctx.accountId)
                local ok = exports.whip_core:RefundPlayer({ id = 999999999, method = 'bank',
                    accountId = ctx.accountId, amount = 1000000000 })
                assertFalse(ok, 'a receipt whip never issued is refused')
                assertEqual(balance(ctx.accountId), b0, 'and paid nothing')

                local c0 = cash(source)
                local receipt = exports.whip_core:ChargePlayer(source, 5, { method = 'cash' })
                assertNotNil(receipt, 'charged $5')
                receipt.amount = 1000000     -- edited by the caller
                local big, bigErr = exports.whip_core:RefundPlayer(receipt, 1000)
                assertFalse(big, 'the edited amount means nothing')
                assertEqual(bigErr, 'Only $5 of that payment is left to refund', 'whip\'s record decides')
                assertOk(exports.whip_core:RefundPlayer(receipt))
                assertEqual(cash(source), c0, 'and only the real $5 came back')
            end,
        },
        {
            name = "'auto' takes cash when they carry enough, and the bank when they do not",
            fn = function(source, ctx)
                local r1 = exports.whip_core:ChargePlayer(source, 10, { method = 'auto', accountId = ctx.accountId })
                assertEqual(r1 and r1.method, 'cash', 'enough cash: cash')
                assertOk(exports.whip_core:RefundPlayer(r1))

                -- More than they carry, with the account topped up to cover it.
                local need = cash(source) + 50
                assertOk(exports.whip_core:BankSystemDeposit(ctx.accountId, need, { reason = '_t47 auto topup' }))
                local b0 = balance(ctx.accountId)
                local r2, err = exports.whip_core:ChargePlayer(source, need, { method = 'auto', accountId = ctx.accountId })
                assertEqual(r2 and r2.method, 'bank', 'not enough cash: the bank (' .. tostring(err) .. ')')
                assertEqual(balance(ctx.accountId), b0 - need, 'paid from the account')
                assertOk(exports.whip_core:RefundPlayer(r2))
            end,
        },
        {
            name = 'A currency item is charged, and refunded, in that item',
            fn = function(source, ctx)
                RemoveAllOf(source, COIN)
                assertTrue(exports.whip_core:AddItem(source, COIN, 10, nil, '_t47 coins') ~= false, 'ten coins')

                local receipt, err = exports.whip_core:ChargePlayer(source, 4, { method = 'cash', currency = COIN })
                assertNotNil(receipt, 'charged in coins: ' .. tostring(err))
                assertEqual(receipt.currency, COIN, 'the receipt says which item')
                assertEqual(exports.whip_core:GetItemCount(source, COIN), 6, 'four coins taken')

                assertOk(exports.whip_core:RefundPlayer(receipt))
                assertEqual(exports.whip_core:GetItemCount(source, COIN), 10, 'four coins back — not banknotes')

                local bank, bankErr = exports.whip_core:ChargePlayer(source, 1, { method = 'bank', currency = COIN })
                assertFalse(bank, 'a bank payment is in dollars')
                assertNotNil(bankErr, 'with a reason')
            end,
        },
        {
            name = 'Bad input is refused; an amount of 0 is a receipt for nothing',
            fn = function(source, ctx)
                local c0 = cash(source)
                for _, amount in ipairs({ -5, 1.5, 'abc' }) do
                    local r = exports.whip_core:ChargePlayer(source, amount, { method = 'cash' })
                    assertFalse(r, ('amount %s refused'):format(tostring(amount)))
                end
                local r, err = exports.whip_core:ChargePlayer(source, 5, { method = 'card' })
                assertFalse(r, 'an unknown method is refused')
                assertNotNil(err, 'with a reason')

                local free = exports.whip_core:ChargePlayer(source, 0, { method = 'cash' })
                assertNotNil(free, 'a free thing still gets a receipt')
                assertEqual(free.amount, 0, 'for nothing')
                assertOk(exports.whip_core:RefundPlayer(free))
                assertEqual(cash(source), c0, 'and no money moved at any point')
            end,
        },
        {
            -- The rule the dealership's list is built on (MON-5): paying needs WITHDRAW rights.
            name = 'A player cannot pay from an account they can only view',
            fn = function(source, ctx)
                -- Owned by ANOTHER player: "any other character" was often one of the tester's own, and
                -- access between two characters of one player is refused (Config.BlockOwnCharacterTransfers).
                local other, otherUser = MakeStranger()
                assertNotNil(other, 'a character on another player account')
                ctx.strangerUserId = otherUser

                -- A character who may be offline: { charId = n } (whip's person rule).
                local acc, err = exports.whip_core:CreateBankAccount({ charId = other }, '_test_payments_view', { type = 'personal' })
                assertNotNil(acc, 'an account someone else owns: ' .. tostring(err))
                ctx.otherAccountId = acc.accountId
                assertOk(exports.whip_core:BankSystemDeposit(acc.accountId, 500, { reason = '_t47 view fund' }))
                assertOk(exports.whip_core:GrantBankAccess(acc.accountId, source, 'view', { charId = other }))

                local receipt, payErr = exports.whip_core:ChargePlayer(source, 50, { method = 'bank', accountId = acc.accountId })
                assertFalse(receipt, 'view access cannot pay')
                assertEqual(payErr, 'No withdraw permission on this account', 'and says why')
                assertEqual(balance(acc.accountId), 500, 'nothing left the account')
            end,
        },
        {
            -- PayPlayer (the Director's payouts, 2 Oct 2026): the other way, never lost.
            name = 'PayPlayer: cash to the player, bank to an account, an item currency as the item; bad input refused',
            fn = function(source, ctx)
                local c0 = cash(source)
                -- The result itself, or false and why, as ChargePlayer returns its receipt (14 Nov 2026: it was
                -- `true, result`).
                local r, why = exports.whip_core:PayPlayer(source, 25, { reason = '_t47 pay' })
                assertType(r, 'table', 'auto pays an online player (' .. tostring(why) .. ')')
                assertEqual(r.method, 'cash', 'in cash')
                assertEqual(r.amount, 25, 'all of it')
                assertEqual(cash(source), c0 + 25, 'and it arrived')

                local b0 = balance(ctx.accountId)
                r, why = exports.whip_core:PayPlayer(source, 40, { method = 'bank', accountId = ctx.accountId, reason = '_t47 pay bank' })
                assertType(r, 'table', 'bank into a named account (' .. tostring(why) .. ')')
                assertEqual(r.accountId, ctx.accountId, 'that account')
                assertEqual(balance(ctx.accountId), b0 + 40, 'and it arrived')

                r, why = exports.whip_core:PayPlayer({ charId = ctx.charId }, 0, { reason = '_t47 nothing' })
                assertType(r, 'table', '0 pays nothing and still returns a result (' .. tostring(why) .. ')')
                assertEqual(r.amount, 0, 'of nothing')

                local coins0 = exports.whip_core:GetItemCount(source, COIN) or 0
                r, why = exports.whip_core:PayPlayer(source, 3, { currency = COIN, reason = '_t47 coins' })
                assertType(r, 'table', 'an item currency (' .. tostring(why) .. ')')
                local coins = exports.whip_core:GetItemCount(source, COIN) or 0
                assertEqual(coins, coins0 + 3, 'paid as that item')
                if coins > 0 then exports.whip_core:RemoveItem(source, COIN, coins, nil, { reason = '_t47 coins back' }) end

                local cases = {
                    { who = source, amount = -1,  opts = nil,                                  why = 'whole number' },
                    { who = source, amount = 2.5, opts = nil,                                  why = 'whole number' },
                    { who = source, amount = 5,   opts = { method = 'cheque' },                why = 'method' },
                    { who = source, amount = 5,   opts = { currency = '_nope' },               why = 'currency' },
                    { who = source, amount = 5,   opts = { currency = COIN, method = 'bank' }, why = 'dollars' },
                    { who = 65000,  amount = 5,   opts = nil,                                  why = 'online' },
                }
                for i, c in ipairs(cases) do
                    local resC, whyC = exports.whip_core:PayPlayer(c.who, c.amount, c.opts)
                    assertFalse(resC, ('case %d is refused'):format(i))
                    assertTrue(type(whyC) == 'string' and whyC:find(c.why, 1, true) ~= nil,
                        ('case %d says "%s" (got: %s)'):format(i, c.why, tostring(whyC)))
                end
            end,
        },
    },
})
