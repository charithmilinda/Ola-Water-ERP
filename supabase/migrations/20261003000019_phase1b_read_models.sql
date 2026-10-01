-- =====================================================================
-- OLA Water ERP — Phase 1B
-- 0019: read models for shops, tills and the dashboard
-- =====================================================================

create or replace function app.can_see_shop(p_location uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select app.has_permission('shops.view') or app.has_permission_at('shops.view', p_location) or app.has_permission_at('shop_pos.use', p_location)
$$;

-- Counters this user may run (shops + head-office / warehouse counters)
create or replace function public.my_pos_locations()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'code', l.code, 'name', l.name, 'type', l.location_type,
           'shop_id', w.id, 'operating_model', w.operating_model,
           'till_open', exists (select 1 from public.pos_sessions s where s.location_id = l.id and s.status = 'open'))
         order by l.location_type desc, l.name), '[]')
    from public.locations l left join public.water_shops w on w.location_id = l.id
   where l.is_active and l.location_type in ('water_shop','warehouse','head_office')
     and (w.id is null or w.status = 'active')
     and app.has_permission_at(app.pos_permission(l.id), l.id)
$$;

create or replace function public.shop_list()
returns table (id uuid, code text, name text, operating_model text, status text, city text, phone text, location_id uuid,
               sales_today numeric, outstanding numeric, pending_requests bigint, till_open boolean, open_exceptions bigint,
               ola_bottles bigint, external_bottles bigint)
language sql stable security definer set search_path = '' as $$
  select w.id, w.code, w.name, w.operating_model, w.status, w.city, w.phone, w.location_id,
    coalesce((select sum(total) from public.pos_sales s where s.location_id = w.location_id
               and (s.sold_at at time zone 'Asia/Colombo')::date = app.today()), 0),
    case when w.operating_model = 'dealer' then app.customer_outstanding(w.account_customer_id) else 0 end,
    (select count(*) from public.shop_stock_requests r where r.shop_id = w.id and r.status in ('submitted','approved','dispatched')),
    exists (select 1 from public.pos_sessions s where s.location_id = w.location_id and s.status = 'open'),
    (select count(*) from public.operation_exceptions e where e.status = 'open' and (e.location_id = w.location_id or e.target_location_id = w.location_id)),
    coalesce((select sum(qty) from public.bottle_balances b where b.holder_type = 'location' and b.holder_id = w.location_id
               and b.company_id = app.own_company_id()), 0),
    coalesce((select sum(qty) from public.bottle_balances b where b.holder_type = 'location' and b.holder_id = w.location_id
               and b.company_id <> app.own_company_id()), 0)
  from public.water_shops w
  where app.can_see_shop(w.location_id)
  order by w.status, w.name
$$;

create or replace function public.shop_dashboard(p_shop uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare w public.water_shops; v jsonb; v_today date := app.today();
begin
  select * into w from public.water_shops where id = p_shop;
  if not found then raise exception 'Shop not found' using errcode = 'P0002'; end if;
  if not app.can_see_shop(w.location_id) then raise exception 'Permission denied' using errcode = '42501'; end if;
  select jsonb_build_object(
    'shop', to_jsonb(w) || jsonb_build_object(
        'account', (select jsonb_build_object('id', c.id, 'customer_no', c.customer_no, 'credit_limit', c.credit_limit,
                       'payment_terms_days', c.payment_terms_days) from public.customers c where c.id = w.account_customer_id),
        'retail_price_list', (select name from public.price_lists where id = w.retail_price_list_id),
        'transfer_price_list', (select name from public.price_lists where id = w.transfer_price_list_id)),
    'today', app.shop_figures(w.id, v_today, v_today),
    'month', app.shop_figures(w.id, date_trunc('month', v_today)::date, v_today),
    'till', (select jsonb_build_object('id', s.id, 'session_no', s.session_no, 'opened_at', s.opened_at, 'opening_float', s.opening_float,
               'opened_by', (select full_name from public.profiles where id = s.opened_by),
               'cash_expected', s.opening_float + coalesce((select sum(cash_in - cash_out) from public.pos_sales ps where ps.session_id = s.id), 0),
               'sales', (select count(*) from public.pos_sales ps where ps.session_id = s.id))
               from public.pos_sessions s where s.location_id = w.location_id and s.status = 'open'),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'request_no', r.request_no, 'status', r.status,
                   'requested_at', r.requested_at, 'items', (select coalesce(jsonb_agg(jsonb_build_object('product', p.name,
                     'requested', i.requested_qty, 'approved', i.approved_qty, 'dispatched', i.dispatched_qty, 'received', i.received_qty)), '[]')
                     from public.shop_stock_request_items i join public.products p on p.id = i.product_id where i.request_id = r.id))
                   order by r.requested_at desc), '[]')
                   from (select * from public.shop_stock_requests where shop_id = w.id order by requested_at desc limit 10) r),
    'sessions', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'session_no', s.session_no, 'status', s.status,
                   'opened_at', s.opened_at, 'closed_at', s.closed_at, 'cash_expected', s.cash_expected, 'cash_counted', s.cash_counted,
                   'exceptions', s.exceptions, 'settled', s.settlement_id is not null) order by s.opened_at desc), '[]')
                   from (select * from public.pos_sessions where location_id = w.location_id order by opened_at desc limit 10) s),
    'settlements', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'settlement_no', x.settlement_no, 'period_from', x.period_from,
                   'period_to', x.period_to, 'amount_received', x.amount_received, 'cash_expected', x.cash_expected, 'commission', x.commission,
                   'created_at', x.created_at) order by x.created_at desc), '[]')
                   from (select * from public.shop_settlements where shop_id = w.id order by created_at desc limit 10) x),
    'exceptions', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'type', e.exception_type, 'severity', e.severity,
                   'description', e.description, 'created_at', e.created_at) order by e.created_at desc), '[]')
                   from public.operation_exceptions e where e.status = 'open' and (e.location_id = w.location_id or e.target_location_id = w.location_id)),
    'recent_sales', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'receipt_no', s.receipt_no, 'sold_at', s.sold_at, 'total', s.total,
                   'customer', (select name from public.customers where id = s.customer_id), 'walk_in', s.is_walk_in) order by s.sold_at desc), '[]')
                   from (select * from public.pos_sales where location_id = w.location_id order by sold_at desc limit 10) s),
    'unsettled_cash', coalesce((select sum(cash_counted - opening_float) from public.pos_sessions
                                 where location_id = w.location_id and status = 'closed' and settlement_id is null), 0)
  ) into v;
  return v;
end $$;

-- Printable statement for any period (daily / weekly / monthly)
create or replace function public.shop_statement(p_shop uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare w public.water_shops; v jsonb;
begin
  select * into w from public.water_shops where id = p_shop;
  if not found then raise exception 'Shop not found' using errcode = 'P0002'; end if;
  if not app.can_see_shop(w.location_id) then raise exception 'Permission denied' using errcode = '42501'; end if;
  select jsonb_build_object(
    'shop', jsonb_build_object('name', w.name, 'code', w.code, 'operating_model', w.operating_model, 'owner_name', w.owner_name,
                               'address', w.address, 'phone', w.phone, 'commission_percent', w.commission_percent),
    'company', jsonb_build_object('name', app.get_setting('company.name') #>> '{}', 'vat_no', app.get_setting('company.vat_registration_no') #>> '{}'),
    'from', p_from, 'to', p_to, 'generated_at', now(),
    'figures', app.shop_figures(w.id, p_from, p_to),
    'days', (select coalesce(jsonb_agg(jsonb_build_object('date', d::date,
               'sales', coalesce((select sum(total) from public.pos_sales s where s.location_id = w.location_id
                                   and (s.sold_at at time zone 'Asia/Colombo')::date = d::date), 0),
               'cash', coalesce((select sum(cash_in - cash_out) from public.pos_sales s where s.location_id = w.location_id
                                  and (s.sold_at at time zone 'Asia/Colombo')::date = d::date), 0),
               'receipts', (select count(*) from public.pos_sales s where s.location_id = w.location_id
                             and (s.sold_at at time zone 'Asia/Colombo')::date = d::date)) order by d), '[]')
             from generate_series(p_from, p_to, interval '1 day') d),
    'invoices', case when w.operating_model = 'dealer' then
        (select coalesce(jsonb_agg(jsonb_build_object('invoice_no', invoice_no, 'date', invoice_date, 'due', due_date, 'total', total,
           'balance', balance) order by invoice_date, invoice_no), '[]')
           from public.invoices where customer_id = w.account_customer_id and status <> 'void' and invoice_date between p_from and p_to)
        else '[]'::jsonb end,
    'payments', case when w.operating_model = 'dealer' then
        (select coalesce(jsonb_agg(jsonb_build_object('payment_no', payment_no, 'date', received_at, 'method', method, 'amount', amount,
           'reference', reference) order by received_at), '[]')
           from public.payments where customer_id = w.account_customer_id and direction = 'in' and status = 'received'
            and (received_at at time zone 'Asia/Colombo')::date between p_from and p_to)
        else '[]'::jsonb end,
    'opening_balance', case when w.operating_model = 'dealer' then
        coalesce((select sum(total) from public.invoices where customer_id = w.account_customer_id and status <> 'void' and invoice_date < p_from), 0)
      - coalesce((select sum(case when direction = 'in' then amount else -amount end) from public.payments where customer_id = w.account_customer_id
                   and status = 'received' and (received_at at time zone 'Asia/Colombo')::date < p_from), 0) end,
    'settlements', (select coalesce(jsonb_agg(jsonb_build_object('settlement_no', settlement_no, 'amount', amount_received, 'commission', commission,
                     'created_at', created_at)), '[]') from public.shop_settlements where shop_id = w.id
                     and (created_at at time zone 'Asia/Colombo')::date between p_from and p_to)
  ) into v;
  return v;
end $$;

-- Receipt for a till sale (shop staff or office)
create or replace function public.get_pos_receipt(p_sale uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare s public.pos_sales; w public.water_shops;
begin
  select * into s from public.pos_sales where id = p_sale;
  if not found then raise exception 'Sale not found' using errcode = 'P0002'; end if;
  if not (app.has_permission('shops.view') or app.has_permission('payments.view') or app.has_permission_at(app.pos_permission(s.location_id), s.location_id)) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  w := app.shop_by_location(s.location_id);
  return s.summary || jsonb_build_object('print_count', s.print_count, 'sale_id', s.id,
    'company', jsonb_build_object(
       'name', case when w.operating_model = 'dealer' then w.name else app.get_setting('company.name') #>> '{}' end,
       'vat_no', case when w.operating_model = 'dealer' then null else app.get_setting('company.vat_registration_no') #>> '{}' end,
       'footer', app.get_setting('receipts.footer_text') #>> '{}'));
end $$;

-- Dashboard: add shop figures; collections are net of refunds
create or replace function public.dashboard_summary()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_today date := app.today(); v_own uuid := app.own_company_id(); v jsonb;
begin
  perform app.require_permission('dashboard.view');
  select jsonb_build_object(
    'today', v_today,
    'sales_today', coalesce((select sum(subtotal_net + tax_total) from public.invoices where invoice_date = v_today and status <> 'void'), 0),
    'invoices_today', (select count(*) from public.invoices where invoice_date = v_today and status <> 'void'),
    'collected_today', coalesce((select sum(case when direction = 'in' then amount else -amount end) from public.payments
                                  where (received_at at time zone 'Asia/Colombo')::date = v_today and status = 'received'), 0),
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
    'customer_outstanding', coalesce((select sum(total) from public.invoices i join public.customers c on c.id = i.customer_id
                                        where i.status <> 'void' and c.customer_type <> 'water_shop'), 0)
                          - coalesce((select sum(case when direction = 'in' then amount else -amount end) from public.payments p
                                        join public.customers c on c.id = p.customer_id where p.status = 'received' and c.customer_type <> 'water_shop'), 0),
    'shop_outstanding', coalesce((select sum(app.customer_outstanding(account_customer_id)) from public.water_shops where operating_model = 'dealer'), 0),
    'shop_sales_today', coalesce((select sum(total) from public.pos_sales s join public.locations l on l.id = s.location_id
                                   where l.location_type = 'water_shop' and (s.sold_at at time zone 'Asia/Colombo')::date = v_today), 0),
    'shops_pending_requests', (select count(*) from public.shop_stock_requests where status in ('submitted','approved')),
    'shops_in_transit', (select count(*) from public.shop_stock_requests where status = 'dispatched'),
    'overdue', coalesce((select sum(balance) from public.invoices where status in ('open','partially_paid') and due_date < v_today), 0),
    'bottles', jsonb_build_object(
      'warehouse_full', coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
                         where b.holder_type = 'location' and l.location_type in ('warehouse','head_office') and b.company_id = v_own and b.fill_state = 'full'), 0),
      'warehouse_empty', coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
                         where b.holder_type = 'location' and l.location_type in ('warehouse','head_office') and b.company_id = v_own and b.fill_state = 'empty'), 0),
      'on_vehicles', coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
                         where b.holder_type = 'location' and l.location_type = 'vehicle' and b.company_id = v_own), 0),
      'at_shops', coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
                         where b.holder_type = 'location' and l.location_type = 'water_shop' and b.company_id = v_own), 0),
      'with_customers', coalesce((select sum(qty) from public.bottle_balances where holder_type = 'customer' and company_id = v_own), 0),
      'external_held', coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
                         where b.holder_type = 'location' and l.location_type = 'external_holding' and b.company_id <> v_own), 0),
      'external_on_vehicles', coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
                         where b.holder_type = 'location' and l.location_type in ('vehicle','water_shop') and b.company_id <> v_own), 0)),
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

-- Walk-in pooled accounts stay out of the customer list
create or replace function public.customer_list(
  p_search text, p_type text, p_route uuid, p_status text, p_limit integer, p_offset integer)
returns table (id uuid, customer_no text, name text, company_name text, customer_type text, phone text, route text,
               status text, bottle_model text, ola_bottles integer, outstanding numeric, total_count bigint)
language sql stable security definer set search_path = '' as $$
  with f as (
    select c.* from public.customers c
     where app.has_permission('customers.view') and not c.is_walk_in
       and (p_search is null or p_search = '' or c.name ilike '%' || p_search || '%' or c.company_name ilike '%' || p_search || '%'
            or c.customer_no ilike '%' || p_search || '%'
            or (length(regexp_replace(p_search, '[^0-9]', '', 'g')) >= 4
                and c.phone like '%' || regexp_replace(regexp_replace(p_search, '[^0-9]', '', 'g'), '^0', '') || '%'))
       and (p_type is null or p_type = '' or c.customer_type = p_type)
       and (p_route is null or c.route_id = p_route)
       and (p_status is null or p_status = '' or c.status = p_status))
  select f.id, f.customer_no, f.name, f.company_name, f.customer_type, f.phone, r.name, f.status, f.bottle_model,
         app.customer_ola_bottles(f.id), app.customer_outstanding(f.id), count(*) over ()
    from f left join public.routes r on r.id = f.route_id
   order by f.name
   limit least(coalesce(p_limit, 50), 200) offset coalesce(p_offset, 0)
$$;

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
