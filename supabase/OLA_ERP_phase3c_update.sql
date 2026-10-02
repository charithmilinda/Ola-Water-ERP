-- OLA Water ERP — Phase 3C database update (reports centre)
-- Run ONCE in Supabase → SQL Editor → New query, on the database that already has Phase 3B.
-- It runs as one transaction: if anything fails, nothing is changed.
begin;

-- >>> 20261009000046_reports.sql
-- =====================================================================
-- OLA Water ERP — Phase 3C
-- 0046: reports centre. One entry point, run_report(report, filters),
--       returns the rows of any operational report as JSON. The app
--       holds the column layout; every export is written to the audit
--       trail (master prompt D-1 / D-3).
--
-- Filters (all optional): from, to (dates, default this month), as_at,
--   location_id, customer_type, product_id, company_id, route_id,
--   rep_id, days, export (true when downloaded)
-- =====================================================================

insert into public.setting_definitions (key, module, label, description, value_type, choices, min_value, max_value, sort_order) values
  ('bottles.max_fill_count', 'Bottles', 'Retire a bottle after this many fills',
   'Bottles at 90% of this appear in the "retirement due" report. Confirm with the bottle supplier.', 'integer', null, 5, 500, 24)
on conflict (key) do nothing;
insert into public.system_settings (key, value, effective_from)
select 'bottles.max_fill_count', '50', date '2026-01-01'
 where not exists (select 1 from public.system_settings where key = 'bottles.max_fill_count');

-- Which permissions open each group of reports.
create or replace function app.report_allowed(p_report text)
returns boolean language sql stable security definer set search_path = '' as $$
  select case
    when p_report like 'sales-%'      then app.has_permission('reports.view') or app.has_permission('accounting.view') or app.has_permission('sales_reps.manage')
    when p_report like 'customers-%'  then app.has_permission('reports.view') or app.has_permission('customers.view')
    when p_report like 'stock-%'      then app.has_permission('inventory.view')
    when p_report like 'bottle-%'     then app.has_permission('bottles.view')
    when p_report like 'delivery-%'   then app.has_permission('deliveries.view') or app.has_permission('deliveries.manage')
    when p_report like 'production-%' then app.has_permission('production.view') or app.has_permission('qc.view')
    when p_report like 'finance-%'    then app.has_permission('accounting.view')
    when p_report like 'complaints-%' then app.has_permission('complaints.view') or app.has_permission('complaints.manage')
    else false end
$$;

create or replace function public.run_report(p_report text, p jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_to    date := coalesce((app.jtext(p, 'to'))::date, app.today());
  v_from  date := coalesce((app.jtext(p, 'from'))::date, date_trunc('month', coalesce((app.jtext(p, 'to'))::date, app.today()))::date);
  v_asat  date := coalesce((app.jtext(p, 'as_at'))::date, app.today());
  v_loc   uuid := app.juuid(p, 'location_id');
  v_ctype text := app.jtext(p, 'customer_type');
  v_prod  uuid := app.juuid(p, 'product_id');
  v_co    uuid := app.juuid(p, 'company_id');
  v_route uuid := app.juuid(p, 'route_id');
  v_rep   uuid := app.juuid(p, 'rep_id');
  v_days  integer := coalesce(app.jint(p, 'days'), 30);
  v_own   uuid := app.own_company_id();
  v       jsonb;
begin
  if app.current_user_id() is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  if not app.report_allowed(p_report) then raise exception 'Permission denied: you cannot open this report' using errcode = '42501'; end if;
  if v_from > v_to then raise exception 'The start date is after the end date' using errcode = '22023'; end if;
  if v_to - v_from > 1100 then raise exception 'Choose a period of at most 3 years' using errcode = '22023'; end if;

  -- ===================================================================== Sales
  if p_report = 'sales-daily' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select d::date as date,
             (select count(*) from public.invoices i where i.invoice_date = d::date and i.status <> 'void') as invoices,
             coalesce((select sum(i.subtotal_net) from public.invoices i where i.invoice_date = d::date and i.status <> 'void'), 0) as net,
             coalesce((select sum(i.tax_total) from public.invoices i where i.invoice_date = d::date and i.status <> 'void'), 0) as vat,
             coalesce((select sum(i.total) from public.invoices i where i.invoice_date = d::date and i.status <> 'void'), 0) as total,
             coalesce((select sum(pm.amount) from public.payments pm where pm.status = 'received' and coalesce(pm.direction, 'in') = 'in'
                        and (pm.received_at at time zone 'Asia/Colombo')::date = d::date), 0) as collected
        from generate_series(v_from, v_to, interval '1 day') d
       order by d) x;

  elsif p_report = 'sales-monthly' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select to_char(m, 'YYYY-MM') as month,
             count(i.id) as invoices, count(distinct i.customer_id) as customers,
             coalesce(sum(i.subtotal_net), 0) as net, coalesce(sum(i.tax_total), 0) as vat, coalesce(sum(i.total), 0) as total,
             coalesce((select sum(pm.amount) from public.payments pm where pm.status = 'received' and coalesce(pm.direction, 'in') = 'in'
                        and (pm.received_at at time zone 'Asia/Colombo')::date >= m and (pm.received_at at time zone 'Asia/Colombo')::date < m + interval '1 month'), 0) as collected
        from generate_series(date_trunc('month', v_from), date_trunc('month', v_to), interval '1 month') m
        left join public.invoices i on i.status <> 'void' and i.invoice_date >= m and i.invoice_date < m + interval '1 month'
                                   and i.invoice_date between v_from and v_to
       group by m order by m) x;

  elsif p_report = 'sales-by-product' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select pr.name as product, pr.sku, sum(l.qty) as qty, sum(l.net) as net, sum(l.tax) as vat, sum(l.total) as total,
             round(100 * sum(l.net) / nullif(sum(sum(l.net)) over (), 0), 1) as share_pct,
             round(sum(l.net) / nullif(sum(l.qty), 0), 2) as avg_price
        from public.invoice_lines l join public.invoices i on i.id = l.invoice_id join public.products pr on pr.id = l.product_id
        join public.customers c on c.id = i.customer_id
       where l.line_type = 'product' and i.status <> 'void' and i.invoice_date between v_from and v_to
         and (v_ctype is null or c.customer_type = v_ctype) and (v_loc is null or i.location_id = v_loc)
       group by pr.id, pr.name, pr.sku order by sum(l.net) desc) x;

  elsif p_report = 'sales-by-customer' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select c.id as customer_id, c.customer_no, c.name as customer, c.customer_type, count(i.id) as invoices,
             sum(i.subtotal_net) as net, sum(i.total) as total, max(i.invoice_date) as last_invoice,
             app.customer_outstanding(c.id) as outstanding
        from public.invoices i join public.customers c on c.id = i.customer_id
       where i.status <> 'void' and i.invoice_date between v_from and v_to and not c.is_walk_in
         and (v_ctype is null or c.customer_type = v_ctype) and (v_route is null or c.route_id = v_route)
       group by c.id order by sum(i.subtotal_net) desc limit 1000) x;

  elsif p_report = 'sales-by-customer-type' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select c.customer_type, count(distinct c.id) as customers, count(i.id) as invoices, sum(i.subtotal_net) as net, sum(i.total) as total,
             round(100 * sum(i.subtotal_net) / nullif(sum(sum(i.subtotal_net)) over (), 0), 1) as share_pct
        from public.invoices i join public.customers c on c.id = i.customer_id
       where i.status <> 'void' and i.invoice_date between v_from and v_to
       group by c.customer_type order by sum(i.subtotal_net) desc) x;

  elsif p_report = 'sales-by-channel' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select case when i.run_id is not null then 'Home & office delivery'
                  when l.location_type = 'water_shop' then 'Water shop — ' || l.name
                  else 'Counter — ' || coalesce(l.name, 'head office') end as channel,
             count(i.id) as invoices, count(distinct i.customer_id) as customers,
             sum(i.subtotal_net) as net, sum(i.tax_total) as vat, sum(i.total) as total,
             round(100 * sum(i.subtotal_net) / nullif(sum(sum(i.subtotal_net)) over (), 0), 1) as share_pct
        from public.invoices i left join public.locations l on l.id = i.location_id
       where i.status <> 'void' and i.invoice_date between v_from and v_to
       group by 1 order by sum(i.subtotal_net) desc) x;

  elsif p_report = 'sales-by-distributor' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select d.id as distributor_id, d.code, c.name as distributor, d.kind, t.name as territory,
             round(d.monthly_target * ((v_to - v_from + 1) / 30.4), 2) as target,
             coalesce(s.net, 0) as net, coalesce(s.total, 0) as total, coalesce(s.invoices, 0) as invoices,
             round(100 * coalesce(s.net, 0) / nullif(d.monthly_target * ((v_to - v_from + 1) / 30.4), 0), 1) as target_pct,
             app.customer_outstanding(c.id) as outstanding
        from public.distributors d join public.customers c on c.id = d.customer_id
        left join public.territories t on t.id = d.territory_id
        left join lateral (select count(*) invoices, sum(i.subtotal_net) net, sum(i.total) total from public.invoices i
                            where i.customer_id = c.id and i.status <> 'void' and i.invoice_date between v_from and v_to) s on true
       where d.status <> 'ended'
       order by coalesce(s.net, 0) desc) x;

  elsif p_report = 'sales-by-rep' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select r.id as rep_id, r.code, pf.full_name as rep, t.name as territory,
             (select count(*) from public.customers c where c.sales_rep_id = r.profile_id and c.status <> 'inactive') as customers,
             coalesce((select sum(i.subtotal_net) from public.invoices i join public.customers c on c.id = i.customer_id
                        where c.sales_rep_id = r.profile_id and i.status <> 'void' and i.invoice_date between v_from and v_to), 0) as net,
             coalesce((select sum(pm.amount) from public.payments pm join public.customers c on c.id = pm.customer_id
                        where c.sales_rep_id = r.profile_id and pm.status = 'received' and coalesce(pm.direction, 'in') = 'in'
                          and (pm.received_at at time zone 'Asia/Colombo')::date between v_from and v_to), 0) as collections,
             coalesce((select sum(st.sales_target) from public.sales_targets st where st.rep_id = r.id
                        and make_date(st.target_year, st.target_month, 1) between date_trunc('month', v_from)::date and v_to), 0) as target,
             (select count(*) from public.rep_visits rv where rv.rep_id = r.id
                and (rv.checkin_at at time zone 'Asia/Colombo')::date between v_from and v_to) as visits
        from public.sales_reps r join public.profiles pf on pf.id = r.profile_id left join public.territories t on t.id = r.territory_id
       where r.is_active
       order by 5 desc) x;
    select coalesce(jsonb_agg(e || jsonb_build_object('target_pct', round(100 * (e ->> 'net')::numeric / nullif((e ->> 'target')::numeric, 0), 1))
                              order by (e ->> 'net')::numeric desc), '[]')
      into v from jsonb_array_elements(v) e;

  -- ===================================================================== Customers
  elsif p_report = 'customers-inactive' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select c.id as customer_id, c.customer_no, c.name as customer, c.customer_type, c.phone, rt.name as route, pf.full_name as rep,
             li.last_invoice, (app.today() - li.last_invoice) as days_since, app.customer_outstanding(c.id) as outstanding
        from public.customers c
        left join public.routes rt on rt.id = c.route_id left join public.profiles pf on pf.id = c.sales_rep_id
        left join lateral (select max(i.invoice_date) last_invoice from public.invoices i where i.customer_id = c.id and i.status <> 'void') li on true
       where c.status = 'active' and not c.is_walk_in
         and (li.last_invoice is null or li.last_invoice < app.today() - v_days)
         and (v_ctype is null or c.customer_type = v_ctype) and (v_route is null or c.route_id = v_route)
       order by li.last_invoice nulls first limit 2000) x;

  elsif p_report = 'customers-new' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select c.id as customer_id, c.customer_no, c.name as customer, c.customer_type, (c.created_at at time zone 'Asia/Colombo')::date as created,
             pf.full_name as rep, (select min(i.invoice_date) from public.invoices i where i.customer_id = c.id and i.status <> 'void') as first_sale,
             coalesce((select sum(i.subtotal_net) from public.invoices i where i.customer_id = c.id and i.status <> 'void'
                        and i.invoice_date <= v_to), 0) as net_to_date
        from public.customers c left join public.profiles pf on pf.id = c.sales_rep_id
       where (c.created_at at time zone 'Asia/Colombo')::date between v_from and v_to and not c.is_walk_in
         and (v_ctype is null or c.customer_type = v_ctype)
       order by c.created_at) x;

  -- ===================================================================== Inventory
  elsif p_report = 'stock-current' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select l.name as location, l.location_type, pr.name as product, pr.sku, pr.item_type, b.stock_status, b.qty,
             pr.cost_price as unit_cost, round(b.qty * pr.cost_price, 2) as value
        from public.inventory_balances b join public.products pr on pr.id = b.product_id join public.locations l on l.id = b.location_id
       where b.qty <> 0 and (v_loc is null or b.location_id = v_loc) and (v_prod is null or b.product_id = v_prod)
       order by l.name, pr.sort_order, pr.name, b.stock_status) x;

  elsif p_report = 'stock-valuation' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select pr.name as product, pr.sku, pr.item_type,
             coalesce(sum(b.qty) filter (where b.stock_status = 'available'), 0) as available,
             coalesce(sum(b.qty) filter (where b.stock_status <> 'available'), 0) as other,
             coalesce(sum(b.qty), 0) as qty, pr.cost_price as unit_cost, round(coalesce(sum(b.qty), 0) * pr.cost_price, 2) as value
        from public.products pr left join public.inventory_balances b on b.product_id = pr.id and (v_loc is null or b.location_id = v_loc)
       where pr.is_active
       group by pr.id having coalesce(sum(b.qty), 0) <> 0
       order by round(coalesce(sum(b.qty), 0) * pr.cost_price, 2) desc) x;

  elsif p_report = 'stock-movements' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select t.created_at as at, t.txn_type, pr.name as product, t.qty, fl.name as from_location, tl.name as to_location,
             t.stock_status, t.reference_type, t.reason, pf.full_name as by
        from public.inventory_transactions t join public.products pr on pr.id = t.product_id
        left join public.locations fl on fl.id = t.from_location left join public.locations tl on tl.id = t.to_location
        left join public.profiles pf on pf.id = t.created_by
       where (t.created_at at time zone 'Asia/Colombo')::date between v_from and v_to
         and (v_loc is null or v_loc in (t.from_location, t.to_location)) and (v_prod is null or t.product_id = v_prod)
       order by t.created_at desc limit 3000) x;

  elsif p_report = 'stock-damaged' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select l.name as location, pr.name as product, b.stock_status, b.qty, round(b.qty * pr.cost_price, 2) as value
        from public.inventory_balances b join public.products pr on pr.id = b.product_id join public.locations l on l.id = b.location_id
       where b.stock_status <> 'available' and b.qty > 0 and (v_loc is null or b.location_id = v_loc)
       order by b.stock_status, l.name, pr.name) x;

  elsif p_report = 'stock-low' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select pr.name as product, pr.sku, pr.item_type, pr.reorder_level, coalesce(sum(b.qty), 0) as available,
             pr.reorder_level - coalesce(sum(b.qty), 0) as short_by
        from public.products pr left join public.inventory_balances b on b.product_id = pr.id and b.stock_status = 'available'
                                                                     and (v_loc is null or b.location_id = v_loc)
       where pr.is_active and pr.reorder_level > 0
       group by pr.id having coalesce(sum(b.qty), 0) <= pr.reorder_level
       order by pr.reorder_level - coalesce(sum(b.qty), 0) desc) x;

  elsif p_report = 'stock-expiry' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select l.name as location, pr.name as product, pb.batch_no, lt.stock_status, lt.qty, pb.production_date, pb.expiry_date,
             (pb.expiry_date - app.today()) as days_left
        from public.inventory_lots lt join public.products pr on pr.id = lt.product_id join public.locations l on l.id = lt.location_id
        join public.production_batches pb on pb.id = lt.batch_id
       where lt.qty > 0 and pb.expiry_date is not null and pb.expiry_date <= app.today() + coalesce(app.jint(p, 'days'), 60)
         and (v_loc is null or lt.location_id = v_loc)
       order by pb.expiry_date, l.name) x;

  -- ===================================================================== Bottles
  elsif p_report = 'bottle-circulation' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select bt.name as bottle_type,
             case when b.holder_type = 'customer' then 'With customers'
                  when b.holder_type = 'location' and l.location_type = 'vehicle' then 'On vehicles'
                  when b.holder_type = 'location' and l.location_type = 'water_shop' then 'At water shops'
                  when b.holder_type = 'location' and l.location_type = 'external_holding' then 'External holding area'
                  when b.holder_type = 'location' then 'Warehouses & head office'
                  when b.holder_type = 'company' then 'With other companies'
                  else 'Outside (lost / written off)' end as holder,
             sum(b.qty) filter (where b.fill_state = 'full') as full, sum(b.qty) filter (where b.fill_state = 'empty') as empty, sum(b.qty) as total
        from public.bottle_balances b join public.bottle_types bt on bt.id = b.bottle_type_id
        left join public.locations l on b.holder_type = 'location' and l.id = b.holder_id
       where b.company_id = coalesce(v_co, v_own) and b.qty <> 0
       group by 1, 2 order by 1, 2) x;

  elsif p_report = 'bottle-customers' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select c.id as customer_id, c.customer_no, c.name as customer, c.customer_type, c.bottle_model, c.allowed_bottles,
             coalesce(bb.qty, 0) as ola_held, coalesce(dp.qty, 0) as deposits_qty, coalesce(dp.amount, 0) as deposits_amount,
             case when c.bottle_model = 'loan' and coalesce(bb.qty, 0) > c.allowed_bottles then coalesce(bb.qty, 0) - c.allowed_bottles
                  when c.bottle_model = 'deposit' and coalesce(bb.qty, 0) > coalesce(dp.qty, 0) then coalesce(bb.qty, 0) - coalesce(dp.qty, 0)
                  else 0 end as uncovered,
             (select max(bx.created_at) from public.bottle_transactions bx where bx.to_type = 'customer' and bx.to_id = c.id) as last_delivered
        from public.customers c
        left join lateral (select sum(qty) qty from public.bottle_balances where holder_type = 'customer' and holder_id = c.id and company_id = v_own) bb on true
        left join lateral (select sum(qty_held) qty, sum(amount_held) amount from public.customer_deposit_balances where customer_id = c.id) dp on true
       where (coalesce(bb.qty, 0) <> 0 or coalesce(dp.qty, 0) <> 0)
         and (v_ctype is null or c.customer_type = v_ctype) and (v_route is null or c.route_id = v_route)
       order by 10 desc, coalesce(bb.qty, 0) desc limit 3000) x;

  elsif p_report = 'bottle-holders' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select l.name as holder, case l.location_type when 'vehicle' then 'Vehicle' when 'water_shop' then 'Water shop' else initcap(replace(l.location_type, '_', ' ')) end as holder_kind,
             (select pf.full_name from public.vehicles vh join public.profiles pf on pf.id = vh.assigned_driver_id where vh.location_id = l.id) as driver,
             bc.name as company, bt.name as bottle_type,
             sum(b.qty) filter (where b.fill_state = 'full') as full, sum(b.qty) filter (where b.fill_state = 'empty') as empty, sum(b.qty) as total
        from public.bottle_balances b join public.locations l on l.id = b.holder_id
        join public.bottle_companies bc on bc.id = b.company_id join public.bottle_types bt on bt.id = b.bottle_type_id
       where b.holder_type = 'location' and b.qty <> 0 and (v_co is null or b.company_id = v_co) and (v_loc is null or l.id = v_loc)
       group by l.id, l.name, l.location_type, bc.name, bt.name order by 2, 1, 4, 5) x;

  elsif p_report = 'bottle-external' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select bc.name as company,
             coalesce((select sum(b.qty) from public.bottle_balances b where b.company_id = bc.id and b.holder_type = 'location'), 0) as held_now,
             coalesce((select sum(t.qty) from public.bottle_transactions t where t.company_id = bc.id and t.txn_type = 'external_intake'
                        and (t.created_at at time zone 'Asia/Colombo')::date between v_from and v_to), 0) as received_from_customers,
             coalesce((select sum(h.bottles_given) from public.external_handovers h where h.company_id = bc.id and h.handover_date between v_from and v_to), 0) as returned_to_company,
             coalesce((select sum(h.ola_received) from public.external_handovers h where h.company_id = bc.id and h.handover_date between v_from and v_to), 0) as ola_received_back,
             (select count(*) from public.external_handovers h where h.company_id = bc.id and h.handover_date between v_from and v_to) as handovers,
             (select max(h.handover_date) from public.external_handovers h where h.company_id = bc.id) as last_handover,
             coalesce(bc.holding_alert_qty, (app.get_setting('bottles.external_holding_alert_qty') #>> '{}')::integer) as alert_level
        from public.bottle_companies bc
       where not bc.is_own and bc.is_active and (v_co is null or bc.id = v_co)
       order by 2 desc) x;

  elsif p_report = 'bottle-external-statement' then
    if v_co is null then raise exception 'Choose the company' using errcode = '22023'; end if;
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select (t.created_at at time zone 'Asia/Colombo')::date as date, t.txn_type, bt.name as bottle_type,
             case when t.txn_type in ('external_intake','received_from_company') then t.qty else 0 end as bottles_in,
             case when t.txn_type in ('return_to_owner','write_off','retire') then t.qty else 0 end as bottles_out,
             t.reference_type, t.reason
        from public.bottle_transactions t join public.bottle_types bt on bt.id = t.bottle_type_id
       where t.company_id = v_co and (t.created_at at time zone 'Asia/Colombo')::date between v_from and v_to
         and t.txn_type in ('external_intake','return_to_owner','received_from_company','write_off','retire','opening','adjust')
       union all
      select h.handover_date, 'handover — OLA bottles received from them', null, h.ola_received, 0, 'handover ' || h.handover_no, h.rep_name
        from public.external_handovers h where h.company_id = v_co and h.handover_date between v_from and v_to and h.ola_received > 0
       order by 1) x;

  elsif p_report = 'bottle-exposure' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select g.holder, bt.name as bottle_type, g.qty, coalesce((app.bottle_value(bt.id, v_own)).replacement_value, 0) as unit_value,
             round(g.qty * coalesce((app.bottle_value(bt.id, v_own)).replacement_value, 0), 2) as value,
             case when g.holder = 'With customers' then coalesce((select sum(amount_held) from public.customer_deposit_balances d where d.bottle_type_id = bt.id), 0) else 0 end as deposits_held,
             round(g.qty * coalesce((app.bottle_value(bt.id, v_own)).replacement_value, 0), 2)
               - case when g.holder = 'With customers' then coalesce((select sum(amount_held) from public.customer_deposit_balances d where d.bottle_type_id = bt.id), 0) else 0 end as uncovered
        from (select b.bottle_type_id,
                     case when b.holder_type = 'customer' then 'With customers'
                          when l.location_type = 'vehicle' then 'On vehicles'
                          when l.location_type = 'water_shop' then 'At water shops'
                          when b.holder_type = 'company' then 'With other companies'
                          else 'Other' end as holder, sum(b.qty) qty
                from public.bottle_balances b left join public.locations l on b.holder_type = 'location' and l.id = b.holder_id
               where b.company_id = v_own and b.qty > 0
                 and (b.holder_type in ('customer','company') or l.location_type in ('vehicle','water_shop'))
               group by 1, 2) g join public.bottle_types bt on bt.id = g.bottle_type_id
       order by 1, 2) x;

  elsif p_report = 'bottle-losses' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select (t.created_at at time zone 'Asia/Colombo')::date as date, t.txn_type, bc.name as company, bt.name as bottle_type, t.qty,
             bo.code as bottle_code, coalesce(fl.name, t.from_type) as from_holder, t.reason,
             round(t.qty * coalesce((app.bottle_value(t.bottle_type_id, t.company_id)).replacement_value, 0), 2) as value
        from public.bottle_transactions t join public.bottle_companies bc on bc.id = t.company_id join public.bottle_types bt on bt.id = t.bottle_type_id
        left join public.bottles bo on bo.id = t.bottle_id left join public.locations fl on t.from_type = 'location' and fl.id = t.from_id
       where t.txn_type in ('write_off','retire','mark_damaged') and (t.created_at at time zone 'Asia/Colombo')::date between v_from and v_to
         and (v_co is null or t.company_id = v_co)
       order by t.created_at desc) x;

  elsif p_report = 'bottle-discrepancies' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select (e.created_at at time zone 'Asia/Colombo')::date as date, e.exception_type, e.description, e.expected, e.actual, e.difference,
             e.status, e.resolution, rr.run_no, l.name as location
        from public.operation_exceptions e left join public.route_runs rr on rr.id = e.run_id left join public.locations l on l.id = e.location_id
       where e.exception_type in ('bottle_location','bottle_shortage','bottle_surplus','over_bottle_limit')
         and (e.created_at at time zone 'Asia/Colombo')::date between v_from and v_to
       order by e.created_at desc) x;

  elsif p_report = 'bottle-ageing' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select case when b.holder_type = 'customer' then 'With customers' when l.location_type = 'vehicle' then 'On vehicles'
                  when l.location_type = 'water_shop' then 'At water shops' when b.holder_type = 'location' then 'Warehouses'
                  else initcap(b.holder_type) end as holder,
             count(*) filter (where coalesce(b.last_movement_at, b.created_at) >= now() - interval '30 days') as d0_30,
             count(*) filter (where coalesce(b.last_movement_at, b.created_at) < now() - interval '30 days' and coalesce(b.last_movement_at, b.created_at) >= now() - interval '60 days') as d31_60,
             count(*) filter (where coalesce(b.last_movement_at, b.created_at) < now() - interval '60 days' and coalesce(b.last_movement_at, b.created_at) >= now() - interval '90 days') as d61_90,
             count(*) filter (where coalesce(b.last_movement_at, b.created_at) < now() - interval '90 days') as d90_plus,
             count(*) as total
        from public.bottles b left join public.locations l on b.holder_type = 'location' and l.id = b.holder_id
       where b.company_id = coalesce(v_co, v_own) and b.lifecycle = 'active'
       group by 1 order by 1) x;

  elsif p_report = 'bottle-retirement' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select b.code, bt.name as bottle_type, b.fill_count, (app.get_setting('bottles.max_fill_count') #>> '{}')::integer as max_fills,
             b.condition, case b.holder_type when 'customer' then (select c.name from public.customers c where c.id = b.holder_id)
                                             when 'location' then (select l.name from public.locations l where l.id = b.holder_id)
                                             else b.holder_type end as holder,
             b.last_movement_at
        from public.bottles b join public.bottle_types bt on bt.id = b.bottle_type_id
       where b.company_id = v_own and b.lifecycle = 'active'
         and (b.fill_count >= 0.9 * coalesce((app.get_setting('bottles.max_fill_count') #>> '{}')::integer, 50) or b.condition <> 'good')
       order by b.fill_count desc limit 3000) x;

  -- ===================================================================== Delivery
  elsif p_report = 'delivery-daily' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select r.run_date as date, count(distinct r.id) as runs,
             count(d.id) filter (where d.status <> 'cancelled') as stops,
             count(d.id) filter (where d.status = 'delivered') as delivered,
             count(d.id) filter (where d.status = 'partially_delivered') as partial,
             count(d.id) filter (where d.status = 'failed') as failed,
             round(100.0 * count(d.id) filter (where d.status in ('delivered','partially_delivered'))
                   / nullif(count(d.id) filter (where d.status in ('delivered','partially_delivered','failed')), 0), 1) as success_pct
        from public.route_runs r left join public.deliveries d on d.run_id = r.id
       where r.run_date between v_from and v_to and r.status <> 'cancelled' and (v_route is null or r.route_id = v_route)
       group by r.run_date order by r.run_date) x;

  elsif p_report = 'delivery-failures' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select coalesce(nullif(trim(d.failure_reason), ''), 'No reason given') as reason, count(*) as failures,
             round(100.0 * count(*) / nullif(sum(count(*)) over (), 0), 1) as share_pct,
             count(distinct d.customer_id) as customers
        from public.deliveries d join public.route_runs r on r.id = d.run_id
       where d.status = 'failed' and r.run_date between v_from and v_to and (v_route is null or r.route_id = v_route)
       group by 1 order by 2 desc) x;

  elsif p_report = 'delivery-drivers' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select pf.full_name as driver, count(distinct r.id) as runs,
             count(d.id) filter (where d.status <> 'cancelled') as stops,
             count(d.id) filter (where d.status = 'failed') as failed,
             round(100.0 * count(d.id) filter (where d.status in ('delivered','partially_delivered'))
                   / nullif(count(d.id) filter (where d.status in ('delivered','partially_delivered','failed')), 0), 1) as success_pct,
             coalesce(sum((d.summary ->> 'total')::numeric), 0) as invoiced,
             coalesce((select sum(e.expected - e.actual) from public.operation_exceptions e join public.route_runs r2 on r2.id = e.run_id
                        where r2.driver_id = r.driver_id and e.exception_type = 'cash_shortage' and r2.run_date between v_from and v_to), 0) as cash_short,
             coalesce((select sum(e.expected - e.actual) from public.operation_exceptions e join public.route_runs r2 on r2.id = e.run_id
                        where r2.driver_id = r.driver_id and e.exception_type = 'bottle_shortage' and r2.run_date between v_from and v_to), 0) as bottles_short
        from public.route_runs r join public.profiles pf on pf.id = r.driver_id left join public.deliveries d on d.run_id = r.id
       where r.run_date between v_from and v_to and r.status <> 'cancelled'
       group by r.driver_id, pf.full_name order by 3 desc) x;

  elsif p_report = 'delivery-routes' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select coalesce(rt.name, 'No route') as route, count(distinct r.id) as runs,
             count(d.id) filter (where d.status <> 'cancelled') as stops,
             round(count(d.id) filter (where d.status <> 'cancelled')::numeric / nullif(count(distinct r.id), 0), 1) as stops_per_run,
             round(100.0 * count(d.id) filter (where d.status in ('delivered','partially_delivered'))
                   / nullif(count(d.id) filter (where d.status in ('delivered','partially_delivered','failed')), 0), 1) as success_pct,
             coalesce(sum((d.summary ->> 'total')::numeric), 0) as invoiced,
             round(coalesce(sum((d.summary ->> 'total')::numeric), 0) / nullif(count(distinct r.id), 0), 2) as invoiced_per_run
        from public.route_runs r left join public.routes rt on rt.id = r.route_id left join public.deliveries d on d.run_id = r.id
       where r.run_date between v_from and v_to and r.status <> 'cancelled'
       group by rt.id, rt.name order by 6 desc) x;

  elsif p_report = 'delivery-vehicles' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select vp.registration_no as vehicle, vp.runs, vp.sales, vp.fuel, vp.repairs, vp.other_costs, vp.depreciation, vp.contribution,
             (select sum(f.litres) from public.fuel_logs f where f.vehicle_id = vp.vehicle_id and f.fuel_date between v_from and v_to) as litres
        from public.vehicle_profitability(v_from, v_to) vp
       order by vp.contribution desc) x;

  -- ===================================================================== Production & QC
  elsif p_report = 'production-summary' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select pr.name as product, count(*) as batches, sum(b.planned_qty) as planned, coalesce(sum(b.produced_qty), 0) as produced,
             coalesce(sum(b.rejected_qty), 0) as rejected, coalesce(sum(b.wastage_qty), 0) as wastage,
             round(100.0 * coalesce(sum(b.produced_qty), 0) / nullif(sum(b.planned_qty), 0), 1) as yield_pct,
             round(100.0 * coalesce(sum(b.rejected_qty), 0) / nullif(coalesce(sum(b.produced_qty), 0) + coalesce(sum(b.rejected_qty), 0), 0), 1) as rejection_pct,
             count(*) filter (where b.status = 'released') as released, count(*) filter (where b.status in ('failed','recalled')) as failed,
             round(sum(b.material_cost) / nullif(sum(b.produced_qty), 0), 2) as avg_unit_cost
        from public.production_batches b join public.products pr on pr.id = b.product_id
       where b.production_date between v_from and v_to and b.status <> 'cancelled' and (v_prod is null or b.product_id = v_prod)
       group by pr.id, pr.name order by 4 desc) x;

  elsif p_report = 'production-batches' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select b.id as batch_id, b.batch_no, b.production_date, pr.name as product, pl.name as line, b.shift, b.planned_qty, b.produced_qty,
             b.rejected_qty, b.wastage_qty, b.unit_cost, b.status,
             (select count(*) from public.qc_tests q where q.batch_id = b.id and q.result = 'pass') as qc_pass,
             (select count(*) from public.qc_tests q where q.batch_id = b.id and q.result = 'fail') as qc_fail,
             (select count(*) from public.complaints c where c.batch_id = b.id) as complaints
        from public.production_batches b join public.products pr on pr.id = b.product_id join public.production_lines pl on pl.id = b.line_id
       where b.production_date between v_from and v_to and (v_prod is null or b.product_id = v_prod)
       order by b.production_date desc, b.batch_no desc) x;

  elsif p_report = 'production-qc-failures' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select q.test_no, (q.tested_at at time zone 'Asia/Colombo')::date as date, b.batch_no, pr.name as product, t.name as test,
             q.lab_name, b.status as batch_status, q.notes,
             (select string_agg(r.parameter_name || ' ' || coalesce(r.value_text, r.value_num::text, ''), '; ')
                from public.qc_test_results r where r.test_id = q.id and not r.passed) as failed_checks
        from public.qc_tests q join public.production_batches b on b.id = q.batch_id join public.products pr on pr.id = b.product_id
        join public.qc_templates t on t.id = q.template_id
       where q.result = 'fail' and (q.tested_at at time zone 'Asia/Colombo')::date between v_from and v_to
       order by q.tested_at desc) x;

  elsif p_report = 'production-recalls' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select rc.recall_no, (rc.created_at at time zone 'Asia/Colombo')::date as date, b.batch_no, pr.name as product, rc.reason, rc.status,
             count(rcc.id) as customers, coalesce(sum(rcc.qty_supplied), 0) as supplied, coalesce(sum(rcc.qty_recovered), 0) as recovered,
             round(100.0 * coalesce(sum(rcc.qty_recovered), 0) / nullif(sum(rcc.qty_supplied), 0), 1) as recovered_pct
        from public.batch_recalls rc join public.production_batches b on b.id = rc.batch_id join public.products pr on pr.id = b.product_id
        left join public.batch_recall_customers rcc on rcc.recall_id = rc.id
       where (rc.created_at at time zone 'Asia/Colombo')::date between v_from and v_to
       group by rc.id, b.batch_no, pr.name order by rc.created_at desc) x;

  -- ===================================================================== Finance (operational)
  elsif p_report = 'finance-expenses' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select ec.name as category, count(*) as expenses, sum(e.net_amount) as net, sum(e.vat_amount) as vat, sum(e.total) as total,
             round(100 * sum(e.net_amount) / nullif(sum(sum(e.net_amount)) over (), 0), 1) as share_pct
        from public.expenses e join public.expense_categories ec on ec.id = e.category_id
       where e.status in ('approved','paid') and e.expense_date between v_from and v_to and (v_loc is null or e.location_id = v_loc)
       group by ec.id, ec.name order by sum(e.net_amount) desc) x;

  elsif p_report = 'finance-shop-balances' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select s.name as shop, s.operating_model,
             coalesce((select sum(i.subtotal_net) from public.invoices i where i.location_id = s.location_id and i.status <> 'void'
                        and i.invoice_date between v_from and v_to), 0) as sales_net,
             coalesce((select sum(st.cash_expected) from public.shop_settlements st where st.shop_id = s.id and st.period_to between v_from and v_to), 0) as settled_expected,
             coalesce((select sum(st.amount_received) from public.shop_settlements st where st.shop_id = s.id and st.period_to between v_from and v_to), 0) as settled_received,
             coalesce((select sum(st.commission) from public.shop_settlements st where st.shop_id = s.id and st.period_to between v_from and v_to), 0) as commission,
             (select max(st.period_to) from public.shop_settlements st where st.shop_id = s.id) as settled_up_to,
             case when s.account_customer_id is not null then app.customer_outstanding(s.account_customer_id) end as dealer_owes
        from public.water_shops s
       where s.status <> 'closed'
       order by s.name) x;

  elsif p_report = 'finance-deposits' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select bt.name as bottle_type, count(distinct d.customer_id) filter (where d.qty_held <> 0) as customers,
             coalesce(sum(d.qty_held), 0) as bottles, coalesce(sum(d.amount_held), 0) as amount,
             coalesce((select sum(dt.amount) from public.deposit_transactions dt where dt.bottle_type_id = bt.id and dt.txn_type in ('collected','opening')
                        and (dt.created_at at time zone 'Asia/Colombo')::date between v_from and v_to), 0) as taken_in_period,
             coalesce((select sum(abs(dt.amount)) from public.deposit_transactions dt where dt.bottle_type_id = bt.id and dt.txn_type in ('refunded','forfeited')
                        and (dt.created_at at time zone 'Asia/Colombo')::date between v_from and v_to), 0) as released_in_period
        from public.bottle_types bt left join public.customer_deposit_balances d on d.bottle_type_id = bt.id
       group by bt.id, bt.name order by bt.name) x;
    v := v || jsonb_build_array(jsonb_build_object('bottle_type', 'Ledger: Bottle Deposits Held (2200)',
             'amount', coalesce((select sum(l.credit - l.debit) from public.journal_lines l join public.accounts a on a.id = l.account_id
                                  join public.journal_entries je on je.id = l.entry_id
                                 where a.system_key = 'bottle_deposits' and je.entry_date <= v_to), 0)));

  -- ===================================================================== Complaints
  elsif p_report = 'complaints-by-category' then
    select coalesce(jsonb_agg(to_jsonb(x)), '[]') into v from (
      select cat.name as category, count(c.id) as logged,
             count(c.id) filter (where c.status in ('resolved','closed')) as resolved,
             count(c.id) filter (where c.status not in ('resolved','closed')) as open,
             round(100.0 * count(c.id) filter (where c.resolved_at <= c.due_at) / nullif(count(c.id) filter (where c.resolved_at is not null), 0), 0) as within_sla_pct,
             round(avg(extract(epoch from c.resolved_at - c.created_at) / 3600)::numeric, 1) as avg_hours
        from public.complaint_categories cat left join public.complaints c on c.category_code = cat.code
             and (c.created_at at time zone 'Asia/Colombo')::date between v_from and v_to
       group by cat.code, cat.name, cat.sort_order order by cat.sort_order) x;

  else
    raise exception 'Unknown report %', p_report using errcode = '22023';
  end if;

  if app.jbool(p, 'export', false) then
    perform app.write_audit('export', 'reports', 'report', p_report, null, p - 'export', 'Report downloaded');
  end if;
  return coalesce(v, '[]');
end $$;

-- Exports of the finance reports (CSV downloads) are recorded the same way.
create or replace function public.log_export(p_report text, p_filters jsonb default '{}')
returns void language plpgsql security definer set search_path = '' as $$
begin
  if app.current_user_id() is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  perform app.write_audit('export', 'reports', 'report', left(p_report, 60), null, coalesce(p_filters, '{}'), 'Report downloaded');
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

commit;
