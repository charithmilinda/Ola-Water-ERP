-- =====================================================================
-- OLA Water ERP — Phase 2C
-- 0032: fleet — vehicle details, documents and expiry, fuel logs,
--       services and repairs, driver expenses on the road
-- =====================================================================
-- Every fuel fill, repair and licence cost is an expense (category, vehicle,
-- approval above the limit, posted to the ledger). Drivers record fuel,
-- tolls and small repairs paid from the cash they carry; the check-in then
-- expects that much less cash. A rejected driver expense becomes a cash
-- shortage the driver owes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Vehicles: more detail
-- ---------------------------------------------------------------------
alter table public.vehicles
  add column make                   text,
  add column model                  text,
  add column year_made              integer check (year_made between 1950 and 2100),
  add column fuel_type              text check (fuel_type in ('diesel','petrol','electric','hybrid','other')),
  add column odometer_km            integer check (odometer_km >= 0),
  add column assigned_driver_id     uuid references public.profiles(id),
  add column service_interval_km    integer check (service_interval_km > 0),
  add column service_interval_days  integer check (service_interval_days > 0),
  add column last_service_km        integer,
  add column last_service_date      date,
  add column asset_id               uuid unique references public.fixed_assets(id);

create table public.vehicle_documents (
  id           uuid primary key default gen_random_uuid(),
  vehicle_id   uuid not null references public.vehicles(id),
  doc_type     text not null check (doc_type in ('insurance','revenue_licence','emission_test','fitness','other')),
  doc_no       text,
  provider     text,
  issued_on    date,
  expires_on   date not null,
  cost         numeric(14,2) check (cost >= 0),
  expense_id   uuid references public.expenses(id),
  notes        text,
  created_at   timestamptz not null default now(),
  created_by   uuid
);
create index vehicle_documents_vehicle_idx on public.vehicle_documents (vehicle_id, doc_type, expires_on desc);
create trigger vehicle_documents_audit after insert or update on public.vehicle_documents for each row execute function app.audit_row('fleet');

create table public.fuel_logs (
  id           uuid primary key default gen_random_uuid(),
  vehicle_id   uuid not null references public.vehicles(id),
  fuel_date    date not null,
  litres       numeric(10,2) not null check (litres > 0),
  amount       numeric(14,2) not null check (amount > 0),
  odometer_km  integer check (odometer_km >= 0),
  station      text,
  driver_id    uuid references public.profiles(id),
  run_id       uuid references public.route_runs(id),
  expense_id   uuid references public.expenses(id),
  created_at   timestamptz not null default now(),
  created_by   uuid
);
create index fuel_logs_vehicle_idx on public.fuel_logs (vehicle_id, fuel_date desc);
create trigger fuel_logs_audit after insert on public.fuel_logs for each row execute function app.audit_row('fleet');

create table public.vehicle_services (
  id            uuid primary key default gen_random_uuid(),
  vehicle_id    uuid not null references public.vehicles(id),
  service_date  date not null,
  kind          text not null check (kind in ('service','repair','tyres','battery','accident','other')),
  description   text not null,
  odometer_km   integer check (odometer_km >= 0),
  cost          numeric(14,2) not null default 0 check (cost >= 0),
  vendor        text,
  expense_id    uuid references public.expenses(id),
  next_due_km   integer,
  next_due_date date,
  created_at    timestamptz not null default now(),
  created_by    uuid
);
create index vehicle_services_vehicle_idx on public.vehicle_services (vehicle_id, service_date desc);
create trigger vehicle_services_audit after insert on public.vehicle_services for each row execute function app.audit_row('fleet');

-- ---------------------------------------------------------------------
-- Expenses: paid from the driver's cash, linked to a run
-- ---------------------------------------------------------------------
alter table public.expenses
  add column run_id     uuid references public.route_runs(id),
  add column driver_id  uuid references public.profiles(id);
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'public.expenses'::regclass and contype = 'c'
            and (pg_get_constraintdef(oid) like '%pay_method%') loop
    execute format('alter table public.expenses drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.expenses add constraint expenses_pay_method_check
  check (pay_method in ('cash','petty_cash','bank_transfer','cheque','card','on_credit','driver_cash'));
alter table public.expenses add constraint expenses_money_account_check
  check (pay_method in ('on_credit','driver_cash') or money_account_id is not null);
alter table public.expenses add constraint expenses_driver_cash_check
  check (pay_method <> 'driver_cash' or (run_id is not null and driver_id is not null));
create index expenses_run_idx on public.expenses (run_id) where run_id is not null;
create index expenses_vehicle_idx on public.expenses (vehicle_id, expense_date) where vehicle_id is not null;

alter table public.expense_categories add column driver_allowed boolean not null default false;

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
  elsif x.pay_method = 'driver_cash' then
    v_lines := v_lines || jsonb_build_object('account_key', 'driver_cash', 'debit', 0, 'credit', x.total, 'memo', 'Paid by the driver',
                                             'party_type', 'driver', 'party_id', x.driver_id);
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
         paid_from = case when x.pay_method in ('on_credit','driver_cash') then null else x.money_account_id end
   where id = x.id;
end $$;

-- Shared by fleet and driver expenses. The caller checks permissions.
--   p: {expense_date, category_code | category_id, description, payee, vehicle_id, asset_id, run_id, driver_id, location_id,
--       net_amount, vat_amount, pay_method, money_account_id, reference, receipt_path}
create or replace function app.create_expense(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid := gen_random_uuid(); v_no text; c public.expense_categories; m public.money_accounts; v_limit numeric; v_auto boolean;
        v_net numeric := round(app.jnum(p, 'net_amount'), 2); v_vat numeric := round(coalesce(app.jnum(p, 'vat_amount'), 0), 2);
        v_method text := coalesce(app.jtext(p, 'pay_method'), 'cash'); v_date date := coalesce((app.jtext(p, 'expense_date'))::date, app.today());
begin
  if app.juuid(p, 'category_id') is not null then
    select * into c from public.expense_categories where id = app.juuid(p, 'category_id') and is_active;
  else
    select * into c from public.expense_categories where code = app.jtext(p, 'category_code') and is_active;
  end if;
  if c.id is null then raise exception 'Choose a category' using errcode = '22023'; end if;
  if coalesce(v_net, 0) <= 0 then raise exception 'Enter the amount' using errcode = '22023'; end if;
  if v_date > app.today() then raise exception 'An expense cannot be dated in the future' using errcode = '22023'; end if;
  if v_method not in ('on_credit','driver_cash') then
    m := app.money_account(app.juuid(p, 'money_account_id'));
    if (v_method = 'cash' and m.kind <> 'cash') or (v_method = 'petty_cash' and m.kind <> 'petty_cash')
       or (v_method in ('bank_transfer','cheque','card') and m.kind <> 'bank') then
      raise exception 'The account does not match how it was paid' using errcode = '22023';
    end if;
  end if;
  v_limit := coalesce((app.get_setting('approvals.expense_amount') #>> '{}')::numeric, 0);
  v_auto := v_net + v_vat < v_limit or app.has_permission('expenses.approve');
  v_no := app.next_document_number('EXP');
  insert into public.expenses (id, expense_no, expense_date, category_id, description, payee, location_id, vehicle_id, asset_id, run_id, driver_id,
    net_amount, vat_amount, total, pay_method, money_account_id, reference, receipt_path, status, created_by, approved_at, approved_by)
  values (v, v_no, v_date, c.id, coalesce(nullif(trim(app.jtext(p, 'description')), ''), c.name), app.jtext(p, 'payee'), app.juuid(p, 'location_id'),
    app.juuid(p, 'vehicle_id'), app.juuid(p, 'asset_id'), app.juuid(p, 'run_id'), app.juuid(p, 'driver_id'), v_net, v_vat, v_net + v_vat,
    v_method, m.id, nullif(trim(app.jtext(p, 'reference')), ''), app.jtext(p, 'receipt_path'), 'pending_approval', app.current_user_id(),
    case when v_auto then now() end, case when v_auto then app.current_user_id() end);
  if v_auto then perform app.post_expense(v); end if;
  return v;
end $$;

-- Rejecting a driver's expense after check-in: the driver owes that cash
create or replace function public.decide_expense(p_id uuid, p_approve boolean, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare x public.expenses; r public.route_runs;
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
    if x.pay_method = 'driver_cash' then
      select * into r from public.route_runs where id = x.run_id;
      if r.status in ('checked_in','closed') then
        perform app.raise_exception_record('cash_shortage',
          format('Driver expense %s (Rs. %s) was rejected — the driver must hand in that cash: %s', x.expense_no,
                 to_char(x.total, 'FM999,999,990.00'), trim(p_note)),
          'warning', r.id, null, null, null, null, null, null, x.total, 0);
        update public.route_runs set status = 'checked_in' where id = r.id and status = 'closed';
      end if;
    end if;
  end if;
  return jsonb_build_object('status', (select status from public.expenses where id = p_id));
end $$;

-- ---------------------------------------------------------------------
-- Fleet records
-- ---------------------------------------------------------------------
create or replace function public.save_vehicle_details(p_vehicle uuid, p jsonb, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_permission('fleet.manage');
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  update public.vehicles set make = app.jtext(p, 'make'), model = app.jtext(p, 'model'), year_made = app.jint(p, 'year_made'),
         fuel_type = app.jtext(p, 'fuel_type'), assigned_driver_id = app.juuid(p, 'assigned_driver_id'),
         service_interval_km = app.jint(p, 'service_interval_km'), service_interval_days = app.jint(p, 'service_interval_days'),
         odometer_km = greatest(coalesce(odometer_km, 0), coalesce(app.jint(p, 'odometer_km'), 0)),
         last_service_km = coalesce(app.jint(p, 'last_service_km'), last_service_km),
         last_service_date = coalesce((app.jtext(p, 'last_service_date'))::date, last_service_date)
   where id = p_vehicle;
  if not found then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
end $$;

create or replace function app.vehicle_expense_payload(p jsonb, p_vehicle uuid, p_category text, p_description text, p_amount numeric)
returns jsonb language sql immutable as $$
  select jsonb_build_object('expense_date', p ->> 'date', 'category_code', p_category, 'description', p_description,
    'payee', p ->> 'payee', 'vehicle_id', p_vehicle, 'net_amount', p_amount, 'vat_amount', coalesce((p ->> 'vat_amount')::numeric, 0),
    'pay_method', coalesce(p ->> 'pay_method', 'cash'), 'money_account_id', p ->> 'money_account_id', 'reference', p ->> 'reference',
    'receipt_path', p ->> 'receipt_path', 'driver_id', p ->> 'driver_id', 'run_id', p ->> 'run_id')
$$;

--   p: {vehicle_id, date, litres, amount, odometer_km, station, driver_id, pay_method, money_account_id, reference, receipt_path}
create or replace function public.record_fuel(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; ve public.vehicles; v_exp uuid; v uuid := gen_random_uuid(); v_res jsonb;
begin
  perform app.require_permission('fleet.manage');
  select * into ve from public.vehicles where id = app.juuid(p, 'vehicle_id');
  if not found then raise exception 'Choose a vehicle' using errcode = '22023'; end if;
  if coalesce(app.jnum(p, 'litres'), 0) <= 0 then raise exception 'Enter the litres' using errcode = '22023'; end if;
  if app.jint(p, 'odometer_km') is not null and app.jint(p, 'odometer_km') < coalesce(ve.odometer_km, 0) - 5 then
    raise exception 'The odometer reading is lower than the last one (% km)', ve.odometer_km using errcode = '22023';
  end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'record_fuel');
  if v_done is not null then return v_done; end if;
  perform app.set_context(null, p_client_txn_id, 'fuel');
  v_exp := app.create_expense(app.vehicle_expense_payload(p || jsonb_build_object('payee', coalesce(app.jtext(p, 'station'), app.jtext(p, 'payee'))),
             ve.id, 'FUEL', format('Fuel %s L — %s', app.jnum(p, 'litres'), ve.registration_no), app.jnum(p, 'amount')));
  insert into public.fuel_logs (id, vehicle_id, fuel_date, litres, amount, odometer_km, station, driver_id, expense_id, created_by)
  values (v, ve.id, coalesce((app.jtext(p, 'date'))::date, app.today()), app.jnum(p, 'litres'), app.jnum(p, 'amount'), app.jint(p, 'odometer_km'),
          app.jtext(p, 'station'), app.juuid(p, 'driver_id'), v_exp, app.current_user_id());
  update public.vehicles set odometer_km = greatest(coalesce(odometer_km, 0), coalesce(app.jint(p, 'odometer_km'), 0)) where id = ve.id;
  v_res := jsonb_build_object('fuel_log_id', v, 'expense_status', (select status from public.expenses where id = v_exp));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

--   p: {vehicle_id, date, kind, description, odometer_km, cost, vendor, next_due_km, next_due_date, pay_method, money_account_id, reference, receipt_path}
create or replace function public.record_vehicle_service(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; ve public.vehicles; v_exp uuid; v uuid := gen_random_uuid(); v_res jsonb; v_kind text := coalesce(app.jtext(p, 'kind'), 'service');
        v_date date := coalesce((app.jtext(p, 'date'))::date, app.today()); v_km integer := app.jint(p, 'odometer_km');
begin
  perform app.require_permission('fleet.manage');
  select * into ve from public.vehicles where id = app.juuid(p, 'vehicle_id');
  if not found then raise exception 'Choose a vehicle' using errcode = '22023'; end if;
  if nullif(trim(app.jtext(p, 'description')), '') is null then raise exception 'Describe the work done' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'record_vehicle_service');
  if v_done is not null then return v_done; end if;
  perform app.set_context(null, p_client_txn_id, 'vehicle_service');
  if coalesce(app.jnum(p, 'cost'), 0) > 0 then
    v_exp := app.create_expense(app.vehicle_expense_payload(p || jsonb_build_object('payee', app.jtext(p, 'vendor')), ve.id, 'VEHICLE_REPAIR',
               format('%s — %s: %s', initcap(v_kind), ve.registration_no, trim(app.jtext(p, 'description'))), app.jnum(p, 'cost')));
  end if;
  insert into public.vehicle_services (id, vehicle_id, service_date, kind, description, odometer_km, cost, vendor, expense_id, next_due_km, next_due_date, created_by)
  values (v, ve.id, v_date, v_kind, trim(app.jtext(p, 'description')), v_km, coalesce(app.jnum(p, 'cost'), 0), app.jtext(p, 'vendor'), v_exp,
          coalesce(app.jint(p, 'next_due_km'), case when v_kind = 'service' and v_km is not null and ve.service_interval_km is not null then v_km + ve.service_interval_km end),
          coalesce((app.jtext(p, 'next_due_date'))::date, case when v_kind = 'service' and ve.service_interval_days is not null then v_date + ve.service_interval_days end),
          app.current_user_id());
  update public.vehicles set odometer_km = greatest(coalesce(odometer_km, 0), coalesce(v_km, 0)),
         last_service_km = case when v_kind = 'service' then coalesce(v_km, last_service_km) else last_service_km end,
         last_service_date = case when v_kind = 'service' then v_date else last_service_date end
   where id = ve.id;
  v_res := jsonb_build_object('service_id', v, 'expense_status', (select status from public.expenses where id = v_exp));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

--   p: {vehicle_id, doc_type, doc_no, provider, issued_on, expires_on, cost, pay_method, money_account_id, reference, notes}
create or replace function public.record_vehicle_document(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; ve public.vehicles; v_exp uuid; v uuid := gen_random_uuid(); v_res jsonb;
begin
  perform app.require_permission('fleet.manage');
  select * into ve from public.vehicles where id = app.juuid(p, 'vehicle_id');
  if not found then raise exception 'Choose a vehicle' using errcode = '22023'; end if;
  if app.jtext(p, 'expires_on') is null then raise exception 'Enter the expiry date' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'record_vehicle_document');
  if v_done is not null then return v_done; end if;
  perform app.set_context(null, p_client_txn_id, 'vehicle_document');
  if coalesce(app.jnum(p, 'cost'), 0) > 0 then
    v_exp := app.create_expense(app.vehicle_expense_payload(p || jsonb_build_object('payee', app.jtext(p, 'provider'),
               'date', coalesce(app.jtext(p, 'issued_on'), app.today()::text)), ve.id, 'VEHICLE_DOCS',
               format('%s — %s', initcap(replace(app.jtext(p, 'doc_type'), '_', ' ')), ve.registration_no), app.jnum(p, 'cost')));
  end if;
  insert into public.vehicle_documents (id, vehicle_id, doc_type, doc_no, provider, issued_on, expires_on, cost, expense_id, notes, created_by)
  values (v, ve.id, app.jtext(p, 'doc_type'), app.jtext(p, 'doc_no'), app.jtext(p, 'provider'), (app.jtext(p, 'issued_on'))::date,
          (app.jtext(p, 'expires_on'))::date, app.jnum(p, 'cost'), v_exp, app.jtext(p, 'notes'), app.current_user_id());
  v_res := jsonb_build_object('document_id', v);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- An asset's maintenance / repair (recorded as an expense)
create or replace function public.record_asset_maintenance(p_asset uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; a public.fixed_assets; v_exp uuid; v_res jsonb;
begin
  perform app.require_permission('assets.manage');
  select * into a from public.fixed_assets where id = p_asset and status = 'active';
  if not found then raise exception 'Active asset not found' using errcode = 'P0002'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'record_asset_maintenance');
  if v_done is not null then return v_done; end if;
  perform app.set_context(null, p_client_txn_id, 'asset_maintenance');
  v_exp := app.create_expense(jsonb_build_object('expense_date', app.jtext(p, 'date'), 'category_code', coalesce(app.jtext(p, 'category_code'), 'EQUIPMENT'),
    'description', format('%s — %s', a.name, trim(app.jtext(p, 'description'))), 'payee', app.jtext(p, 'vendor'), 'asset_id', a.id,
    'location_id', a.location_id, 'net_amount', app.jnum(p, 'cost'), 'vat_amount', coalesce(app.jnum(p, 'vat_amount'), 0),
    'pay_method', coalesce(app.jtext(p, 'pay_method'), 'cash'), 'money_account_id', app.jtext(p, 'money_account_id'),
    'reference', app.jtext(p, 'reference')));
  v_res := jsonb_build_object('expense_id', v_exp, 'status', (select status from public.expenses where id = v_exp));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- Driver expenses from the driver app (works offline: queued, idempotent)
--   p: {category_code, amount, description, litres, odometer_km, receipt_path, expense_date}
-- ---------------------------------------------------------------------
create or replace function public.driver_record_expense(p_run uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; r public.route_runs; c public.expense_categories; v_exp uuid; v_res jsonb; ve public.vehicles;
begin
  r := app.require_run_access(p_run);
  v_done := app.idempotency_begin(p_client_txn_id, 'driver_record_expense');
  if v_done is not null then return v_done; end if;
  if r.status not in ('loaded','in_progress') then raise exception 'Expenses can be added only while the run is on the road' using errcode = '22023'; end if;
  select * into c from public.expense_categories where code = app.jtext(p, 'category_code') and is_active and driver_allowed;
  if not found then raise exception 'Choose fuel, tolls & parking or a repair' using errcode = '22023'; end if;
  if coalesce(app.jnum(p, 'amount'), 0) <= 0 then raise exception 'Enter the amount' using errcode = '22023'; end if;
  if app.jnum(p, 'amount') > r.cash_float + coalesce((select sum(amount) from public.payments where run_id = r.id and method = 'cash' and status = 'received'), 0) then
    raise exception 'That is more than the cash you are carrying' using errcode = '22023';
  end if;
  select * into ve from public.vehicles where id = r.vehicle_id;
  perform app.set_context(app.jtext(p, 'description'), p_client_txn_id, 'driver_expense');
  v_exp := app.create_expense(jsonb_build_object('expense_date', coalesce(app.jtext(p, 'expense_date'), app.today()::text),
    'category_id', c.id, 'description', coalesce(nullif(trim(app.jtext(p, 'description')), ''), c.name) || ' — ' || r.run_no,
    'vehicle_id', r.vehicle_id, 'run_id', r.id, 'driver_id', r.driver_id, 'net_amount', app.jnum(p, 'amount'),
    'pay_method', 'driver_cash', 'receipt_path', app.jtext(p, 'receipt_path'), 'payee', app.jtext(p, 'payee')));
  if c.code = 'FUEL' and coalesce(app.jnum(p, 'litres'), 0) > 0 then
    insert into public.fuel_logs (vehicle_id, fuel_date, litres, amount, odometer_km, station, driver_id, run_id, expense_id, created_by)
    values (r.vehicle_id, app.today(), app.jnum(p, 'litres'), app.jnum(p, 'amount'), app.jint(p, 'odometer_km'), app.jtext(p, 'payee'),
            r.driver_id, r.id, v_exp, app.current_user_id());
    update public.vehicles set odometer_km = greatest(coalesce(odometer_km, 0), coalesce(app.jint(p, 'odometer_km'), 0)) where id = r.vehicle_id;
  end if;
  v_res := jsonb_build_object('expense_id', v_exp, 'expense_no', (select expense_no from public.expenses where id = v_exp),
                              'status', (select status from public.expenses where id = v_exp));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

alter table public.vehicle_documents enable row level security;
alter table public.fuel_logs         enable row level security;
alter table public.vehicle_services  enable row level security;
create policy vehicle_documents_read on public.vehicle_documents for select to authenticated
  using (app.has_permission('fleet.manage') or app.has_permission('deliveries.manage') or app.has_permission('routes.manage'));
create policy fuel_logs_read on public.fuel_logs for select to authenticated
  using (app.has_permission('fleet.manage') or app.has_permission('expenses.view') or driver_id = app.current_user_id());
create policy vehicle_services_read on public.vehicle_services for select to authenticated
  using (app.has_permission('fleet.manage') or app.has_permission('deliveries.manage'));

-- ---------------------------------------------------------------------
-- Check-in: the driver's expenses reduce the cash expected
-- (same as Phase 1A except the marked lines)
-- ---------------------------------------------------------------------
create or replace function public.checkin_route_run(p_run uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; r public.route_runs; v_veh uuid; v_wh uuid; v_ext uuid; v_own uuid := app.own_company_id();
  bal record; v_actual numeric; v_diff numeric; pr public.products; v_code text; b public.bottles; v_dest uuid;
  v_moved integer; v_exc integer := 0; v_cash_expected numeric; v_cash_handed numeric := coalesce(app.jnum(p, 'cash_handed'), 0);
  v_res jsonb; v_lines jsonb := '[]'; bser record; v_remaining integer;
begin
  if not (app.has_permission('inventory.manage') or app.has_permission('deliveries.manage')) then
    raise exception 'Permission denied: check-in is done by the warehouse (inventory.manage)' using errcode = '42501';
  end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'checkin_route_run');
  if v_done is not null then return v_done; end if;
  select * into r from public.route_runs where id = p_run for update;
  if r.status not in ('in_progress','loaded') then
    raise exception 'Run % cannot be checked in (status: %)', r.run_no, replace(r.status, '_', ' ') using errcode = '22023';
  end if;
  if exists (select 1 from public.deliveries where run_id = p_run and status = 'pending') then
    if r.status = 'in_progress' then
      raise exception 'Some stops are still pending. The driver must complete or fail every stop first.' using errcode = '22023';
    end if;
  end if;
  perform app.set_context(nullif(trim(app.jtext(p, 'notes')), ''), p_client_txn_id, 'check_in');
  v_veh := app.vehicle_location(p_run);
  v_wh := r.load_location_id;
  select id into v_ext from public.locations where location_type = 'external_holding' order by created_at limit 1;

  -- unstarted run: put pending orders back to confirmed
  update public.deliveries set status = 'cancelled', failure_reason = 'Run checked in before departure'
   where run_id = p_run and status = 'pending';
  update public.orders set status = 'confirmed'
   where id in (select order_id from public.deliveries where run_id = p_run and failure_reason = 'Run checked in before departure')
     and status in ('loaded','assigned','out_for_delivery');

  -- 1. Products ---------------------------------------------------------------
  for bal in select * from public.inventory_balances where location_id = v_veh and stock_status = 'available' and qty > 0 loop
    select coalesce(sum(app.jnum(x, 'qty')), 0) into v_actual
      from jsonb_array_elements(coalesce(p -> 'products', '[]')) x where app.juuid(x, 'product_id') = bal.product_id;
    select * into pr from public.products where id = bal.product_id;
    v_moved := least(v_actual, bal.qty)::integer;
    if v_moved > 0 then
      perform app.stock_move('check_in', pr.id, v_moved, v_veh, v_wh, 'route_run', p_run);
      if pr.is_returnable then
        perform app.bottle_move('check_in', v_own, pr.bottle_type_id, v_moved, 'location', v_veh, 'full', 'location', v_wh, 'full',
          'route_run', p_run, null, null, null, null, p_run);
      end if;
    end if;
    v_lines := v_lines || jsonb_build_object('item', pr.name, 'expected', bal.qty, 'actual', v_actual);
    if v_actual <> bal.qty then
      v_exc := v_exc + 1;
      perform app.raise_exception_record(case when v_actual < bal.qty then 'stock_shortage' else 'stock_surplus' end,
        format('%s: %s expected back, %s counted', pr.name, bal.qty::integer, v_actual::integer),
        case when v_actual < bal.qty then 'critical' else 'warning' end, p_run, v_veh, null, null, null, null, pr.id, bal.qty, v_actual);
    end if;
  end loop;

  -- 2. Scanned bottles (verified one by one) ----------------------------------
  for v_code in select jsonb_array_elements_text(coalesce(p -> 'scanned_codes', '[]')) loop
    b := app.bottle_by_code(v_code);
    continue when b.id is null;
    v_dest := case when b.company_id = v_own then v_wh else v_ext end;
    perform app.bottle_move(case when b.company_id = v_own then 'check_in' else 'to_external_holding' end, null, null, 1,
      'location', v_veh, 'empty', 'location', v_dest, 'empty', 'route_run', p_run, b.id, null, null, null, p_run);
  end loop;

  -- 3. Bottle counts (empties of all companies; full external bottles are not expected) ---
  for bal in
    select company_id, bottle_type_id, fill_state, qty from public.bottle_balances
     where holder_type = 'location' and holder_id = v_veh and not (company_id = v_own and fill_state = 'full') and qty <> 0
    union
    select app.juuid(x, 'company_id'), app.juuid(x, 'bottle_type_id'), coalesce(app.jtext(x, 'fill_state'), 'empty'), 0
      from jsonb_array_elements(coalesce(p -> 'bottles', '[]')) x
     where not exists (select 1 from public.bottle_balances bb where bb.holder_type = 'location' and bb.holder_id = v_veh
                         and bb.company_id = app.juuid(x, 'company_id') and bb.bottle_type_id = app.juuid(x, 'bottle_type_id')
                         and bb.fill_state = coalesce(app.jtext(x, 'fill_state'), 'empty'))
  loop
    -- expected = what is on the vehicle now (scanned bottles already moved) + scanned of this kind
    select coalesce(sum(app.jint(x, 'qty')), 0) into v_actual
      from jsonb_array_elements(coalesce(p -> 'bottles', '[]')) x
     where app.juuid(x, 'company_id') = bal.company_id and app.juuid(x, 'bottle_type_id') = bal.bottle_type_id
       and coalesce(app.jtext(x, 'fill_state'), 'empty') = bal.fill_state;
    -- counted totals include scanned bottles; subtract the ones already moved
    select v_actual - count(*) into v_actual from public.bottle_transactions bt
     where bt.reference_type = 'route_run' and bt.reference_id = p_run and bt.bottle_id is not null
       and bt.client_txn_id = p_client_txn_id and bt.company_id = bal.company_id and bt.bottle_type_id = bal.bottle_type_id;
    v_actual := greatest(v_actual, 0);
    v_dest := case when bal.company_id = v_own then v_wh else v_ext end;
    v_moved := least(v_actual, greatest(bal.qty, 0))::integer;

    if v_moved > 0 then
      v_remaining := v_moved;
      -- tagged bottles still on the vehicle go first, one by one
      for bser in select id from public.bottles where holder_type = 'location' and holder_id = v_veh and company_id = bal.company_id
                   and bottle_type_id = bal.bottle_type_id and fill_state = bal.fill_state order by last_movement_at limit v_remaining loop
        perform app.bottle_move(case when bal.company_id = v_own then 'check_in' else 'to_external_holding' end, null, null, 1,
          'location', v_veh, bal.fill_state, 'location', v_dest, 'empty', 'route_run', p_run, bser.id, null, null, null, p_run);
        v_remaining := v_remaining - 1;
      end loop;
      if v_remaining > 0 then
        perform app.bottle_move(case when bal.company_id = v_own then 'check_in' else 'to_external_holding' end,
          bal.company_id, bal.bottle_type_id, v_remaining, 'location', v_veh, bal.fill_state, 'location', v_dest, 'empty',
          'route_run', p_run, null, null, null, null, p_run);
      end if;
    end if;

    v_lines := v_lines || jsonb_build_object('item', (select name from public.bottle_companies where id = bal.company_id) || ' '
               || (select name from public.bottle_types where id = bal.bottle_type_id) || ' ' || bal.fill_state,
               'expected', bal.qty, 'actual', v_actual);
    if v_actual <> bal.qty then
      v_exc := v_exc + 1;
      if v_actual > bal.qty then
        -- extra bottles physically present: bring them into stock and flag
        perform app.bottle_move('found', bal.company_id, bal.bottle_type_id, (v_actual - greatest(bal.qty, 0))::integer,
          'outside', app.outside_id(), 'empty', 'location', v_dest, 'empty', 'route_run', p_run, null,
          'More bottles counted than recorded at check-in', null, null, p_run);
      end if;
      perform app.raise_exception_record(case when v_actual < bal.qty then 'bottle_shortage' else 'bottle_surplus' end,
        format('%s %s bottles (%s): %s expected, %s counted',
          (select name from public.bottle_companies where id = bal.company_id),
          (select name from public.bottle_types where id = bal.bottle_type_id), bal.fill_state, bal.qty, v_actual::integer),
        case when v_actual < bal.qty then 'critical' else 'warning' end,
        p_run, v_veh, null, null, bal.company_id, bal.bottle_type_id, null, bal.qty, v_actual);
    end if;
  end loop;

  -- 4. Cash -----------------------------------------------------------------------
  select r.cash_float + coalesce(sum(amount), 0) into v_cash_expected
    from public.payments where run_id = p_run and method = 'cash' and status = 'received';
  -- fuel, tolls and repairs the driver paid from that cash
  v_cash_expected := v_cash_expected - coalesce((select sum(total) from public.expenses
                       where run_id = p_run and pay_method = 'driver_cash' and status <> 'rejected'), 0);
  if v_cash_handed > 0 then
    perform app.post_event('driver.cash_handover', jsonb_build_object('amount', v_cash_handed), app.today(),
      'Cash handed in for ' || r.run_no, 'route_run', p_run, v_veh, 'driver', r.driver_id);
  end if;
  if v_cash_handed <> v_cash_expected then
    v_exc := v_exc + 1;
    perform app.raise_exception_record(case when v_cash_handed < v_cash_expected then 'cash_shortage' else 'cash_surplus' end,
      format('Cash: Rs. %s expected, Rs. %s handed in', to_char(v_cash_expected, 'FM999,999,990.00'), to_char(v_cash_handed, 'FM999,999,990.00')),
      case when v_cash_handed < v_cash_expected then 'critical' else 'warning' end, p_run, null, null, null, null, null, null,
      v_cash_expected, v_cash_handed);
  end if;

  update public.route_runs set status = case when v_exc = 0 then 'closed' else 'checked_in' end,
         cash_expected = v_cash_expected, cash_handed = v_cash_handed, checked_in_at = now(), checked_in_by = app.current_user_id(),
         closed_at = case when v_exc = 0 then now() end
   where id = p_run;

  v_res := jsonb_build_object('run_no', r.run_no, 'exceptions', v_exc, 'lines', v_lines,
                              'cash_expected', v_cash_expected, 'cash_handed', v_cash_handed,
                              'status', case when v_exc = 0 then 'closed' else 'checked_in' end);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Driver app: run data now includes the driver's expenses and only products for sale
create or replace function public.driver_get_run(p_run uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.route_runs; v_res jsonb; v_veh uuid; v_own uuid := app.own_company_id();
begin
  r := app.require_run_access(p_run);
  v_veh := app.vehicle_location(p_run);
  select jsonb_build_object(
    'run', jsonb_build_object('id', r.id, 'run_no', r.run_no, 'run_date', r.run_date, 'status', r.status, 'cash_float', r.cash_float,
             'route', (select name from public.routes where id = r.route_id),
             'vehicle', (select registration_no from public.vehicles where id = r.vehicle_id)),
    'company', jsonb_build_object('name', app.get_setting('company.name') #>> '{}',
             'vat_no', app.get_setting('company.vat_registration_no') #>> '{}',
             'receipt_footer', app.get_setting('receipts.footer_text') #>> '{}'),
    'own_company_id', v_own,
    'companies', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'name', name, 'is_own', is_own,
                    'policy', acceptance_policy) order by is_own desc, name), '[]') from public.bottle_companies where is_active),
    'bottle_types', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'name', name) order by size_litres desc), '[]')
                       from public.bottle_types where is_active),
    'products', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'sku', sku, 'name', name, 'barcode', barcode,
                    'is_returnable', is_returnable, 'bottle_type_id', bottle_type_id) order by sort_order, name), '[]')
                   from public.products where is_active and item_type = 'finished_good'),
    'vehicle_stock', (select coalesce(jsonb_agg(jsonb_build_object('product_id', product_id, 'qty', qty)), '[]')
                        from public.inventory_balances where location_id = v_veh and qty > 0),
    'vehicle_bottles', (select coalesce(jsonb_agg(jsonb_build_object('company_id', company_id, 'bottle_type_id', bottle_type_id,
                          'fill_state', fill_state, 'qty', qty)), '[]')
                          from public.bottle_balances where holder_type = 'location' and holder_id = v_veh and qty <> 0),
    'cash_collected', (select coalesce(sum(amount), 0) from public.payments where run_id = r.id and method = 'cash' and status = 'received'),
    'driver_expenses', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'expense_no', x.expense_no, 'category', c.name, 'total', x.total,
                          'status', x.status, 'description', x.description) order by x.created_at), '[]')
                          from public.expenses x join public.expense_categories c on c.id = x.category_id
                         where x.run_id = r.id and x.pay_method = 'driver_cash'),
    'expense_categories', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name) order by sort_order), '[]')
                             from public.expense_categories where driver_allowed and is_active),
    'bottle_values', (select coalesce(jsonb_agg(jsonb_build_object('bottle_type_id', bt.id, 'company_id', bc.id,
                        'deposit', coalesce((app.bottle_value(bt.id, bc.id)).deposit_amount, 0),
                        'external_charge', coalesce((app.bottle_value(bt.id, bc.id)).external_charge, 0))), '[]')
                        from public.bottle_types bt cross join public.bottle_companies bc where bt.is_active and bc.is_active),
    'settings', jsonb_build_object(
        'external_policy_default', app.get_setting('bottles.external_policy_default') #>> '{}',
        'require_confirmation', coalesce((app.get_setting('deliveries.require_confirmation') #>> '{}')::boolean, false)),
    'stops', (select coalesce(jsonb_agg(stop order by (stop ->> 'stop_sequence')::integer), '[]') from (
       select jsonb_build_object(
         'delivery_id', d.id, 'delivery_no', d.delivery_no, 'stop_sequence', d.stop_sequence, 'status', d.status,
         'failure_reason', d.failure_reason, 'summary', d.summary, 'invoice_id', d.invoice_id,
         'order', jsonb_build_object('id', o.id, 'order_no', o.order_no, 'notes', o.notes, 'time_window', o.time_window,
             'expected_ola_returns', o.expected_ola_returns, 'delivery_charge', o.delivery_charge, 'total', o.total,
             'items', (select coalesce(jsonb_agg(jsonb_build_object('product_id', oi.product_id, 'qty', oi.qty - oi.delivered_qty,
                         'unit_price', oi.unit_price, 'discount', oi.discount) order by oi.line_no), '[]')
                         from public.order_items oi where oi.order_id = o.id)),
         'customer', jsonb_build_object('id', c.id, 'customer_no', c.customer_no, 'name', c.name, 'company_name', c.company_name,
             'phone', c.phone, 'phone2', c.phone2, 'bottle_model', c.bottle_model, 'allowed_bottles', c.allowed_bottles,
             'ola_bottles', app.customer_ola_bottles(c.id), 'outstanding', app.customer_outstanding(c.id),
             'credit_limit', c.credit_limit, 'external_policy', c.external_policy, 'payment_terms_days', c.payment_terms_days,
             'deposits_held', (select coalesce(jsonb_object_agg(bottle_type_id, qty_held), '{}') from public.customer_deposit_balances where customer_id = c.id),
             'prices_include_tax', (select prices_include_tax from public.price_lists where id = c.price_list_id),
             'prices', (select coalesce(jsonb_object_agg(p.id, app.unit_price(p.id, c.price_list_id)), '{}')
                          from public.products p
                         where p.is_active and exists (select 1 from public.price_list_items pli
                               where pli.product_id = p.id and pli.price_list_id = c.price_list_id and pli.effective_from <= app.today()))),
         'address', (select jsonb_build_object('address_line', a.address_line, 'city', a.city, 'gps_lat', a.gps_lat, 'gps_lng', a.gps_lng,
             'delivery_instructions', a.delivery_instructions) from public.customer_addresses a where a.id = d.address_id)
       ) as stop
         from public.deliveries d
         join public.orders o on o.id = d.order_id
         join public.customers c on c.id = d.customer_id
        where d.run_id = r.id and d.status <> 'cancelled') s)
  ) into v_res;
  return v_res;
end $$;
