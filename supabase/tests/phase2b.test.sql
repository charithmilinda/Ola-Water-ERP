-- =====================================================================
-- Phase 2B database tests — acceptance scenario 6 (sale → invoice →
-- partial payment → ageing → journals → trial balance → P&L), cheques,
-- reversals, credit notes, manual journal approval, transfers, bank
-- reconciliation, expenses, reports.
-- Runs after the Phase 0, 1A, 1B and 2A tests in the same database.
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = notice;

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000b1', 'finance@ola.test', '{"full_name":"Ishara Gunawardena"}');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.admin_assign_role('00000000-0000-0000-0000-0000000000b1', (select id from public.roles where code = 'finance_manager'), null, 'Finance');
reset role;

-- ---------------------------------------------------------------------
-- Scenario 6: sale on account → invoice → partial payment → ageing → TB → P&L
-- ---------------------------------------------------------------------
set role authenticated;
select (select coalesce(sum(amount), 0) from public.report_profit_loss(app.today(), app.today()) r,
        jsonb_to_recordset(r -> 'sections' -> 'income') as x(code text, amount numeric) where code = '4100') as sales_before \gset
select public.save_customer(null, jsonb_build_object('name', 'Galle Face Residency', 'customer_type', 'hotel', 'phone', '0112441122',
  'credit_limit', 100000, 'address', jsonb_build_object('address_line', '2 Galle Road', 'city', 'Colombo 03')), 'New customer') as hotel \gset
select public.pos_sale((select id from public.pos_sessions where location_id = (select id from public.locations where code = 'WH1') and status = 'open'),
  jsonb_build_object('seq', 3, 'customer_id', :'hotel',
    'lines', jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 20)),
    'payments', '[]'::jsonb), gen_random_uuid()) as sale \gset
reset role;
select (select id from public.invoices where customer_id = :'hotel') as inv \gset
select (select total from public.invoices where id = :'inv') as inv_total \gset
select (select subtotal_net from public.invoices where id = :'inv') as inv_net \gset
select tests.ok((select status = 'open' and total > 0 and due_date = invoice_date + 30 from public.invoices where id = :'inv'),
                'sale on account creates an open invoice with 30-day terms');
set role authenticated;
select public.record_payment(:'hotel', 'cash', round(:inv_total / 2, 2), null, :'inv', 'Half now', gen_random_uuid()) as pay1 \gset
reset role;
select tests.ok((select status = 'partially_paid' and balance = :inv_total - round(:inv_total / 2, 2) from public.invoices where id = :'inv'),
                'partial payment leaves the invoice part paid');
set role authenticated;
select tests.ok((select not_due = :inv_total - round(:inv_total / 2, 2) and d1_30 = 0 from public.report_ar_ageing() where customer_id = :'hotel'),
                'ageing shows the balance as not yet due');
select tests.ok((select sum(closing) = 0 from public.report_trial_balance(date '2026-01-01', app.today())), 'trial balance balances');
select tests.ok((select coalesce(sum(amount), 0) from public.report_profit_loss(app.today(), app.today()) r,
                   jsonb_to_recordset(r -> 'sections' -> 'income') as x(code text, amount numeric) where code = '4100') = :sales_before + :inv_net,
                'profit and loss includes the sale (net of VAT)');
select tests.ok((select (r -> 'totals' ->> 'net_profit')::numeric
                        = (r -> 'totals' ->> 'income')::numeric - (r -> 'totals' ->> 'cost_of_sales')::numeric - (r -> 'totals' ->> 'expenses')::numeric
                   from public.report_profit_loss(date '2026-01-01', app.today()) r), 'net profit = income − cost of sales − expenses');
select tests.ok((select (r -> 'totals' ->> 'assets')::numeric = (r -> 'totals' ->> 'liabilities')::numeric + (r -> 'totals' ->> 'equity')::numeric
                   from public.report_balance_sheet(app.today()) r), 'balance sheet balances: assets = liabilities + equity');
reset role;

-- ---------------------------------------------------------------------
-- Cheques: received → deposited → returned
-- ---------------------------------------------------------------------
set role authenticated;
select (select id from public.money_accounts where kind = 'bank' and is_default) as bank \gset
select (select id from public.money_accounts where kind = 'cash' and is_default) as cash \gset
select public.record_payment(:'hotel', 'cheque', 1000, 'HNB 004512', :'inv', null, gen_random_uuid()) as chq \gset
reset role;
select (:'chq'::jsonb ->> 'payment_id') as chq_id \gset
select tests.ok((select cheque_status = 'in_hand' from public.payments where id = :'chq_id'), 'a cheque starts in hand');
set role authenticated;
select public.deposit_cheques(array[:'chq_id']::uuid[], :'bank', 'Slip 7781', gen_random_uuid()) as dep \gset
select tests.throws(format($$select public.deposit_cheques(array[%L]::uuid[], %L, 'again', gen_random_uuid())$$, :'chq_id', :'bank'),
                    'not a cheque in hand', 'a cheque is deposited only once');
reset role;
select (select app.customer_outstanding(:'hotel')) as owed_before_return \gset
set role authenticated;
select public.return_cheque(:'chq_id', 'Refer to drawer', gen_random_uuid()) as ret \gset
reset role;
select tests.ok((select status = 'reversed' and cheque_status = 'returned' from public.payments where id = :'chq_id')
                and (:'ret'::jsonb ->> 'outstanding')::numeric = :owed_before_return + 1000
                and (select balance = :inv_total - round(:inv_total / 2, 2) from public.invoices where id = :'inv'),
                'returned cheque: the customer owes the Rs. 1,000 again and the invoice reopens');
select tests.ok((select balance = 0 from public.trial_balance(date '2026-01-01', date '2027-12-31') where account_code = '1140')
                or not exists (select 1 from public.trial_balance(date '2026-01-01', date '2027-12-31') where account_code = '1140'),
                'cheques in hand back to zero after deposit');

-- Reverse a payment entered by mistake
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
select public.record_payment(:'hotel', 'bank_transfer', 500, 'BOC 99812', null, 'Wrong customer', gen_random_uuid()) as wrong \gset
select tests.throws(format($$select public.reverse_payment(%L, 'x', gen_random_uuid())$$, :'wrong'::jsonb ->> 'payment_id'), 'permission denied',
                    'an accountant without accounting.reverse cannot reverse a payment');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
select public.reverse_payment((:'wrong'::jsonb ->> 'payment_id')::uuid, 'Paid by another customer', gen_random_uuid()) as rev \gset
reset role;
select tests.ok((:'rev'::jsonb ->> 'outstanding')::numeric = :owed_before_return + 1000, 'reversed payment no longer reduces what is owed');

-- ---------------------------------------------------------------------
-- Credit note against the invoice
-- ---------------------------------------------------------------------
set role authenticated;
select public.issue_credit_note(jsonb_build_object('customer_id', :'hotel', 'invoice_id', :'inv', 'net', 100, 'tax_rate', 18,
  'reason', 'Two bottles leaking'), gen_random_uuid()) as cn \gset
reset role;
select tests.ok((:'cn'::jsonb ->> 'total')::numeric = 118 and (:'cn'::jsonb ->> 'outstanding')::numeric = :owed_before_return + 1000 - 118
                and (select balance = :inv_total - round(:inv_total / 2, 2) - 118 from public.invoices where id = :'inv'),
                'credit note of Rs. 118 (incl. VAT) reduces the invoice and what the customer owes');
select tests.ok((select sum(l.debit) filter (where a.system_key = 'sales_returns') = 100 and sum(l.debit) filter (where a.system_key = 'vat_output') = 18
                   from public.journal_lines l join public.accounts a on a.id = l.account_id join public.journal_entries e on e.id = l.entry_id
                  where e.event_type = 'credit_note.issued'), 'credit note posts sales returns and reduces output VAT');

-- ---------------------------------------------------------------------
-- Manual journals need a second person
-- ---------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
select public.submit_manual_journal(app.today(), 'Office tea fund', jsonb_build_array(
  jsonb_build_object('account_id', (select id from public.accounts where system_key = 'exp_office'), 'debit', 750),
  jsonb_build_object('account_id', (select id from public.accounts where system_key = 'petty_cash'), 'credit', 750)), 'Petty cash spend not recorded', gen_random_uuid()) as mj \gset
select tests.throws(format($$select public.submit_manual_journal(app.today(), 'x', jsonb_build_array(
  jsonb_build_object('account_id', (select id from public.accounts where system_key = 'exp_office'), 'debit', 10),
  jsonb_build_object('account_id', (select id from public.accounts where system_key = 'cash'), 'credit', 9)), 'r', gen_random_uuid())$$),
  'not equal', 'an unbalanced manual journal is refused');
select tests.throws(format($$select public.decide_manual_journal(%L, 'approve', null)$$, :'mj'::jsonb ->> 'draft_id'),
                    'someone other', 'you cannot approve your own journal');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
select public.decide_manual_journal((:'mj'::jsonb ->> 'draft_id')::uuid, 'approve', 'Checked receipts') as mjp \gset
reset role;
select tests.ok((:'mjp'::jsonb ->> 'status') = 'posted' and (select status = 'posted' and entry_id is not null from public.journal_drafts
                  where id = (:'mj'::jsonb ->> 'draft_id')::uuid), 'approved journal is posted');

-- ---------------------------------------------------------------------
-- Money: new bank account, transfer, card settlement, bank charge
-- ---------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
select public.save_money_account(null, '{"name":"Sampath current","kind":"bank","bank_name":"Sampath Bank","account_no":"0012 3456 7890"}', 'New bank account') as sampath \gset
select public.record_fund_transfer(jsonb_build_object('kind', 'transfer', 'from_account_id', :'cash', 'to_account_id', :'bank', 'amount', 5000,
  'fee', 25, 'reference', 'Deposit slip 101'), gen_random_uuid());
select public.record_fund_transfer(jsonb_build_object('kind', 'card_settlement', 'to_account_id', :'bank', 'amount', 1000, 'fee', 30,
  'reference', 'Card batch 12'), gen_random_uuid());
select public.record_fund_transfer(jsonb_build_object('kind', 'bank_charge', 'from_account_id', :'bank', 'amount', 150, 'reference', 'Statement fee'), gen_random_uuid());
select tests.throws(format($$select public.record_fund_transfer(jsonb_build_object('kind', 'transfer', 'from_account_id', %L, 'to_account_id', %L, 'amount', 10), gen_random_uuid())$$, :'bank', :'bank'),
                    'two different', 'a transfer needs two different accounts');
reset role;
select tests.ok((select a.code = '1201' and a.name like 'Bank — Sampath%' from public.money_accounts m join public.accounts a on a.id = m.account_id
                  where m.id = :'sampath'), 'a new bank account gets its own ledger account (1201)');
select tests.ok((select sum(l.debit) = 25 + 30 + 150 from public.journal_lines l join public.accounts a on a.id = l.account_id
                  where a.system_key = 'exp_bank_charges'), 'bank charges and card commission are expensed');

-- Bank reconciliation
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
select public.bank_reconciliation_workspace(:'bank', app.today()) as ws \gset
select (select array_agg((x ->> 'line_id')::bigint) from jsonb_array_elements(:'ws'::jsonb -> 'items') x) as all_lines \gset
select (select sum((x ->> 'amount')::numeric) from jsonb_array_elements(:'ws'::jsonb -> 'items') x) as all_sum \gset
select tests.throws(format($$select public.complete_bank_reconciliation(%L, app.today(), %s, %L::bigint[], null, gen_random_uuid())$$,
  :'bank', :all_sum + 10, :'all_lines'), 'difference', 'a reconciliation that does not agree with the statement is refused');
select public.complete_bank_reconciliation(:'bank', app.today(), :all_sum, :'all_lines'::bigint[], 'October statement', gen_random_uuid()) as rec \gset
select tests.ok(jsonb_array_length(public.bank_reconciliation_workspace(:'bank', app.today()) -> 'items') = 0, 'everything ticked is reconciled');
reset role;

-- ---------------------------------------------------------------------
-- Expenses
-- ---------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
select public.record_expense(jsonb_build_object('category_id', (select id from public.expense_categories where code = 'ELECTRICITY'),
  'description', 'CEB bill September', 'payee', 'Ceylon Electricity Board', 'net_amount', 10000, 'pay_method', 'cash', 'money_account_id', :'cash'),
  gen_random_uuid()) as e1 \gset
select tests.throws(format($$select public.record_expense(jsonb_build_object('category_id', (select id from public.expense_categories where code = 'RENT'),
  'description', 'x', 'net_amount', 10, 'pay_method', 'bank_transfer', 'money_account_id', %L), gen_random_uuid())$$, :'cash'),
  'does not match', 'the cash/bank account must match how it was paid');
select public.record_expense(jsonb_build_object('category_id', (select id from public.expense_categories where code = 'RENT'),
  'description', 'Warehouse rent October', 'payee', 'K. Perera', 'net_amount', 40000, 'pay_method', 'on_credit'), gen_random_uuid()) as e2 \gset
select tests.throws(format($$select public.decide_expense(%L, true, 'ok')$$, :'e2'::jsonb ->> 'expense_id'), 'permission denied',
                    'an accountant cannot approve expenses');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
select public.decide_expense((:'e2'::jsonb ->> 'expense_id')::uuid, true, 'Agreed lease');
select public.pay_expense((:'e2'::jsonb ->> 'expense_id')::uuid, :'bank', 'TT 5521', gen_random_uuid());
reset role;
select tests.ok((:'e1'::jsonb ->> 'status') = 'paid' and (:'e2'::jsonb ->> 'status') = 'pending_approval', 'small expense posts at once; large one waits');
select tests.ok((select status = 'paid' from public.expenses where id = (:'e2'::jsonb ->> 'expense_id')::uuid)
                and (select balance = 0 from public.trial_balance(date '2026-01-01', date '2027-12-31') where account_code = '2150'),
                'approved bill paid: expenses payable back to zero');

-- ---------------------------------------------------------------------
-- Chart of accounts, VAT, reports
-- ---------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
select public.save_account(null, jsonb_build_object('code', '6260', 'name', 'Security', 'account_type', 'expense',
  'parent_id', (select id from public.accounts where code = '6000')), 'New account');
select tests.throws(format($$select public.save_account(%L, '{"name":"Cash","account_type":"asset","is_active":false}', 'x')$$,
  (select id from public.accounts where system_key = 'cash')), 'balance', 'an account with a balance cannot be deactivated');
select tests.throws($$select public.file_vat_return(app.today() - 5, app.today(), null, null, gen_random_uuid())$$, 'has ended',
                    'a VAT return is filed only for a finished period');
select tests.ok((select (r ->> 'output_vat')::numeric > 0 from public.report_vat(app.today(), app.today()) r), 'VAT report shows output VAT');
select public.file_vat_return(date '2026-09-01', date '2026-09-30', :'bank', 'IRD ref 0925', gen_random_uuid()) as vr \gset
select tests.ok((:'vr'::jsonb ->> 'return_no') like 'VAT-%', 'VAT return filed for September');
select tests.throws($$select public.file_vat_return(date '2026-09-15', date '2026-09-30', null, 'x', gen_random_uuid())$$, 'already covers',
                    'periods of VAT returns cannot overlap');
select tests.ok((select (r ->> 'opening')::numeric + coalesce((select sum((x ->> 'net')::numeric) from jsonb_array_elements(r -> 'lines') x), 0)
                        = (r ->> 'closing')::numeric from public.report_cash_flow(date '2026-01-01', app.today()) r),
                'cash flow: opening + net movement = closing');
select tests.ok((select (g ->> 'closing')::numeric from public.report_general_ledger((select id from public.accounts where system_key = 'cash'),
                   date '2026-01-01', app.today()) g)
                = (select closing from public.report_trial_balance(date '2026-01-01', app.today()) where code = '1100'),
                'general ledger closing agrees with the trial balance');
select tests.ok((public.accounting_overview() ->> 'journals_waiting')::integer = 0
                and jsonb_array_length(public.accounting_overview() -> 'money') = 5, 'accounting overview lists the five cash and bank accounts');
select tests.ok((select (r -> 'totals' ->> 'assets')::numeric = (r -> 'totals' ->> 'liabilities')::numeric + (r -> 'totals' ->> 'equity')::numeric
                   from public.report_balance_sheet(app.today()) r), 'balance sheet still balances after all Phase 2B flows');
select tests.ok((select sum(closing) = 0 from public.report_trial_balance(date '2026-01-01', app.today())), 'ledger balances after all Phase 2B flows');
reset role;

do $$ begin raise notice 'ALL PHASE 2B DATABASE TESTS PASSED'; end $$;
