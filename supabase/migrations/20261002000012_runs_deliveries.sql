-- =====================================================================
-- OLA Water ERP — Phase 1A
-- 0012: route runs, deliveries, driver app RPCs, check-in reconciliation
-- =====================================================================

create table public.route_runs (
  id                 uuid primary key default gen_random_uuid(),
  run_no             text not null unique,
  run_date           date not null,
  route_id           uuid references public.routes(id),
  vehicle_id         uuid not null references public.vehicles(id),
  driver_id          uuid not null references public.profiles(id),
  helper_name        text,
  load_location_id   uuid not null references public.locations(id),
  status             text not null default 'planned' check (status in ('planned','loaded','in_progress','checked_in','closed','cancelled')),
  cash_float         numeric(12,2) not null default 0 check (cash_float >= 0),
  cash_expected      numeric(12,2),
  cash_handed        numeric(12,2),
  loaded_at          timestamptz,
  loaded_by          uuid,
  driver_confirmed_at timestamptz,
  checked_in_at      timestamptz,
  checked_in_by      uuid,
  closed_at          timestamptz,
  notes              text,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  client_txn_id      uuid unique
);
create index route_runs_date_idx on public.route_runs (run_date desc, status);
create index route_runs_driver_idx on public.route_runs (driver_id, run_date desc);
-- one active run per vehicle at a time
create unique index route_runs_one_active_per_vehicle on public.route_runs (vehicle_id)
  where status in ('planned','loaded','in_progress');

create table public.deliveries (
  id                   uuid primary key default gen_random_uuid(),
  delivery_no          text not null unique,
  run_id               uuid not null references public.route_runs(id),
  order_id             uuid not null references public.orders(id),
  customer_id          uuid not null references public.customers(id),
  address_id           uuid references public.customer_addresses(id),
  stop_sequence        integer not null,
  status               text not null default 'pending' check (status in ('pending','delivered','partially_delivered','failed','cancelled')),
  failure_reason       text,
  arrived_at           timestamptz,
  completed_at         timestamptz,
  synced_at            timestamptz,
  gps_lat              numeric(9,6),
  gps_lng              numeric(9,6),
  confirmation_method  text check (confirmation_method in ('signature','otp','photo','none')),
  recipient_name       text,
  signature_data       text check (signature_data is null or length(signature_data) < 120000),
  photo_path           text,
  otp_verified         boolean not null default false,
  invoice_id           uuid references public.invoices(id),
  summary              jsonb,
  notes                text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  client_txn_id        uuid unique
);
create index deliveries_run_idx on public.deliveries (run_id, stop_sequence);
create index deliveries_customer_idx on public.deliveries (customer_id, created_at desc);
create unique index deliveries_one_open_per_order on public.deliveries (order_id) where status = 'pending';

alter table public.invoices add constraint invoices_delivery_fk foreign key (delivery_id) references public.deliveries(id);
alter table public.invoices add constraint invoices_run_fk foreign key (run_id) references public.route_runs(id);
alter table public.payments add constraint payments_run_fk foreign key (run_id) references public.route_runs(id);
alter table public.payments add constraint payments_delivery_fk foreign key (delivery_id) references public.deliveries(id);
alter table public.operation_exceptions add constraint operation_exceptions_run_fk foreign key (run_id) references public.route_runs(id);

create trigger route_runs_touch before update on public.route_runs for each row execute function app.touch_updated_at();
create trigger deliveries_touch before update on public.deliveries for each row execute function app.touch_updated_at();
create trigger route_runs_audit after insert or update on public.route_runs for each row execute function app.audit_row('deliveries');
create trigger deliveries_audit after insert or update on public.deliveries for each row execute function app.audit_row('deliveries');
create trigger deliveries_no_delete before delete on public.deliveries for each row execute function app.forbid_change();

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create or replace function app.require_run_access(p_run uuid)
returns public.route_runs language plpgsql stable security definer set search_path = '' as $$
declare r public.route_runs;
begin
  select * into r from public.route_runs where id = p_run;
  if not found then raise exception 'Route run not found' using errcode = 'P0002'; end if;
  if app.has_permission('deliveries.manage') then return r; end if;
  if app.has_permission('driver.app') and r.driver_id = app.current_user_id() then return r; end if;
  raise exception 'Permission denied: this run belongs to another driver' using errcode = '42501';
end $$;

create or replace function app.vehicle_location(p_run uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select v.location_id from public.route_runs r join public.vehicles v on v.id = r.vehicle_id where r.id = p_run
$$;

create or replace function app.is_driver(p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.user_roles ur join public.roles r on r.id = ur.role_id
                  join public.profiles p on p.id = ur.user_id and p.is_active
                 where ur.user_id = p_user and r.code in ('driver','super_admin','delivery_manager'))
$$;

-- =====================================================================
-- Dispatch
-- =====================================================================
create or replace function public.create_route_run(
  p_run_date date, p_route uuid, p_vehicle uuid, p_driver uuid, p_order_ids uuid[],
  p_helper text, p_notes text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v uuid; v_no text; o record; n integer := 0; v_res jsonb; v_veh public.vehicles;
begin
  perform app.require_permission('deliveries.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'create_route_run');
  if v_done is not null then return v_done; end if;
  perform app.set_context(null, p_client_txn_id, null);

  select * into v_veh from public.vehicles where id = p_vehicle and is_active;
  if not found then raise exception 'Choose an active vehicle' using errcode = '22023'; end if;
  if not app.is_driver(p_driver) then raise exception 'The selected person does not have the Driver role' using errcode = '22023'; end if;
  if exists (select 1 from public.route_runs where vehicle_id = p_vehicle and status in ('planned','loaded','in_progress')) then
    raise exception 'Vehicle % already has an open run. Check it in first.', v_veh.registration_no using errcode = '22023';
  end if;
  if coalesce(array_length(p_order_ids, 1), 0) = 0 then raise exception 'Select at least one order' using errcode = '22023'; end if;

  v_no := app.next_document_number('RUN');
  insert into public.route_runs (run_no, run_date, route_id, vehicle_id, driver_id, helper_name, load_location_id, notes, created_by, client_txn_id)
  values (v_no, p_run_date, p_route, p_vehicle, p_driver, nullif(trim(p_helper), ''),
          (select id from public.locations where code = 'WH1'), nullif(trim(p_notes), ''), app.current_user_id(), p_client_txn_id)
  returning id into v;

  for o in
    select ord.*, c.route_sequence from public.orders ord join public.customers c on c.id = ord.customer_id
     where ord.id = any (p_order_ids) order by c.route_sequence nulls last, c.name for update of ord
  loop
    if o.status <> 'confirmed' then
      raise exception 'Order % is % — only confirmed orders can be dispatched', o.order_no, replace(o.status, '_', ' ') using errcode = '22023';
    end if;
    n := n + 1;
    insert into public.deliveries (delivery_no, run_id, order_id, customer_id, address_id, stop_sequence)
    values (app.next_document_number('DN'), v, o.id, o.customer_id, o.address_id, n);
    perform set_config('app.audit_action', 'assign', true);
    update public.orders set status = 'assigned' where id = o.id;
  end loop;
  perform set_config('app.audit_action', '', true);

  v_res := jsonb_build_object('run_id', v, 'run_no', v_no, 'stops', n);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Suggested load: everything on the run's orders
create or replace function public.run_suggested_load(p_run uuid)
returns table (product_id uuid, product_name text, qty numeric, available numeric)
language sql stable security definer set search_path = '' as $$
  select oi.product_id, p.name, sum(oi.qty - oi.delivered_qty),
         coalesce((select qty from public.inventory_balances b where b.location_id = r.load_location_id
                   and b.product_id = oi.product_id and b.stock_status = 'available'), 0)
    from public.route_runs r
    join public.deliveries d on d.run_id = r.id and d.status = 'pending'
    join public.order_items oi on oi.order_id = d.order_id
    join public.products p on p.id = oi.product_id
   where r.id = p_run and (app.has_permission('deliveries.manage') or app.has_permission('inventory.manage'))
   group by oi.product_id, p.name, p.sort_order, r.load_location_id
   order by p.sort_order, p.name
$$;

-- Warehouse loads the vehicle. p_lines: [{product_id, qty}]
create or replace function public.load_route_run(p_run uuid, p_lines jsonb, p_cash_float numeric, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; r public.route_runs; v_veh uuid; l jsonb; pr public.products; v_qty numeric; v_res jsonb; n integer := 0;
begin
  if not (app.has_permission('inventory.manage') or app.has_permission('deliveries.manage')) then
    raise exception 'Permission denied: inventory.manage is required' using errcode = '42501';
  end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'load_route_run');
  if v_done is not null then return v_done; end if;
  select * into r from public.route_runs where id = p_run for update;
  if r.status <> 'planned' then raise exception 'Run % is already %', r.run_no, replace(r.status, '_', ' ') using errcode = '22023'; end if;
  perform app.set_context(null, p_client_txn_id, 'load_out');
  v_veh := app.vehicle_location(p_run);

  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    v_qty := app.jnum(l, 'qty');
    continue when coalesce(v_qty, 0) <= 0;
    select * into pr from public.products where id = app.juuid(l, 'product_id');
    perform app.stock_move('load_out', pr.id, v_qty, r.load_location_id, v_veh, 'route_run', p_run);
    if pr.is_returnable then
      perform app.bottle_move('load_out', app.own_company_id(), pr.bottle_type_id, v_qty::integer,
        'location', r.load_location_id, 'full', 'location', v_veh, 'full', 'route_run', p_run);
    end if;
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Load at least one product' using errcode = '22023'; end if;

  if coalesce(p_cash_float, 0) > 0 then
    perform app.post_event('driver.cash_float', jsonb_build_object('amount', p_cash_float), app.today(),
      'Cash float for ' || r.run_no, 'route_run', p_run, v_veh, 'driver', r.driver_id);
  end if;

  update public.route_runs set status = 'loaded', cash_float = coalesce(p_cash_float, 0), loaded_at = now(), loaded_by = app.current_user_id()
   where id = p_run;
  perform set_config('app.audit_action', 'load_out', true);
  update public.orders set status = 'loaded' where id in (select order_id from public.deliveries where run_id = p_run and status = 'pending');
  perform set_config('app.audit_action', '', true);

  v_res := jsonb_build_object('ok', true, 'run_no', r.run_no);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Driver confirms what was loaded and starts the run
create or replace function public.driver_start_run(p_run uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.route_runs;
begin
  r := app.require_run_access(p_run);
  if r.status = 'in_progress' then return jsonb_build_object('ok', true); end if;
  if r.status <> 'loaded' then raise exception 'The vehicle has not been loaded yet' using errcode = '22023'; end if;
  perform app.set_context(null, null, 'start_run');
  update public.route_runs set status = 'in_progress', driver_confirmed_at = now() where id = p_run;
  update public.orders set status = 'out_for_delivery' where id in (select order_id from public.deliveries where run_id = p_run and status = 'pending');
  perform set_config('app.audit_action', '', true);
  return jsonb_build_object('ok', true);
end $$;

-- Cancel an order (before it leaves on a vehicle)
create or replace function public.cancel_order(p_order uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.orders;
begin
  perform app.require_permission('orders.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required to cancel an order' using errcode = '22023'; end if;
  select * into o from public.orders where id = p_order for update;
  if o.status not in ('draft','on_hold','confirmed','assigned') then
    raise exception 'Order % is % and can no longer be cancelled', o.order_no, replace(o.status, '_', ' ') using errcode = '22023';
  end if;
  perform app.set_context(trim(p_reason), null, 'cancel');
  update public.deliveries set status = 'cancelled', failure_reason = 'Order cancelled: ' || trim(p_reason)
   where order_id = p_order and status = 'pending';
  update public.orders set status = 'cancelled', cancel_reason = trim(p_reason) where id = p_order;
end $$;

-- =====================================================================
-- Driver app: read everything needed for a run (also cached offline)
-- =====================================================================
create or replace function public.driver_my_runs()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'run_no', r.run_no, 'run_date', r.run_date, 'status', r.status,
           'route', rt.name, 'vehicle', v.registration_no,
           'stops', (select count(*) from public.deliveries d where d.run_id = r.id and d.status <> 'cancelled'),
           'done', (select count(*) from public.deliveries d where d.run_id = r.id and d.status in ('delivered','partially_delivered','failed')))
         order by r.run_date, r.run_no), '[]'::jsonb)
    from public.route_runs r
    join public.vehicles v on v.id = r.vehicle_id
    left join public.routes rt on rt.id = r.route_id
   where r.driver_id = app.current_user_id()
     and (r.status in ('planned','loaded','in_progress') or (r.status in ('checked_in','closed') and r.run_date >= app.today() - 1))
$$;

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
                   from public.products where is_active),
    'vehicle_stock', (select coalesce(jsonb_agg(jsonb_build_object('product_id', product_id, 'qty', qty)), '[]')
                        from public.inventory_balances where location_id = v_veh and qty > 0),
    'vehicle_bottles', (select coalesce(jsonb_agg(jsonb_build_object('company_id', company_id, 'bottle_type_id', bottle_type_id,
                          'fill_state', fill_state, 'qty', qty)), '[]')
                          from public.bottle_balances where holder_type = 'location' and holder_id = v_veh and qty <> 0),
    'cash_collected', (select coalesce(sum(amount), 0) from public.payments where run_id = r.id and method = 'cash' and status = 'received'),
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

-- =====================================================================
-- Complete a delivery (the heart of Phase 1A)
-- p: {
--   lines: [{product_id, qty}],                 -- delivered quantities
--   issued_codes: [code],                       -- optional: scanned full OLA bottles handed over
--   ola_returned_codes: [code],                 -- scanned empty OLA bottles collected
--   ola_returned_counts: [{bottle_type_id, qty}],  -- unscanned empty OLA bottles collected
--   external: [{company_id, bottle_type_id, code, new_tag, qty}],
--             code    = an existing EXT-… tag already on the bottle
--             new_tag = a fresh EXT-… label being applied now
--             neither = count mode (qty bottles)
--   payment: {method, amount, reference, tendered},
--   confirmation: {method, signature_data, photo_path, otp_verified, recipient_name},
--   gps: {lat, lng}, notes, completed_at
-- }
-- =====================================================================
create or replace function public.complete_delivery(p_delivery uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; d public.deliveries; r public.route_runs; o public.orders; c public.customers; pr public.products;
  v_veh uuid; v_own uuid := app.own_company_id(); v_today date := app.today();
  l jsonb; v_qty numeric; v_price numeric; v_disc numeric; v_rate numeric; calc record; oi public.order_items;
  v_lines jsonb := '[]'; v_ln integer := 0; v_net numeric := 0; v_tax numeric := 0; v_total numeric := 0;
  v_cogs numeric := 0; v_deposit numeric := 0; v_refund numeric := 0; v_charge numeric := 0;
  v_issued jsonb := '{}'; v_returned jsonb := '{}'; v_ext_summary jsonb := '[]';
  v_code text; b public.bottles; v_bid uuid; v_left integer; v_type uuid; v_policy text; v_company public.bottle_companies;
  v_ext_qty integer; v_gps_lat numeric := app.jnum(p -> 'gps', 'lat'); v_gps_lng numeric := app.jnum(p -> 'gps', 'lng');
  v_held integer; v_target integer; v_delta integer; bv public.bottle_values; bt record;
  v_inv uuid; v_inv_no text; v_je uuid; v_pay uuid; v_pay_amount numeric := coalesce(app.jnum(p -> 'payment', 'amount'), 0);
  v_status text; v_res jsonb; v_all_done boolean; v_balance integer; v_credit_used numeric;
begin
  v_done := app.idempotency_begin(p_client_txn_id, 'complete_delivery');
  if v_done is not null then return v_done; end if;

  select * into d from public.deliveries where id = p_delivery for update;
  if not found then raise exception 'Delivery not found' using errcode = 'P0002'; end if;
  r := app.require_run_access(d.run_id);
  if r.status <> 'in_progress' then raise exception 'Run % is not in progress (status: %)', r.run_no, replace(r.status, '_', ' ') using errcode = '22023'; end if;
  if d.status <> 'pending' then raise exception 'Delivery % is already %', d.delivery_no, replace(d.status, '_', ' ') using errcode = '22023'; end if;

  select * into o from public.orders where id = d.order_id for update;
  select * into c from public.customers where id = d.customer_id;
  v_veh := app.vehicle_location(r.id);
  perform app.set_context(null, p_client_txn_id, null);

  -- 1. Products delivered -------------------------------------------------
  for l in select * from jsonb_array_elements(coalesce(p -> 'lines', '[]')) loop
    v_qty := app.jnum(l, 'qty');
    continue when coalesce(v_qty, 0) <= 0;
    if v_qty <> trunc(v_qty) then raise exception 'Quantities must be whole numbers' using errcode = '22023'; end if;
    select * into pr from public.products where id = app.juuid(l, 'product_id');
    if not found then raise exception 'Unknown product' using errcode = 'P0002'; end if;

    select * into oi from public.order_items where order_id = o.id and product_id = pr.id order by line_no limit 1;
    if oi.id is not null then
      v_price := oi.unit_price;
      v_disc := case when oi.qty > 0 then round(oi.discount * least(v_qty, oi.qty) / oi.qty, 2) else 0 end;
      update public.order_items set delivered_qty = delivered_qty + v_qty where id = oi.id;
    else
      v_price := app.unit_price(pr.id, o.price_list_id, v_today);
      v_disc := 0;
    end if;
    v_rate := app.tax_rate(pr.tax_code, v_today);
    select * into calc from app.calc_line(v_qty, v_price, v_disc, v_rate, o.prices_include_tax);

    perform app.stock_move('sale', pr.id, v_qty, v_veh, null, 'delivery', d.id);
    v_cogs := v_cogs + v_qty * pr.cost_price;

    v_ln := v_ln + 1;
    v_lines := v_lines || jsonb_build_object('line_type', 'product', 'product_id', pr.id, 'description', pr.name, 'qty', v_qty,
      'unit_price', v_price, 'discount', v_disc, 'tax_rate', v_rate, 'net', calc.net, 'tax', calc.tax, 'total', calc.total);
    v_net := v_net + calc.net; v_tax := v_tax + calc.tax; v_total := v_total + calc.total;

    if pr.is_returnable then
      v_left := v_qty::integer;
      -- scanned full bottles of this type first
      for v_code in select jsonb_array_elements_text(coalesce(p -> 'issued_codes', '[]')) loop
        exit when v_left = 0;
        b := app.bottle_by_code(v_code);
        continue when b.id is null or b.bottle_type_id <> pr.bottle_type_id or b.company_id <> v_own
              or (b.holder_type = 'customer' and b.holder_id = c.id);
        perform app.bottle_move('deliver', null, null, 1, 'location', v_veh, 'full', 'customer', c.id, 'full',
          'delivery', d.id, b.id, null, v_gps_lat, v_gps_lng, r.id);
        v_left := v_left - 1;
      end loop;
      if v_left > 0 then
        perform app.bottle_move('deliver', v_own, pr.bottle_type_id, v_left, 'location', v_veh, 'full', 'customer', c.id, 'full',
          'delivery', d.id, null, null, v_gps_lat, v_gps_lng, r.id);
      end if;
      v_issued := jsonb_set(v_issued, array[pr.bottle_type_id::text],
                            to_jsonb(coalesce((v_issued ->> pr.bottle_type_id::text)::integer, 0) + v_qty::integer));
    end if;
  end loop;

  -- 2. OLA empties collected ---------------------------------------------
  --    A scanned label that is printed but not yet on a bottle is registered
  --    on the spot; an unknown label is counted and flagged. Never block.
  for v_code in select jsonb_array_elements_text(coalesce(p -> 'ola_returned_codes', '[]')) loop
    b := app.bottle_by_code(v_code);
    if b.id is null and upper(trim(v_code)) like 'EXT-%' then
      -- an external tag in the OLA list: hand it to the external-bottle step (company from the tag prefix)
      select id into v_bid from public.bottle_companies
       where code = split_part(upper(trim(v_code)), '-', 2) and not is_own;
      if v_bid is not null then
        p := jsonb_set(p, '{external}', coalesce(p -> 'external', '[]') || jsonb_build_array(jsonb_build_object(
               'company_id', v_bid, 'code', upper(trim(v_code)))));
        continue;
      end if;
    end if;
    if b.id is null then
      if exists (select 1 from public.identifiers where value = upper(trim(v_code)) and status = 'unassigned' and entity_type = 'bottle') then
        v_bid := app.register_bottle(v_code, v_own, coalesce(app.juuid(p, 'default_bottle_type_id'),
                   (select id from public.bottle_types where is_active order by size_litres desc limit 1)), 'customer', c.id, 'full');
        select * into b from public.bottles where id = v_bid;
      else
        v_type := coalesce(app.juuid(p, 'default_bottle_type_id'), (select id from public.bottle_types where is_active order by size_litres desc limit 1));
        perform app.bottle_move('collect', v_own, v_type, 1, 'customer', c.id, 'full', 'location', v_veh, 'empty',
          'delivery', d.id, null, 'Unknown label ' || upper(trim(v_code)), v_gps_lat, v_gps_lng, r.id);
        perform app.raise_exception_record('bottle_location', format('Unknown label %s scanned at %s — counted as an OLA bottle', upper(trim(v_code)), c.name),
          'warning', r.id, null, c.id, null, v_own, v_type);
        v_returned := jsonb_set(v_returned, array[v_type::text], to_jsonb(coalesce((v_returned ->> v_type::text)::integer, 0) + 1));
        continue;
      end if;
    end if;
    if b.company_id <> v_own then
      -- an external tag scanned in the OLA list: treat it as an external bottle
      p := jsonb_set(p, '{external}', coalesce(p -> 'external', '[]') || jsonb_build_array(jsonb_build_object(
             'company_id', b.company_id, 'bottle_type_id', b.bottle_type_id, 'code', b.code)));
      continue;
    end if;
    perform app.bottle_move('collect', null, null, 1, 'customer', c.id, 'full', 'location', v_veh, 'empty',
      'delivery', d.id, b.id, null, v_gps_lat, v_gps_lng, r.id);
    v_returned := jsonb_set(v_returned, array[b.bottle_type_id::text],
                            to_jsonb(coalesce((v_returned ->> b.bottle_type_id::text)::integer, 0) + 1));
  end loop;
  for l in select * from jsonb_array_elements(coalesce(p -> 'ola_returned_counts', '[]')) loop
    v_qty := app.jint(l, 'qty');
    continue when coalesce(v_qty, 0) <= 0;
    perform app.bottle_move('collect', v_own, app.juuid(l, 'bottle_type_id'), v_qty::integer, 'customer', c.id, 'full',
      'location', v_veh, 'empty', 'delivery', d.id, null, null, v_gps_lat, v_gps_lng, r.id);
    v_returned := jsonb_set(v_returned, array[app.jtext(l, 'bottle_type_id')],
                            to_jsonb(coalesce((v_returned ->> app.jtext(l, 'bottle_type_id'))::integer, 0) + v_qty::integer));
  end loop;

  -- 3. External bottles collected -----------------------------------------
  for l in select * from jsonb_array_elements(coalesce(p -> 'external', '[]')) loop
    select * into v_company from public.bottle_companies where id = app.juuid(l, 'company_id');
    if not found or v_company.is_own then raise exception 'Choose the bottle''s company' using errcode = '22023'; end if;
    v_type := coalesce(app.juuid(l, 'bottle_type_id'), app.juuid(p, 'default_bottle_type_id'),
                       (select id from public.bottle_types where is_active order by size_litres desc limit 1));
    v_policy := app.external_policy(c.id, v_company.id);
    if v_policy = 'refuse' then
      raise exception '% bottles are not accepted from this customer', v_company.name using errcode = '22023';
    end if;

    v_code := coalesce(app.jtext(l, 'code'), app.jtext(l, 'new_tag'));
    if v_code is not null then
      b := app.bottle_by_code(v_code);
      if b.id is not null then
        v_type := b.bottle_type_id;
        perform app.bottle_move('external_intake', null, null, 1, b.holder_type, b.holder_id, b.fill_state, 'location', v_veh, 'empty',
          'delivery', d.id, b.id, null, v_gps_lat, v_gps_lng, r.id);
      elsif exists (select 1 from public.identifiers where value = upper(trim(v_code)) and status = 'unassigned') then
        v_bid := app.register_bottle(v_code, v_company.id, v_type, 'outside', app.outside_id(), 'empty');
        perform app.bottle_move('external_intake', null, null, 1, 'outside', app.outside_id(), 'empty', 'location', v_veh, 'empty',
          'delivery', d.id, v_bid, null, v_gps_lat, v_gps_lng, r.id);
      else
        perform app.bottle_move('external_intake', v_company.id, v_type, 1, 'outside', app.outside_id(), 'empty',
          'location', v_veh, 'empty', 'delivery', d.id, null, 'Unknown label ' || upper(trim(v_code)), v_gps_lat, v_gps_lng, r.id);
        perform app.raise_exception_record('bottle_location', format('Unknown label %s scanned at %s — counted as a %s bottle',
          upper(trim(v_code)), c.name, v_company.name), 'warning', r.id, null, c.id, null, v_company.id, v_type);
      end if;
      v_ext_qty := 1;
    else
      v_ext_qty := coalesce(app.jint(l, 'qty'), 1);
      if v_ext_qty <= 0 then continue; end if;
      perform app.bottle_move('external_intake', v_company.id, v_type, v_ext_qty, 'outside', app.outside_id(), 'empty',
        'location', v_veh, 'empty', 'delivery', d.id, null, null, v_gps_lat, v_gps_lng, r.id);
    end if;

    -- the customer's OLA bottle that this external bottle replaces is gone
    if v_policy in ('accept_one_for_one','accept_with_charge') then
      perform app.bottle_move('adjust', v_own, v_type, v_ext_qty, 'customer', c.id, 'full', 'outside', app.outside_id(), 'empty',
        'delivery', d.id, null, format('Exchanged for %s %s bottle(s)', v_ext_qty, v_company.name), v_gps_lat, v_gps_lng, r.id);
      v_returned := jsonb_set(v_returned, array[v_type::text],
                              to_jsonb(coalesce((v_returned ->> v_type::text)::integer, 0) + v_ext_qty));
    end if;
    if v_policy = 'accept_with_charge' then
      bv := app.bottle_value(v_type, v_company.id, v_today);
      if coalesce(bv.external_charge, 0) > 0 then
        v_ln := v_ln + 1;
        v_lines := v_lines || jsonb_build_object('line_type', 'bottle_charge', 'bottle_type_id', v_type,
          'description', v_company.name || ' bottle charge', 'qty', v_ext_qty, 'unit_price', bv.external_charge, 'discount', 0,
          'tax_rate', 0, 'net', v_ext_qty * bv.external_charge, 'tax', 0, 'total', v_ext_qty * bv.external_charge);
        v_charge := v_charge + v_ext_qty * bv.external_charge;
      end if;
    end if;
    v_ext_summary := v_ext_summary || jsonb_build_object('company', v_company.name, 'company_id', v_company.id, 'qty', v_ext_qty,
                                                         'policy', v_policy);
  end loop;

  -- 4. Deposits and bottle limits -----------------------------------------
  for bt in select id, name from public.bottle_types loop
    v_balance := app.customer_ola_bottles(c.id, bt.id);
    if c.bottle_model = 'deposit' then
      select coalesce(sum(qty_held), 0) into v_held from public.customer_deposit_balances
       where customer_id = c.id and bottle_type_id = bt.id;
      v_target := greatest(v_balance, 0);
      v_delta := v_target - v_held;
      continue when v_delta = 0;
      bv := app.bottle_value(bt.id, v_own, v_today);
      continue when coalesce(bv.deposit_amount, 0) = 0;
      v_ln := v_ln + 1;
      if v_delta > 0 then
        v_lines := v_lines || jsonb_build_object('line_type', 'deposit', 'bottle_type_id', bt.id, 'description', 'Bottle deposit ' || bt.name,
          'qty', v_delta, 'unit_price', bv.deposit_amount, 'discount', 0, 'tax_rate', 0,
          'net', v_delta * bv.deposit_amount, 'tax', 0, 'total', v_delta * bv.deposit_amount);
        v_deposit := v_deposit + v_delta * bv.deposit_amount;
        insert into public.deposit_transactions (customer_id, bottle_type_id, txn_type, qty, amount, reference_type, reference_id, created_by)
        values (c.id, bt.id, 'collected', v_delta, v_delta * bv.deposit_amount, 'delivery', d.id, app.current_user_id());
      else
        v_lines := v_lines || jsonb_build_object('line_type', 'deposit_refund', 'bottle_type_id', bt.id, 'description', 'Deposit refund ' || bt.name,
          'qty', -v_delta, 'unit_price', -bv.deposit_amount, 'discount', 0, 'tax_rate', 0,
          'net', v_delta * bv.deposit_amount, 'tax', 0, 'total', v_delta * bv.deposit_amount);
        v_refund := v_refund - v_delta * bv.deposit_amount;
        insert into public.deposit_transactions (customer_id, bottle_type_id, txn_type, qty, amount, reference_type, reference_id, created_by)
        values (c.id, bt.id, 'refunded', -v_delta, -v_delta * bv.deposit_amount, 'delivery', d.id, app.current_user_id());
      end if;
    elsif c.bottle_model = 'loan' and v_balance > c.allowed_bottles and (v_issued ? bt.id::text) then
      perform app.raise_exception_record('over_bottle_limit',
        format('%s now holds %s %s bottles (limit %s)', c.name, v_balance, bt.name, c.allowed_bottles),
        'info', r.id, null, c.id, null, v_own, bt.id, null, c.allowed_bottles, v_balance);
    end if;
  end loop;

  -- 5. Delivery charge ------------------------------------------------------
  if o.delivery_charge > 0 and not exists (select 1 from public.invoices where order_id = o.id) then
    v_ln := v_ln + 1;
    v_lines := v_lines || jsonb_build_object('line_type', 'delivery_charge', 'description', 'Delivery charge', 'qty', 1,
      'unit_price', o.delivery_charge, 'discount', 0, 'tax_rate', 0, 'net', o.delivery_charge, 'tax', 0, 'total', o.delivery_charge);
  end if;

  -- 6. Invoice + journal ----------------------------------------------------
  if jsonb_array_length(v_lines) > 0 then
    v_inv := gen_random_uuid();
    v_inv_no := app.next_document_number('INV');
    v_total := v_total + v_deposit - v_refund + v_charge +
               case when o.delivery_charge > 0 and v_lines @> '[{"line_type":"delivery_charge"}]' then o.delivery_charge else 0 end;
    insert into public.invoices (id, invoice_no, customer_id, order_id, delivery_id, run_id, location_id, invoice_date, due_date,
      is_tax_invoice, subtotal_net, tax_total, deposit_net, other_charges, total, status, created_by, client_txn_id)
    values (v_inv, v_inv_no, c.id, o.id, d.id, r.id, v_veh, v_today, v_today + c.payment_terms_days, c.vat_no is not null,
      v_net, v_tax, v_deposit - v_refund, v_charge + case when v_lines @> '[{"line_type":"delivery_charge"}]' then o.delivery_charge else 0 end,
      v_total, case when v_total <= 0 then 'credit' else 'open' end, app.current_user_id(), p_client_txn_id);
    insert into public.invoice_lines (invoice_id, line_no, line_type, product_id, bottle_type_id, description, qty, unit_price,
      discount, tax_rate, net, tax, total)
    select v_inv, ord, x ->> 'line_type', nullif(x ->> 'product_id', '')::uuid, nullif(x ->> 'bottle_type_id', '')::uuid,
           x ->> 'description', (x ->> 'qty')::numeric, (x ->> 'unit_price')::numeric, (x ->> 'discount')::numeric,
           (x ->> 'tax_rate')::numeric, (x ->> 'net')::numeric, (x ->> 'tax')::numeric, (x ->> 'total')::numeric
      from jsonb_array_elements(v_lines) with ordinality as t(x, ord);

    v_je := app.post_event('invoice.issued', jsonb_build_object(
        'ar_debit', greatest(v_total, 0), 'ar_credit', greatest(-v_total, 0),
        'net', v_net, 'vat', v_tax, 'delivery', case when v_lines @> '[{"line_type":"delivery_charge"}]' then o.delivery_charge else 0 end,
        'deposit', v_deposit, 'deposit_refund', v_refund, 'bottle_charge', v_charge),
      v_today, format('Invoice %s — %s', v_inv_no, c.name), 'invoice', v_inv, v_veh, 'customer', c.id);
    update public.invoices set journal_entry_id = v_je where id = v_inv;

    if v_cogs > 0 then
      perform app.post_event('cogs.sale', jsonb_build_object('value', v_cogs), v_today,
        format('Cost of goods — %s', v_inv_no), 'invoice', v_inv, v_veh);
    end if;

    -- apply any credit the customer already has on account
    for v_pay in select id from public.payments where customer_id = c.id and status = 'received' and unallocated > 0 order by received_at loop
      perform app.allocate_payment(v_pay, v_inv);
    end loop;
    perform app.refresh_invoice_status(v_inv);
  end if;

  -- 7. Payment collected ------------------------------------------------------
  if v_pay_amount > 0 then
    v_pay := app.create_payment(c.id, coalesce(app.jtext(p -> 'payment', 'method'), 'cash'), v_pay_amount,
      app.jtext(p -> 'payment', 'reference'), r.id, d.id, v_inv, null, null);
  end if;

  -- 8. Order + delivery status ------------------------------------------------
  select bool_and(delivered_qty >= qty) into v_all_done from public.order_items where order_id = o.id;
  v_status := case when v_all_done then 'delivered'
                   when exists (select 1 from public.order_items where order_id = o.id and delivered_qty > 0) then 'partially_delivered'
                   else 'delivered' end;   -- bottle-collection-only stops count as delivered
  update public.orders set status = v_status where id = o.id;

  v_res := jsonb_build_object(
    'delivery_id', d.id, 'delivery_no', d.delivery_no, 'invoice_id', v_inv, 'invoice_no', v_inv_no,
    'customer', jsonb_build_object('name', c.name, 'customer_no', c.customer_no),
    'lines', v_lines, 'subtotal_net', v_net, 'tax_total', v_tax, 'total', coalesce(v_total, 0),
    'paid', v_pay_amount, 'method', app.jtext(p -> 'payment', 'method'),
    'tendered', app.jnum(p -> 'payment', 'tendered'),
    'change', greatest(coalesce(app.jnum(p -> 'payment', 'tendered'), v_pay_amount) - v_pay_amount, 0),
    'outstanding', app.customer_outstanding(c.id),
    'bottles', jsonb_build_object('issued', v_issued, 'returned', v_returned, 'external', v_ext_summary,
                                  'balance', app.customer_ola_bottles(c.id)));

  update public.deliveries set
    status = v_status,
    completed_at = coalesce((app.jtext(p, 'completed_at'))::timestamptz, now()),
    synced_at = now(),
    gps_lat = v_gps_lat, gps_lng = v_gps_lng,
    confirmation_method = coalesce(app.jtext(p -> 'confirmation', 'method'), 'none'),
    recipient_name = app.jtext(p -> 'confirmation', 'recipient_name'),
    signature_data = app.jtext(p -> 'confirmation', 'signature_data'),
    photo_path = app.jtext(p -> 'confirmation', 'photo_path'),
    otp_verified = app.jbool(p -> 'confirmation', 'otp_verified', false),
    invoice_id = v_inv, summary = v_res, notes = app.jtext(p, 'notes'), client_txn_id = p_client_txn_id
  where id = d.id;

  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- A stop that could not be delivered. Optionally re-books the order for another day.
create or replace function public.fail_delivery(p_delivery uuid, p_reason text, p_notes text, p_reschedule_date date,
  p_gps jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; d public.deliveries; r public.route_runs; v_res jsonb;
begin
  v_done := app.idempotency_begin(p_client_txn_id, 'fail_delivery');
  if v_done is not null then return v_done; end if;
  select * into d from public.deliveries where id = p_delivery for update;
  if not found then raise exception 'Delivery not found' using errcode = 'P0002'; end if;
  r := app.require_run_access(d.run_id);
  if d.status <> 'pending' then raise exception 'Delivery % is already %', d.delivery_no, d.status using errcode = '22023'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'Choose a reason' using errcode = '22023'; end if;
  perform app.set_context(trim(p_reason), p_client_txn_id, 'fail');

  update public.deliveries set status = 'failed', failure_reason = trim(p_reason), notes = nullif(trim(p_notes), ''),
         completed_at = now(), synced_at = now(), gps_lat = app.jnum(p_gps, 'lat'), gps_lng = app.jnum(p_gps, 'lng'),
         client_txn_id = p_client_txn_id
   where id = d.id;
  if p_reschedule_date is not null then
    perform set_config('app.audit_action', 'reschedule', true);
    update public.orders set status = 'confirmed', requested_date = p_reschedule_date where id = d.order_id;
  else
    update public.orders set status = 'failed' where id = d.order_id;
  end if;
  perform set_config('app.audit_action', '', true);
  v_res := jsonb_build_object('ok', true, 'rescheduled', p_reschedule_date);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- =====================================================================
-- Check-in: expected vs actual, with exceptions for every difference
-- p: { products: [{product_id, qty}],                       -- full units returned
--      bottles:  [{company_id, bottle_type_id, fill_state, qty}],  -- bottles counted (empties + external)
--      scanned_codes: [code],                                -- optional, tagged bottles verified one by one
--      cash_handed, notes }
-- =====================================================================
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

-- =====================================================================
-- Resolve an exception
--   found         — the missing items were found (moved to the warehouse / cash handed in)
--   charge_driver — the driver pays (bottles/cash remain the driver's debt)
--   write_off     — loss accepted and expensed (needs bottles.writeoff for bottles)
--   accepted      — information only, nothing moves
-- =====================================================================
create or replace function public.resolve_exception(p_id uuid, p_resolution text, p_note text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; e public.operation_exceptions; r public.route_runs; v_qty integer; v_amount numeric; v_own uuid := app.own_company_id();
  v_dest uuid; bv public.bottle_values; pr public.products; v_veh uuid;
begin
  perform app.require_permission('deliveries.reconcile');
  if nullif(trim(p_note), '') is null then raise exception 'Explain the resolution' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'resolve_exception');
  if v_done is not null then return v_done; end if;
  select * into e from public.operation_exceptions where id = p_id for update;
  if not found then raise exception 'Exception not found' using errcode = 'P0002'; end if;
  if e.status = 'resolved' then raise exception 'Already resolved' using errcode = '22023'; end if;
  perform app.set_context(trim(p_note), p_client_txn_id, 'resolve');
  if e.run_id is not null then select * into r from public.route_runs where id = e.run_id; v_veh := app.vehicle_location(e.run_id); end if;

  if e.exception_type = 'bottle_shortage' then
    v_qty := (e.expected - e.actual)::integer;
    v_dest := case when e.company_id = v_own then r.load_location_id
                   else (select id from public.locations where location_type = 'external_holding' order by created_at limit 1) end;
    bv := app.bottle_value(e.bottle_type_id, e.company_id);
    if p_resolution = 'found' then
      perform app.bottle_move(case when e.company_id = v_own then 'check_in' else 'to_external_holding' end, e.company_id, e.bottle_type_id,
        v_qty, 'location', v_veh, 'empty', 'location', v_dest, 'empty', 'exception', e.id);
    elsif p_resolution in ('write_off','charge_driver') then
      if p_resolution = 'write_off' then perform app.require_permission('bottles.writeoff'); end if;
      perform app.bottle_move('write_off', e.company_id, e.bottle_type_id, v_qty, 'location', v_veh, 'empty', 'outside', app.outside_id(), 'empty',
        'exception', e.id);
      v_amount := v_qty * coalesce(bv.replacement_value, 0);
      if p_resolution = 'write_off' and e.company_id = v_own and v_amount > 0 then
        perform app.post_event('bottle.writeoff', jsonb_build_object('value', v_amount), app.today(),
          'Bottles written off: ' || e.description, 'exception', e.id);
      elsif p_resolution = 'charge_driver' and v_amount > 0 then
        perform app.post_event('driver.bottle_charge', jsonb_build_object('amount', v_amount), app.today(),
          'Bottles charged to driver: ' || e.description, 'exception', e.id, null, 'driver', r.driver_id);
      end if;
    elsif p_resolution <> 'accepted' then
      raise exception 'Unsupported resolution' using errcode = '22023';
    end if;

  elsif e.exception_type = 'stock_shortage' then
    v_qty := (e.expected - e.actual)::integer;
    select * into pr from public.products where id = e.product_id;
    if p_resolution = 'found' then
      perform app.stock_move('check_in', pr.id, v_qty, v_veh, r.load_location_id, 'exception', e.id);
      if pr.is_returnable then
        perform app.bottle_move('check_in', v_own, pr.bottle_type_id, v_qty, 'location', v_veh, 'full', 'location', r.load_location_id, 'full',
          'exception', e.id);
      end if;
    elsif p_resolution in ('write_off','charge_driver') then
      perform app.require_permission('inventory.adjust');
      perform app.stock_move('adjust_loss', pr.id, v_qty, v_veh, null, 'exception', e.id);
      if pr.is_returnable then
        perform app.bottle_move('write_off', v_own, pr.bottle_type_id, v_qty, 'location', v_veh, 'full', 'outside', app.outside_id(), 'empty',
          'exception', e.id);
      end if;
      if pr.cost_price > 0 then
        perform app.post_event(case when p_resolution = 'write_off' then 'stock.adjust_loss' else 'driver.stock_charge' end,
          jsonb_build_object('value', v_qty * pr.cost_price, 'amount', v_qty * pr.cost_price), app.today(),
          'Stock shortage: ' || e.description, 'exception', e.id, null,
          case when p_resolution = 'charge_driver' then 'driver' end, case when p_resolution = 'charge_driver' then r.driver_id end);
      end if;
    elsif p_resolution <> 'accepted' then
      raise exception 'Unsupported resolution' using errcode = '22023';
    end if;

  elsif e.exception_type = 'cash_shortage' then
    v_amount := e.expected - e.actual;
    if p_resolution = 'found' then
      perform app.post_event('driver.cash_handover', jsonb_build_object('amount', v_amount), app.today(),
        'Shortage handed in: ' || r.run_no, 'exception', e.id, null, 'driver', r.driver_id);
    elsif p_resolution = 'write_off' then
      perform app.require_permission('accounting.manual_journal');
      perform app.post_event('driver.cash_shortage', jsonb_build_object('amount', v_amount), app.today(),
        'Cash shortage written off: ' || r.run_no, 'exception', e.id, null, 'driver', r.driver_id);
    elsif p_resolution not in ('charge_driver','accepted') then
      raise exception 'Unsupported resolution' using errcode = '22023';
    end if;

  elsif p_resolution <> 'accepted' then
    raise exception 'This exception can only be acknowledged' using errcode = '22023';
  end if;

  update public.operation_exceptions set status = 'resolved', resolution = p_resolution, resolution_note = trim(p_note),
         resolved_at = now(), resolved_by = app.current_user_id()
   where id = p_id;

  if e.run_id is not null and not exists (select 1 from public.operation_exceptions where run_id = e.run_id and status = 'open'
       and exception_type in ('bottle_shortage','bottle_surplus','stock_shortage','stock_surplus','cash_shortage','cash_surplus')) then
    update public.route_runs set status = 'closed', closed_at = now() where id = e.run_id and status = 'checked_in';
  end if;

  perform app.idempotency_finish(p_client_txn_id, jsonb_build_object('ok', true));
  return jsonb_build_object('ok', true);
end $$;

-- Receipt print / reprint (audited)
create or replace function public.record_receipt_print(p_invoice uuid, p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
declare i public.invoices; d public.deliveries;
begin
  select * into i from public.invoices where id = p_invoice for update;
  if not found then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if not (app.has_permission('payments.view') or app.has_permission('orders.view')) then
    select * into d from public.deliveries where id = i.delivery_id;
    perform app.require_run_access(d.run_id);
  end if;
  if i.print_count > 0 and nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required to reprint a receipt' using errcode = '22023';
  end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, case when i.print_count > 0 then 'reprint' else 'print' end);
  update public.invoices set print_count = print_count + 1 where id = p_invoice;
  perform set_config('app.audit_action', '', true);
  return i.print_count + 1;
end $$;

-- Everything a receipt needs (office or the run's driver)
create or replace function public.get_receipt(p_invoice uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare i public.invoices; d public.deliveries; v jsonb;
begin
  select * into i from public.invoices where id = p_invoice;
  if not found then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if not (app.has_permission('payments.view') or app.has_permission('orders.view') or app.has_permission('customers.view')) then
    select * into d from public.deliveries where id = i.delivery_id;
    perform app.require_run_access(d.run_id);
  end if;
  select jsonb_build_object(
    'invoice_no', i.invoice_no, 'invoice_date', i.invoice_date, 'created_at', i.created_at, 'is_tax_invoice', i.is_tax_invoice,
    'print_count', i.print_count, 'subtotal_net', i.subtotal_net, 'tax_total', i.tax_total, 'total', i.total,
    'amount_paid', i.amount_paid, 'balance', i.balance,
    'company', jsonb_build_object('name', app.get_setting('company.name') #>> '{}', 'vat_no', app.get_setting('company.vat_registration_no') #>> '{}',
                                  'footer', app.get_setting('receipts.footer_text') #>> '{}'),
    'customer', (select jsonb_build_object('name', name, 'customer_no', customer_no, 'vat_no', vat_no, 'phone', phone)
                   from public.customers where id = i.customer_id),
    'staff', (select full_name from public.profiles where id = i.created_by),
    'lines', (select jsonb_agg(jsonb_build_object('description', description, 'qty', qty, 'unit_price', unit_price, 'discount', discount,
                'total', total, 'line_type', line_type) order by line_no) from public.invoice_lines where invoice_id = i.id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', p.method, 'amount', pa.amount, 'payment_no', p.payment_no)), '[]')
                   from public.payment_allocations pa join public.payments p on p.id = pa.payment_id where pa.invoice_id = i.id),
    'summary', (select summary from public.deliveries where id = i.delivery_id),
    'outstanding', app.customer_outstanding(i.customer_id),
    'ola_bottles', app.customer_ola_bottles(i.customer_id)
  ) into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.route_runs enable row level security;
alter table public.deliveries enable row level security;
create policy route_runs_read on public.route_runs for select to authenticated
  using (app.has_permission('deliveries.view') or driver_id = app.current_user_id());
create policy deliveries_read on public.deliveries for select to authenticated
  using (app.has_permission('deliveries.view')
         or exists (select 1 from public.route_runs r where r.id = run_id and r.driver_id = app.current_user_id()));
