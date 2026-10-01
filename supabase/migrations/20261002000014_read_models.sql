-- =====================================================================
-- OLA Water ERP — Phase 1A
-- 0014: read models for screens (dashboard, customer summary, bottles)
-- =====================================================================

create or replace function public.dashboard_summary()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_today date := app.today(); v_own uuid := app.own_company_id(); v jsonb;
begin
  perform app.require_permission('dashboard.view');
  select jsonb_build_object(
    'today', v_today,
    'sales_today', coalesce((select sum(subtotal_net + tax_total) from public.invoices where invoice_date = v_today and status <> 'void'), 0),
    'invoices_today', (select count(*) from public.invoices where invoice_date = v_today and status <> 'void'),
    'collected_today', coalesce((select sum(amount) from public.payments where (received_at at time zone 'Asia/Colombo')::date = v_today
                                   and status = 'received'), 0),
    'orders_today', (select count(*) from public.orders where (created_at at time zone 'Asia/Colombo')::date = v_today),
    'orders_on_hold', (select count(*) from public.orders where status = 'on_hold'),
    'orders_to_dispatch', (select count(*) from public.orders where status = 'confirmed' and requested_date <= v_today),
    'deliveries', (select jsonb_build_object(
        'total', count(*) filter (where d.status <> 'cancelled'),
        'completed', count(*) filter (where d.status in ('delivered','partially_delivered')),
        'failed', count(*) filter (where d.status = 'failed'),
        'pending', count(*) filter (where d.status = 'pending'))
      from public.deliveries d join public.route_runs r on r.id = d.run_id where r.run_date = v_today),
    'runs_out', (select count(*) from public.route_runs where status = 'in_progress'),
    'customer_outstanding', coalesce((select sum(total) from public.invoices where status <> 'void'), 0)
                            - coalesce((select sum(amount) from public.payments where status = 'received'), 0),
    'overdue', coalesce((select sum(balance) from public.invoices where status in ('open','partially_paid') and due_date < v_today), 0),
    'bottles', jsonb_build_object(
      'warehouse_full', coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
                         where b.holder_type = 'location' and l.location_type in ('warehouse','head_office') and b.company_id = v_own and b.fill_state = 'full'), 0),
      'warehouse_empty', coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
                         where b.holder_type = 'location' and l.location_type in ('warehouse','head_office') and b.company_id = v_own and b.fill_state = 'empty'), 0),
      'on_vehicles', coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
                         where b.holder_type = 'location' and l.location_type = 'vehicle' and b.company_id = v_own), 0),
      'with_customers', coalesce((select sum(qty) from public.bottle_balances where holder_type = 'customer' and company_id = v_own), 0),
      'external_held', coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
                         where b.holder_type = 'location' and l.location_type = 'external_holding' and b.company_id <> v_own), 0),
      'external_on_vehicles', coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
                         where b.holder_type = 'location' and l.location_type = 'vehicle' and b.company_id <> v_own), 0)),
    'exceptions', jsonb_build_object(
      'critical', (select count(*) from public.operation_exceptions where status = 'open' and severity = 'critical'),
      'warning', (select count(*) from public.operation_exceptions where status = 'open' and severity = 'warning'),
      'info', (select count(*) from public.operation_exceptions where status = 'open' and severity = 'info')),
    'external_alerts', (select coalesce(jsonb_agg(jsonb_build_object('company', c.name, 'held', h.qty, 'limit', h.alert)), '[]') from (
        select b.company_id, sum(b.qty) qty,
               coalesce(bc.holding_alert_qty, (app.get_setting('bottles.external_holding_alert_qty') #>> '{}')::integer) alert
          from public.bottle_balances b join public.locations l on l.id = b.holder_id
          join public.bottle_companies bc on bc.id = b.company_id
         where b.holder_type = 'location' and l.location_type = 'external_holding' and not bc.is_own
         group by b.company_id, bc.holding_alert_qty) h join public.bottle_companies c on c.id = h.company_id
       where h.qty > h.alert),
    'sales_14d', (select coalesce(jsonb_agg(jsonb_build_object('date', d::date, 'sales',
                     coalesce((select sum(subtotal_net + tax_total) from public.invoices where invoice_date = d::date and status <> 'void'), 0),
                     'deliveries', (select count(*) from public.deliveries where status in ('delivered','partially_delivered')
                                     and (completed_at at time zone 'Asia/Colombo')::date = d::date)) order by d), '[]')
                    from generate_series(v_today - 13, v_today, interval '1 day') d)
  ) into v;
  return v;
end $$;

create or replace function public.customer_summary(p_customer uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c public.customers; v jsonb;
begin
  perform app.require_permission('customers.view');
  select * into c from public.customers where id = p_customer;
  if not found then raise exception 'Customer not found' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'outstanding', app.customer_outstanding(c.id),
    'overdue', app.customer_overdue(c.id),
    'credit_available', case when c.credit_limit > 0 then c.credit_limit - app.customer_outstanding(c.id) end,
    'ola_bottles', app.customer_ola_bottles(c.id),
    'bottles_by_type', (select coalesce(jsonb_agg(jsonb_build_object('type', bt.name, 'qty', s.qty)), '[]') from (
        select bottle_type_id, sum(qty) qty from public.bottle_balances
         where holder_type = 'customer' and holder_id = c.id and company_id = app.own_company_id() group by bottle_type_id) s
        join public.bottle_types bt on bt.id = s.bottle_type_id),
    'deposits', (select coalesce(jsonb_agg(jsonb_build_object('type', bt.name, 'qty', d.qty_held, 'amount', d.amount_held)), '[]')
                   from public.customer_deposit_balances d join public.bottle_types bt on bt.id = d.bottle_type_id
                  where d.customer_id = c.id and d.qty_held <> 0),
    'last_delivery', (select max(completed_at) from public.deliveries where customer_id = c.id and status in ('delivered','partially_delivered')),
    'open_orders', (select count(*) from public.orders where customer_id = c.id and status in ('draft','on_hold','confirmed','assigned','loaded','out_for_delivery'))
  ) into v;
  return v;
end $$;

-- Where every bottle is: by owner company, type and kind of holder
create or replace function public.bottle_overview()
returns table (company_id uuid, company text, is_own boolean, bottle_type text, holder_kind text, fill_state text, qty bigint, value numeric)
language sql stable security definer set search_path = '' as $$
  select bc.id, bc.name, bc.is_own, bt.name,
         case b.holder_type when 'location' then l.location_type else b.holder_type end,
         b.fill_state, sum(b.qty),
         sum(b.qty) * coalesce((app.bottle_value(bt.id, bc.id)).replacement_value, 0)
    from public.bottle_balances b
    join public.bottle_companies bc on bc.id = b.company_id
    join public.bottle_types bt on bt.id = b.bottle_type_id
    left join public.locations l on b.holder_type = 'location' and l.id = b.holder_id
   where app.has_permission('bottles.view') and b.qty <> 0 and b.holder_type <> 'outside'
   group by bc.id, bc.name, bc.is_own, bt.id, bt.name, 5, b.fill_state
   order by bc.is_own desc, bc.name, bt.name, 5
$$;

-- External bottles: collected, returned, held — per company
create or replace function public.external_bottle_accounts()
returns table (company_id uuid, company text, code text, held bigint, on_vehicles bigint, tagged_held bigint,
               collected bigint, returned bigint, ola_received bigint, held_value numeric, alert_qty integer, last_handover date)
language sql stable security definer set search_path = '' as $$
  select bc.id, bc.name, bc.code,
    coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
               where b.company_id = bc.id and b.holder_type = 'location' and l.location_type = 'external_holding'), 0),
    coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
               where b.company_id = bc.id and b.holder_type = 'location' and l.location_type = 'vehicle'), 0),
    (select count(*) from public.bottles bo join public.locations l on l.id = bo.holder_id
      where bo.company_id = bc.id and bo.holder_type = 'location' and l.location_type = 'external_holding'),
    coalesce((select sum(qty) from public.bottle_transactions where company_id = bc.id and txn_type = 'external_intake'), 0),
    coalesce((select sum(qty) from public.bottle_transactions where company_id = bc.id and txn_type = 'return_to_owner'), 0),
    coalesce((select sum(ola_received) from public.external_handovers where company_id = bc.id), 0),
    coalesce((select sum(b.qty * coalesce((app.bottle_value(b.bottle_type_id, bc.id)).replacement_value, 0))
                from public.bottle_balances b join public.locations l on l.id = b.holder_id
               where b.company_id = bc.id and b.holder_type = 'location' and l.location_type in ('external_holding','vehicle')), 0),
    coalesce(bc.holding_alert_qty, (app.get_setting('bottles.external_holding_alert_qty') #>> '{}')::integer),
    (select max(handover_date) from public.external_handovers where company_id = bc.id)
  from public.bottle_companies bc
  where not bc.is_own and app.has_permission('bottles.view')
  order by bc.name
$$;

-- Bottle lookup by scanned code (with its history)
create or replace function public.bottle_details(p_code text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare b public.bottles; v jsonb;
begin
  perform app.require_permission('bottles.view');
  b := app.bottle_by_code(p_code);
  if b.id is null then
    return (select jsonb_build_object('found', false, 'identifier', to_jsonb(i)) from public.identifiers i where i.value = upper(trim(p_code)));
  end if;
  select jsonb_build_object('found', true,
    'bottle', jsonb_build_object('id', b.id, 'code', b.code, 'company', (select name from public.bottle_companies where id = b.company_id),
      'is_own', b.company_id = app.own_company_id(), 'type', (select name from public.bottle_types where id = b.bottle_type_id),
      'holder', app.holder_label(b.holder_type, b.holder_id), 'holder_type', b.holder_type, 'fill_state', b.fill_state,
      'condition', b.condition, 'lifecycle', b.lifecycle, 'fill_count', b.fill_count, 'created_at', b.created_at,
      'last_movement_at', b.last_movement_at),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('at', t.created_at, 'type', t.txn_type,
        'from', app.holder_label(t.from_type, t.from_id), 'to', app.holder_label(t.to_type, t.to_id), 'to_fill', t.to_fill,
        'by', (select full_name from public.profiles where id = t.created_by), 'reference_type', t.reference_type,
        'reason', t.reason) order by t.created_at desc, t.id desc), '[]')
      from public.bottle_transactions t where t.bottle_id = b.id)
  ) into v;
  return v;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;
revoke execute on function public.log_failed_login(text, text, text, text) from authenticated;
revoke execute on function public.bootstrap_super_admin(text)              from authenticated;

-- Customer list with balances (server-side search + pagination)
create or replace function public.customer_list(
  p_search text, p_type text, p_route uuid, p_status text, p_limit integer, p_offset integer)
returns table (id uuid, customer_no text, name text, company_name text, customer_type text, phone text, route text,
               status text, bottle_model text, ola_bottles integer, outstanding numeric, total_count bigint)
language sql stable security definer set search_path = '' as $$
  with f as (
    select c.* from public.customers c
     where app.has_permission('customers.view')
       and (p_search is null or p_search = '' or c.name ilike '%' || p_search || '%' or c.company_name ilike '%' || p_search || '%'
            or c.customer_no ilike '%' || p_search || '%'
            or c.phone like '%' || regexp_replace(regexp_replace(p_search, '[^0-9]', '', 'g'), '^0', '') || '%')
       and (p_type is null or p_type = '' or c.customer_type = p_type)
       and (p_route is null or c.route_id = p_route)
       and (p_status is null or p_status = '' or c.status = p_status))
  select f.id, f.customer_no, f.name, f.company_name, f.customer_type, f.phone, r.name, f.status, f.bottle_model,
         app.customer_ola_bottles(f.id), app.customer_outstanding(f.id), count(*) over ()
    from f left join public.routes r on r.id = f.route_id
   order by f.name
   limit least(coalesce(p_limit, 50), 200) offset coalesce(p_offset, 0)
$$;
grant execute on function public.customer_list(text, text, uuid, text, integer, integer) to authenticated;

-- Active staff who can drive (for dispatch and route screens)
create or replace function public.list_drivers()
returns table (id uuid, full_name text, phone text)
language sql stable security definer set search_path = '' as $$
  select distinct p.id, p.full_name, p.phone
    from public.profiles p
    join public.user_roles ur on ur.user_id = p.id
    join public.roles r on r.id = ur.role_id and r.code = 'driver' and r.archived_at is null
   where p.is_active
     and (app.has_permission('deliveries.manage') or app.has_permission('routes.manage') or app.has_permission('deliveries.view'))
   order by p.full_name
$$;
grant execute on function public.list_drivers() to authenticated;
