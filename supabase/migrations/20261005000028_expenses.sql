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
