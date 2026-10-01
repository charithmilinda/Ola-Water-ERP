-- OLA Water ERP — Phase 2B database update (accounting, banking, cheques, expenses, VAT)
-- Run ONCE in Supabase → SQL Editor → New query, on the database that already has Phase 2A.
-- It runs as one transaction: if anything fails, nothing is changed.
begin;

-- >>> 20261005000026_accounting_setup.sql
-- =====================================================================
-- OLA Water ERP — Phase 2B
-- 0026: money accounts, chart-of-accounts maintenance, accounting years,
--       manual journals with approval
-- =====================================================================

-- ---------------------------------------------------------------------
-- Money accounts: cash, petty cash, bank accounts, card clearing.
-- Each one is a ledger account; payments, transfers and the bank
-- reconciliation work against them.
-- ---------------------------------------------------------------------
create table public.money_accounts (
  id           uuid primary key default gen_random_uuid(),
  name         text not null check (length(trim(name)) > 0),
  kind         text not null check (kind in ('cash','petty_cash','bank','card_clearing')),
  bank_name    text,
  branch       text,
  account_no   text,
  account_id   uuid not null unique references public.accounts(id),
  is_default   boolean not null default false,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create unique index money_accounts_one_default on public.money_accounts (kind) where is_default;
create trigger money_accounts_touch before update on public.money_accounts for each row execute function app.touch_updated_at();
create trigger money_accounts_audit after insert or update on public.money_accounts for each row execute function app.audit_row('accounting');

insert into public.money_accounts (name, kind, account_id, is_default)
select v.name, v.kind, (select id from public.accounts where system_key = v.key), true
  from (values ('Cash in hand', 'cash', 'cash'), ('Petty cash', 'petty_cash', 'petty_cash'),
               ('Main bank account', 'bank', 'bank'), ('Card / QR settlements', 'card_clearing', 'card_clearing')) as v(name, kind, key);

create or replace function app.money_account(p_id uuid)
returns public.money_accounts language plpgsql stable security definer set search_path = '' as $$
declare m public.money_accounts;
begin
  select * into m from public.money_accounts where id = p_id and is_active;
  if not found then raise exception 'Choose a cash or bank account' using errcode = '22023'; end if;
  return m;
end $$;

create or replace function public.save_money_account(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; v_kind text := app.jtext(p, 'kind'); v_code text; v_acc uuid; v_name text := trim(app.jtext(p, 'name'));
begin
  perform app.require_permission('accounting.period_close');
  if nullif(v_name, '') is null then raise exception 'Enter a name' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    if v_kind not in ('bank','petty_cash','cash') then raise exception 'Choose bank, cash or petty cash' using errcode = '22023'; end if;
    -- a ledger account of its own, numbered after the existing cash and bank accounts
    select (max(code::integer) + 1)::text into v_code from public.accounts
     where code ~ '^[0-9]{4}$' and code::integer between (case when v_kind = 'bank' then 1200 else 1100 end)
                                                    and (case when v_kind = 'bank' then 1209 else 1119 end);
    if v_code is null or v_code::integer > (case when v_kind = 'bank' then 1209 else 1119 end) then
      raise exception 'No free account code left for a new % account — add the ledger account in the chart first', v_kind using errcode = '22023';
    end if;
    insert into public.accounts (code, name, account_type, parent_id)
    values (v_code, case when v_kind = 'bank' then 'Bank — ' else '' end || v_name, 'asset', (select id from public.accounts where code = '1000'))
    returning id into v_acc;
    insert into public.money_accounts (name, kind, bank_name, branch, account_no, account_id)
    values (v_name, v_kind, app.jtext(p, 'bank_name'), app.jtext(p, 'branch'), app.jtext(p, 'account_no'), v_acc)
    returning id into v;
  else
    update public.money_accounts set name = v_name, bank_name = app.jtext(p, 'bank_name'), branch = app.jtext(p, 'branch'),
           account_no = app.jtext(p, 'account_no'), is_active = app.jbool(p, 'is_active', true)
     where id = p_id returning id into v;
    if v is null then raise exception 'Account not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Chart of accounts maintenance
-- ---------------------------------------------------------------------
create or replace function public.save_account(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare a public.accounts; v uuid; v_used boolean; v_bal numeric; v_parent uuid := app.juuid(p, 'parent_id');
begin
  perform app.require_permission('accounting.period_close');
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if v_parent is not null and not exists (select 1 from public.accounts where id = v_parent and not is_postable) then
    raise exception 'A parent must be a heading account (not postable)' using errcode = '22023';
  end if;
  if p_id is null then
    insert into public.accounts (code, name, account_type, parent_id, is_postable, description)
    values (trim(app.jtext(p, 'code')), trim(app.jtext(p, 'name')), app.jtext(p, 'account_type'), v_parent,
            app.jbool(p, 'is_postable', true), app.jtext(p, 'description'))
    returning id into v;
  else
    select * into a from public.accounts where id = p_id for update;
    if not found then raise exception 'Account not found' using errcode = 'P0002'; end if;
    v_used := exists (select 1 from public.journal_lines where account_id = a.id);
    select coalesce(sum(debit - credit), 0) into v_bal from public.journal_lines where account_id = a.id;
    if v_used and app.jtext(p, 'account_type') is distinct from a.account_type then
      raise exception 'The type of an account with postings cannot change' using errcode = '22023';
    end if;
    if not app.jbool(p, 'is_active', true) and v_bal <> 0 then
      raise exception 'Only an account with a zero balance can be deactivated (balance %)', v_bal using errcode = '22023';
    end if;
    if not app.jbool(p, 'is_active', true) and a.system_key is not null then
      raise exception 'This account is used by automatic postings and cannot be deactivated' using errcode = '22023';
    end if;
    if not app.jbool(p, 'is_postable', true) and v_used then
      raise exception 'An account with postings must stay postable' using errcode = '22023';
    end if;
    update public.accounts set name = trim(app.jtext(p, 'name')), account_type = app.jtext(p, 'account_type'), parent_id = v_parent,
           is_postable = app.jbool(p, 'is_postable', true), is_active = app.jbool(p, 'is_active', true),
           description = app.jtext(p, 'description')
     where id = p_id returning id into v;
  end if;
  return v;
end $$;


-- Open the next financial year's monthly periods
create or replace function public.open_accounting_year(p_year integer)
returns integer language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_permission('accounting.period_close');
  if p_year < 2020 or p_year > 2100 then raise exception 'Enter a valid year' using errcode = '22023'; end if;
  perform app.set_context('Open accounting year ' || p_year, null, 'open_year');
  return public.ensure_accounting_year(p_year);
end $$;

-- ---------------------------------------------------------------------
-- Manual journals: prepared by one person, approved by another
-- ---------------------------------------------------------------------
create table public.journal_drafts (
  id             uuid primary key default gen_random_uuid(),
  draft_no       text not null unique,
  entry_date     date not null,
  description    text not null,
  lines          jsonb not null,
  total          numeric(16,2) not null,
  reason         text not null,
  status         text not null default 'pending' check (status in ('pending','posted','rejected','withdrawn')),
  created_at     timestamptz not null default now(),
  created_by     uuid,
  decided_at     timestamptz,
  decided_by     uuid,
  decision_note  text,
  entry_id       uuid references public.journal_entries(id),
  updated_at     timestamptz not null default now(),
  client_txn_id  uuid unique
);
create trigger journal_drafts_touch before update on public.journal_drafts for each row execute function app.touch_updated_at();
create trigger journal_drafts_audit after insert or update on public.journal_drafts for each row execute function app.audit_row('accounting');

-- Check the lines of a manual journal: balanced, postable accounts, one side per line
create or replace function app.check_journal_lines(p_lines jsonb)
returns numeric language plpgsql stable security definer set search_path = '' as $$
declare l jsonb; v_d numeric := 0; v_c numeric := 0; a public.accounts; n integer := 0; d numeric; c numeric;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'A journal needs at least two lines' using errcode = '22023';
  end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    select * into a from public.accounts where id = app.juuid(l, 'account_id');
    if not found then raise exception 'Line %: choose an account', n using errcode = '22023'; end if;
    if not a.is_postable or not a.is_active then raise exception 'Line %: % % cannot be posted to', n, a.code, a.name using errcode = '22023'; end if;
    d := round(coalesce(app.jnum(l, 'debit'), 0), 2); c := round(coalesce(app.jnum(l, 'credit'), 0), 2);
    if d < 0 or c < 0 or (d > 0) = (c > 0) then raise exception 'Line %: enter either a debit or a credit', n using errcode = '22023'; end if;
    v_d := v_d + d; v_c := v_c + c;
  end loop;
  if v_d <> v_c then raise exception 'Debits (%) and credits (%) are not equal', v_d, v_c using errcode = '22023'; end if;
  return v_d;
end $$;

create or replace function public.submit_manual_journal(p_entry_date date, p_description text, p_lines jsonb, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v uuid := gen_random_uuid(); v_no text; v_total numeric; v_res jsonb; v_period public.accounting_periods;
begin
  perform app.require_permission('accounting.manual_journal');
  if nullif(trim(p_reason), '') is null then raise exception 'Explain why this journal is needed' using errcode = '22023'; end if;
  if nullif(trim(p_description), '') is null then raise exception 'Enter a description' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'submit_manual_journal');
  if v_done is not null then return v_done; end if;
  v_total := app.check_journal_lines(p_lines);
  select * into v_period from public.accounting_periods where p_entry_date between starts_on and ends_on;
  if not found then raise exception 'No accounting period exists for %', p_entry_date using errcode = 'P0002'; end if;
  if v_period.status <> 'open' then raise exception 'Period % is closed — date the journal in an open period', v_period.name using errcode = 'P0001'; end if;
  perform app.set_context(trim(p_reason), p_client_txn_id, 'submit');
  v_no := app.next_document_number('MJ');
  insert into public.journal_drafts (id, draft_no, entry_date, description, lines, total, reason, created_by, client_txn_id)
  values (v, v_no, p_entry_date, trim(p_description), p_lines, v_total, trim(p_reason), app.current_user_id(), p_client_txn_id);
  v_res := jsonb_build_object('draft_id', v, 'draft_no', v_no, 'total', v_total);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.decide_manual_journal(p_id uuid, p_decision text, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare j public.journal_drafts; v_entry uuid; v_lines jsonb;
begin
  select * into j from public.journal_drafts where id = p_id for update;
  if not found then raise exception 'Journal not found' using errcode = 'P0002'; end if;
  if j.status <> 'pending' then raise exception 'This journal has already been decided' using errcode = '22023'; end if;
  if p_decision = 'withdraw' then
    if j.created_by is distinct from app.current_user_id() then raise exception 'Only the person who prepared it can withdraw it' using errcode = '42501'; end if;
    perform app.set_context(coalesce(nullif(trim(p_note), ''), 'Withdrawn'), null, 'withdraw');
    update public.journal_drafts set status = 'withdrawn', decided_at = now(), decided_by = app.current_user_id(), decision_note = nullif(trim(p_note), '')
     where id = p_id;
    return jsonb_build_object('status', 'withdrawn');
  end if;
  perform app.require_permission('accounting.manual_journal');
  if j.created_by = app.current_user_id() and not app.is_super_admin(app.current_user_id()) then
    raise exception 'A manual journal must be approved by someone other than the person who prepared it' using errcode = '42501';
  end if;
  if p_decision = 'reject' then
    if nullif(trim(p_note), '') is null then raise exception 'Give a reason for rejecting' using errcode = '22023'; end if;
    perform app.set_context(trim(p_note), null, 'reject');
    update public.journal_drafts set status = 'rejected', decided_at = now(), decided_by = app.current_user_id(), decision_note = trim(p_note)
     where id = p_id;
    return jsonb_build_object('status', 'rejected');
  elsif p_decision <> 'approve' then
    raise exception 'Unknown decision' using errcode = '22023';
  end if;
  perform app.check_journal_lines(j.lines);
  perform app.set_context(j.reason || coalesce(' — approved: ' || nullif(trim(p_note), ''), ''), j.client_txn_id, 'approve');
  select jsonb_agg(jsonb_build_object('account_id', x ->> 'account_id', 'debit', coalesce((x ->> 'debit')::numeric, 0),
           'credit', coalesce((x ->> 'credit')::numeric, 0), 'memo', x ->> 'memo',
           'party_type', nullif(x ->> 'party_type', ''), 'party_id', nullif(x ->> 'party_id', '')))
    into v_lines from jsonb_array_elements(j.lines) x;
  v_entry := app.post_journal(j.entry_date, j.description, 'manual.journal', v_lines, 'manual_journal', j.id);
  update public.journal_drafts set status = 'posted', decided_at = now(), decided_by = app.current_user_id(),
         decision_note = nullif(trim(p_note), ''), entry_id = v_entry where id = p_id;
  return jsonb_build_object('status', 'posted', 'entry_no', (select entry_no from public.journal_entries where id = v_entry));
end $$;

-- Direct posting (no second person) is kept only for finance managers
create or replace function public.post_manual_journal(
  p_entry_date date, p_description text, p_lines jsonb, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v_id uuid; v_res jsonb;
begin
  perform app.require_permission('accounting.manual_journal');
  perform app.require_permission('accounting.period_close');
  if nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required for a manual journal' using errcode = '22023';
  end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'post_manual_journal');
  if v_done is not null then return v_done; end if;
  perform app.set_context(trim(p_reason), p_client_txn_id, null);
  v_id := app.post_journal(p_entry_date, p_description, 'manual.journal', p_lines, 'manual', null, null, null, p_client_txn_id);
  select jsonb_build_object('entry_id', id, 'entry_no', entry_no) into v_res from public.journal_entries where id = v_id;
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.money_accounts  enable row level security;
alter table public.journal_drafts  enable row level security;
create policy money_accounts_read on public.money_accounts for select to authenticated
  using (app.has_permission('accounting.view') or app.has_permission('payments.view') or app.has_permission('expenses.view')
         or app.has_permission('payments.manage'));
create policy journal_drafts_read on public.journal_drafts for select to authenticated
  using (app.has_permission('accounting.view') or app.has_permission('accounting.manual_journal'));

-- >>> 20261005000027_banking_cheques_credit_notes.sql
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

-- >>> 20261005000028_expenses.sql
-- =====================================================================
-- OLA Water ERP — Phase 2B
-- 0028: expenses — record → approve (above the limit) → pay → posted
-- =====================================================================
-- Paid on the spot (cash, petty cash, bank, cheque): one entry
--   Dr expense (+ VAT input) / Cr the cash or bank account.
-- Bought on credit (a bill to pay later): Dr expense (+ VAT input) /
--   Cr Expenses Payable when approved, then Dr Expenses Payable / Cr bank
--   when paid.
-- =====================================================================

create table public.expense_categories (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (code ~ '^[A-Z0-9_-]{2,20}$'),
  name        text not null,
  account_id  uuid not null references public.accounts(id),
  is_active   boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now()
);
create trigger expense_categories_audit after insert or update on public.expense_categories for each row execute function app.audit_row('expenses');

create table public.expenses (
  id                 uuid primary key default gen_random_uuid(),
  expense_no         text not null unique,
  expense_date       date not null,
  category_id        uuid not null references public.expense_categories(id),
  description        text not null,
  payee              text,
  supplier_id        uuid references public.suppliers(id),
  location_id        uuid references public.locations(id),
  vehicle_id         uuid references public.vehicles(id),
  net_amount         numeric(14,2) not null check (net_amount > 0),
  vat_amount         numeric(14,2) not null default 0 check (vat_amount >= 0),
  total              numeric(14,2) not null,
  pay_method         text not null check (pay_method in ('cash','petty_cash','bank_transfer','cheque','card','on_credit')),
  money_account_id   uuid references public.money_accounts(id),
  reference          text,
  receipt_path       text,
  status             text not null check (status in ('pending_approval','approved','paid','rejected')),
  created_at         timestamptz not null default now(),
  created_by         uuid,
  approved_at        timestamptz,
  approved_by        uuid,
  decision_note      text,
  paid_at            timestamptz,
  paid_by            uuid,
  paid_from          uuid references public.money_accounts(id),
  payment_reference  text,
  journal_entry_id   uuid references public.journal_entries(id),
  payment_entry_id   uuid references public.journal_entries(id),
  updated_at         timestamptz not null default now(),
  client_txn_id      uuid unique,
  check (total = net_amount + vat_amount),
  check (pay_method = 'on_credit' or money_account_id is not null)
);
create index expenses_date_idx on public.expenses (expense_date desc);
create index expenses_status_idx on public.expenses (status, expense_date);
create trigger expenses_touch before update on public.expenses for each row execute function app.touch_updated_at();
create trigger expenses_audit after insert or update on public.expenses for each row execute function app.audit_row('expenses');

insert into public.accounts (code, name, account_type, system_key, parent_id)
select v.code, v.name, v.type, v.key, (select id from public.accounts where code = v.parent)
  from (values
    ('2150', 'Expenses Payable',          'liability', 'expenses_payable', '2000'),
    ('4160', 'Sales Returns & Allowances','income',    'sales_returns',    '4000'),
    ('4910', 'Interest Income',           'income',    'interest_income',  '4000'),
    ('6220', 'Bank Charges',              'expense',   'exp_bank_charges', '6000'),
    ('6230', 'Telephone & Internet',      'expense',   'exp_telephone',    '6000'),
    ('6240', 'Travel',                    'expense',   'exp_travel',       '6000'),
    ('6250', 'Repairs to Equipment',      'expense',   'exp_equipment_repair', '6000')
  ) as v(code, name, type, key, parent);

insert into public.expense_categories (code, name, account_id, sort_order)
select v.code, v.name, (select id from public.accounts where system_key = v.key), v.ord
  from (values
    ('FUEL', 'Fuel', 'exp_fuel', 1), ('ELECTRICITY', 'Electricity', 'exp_electricity', 2), ('WATER', 'Water bill', 'exp_water', 3),
    ('RENT', 'Rent', 'exp_rent', 4), ('VEHICLE_REPAIR', 'Vehicle repair', 'exp_vehicle_repair', 5),
    ('MAINTENANCE', 'Plant maintenance', 'exp_maintenance', 6), ('EQUIPMENT', 'Equipment repair', 'exp_equipment_repair', 7),
    ('MARKETING', 'Marketing', 'exp_marketing', 8), ('PACKAGING', 'Packaging (not stocked)', 'exp_packaging', 9),
    ('OFFICE', 'Office', 'exp_office', 10), ('UTILITIES', 'Other utilities', 'exp_utilities', 11),
    ('TELEPHONE', 'Telephone & internet', 'exp_telephone', 12), ('TRAVEL', 'Travel', 'exp_travel', 13),
    ('BANK', 'Bank charges', 'exp_bank_charges', 14), ('OTHER', 'Other', 'exp_other', 99)
  ) as v(code, name, key, ord);

create or replace function public.save_expense_category(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; a public.accounts;
begin
  perform app.require_permission('expenses.approve');
  select * into a from public.accounts where id = app.juuid(p, 'account_id');
  if not found or a.account_type <> 'expense' or not a.is_postable then raise exception 'Choose an expense account' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    insert into public.expense_categories (code, name, account_id, sort_order)
    values (upper(trim(app.jtext(p, 'code'))), trim(app.jtext(p, 'name')), a.id, coalesce(app.jint(p, 'sort_order'), 50)) returning id into v;
  else
    update public.expense_categories set name = trim(app.jtext(p, 'name')), account_id = a.id, is_active = app.jbool(p, 'is_active', true)
     where id = p_id returning id into v;
    if v is null then raise exception 'Category not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

-- Post the expense itself (on approval)
create or replace function app.post_expense(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare x public.expenses; c public.expense_categories; m public.money_accounts; v_je uuid; v_lines jsonb;
begin
  select * into x from public.expenses where id = p_id for update;
  select * into c from public.expense_categories where id = x.category_id;
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', c.account_id, 'debit', x.net_amount, 'credit', 0, 'memo', c.name,
                       'party_type', case when x.supplier_id is not null then 'supplier' end, 'party_id', x.supplier_id));
  if x.vat_amount > 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'vat_input', 'debit', x.vat_amount, 'credit', 0, 'memo', 'VAT input');
  end if;
  if x.pay_method = 'on_credit' then
    v_lines := v_lines || jsonb_build_object('account_key', 'expenses_payable', 'debit', 0, 'credit', x.total, 'memo', 'To pay: ' || coalesce(x.payee, ''),
                                             'party_type', case when x.supplier_id is not null then 'supplier' end, 'party_id', x.supplier_id);
  else
    select * into m from public.money_accounts where id = x.money_account_id;
    v_lines := v_lines || jsonb_build_object('account_id', m.account_id, 'debit', 0, 'credit', x.total, 'memo', 'Paid: ' || coalesce(x.payee, ''));
  end if;
  v_je := app.post_journal(x.expense_date, format('Expense %s — %s: %s', x.expense_no, c.name, x.description), 'expense.recorded',
    v_lines, 'expense', x.id, x.location_id);
  update public.expenses set journal_entry_id = v_je,
         status = case when x.pay_method = 'on_credit' then 'approved' else 'paid' end,
         paid_at = case when x.pay_method = 'on_credit' then null else now() end,
         paid_by = case when x.pay_method = 'on_credit' then null else coalesce(x.approved_by, x.created_by) end,
         paid_from = case when x.pay_method = 'on_credit' then null else x.money_account_id end
   where id = x.id;
end $$;

--   p: {expense_date, category_id, description, payee, supplier_id, location_id, vehicle_id, net_amount, vat_amount,
--       pay_method, money_account_id, reference, receipt_path}
create or replace function public.record_expense(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v uuid := gen_random_uuid(); v_no text; v_net numeric := round(app.jnum(p, 'net_amount'), 2);
        v_vat numeric := round(coalesce(app.jnum(p, 'vat_amount'), 0), 2); v_method text := app.jtext(p, 'pay_method');
        v_limit numeric; v_auto boolean; m public.money_accounts; v_res jsonb; v_date date := coalesce((app.jtext(p, 'expense_date'))::date, app.today());
begin
  perform app.require_permission('expenses.manage');
  if coalesce(v_net, 0) <= 0 then raise exception 'Enter the amount' using errcode = '22023'; end if;
  if v_vat < 0 then raise exception 'VAT cannot be negative' using errcode = '22023'; end if;
  if nullif(trim(app.jtext(p, 'description')), '') is null then raise exception 'Describe the expense' using errcode = '22023'; end if;
  if not exists (select 1 from public.expense_categories where id = app.juuid(p, 'category_id') and is_active) then
    raise exception 'Choose a category' using errcode = '22023';
  end if;
  if v_date > app.today() then raise exception 'An expense cannot be dated in the future' using errcode = '22023'; end if;
  if v_method <> 'on_credit' then
    m := app.money_account(app.juuid(p, 'money_account_id'));
    if (v_method = 'cash' and m.kind <> 'cash') or (v_method = 'petty_cash' and m.kind <> 'petty_cash')
       or (v_method in ('bank_transfer','cheque','card') and m.kind <> 'bank') then
      raise exception 'The account does not match how it was paid' using errcode = '22023';
    end if;
    if v_method in ('bank_transfer','cheque') and nullif(trim(app.jtext(p, 'reference')), '') is null then
      raise exception 'Enter the bank reference or cheque number' using errcode = '22023';
    end if;
  end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'record_expense');
  if v_done is not null then return v_done; end if;
  v_limit := coalesce((app.get_setting('approvals.expense_amount') #>> '{}')::numeric, 0);
  v_auto := v_net + v_vat < v_limit or app.has_permission('expenses.approve');
  perform app.set_context(null, p_client_txn_id, 'expense');
  v_no := app.next_document_number('EXP');
  insert into public.expenses (id, expense_no, expense_date, category_id, description, payee, supplier_id, location_id, vehicle_id,
    net_amount, vat_amount, total, pay_method, money_account_id, reference, receipt_path, status, created_by, approved_at, approved_by, client_txn_id)
  values (v, v_no, v_date, app.juuid(p, 'category_id'), trim(app.jtext(p, 'description')), app.jtext(p, 'payee'), app.juuid(p, 'supplier_id'),
    app.juuid(p, 'location_id'), app.juuid(p, 'vehicle_id'), v_net, v_vat, v_net + v_vat, v_method, m.id, nullif(trim(app.jtext(p, 'reference')), ''),
    app.jtext(p, 'receipt_path'), 'pending_approval', app.current_user_id(),
    case when v_auto then now() end, case when v_auto then app.current_user_id() end, p_client_txn_id);
  if v_auto then perform app.post_expense(v); end if;
  v_res := jsonb_build_object('expense_id', v, 'expense_no', v_no, 'status', (select status from public.expenses where id = v));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.decide_expense(p_id uuid, p_approve boolean, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare x public.expenses;
begin
  perform app.require_permission('expenses.approve');
  select * into x from public.expenses where id = p_id for update;
  if not found then raise exception 'Expense not found' using errcode = 'P0002'; end if;
  if x.status <> 'pending_approval' then raise exception 'This expense has already been decided' using errcode = '22023'; end if;
  if x.created_by = app.current_user_id() and not app.is_super_admin(app.current_user_id()) then
    raise exception 'Someone else must approve your own expense' using errcode = '42501';
  end if;
  if not p_approve and nullif(trim(p_note), '') is null then raise exception 'Give a reason for rejecting' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_note), ''), null, case when p_approve then 'approve' else 'reject' end);
  if p_approve then
    update public.expenses set approved_at = now(), approved_by = app.current_user_id(), decision_note = nullif(trim(p_note), '') where id = p_id;
    perform app.post_expense(p_id);
  else
    update public.expenses set status = 'rejected', decision_note = trim(p_note), approved_by = app.current_user_id(), approved_at = now() where id = p_id;
  end if;
  return jsonb_build_object('status', (select status from public.expenses where id = p_id));
end $$;

-- Pay a bill recorded on credit
create or replace function public.pay_expense(p_id uuid, p_money_account uuid, p_reference text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; x public.expenses; m public.money_accounts; v_je uuid; v_res jsonb;
begin
  perform app.require_permission('payments.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'pay_expense');
  if v_done is not null then return v_done; end if;
  select * into x from public.expenses where id = p_id for update;
  if not found or x.status <> 'approved' or x.pay_method <> 'on_credit' then raise exception 'Only an approved unpaid bill can be paid' using errcode = '22023'; end if;
  m := app.money_account(p_money_account);
  if m.kind in ('bank') and nullif(trim(p_reference), '') is null then raise exception 'Enter the bank reference or cheque number' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_reference), ''), p_client_txn_id, 'pay_expense');
  v_je := app.post_journal(app.today(), format('Payment of expense %s — %s', x.expense_no, coalesce(x.payee, x.description)), 'expense.paid',
    jsonb_build_array(
      jsonb_build_object('account_key', 'expenses_payable', 'debit', x.total, 'credit', 0, 'memo', 'Bill paid',
                         'party_type', case when x.supplier_id is not null then 'supplier' end, 'party_id', x.supplier_id),
      jsonb_build_object('account_id', m.account_id, 'debit', 0, 'credit', x.total, 'memo', 'Bill paid')),
    'expense', x.id, x.location_id);
  update public.expenses set status = 'paid', paid_at = now(), paid_by = app.current_user_id(), paid_from = m.id,
         payment_reference = nullif(trim(p_reference), ''), payment_entry_id = v_je where id = p_id;
  v_res := jsonb_build_object('expense_no', x.expense_no, 'paid', x.total);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

alter table public.expense_categories enable row level security;
alter table public.expenses           enable row level security;
create policy expense_categories_read on public.expense_categories for select to authenticated
  using (app.has_permission('expenses.view') or app.has_permission('expenses.manage') or app.has_permission('accounting.view'));
create policy expenses_read on public.expenses for select to authenticated
  using (app.has_permission('expenses.view') or app.has_permission('accounting.view') or created_by = app.current_user_id());

-- Receipt photos / PDFs for expenses
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('expense-receipts', 'expense-receipts', false, 10485760,
            array['application/pdf','image/jpeg','image/png','image/webp','image/heic'])
    on conflict (id) do nothing;
    execute $p$
      create policy "Staff upload expense receipts" on storage.objects
        for insert to authenticated
        with check (bucket_id = 'expense-receipts' and app.has_permission('expenses.manage'))
    $p$;
    execute $p$
      create policy "Staff read expense receipts" on storage.objects
        for select to authenticated
        using (bucket_id = 'expense-receipts' and (app.has_permission('expenses.view') or app.has_permission('accounting.view')))
    $p$;
  end if;
exception when others then
  raise notice 'Storage bucket/policies not created (%). Expense receipts cannot be uploaded until this is fixed.', sqlerrm;
end $$;

-- >>> 20261005000029_phase2b_reference_and_reports.sql
-- =====================================================================
-- OLA Water ERP — Phase 2B
-- 0029: document numbers, settings, roles, financial reports, grants
-- =====================================================================

insert into public.document_types (code, name, padding) values
  ('MJ',  'Manual journal', 6),
  ('FT',  'Funds transfer', 6),
  ('VAT', 'VAT return', 4),
  ('EXP', 'Expense', 6)
on conflict (code) do nothing;

insert into public.setting_definitions (key, module, label, description, value_type, choices, min_value, max_value, sort_order) values
  ('accounting.fiscal_year_start_month', 'Accounting', 'Financial year starts in month',
   '4 = April (Sri Lankan tax year). Used by the balance sheet for "profit this year".', 'integer', null, 1, 12, 80);
insert into public.system_settings (key, value, effective_from) values ('accounting.fiscal_year_start_month', '4', date '2026-01-01');

select public.ensure_accounting_year(2028);

insert into public.role_permissions (role_id, permission_code)
select r.id, x.code
  from public.roles r
  join (values
    ('accountant',          array['reports.export','expenses.view','procurement.view']),
    ('operations_manager',  array['expenses.view','expenses.manage']),
    ('director',            array['reports.view'])
  ) as m(role_code, perms) on m.role_code = r.code
  cross join lateral unnest(m.perms) as x(code)
 where not exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_code = x.code);

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create or replace function app.require_accounting_view()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.has_permission('accounting.view') then
    raise exception 'Permission denied: accounting.view is required' using errcode = '42501';
  end if;
end $$;

create or replace function app.party_name(p_type text, p_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case p_type
    when 'customer' then (select name from public.customers where id = p_id)
    when 'supplier' then (select name from public.suppliers where id = p_id)
    when 'water_shop' then (select name from public.water_shops where id = p_id)
    when 'driver' then (select full_name from public.profiles where id = p_id)
    when 'employee' then (select full_name from public.profiles where id = p_id)
    when 'external_company' then (select name from public.bottle_companies where id = p_id)
  end
$$;

create or replace function app.fiscal_year_start(p_date date)
returns date language sql stable security definer set search_path = '' as $$
  select case when extract(month from p_date)::int >= m then make_date(extract(year from p_date)::int, m, 1)
              else make_date(extract(year from p_date)::int - 1, m, 1) end
    from (select coalesce((app.get_setting('accounting.fiscal_year_start_month') #>> '{}')::int, 4) as m) s
$$;

-- Accounts that count as cash for the cash-flow report
create or replace function app.is_cash_account(p_account uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.money_accounts where account_id = p_account)
      or exists (select 1 from public.accounts where id = p_account and system_key in ('driver_cash','shop_cash','cheques_in_hand'))
$$;

-- ---------------------------------------------------------------------
-- Trial balance with opening and closing balances
-- ---------------------------------------------------------------------
create or replace function public.report_trial_balance(p_from date, p_to date)
returns table (account_id uuid, code text, name text, account_type text, opening numeric, debit numeric, credit numeric, closing numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_accounting_view();
  return query
  select a.id, a.code, a.name, a.account_type,
         coalesce(sum(l.debit - l.credit) filter (where e.entry_date < p_from), 0),
         coalesce(sum(l.debit) filter (where e.entry_date between p_from and p_to), 0),
         coalesce(sum(l.credit) filter (where e.entry_date between p_from and p_to), 0),
         coalesce(sum(l.debit - l.credit) filter (where e.entry_date <= p_to), 0)
    from public.accounts a
    join public.journal_lines l on l.account_id = a.id
    join public.journal_entries e on e.id = l.entry_id
   where e.entry_date <= p_to
   group by a.id
   order by a.code;
end $$;

-- ---------------------------------------------------------------------
-- Profit and loss (with the previous period of the same length)
-- ---------------------------------------------------------------------
create or replace function public.report_profit_loss(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_len integer := p_to - p_from + 1; v_pfrom date := p_from - (p_to - p_from + 1); v_pto date := p_from - 1; v jsonb;
begin
  perform app.require_accounting_view();
  with amounts as (
    select a.id, a.code, a.name, a.account_type,
           case when a.account_type = 'income' then 'income' when a.code like '5%' then 'cost_of_sales' else 'expenses' end as section,
           coalesce(sum(case when a.account_type = 'income' then l.credit - l.debit else l.debit - l.credit end)
                    filter (where e.entry_date between p_from and p_to), 0) as amount,
           coalesce(sum(case when a.account_type = 'income' then l.credit - l.debit else l.debit - l.credit end)
                    filter (where e.entry_date between v_pfrom and v_pto), 0) as previous
      from public.accounts a
      join public.journal_lines l on l.account_id = a.id
      join public.journal_entries e on e.id = l.entry_id
     where a.account_type in ('income','expense') and e.entry_date between v_pfrom and p_to
     group by a.id
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'previous_from', v_pfrom, 'previous_to', v_pto, 'days', v_len,
    'sections', jsonb_build_object(
      'income', (select coalesce(jsonb_agg(jsonb_build_object('account_id', id, 'code', code, 'name', name, 'amount', amount, 'previous', previous) order by code), '[]')
                   from amounts where section = 'income' and (amount <> 0 or previous <> 0)),
      'cost_of_sales', (select coalesce(jsonb_agg(jsonb_build_object('account_id', id, 'code', code, 'name', name, 'amount', amount, 'previous', previous) order by code), '[]')
                   from amounts where section = 'cost_of_sales' and (amount <> 0 or previous <> 0)),
      'expenses', (select coalesce(jsonb_agg(jsonb_build_object('account_id', id, 'code', code, 'name', name, 'amount', amount, 'previous', previous) order by code), '[]')
                   from amounts where section = 'expenses' and (amount <> 0 or previous <> 0))),
    'totals', jsonb_build_object(
      'income', (select coalesce(sum(amount), 0) from amounts where section = 'income'),
      'cost_of_sales', (select coalesce(sum(amount), 0) from amounts where section = 'cost_of_sales'),
      'expenses', (select coalesce(sum(amount), 0) from amounts where section = 'expenses'),
      'gross_profit', (select coalesce(sum(case when section = 'income' then amount when section = 'cost_of_sales' then -amount else 0 end), 0) from amounts),
      'net_profit', (select coalesce(sum(case when section = 'income' then amount else -amount end), 0) from amounts),
      'previous_income', (select coalesce(sum(previous), 0) from amounts where section = 'income'),
      'previous_cost_of_sales', (select coalesce(sum(previous), 0) from amounts where section = 'cost_of_sales'),
      'previous_expenses', (select coalesce(sum(previous), 0) from amounts where section = 'expenses'),
      'previous_net_profit', (select coalesce(sum(case when section = 'income' then previous else -previous end), 0) from amounts))
  ) into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Balance sheet
-- ---------------------------------------------------------------------
create or replace function public.report_balance_sheet(p_as_at date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; v_fy date := app.fiscal_year_start(p_as_at);
begin
  perform app.require_accounting_view();
  with bal as (
    select a.id, a.code, a.name, a.account_type,
           coalesce(sum(l.debit - l.credit), 0) as dr_balance,
           coalesce(sum(l.debit - l.credit) filter (where e.entry_date >= v_fy), 0) as dr_this_year
      from public.accounts a
      join public.journal_lines l on l.account_id = a.id
      join public.journal_entries e on e.id = l.entry_id
     where e.entry_date <= p_as_at
     group by a.id
  ), pl as (
    select coalesce(sum(-(dr_balance - dr_this_year)), 0) as prior_years, coalesce(sum(-dr_this_year), 0) as this_year
      from bal where account_type in ('income','expense')
  )
  select jsonb_build_object(
    'as_at', p_as_at, 'year_start', v_fy,
    'assets', (select coalesce(jsonb_agg(jsonb_build_object('account_id', id, 'code', code, 'name', name, 'amount', dr_balance) order by code), '[]')
                 from bal where account_type = 'asset' and dr_balance <> 0),
    'liabilities', (select coalesce(jsonb_agg(jsonb_build_object('account_id', id, 'code', code, 'name', name, 'amount', -dr_balance) order by code), '[]')
                 from bal where account_type = 'liability' and dr_balance <> 0),
    'equity', (select coalesce(jsonb_agg(jsonb_build_object('account_id', id, 'code', code, 'name', name, 'amount', -dr_balance) order by code), '[]')
                 from bal where account_type = 'equity' and dr_balance <> 0),
    'profit_prior_years', (select prior_years from pl),
    'profit_this_year', (select this_year from pl),
    'totals', jsonb_build_object(
      'assets', (select coalesce(sum(dr_balance), 0) from bal where account_type = 'asset'),
      'liabilities', (select coalesce(sum(-dr_balance), 0) from bal where account_type = 'liability'),
      'equity', (select coalesce(sum(-dr_balance), 0) from bal where account_type = 'equity') + (select prior_years + this_year from pl))
  ) into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Cash flow (direct method): every entry that moves cash, grouped by
-- what the money was for
-- ---------------------------------------------------------------------
create or replace function public.report_cash_flow(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  perform app.require_accounting_view();
  with cashacc as (
    select id from public.accounts a where app.is_cash_account(a.id)
  ), moves as (
    select e.id, e.entry_date, e.event_type,
           sum(l.debit - l.credit) filter (where l.account_id in (select id from cashacc)) as delta
      from public.journal_entries e join public.journal_lines l on l.entry_id = e.id
     where e.entry_date between p_from and p_to
     group by e.id
    having coalesce(sum(l.debit - l.credit) filter (where l.account_id in (select id from cashacc)), 0) <> 0
  ), counter as (
    select distinct on (m.id) m.id, m.delta, m.event_type, a.system_key, a.account_type, a.code
      from moves m join public.journal_lines l on l.entry_id = m.id join public.accounts a on a.id = l.account_id
     where l.account_id not in (select id from cashacc)
     order by m.id, abs(l.debit - l.credit) desc
  ), classified as (
    select c.delta,
      case
        when c.system_key in ('ar','ar_shops','ar_distributors','customer_advances','bottle_deposits','sales','sales_shops','delivery_income')
          or c.event_type like 'payment.%' or c.event_type like 'refund.%' or c.event_type like 'cheque.%' then 'Customers (receipts less refunds)'
        when c.system_key in ('ap','grni') or c.event_type like 'supplier.%' then 'Suppliers'
        when c.system_key in ('salaries_payable','epf_payable','etf_payable','paye_payable') then 'Salaries and statutory payments'
        when c.system_key in ('vat_output','vat_input','sscl_payable') then 'Taxes'
        when c.system_key like 'fa_%' or c.system_key = 'accum_depreciation' then 'Fixed assets (investing)'
        when c.account_type = 'equity' then 'Owners and financing'
        when c.system_key = 'expenses_payable' or c.account_type = 'expense' then 'Expenses'
        when c.account_type = 'income' then 'Other income'
        else 'Other' end as category
      from counter c
  ), all_moves as (
    select category, delta from classified
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'opening', coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                          where e.entry_date < p_from and l.account_id in (select id from cashacc)), 0),
    'closing', coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                          where e.entry_date <= p_to and l.account_id in (select id from cashacc)), 0),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'cash_in', cash_in, 'cash_out', cash_out, 'net', cash_in - cash_out)
                order by cash_in - cash_out desc), '[]')
                from (select category, coalesce(sum(delta) filter (where delta > 0), 0) cash_in, coalesce(-sum(delta) filter (where delta < 0), 0) cash_out
                        from all_moves group by category) g),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name,
                   'opening', coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                                         where l.account_id = a.id and e.entry_date < p_from), 0),
                   'closing', coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                                         where l.account_id = a.id and e.entry_date <= p_to), 0)) order by a.code), '[]')
                 from public.accounts a where a.id in (select id from cashacc))
  ) into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- General ledger for one account
-- ---------------------------------------------------------------------
create or replace function public.report_general_ledger(p_account uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.accounts; v jsonb; v_open numeric;
begin
  perform app.require_accounting_view();
  select * into a from public.accounts where id = p_account;
  if not found then raise exception 'Account not found' using errcode = 'P0002'; end if;
  select coalesce(sum(l.debit - l.credit), 0) into v_open from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
   where l.account_id = a.id and e.entry_date < p_from;
  select jsonb_build_object(
    'account', jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'account_type', a.account_type),
    'from', p_from, 'to', p_to, 'opening', v_open,
    'lines', (select coalesce(jsonb_agg(x order by (x ->> 'n')::bigint), '[]') from (
        select jsonb_build_object('n', row_number() over w, 'entry_id', e.id, 'entry_no', e.entry_no, 'date', e.entry_date, 'description', e.description,
                 'memo', l.memo, 'party', app.party_name(l.party_type, l.party_id), 'event_type', e.event_type,
                 'source_type', e.source_type, 'source_id', e.source_id, 'debit', l.debit, 'credit', l.credit,
                 'balance', v_open + sum(l.debit - l.credit) over w) as x
          from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
         where l.account_id = a.id and e.entry_date between p_from and p_to
        window w as (order by e.entry_date, e.created_at, l.id rows between unbounded preceding and current row)
        limit 3000) q),
    'debit', coalesce((select sum(l.debit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                        where l.account_id = a.id and e.entry_date between p_from and p_to), 0),
    'credit', coalesce((select sum(l.credit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                        where l.account_id = a.id and e.entry_date between p_from and p_to), 0)
  ) into v;
  return v || jsonb_build_object('closing', v_open + (v ->> 'debit')::numeric - (v ->> 'credit')::numeric);
end $$;

create or replace function public.journal_entry_details(p_entry uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare e public.journal_entries; v jsonb;
begin
  perform app.require_accounting_view();
  select * into e from public.journal_entries where id = p_entry;
  if not found then raise exception 'Entry not found' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'entry', to_jsonb(e) || jsonb_build_object('created_by_name', (select full_name from public.profiles where id = e.created_by),
               'period', (select name || case when status = 'closed' then ' (closed)' else '' end from public.accounting_periods where id = e.period_id),
               'location', (select name from public.locations where id = e.location_id)),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('line_no', l.line_no, 'account_id', a.id, 'code', a.code, 'name', a.name,
                'debit', l.debit, 'credit', l.credit, 'memo', l.memo, 'party', app.party_name(l.party_type, l.party_id)) order by l.line_no), '[]')
                from public.journal_lines l join public.accounts a on a.id = l.account_id where l.entry_id = e.id),
    'reverses', (select jsonb_build_object('id', id, 'entry_no', entry_no) from public.journal_entries where id = e.reverses_entry_id),
    'reversed_by', (select jsonb_build_object('id', id, 'entry_no', entry_no, 'entry_date', entry_date) from public.journal_entries where reverses_entry_id = e.id),
    'reason', (select reason from public.audit_logs where record_type = 'journal_entries' and record_id = e.id::text order by occurred_at limit 1)
  ) into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Ageing
-- ---------------------------------------------------------------------
create or replace function public.report_ar_ageing(p_as_at date default null)
returns table (customer_id uuid, customer_no text, name text, phone text, customer_type text, not_due numeric, d1_30 numeric, d31_60 numeric,
               d61_90 numeric, d90_plus numeric, total_due numeric, unapplied numeric, net numeric, credit_limit numeric)
language plpgsql stable security definer set search_path = '' as $$
declare d date := coalesce(p_as_at, app.today());
begin
  if not (app.has_permission('accounting.view') or app.has_permission('payments.view')) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  return query
  with inv as (
    select i.customer_id, i.balance, d - i.due_date as late from public.invoices i
     where i.status in ('open','partially_paid') and i.balance > 0 and i.invoice_date <= d
  ), un as (
    select p.customer_id, sum(p.unallocated) amt from public.payments p where p.status = 'received' and p.direction = 'in' and p.unallocated > 0 group by 1
    union all
    select cn.customer_id, sum(cn.unallocated) from public.credit_notes cn where cn.unallocated > 0 group by 1
  )
  select c.id, c.customer_no, c.name, c.phone, c.customer_type,
         coalesce(sum(inv.balance) filter (where inv.late <= 0), 0),
         coalesce(sum(inv.balance) filter (where inv.late between 1 and 30), 0),
         coalesce(sum(inv.balance) filter (where inv.late between 31 and 60), 0),
         coalesce(sum(inv.balance) filter (where inv.late between 61 and 90), 0),
         coalesce(sum(inv.balance) filter (where inv.late > 90), 0),
         coalesce(sum(inv.balance), 0),
         coalesce((select sum(amt) from un where un.customer_id = c.id), 0),
         coalesce(sum(inv.balance), 0) - coalesce((select sum(amt) from un where un.customer_id = c.id), 0),
         c.credit_limit
    from public.customers c
    left join inv on inv.customer_id = c.id
   group by c.id
  having coalesce(sum(inv.balance), 0) <> 0 or coalesce((select sum(amt) from un where un.customer_id = c.id), 0) <> 0
   order by coalesce(sum(inv.balance) filter (where inv.late > 90), 0) desc, coalesce(sum(inv.balance), 0) desc;
end $$;

create or replace function public.report_ap_ageing(p_as_at date default null)
returns table (party text, supplier_id uuid, not_due numeric, d1_30 numeric, d31_60 numeric, d61_90 numeric, d90_plus numeric, total_due numeric,
               advances numeric)
language plpgsql stable security definer set search_path = '' as $$
declare d date := coalesce(p_as_at, app.today());
begin
  if not (app.has_permission('accounting.view') or app.has_permission('payments.view')) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  return query
  with bills as (
    select s.name as party, s.id as supplier_id, i.total - i.amount_paid as bal, d - i.due_date as late
      from public.supplier_invoices i join public.suppliers s on s.id = i.supplier_id
     where i.status in ('approved','partially_paid') and i.invoice_date <= d
    union all
    select coalesce(s.name, x.payee, 'Other bills'), s.id, x.total, d - x.expense_date
      from public.expenses x left join public.suppliers s on s.id = x.supplier_id
     where x.status = 'approved' and x.pay_method = 'on_credit' and x.expense_date <= d
  )
  select b.party, b.supplier_id,
         coalesce(sum(bal) filter (where late <= 0), 0), coalesce(sum(bal) filter (where late between 1 and 30), 0),
         coalesce(sum(bal) filter (where late between 31 and 60), 0), coalesce(sum(bal) filter (where late between 61 and 90), 0),
         coalesce(sum(bal) filter (where late > 90), 0), coalesce(sum(bal), 0),
         coalesce((select sum(unallocated) from public.supplier_payments sp where sp.supplier_id = b.supplier_id), 0)
    from bills b
   group by b.party, b.supplier_id
   order by coalesce(sum(bal), 0) desc;
end $$;

-- ---------------------------------------------------------------------
-- VAT report for a period
-- ---------------------------------------------------------------------
create or replace function public.report_vat(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare t record; v jsonb;
begin
  perform app.require_accounting_view();
  select * into t from app.vat_totals(p_from, p_to);
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'output_vat', t.output_vat, 'input_vat', t.input_vat, 'net', t.output_vat - t.input_vat,
    'vat_no', app.get_setting('company.vat_registration_no') #>> '{}',
    'sales_by_rate', (select coalesce(jsonb_agg(jsonb_build_object('rate', rate, 'net', net, 'vat', vat) order by rate desc), '[]') from (
        select il.tax_rate rate, sum(il.net) net, sum(il.tax) vat from public.invoice_lines il join public.invoices i on i.id = il.invoice_id
         where i.status <> 'void' and i.invoice_date between p_from and p_to and il.line_type in ('product','delivery_charge','bottle_charge')
           and exists (select 1 from public.journal_entries je where je.id = i.journal_entry_id)
         group by il.tax_rate) s),
    'credit_notes', jsonb_build_object('net', coalesce((select sum(net) from public.credit_notes where credit_date between p_from and p_to), 0),
                                       'vat', coalesce((select sum(tax) from public.credit_notes where credit_date between p_from and p_to), 0)),
    'purchases', jsonb_build_object('net', coalesce((select sum(subtotal) from public.supplier_invoices where status not in ('on_hold','void')
                                                       and invoice_date between p_from and p_to), 0),
                                    'vat', coalesce((select sum(tax_total) from public.supplier_invoices where status not in ('on_hold','void')
                                                       and invoice_date between p_from and p_to), 0)),
    'expenses', jsonb_build_object('net', coalesce((select sum(net_amount) from public.expenses where status in ('approved','paid')
                                                      and expense_date between p_from and p_to), 0),
                                   'vat', coalesce((select sum(vat_amount) from public.expenses where status in ('approved','paid')
                                                      and expense_date between p_from and p_to), 0)),
    'balances', jsonb_build_object(
        'vat_output', coalesce((select sum(l.credit - l.debit) from public.journal_lines l join public.accounts a on a.id = l.account_id
                                 join public.journal_entries e on e.id = l.entry_id where a.system_key = 'vat_output' and e.entry_date <= p_to), 0),
        'vat_input', coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.accounts a on a.id = l.account_id
                                join public.journal_entries e on e.id = l.entry_id where a.system_key = 'vat_input' and e.entry_date <= p_to), 0)),
    'returns', (select coalesce(jsonb_agg(jsonb_build_object('return_no', return_no, 'period_from', period_from, 'period_to', period_to,
                  'output_vat', output_vat, 'input_vat', input_vat, 'net_payable', net_payable, 'reference', reference, 'created_at', created_at)
                  order by period_from desc), '[]') from public.vat_returns),
    'last_return_to', (select max(period_to) from public.vat_returns)
  ) into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Accounting overview
-- ---------------------------------------------------------------------
create or replace function public.accounting_overview()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; v_today date := app.today(); v_month date := date_trunc('month', app.today())::date;
begin
  if not (app.has_permission('accounting.view') or app.has_permission('payments.manage')) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'money', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'kind', m.kind, 'bank_name', m.bank_name, 'account_no', m.account_no,
                'is_default', m.is_default, 'is_active', m.is_active, 'code', a.code,
                'balance', coalesce((select sum(debit - credit) from public.journal_lines where account_id = m.account_id), 0),
                'last_reconciled', (select max(statement_date) from public.bank_reconciliations r where r.money_account_id = m.id))
                order by m.kind, m.name), '[]')
                from public.money_accounts m join public.accounts a on a.id = m.account_id),
    'other_cash', (select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name,
                     'balance', coalesce((select sum(debit - credit) from public.journal_lines where account_id = a.id), 0)) order by a.code), '[]')
                     from public.accounts a where a.system_key in ('driver_cash','shop_cash','cheques_in_hand')),
    'receivable', coalesce((select sum(balance) from public.invoices where status in ('open','partially_paid')), 0),
    'receivable_overdue', coalesce((select sum(balance) from public.invoices where status in ('open','partially_paid') and due_date < v_today), 0),
    'payable', coalesce((select sum(total - amount_paid) from public.supplier_invoices where status in ('approved','partially_paid')), 0)
             + coalesce((select sum(total) from public.expenses where status = 'approved' and pay_method = 'on_credit'), 0),
    'vat_balance', coalesce((select sum(l.credit - l.debit) from public.journal_lines l join public.accounts a on a.id = l.account_id
                              where a.system_key in ('vat_output','vat_input')), 0),
    'deposits_held', coalesce((select sum(l.credit - l.debit) from public.journal_lines l join public.accounts a on a.id = l.account_id
                                where a.system_key = 'bottle_deposits'), 0),
    'cheques_in_hand', jsonb_build_object('count', (select count(*) from public.payments where cheque_status = 'in_hand' and status = 'received'),
                                          'amount', coalesce((select sum(amount) from public.payments where cheque_status = 'in_hand' and status = 'received'), 0)),
    'cheques_deposited', (select count(*) from public.payments where cheque_status = 'deposited'),
    'journals_waiting', (select count(*) from public.journal_drafts where status = 'pending'),
    'expenses_waiting', (select count(*) from public.expenses where status = 'pending_approval'),
    'bills_to_pay', (select count(*) from public.expenses where status = 'approved' and pay_method = 'on_credit'),
    'month', (select jsonb_build_object(
        'income', coalesce(sum(case when a.account_type = 'income' then l.credit - l.debit end), 0),
        'expense', coalesce(sum(case when a.account_type = 'expense' then l.debit - l.credit end), 0))
        from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
       where e.entry_date between v_month and v_today and a.account_type in ('income','expense')),
    'periods', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'starts_on', starts_on, 'ends_on', ends_on, 'status', status,
                  'closed_at', closed_at) order by starts_on), '[]')
                  from public.accounting_periods where starts_on <= v_today + 62 and ends_on >= v_today - 400)
  ) into v;
  return v;
end $$;

-- Cheques received, for the cheque register
create or replace function public.cheque_register(p_status text default null)
returns table (id uuid, payment_no text, customer_id uuid, customer text, amount numeric, reference text, cheque_bank text, cheque_date date,
               received_at timestamptz, cheque_status text, deposited_at timestamptz, deposited_to text, cleared_at timestamptz,
               returned_at timestamptz, reversal_reason text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.payment_no, p.customer_id, c.name, p.amount, p.reference, p.cheque_bank, p.cheque_date, p.received_at, p.cheque_status,
         p.deposited_at, m.name, p.cleared_at, p.returned_at, p.reversal_reason
    from public.payments p join public.customers c on c.id = p.customer_id left join public.money_accounts m on m.id = p.deposited_to
   where p.method = 'cheque' and (app.has_permission('payments.view') or app.has_permission('accounting.view'))
     and (p_status is null or p.cheque_status = p_status)
   order by case p.cheque_status when 'in_hand' then 0 when 'deposited' then 1 when 'returned' then 2 else 3 end, p.received_at desc
   limit 300
$$;

-- ---------------------------------------------------------------------
-- Function privileges (re-applied after functions are added)
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app    from public, anon, authenticated;
grant execute on all functions in schema public to authenticated, service_role;
grant execute on function app.current_user_id()               to authenticated, service_role;
grant execute on function app.has_permission(text)             to authenticated, service_role;
grant execute on function app.has_permission_at(text, uuid)    to authenticated, service_role;
grant execute on function app.pos_permission(uuid)             to authenticated, service_role;
grant execute on function app.is_super_admin(uuid)             to authenticated, service_role;
grant execute on function app.today()                          to authenticated, service_role;
grant execute on function app.own_company_id()                 to authenticated, service_role;
revoke execute on function public.log_failed_login(text, text, text, text) from authenticated;
revoke execute on function public.bootstrap_super_admin(text)              from authenticated;

grant select on all tables in schema public to authenticated, service_role;
revoke all on all tables in schema public from anon;

commit;
