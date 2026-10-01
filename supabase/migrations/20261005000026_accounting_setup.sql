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
