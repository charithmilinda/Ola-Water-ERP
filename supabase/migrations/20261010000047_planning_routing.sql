-- =====================================================================
-- OLA Water ERP — Phase 4
-- 0047: route ordering by GPS (no outside map service), demand
--       forecast, production and material suggestions, customers due
--       for a refill, analytics series for the charts
-- =====================================================================

insert into public.setting_definitions (key, module, label, description, value_type, choices, min_value, max_value, sort_order) values
  ('planning.road_factor', 'Planning', 'Road distance ÷ straight-line distance',
   'Used to estimate road kilometres from GPS points (about 1.3 in towns)', 'number', null, 1, 3, 110),
  ('planning.safety_stock_days', 'Planning', 'Safety stock (days of demand)',
   'Extra finished stock to keep when suggesting production', 'integer', null, 0, 30, 111),
  ('planning.refill_window_days', 'Planning', 'Show customers due for a refill within (days)', null, 'integer', null, 0, 14, 112)
on conflict (key) do nothing;
insert into public.system_settings (key, value, effective_from)
select v.k, v.val::jsonb, date '2026-01-01'
  from (values ('planning.road_factor', '1.3'), ('planning.safety_stock_days', '2'), ('planning.refill_window_days', '2')) v(k, val)
 where not exists (select 1 from public.system_settings s where s.key = v.k);

-- ---------------------------------------------------------------------
-- Stop ordering: nearest neighbour from the start, then 2-opt.
-- Point 1 is the start (warehouse or last completed stop). Returns the
-- visiting order of points 2..n as indexes into the input arrays.
-- ---------------------------------------------------------------------
create or replace function app.tour_order(p_lat float8[], p_lng float8[], p_return boolean default true)
returns integer[] language plpgsql immutable set search_path = '' as $$
declare
  n integer := coalesce(array_length(p_lat, 1), 0);
  dm float8[]; o integer[] := '{}'; used boolean[]; cur integer := 1; best integer; bd float8; dd float8;
  i integer; j integer; k integer; improved boolean := true; passes integer := 0; a integer; b integer; c integer; e integer; tmp integer[];
begin
  if n <= 2 then return case when n = 2 then array[2] else '{}'::integer[] end; end if;
  dm := array_fill(0::float8, array[n * n]);
  for i in 1..n loop
    for j in 1..n loop
      if i <> j then
        dm[(i - 1) * n + j] := 6371000 * 2 * asin(sqrt(power(sin(radians((p_lat[j] - p_lat[i]) / 2)), 2)
          + cos(radians(p_lat[i])) * cos(radians(p_lat[j])) * power(sin(radians((p_lng[j] - p_lng[i]) / 2)), 2)));
      end if;
    end loop;
  end loop;
  used := array_fill(false, array[n]);
  used[1] := true;
  for k in 2..n loop
    best := null; bd := null;
    for j in 2..n loop
      if not used[j] and (bd is null or dm[(cur - 1) * n + j] < bd) then best := j; bd := dm[(cur - 1) * n + j]; end if;
    end loop;
    o := o || best; used[best] := true; cur := best;
  end loop;
  -- 2-opt on the path start → o[1..m] (→ start again when returning)
  while improved and passes < 50 loop
    improved := false; passes := passes + 1;
    for i in 1..array_length(o, 1) - 1 loop
      for k in i + 1..array_length(o, 1) loop
        a := case when i = 1 then 1 else o[i - 1] end; b := o[i]; c := o[k];
        e := case when k = array_length(o, 1) then (case when p_return then 1 else null end) else o[k + 1] end;
        dd := dm[(a - 1) * n + c] - dm[(a - 1) * n + b]
              + case when e is null then 0 else dm[(b - 1) * n + e] - dm[(c - 1) * n + e] end;
        if dd < -0.5 then
          tmp := o[i:k];
          for j in 0..(k - i) loop o[i + j] := tmp[k - i + 1 - j]; end loop;
          improved := true;
        end if;
      end loop;
    end loop;
  end loop;
  return o;
end $$;

-- Length in metres of a path through points (index order), optionally back to point 1.
create or replace function app.path_length(p_lat float8[], p_lng float8[], p_order integer[], p_return boolean default true)
returns float8 language plpgsql immutable set search_path = '' as $$
declare t float8 := 0; prev integer := 1; x integer;
begin
  foreach x in array coalesce(p_order, '{}') loop
    t := t + app.distance_m(p_lat[prev]::numeric, p_lng[prev]::numeric, p_lat[x]::numeric, p_lng[x]::numeric);
    prev := x;
  end loop;
  if p_return and prev <> 1 then t := t + app.distance_m(p_lat[prev]::numeric, p_lng[prev]::numeric, p_lat[1]::numeric, p_lng[1]::numeric); end if;
  return t;
end $$;

create or replace function app.road_km(p_metres float8)
returns numeric language sql stable security definer set search_path = '' as $$
  select round((p_metres / 1000 * coalesce((app.get_setting('planning.road_factor') #>> '{}')::numeric, 1.3))::numeric, 1)
$$;

-- GPS of a location (warehouse / shop), e.g. from the phone at the gate.
create or replace function public.set_location_gps(p_location uuid, p_lat numeric, p_lng numeric)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (app.has_permission('routes.manage') or app.has_permission('settings.manage')) then
    raise exception 'Permission denied: routes.manage is required' using errcode = '42501';
  end if;
  if p_lat is null or p_lng is null or p_lat not between 5.8 and 10.0 or p_lng not between 79.4 and 82.0 then
    raise exception 'That is not a location in Sri Lanka' using errcode = '22023';
  end if;
  perform app.set_context('Location GPS set', null, null);
  update public.locations set gps_lat = round(p_lat, 6), gps_lng = round(p_lng, 6) where id = p_location;
  if not found then raise exception 'Location not found' using errcode = 'P0002'; end if;
end $$;

-- ---------------------------------------------------------------------
-- A run: suggested order for the stops not yet done
-- ---------------------------------------------------------------------
create or replace function public.suggest_run_order(p_run uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.route_runs; s record; lat float8[]; lng float8[]; ids uuid[] := '{}'; v_cur integer[] := '{}'; v_new integer[];
        v_start jsonb; v_stops jsonb := '[]'; v_nogps jsonb := '[]'; v_done jsonb := '[]'; i integer; x integer; v_last record;
        l public.locations;
begin
  if not (app.has_permission('deliveries.manage') or app.has_permission('deliveries.view')) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  select * into r from public.route_runs where id = p_run;
  if not found then raise exception 'Run not found' using errcode = 'P0002'; end if;
  select * into l from public.locations where id = r.load_location_id;

  -- start: last completed stop with GPS when the run is on the road, else the warehouse
  select d.gps_lat lat, d.gps_lng lng, c.name into v_last
    from public.deliveries d join public.customers c on c.id = d.customer_id
   where d.run_id = r.id and d.status in ('delivered','partially_delivered','failed') and d.gps_lat is not null
   order by d.completed_at desc nulls last limit 1;
  if r.status = 'in_progress' and v_last.lat is not null then
    v_start := jsonb_build_object('name', 'Last stop: ' || v_last.name, 'lat', v_last.lat, 'lng', v_last.lng, 'kind', 'last_stop');
  elsif l.gps_lat is not null then
    v_start := jsonb_build_object('name', l.name, 'lat', l.gps_lat, 'lng', l.gps_lng, 'kind', 'warehouse');
  end if;

  for s in
    select d.id, d.delivery_no, d.stop_sequence, d.status, c.name customer, a.address_line, a.city,
           coalesce(a.gps_lat, (select ca.gps_lat from public.customer_addresses ca where ca.customer_id = c.id and ca.is_default and ca.is_active)) lat,
           coalesce(a.gps_lng, (select ca.gps_lng from public.customer_addresses ca where ca.customer_id = c.id and ca.is_default and ca.is_active)) lng
      from public.deliveries d join public.customers c on c.id = d.customer_id left join public.customer_addresses a on a.id = d.address_id
     where d.run_id = r.id and d.status <> 'cancelled'
     order by d.stop_sequence
  loop
    if s.status <> 'pending' then
      v_done := v_done || jsonb_build_object('delivery_id', s.id, 'delivery_no', s.delivery_no, 'customer', s.customer, 'status', s.status,
        'current_seq', s.stop_sequence, 'lat', s.lat, 'lng', s.lng);
    elsif s.lat is null then
      v_nogps := v_nogps || jsonb_build_object('delivery_id', s.id, 'delivery_no', s.delivery_no, 'customer', s.customer,
        'address', concat_ws(', ', s.address_line, s.city), 'current_seq', s.stop_sequence);
    else
      if lat is null then
        lat := array[coalesce((v_start ->> 'lat')::float8, s.lat::float8)]; lng := array[coalesce((v_start ->> 'lng')::float8, s.lng::float8)];
      end if;
      lat := lat || s.lat::float8; lng := lng || s.lng::float8; ids := ids || s.id;
      v_cur := v_cur || (array_length(lat, 1));
      v_stops := v_stops || jsonb_build_object('delivery_id', s.id, 'delivery_no', s.delivery_no, 'customer', s.customer,
        'address', concat_ws(', ', s.address_line, s.city), 'lat', s.lat, 'lng', s.lng, 'current_seq', s.stop_sequence);
    end if;
  end loop;

  v_new := app.tour_order(lat, lng, v_start is not null and v_start ->> 'kind' = 'warehouse');
  return jsonb_build_object(
    'run', jsonb_build_object('id', r.id, 'run_no', r.run_no, 'status', r.status),
    'start', v_start,
    'can_apply', r.status in ('planned','loaded','in_progress') and jsonb_array_length(v_stops) > 1,
    'current_km', case when lat is not null then app.road_km(app.path_length(lat, lng, v_cur, v_start ->> 'kind' = 'warehouse')) end,
    'suggested_km', case when lat is not null then app.road_km(app.path_length(lat, lng, v_new, v_start ->> 'kind' = 'warehouse')) end,
    'done', v_done,
    'suggested', coalesce((select jsonb_agg(v_stops -> (u.ix - 2) order by u.ord) from unnest(v_new) with ordinality as u(ix, ord)), '[]'),
    'no_gps', v_nogps);
end $$;

-- Apply a stop order: p_order = the pending deliveries in the new order (all of them).
create or replace function public.apply_run_order(p_run uuid, p_order uuid[], p_reason text default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare r public.route_runs; v_pending uuid[]; v_first integer; i integer;
begin
  perform app.require_permission('deliveries.manage');
  select * into r from public.route_runs where id = p_run for update;
  if not found then raise exception 'Run not found' using errcode = 'P0002'; end if;
  if r.status not in ('planned','loaded','in_progress') then raise exception 'This run is finished — its stops cannot be re-ordered' using errcode = '22023'; end if;
  select array_agg(id order by stop_sequence) into v_pending from public.deliveries where run_id = p_run and status = 'pending';
  if v_pending is null or array_length(p_order, 1) is distinct from array_length(v_pending, 1)
     or not (p_order @> v_pending and v_pending @> p_order) then
    raise exception 'The stops changed while you were planning — open the run again' using errcode = '22023';
  end if;
  select coalesce(max(stop_sequence), 0) into v_first from public.deliveries where run_id = p_run and status not in ('pending','cancelled');
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Stops re-ordered by GPS'), null, 'reorder');
  for i in 1..array_length(p_order, 1) loop
    update public.deliveries set stop_sequence = v_first + i where id = p_order[i];
  end loop;
  return array_length(p_order, 1);
end $$;

-- ---------------------------------------------------------------------
-- A route: suggested visiting order of its customers (route_sequence)
-- ---------------------------------------------------------------------
create or replace function public.suggest_route_sequence(p_route uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare l public.locations; s record; lat float8[]; lng float8[]; v_cur integer[] := '{}'; v_new integer[]; v_list jsonb := '[]'; v_nogps jsonb := '[]';
        rt public.routes; x integer;
begin
  if not (app.has_permission('routes.manage') or app.has_permission('deliveries.manage')) then raise exception 'Permission denied' using errcode = '42501'; end if;
  select * into rt from public.routes where id = p_route;
  if not found then raise exception 'Route not found' using errcode = 'P0002'; end if;
  select * into l from public.locations where code = 'WH1';
  for s in
    select c.id, c.name, c.customer_no, c.route_sequence, a.address_line, a.city, a.gps_lat lat, a.gps_lng lng
      from public.customers c left join public.customer_addresses a on a.customer_id = c.id and a.is_default and a.is_active
     where c.route_id = p_route and c.status <> 'inactive'
     order by c.route_sequence nulls last, c.name
  loop
    if s.lat is null then
      v_nogps := v_nogps || jsonb_build_object('customer_id', s.id, 'customer', s.name, 'customer_no', s.customer_no, 'current_seq', s.route_sequence);
    else
      if lat is null then lat := array[coalesce(l.gps_lat, s.lat)::float8]; lng := array[coalesce(l.gps_lng, s.lng)::float8]; end if;
      lat := lat || s.lat::float8; lng := lng || s.lng::float8; v_cur := v_cur || array_length(lat, 1);
      v_list := v_list || jsonb_build_object('customer_id', s.id, 'customer', s.name, 'customer_no', s.customer_no,
        'address', concat_ws(', ', s.address_line, s.city), 'lat', s.lat, 'lng', s.lng, 'current_seq', s.route_sequence);
    end if;
  end loop;
  v_new := app.tour_order(lat, lng, l.gps_lat is not null);
  return jsonb_build_object(
    'route', jsonb_build_object('id', rt.id, 'name', rt.name),
    'start', case when l.gps_lat is not null then jsonb_build_object('name', l.name, 'lat', l.gps_lat, 'lng', l.gps_lng) end,
    'current_km', case when lat is not null then app.road_km(app.path_length(lat, lng, v_cur, l.gps_lat is not null)) end,
    'suggested_km', case when lat is not null then app.road_km(app.path_length(lat, lng, v_new, l.gps_lat is not null)) end,
    'suggested', coalesce((select jsonb_agg(v_list -> (u.ix - 2) order by u.ord) from unnest(v_new) with ordinality as u(ix, ord)), '[]'),
    'no_gps', v_nogps);
end $$;

create or replace function public.apply_route_sequence(p_route uuid, p_customers uuid[])
returns integer language plpgsql security definer set search_path = '' as $$
declare i integer; n integer := 0; v uuid;
begin
  perform app.require_permission('routes.manage');
  if exists (select 1 from unnest(p_customers) c where not exists (select 1 from public.customers x where x.id = c and x.route_id = p_route)) then
    raise exception 'Some customers are not on this route' using errcode = '22023';
  end if;
  perform app.set_context('Route order set by GPS', null, null);
  for i in 1..coalesce(array_length(p_customers, 1), 0) loop
    update public.customers set route_sequence = i where id = p_customers[i];
    n := n + 1;
  end loop;
  -- customers without GPS keep their relative order after the others
  for v in select id from public.customers where route_id = p_route and not (id = any (p_customers)) order by route_sequence nulls last, name loop
    n := n + 1;
    update public.customers set route_sequence = n where id = v;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Demand forecast (finished goods): weighted average of the last 12
-- weeks (recent weeks count more), never below what recurring and open
-- orders already ask for; with stock cover and a production suggestion.
-- ---------------------------------------------------------------------
create or replace function public.demand_forecast(p_weeks integer default 4)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_weeks integer := least(greatest(coalesce(p_weeks, 4), 1), 8); v_start date := date_trunc('week', app.today())::date;
        v_safety integer := coalesce((app.get_setting('planning.safety_stock_days') #>> '{}')::integer, 2); v jsonb;
begin
  if not (app.has_permission('production.view') or app.has_permission('inventory.view') or app.has_permission('reports.view')) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  with weeks as (
    select generate_series(v_start - 84, v_start - 7, interval '7 days')::date w),
  hist as (
    select p.id product_id, w.w,
           coalesce((select sum(l.qty) from public.invoice_lines l join public.invoices i on i.id = l.invoice_id
                      where l.product_id = p.id and l.line_type = 'product' and i.status <> 'void' and i.invoice_date >= w.w and i.invoice_date < w.w + 7), 0) qty
      from public.products p cross join weeks w
     where p.is_active and p.item_type = 'finished_good'),
  agg as (
    select product_id, array_agg(qty order by w) series,
           sum(qty * case when w >= v_start - 28 then 2 else 1 end) / sum(case when w >= v_start - 28 then 2 else 1 end) wavg,
           avg(qty) filter (where w >= v_start - 28) last4, avg(qty) filter (where w < v_start - 28) prev8
      from hist group by product_id),
  recurring as (
    select ri.product_id, sum(ri.qty * case ro.frequency when 'daily' then 6 when 'alternate_days' then 3.5 when 'weekly' then coalesce(cardinality(ro.weekdays), 1)
                                              when 'monthly' then 0.23 else 7.0 / greatest(coalesce(ro.interval_days, 7), 1) end) per_week
      from public.recurring_orders ro join public.recurring_order_items ri on ri.recurring_order_id = ro.id
     where ro.status = 'active' and (ro.end_date is null or ro.end_date >= app.today())
     group by ri.product_id),
  open_orders as (
    select oi.product_id, sum(oi.qty - oi.delivered_qty) qty
      from public.order_items oi join public.orders o on o.id = oi.order_id
     where o.status in ('draft','on_hold','confirmed','assigned','loaded','out_for_delivery') group by oi.product_id),
  stock as (
    select product_id, sum(qty) filter (where stock_status = 'available') available, sum(qty) filter (where stock_status = 'qc_hold') qc_hold
      from public.inventory_balances group by product_id)
  select coalesce(jsonb_agg(jsonb_build_object(
      'product_id', p.id, 'product', p.name, 'sku', p.sku, 'history', a.series,
      'trend_pct', case when coalesce(a.prev8, 0) > 0 then round(100 * (coalesce(a.last4, 0) - a.prev8) / a.prev8, 0) end,
      'forecast_week', round(greatest(a.wavg, coalesce(rc.per_week, 0)), 0),
      'forecast_total', round(greatest(a.wavg, coalesce(rc.per_week, 0)) * v_weeks, 0),
      'recurring_week', round(coalesce(rc.per_week, 0), 0), 'open_orders', coalesce(oo.qty, 0),
      'available', coalesce(st.available, 0), 'qc_hold', coalesce(st.qc_hold, 0),
      'cover_days', case when greatest(a.wavg, coalesce(rc.per_week, 0)) > 0
                         then round(coalesce(st.available, 0) / (greatest(a.wavg, coalesce(rc.per_week, 0)) / 7), 1) end,
      'suggested_production', greatest(0, ceil(greatest(a.wavg, coalesce(rc.per_week, 0)) * v_weeks
                                              + greatest(a.wavg, coalesce(rc.per_week, 0)) / 7 * v_safety
                                              - coalesce(st.available, 0) - coalesce(st.qc_hold, 0)))
    ) order by greatest(a.wavg, coalesce(rc.per_week, 0)) desc), '[]')
    into v
    from public.products p join agg a on a.product_id = p.id
    left join recurring rc on rc.product_id = p.id left join open_orders oo on oo.product_id = p.id left join stock st on st.product_id = p.id;
  return jsonb_build_object('weeks', v_weeks, 'week_starts', (select jsonb_agg(w order by w) from (select generate_series(v_start - 84, v_start - 7, interval '7 days')::date w) x),
    'products', v,
    'weekday_share', (select coalesce(jsonb_agg(jsonb_build_object('dow', dow, 'share', share) order by dow), '[]') from (
        select extract(isodow from i.invoice_date)::integer dow,
               round(100.0 * sum(l.qty) / nullif(sum(sum(l.qty)) over (), 0), 1) share
          from public.invoice_lines l join public.invoices i on i.id = l.invoice_id
         where l.line_type = 'product' and i.status <> 'void' and i.invoice_date >= v_start - 84 and i.invoice_date < v_start
         group by 1) d),
    'by_route', (select coalesce(jsonb_agg(jsonb_build_object('route', coalesce(rt.name, 'No route'), 'stops_week', round(x.stops / 12.0, 1),
                   'qty_week', round(x.qty / 12.0, 0)) order by x.qty desc), '[]') from (
        select r.route_id, count(distinct d.id) stops, coalesce(sum(l.qty), 0) qty
          from public.deliveries d join public.route_runs r on r.id = d.run_id
          left join public.invoice_lines l on l.invoice_id = d.invoice_id and l.line_type = 'product'
         where d.status in ('delivered','partially_delivered') and r.run_date >= v_start - 84 and r.run_date < v_start
         group by r.route_id) x left join public.routes rt on rt.id = x.route_id));
end $$;

-- Materials needed for the suggested production, against stock and the reorder level.
create or replace function public.material_needs(p_weeks integer default 4)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare f jsonb := public.demand_forecast(p_weeks);
begin
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.to_buy desc, x.material) from (
    select m.name material, m.sku, m.item_type,
           round(sum(bom.qty_per_unit * (pr ->> 'suggested_production')::numeric), 3) needed,
           coalesce((select sum(b.qty) from public.inventory_balances b where b.product_id = m.id and b.stock_status = 'available'), 0) available,
           m.reorder_level,
           coalesce((select sum(pol.qty_ordered - pol.qty_received) from public.purchase_order_lines pol join public.purchase_orders po on po.id = pol.po_id
                      where pol.product_id = m.id and po.status in ('approved','partially_received')), 0) on_order,
           greatest(0, round(sum(bom.qty_per_unit * (pr ->> 'suggested_production')::numeric) + m.reorder_level
             - coalesce((select sum(b.qty) from public.inventory_balances b where b.product_id = m.id and b.stock_status = 'available'), 0)
             - coalesce((select sum(pol.qty_ordered - pol.qty_received) from public.purchase_order_lines pol join public.purchase_orders po on po.id = pol.po_id
                          where pol.product_id = m.id and po.status in ('approved','partially_received')), 0), 3)) to_buy
      from jsonb_array_elements(f -> 'products') pr
      join public.product_materials bom on bom.product_id = (pr ->> 'product_id')::uuid
      join public.products m on m.id = bom.material_id
     group by m.id, m.name, m.sku, m.item_type, m.reorder_level) x), '[]');
end $$;

-- ---------------------------------------------------------------------
-- Customers due for a refill: their usual gap between orders says the
-- next one is due, and nothing is ordered yet (recurring orders excluded).
-- ---------------------------------------------------------------------
create or replace function public.refill_due(p_days integer default null, p_route uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_days integer := coalesce(p_days, (app.get_setting('planning.refill_window_days') #>> '{}')::integer, 2);
begin
  if not (app.has_permission('orders.manage') or app.has_permission('customers.view') or app.has_permission('crm.manage')) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.due_date, x.customer) from (
    with dates as (
      select i.customer_id, i.invoice_date, lag(i.invoice_date) over (partition by i.customer_id order by i.invoice_date) prev
        from (select distinct customer_id, invoice_date from public.invoices
               where status <> 'void' and invoice_date >= app.today() - 180) i),
    gaps as (
      select customer_id, max(invoice_date) last_date, count(*) orders,
             percentile_cont(0.5) within group (order by invoice_date - prev) filter (where prev is not null) median_gap
        from dates group by customer_id)
    select c.id customer_id, c.customer_no, c.name customer, c.phone, c.customer_type, rt.name route, g.last_date,
           round(g.median_gap::numeric, 0) usual_gap_days, (g.last_date + round(g.median_gap)::integer) due_date,
           (app.today() - (g.last_date + round(g.median_gap)::integer)) days_late,
           (select round(avg(l.qty), 0) from public.invoice_lines l join public.invoices i on i.id = l.invoice_id
             where i.customer_id = c.id and l.line_type = 'product' and i.status <> 'void' and i.invoice_date >= app.today() - 180) usual_qty,
           app.customer_outstanding(c.id) outstanding
      from gaps g join public.customers c on c.id = g.customer_id left join public.routes rt on rt.id = c.route_id
     where g.orders >= 3 and g.median_gap between 2 and 60 and c.status = 'active' and not c.is_walk_in
       and g.last_date + round(g.median_gap)::integer <= app.today() + v_days
       and g.last_date + round(g.median_gap)::integer >= app.today() - 30
       and not exists (select 1 from public.orders o where o.customer_id = c.id
                         and o.status in ('draft','on_hold','confirmed','assigned','loaded','out_for_delivery'))
       and not exists (select 1 from public.recurring_orders ro where ro.customer_id = c.id and ro.status = 'active')
       and (p_route is null or c.route_id = p_route)
     limit 500) x), '[]');
end $$;

-- ---------------------------------------------------------------------
-- Analytics series for the charts
-- ---------------------------------------------------------------------
create or replace function public.analytics_overview(p_months integer default 12)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_m integer := least(greatest(coalesce(p_months, 12), 3), 24); v_start date := (date_trunc('month', app.today()) - make_interval(months => v_m - 1))::date;
begin
  if not (app.has_permission('reports.view') or app.has_permission('accounting.view')) then
    raise exception 'Permission denied: reports.view is required' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'months', (select jsonb_agg(jsonb_build_object(
        'month', to_char(m, 'Mon YY'),
        'sales', coalesce((select sum(subtotal_net) from public.invoices where status <> 'void' and invoice_date >= m and invoice_date < m + interval '1 month'), 0),
        'last_year', coalesce((select sum(subtotal_net) from public.invoices where status <> 'void'
                                and invoice_date >= m - interval '1 year' and invoice_date < m - interval '1 year' + interval '1 month'), 0),
        'collected', coalesce((select sum(amount) from public.payments where status = 'received' and coalesce(direction, 'in') = 'in'
                                and (received_at at time zone 'Asia/Colombo')::date >= m and (received_at at time zone 'Asia/Colombo')::date < m + interval '1 month'), 0),
        'customers', (select count(distinct customer_id) from public.invoices where status <> 'void' and invoice_date >= m and invoice_date < m + interval '1 month'),
        'qty_19l', coalesce((select sum(l.qty) from public.invoice_lines l join public.invoices i on i.id = l.invoice_id join public.products p on p.id = l.product_id
                              where i.status <> 'void' and l.line_type = 'product' and p.sku = 'OLA-19L' and i.invoice_date >= m and i.invoice_date < m + interval '1 month'), 0),
        'delivery_success', (select round(100.0 * count(*) filter (where d.status in ('delivered','partially_delivered'))
                                         / nullif(count(*) filter (where d.status in ('delivered','partially_delivered','failed')), 0), 1)
                               from public.deliveries d join public.route_runs r on r.id = d.run_id where r.run_date >= m and r.run_date < m + interval '1 month'),
        'complaints', (select count(*) from public.complaints where created_at >= m and created_at < m + interval '1 month'),
        'expenses', coalesce((select sum(net_amount) from public.expenses where status in ('approved','paid') and expense_date >= m and expense_date < m + interval '1 month'), 0)
      ) order by m) from generate_series(v_start, date_trunc('month', app.today())::date, interval '1 month') m),
    'by_type', (select coalesce(jsonb_agg(jsonb_build_object('name', t, 'value', v) order by v desc), '[]') from (
                  select initcap(replace(c.customer_type, '_', ' ')) t, sum(i.subtotal_net) v
                    from public.invoices i join public.customers c on c.id = i.customer_id
                   where i.status <> 'void' and i.invoice_date >= v_start group by c.customer_type) z),
    'by_product', (select coalesce(jsonb_agg(jsonb_build_object('name', n, 'value', v) order by v desc), '[]') from (
                  select p.name n, sum(l.net) v from public.invoice_lines l join public.invoices i on i.id = l.invoice_id join public.products p on p.id = l.product_id
                   where l.line_type = 'product' and i.status <> 'void' and i.invoice_date >= v_start group by p.name) z),
    'by_route', (select coalesce(jsonb_agg(jsonb_build_object('name', n, 'value', v) order by v desc), '[]') from (
                  select coalesce(rt.name, 'No route') n, sum(i.subtotal_net) v from public.invoices i join public.customers c on c.id = i.customer_id
                    left join public.routes rt on rt.id = c.route_id
                   where i.status <> 'void' and i.invoice_date >= v_start and not c.is_walk_in group by 1 order by 2 desc limit 12) z),
    'top_customers', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', n, 'value', v) order by v desc), '[]') from (
                  select c.id, c.name n, sum(i.subtotal_net) v from public.invoices i join public.customers c on c.id = i.customer_id
                   where i.status <> 'void' and i.invoice_date >= v_start and not c.is_walk_in group by c.id, c.name order by 3 desc limit 10) z),
    'kpis', jsonb_build_object(
        'avg_invoice', (select round(avg(subtotal_net), 2) from public.invoices where status <> 'void' and invoice_date >= v_start),
        'active_customers', (select count(distinct customer_id) from public.invoices where status <> 'void' and invoice_date >= app.today() - 90),
        'repeat_rate', (select round(100.0 * count(*) filter (where n >= 2) / nullif(count(*), 0), 1) from (
                          select customer_id, count(*) n from public.invoices where status <> 'void' and invoice_date >= app.today() - 90 group by customer_id) r),
        'ola_bottles_out', (select coalesce(sum(qty), 0) from public.bottle_balances where company_id = app.own_company_id() and holder_type = 'customer'))
  );
end $$;

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
grant execute on function app.document_can(text, boolean)      to authenticated, service_role;
revoke execute on function public.log_failed_login(text, text, text, text) from authenticated;
revoke execute on function public.bootstrap_super_admin(text)              from authenticated;

grant select on all tables in schema public to authenticated, service_role;
revoke all on all tables in schema public from anon;
