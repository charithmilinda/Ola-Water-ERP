-- =====================================================================
-- OLA Water ERP — Phase 2B
-- 0027: cheques received, payment reversals, customer credit notes,
--       transfers between cash/bank accounts, card settlements,
--       bank charges/interest, bank reconciliation, VAT returns
-- =====================================================================

-- Allocations stay append-only: undoing one adds a negative row
alter table public.payment_allocations drop constraint if exists payment_allocations_amount_check;
alter table public.payment_allocations add constraint payment_allocations_amount_check check (amount <> 0);

-- ---------------------------------------------------------------------
-- Cheques received from customers
-- ---------------------------------------------------------------------
alter table public.payments
  add column cheque_status    text check (cheque_status in ('in_hand','deposited','cleared','returned')),
  add column cheque_date      date,
  add column cheque_bank      text,
  add column deposited_at     timestamptz,
  add column deposited_to     uuid references public.money_accounts(id),
  add column cleared_at       timestamptz,
  add column returned_at      timestamptz,
  add column reversal_reason  text,
  add column reversal_entry_id uuid references public.journal_entries(id);
update public.payments set cheque_status = 'in_hand' where method = 'cheque' and status = 'received';

create or replace function app.payment_cheque_defaults()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.method = 'cheque' and new.cheque_status is null then new.cheque_status := 'in_hand'; end if;
  return new;
end $$;
create trigger payments_cheque_defaults before insert on public.payments for each row execute function app.payment_cheque_defaults();

-- Undo every allocation of a payment (invoices become unpaid again)
create or replace function app.unallocate_payment(p_payment uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare a record;
begin
  for a in select invoice_id, sum(amount) amt from public.payment_allocations where payment_id = p_payment group by invoice_id having sum(amount) <> 0 loop
    insert into public.payment_allocations (payment_id, invoice_id, amount) values (p_payment, a.invoice_id, -a.amt);
    perform app.refresh_invoice_status(a.invoice_id);
  end loop;
end $$;

-- Bank a set of cheques on one deposit slip
create or replace function public.deposit_cheques(p_payments uuid[], p_money_account uuid, p_reference text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; m public.money_accounts; pay public.payments; v_total numeric := 0; n integer := 0; v_je uuid; v_res jsonb;
begin
  perform app.require_permission('payments.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'deposit_cheques');
  if v_done is not null then return v_done; end if;
  m := app.money_account(p_money_account);
  if m.kind <> 'bank' then raise exception 'Cheques are deposited into a bank account' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_reference), ''), p_client_txn_id, 'deposit');
  for pay in select * from public.payments where id = any(p_payments) for update loop
    if pay.method <> 'cheque' or pay.cheque_status <> 'in_hand' or pay.status <> 'received' then
      raise exception 'Payment % is not a cheque in hand', pay.payment_no using errcode = '22023';
    end if;
    update public.payments set cheque_status = 'deposited', deposited_at = now(), deposited_to = m.id where id = pay.id;
    v_total := v_total + pay.amount; n := n + 1;
  end loop;
  if n = 0 then raise exception 'Choose the cheques to deposit' using errcode = '22023'; end if;
  v_je := app.post_journal(app.today(), format('Cheque deposit — %s cheque(s)%s', n, coalesce(' — ' || nullif(trim(p_reference), ''), '')),
    'cheque.deposit', jsonb_build_array(
      jsonb_build_object('account_id', m.account_id, 'debit', v_total, 'credit', 0, 'memo', 'Cheques banked'),
      jsonb_build_object('account_key', 'cheques_in_hand', 'debit', 0, 'credit', v_total, 'memo', 'Cheques banked')),
    'cheque_deposit', null);
  v_res := jsonb_build_object('cheques', n, 'total', v_total);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.clear_cheque(p_payment uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare pay public.payments;
begin
  perform app.require_permission('payments.manage');
  select * into pay from public.payments where id = p_payment for update;
  if not found or pay.cheque_status <> 'deposited' then raise exception 'Only a deposited cheque can be marked cleared' using errcode = '22023'; end if;
  perform app.set_context(null, null, 'cheque_cleared');
  update public.payments set cheque_status = 'cleared', cleared_at = now() where id = p_payment;
end $$;

-- A cheque that bounced: the customer owes the money again
create or replace function public.return_cheque(p_payment uuid, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; pay public.payments; v_credit jsonb; v_je uuid; v_res jsonb;
begin
  perform app.require_permission('payments.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'Give the bank''s reason' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'return_cheque');
  if v_done is not null then return v_done; end if;
  select * into pay from public.payments where id = p_payment for update;
  if not found or pay.method <> 'cheque' or pay.status <> 'received' or pay.cheque_status = 'returned' then
    raise exception 'Only a cheque that has not been returned already can be returned' using errcode = '22023';
  end if;
  perform app.set_context(trim(p_reason), p_client_txn_id, 'cheque_returned');
  v_credit := case when pay.cheque_status = 'in_hand'
    then jsonb_build_object('account_key', 'cheques_in_hand', 'debit', 0, 'credit', pay.amount, 'memo', 'Returned cheque')
    else jsonb_build_object('account_id', (select account_id from public.money_accounts where id = pay.deposited_to), 'debit', 0,
                            'credit', pay.amount, 'memo', 'Returned cheque') end;
  v_je := app.post_journal(app.today(), format('Returned cheque %s (%s): %s', pay.payment_no, coalesce(pay.reference, ''), trim(p_reason)),
    'cheque.returned', jsonb_build_array(
      jsonb_build_object('account_key', 'ar', 'debit', pay.amount, 'credit', 0, 'memo', 'Cheque returned — amount owed again',
                         'party_type', 'customer', 'party_id', pay.customer_id),
      v_credit), 'payment', pay.id, pay.location_id);
  perform app.unallocate_payment(pay.id);
  update public.payments set status = 'reversed', cheque_status = 'returned', returned_at = now(), unallocated = 0,
         reversal_reason = trim(p_reason), reversal_entry_id = v_je where id = pay.id;
  v_res := jsonb_build_object('payment_no', pay.payment_no, 'outstanding', app.customer_outstanding(pay.customer_id));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Reverse a payment entered by mistake (wrong customer, wrong amount, duplicate)
create or replace function public.reverse_payment(p_payment uuid, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; pay public.payments; v_lines jsonb; v_je uuid; v_res jsonb; e public.journal_entries;
begin
  perform app.require_permission('payments.manage');
  perform app.require_permission('accounting.reverse');
  if nullif(trim(p_reason), '') is null then raise exception 'Give a reason' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'reverse_payment');
  if v_done is not null then return v_done; end if;
  select * into pay from public.payments where id = p_payment for update;
  if not found or pay.status <> 'received' then raise exception 'This payment is already reversed' using errcode = '22023'; end if;
  if pay.method = 'cheque' and pay.cheque_status in ('deposited','cleared') then
    raise exception 'A banked cheque is handled with "Cheque returned"' using errcode = '22023';
  end if;
  select * into e from public.journal_entries where id = pay.journal_entry_id;
  if not found then raise exception 'The payment''s journal entry was not found' using errcode = 'P0002'; end if;
  perform app.set_context(trim(p_reason), p_client_txn_id, 'reverse_payment');
  select jsonb_agg(jsonb_build_object('account_id', account_id, 'debit', credit, 'credit', debit, 'memo', 'Reversal of ' || pay.payment_no,
           'party_type', party_type, 'party_id', party_id, 'location_id', location_id) order by line_no)
    into v_lines from public.journal_lines where entry_id = e.id;
  v_je := app.post_journal(app.today(), format('Payment %s reversed: %s', pay.payment_no, trim(p_reason)), e.event_type || '.reversal',
    v_lines, 'payment', pay.id, pay.location_id, e.id);
  perform app.unallocate_payment(pay.id);
  update public.payments set status = 'reversed', unallocated = 0, reversal_reason = trim(p_reason), reversal_entry_id = v_je,
         cheque_status = case when method = 'cheque' then 'returned' else cheque_status end
   where id = pay.id;
  v_res := jsonb_build_object('payment_no', pay.payment_no, 'outstanding', app.customer_outstanding(pay.customer_id));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- Customer credit notes (price corrections, returns, recall refunds)
-- ---------------------------------------------------------------------
create table public.credit_notes (
  id               uuid primary key default gen_random_uuid(),
  credit_note_no   text not null unique,
  customer_id      uuid not null references public.customers(id),
  invoice_id       uuid references public.invoices(id),
  credit_date      date not null,
  reason           text not null,
  net              numeric(14,2) not null check (net >= 0),
  tax              numeric(14,2) not null default 0 check (tax >= 0),
  total            numeric(14,2) not null check (total > 0),
  unallocated      numeric(14,2) not null default 0 check (unallocated >= 0),
  journal_entry_id uuid references public.journal_entries(id),
  created_at       timestamptz not null default now(),
  created_by       uuid,
  client_txn_id    uuid unique
);
create index credit_notes_customer_idx on public.credit_notes (customer_id, credit_date desc);
create trigger credit_notes_audit after insert or update on public.credit_notes for each row execute function app.audit_row('sales');
create trigger credit_notes_no_delete before delete on public.credit_notes for each row execute function app.forbid_change();

create table public.credit_note_allocations (
  id              bigint generated always as identity primary key,
  credit_note_id  uuid not null references public.credit_notes(id),
  invoice_id      uuid not null references public.invoices(id),
  amount          numeric(14,2) not null check (amount > 0),
  created_at      timestamptz not null default now()
);
create index credit_note_allocations_invoice_idx on public.credit_note_allocations (invoice_id);
create trigger credit_note_allocations_append_only before update or delete on public.credit_note_allocations
  for each row execute function app.forbid_change();

-- Invoices are settled by payments and by credit notes
create or replace function app.refresh_invoice_status(p_invoice uuid)
returns void language sql security definer set search_path = '' as $$
  update public.invoices i set
    amount_paid = coalesce((select sum(amount) from public.payment_allocations where invoice_id = i.id), 0)
                + coalesce((select sum(amount) from public.credit_note_allocations where invoice_id = i.id), 0),
    status = case
      when i.status = 'void' then 'void'
      when i.total <= 0 then 'credit'
      when coalesce((select sum(amount) from public.payment_allocations where invoice_id = i.id), 0)
         + coalesce((select sum(amount) from public.credit_note_allocations where invoice_id = i.id), 0) >= i.total then 'paid'
      when coalesce((select sum(amount) from public.payment_allocations where invoice_id = i.id), 0)
         + coalesce((select sum(amount) from public.credit_note_allocations where invoice_id = i.id), 0) > 0 then 'partially_paid'
      else 'open' end
  where i.id = p_invoice
$$;

create or replace function app.customer_outstanding(p_customer uuid)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce((select sum(total) from public.invoices where customer_id = p_customer and status <> 'void'), 0)
       - coalesce((select sum(case when direction = 'in' then amount else -amount end)
                     from public.payments where customer_id = p_customer and status = 'received'), 0)
       - coalesce((select sum(total) from public.credit_notes where customer_id = p_customer), 0)
$$;

-- Apply a customer's unused credit (credit notes) to open invoices, oldest first
create or replace function app.apply_customer_credit(p_customer uuid, p_first_invoice uuid default null)
returns numeric language plpgsql security definer set search_path = '' as $$
declare cn record; inv record; v_take numeric; v_done numeric := 0;
begin
  for cn in select id, unallocated from public.credit_notes where customer_id = p_customer and unallocated > 0 order by credit_date, created_at for update loop
    for inv in select id, balance from public.invoices
                where customer_id = p_customer and status in ('open','partially_paid') and balance > 0
                order by (id = p_first_invoice) desc, invoice_date, created_at for update loop
      exit when cn.unallocated <= 0;
      v_take := least(cn.unallocated, inv.balance);
      insert into public.credit_note_allocations (credit_note_id, invoice_id, amount) values (cn.id, inv.id, v_take);
      perform app.refresh_invoice_status(inv.id);
      cn.unallocated := cn.unallocated - v_take; v_done := v_done + v_take;
    end loop;
    update public.credit_notes set unallocated = cn.unallocated where id = cn.id;
  end loop;
  return v_done;
end $$;

--   p: {customer_id, invoice_id?, net, tax_rate?, reason}
create or replace function public.issue_credit_note(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; c public.customers; inv public.invoices; v uuid := gen_random_uuid(); v_no text; v_net numeric := round(app.jnum(p, 'net'), 2);
        v_rate numeric := coalesce(app.jnum(p, 'tax_rate'), 0); v_tax numeric; v_total numeric; v_je uuid; v_res jsonb;
begin
  perform app.require_permission('payments.manage');
  if not (app.has_permission('customers.credit') or app.has_permission('accounting.manual_journal')) then
    raise exception 'Permission denied: credit notes need customers.credit or accounting.manual_journal' using errcode = '42501';
  end if;
  if coalesce(v_net, 0) <= 0 then raise exception 'Enter the amount to credit' using errcode = '22023'; end if;
  if nullif(trim(app.jtext(p, 'reason')), '') is null then raise exception 'Give the reason for the credit' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'issue_credit_note');
  if v_done is not null then return v_done; end if;
  select * into c from public.customers where id = app.juuid(p, 'customer_id');
  if not found then raise exception 'Customer not found' using errcode = 'P0002'; end if;
  if app.juuid(p, 'invoice_id') is not null then
    select * into inv from public.invoices where id = app.juuid(p, 'invoice_id') and customer_id = c.id;
    if not found or inv.status = 'void' then raise exception 'Invoice not found for this customer' using errcode = 'P0002'; end if;
    if v_net > inv.subtotal_net + inv.other_charges then raise exception 'The credit is more than the invoice' using errcode = '22023'; end if;
  end if;
  v_tax := round(v_net * v_rate / 100, 2);
  v_total := v_net + v_tax;
  perform app.set_context(trim(app.jtext(p, 'reason')), p_client_txn_id, 'credit_note');
  v_no := app.next_document_number('CN');
  insert into public.credit_notes (id, credit_note_no, customer_id, invoice_id, credit_date, reason, net, tax, total, unallocated, created_by, client_txn_id)
  values (v, v_no, c.id, inv.id, app.today(), trim(app.jtext(p, 'reason')), v_net, v_tax, v_total, v_total, app.current_user_id(), p_client_txn_id);
  v_je := app.post_journal(app.today(), format('Credit note %s to %s: %s', v_no, c.name, trim(app.jtext(p, 'reason'))), 'credit_note.issued',
    jsonb_build_array(
      jsonb_build_object('account_key', 'sales_returns', 'debit', v_net, 'credit', 0, 'memo', 'Sales credited'),
      jsonb_build_object('account_key', 'vat_output', 'debit', v_tax, 'credit', 0, 'memo', 'VAT credited'),
      jsonb_build_object('account_key', 'ar', 'debit', 0, 'credit', v_total, 'memo', 'Credit to customer', 'party_type', 'customer', 'party_id', c.id))
    - (case when v_tax = 0 then 1 else 3 end),  -- drop the VAT line when there is no VAT
    'credit_note', v, inv.location_id);
  update public.credit_notes set journal_entry_id = v_je where id = v;
  perform app.apply_customer_credit(c.id, inv.id);
  v_res := jsonb_build_object('credit_note_id', v, 'credit_note_no', v_no, 'total', v_total,
                              'unused_credit', (select unallocated from public.credit_notes where id = v),
                              'outstanding', app.customer_outstanding(c.id));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.apply_customer_credit(p_customer uuid)
returns numeric language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_permission('payments.manage');
  perform app.set_context('Apply customer credit', null, 'apply_credit');
  return app.apply_customer_credit(p_customer);
end $$;

-- ---------------------------------------------------------------------
-- Moving money between cash and bank accounts
-- ---------------------------------------------------------------------
create table public.fund_transfers (
  id               uuid primary key default gen_random_uuid(),
  transfer_no      text not null unique,
  kind             text not null check (kind in ('transfer','card_settlement','bank_charge','bank_interest')),
  from_account_id  uuid references public.money_accounts(id),
  to_account_id    uuid references public.money_accounts(id),
  amount           numeric(16,2) not null check (amount > 0),
  fee              numeric(16,2) not null default 0 check (fee >= 0),
  transfer_date    date not null,
  reference        text,
  notes            text,
  journal_entry_id uuid references public.journal_entries(id),
  created_at       timestamptz not null default now(),
  created_by       uuid,
  client_txn_id    uuid unique
);
create trigger fund_transfers_audit after insert on public.fund_transfers for each row execute function app.audit_row('accounting');
create trigger fund_transfers_append_only before update or delete on public.fund_transfers for each row execute function app.forbid_change();

--   kind 'transfer':        from → to (cash banked, petty cash top-up, bank to bank); fee = bank charge on top
--   kind 'card_settlement': card/QR clearing → bank; amount = sales settled, fee = commission deducted by the bank
--   kind 'bank_charge':     charge on the statement (from = bank)
--   kind 'bank_interest':   interest credited (to = bank)
create or replace function public.record_fund_transfer(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; v_kind text := app.jtext(p, 'kind'); f public.money_accounts; t public.money_accounts; v_amt numeric := round(app.jnum(p, 'amount'), 2);
  v_fee numeric := round(coalesce(app.jnum(p, 'fee'), 0), 2); v_date date := coalesce((app.jtext(p, 'date'))::date, app.today());
  v uuid := gen_random_uuid(); v_no text; v_lines jsonb; v_je uuid; v_res jsonb; v_desc text;
begin
  perform app.require_permission('payments.manage');
  if coalesce(v_amt, 0) <= 0 then raise exception 'Enter the amount' using errcode = '22023'; end if;
  if v_fee < 0 then raise exception 'The fee cannot be negative' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'record_fund_transfer');
  if v_done is not null then return v_done; end if;
  if v_kind in ('transfer','bank_charge') then f := app.money_account(app.juuid(p, 'from_account_id')); end if;
  if v_kind in ('transfer','card_settlement','bank_interest') then t := app.money_account(app.juuid(p, 'to_account_id')); end if;
  if v_kind = 'card_settlement' then
    select * into f from public.money_accounts where kind = 'card_clearing' and is_default;
    if t.kind <> 'bank' then raise exception 'Card settlements are paid into a bank account' using errcode = '22023'; end if;
    if v_fee >= v_amt then raise exception 'The commission must be less than the amount settled' using errcode = '22023'; end if;
  end if;
  if v_kind = 'transfer' and f.id = t.id then raise exception 'Choose two different accounts' using errcode = '22023'; end if;
  if v_kind in ('bank_charge','bank_interest') and coalesce(f.kind, t.kind) <> 'bank' then
    raise exception 'Bank charges and interest belong to a bank account' using errcode = '22023';
  end if;

  v_lines := case v_kind
    when 'transfer' then jsonb_build_array(
      jsonb_build_object('account_id', t.account_id, 'debit', v_amt, 'credit', 0, 'memo', 'Transfer in'),
      jsonb_build_object('account_key', 'exp_bank_charges', 'debit', v_fee, 'credit', 0, 'memo', 'Bank charge'),
      jsonb_build_object('account_id', f.account_id, 'debit', 0, 'credit', v_amt + v_fee, 'memo', 'Transfer out'))
    when 'card_settlement' then jsonb_build_array(
      jsonb_build_object('account_id', t.account_id, 'debit', v_amt - v_fee, 'credit', 0, 'memo', 'Card / QR settlement'),
      jsonb_build_object('account_key', 'exp_bank_charges', 'debit', v_fee, 'credit', 0, 'memo', 'Card commission'),
      jsonb_build_object('account_id', f.account_id, 'debit', 0, 'credit', v_amt, 'memo', 'Card / QR sales settled'))
    when 'bank_charge' then jsonb_build_array(
      jsonb_build_object('account_key', 'exp_bank_charges', 'debit', v_amt, 'credit', 0, 'memo', 'Bank charge'),
      jsonb_build_object('account_id', f.account_id, 'debit', 0, 'credit', v_amt, 'memo', 'Bank charge'))
    when 'bank_interest' then jsonb_build_array(
      jsonb_build_object('account_id', t.account_id, 'debit', v_amt, 'credit', 0, 'memo', 'Interest credited'),
      jsonb_build_object('account_key', 'interest_income', 'debit', 0, 'credit', v_amt, 'memo', 'Interest income'))
    else null end;
  if v_lines is null then raise exception 'Unknown kind of transfer' using errcode = '22023'; end if;
  select jsonb_agg(x) into v_lines from jsonb_array_elements(v_lines) x where (x ->> 'debit')::numeric > 0 or (x ->> 'credit')::numeric > 0;

  perform app.set_context(coalesce(nullif(trim(app.jtext(p, 'notes')), ''), nullif(trim(app.jtext(p, 'reference')), '')), p_client_txn_id, v_kind);
  v_no := app.next_document_number('FT');
  v_desc := case v_kind when 'transfer' then format('%s → %s', f.name, t.name)
                        when 'card_settlement' then format('Card / QR settlement into %s', t.name)
                        when 'bank_charge' then format('Bank charge — %s', f.name)
                        else format('Interest — %s', t.name) end
            || coalesce(' (' || nullif(trim(app.jtext(p, 'reference')), '') || ')', '');
  v_je := app.post_journal(v_date, v_no || ': ' || v_desc, 'funds.' || v_kind, v_lines, 'fund_transfer', v);
  insert into public.fund_transfers (id, transfer_no, kind, from_account_id, to_account_id, amount, fee, transfer_date, reference, notes,
    journal_entry_id, created_by, client_txn_id)
  values (v, v_no, v_kind, f.id, t.id, v_amt, v_fee, v_date, nullif(trim(app.jtext(p, 'reference')), ''), app.jtext(p, 'notes'), v_je,
    app.current_user_id(), p_client_txn_id);
  v_res := jsonb_build_object('transfer_id', v, 'transfer_no', v_no);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- Bank reconciliation
-- ---------------------------------------------------------------------
create table public.bank_reconciliations (
  id                 uuid primary key default gen_random_uuid(),
  money_account_id   uuid not null references public.money_accounts(id),
  statement_date     date not null,
  statement_balance  numeric(16,2) not null,
  book_balance       numeric(16,2) not null,
  items_cleared      integer not null,
  notes              text,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  client_txn_id      uuid unique,
  unique (money_account_id, statement_date)
);
create trigger bank_reconciliations_audit after insert on public.bank_reconciliations for each row execute function app.audit_row('accounting');
create trigger bank_reconciliations_append_only before update or delete on public.bank_reconciliations for each row execute function app.forbid_change();

create table public.bank_reconciliation_items (
  reconciliation_id  uuid not null references public.bank_reconciliations(id),
  journal_line_id    bigint not null unique references public.journal_lines(id),
  primary key (reconciliation_id, journal_line_id)
);
create trigger bank_reconciliation_items_append_only before update or delete on public.bank_reconciliation_items
  for each row execute function app.forbid_change();

-- What still has to be ticked off for a bank account
create or replace function public.bank_reconciliation_workspace(p_money_account uuid, p_statement_date date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare m public.money_accounts; v jsonb;
begin
  if not (app.has_permission('payments.manage') or app.has_permission('accounting.view')) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  select * into m from public.money_accounts where id = p_money_account;
  if not found then raise exception 'Account not found' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'account', jsonb_build_object('id', m.id, 'name', m.name, 'kind', m.kind, 'bank_name', m.bank_name, 'account_no', m.account_no),
    'book_balance', coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                               where l.account_id = m.account_id and e.entry_date <= p_statement_date), 0),
    'cleared_balance', coalesce((select sum(l.debit - l.credit) from public.journal_lines l
                                  join public.bank_reconciliation_items i on i.journal_line_id = l.id where l.account_id = m.account_id), 0),
    'last', (select jsonb_build_object('statement_date', statement_date, 'statement_balance', statement_balance, 'created_at', created_at)
               from public.bank_reconciliations where money_account_id = m.id order by statement_date desc limit 1),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('line_id', l.id, 'date', e.entry_date, 'entry_no', e.entry_no,
                'description', e.description, 'memo', l.memo, 'amount', l.debit - l.credit) order by e.entry_date, l.id), '[]')
                from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
               where l.account_id = m.account_id and e.entry_date <= p_statement_date
                 and not exists (select 1 from public.bank_reconciliation_items i where i.journal_line_id = l.id))
  ) into v;
  return v;
end $$;

create or replace function public.complete_bank_reconciliation(p_money_account uuid, p_statement_date date, p_statement_balance numeric,
  p_line_ids bigint[], p_notes text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; m public.money_accounts; v uuid := gen_random_uuid(); v_cleared numeric; v_book numeric; n integer; v_res jsonb;
begin
  perform app.require_permission('payments.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'complete_bank_reconciliation');
  if v_done is not null then return v_done; end if;
  m := app.money_account(p_money_account);
  if exists (select 1 from public.bank_reconciliations where money_account_id = m.id and statement_date >= p_statement_date) then
    raise exception 'A reconciliation on or after % already exists for this account', p_statement_date using errcode = '22023';
  end if;
  if exists (select 1 from unnest(coalesce(p_line_ids, '{}')) x
              where not exists (select 1 from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                                 where l.id = x and l.account_id = m.account_id and e.entry_date <= p_statement_date)
                 or exists (select 1 from public.bank_reconciliation_items i where i.journal_line_id = x)) then
    raise exception 'Some ticked items do not belong to this account or were reconciled before' using errcode = '22023';
  end if;
  select coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.bank_reconciliation_items i on i.journal_line_id = l.id
                    where l.account_id = m.account_id), 0)
       + coalesce((select sum(debit - credit) from public.journal_lines where id = any(coalesce(p_line_ids, '{}'))), 0)
    into v_cleared;
  if round(v_cleared, 2) <> round(p_statement_balance, 2) then
    raise exception 'The ticked items add up to %, but the statement says % (difference %). Find the difference before saving.',
      round(v_cleared, 2), round(p_statement_balance, 2), round(p_statement_balance - v_cleared, 2) using errcode = '22023';
  end if;
  select coalesce(sum(l.debit - l.credit), 0) into v_book from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
   where l.account_id = m.account_id and e.entry_date <= p_statement_date;
  perform app.set_context(nullif(trim(p_notes), ''), p_client_txn_id, 'reconcile');
  n := coalesce(array_length(p_line_ids, 1), 0);
  insert into public.bank_reconciliations (id, money_account_id, statement_date, statement_balance, book_balance, items_cleared, notes, created_by, client_txn_id)
  values (v, m.id, p_statement_date, round(p_statement_balance, 2), v_book, n, nullif(trim(p_notes), ''), app.current_user_id(), p_client_txn_id);
  insert into public.bank_reconciliation_items (reconciliation_id, journal_line_id) select v, x from unnest(coalesce(p_line_ids, '{}')) x;
  v_res := jsonb_build_object('reconciliation_id', v, 'items', n, 'book_balance', v_book, 'outstanding', v_book - p_statement_balance);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- VAT returns
-- ---------------------------------------------------------------------
create table public.vat_returns (
  id                uuid primary key default gen_random_uuid(),
  return_no         text not null unique,
  period_from       date not null,
  period_to         date not null,
  output_vat        numeric(16,2) not null,
  input_vat         numeric(16,2) not null,
  net_payable       numeric(16,2) not null,
  money_account_id  uuid references public.money_accounts(id),
  reference         text,
  journal_entry_id  uuid references public.journal_entries(id),
  created_at        timestamptz not null default now(),
  created_by        uuid,
  client_txn_id     uuid unique,
  check (period_to >= period_from),
  exclude using gist (daterange(period_from, period_to, '[]') with &&)
);
create trigger vat_returns_audit after insert on public.vat_returns for each row execute function app.audit_row('accounting');
create trigger vat_returns_append_only before update or delete on public.vat_returns for each row execute function app.forbid_change();

create or replace function app.vat_totals(p_from date, p_to date, out output_vat numeric, out input_vat numeric)
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(case when a.system_key = 'vat_output' then l.credit - l.debit else 0 end), 0),
         coalesce(sum(case when a.system_key = 'vat_input' then l.debit - l.credit else 0 end), 0)
    from public.journal_lines l
    join public.journal_entries e on e.id = l.entry_id
    join public.accounts a on a.id = l.account_id
   where a.system_key in ('vat_output','vat_input') and e.entry_date between p_from and p_to and e.event_type <> 'vat.settlement'
$$;

create or replace function public.file_vat_return(p_from date, p_to date, p_money_account uuid, p_reference text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; t record; m public.money_accounts; v uuid := gen_random_uuid(); v_no text; v_net numeric; v_lines jsonb; v_je uuid; v_res jsonb;
begin
  perform app.require_permission('accounting.period_close');
  v_done := app.idempotency_begin(p_client_txn_id, 'file_vat_return');
  if v_done is not null then return v_done; end if;
  if p_to >= app.today() then raise exception 'File a VAT return only for a period that has ended' using errcode = '22023'; end if;
  -- settle everything recorded up to the end of the period, including input VAT carried forward
  select coalesce(sum(case when a.system_key = 'vat_output' then l.credit - l.debit else 0 end), 0) as output_vat,
         coalesce(sum(case when a.system_key = 'vat_input' then l.debit - l.credit else 0 end), 0) as input_vat
    into t
    from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
   where a.system_key in ('vat_output','vat_input') and e.entry_date <= p_to;
  if exists (select 1 from public.vat_returns where period_to >= p_from) then
    raise exception 'A VAT return already covers part of this period — start after the last return' using errcode = '22023';
  end if;
  v_net := round(t.output_vat - t.input_vat, 2);
  if v_net > 0 then
    m := app.money_account(p_money_account);
    if nullif(trim(p_reference), '') is null then raise exception 'Enter the payment reference' using errcode = '22023'; end if;
  end if;
  perform app.set_context(coalesce(nullif(trim(p_reference), ''), 'VAT return'), p_client_txn_id, 'vat_return');
  v_no := app.next_document_number('VAT');
  -- clear the period's VAT: output and input are netted; anything due is paid from the bank,
  -- excess input VAT stays in VAT Input as a credit carried forward
  v_lines := jsonb_build_array(
    jsonb_build_object('account_key', 'vat_output', 'debit', greatest(t.output_vat, 0), 'credit', 0, 'memo', 'Output VAT for the period'),
    jsonb_build_object('account_key', 'vat_input', 'debit', 0, 'credit', least(greatest(t.input_vat, 0), greatest(t.output_vat, 0)), 'memo', 'Input VAT claimed'));
  if v_net > 0 then
    v_lines := v_lines || jsonb_build_object('account_id', m.account_id, 'debit', 0, 'credit', v_net, 'memo', 'VAT paid');
  end if;
  select jsonb_agg(x) into v_lines from jsonb_array_elements(v_lines) x where (x ->> 'debit')::numeric > 0 or (x ->> 'credit')::numeric > 0;
  if jsonb_array_length(coalesce(v_lines, '[]')) >= 2 then
    v_je := app.post_journal(app.today(), format('VAT return %s for %s to %s', v_no, p_from, p_to), 'vat.settlement', v_lines, 'vat_return', v);
  end if;
  insert into public.vat_returns (id, return_no, period_from, period_to, output_vat, input_vat, net_payable, money_account_id, reference,
    journal_entry_id, created_by, client_txn_id)
  values (v, v_no, p_from, p_to, t.output_vat, t.input_vat, v_net, m.id, nullif(trim(p_reference), ''), v_je, app.current_user_id(), p_client_txn_id);
  v_res := jsonb_build_object('return_no', v_no, 'output_vat', t.output_vat, 'input_vat', t.input_vat, 'net_payable', v_net);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.credit_notes              enable row level security;
alter table public.credit_note_allocations   enable row level security;
alter table public.fund_transfers            enable row level security;
alter table public.bank_reconciliations      enable row level security;
alter table public.bank_reconciliation_items enable row level security;
alter table public.vat_returns               enable row level security;
create policy credit_notes_read on public.credit_notes for select to authenticated
  using (app.has_permission('payments.view') or app.has_permission('customers.view'));
create policy credit_note_allocations_read on public.credit_note_allocations for select to authenticated
  using (app.has_permission('payments.view') or app.has_permission('customers.view'));
create policy fund_transfers_read on public.fund_transfers for select to authenticated
  using (app.has_permission('accounting.view') or app.has_permission('payments.manage'));
create policy bank_reconciliations_read on public.bank_reconciliations for select to authenticated
  using (app.has_permission('accounting.view') or app.has_permission('payments.manage'));
create policy bank_reconciliation_items_read on public.bank_reconciliation_items for select to authenticated
  using (app.has_permission('accounting.view') or app.has_permission('payments.manage'));
create policy vat_returns_read on public.vat_returns for select to authenticated using (app.has_permission('accounting.view'));
revoke insert, update, delete, truncate on public.fund_transfers, public.bank_reconciliations, public.bank_reconciliation_items,
  public.vat_returns, public.credit_note_allocations from anon, authenticated, service_role;
