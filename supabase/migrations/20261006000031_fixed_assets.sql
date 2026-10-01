-- =====================================================================
-- OLA Water ERP — Phase 2C
-- 0031: fixed assets — register, monthly depreciation, maintenance,
--       disposal
-- =====================================================================
-- Acquisition: Dr asset cost account / Cr cash or bank (or opening equity
--   for assets owned before go-live, with their depreciation to date).
-- Depreciation (monthly run): Dr Depreciation / Cr Accumulated Depreciation.
--   Straight line: (cost − residual) ÷ useful life in months.
--   Reducing balance: book value × annual rate ÷ 12.
-- Disposal: remove cost and accumulated depreciation; proceeds to cash or
--   bank; the difference is a gain or loss on disposal.
-- =====================================================================

create table public.asset_categories (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique check (code ~ '^[A-Z0-9_-]{2,12}$'),
  name                text not null,
  asset_account_id    uuid not null references public.accounts(id),
  method              text not null default 'straight_line' check (method in ('straight_line','reducing_balance')),
  useful_life_months  integer check (useful_life_months > 0),
  rate_percent        numeric(6,2) check (rate_percent > 0 and rate_percent <= 100),
  residual_percent    numeric(5,2) not null default 0 check (residual_percent between 0 and 100),
  is_active           boolean not null default true,
  check (method <> 'straight_line' or useful_life_months is not null),
  check (method <> 'reducing_balance' or rate_percent is not null)
);
create trigger asset_categories_audit after insert or update on public.asset_categories for each row execute function app.audit_row('assets');

create table public.fixed_assets (
  id                     uuid primary key default gen_random_uuid(),
  asset_no               text not null unique,
  name                   text not null check (length(trim(name)) > 0),
  category_id            uuid not null references public.asset_categories(id),
  serial_no              text,
  description            text,
  location_id            uuid references public.locations(id),
  responsible_employee_id uuid references public.employees(id),
  supplier_name          text,
  purchase_date          date not null,
  cost                   numeric(16,2) not null check (cost > 0),
  residual_value         numeric(16,2) not null default 0 check (residual_value >= 0),
  method                 text not null check (method in ('straight_line','reducing_balance')),
  useful_life_months     integer check (useful_life_months > 0),
  rate_percent           numeric(6,2),
  depreciation_start     date not null,
  opening_accumulated    numeric(16,2) not null default 0 check (opening_accumulated >= 0),
  accumulated            numeric(16,2) not null default 0 check (accumulated >= 0),
  warranty_until         date,
  funding                text not null check (funding in ('paid','opening','recorded')),
  money_account_id       uuid references public.money_accounts(id),
  status                 text not null default 'active' check (status in ('active','disposed')),
  disposed_on            date,
  disposal_proceeds      numeric(16,2),
  disposal_note          text,
  journal_entry_id       uuid references public.journal_entries(id),
  disposal_entry_id      uuid references public.journal_entries(id),
  created_at             timestamptz not null default now(),
  created_by             uuid,
  updated_at             timestamptz not null default now(),
  client_txn_id          uuid unique,
  check (residual_value < cost),
  check (opening_accumulated <= cost - residual_value),
  check (accumulated <= cost)
);
create index fixed_assets_category_idx on public.fixed_assets (category_id, status);
create trigger fixed_assets_touch before update on public.fixed_assets for each row execute function app.touch_updated_at();
create trigger fixed_assets_audit after insert or update on public.fixed_assets for each row execute function app.audit_row('assets');

create table public.depreciation_runs (
  id                uuid primary key default gen_random_uuid(),
  run_no            text not null unique,
  dep_year          integer not null,
  dep_month         integer not null check (dep_month between 1 and 12),
  assets            integer not null default 0,
  total             numeric(16,2) not null default 0,
  journal_entry_id  uuid references public.journal_entries(id),
  created_at        timestamptz not null default now(),
  created_by        uuid,
  unique (dep_year, dep_month)
);
create trigger depreciation_runs_audit after insert on public.depreciation_runs for each row execute function app.audit_row('assets');

create table public.asset_depreciation (
  asset_id   uuid not null references public.fixed_assets(id),
  run_id     uuid not null references public.depreciation_runs(id),
  dep_year   integer not null,
  dep_month  integer not null,
  amount     numeric(16,2) not null check (amount > 0),
  primary key (asset_id, dep_year, dep_month)
);
create trigger asset_depreciation_append_only before update or delete on public.asset_depreciation for each row execute function app.forbid_change();

-- Maintenance and repairs are expenses linked to the asset
alter table public.expenses add column asset_id uuid references public.fixed_assets(id);

-- ---------------------------------------------------------------------
create or replace function public.save_asset_category(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; a public.accounts;
begin
  perform app.require_permission('assets.manage');
  select * into a from public.accounts where id = app.juuid(p, 'asset_account_id');
  if not found or a.account_type <> 'asset' or not a.is_postable then raise exception 'Choose the fixed-asset ledger account' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    insert into public.asset_categories (code, name, asset_account_id, method, useful_life_months, rate_percent, residual_percent)
    values (upper(trim(app.jtext(p, 'code'))), trim(app.jtext(p, 'name')), a.id, coalesce(app.jtext(p, 'method'), 'straight_line'),
            app.jint(p, 'useful_life_months'), app.jnum(p, 'rate_percent'), coalesce(app.jnum(p, 'residual_percent'), 0)) returning id into v;
  else
    update public.asset_categories set name = trim(app.jtext(p, 'name')), asset_account_id = a.id, method = coalesce(app.jtext(p, 'method'), method),
           useful_life_months = app.jint(p, 'useful_life_months'), rate_percent = app.jnum(p, 'rate_percent'),
           residual_percent = coalesce(app.jnum(p, 'residual_percent'), 0), is_active = app.jbool(p, 'is_active', true)
     where id = p_id returning id into v;
  end if;
  if v is null then raise exception 'Category not found' using errcode = 'P0002'; end if;
  return v;
end $$;

--   p: {name, category_id, serial_no, description, location_id, responsible_employee_id, supplier_name, purchase_date, cost,
--       residual_value, method, useful_life_months, rate_percent, depreciation_start, warranty_until,
--       funding: paid | opening | recorded, money_account_id, reference, opening_accumulated, vehicle_id}
create or replace function public.register_asset(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; c public.asset_categories; m public.money_accounts; v uuid := gen_random_uuid(); v_no text; v_je uuid; v_res jsonb;
  v_cost numeric := round(app.jnum(p, 'cost'), 2); v_fund text := coalesce(app.jtext(p, 'funding'), 'paid');
  v_date date := (app.jtext(p, 'purchase_date'))::date; v_res_val numeric; v_open numeric := round(coalesce(app.jnum(p, 'opening_accumulated'), 0), 2);
  v_lines jsonb;
begin
  perform app.require_permission('assets.manage');
  select * into c from public.asset_categories where id = app.juuid(p, 'category_id') and is_active;
  if not found then raise exception 'Choose an asset category' using errcode = '22023'; end if;
  if coalesce(v_cost, 0) <= 0 then raise exception 'Enter the cost' using errcode = '22023'; end if;
  if v_date is null or v_date > app.today() then raise exception 'Enter the purchase date (not in the future)' using errcode = '22023'; end if;
  if v_fund not in ('paid','opening','recorded') then raise exception 'Say how the asset was paid for' using errcode = '22023'; end if;
  if v_fund <> 'opening' and v_open > 0 then raise exception 'Depreciation to date is only for assets owned before go-live' using errcode = '22023'; end if;
  if v_fund = 'paid' then m := app.money_account(app.juuid(p, 'money_account_id')); end if;
  v_res_val := coalesce(app.jnum(p, 'residual_value'), round(v_cost * c.residual_percent / 100, 2));
  v_done := app.idempotency_begin(p_client_txn_id, 'register_asset');
  if v_done is not null then return v_done; end if;
  perform app.set_context(null, p_client_txn_id, 'register_asset');
  v_no := app.next_document_number('FA');
  insert into public.fixed_assets (id, asset_no, name, category_id, serial_no, description, location_id, responsible_employee_id, supplier_name,
    purchase_date, cost, residual_value, method, useful_life_months, rate_percent, depreciation_start, opening_accumulated, accumulated,
    warranty_until, funding, money_account_id, created_by, client_txn_id)
  values (v, v_no, trim(app.jtext(p, 'name')), c.id, app.jtext(p, 'serial_no'), app.jtext(p, 'description'), app.juuid(p, 'location_id'),
    app.juuid(p, 'responsible_employee_id'), app.jtext(p, 'supplier_name'), v_date, v_cost, v_res_val,
    coalesce(app.jtext(p, 'method'), c.method), coalesce(app.jint(p, 'useful_life_months'), c.useful_life_months),
    coalesce(app.jnum(p, 'rate_percent'), c.rate_percent),
    coalesce((app.jtext(p, 'depreciation_start'))::date, date_trunc('month', v_date)::date), v_open, v_open,
    (app.jtext(p, 'warranty_until'))::date, v_fund, m.id, app.current_user_id(), p_client_txn_id);

  if v_fund = 'paid' then
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', c.asset_account_id, 'debit', v_cost, 'credit', 0, 'memo', v_no),
      jsonb_build_object('account_id', m.account_id, 'debit', 0, 'credit', v_cost, 'memo', 'Bought ' || trim(app.jtext(p, 'name'))));
  elsif v_fund = 'opening' then
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', c.asset_account_id, 'debit', v_cost, 'credit', 0, 'memo', v_no),
      jsonb_build_object('account_key', 'opening_equity', 'debit', 0, 'credit', v_cost - v_open, 'memo', 'Opening balance'));
    if v_open > 0 then
      v_lines := v_lines || jsonb_build_object('account_key', 'accum_depreciation', 'debit', 0, 'credit', v_open, 'memo', 'Depreciation before go-live');
    end if;
  end if;
  if v_lines is not null then
    v_je := app.post_journal(case when v_fund = 'opening' then app.today() else app.open_posting_date(v_date) end,
      format('Fixed asset %s — %s', v_no, trim(app.jtext(p, 'name'))), 'asset.acquired', v_lines, 'fixed_asset', v);
    update public.fixed_assets set journal_entry_id = v_je where id = v;
  end if;
  if app.juuid(p, 'vehicle_id') is not null then
    update public.vehicles set asset_id = v where id = app.juuid(p, 'vehicle_id');
  end if;
  v_res := jsonb_build_object('asset_id', v, 'asset_no', v_no);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Details that do not change the books
create or replace function public.update_asset(p_id uuid, p jsonb, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_permission('assets.manage');
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  update public.fixed_assets set name = coalesce(nullif(trim(app.jtext(p, 'name')), ''), name), serial_no = app.jtext(p, 'serial_no'),
         description = app.jtext(p, 'description'), location_id = app.juuid(p, 'location_id'),
         responsible_employee_id = app.juuid(p, 'responsible_employee_id'), warranty_until = (app.jtext(p, 'warranty_until'))::date,
         supplier_name = app.jtext(p, 'supplier_name')
   where id = p_id;
  if not found then raise exception 'Asset not found' using errcode = 'P0002'; end if;
end $$;

-- Depreciation for one asset for one month (0 when nothing is due)
create or replace function app.asset_month_depreciation(a public.fixed_assets, p_year integer, p_month integer)
returns numeric language plpgsql stable set search_path = '' as $$
declare v_month_start date := make_date(p_year, p_month, 1); v_left numeric; v numeric;
begin
  if a.status <> 'active' then return 0; end if;  -- run depreciation up to the disposal month before disposing
  if date_trunc('month', a.depreciation_start) > v_month_start then return 0; end if;
  v_left := a.cost - a.residual_value - a.accumulated;
  if v_left <= 0 then return 0; end if;
  if a.method = 'straight_line' then
    v := round((a.cost - a.residual_value) / a.useful_life_months, 2);
  else
    v := round((a.cost - a.accumulated) * a.rate_percent / 100 / 12, 2);
  end if;
  return least(v, v_left);
end $$;

create or replace function public.run_depreciation(p_year integer, p_month integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := gen_random_uuid(); v_no text; a public.fixed_assets; v_amt numeric; v_total numeric := 0; n integer := 0;
        v_end date := (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date; v_je uuid;
begin
  perform app.require_permission('assets.manage');
  if make_date(p_year, p_month, 1) > date_trunc('month', app.today())::date then
    raise exception 'Depreciation cannot be run for a future month' using errcode = '22023';
  end if;
  if exists (select 1 from public.depreciation_runs where dep_year = p_year and dep_month = p_month) then
    raise exception 'Depreciation for %-% has already been run', p_year, lpad(p_month::text, 2, '0') using errcode = '22023';
  end if;
  if exists (select 1 from public.depreciation_runs where (dep_year, dep_month) > (p_year, p_month)) then
    raise exception 'A later month has already been depreciated — run months in order' using errcode = '22023';
  end if;
  perform app.set_context(null, null, 'depreciation');
  v_no := app.next_document_number('DEP', null, v_end);
  insert into public.depreciation_runs (id, run_no, dep_year, dep_month, created_by) values (v, v_no, p_year, p_month, app.current_user_id());
  for a in select * from public.fixed_assets where status = 'active' order by asset_no for update loop
    v_amt := app.asset_month_depreciation(a, p_year, p_month);
    continue when v_amt <= 0;
    insert into public.asset_depreciation (asset_id, run_id, dep_year, dep_month, amount) values (a.id, v, p_year, p_month, v_amt);
    update public.fixed_assets set accumulated = accumulated + v_amt where id = a.id;
    v_total := v_total + v_amt; n := n + 1;
  end loop;
  if v_total > 0 then
    v_je := app.post_journal(app.open_posting_date(v_end), format('Depreciation %s', to_char(v_end, 'FMMonth YYYY')), 'asset.depreciation',
      jsonb_build_array(jsonb_build_object('account_key', 'exp_depreciation', 'debit', v_total, 'credit', 0, 'memo', 'Depreciation'),
                        jsonb_build_object('account_key', 'accum_depreciation', 'debit', 0, 'credit', v_total, 'memo', 'Depreciation')),
      'depreciation_run', v);
  end if;
  update public.depreciation_runs set assets = n, total = v_total, journal_entry_id = v_je where id = v;
  return jsonb_build_object('run_no', v_no, 'assets', n, 'total', v_total);
end $$;

create or replace function public.dispose_asset(p_id uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; a public.fixed_assets; c public.asset_categories; m public.money_accounts; v_proceeds numeric := round(coalesce(app.jnum(p, 'proceeds'), 0), 2);
        v_date date := coalesce((app.jtext(p, 'disposed_on'))::date, app.today()); v_nbv numeric; v_gain numeric; v_lines jsonb; v_je uuid; v_res jsonb;
begin
  perform app.require_permission('assets.manage');
  if nullif(trim(app.jtext(p, 'reason')), '') is null then raise exception 'Say why the asset is disposed of' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'dispose_asset');
  if v_done is not null then return v_done; end if;
  select * into a from public.fixed_assets where id = p_id for update;
  if not found or a.status <> 'active' then raise exception 'Active asset not found' using errcode = 'P0002'; end if;
  if v_date > app.today() or v_date < a.purchase_date then raise exception 'Check the disposal date' using errcode = '22023'; end if;
  if v_proceeds > 0 then m := app.money_account(app.juuid(p, 'money_account_id')); end if;
  select * into c from public.asset_categories where id = a.category_id;
  perform app.set_context(trim(app.jtext(p, 'reason')), p_client_txn_id, 'dispose_asset');
  v_nbv := a.cost - a.accumulated;
  v_gain := v_proceeds - v_nbv;
  v_lines := jsonb_build_array(jsonb_build_object('account_id', c.asset_account_id, 'debit', 0, 'credit', a.cost, 'memo', 'Cost removed'));
  if a.accumulated > 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'accum_depreciation', 'debit', a.accumulated, 'credit', 0, 'memo', 'Depreciation removed');
  end if;
  if v_proceeds > 0 then
    v_lines := v_lines || jsonb_build_object('account_id', m.account_id, 'debit', v_proceeds, 'credit', 0, 'memo', 'Sale proceeds');
  end if;
  if v_gain > 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'gain_on_disposal', 'debit', 0, 'credit', v_gain, 'memo', 'Gain on disposal');
  elsif v_gain < 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'loss_on_disposal', 'debit', -v_gain, 'credit', 0, 'memo', 'Loss on disposal');
  end if;
  v_je := app.post_journal(v_date, format('Disposal of %s — %s', a.asset_no, a.name), 'asset.disposed', v_lines, 'fixed_asset', a.id);
  update public.fixed_assets set status = 'disposed', disposed_on = v_date, disposal_proceeds = v_proceeds,
         disposal_note = trim(app.jtext(p, 'reason')), disposal_entry_id = v_je where id = a.id;
  update public.vehicles set is_active = false where asset_id = a.id and app.jbool(p, 'deactivate_vehicle', true);
  v_res := jsonb_build_object('book_value', v_nbv, 'gain', v_gain);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

alter table public.asset_categories   enable row level security;
alter table public.fixed_assets       enable row level security;
alter table public.depreciation_runs  enable row level security;
alter table public.asset_depreciation enable row level security;
create policy asset_categories_read on public.asset_categories for select to authenticated
  using (app.has_permission('assets.manage') or app.has_permission('accounting.view') or app.has_permission('fleet.manage'));
create policy fixed_assets_read on public.fixed_assets for select to authenticated
  using (app.has_permission('assets.manage') or app.has_permission('accounting.view') or app.has_permission('fleet.manage'));
create policy depreciation_runs_read on public.depreciation_runs for select to authenticated
  using (app.has_permission('assets.manage') or app.has_permission('accounting.view'));
create policy asset_depreciation_read on public.asset_depreciation for select to authenticated
  using (app.has_permission('assets.manage') or app.has_permission('accounting.view') or app.has_permission('fleet.manage'));
