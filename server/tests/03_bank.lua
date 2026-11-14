--- Is the overdraft rule installed? Two tests need to know; one of them skips without it.
---@return boolean
local function checkConstraintPresent()
    local rows = DbQuery([[
        SELECT COUNT(*) AS n FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'bank_accounts'
          AND `CONSTRAINT_NAME` = 'chk_balance_nonneg'
    ]])
    return rows[1] and (tonumber(rows[1].n) or 0) > 0 or false
end

RegisterTestModule({
    order    = 3,
    category = 'Bank',
    -- FILLS THE RUNNER'S ctx AS IT GOES. It used to build its own table and return it at the end,
    -- so a setup that created the first account and then failed on the second lost the only record
    -- of the first — and teardown, handed an empty table, left it open for good.
    setup = function(source, ctx)
        local player = exports.whip_core:GetPlayer(source)
        ctx.charId = player.charId

        -- Every person argument is a server id or { charId = n } (whip's person rule, audit 3 DX-17).
        local acc, err = exports.whip_core:CreateBankAccount(source, '_test_account', 'personal')
        if not acc then error('Setup failed: ' .. tostring(err)) end
        ctx.accountId, ctx.accountNumber = acc.accountId, acc.accountNumber

        local acc2, err2 = exports.whip_core:CreateBankAccount(source, '_test_account_2', 'personal')
        if not acc2 then error('Setup failed: ' .. tostring(err2)) end
        ctx.accountId2 = acc2.accountId
    end,
    teardown = function(ctx)
        -- A raw-query fault left armed would fail the next module's write instead of this one's.
        pcall(exports.whip_core.__TestFailNextQuery, exports.whip_core, nil)

        -- Unfrozen FIRST: a frozen account refuses the withdrawal DisposeTestAccount drains it with,
        -- and then refuses to close for still holding money. The frozen test unfreezes on its way
        -- out, but only if every assertion before that line passed.
        if ctx.accountId then
            pcall(DbQuery, 'UPDATE `bank_accounts` SET `frozen` = 0 WHERE `accountId` IN (?, ?)',
                { ctx.accountId, ctx.accountId2 or ctx.accountId })
        end

        -- Bank.CloseAccount refuses an account with a non-zero balance, and this teardown
        -- used to throw that refusal away into a pcall without reading the return. The
        -- deposit tests leave a balance behind, so `_test_account` was never actually closed:
        -- 85 of them had accumulated, one per run since March, against 82-of-85 closed for
        -- `_test_account_2` which happens to end at zero. Drain first, then close, then say
        -- so if it still failed.
        -- Stray grants first: the accounts below are closed, but a failed GrantAccess test
        -- would otherwise leave a row pointing at an account id that gets reused.
        --
        -- SCOPED TO THIS MODULE'S OWN ACCOUNT, and that is not a detail. The grant target is a
        -- REAL charId now, so a delete keyed on charId alone would strip that character's
        -- access to every account they hold — including their own — to tidy up after a test.
        if ctx.accountId and ctx.grantProbe then
            pcall(DbQuery, 'DELETE FROM `bank_access` WHERE `accountId` = ? AND `charId` = ?',
                { ctx.accountId, ctx.grantProbe })
        end
        DisposeTestAccount(ctx.accountId)
        DisposeTestAccount(ctx.accountId2)

        -- The account the close test closed is already closed, so DisposeTestAccount cannot find
        -- it — but its ledger rows (the prefund, the transfer in, the drain) are still there.
        if ctx.closedAccountId then
            pcall(DbQuery, 'DELETE FROM `bank_transactions` WHERE `fromAccountId` = ? OR `toAccountId` = ?',
                { ctx.closedAccountId, ctx.closedAccountId })
        end

        -- The limit tests' accounts: the open ones closed, the closed ones' ledger rows deleted.
        for _, id in ipairs(ctx.extraAccounts or {}) do
            if exports.whip_core:GetBankAccount(id) then DisposeTestAccount(id) end
        end
        for _, id in ipairs(ctx.closedExtra or {}) do
            pcall(DbQuery, 'DELETE FROM `bank_transactions` WHERE `fromAccountId` = ? OR `toAccountId` = ?', { id, id })
        end
    end,
    tests = {
        {
            name = 'GetBankAccount returns created account',
            fn = function(source, ctx)
                local acc = exports.whip_core:GetBankAccount(ctx.accountId)
                assertNotNil(acc, 'GetBankAccount')
                assertEqual(acc.accountId, ctx.accountId, 'accountId')
                assertEqual(acc.ownerCharId, ctx.charId, 'owned by the tester')
                assertEqual(acc.balance, 0, 'a new non-default account starts empty')
            end,
        },
        {
            name = 'GetBankAccountByNumber finds by number',
            fn = function(source, ctx)
                local acc = exports.whip_core:GetBankAccountByNumber(ctx.accountNumber)
                assertNotNil(acc, 'GetBankAccountByNumber')
                assertEqual(acc.accountId, ctx.accountId, 'accountId')
            end,
        },
        {
            -- NAMES BOTH ACCOUNTS. ">= 2" was satisfied by any two accounts the tester happened to
            -- hold — a default account and one leaked by an earlier run would have done.
            name = 'GetCharacterBankAccounts lists both new accounts, as owner',
            fn = function(source, ctx)
                local accs = exports.whip_core:GetCharacterBankAccounts(ctx.charId)
                assertType(accs, 'table', 'GetCharacterBankAccounts')
                local roles = {}
                for _, a in ipairs(accs) do roles[a.accountId] = a.role end
                assertEqual(roles[ctx.accountId], 'owner', 'the first test account, with its role')
                assertEqual(roles[ctx.accountId2], 'owner', 'the second test account, with its role')
            end,
        },
        {
            -- WHICH account, not just "an" account. Every character is given a default account
            -- at creation (player_lifecycle), and it must be that one — not either of the fixtures,
            -- which are created with isDefault pinned false.
            name = 'GetDefaultBankAccount returns the character\'s default account',
            fn = function(source, ctx)
                local acc = exports.whip_core:GetDefaultBankAccount(source)
                assertNotNil(acc, 'GetDefaultBankAccount')
                assertEqual(acc.ownerCharId, ctx.charId, 'owned by the tester')
                assertTrue(acc.isDefault == true or acc.isDefault == 1, 'flagged as the default')
                assertNotEqual(acc.accountId, ctx.accountId, 'not the first fixture')
                assertNotEqual(acc.accountId, ctx.accountId2, 'not the second fixture')
            end,
        },
        {
            name = 'BankDeposit increases balance',
            fn = function(source, ctx)
                local before = exports.whip_core:GetBankAccount(ctx.accountId)
                local ok, err = exports.whip_core:BankDeposit(ctx.accountId, 500, { charId = ctx.charId }, '_test_deposit')
                assertOk(ok, err, 'BankDeposit')
                local after = exports.whip_core:GetBankAccount(ctx.accountId)
                assertEqual(after.balance, before.balance + 500, 'balance after deposit')
            end,
        },
        {
            name = 'BankWithdraw decreases balance',
            fn = function(source, ctx)
                local before = exports.whip_core:GetBankAccount(ctx.accountId)
                local ok, err = exports.whip_core:BankWithdraw(ctx.accountId, 200, { charId = ctx.charId }, '_test_withdraw')
                assertOk(ok, err, 'BankWithdraw')
                local after = exports.whip_core:GetBankAccount(ctx.accountId)
                assertEqual(after.balance, before.balance - 200, 'balance after withdraw')
            end,
        },
        {
            -- GetBalance keeps the balance in memory after its first read: every write must keep it true.
            name = 'GetBalance answers the account\'s balance, and follows a deposit, a withdrawal and a transfer',
            fn = function(source, ctx)
                local ref = { accountId = ctx.accountId }
                local first = exports.whip_core:GetBalance(ref)
                assertEqual(first, exports.whip_core:GetBankAccount(ctx.accountId).balance, 'the first read is the row\'s')
                assertOk(exports.whip_core:BankDeposit(ctx.accountId, 40, { charId = ctx.charId }, '_test_balance'))
                assertEqual(exports.whip_core:GetBalance(ref), first + 40, 'after a deposit')
                assertOk(exports.whip_core:BankWithdraw(ctx.accountId, 15, { charId = ctx.charId }, '_test_balance'))
                assertEqual(exports.whip_core:GetBalance(ref), first + 25, 'after a withdrawal')
                assertOk(exports.whip_core:BankSystemTransfer(ctx.accountId, ctx.accountId2, 5, '_test_balance'))
                assertEqual(exports.whip_core:GetBalance(ref), first + 20, 'after a transfer out')
                assertEqual(exports.whip_core:GetBalance(ref), exports.whip_core:GetBankAccount(ctx.accountId).balance,
                    'still the row\'s')

                local main = exports.whip_core:GetDefaultBankAccount(source)
                if main then
                    assertEqual(exports.whip_core:GetBalance(source), main.balance, 'a person\'s: their main account')
                end
                local none, why = exports.whip_core:GetBalance({ accountId = 2000000000 })
                assertFalse(none, 'no such account: false')
                assertType(why, 'string', 'and why')
            end,
        },
        {
            -- Pins WHICH branch refused. Withdraw short-circuits on an in-Lua balance check
            -- before it builds a transaction, so this test has only ever exercised that check —
            -- never the SQL. 'Transaction failed' here would mean it got through, which is a
            -- different bug entirely.
            name = 'BankWithdraw more than balance is refused by the pre-check',
            fn = function(source, ctx)
                local ok, err = exports.whip_core:BankWithdraw(ctx.accountId, 999999999, { charId = ctx.charId }, '_test_overdraft')
                assertFalse(ok, 'BankWithdraw overdraft should fail')
                assertEqual(err, 'Insufficient funds',
                    'refused by the pre-check, not by a failed transaction')
            end,
        },
        {
            -- THE OVERDRAFT RULE LIVES IN THE DATABASE NOW, and nothing was checking it was there.
            --
            -- The `AND balance >= ?` guards were removed from Withdraw and Transfer, because a
            -- guarded UPDATE matching zero rows is not an error — it commits and reports success,
            -- which is how two concurrent withdrawals both succeeded. chk_balance_nonneg replaces
            -- them: an overdraft becomes a real SQL error that rolls the whole transaction back.
            --
            -- The CHECK is declared in Bank.ensureTable's CREATE TABLE, but a database can still
            -- lack it: MariaDB older than 10.2.1 accepts the clause and ignores it, and a table
            -- built by hand may simply not have it. Without this test the suite is fully green on
            -- a server that has NO overdraft protection at all — the framework prints a warning
            -- at startup and the tests say nothing.
            name = 'chk_balance_nonneg exists — the overdraft rule is actually installed',
            fn = function()
                assertTrue(checkConstraintPresent(),
                    'chk_balance_nonneg is missing from bank_accounts — balances can go negative')
            end,
        },
        {
            -- Proves ENFORCEMENT, not just presence. Drives the same statements Withdraw builds,
            -- bypassing the Lua pre-check, so the database itself has to refuse. (Raw SQL on
            -- purpose: going around whip_core is the whole point of this one.)
            name = 'A CHECK violation rolls back the whole transaction, ledger row included',
            fn = function(source, ctx)
                if not checkConstraintPresent() then
                    skip('migration 008 has not run — the test above is the one that names this')
                end

                local before = exports.whip_core:GetBankAccount(ctx.accountId).balance

                local ok = MySQL.transaction.await({
                    { query  = 'UPDATE `bank_accounts` SET `balance` = `balance` - ? WHERE `accountId` = ?',
                      values = { before + 1000, ctx.accountId } },
                    { query  = 'INSERT INTO `bank_transactions` (`fromAccountId`, `amount`, `type`, `message`) VALUES (?, ?, ?, ?)',
                      values = { ctx.accountId, 1, 'withdraw', '_test_check_rollback' } },
                })

                assertFalse(ok, 'a CHECK violation must fail the transaction, not commit silently')
                assertDbScalar('SELECT `balance` FROM `bank_accounts` WHERE `accountId` = ?',
                    { ctx.accountId }, before, 'balance unchanged')
                assertDbRowCount('SELECT 1 FROM `bank_transactions` WHERE `message` = ?',
                    { '_test_check_rollback' }, 0, 'the ledger row rolled back with it')
            end,
        },
        {
            name = 'BankTransfer moves money between accounts',
            fn = function(source, ctx)
                -- Ensure source has funds
                local funded, fErr = exports.whip_core:BankDeposit(ctx.accountId, 100, { charId = ctx.charId }, '_test_prefund')
                assertOk(funded, fErr, 'prefund deposit')
                local b1 = exports.whip_core:GetBankAccount(ctx.accountId).balance
                local b2 = exports.whip_core:GetBankAccount(ctx.accountId2).balance
                local ok, err = exports.whip_core:BankTransfer(ctx.accountId, ctx.accountId2, 50, { charId = ctx.charId }, '_test_transfer')
                assertOk(ok, err, 'BankTransfer')
                assertEqual(exports.whip_core:GetBankAccount(ctx.accountId).balance, b1 - 50, 'source balance')
                assertEqual(exports.whip_core:GetBankAccount(ctx.accountId2).balance, b2 + 50, 'dest balance')
            end,
        },

        -- ==========================================
        -- Refusals — the half of a bank that matters
        -- ==========================================
        {
            -- A zero deposit is a ledger row for nothing, and a negative one is a withdrawal that
            -- skips every withdrawal rule. MON-2 (24 Sep 2026): the amount was math.floor'd, so a
            -- string or nil THREW out of the export, 1.5 was quietly charged as 1, and NaN passed
            -- `amount <= 0` on its way to the balance. All refused now, by the same words.
            name = 'Bad amounts — zero, negative, fractions, text, NaN, infinity, nothing — are refused everywhere',
            fn = function(source, ctx)
                local before = exports.whip_core:GetBankAccount(ctx.accountId).balance
                local WHY = 'Amount must be a whole number of 1 or more'

                -- A list with holes: `nil` sits in it on purpose, so it is walked by index.
                local bad = { 0, -5, 0.4, 1.5, 'abc', 0/0, math.huge, nil }
                for i = 1, 8 do
                    local amount = bad[i]
                    local label = tostring(amount)

                    local d, dErr = exports.whip_core:BankDeposit(ctx.accountId, amount, { charId = ctx.charId }, '_test_bad_amount')
                    assertFalse(d, ('BankDeposit(%s) refused'):format(label))
                    assertEqual(dErr, WHY, ('BankDeposit(%s) reason'):format(label))

                    local w, wErr = exports.whip_core:BankWithdraw(ctx.accountId, amount, { charId = ctx.charId }, '_test_bad_amount')
                    assertFalse(w, ('BankWithdraw(%s) refused'):format(label))
                    assertEqual(wErr, WHY, ('BankWithdraw(%s) reason'):format(label))

                    local t, tErr = exports.whip_core:BankTransfer(ctx.accountId, ctx.accountId2, amount, { charId = ctx.charId }, '_test_bad_amount')
                    assertFalse(t, ('BankTransfer(%s) refused'):format(label))
                    assertEqual(tErr, WHY, ('BankTransfer(%s) reason'):format(label))

                    local s, sErr = exports.whip_core:BankSystemDeposit(ctx.accountId, amount, '_test_bad_amount')
                    assertFalse(s, ('BankSystemDeposit(%s) refused'):format(label))
                    assertEqual(sErr, WHY, ('BankSystemDeposit(%s) reason'):format(label))
                end

                local same, sameErr = exports.whip_core:BankTransfer(ctx.accountId, ctx.accountId, 10, { charId = ctx.charId }, '_test_same')
                assertFalse(same, 'a transfer to the same account is refused')
                assertEqual(sameErr, 'Cannot transfer to the same account', 'and says so')

                assertEqual(exports.whip_core:GetBankAccount(ctx.accountId).balance, before, 'the balance never moved')
                assertDbRowCount('SELECT 1 FROM `bank_transactions` WHERE `message` IN (?, ?)',
                    { '_test_bad_amount', '_test_same' }, 0, 'and no refused call wrote a ledger row')
            end,
        },
        {
            -- charId 0 is nobody: `characters` starts at 1, so it holds access to nothing. The
            -- permission check is the only thing standing between an accountId and anyone who knows
            -- it, so each verb's refusal is pinned by its own reason.
            name = 'Someone with no access cannot deposit into, withdraw from or transfer out of an account',
            fn = function(source, ctx)
                local b1 = exports.whip_core:GetBankAccount(ctx.accountId).balance
                local b2 = exports.whip_core:GetBankAccount(ctx.accountId2).balance

                local d, dErr = exports.whip_core:BankDeposit(ctx.accountId, 10, { charId = 999999999 }, '_test_noaccess')
                assertFalse(d, 'deposit refused')
                assertEqual(dErr, 'No deposit permission on this account', 'deposit reason')

                local w, wErr = exports.whip_core:BankWithdraw(ctx.accountId, 10, { charId = 999999999 }, '_test_noaccess')
                assertFalse(w, 'withdraw refused')
                assertEqual(wErr, 'No withdraw permission on this account', 'withdraw reason')

                local t, tErr = exports.whip_core:BankTransfer(ctx.accountId, ctx.accountId2, 10, { charId = 999999999 }, '_test_noaccess')
                assertFalse(t, 'transfer refused')
                assertEqual(tErr, 'No withdraw permission on source account', 'transfer reason')

                assertEqual(exports.whip_core:GetBankAccount(ctx.accountId).balance, b1, 'first balance unchanged')
                assertEqual(exports.whip_core:GetBankAccount(ctx.accountId2).balance, b2, 'second balance unchanged')
            end,
        },
        {
            -- There is no export to freeze an account — it is an admin's switch, on the row. So the
            -- row is what this test flips, which is also exactly where Bank reads it from: every
            -- verb re-reads the account (GetAccount) rather than trusting a cache.
            name = 'A frozen account refuses deposits, withdrawals and transfers either way',
            fn = function(source, ctx)
                local b1 = exports.whip_core:GetBankAccount(ctx.accountId).balance
                DbQuery('UPDATE `bank_accounts` SET `frozen` = 1 WHERE `accountId` = ?', { ctx.accountId })

                local d, dErr = exports.whip_core:BankDeposit(ctx.accountId, 10, { charId = ctx.charId }, '_test_frozen')
                assertFalse(d, 'deposit refused')
                assertEqual(dErr, 'Account is frozen', 'deposit reason')

                local w, wErr = exports.whip_core:BankWithdraw(ctx.accountId, 10, { charId = ctx.charId }, '_test_frozen')
                assertFalse(w, 'withdraw refused')
                assertEqual(wErr, 'Account is frozen', 'withdraw reason')

                local out, outErr = exports.whip_core:BankTransfer(ctx.accountId, ctx.accountId2, 10, { charId = ctx.charId }, '_test_frozen')
                assertFalse(out, 'transfer out refused')
                assertEqual(outErr, 'Source account is frozen', 'transfer-out reason')

                -- Money cannot be parked IN a frozen account either — the second account holds the
                -- 50 the transfer test moved, so this is refused for the freeze, not for funds.
                local into, intoErr = exports.whip_core:BankTransfer(ctx.accountId2, ctx.accountId, 1, { charId = ctx.charId }, '_test_frozen')
                assertFalse(into, 'transfer in refused')
                assertEqual(intoErr, 'Destination account is frozen', 'transfer-in reason')

                local sys, sysErr = exports.whip_core:BankSystemDeposit(ctx.accountId, 10, '_test_frozen')
                assertFalse(sys, 'even a system deposit is refused')
                assertEqual(sysErr, 'Account is frozen', 'system deposit reason')

                DbQuery('UPDATE `bank_accounts` SET `frozen` = 0 WHERE `accountId` = ?', { ctx.accountId })
                assertEqual(exports.whip_core:GetBankAccount(ctx.accountId).balance, b1, 'the balance never moved')
            end,
        },
        {
            -- Reads the ROWS the tests above wrote, not "at least one row": an account whose ledger
            -- was missing its withdrawals would have passed.
            name = 'GetBankTransactions returns this account\'s own ledger rows',
            fn = function(source, ctx)
                local txns = exports.whip_core:GetBankTransactions(ctx.accountId, 50, 0)
                assertType(txns, 'table', 'GetBankTransactions')

                local byMessage = {}
                for _, t in ipairs(txns) do byMessage[t.message] = t end

                local dep = byMessage['_test_deposit']
                assertNotNil(dep, 'the deposit is in the ledger')
                assertEqual(dep.amount, 500, 'deposit amount')
                assertEqual(dep.type, 'deposit', 'deposit type')
                assertEqual(dep.toAccountId, ctx.accountId, 'deposit went INTO this account')

                local wd = byMessage['_test_withdraw']
                assertNotNil(wd, 'the withdrawal is in the ledger')
                assertEqual(wd.amount, 200, 'withdraw amount')
                assertEqual(wd.fromAccountId, ctx.accountId, 'withdrawal came OUT of this account')

                local tr = byMessage['_test_transfer']
                assertNotNil(tr, 'the transfer is in the ledger')
                assertEqual(tr.toAccountId, ctx.accountId2, 'transfer went to the second account')

                assertNil(byMessage['_test_noaccess'], 'refused calls left no rows')
            end,
        },
        {
            name = 'BankSystemDeposit works without an actor, and takes { reason, actorCharId }',
            fn = function(source, ctx)
                local before = exports.whip_core:GetBankAccount(ctx.accountId).balance
                local ok, err = exports.whip_core:BankSystemDeposit(ctx.accountId, 100, '_test_system')
                assertOk(ok, err, 'BankSystemDeposit with a plain reason')
                assertEqual(exports.whip_core:GetBankAccount(ctx.accountId).balance, before + 100, 'balance after system deposit')

                -- MON-4: the options form, so the reason and the actor cannot swap places.
                ok, err = exports.whip_core:BankSystemDeposit(ctx.accountId, 7, { reason = '_test_system_opts', actorCharId = ctx.charId })
                assertOk(ok, err, 'BankSystemDeposit with options')
                assertDbRowCount('SELECT 1 FROM `bank_transactions` WHERE `message` = ? AND `actorCharId` = ? AND `toAccountId` = ?',
                    { '_test_system_opts', ctx.charId, ctx.accountId }, 1, 'the ledger row has the reason AND the actor')
            end,
        },
        {
            -- MON-3: the system can take money OUT, and move it between accounts, with no
            -- permission check — fines, fees, payroll — and the same refusals otherwise.
            name = 'BankSystemWithdraw and BankSystemTransfer move money without a permission check',
            fn = function(source, ctx)
                local ok, err = exports.whip_core:BankSystemDeposit(ctx.accountId, 40, '_test_sys_prefund')
                assertOk(ok, err, 'prefund')
                local b1 = exports.whip_core:GetBankAccount(ctx.accountId).balance
                local b2 = exports.whip_core:GetBankAccount(ctx.accountId2).balance

                ok, err = exports.whip_core:BankSystemWithdraw(ctx.accountId, 15, '_test_sys_withdraw')
                assertOk(ok, err, 'system withdrawal')
                assertEqual(exports.whip_core:GetBankAccount(ctx.accountId).balance, b1 - 15, 'taken out')

                ok, err = exports.whip_core:BankSystemTransfer(ctx.accountId, ctx.accountId2, 10, { reason = '_test_sys_transfer' })
                assertOk(ok, err, 'system transfer')
                assertEqual(exports.whip_core:GetBankAccount(ctx.accountId).balance, b1 - 25, 'source after transfer')
                assertEqual(exports.whip_core:GetBankAccount(ctx.accountId2).balance, b2 + 10, 'destination after transfer')

                local over, overErr = exports.whip_core:BankSystemWithdraw(ctx.accountId, 999999999, '_test_sys_over')
                assertFalse(over, 'a system withdrawal still cannot overdraw')
                assertEqual(overErr, 'Insufficient funds', 'and says so')
                local same, sameErr = exports.whip_core:BankSystemTransfer(ctx.accountId, ctx.accountId, 1)
                assertFalse(same, 'nor transfer to the same account')
                assertEqual(sameErr, 'Cannot transfer to the same account', 'and says so')
            end,
        },
        {
            -- MON-3: ask before acting — the rule the bank applies, with a reason.
            name = 'CanUseBankAccount answers the bank\'s own permission rule, with a reason',
            fn = function(source, ctx)
                -- The account first, then the person (audit 3 DX-17).
                assertOk(exports.whip_core:CanUseBankAccount(ctx.accountId, source, 'owner'))
                assertOk(exports.whip_core:CanUseBankAccount(ctx.accountId, { charId = ctx.charId }, 'withdraw'))

                -- A charId nobody holds (a real id, so it reaches the permission check).
                local ok, err = exports.whip_core:CanUseBankAccount(ctx.accountId, { charId = 999999999 }, 'view')
                assertFalse(ok, 'someone with no access cannot even view it')
                assertEqual(err, 'Needs view access to this account', 'and says what is missing')

                -- A bare number is a SERVER ID, and nobody is on server id 0.
                ok, err = exports.whip_core:CanUseBankAccount(ctx.accountId, 0, 'view')
                assertFalse(ok, 'server id 0 is nobody')
                assertNotNil(err, 'with a reason')

                ok, err = exports.whip_core:CanUseBankAccount(ctx.accountId, source, 'emperor')
                assertFalse(ok, 'an unknown role is refused')
                assertNotNil(err, 'with a reason')

                ok, err = exports.whip_core:CanUseBankAccount(999999999, source, 'view')
                assertFalse(ok, 'an account that does not exist')
                assertEqual(err, 'Account not found', 'says so')
            end,
        },
        -- ==========================================
        -- Access Control
        -- ==========================================
        {
            -- NAMED FOR WHAT IT ACTUALLY DOES. This was called "GrantAccess assigns view role on
            -- account2" and never called GrantAccess — it read the access list of account ONE,
            -- behind a guard on account TWO, which it then did not use. A green line reading
            -- "GrantAccess assigns view role" while GrantAccess was never entered is worse than
            -- no coverage, because it is coverage somebody will trust.
            --
            -- (Absorbed 'GetBankAccessList returns correct structure', which read list[1] and
            -- checked two fields were present — a weaker copy of this one.)
            name = 'Creating an account puts the owner in its access list',
            fn = function(source, ctx)
                local list = exports.whip_core:GetBankAccessList(ctx.accountId)
                assertType(list, 'table', 'access list type')

                local found = nil
                for _, entry in ipairs(list) do
                    if entry.charId == ctx.charId then found = entry; break end
                end
                assertNotNil(found, 'owner in access list')
                assertEqual(found.role, 'owner', 'with the owner role')
            end,
        },
        {
            -- ####################################################################
            -- THIS USED TO SKIP UNCONDITIONALLY, AND THE REASON IT GAVE WAS WRONG.
            --
            -- It said testing GrantAccess "needs a second character to grant TO — which this
            -- harness cannot produce", so the export had never executed once. But GrantAccess
            -- takes a charId, not a player: it writes a row into `bank_access`, and that table
            -- carries no foreign key to `characters`. A second character was never required —
            -- only a charId that is not the granter's.
            --
            -- The original worry was real and is still honoured: every role is at or below
            -- owner, so granting one to YOURSELF would overwrite the ownership the rest of this
            -- module depends on. The answer is to grant to a synthetic charId instead, which
            -- A second character ROW, though — not a second character ONLINE, which is what
            -- the skip claimed and what made this look impossible. `bank_access.charId` is
            -- foreign-keyed to `characters` (fk_access_charId, declared in migrations.lua), so
            -- the target has to be a real charId; it does not have to be connected, and the
            -- account being granted on is this module's own fixture, disposed in teardown.
            --
            -- A skip that states a reason beats a silent pass. It is still a test that never
            -- runs, and "the harness cannot do this" deserves re-checking rather than
            -- inheriting — it was half right, and the half it got wrong cost the whole test.
            -- ####################################################################
            name = 'GrantBankAccess assigns a role, and refuses what it must',
            fn = function(source, ctx)
                -- Any real character of ANOTHER player (the bank refuses the granter's own other characters while
                -- Config.BlockOwnCharacterTransfers is on). Read rather than invented, because the foreign key
                -- means an invented one cannot be inserted at all.
                local rows = DbQuery('SELECT `charId` FROM `characters` WHERE `charId` <> ? '
                    .. 'AND `userId` <> (SELECT `userId` FROM `characters` WHERE `charId` = ?) LIMIT 1', { ctx.charId, ctx.charId })
                if not rows[1] then
                    skip('this database holds no other player\'s character — nobody to grant access to')
                end

                local OTHER = tonumber(rows[1].charId)
                ctx.grantProbe = OTHER   -- so teardown clears exactly what was granted

                local ok, err = exports.whip_core:GrantBankAccess(ctx.accountId, { charId = OTHER }, 'view', source)
                assertTrue(ok, 'the owner may grant a lesser role: ' .. tostring(err))

                local list = exports.whip_core:GetBankAccessList(ctx.accountId)
                local granted = nil
                for _, entry in ipairs(list or {}) do
                    if tonumber(entry.charId) == OTHER then granted = entry break end
                end
                assertNotNil(granted, 'the grant appears in the access list')
                assertEqual(granted.role, 'view', 'with the role it was given')

                -- ---- the refusals, which are the whole authorization surface ----

                local ok2, e2 = exports.whip_core:GrantBankAccess(ctx.accountId, { charId = OTHER }, 'emperor', source)
                assertFalse(ok2, 'an unknown role is refused')
                assertTrue(tostring(e2):find('Invalid role', 1, true) ~= nil, 'and says so')

                -- NOBODY MAY GRANT AT OR ABOVE THEIR OWN LEVEL. An owner granting owner would
                -- hand the account away; a manager granting manager would let access spread
                -- sideways forever without the owner ever agreeing to it.
                local ok3, e3 = exports.whip_core:GrantBankAccess(ctx.accountId, { charId = OTHER }, 'owner', source)
                assertFalse(ok3, 'granting a role equal to your own is refused')
                assertTrue(tostring(e3):lower():find('equal to or higher', 1, true) ~= nil,
                    ('and says why (got "%s")'):format(tostring(e3)))

                -- The granter must hold access themselves. Without this check, anyone who knew
                -- an accountId could grant themselves into it.
                --
                -- A charId nobody holds, NOT OTHER + 1. That was "some other character" — until the
                -- tester's own charId happened to be OTHER + 1, and the owner's grant then succeeded
                -- and the test went red against correct code. (It was charId 0; a person is
                -- { charId = n } with n a real id now, so 0 would be refused before the check.)
                local ok4, e4 = exports.whip_core:GrantBankAccess(ctx.accountId, { charId = OTHER }, 'view', { charId = 999999999 })
                assertFalse(ok4, 'a granter with no access to the account is refused')
                assertEqual(e4, 'Granter has no access to this account', 'and says why')

                -- ---- and it comes back off ----

                local revoked = exports.whip_core:RevokeBankAccess(ctx.accountId, { charId = OTHER }, source)
                assertTrue(revoked, 'the grant can be revoked')

                local after = exports.whip_core:GetBankAccessList(ctx.accountId) or {}
                for _, entry in ipairs(after) do
                    assertNotEqual(tonumber(entry.charId), OTHER,
                        'and the revoked charId is gone from the list')
                end

                -- Nobody can take the owner's access away, the owner included.
                local ownerRevoked, orErr = exports.whip_core:RevokeBankAccess(ctx.accountId, source, source)
                assertFalse(ownerRevoked, 'the owner cannot be revoked')
                assertEqual(orErr, 'Cannot revoke owner access', 'and says so')
            end,
        },
        {
            -- A WRITE THAT FAILS MUST SAY SO, AND LEAVE NOTHING BEHIND. The upsert is the one write
            -- in GrantAccess, and it is pcall'd precisely so a database error comes back as
            -- (false, reason) rather than as a grant the caller believes happened.
            --
            -- The target is a charId nobody holds on purpose: if the injected fault somehow did not
            -- fire, the real insert fails anyway on the characters foreign key — and __TestRawFaultArmed
            -- still being set is what then turns the test red, naming the real problem.
            name = 'A GrantBankAccess whose write fails reports it, and grants nothing',
            fn = function(source, ctx)
                assertTrue(exports.whip_core:__TestFailNextQuery('INSERT INTO `bank_access`'), 'fault armed')

                local ok, err = exports.whip_core:GrantBankAccess(ctx.accountId, { charId = 999999999 }, 'view', source)
                -- Read, then disarm AT ONCE: a fault that did not fire would otherwise sit armed for
                -- ten seconds and fail whatever unrelated write matched it next.
                local stillArmed = exports.whip_core:__TestRawFaultArmed()
                exports.whip_core:__TestFailNextQuery(nil)
                assertNil(stillArmed, 'the fault fired on the grant\'s own write')
                assertFalse(ok, 'the grant reports failure')
                assertEqual(err, 'Could not save the access change', 'with its reason')

                for _, entry in ipairs(exports.whip_core:GetBankAccessList(ctx.accountId) or {}) do
                    assertNotEqual(tonumber(entry.charId), 0, 'nothing was granted')
                end
            end,
        },
        {
            name = 'GetJobBankAccounts returns nothing for a job with no accounts',
            fn = function(source)
                -- (The positive case — a job's business account — is in 04_jobs, which owns a job.)
                local accs = exports.whip_core:GetJobBankAccounts(999999)
                assertType(accs, 'table', 'GetJobBankAccounts type')
                assertEqual(#accs, 0, 'no accounts for fake jobId')
            end,
        },

        -- ==========================================
        -- Close
        -- ==========================================
        {
            -- UNCONDITIONAL. This only asserted when the balance happened to be above zero, so on a
            -- run where the deposits had failed it checked nothing and still passed.
            name = 'CloseBankAccount refuses an account that still holds money',
            fn = function(source, ctx)
                local acc = exports.whip_core:GetBankAccount(ctx.accountId)
                assertNotNil(acc, 'the account exists')
                if acc.balance <= 0 then
                    local ok, err = exports.whip_core:BankSystemDeposit(ctx.accountId, 1, '_test_nonzero')
                    assertOk(ok, err, 'gave the account a balance to refuse on')
                end

                local closed, why = exports.whip_core:CloseBankAccount(ctx.accountId)
                assertFalse(closed, 'close refused with money in it')
                assertEqual(why, 'Account must have zero balance', 'and says why')
                assertNotNil(exports.whip_core:GetBankAccount(ctx.accountId), 'the account is still open')
            end,
        },
        {
            name = 'CloseBankAccount succeeds with zero balance',
            fn = function(source, ctx)
                -- A MISSING FIXTURE IS A FAILURE. This was `if not ctx.accountId2 then return end`,
                -- so a setup that failed to create the second account produced a green line saying
                -- account closure works — having never closed one.
                assertNotNil(ctx.accountId2, 'setup created a second account to close')

                local acc = exports.whip_core:GetBankAccount(ctx.accountId2)
                if acc and acc.balance > 0 then
                    local drained, dErr = exports.whip_core:BankWithdraw(ctx.accountId2, acc.balance, { charId = ctx.charId }, '_test_drain')
                    assertOk(drained, dErr, 'drained to zero first')
                end

                local ok, err = exports.whip_core:CloseBankAccount(ctx.accountId2)
                assertOk(ok, err, 'CloseBankAccount')

                -- CLOSED MEANS GONE, and that has to be read from somewhere other than the call
                -- that just said so. Without this the test proves only that the function returned
                -- true, which is the weakest thing it could possibly prove.
                assertNil(exports.whip_core:GetBankAccount(ctx.accountId2), 'the account is gone')
                assertDbRowCount('SELECT 1 FROM `bank_accounts` WHERE `accountId` = ? AND `closedAt` IS NOT NULL',
                    { ctx.accountId2 }, 1, 'the row is marked closed on disk')

                -- Teardown cannot dispose a closed account, but still owes its ledger rows.
                ctx.closedAccountId = ctx.accountId2
                ctx.accountId2 = nil
            end,
        },

        -- ==========================================
        -- A character's own accounts: the limit, and closing by who (8 Oct 2026)
        -- ==========================================
        {
            -- Config.MaxExtraAccounts is whatever this server set, so savings accounts are opened until
            -- one is refused, and the limit is read from the refusal.
            name = 'CreateBankAccount stops at the savings and shared limit; personal accounts do not count',
            fn = function(source, ctx)
                ctx.extraAccounts, ctx.extraSavings, ctx.closedExtra = {}, {}, {}
                local refusedWhy
                for _ = 1, 101 do
                    local acc, why = exports.whip_core:CreateBankAccount(source, '_test_extra', 'savings')
                    if not acc then refusedWhy = why break end
                    ctx.extraAccounts[#ctx.extraAccounts + 1] = acc.accountId
                    ctx.extraSavings[#ctx.extraSavings + 1] = acc.accountId
                end
                assertType(refusedWhy, 'string', 'a savings account past the limit is refused')
                local limit = tonumber(refusedWhy:match('at most (%d+)'))
                if not limit and refusedWhy == 'Savings and shared accounts are turned off' then limit = 0 end
                assertNotNil(limit, 'with the limit in its reason: ' .. refusedWhy)
                local held = DbQuery("SELECT COUNT(*) AS n FROM `bank_accounts` WHERE `ownerCharId` = ? AND `isDefault` = 0 AND `jobId` IS NULL AND `type` IN ('savings', 'shared') AND `closedAt` IS NULL",
                    { ctx.charId })
                assertTrue((tonumber(held[1] and held[1].n) or 0) >= limit, 'refused only at the limit')

                local shared, sharedWhy = exports.whip_core:CreateBankAccount(source, '_test_extra', 'shared')
                if shared then ctx.extraAccounts[#ctx.extraAccounts + 1] = shared.accountId end
                assertFalse(shared, 'a shared account counts the same')
                assertEqual(sharedWhy, refusedWhy, 'and is refused the same way')

                local personal, personalWhy = exports.whip_core:CreateBankAccount(source, '_test_extra', 'personal')
                if personal then ctx.extraAccounts[#ctx.extraAccounts + 1] = personal.accountId end
                assertOk(personal, personalWhy, 'a personal account is not limited')

                if #ctx.extraSavings == 0 then return end
                local closeId = table.remove(ctx.extraSavings)
                assertOk(exports.whip_core:CloseBankAccount(closeId, source), nil, 'one savings account closed')
                ctx.closedExtra[#ctx.closedExtra + 1] = closeId
                local again, againWhy = exports.whip_core:CreateBankAccount(source, '_test_extra', 'savings')
                if again then
                    ctx.extraAccounts[#ctx.extraAccounts + 1] = again.accountId
                    ctx.extraSavings[#ctx.extraSavings + 1] = again.accountId
                end
                assertOk(again, againWhy, 'which makes room for another')
            end,
        },
        {
            name = 'CloseBankAccount with who: only the owner, only savings or shared, never the default',
            fn = function(source, ctx)
                local savingsId = ctx.extraSavings and ctx.extraSavings[#ctx.extraSavings]
                if not savingsId then skip('no savings account to close (MaxExtraAccounts is 0 here)') end

                local nobody = exports.whip_core:CloseBankAccount(savingsId, 65000)
                assertFalse(nobody, 'a source with no player is refused')
                local rows = DbQuery('SELECT `charId` FROM `characters` WHERE `charId` <> ? AND `deleted` IS NULL LIMIT 1', { ctx.charId })
                if rows[1] then
                    local other, otherWhy = exports.whip_core:CloseBankAccount(savingsId, { charId = tonumber(rows[1].charId) })
                    assertFalse(other, 'someone who does not own it is refused')
                    assertEqual(otherWhy, 'Only the owner can close this account', 'and says why')
                end

                local personal, personalWhy = exports.whip_core:CloseBankAccount(ctx.accountId, source)
                assertFalse(personal, 'their personal (not default) account is refused')
                assertEqual(personalWhy, 'Only a savings or shared account can be closed', 'and says why')
                local default = exports.whip_core:GetDefaultBankAccount(source)
                if default then
                    local d, dWhy = exports.whip_core:CloseBankAccount(default.accountId, source)
                    assertFalse(d, 'their default account is refused')
                    assertEqual(dWhy, 'Cannot close default account', 'and says why')
                end

                assertOk(exports.whip_core:BankSystemDeposit(savingsId, 1, '_test_nonzero'), nil, 'money in')
                local full, fullWhy = exports.whip_core:CloseBankAccount(savingsId, source)
                assertFalse(full, 'refused while it holds money')
                assertEqual(fullWhy, 'Account must have zero balance', 'and says why')
                assertOk(exports.whip_core:BankSystemWithdraw(savingsId, 1, '_test_drain'), nil, 'money out')

                local ok, why = exports.whip_core:CloseBankAccount(savingsId, source)
                assertOk(ok, why, 'the owner closes their empty savings account')
                ctx.closedExtra[#ctx.closedExtra + 1] = savingsId
                assertNil(exports.whip_core:GetBankAccount(savingsId), 'and it is gone')
            end,
        },
    }
})
