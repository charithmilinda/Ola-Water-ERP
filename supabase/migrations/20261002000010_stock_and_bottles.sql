-- =====================================================================
-- OLA Water ERP — Phase 1A
-- 0010: stock ledger (products) and bottle ledger (containers)
-- =====================================================================
-- Two separate, append-only ledgers:
--   inventory_transactions  — filled product units (water) by location
--   bottle_transactions     — returnable containers by holder, owner company
--                             and fill state, serialised (per bottle) or
--                             counted (count mode)
-- Holders: 'location' (warehouse, vehicle, shop, external holding),
--          'customer', 'company' (an external water company),
--          'outside' (source/sink for bottles entering or leaving).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Product stock
-- ---------------------------------------------------------------------
create table public.inventory_balances (
  location_id  uuid not null references public.locations(id),
  product_id   uuid not null references public.products(id),
  stock_status text not null default 'available' check (stock_status in ('available','damaged')),
  qty          numeric(14,3) not null default 0 check (qty >= 0),
  updated_at   timestamptz not null default now(),
  primary key (location_id, product_id, stock_status)
);

create table public.inventory_transactions (
  id              bigint generated always as identity primary key,
  txn_type        text not null check (txn_type in
                    ('opening','receipt','transfer','load_out','check_in','sale','adjust_gain','adjust_loss','damaged','return')),
  product_id      uuid not null references public.products(id),
  qty             numeric(14,3) not null check (qty > 0),
  from_location   uuid references public.locations(id),
  to_location     uuid references public.locations(id),
  stock_status    text not null default 'available',
  unit_cost       numeric(12,2),
  reference_type  text,
  reference_id    uuid,
  reason          text,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  client_txn_id   uuid,
  check (from_location is not null or to_location is not null)
);
create index inventory_transactions_product_idx on public.inventory_transactions (product_id, created_at desc);
create index inventory_transactions_ref_idx on public.inventory_transactions (reference_type, reference_id);
create trigger inventory_transactions_append_only before update or delete on public.inventory_transactions
  for each row execute function app.forbid_change();

create or replace function app.stock_move(
  p_txn_type text, p_product uuid, p_qty numeric, p_from uuid, p_to uuid,
  p_ref_type text default null, p_ref_id uuid default null, p_reason text default null,
  p_status text default 'available')
returns void language plpgsql security definer set search_path = '' as $$
declare v_have numeric; v_name text; v_loc text;
begin
  if p_qty is null or p_qty = 0 then return; end if;
  if p_qty < 0 then raise exception 'Quantity cannot be negative' using errcode = '22023'; end if;

  if p_from is not null then
    select qty into v_have from public.inventory_balances
     where location_id = p_from and product_id = p_product and stock_status = p_status for update;
    if coalesce(v_have, 0) < p_qty then
      select name into v_name from public.products where id = p_product;
      select name into v_loc from public.locations where id = p_from;
      raise exception 'Not enough stock: % at % has %, needs %', v_name, v_loc, coalesce(v_have, 0)::numeric(14,0), p_qty::numeric(14,0)
        using errcode = 'P0001';
    end if;
    update public.inventory_balances set qty = qty - p_qty, updated_at = now()
     where location_id = p_from and product_id = p_product and stock_status = p_status;
  end if;

  if p_to is not null then
    insert into public.inventory_balances (location_id, product_id, stock_status, qty)
    values (p_to, p_product, p_status, p_qty)
    on conflict (location_id, product_id, stock_status) do update set qty = public.inventory_balances.qty + excluded.qty, updated_at = now();
  end if;

  insert into public.inventory_transactions (txn_type, product_id, qty, from_location, to_location, stock_status,
    unit_cost, reference_type, reference_id, reason, created_by, client_txn_id)
  values (p_txn_type, p_product, p_qty, p_from, p_to, p_status,
    (select cost_price from public.products where id = p_product), p_ref_type, p_ref_id,
    coalesce(p_reason, nullif(current_setting('app.reason', true), '')), app.current_user_id(),
    nullif(current_setting('app.client_txn_id', true), '')::uuid);
end $$;

-- ---------------------------------------------------------------------
-- Bottles (serialised containers)
-- ---------------------------------------------------------------------
create table public.bottles (
  id                uuid primary key default gen_random_uuid(),
  code              text not null unique,
  identifier_id     uuid unique references public.identifiers(id),
  company_id        uuid not null references public.bottle_companies(id),
  bottle_type_id    uuid not null references public.bottle_types(id),
  holder_type       text not null check (holder_type in ('location','customer','company','outside')),
  holder_id         uuid,
  fill_state        text not null default 'empty' check (fill_state in ('full','empty')),
  condition         text not null default 'good' check (condition in ('good','needs_inspection','damaged')),
  lifecycle         text not null default 'active' check (lifecycle in ('active','lost','written_off','retired','returned_to_owner')),
  fill_count        integer not null default 0 check (fill_count >= 0),
  last_batch_no     text,
  intake_photo_path text,
  last_movement_at  timestamptz,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now()
);
create index bottles_holder_idx on public.bottles (holder_type, holder_id);
create index bottles_company_idx on public.bottles (company_id, lifecycle);

create table public.bottle_balances (
  holder_type     text not null check (holder_type in ('location','customer','company','outside')),
  holder_id       uuid not null,
  company_id      uuid not null references public.bottle_companies(id),
  bottle_type_id  uuid not null references public.bottle_types(id),
  fill_state      text not null check (fill_state in ('full','empty')),
  qty             integer not null default 0,
  updated_at      timestamptz not null default now(),
  primary key (holder_type, holder_id, company_id, bottle_type_id, fill_state)
);
comment on table public.bottle_balances is 'Running counts, updated in the same transaction as bottle_transactions. Negative values are allowed and flagged (e.g. bottles held before go-live).';

create table public.bottle_transactions (
  id               bigint generated always as identity primary key,
  txn_type         text not null check (txn_type in
                     ('opening','fill','load_out','deliver','collect','external_intake','check_in','to_external_holding',
                      'return_to_owner','received_from_company','transfer','mark_damaged','write_off','found','relabel','retire','adjust')),
  bottle_id        uuid references public.bottles(id),
  company_id       uuid not null references public.bottle_companies(id),
  bottle_type_id   uuid not null references public.bottle_types(id),
  qty              integer not null check (qty > 0),
  from_type        text not null,
  from_id          uuid not null,
  from_fill        text not null,
  to_type          text not null,
  to_id            uuid not null,
  to_fill          text not null,
  reference_type   text,
  reference_id     uuid,
  reason           text,
  gps_lat          numeric(9,6),
  gps_lng          numeric(9,6),
  created_at       timestamptz not null default now(),
  created_by       uuid,
  client_txn_id    uuid,
  check (bottle_id is null or qty = 1)
);
create index bottle_transactions_bottle_idx on public.bottle_transactions (bottle_id, created_at desc);
create index bottle_transactions_ref_idx    on public.bottle_transactions (reference_type, reference_id);
create index bottle_transactions_from_idx   on public.bottle_transactions (from_type, from_id, created_at desc);
create index bottle_transactions_to_idx     on public.bottle_transactions (to_type, to_id, created_at desc);
create trigger bottle_transactions_append_only before update or delete on public.bottle_transactions
  for each row execute function app.forbid_change();

create or replace function app.outside_id() returns uuid
language sql immutable set search_path = '' as $$ select '00000000-0000-0000-0000-000000000000'::uuid $$;

-- ---------------------------------------------------------------------
-- Exceptions (bottle location mismatches, reconciliation differences...)
-- ---------------------------------------------------------------------
create table public.operation_exceptions (
  id               uuid primary key default gen_random_uuid(),
  exception_type   text not null check (exception_type in
                     ('bottle_location','bottle_shortage','bottle_surplus','stock_shortage','stock_surplus','cash_shortage',
                      'cash_surplus','over_bottle_limit','credit_limit','negative_balance')),
  severity         text not null default 'warning' check (severity in ('info','warning','critical')),
  status           text not null default 'open' check (status in ('open','resolved')),
  run_id           uuid,
  location_id      uuid references public.locations(id),
  customer_id      uuid references public.customers(id),
  bottle_id        uuid references public.bottles(id),
  company_id       uuid references public.bottle_companies(id),
  bottle_type_id   uuid references public.bottle_types(id),
  product_id       uuid references public.products(id),
  expected         numeric(14,2),
  actual           numeric(14,2),
  difference       numeric(14,2),
  description      text not null,
  resolution       text check (resolution in ('found','charge_driver','write_off','accepted')),
  resolution_note  text,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  resolved_at      timestamptz,
  resolved_by      uuid,
  updated_at       timestamptz not null default now()
);
create index operation_exceptions_open_idx on public.operation_exceptions (status, created_at desc);
create index operation_exceptions_run_idx  on public.operation_exceptions (run_id);
create trigger operation_exceptions_touch before update on public.operation_exceptions for each row execute function app.touch_updated_at();
create trigger operation_exceptions_audit after insert or update on public.operation_exceptions for each row execute function app.audit_row('exceptions');

create or replace function app.raise_exception_record(
  p_type text, p_description text, p_severity text default 'warning',
  p_run uuid default null, p_location uuid default null, p_customer uuid default null, p_bottle uuid default null,
  p_company uuid default null, p_bottle_type uuid default null, p_product uuid default null,
  p_expected numeric default null, p_actual numeric default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  insert into public.operation_exceptions (exception_type, severity, run_id, location_id, customer_id, bottle_id, company_id,
    bottle_type_id, product_id, expected, actual, difference, description, created_by)
  values (p_type, p_severity, p_run, p_location, p_customer, p_bottle, p_company, p_bottle_type, p_product,
    p_expected, p_actual, case when p_expected is not null and p_actual is not null then p_actual - p_expected end,
    p_description, app.current_user_id())
  returning id into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Core bottle movement
--   Serialised (p_bottle given): moves that bottle. Counts always follow the
--   physical event (p_from -> p_to). If the bottle's record says it was
--   somewhere else, the scan is still accepted (never block the field), the
--   bottle record is corrected and a bottle_location exception is raised.
--   Counted (p_bottle null): moves p_qty bottles of a company/type.
-- ---------------------------------------------------------------------
create or replace function app.bottle_move(
  p_txn_type text, p_company uuid, p_bottle_type uuid, p_qty integer,
  p_from_type text, p_from_id uuid, p_from_fill text,
  p_to_type text, p_to_id uuid, p_to_fill text,
  p_ref_type text default null, p_ref_id uuid default null,
  p_bottle uuid default null, p_reason text default null,
  p_gps_lat numeric default null, p_gps_lng numeric default null,
  p_run uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  b public.bottles;
  v_from_type text := p_from_type; v_from_id uuid := p_from_id; v_from_fill text := p_from_fill;
  v_company uuid := p_company; v_type uuid := p_bottle_type; v_qty integer := coalesce(p_qty, 0);
begin
  if p_bottle is not null then
    select * into b from public.bottles where id = p_bottle for update;
    if not found then raise exception 'Bottle not found' using errcode = 'P0002'; end if;
    v_company := b.company_id; v_type := b.bottle_type_id; v_qty := 1;
    if b.holder_type <> p_from_type or b.holder_id is distinct from p_from_id then
      -- Bottles moved in count mode keep their old record; a mismatch with a
      -- company location is routine (info). Another customer is a warning.
      perform app.raise_exception_record('bottle_location',
        format('Bottle %s was recorded at %s but was handled at %s', b.code,
               app.holder_label(b.holder_type, b.holder_id), app.holder_label(p_from_type, p_from_id)),
        case when b.holder_type = 'customer' then 'warning' else 'info' end,
        p_run, null, case when p_from_type = 'customer' then p_from_id end, b.id, b.company_id, b.bottle_type_id);
    end if;
    update public.bottles set holder_type = p_to_type, holder_id = p_to_id, fill_state = p_to_fill,
           last_movement_at = now(), updated_at = now(),
           fill_count = fill_count + case when p_txn_type = 'fill' then 1 else 0 end,
           lifecycle = case when p_to_type = 'company' and company_id <> app.own_company_id() then 'returned_to_owner'
                            when p_txn_type = 'write_off' then 'written_off'
                            when p_txn_type = 'retire' then 'retired'
                            when lifecycle in ('lost','returned_to_owner','written_off') and p_txn_type in ('found','received_from_company','collect','external_intake') then 'active'
                            else lifecycle end
     where id = p_bottle;
  end if;

  if v_qty <= 0 then return; end if;

  insert into public.bottle_balances (holder_type, holder_id, company_id, bottle_type_id, fill_state, qty)
  values (v_from_type, coalesce(v_from_id, app.outside_id()), v_company, v_type, v_from_fill, -v_qty)
  on conflict (holder_type, holder_id, company_id, bottle_type_id, fill_state)
  do update set qty = public.bottle_balances.qty - v_qty, updated_at = now();

  insert into public.bottle_balances (holder_type, holder_id, company_id, bottle_type_id, fill_state, qty)
  values (p_to_type, coalesce(p_to_id, app.outside_id()), v_company, v_type, p_to_fill, v_qty)
  on conflict (holder_type, holder_id, company_id, bottle_type_id, fill_state)
  do update set qty = public.bottle_balances.qty + v_qty, updated_at = now();

  insert into public.bottle_transactions (txn_type, bottle_id, company_id, bottle_type_id, qty, from_type, from_id, from_fill,
    to_type, to_id, to_fill, reference_type, reference_id, reason, gps_lat, gps_lng, created_by, client_txn_id)
  values (p_txn_type, p_bottle, v_company, v_type, v_qty, v_from_type, coalesce(v_from_id, app.outside_id()), v_from_fill,
    p_to_type, coalesce(p_to_id, app.outside_id()), p_to_fill, p_ref_type, p_ref_id,
    coalesce(p_reason, nullif(current_setting('app.reason', true), '')), p_gps_lat, p_gps_lng, app.current_user_id(),
    nullif(current_setting('app.client_txn_id', true), '')::uuid);
end $$;

-- Human-readable name of a holder
create or replace function app.holder_label(p_type text, p_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case p_type
    when 'location' then (select name || ' (' || code || ')' from public.locations where id = p_id)
    when 'customer' then (select name || ' (' || customer_no || ')' from public.customers where id = p_id)
    when 'company'  then (select name from public.bottle_companies where id = p_id)
    else 'Outside the company' end
$$;

-- Register a new serialised bottle against a printed label
create or replace function app.register_bottle(
  p_code text, p_company uuid, p_bottle_type uuid, p_holder_type text, p_holder_id uuid, p_fill text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_ident public.identifiers; v uuid; v_entity text;
begin
  select * into v_ident from public.identifiers where value = upper(trim(p_code)) for update;
  if not found then
    raise exception 'Label % was not issued by this system', upper(trim(p_code)) using errcode = 'P0002';
  end if;
  if v_ident.status = 'void' then
    raise exception 'Label % belongs to a cancelled batch', v_ident.value using errcode = '22023';
  end if;
  if v_ident.status = 'assigned' then
    raise exception 'Label % is already on another bottle', v_ident.value using errcode = '23505';
  end if;
  v_entity := case when p_company = app.own_company_id() then 'bottle' else 'external_bottle' end;
  if v_ident.entity_type <> v_entity then
    raise exception 'Label % is a % label, not a % label', v_ident.value, replace(v_ident.entity_type, '_', ' '), replace(v_entity, '_', ' ')
      using errcode = '22023';
  end if;
  if v_entity = 'external_bottle' and v_ident.series_code <> 'EXT-UNK'
     and v_ident.series_code <> 'EXT-' || (select code from public.bottle_companies where id = p_company) then
    raise exception 'Label % is for a different company''s bottles', v_ident.value using errcode = '22023';
  end if;

  insert into public.bottles (code, identifier_id, company_id, bottle_type_id, holder_type, holder_id, fill_state, created_by, last_movement_at)
  values (v_ident.value, v_ident.id, p_company, p_bottle_type, p_holder_type, p_holder_id, p_fill, app.current_user_id(), now())
  returning id into v;

  perform set_config('app.audit_action', 'assign', true);
  update public.identifiers set status = 'assigned', entity_id = v, assigned_at = now(), assigned_by = app.current_user_id()
   where id = v_ident.id;
  perform set_config('app.audit_action', '', true);
  return v;
end $$;

create or replace function app.bottle_by_code(p_code text)
returns public.bottles language sql stable security definer set search_path = '' as $$
  select * from public.bottles where code = upper(trim(p_code))
$$;

-- ---------------------------------------------------------------------
-- Customer bottle deposits (liability)
-- ---------------------------------------------------------------------
create table public.deposit_transactions (
  id               bigint generated always as identity primary key,
  customer_id      uuid not null references public.customers(id),
  bottle_type_id   uuid not null references public.bottle_types(id),
  txn_type         text not null check (txn_type in ('collected','refunded','forfeited','opening')),
  qty              integer not null,
  amount           numeric(12,2) not null,
  reference_type   text,
  reference_id     uuid,
  created_at       timestamptz not null default now(),
  created_by       uuid
);
create index deposit_transactions_customer_idx on public.deposit_transactions (customer_id, bottle_type_id);
create trigger deposit_transactions_append_only before update or delete on public.deposit_transactions
  for each row execute function app.forbid_change();

create or replace view public.customer_deposit_balances with (security_invoker = true) as
  select customer_id, bottle_type_id,
         sum(case when txn_type in ('collected','opening') then qty else -qty end)::integer as qty_held,
         sum(case when txn_type in ('collected','opening') then amount else -amount end) as amount_held
    from public.deposit_transactions
   group by customer_id, bottle_type_id;

-- ---------------------------------------------------------------------
-- External bottle hand-overs to their owners
-- ---------------------------------------------------------------------
create table public.external_handovers (
  id               uuid primary key default gen_random_uuid(),
  handover_no      text not null unique,
  company_id       uuid not null references public.bottle_companies(id),
  handover_date    date not null,
  rep_name         text not null,
  rep_phone        text,
  bottles_given    integer not null default 0,
  ola_received     integer not null default 0,
  proof_path       text,
  notes            text,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  client_txn_id    uuid unique
);
create trigger external_handovers_append_only before update or delete on public.external_handovers
  for each row execute function app.forbid_change();
create trigger external_handovers_audit after insert on public.external_handovers
  for each row execute function app.audit_row('bottles');

-- =====================================================================
-- RPCs: stock
-- =====================================================================

-- Receive stock into a location. p_source: 'opening' (balances at go-live)
-- or 'receipt' (finished goods received, e.g. from production before the
-- Production module exists). Returnable products also fill bottles:
-- 'receipt' fills empties already at that location; 'opening' brings full
-- bottles in from outside.
create or replace function public.receive_stock(
  p_location uuid, p_lines jsonb, p_source text, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v_line jsonb; pr public.products; v_qty numeric; v_value numeric := 0; v_res jsonb;
begin
  perform app.require_permission('inventory.manage');
  if p_source not in ('opening','receipt') then raise exception 'Unknown source' using errcode = '22023'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'receive_stock');
  if v_done is not null then return v_done; end if;
  perform app.set_context(trim(p_reason), p_client_txn_id, null);

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_qty := app.jnum(v_line, 'qty');
    continue when coalesce(v_qty, 0) = 0;
    if v_qty < 0 or v_qty <> trunc(v_qty) then raise exception 'Quantities must be whole positive numbers' using errcode = '22023'; end if;
    select * into pr from public.products where id = app.juuid(v_line, 'product_id');
    if not found then raise exception 'Product not found' using errcode = 'P0002'; end if;

    perform app.stock_move(p_source, pr.id, v_qty, null, p_location, 'stock_receipt', p_client_txn_id);
    if pr.is_returnable then
      if p_source = 'opening' then
        perform app.bottle_move('opening', app.own_company_id(), pr.bottle_type_id, v_qty::integer,
          'outside', app.outside_id(), 'full', 'location', p_location, 'full', 'stock_receipt', p_client_txn_id);
      else
        perform app.bottle_move('fill', app.own_company_id(), pr.bottle_type_id, v_qty::integer,
          'location', p_location, 'empty', 'location', p_location, 'full', 'stock_receipt', p_client_txn_id);
      end if;
    end if;
    v_value := v_value + v_qty * pr.cost_price;
  end loop;

  if p_source = 'opening' and v_value > 0 then
    perform app.post_event('stock.opening', jsonb_build_object('value', v_value), app.today(),
      'Opening stock: ' || trim(p_reason), 'stock_receipt', p_client_txn_id, p_location);
  end if;

  v_res := jsonb_build_object('ok', true, 'value', v_value);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.transfer_stock(
  p_from uuid, p_to uuid, p_lines jsonb, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v_line jsonb; pr public.products; v_qty numeric; v_res jsonb;
begin
  perform app.require_permission('inventory.manage');
  if p_from = p_to then raise exception 'Choose two different locations' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'transfer_stock');
  if v_done is not null then return v_done; end if;
  perform app.set_context(nullif(trim(p_reason), ''), p_client_txn_id, null);
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_qty := app.jnum(v_line, 'qty');
    continue when coalesce(v_qty, 0) = 0;
    select * into pr from public.products where id = app.juuid(v_line, 'product_id');
    perform app.stock_move('transfer', pr.id, v_qty, p_from, p_to, 'stock_transfer', p_client_txn_id);
    if pr.is_returnable then
      perform app.bottle_move('transfer', app.own_company_id(), pr.bottle_type_id, v_qty::integer,
        'location', p_from, 'full', 'location', p_to, 'full', 'stock_transfer', p_client_txn_id);
    end if;
  end loop;
  v_res := jsonb_build_object('ok', true);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Counted stock differs from the system: post a gain or loss.
create or replace function public.adjust_stock(
  p_location uuid, p_product uuid, p_counted numeric, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v_have numeric; v_diff numeric; pr public.products; v_limit numeric; v_res jsonb;
begin
  perform app.require_permission('inventory.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required for a stock adjustment' using errcode = '22023'; end if;
  if p_counted is null or p_counted < 0 then raise exception 'Enter the counted quantity' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'adjust_stock');
  if v_done is not null then return v_done; end if;

  select * into pr from public.products where id = p_product;
  select coalesce(qty, 0) into v_have from public.inventory_balances
   where location_id = p_location and product_id = p_product and stock_status = 'available';
  v_have := coalesce(v_have, 0);
  v_diff := p_counted - v_have;
  v_limit := coalesce((app.get_setting('approvals.stock_adjustment_qty') #>> '{}')::numeric, 0);
  if abs(v_diff) > v_limit and not app.has_permission('inventory.adjust') then
    raise exception 'Adjustments over % units need a Warehouse Manager (inventory.adjust)', v_limit using errcode = '42501';
  end if;
  perform app.set_context(trim(p_reason), p_client_txn_id, 'stock_adjustment');

  if v_diff > 0 then
    perform app.stock_move('adjust_gain', p_product, v_diff, null, p_location, 'stock_adjustment', p_client_txn_id);
    if pr.cost_price > 0 then
      perform app.post_event('stock.adjust_gain', jsonb_build_object('value', v_diff * pr.cost_price), app.today(),
        'Stock count gain: ' || pr.name, 'stock_adjustment', p_client_txn_id, p_location);
    end if;
  elsif v_diff < 0 then
    perform app.stock_move('adjust_loss', p_product, -v_diff, p_location, null, 'stock_adjustment', p_client_txn_id);
    if pr.cost_price > 0 then
      perform app.post_event('stock.adjust_loss', jsonb_build_object('value', -v_diff * pr.cost_price), app.today(),
        'Stock count loss: ' || pr.name, 'stock_adjustment', p_client_txn_id, p_location);
    end if;
  end if;
  v_res := jsonb_build_object('previous', v_have, 'counted', p_counted, 'difference', v_diff);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- =====================================================================
-- RPCs: bottles
-- =====================================================================

-- Register printed OLA labels on bottles that are physically at a location
-- (bottles already in circulation before go-live, or new bottles bought).
create or replace function public.register_bottles(
  p_codes text[], p_bottle_type uuid, p_location uuid, p_fill text, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; c text; v uuid; n integer := 0; v_res jsonb;
begin
  perform app.require_permission('bottles.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'register_bottles');
  if v_done is not null then return v_done; end if;
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Bottle labelled'), p_client_txn_id, null);
  foreach c in array p_codes loop
    continue when nullif(trim(c), '') is null;
    v := app.register_bottle(c, app.own_company_id(), p_bottle_type, 'outside', app.outside_id(), p_fill);
    -- counted bottles at this location become serialised: no net count change
    update public.bottles set holder_type = 'location', holder_id = p_location where id = v;
    n := n + 1;
  end loop;
  v_res := jsonb_build_object('registered', n);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Bottle opening balances (e.g. bottles customers already hold at go-live)
create or replace function public.set_opening_bottles(
  p_holder_type text, p_holder_id uuid, p_company uuid, p_bottle_type uuid, p_fill text, p_qty integer,
  p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v_res jsonb;
begin
  perform app.require_permission('bottles.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  if p_holder_type not in ('location','customer') then raise exception 'Opening bottles go to a location or a customer' using errcode = '22023'; end if;
  if coalesce(p_qty, 0) <= 0 then raise exception 'Quantity must be at least 1' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'set_opening_bottles');
  if v_done is not null then return v_done; end if;
  perform app.set_context(trim(p_reason), p_client_txn_id, null);
  perform app.bottle_move('opening', p_company, p_bottle_type, p_qty, 'outside', app.outside_id(), p_fill,
    p_holder_type, p_holder_id, p_fill, 'opening_balance', p_client_txn_id);
  perform app.write_audit('opening_balance', 'bottles', 'bottle_balances', p_holder_id::text, null,
    jsonb_build_object('holder', app.holder_label(p_holder_type, p_holder_id), 'qty', p_qty, 'fill', p_fill,
      'company', (select name from public.bottle_companies where id = p_company),
      'bottle_type', (select name from public.bottle_types where id = p_bottle_type)));
  v_res := jsonb_build_object('ok', true);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Hand external bottles back to their owner, optionally receiving OLA bottles back.
-- p_give_codes: tagged bottles handed over; p_give_counts: [{bottle_type_id, qty}] untagged
-- p_receive_counts: [{bottle_type_id, qty}] OLA bottles received; p_receive_codes: scanned OLA bottles
create or replace function public.record_external_handover(
  p_company uuid, p_give_codes text[], p_give_counts jsonb, p_receive_codes text[], p_receive_counts jsonb,
  p_rep_name text, p_rep_phone text, p_notes text, p_proof_path text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; v_id uuid := gen_random_uuid(); v_no text; v_hold uuid; b public.bottles; c text; r jsonb;
  v_given integer := 0; v_recv integer := 0; v_wh uuid; v_res jsonb; v_avail integer;
begin
  perform app.require_permission('bottles.external');
  if nullif(trim(p_rep_name), '') is null then
    raise exception 'Enter the name of the company representative who received the bottles' using errcode = '22023';
  end if;
  if p_company = app.own_company_id() then raise exception 'Choose an external company' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'record_external_handover');
  if v_done is not null then return v_done; end if;
  perform app.set_context(null, p_client_txn_id, null);

  select id into v_hold from public.locations where location_type = 'external_holding' order by created_at limit 1;
  select id into v_wh from public.locations where code = 'WH1';
  v_no := app.next_document_number('EHO');

  foreach c in array coalesce(p_give_codes, '{}') loop
    continue when nullif(trim(c), '') is null;
    b := app.bottle_by_code(c);
    if b.id is null then raise exception 'Bottle % not found', c using errcode = 'P0002'; end if;
    if b.company_id <> p_company then raise exception 'Bottle % belongs to another company', b.code using errcode = '22023'; end if;
    perform app.bottle_move('return_to_owner', null, null, 1, 'location', v_hold, 'empty', 'company', p_company, 'empty',
      'external_handover', v_id, b.id);
    v_given := v_given + 1;
  end loop;

  for r in select * from jsonb_array_elements(coalesce(p_give_counts, '[]')) loop
    continue when coalesce(app.jint(r, 'qty'), 0) = 0;
    select coalesce(qty, 0) into v_avail from public.bottle_balances
     where holder_type = 'location' and holder_id = v_hold and company_id = p_company
       and bottle_type_id = app.juuid(r, 'bottle_type_id') and fill_state = 'empty';
    if coalesce(v_avail, 0) - (select count(*) from public.bottles where holder_type = 'location' and holder_id = v_hold
                                and company_id = p_company and bottle_type_id = app.juuid(r, 'bottle_type_id')) < app.jint(r, 'qty') then
      raise exception 'Only % untagged bottles of this type are in external holding', greatest(coalesce(v_avail, 0) - (select count(*) from public.bottles
        where holder_type = 'location' and holder_id = v_hold and company_id = p_company and bottle_type_id = app.juuid(r, 'bottle_type_id')), 0)
        using errcode = '22023';
    end if;
    perform app.bottle_move('return_to_owner', p_company, app.juuid(r, 'bottle_type_id'), app.jint(r, 'qty'),
      'location', v_hold, 'empty', 'company', p_company, 'empty', 'external_handover', v_id);
    v_given := v_given + app.jint(r, 'qty');
  end loop;

  foreach c in array coalesce(p_receive_codes, '{}') loop
    continue when nullif(trim(c), '') is null;
    b := app.bottle_by_code(c);
    if b.id is null then raise exception 'Bottle % not found', c using errcode = 'P0002'; end if;
    perform app.bottle_move('received_from_company', null, null, 1, b.holder_type, b.holder_id, b.fill_state,
      'location', v_wh, 'empty', 'external_handover', v_id, b.id);
    v_recv := v_recv + 1;
  end loop;

  for r in select * from jsonb_array_elements(coalesce(p_receive_counts, '[]')) loop
    continue when coalesce(app.jint(r, 'qty'), 0) = 0;
    perform app.bottle_move('received_from_company', app.own_company_id(), app.juuid(r, 'bottle_type_id'), app.jint(r, 'qty'),
      'company', p_company, 'empty', 'location', v_wh, 'empty', 'external_handover', v_id);
    v_recv := v_recv + app.jint(r, 'qty');
  end loop;

  if v_given + v_recv = 0 then raise exception 'Nothing was handed over or received' using errcode = '22023'; end if;

  insert into public.external_handovers (id, handover_no, company_id, handover_date, rep_name, rep_phone, bottles_given,
    ola_received, proof_path, notes, created_by, client_txn_id)
  values (v_id, v_no, p_company, app.today(), trim(p_rep_name), app.normalize_phone(p_rep_phone), v_given, v_recv,
    p_proof_path, nullif(trim(p_notes), ''), app.current_user_id(), p_client_txn_id);

  v_res := jsonb_build_object('handover_id', v_id, 'handover_no', v_no, 'given', v_given, 'received', v_recv);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Mark a bottle damaged (stays where it is, flagged) or retire it
create or replace function public.mark_bottle(p_code text, p_action text, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare b public.bottles;
begin
  perform app.require_permission('bottles.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  b := app.bottle_by_code(p_code);
  if b.id is null then raise exception 'Bottle not found' using errcode = 'P0002'; end if;
  perform app.set_context(trim(p_reason), null, p_action);
  if p_action = 'damaged' then
    update public.bottles set condition = 'damaged' where id = b.id;
  elsif p_action = 'repaired' then
    update public.bottles set condition = 'good' where id = b.id;
  elsif p_action = 'retire' then
    perform app.bottle_move('retire', null, null, 1, b.holder_type, b.holder_id, b.fill_state, 'outside', app.outside_id(), 'empty',
      'bottle', b.id, b.id, trim(p_reason));
  else
    raise exception 'Unknown action' using errcode = '22023';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.inventory_balances     enable row level security;
alter table public.inventory_transactions enable row level security;
alter table public.bottles                enable row level security;
alter table public.bottle_balances        enable row level security;
alter table public.bottle_transactions    enable row level security;
alter table public.operation_exceptions   enable row level security;
alter table public.deposit_transactions   enable row level security;
alter table public.external_handovers     enable row level security;

create policy inventory_balances_read on public.inventory_balances for select to authenticated
  using (app.has_permission('inventory.view') or app.has_permission('deliveries.manage'));
create policy inventory_transactions_read on public.inventory_transactions for select to authenticated
  using (app.has_permission('inventory.view'));
create policy bottles_read on public.bottles for select to authenticated using (app.has_permission('bottles.view'));
create policy bottle_balances_read on public.bottle_balances for select to authenticated
  using (app.has_permission('bottles.view') or app.has_permission('customers.view'));
create policy bottle_transactions_read on public.bottle_transactions for select to authenticated
  using (app.has_permission('bottles.view'));
create policy operation_exceptions_read on public.operation_exceptions for select to authenticated
  using (app.has_permission('deliveries.reconcile') or app.has_permission('bottles.view') or app.has_permission('inventory.view'));
create policy deposit_transactions_read on public.deposit_transactions for select to authenticated
  using (app.has_permission('customers.view'));
create policy external_handovers_read on public.external_handovers for select to authenticated
  using (app.has_permission('bottles.view'));

revoke insert, update, delete, truncate on
  public.inventory_transactions, public.bottle_transactions, public.deposit_transactions, public.external_handovers
  from anon, authenticated, service_role;
