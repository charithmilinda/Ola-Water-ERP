-- =====================================================================
-- OLA Water ERP — Phase 3B
-- 0045: read models — sales team, rep's day, distributors, CRM,
--       campaigns and promotions; extra alerts
-- =====================================================================

create or replace function public.sales_team_overview(p_year integer, p_month integer)
returns table (id uuid, code text, full_name text, profile_id uuid, employee_id uuid, territory text, territory_id uuid, plan text, plan_id uuid,
               phone text, is_active boolean, sales_target numeric, collection_target numeric, new_customers_target integer, visits_target integer,
               sales_net numeric, collections numeric, new_customers integer, visits integer, achievement_pct numeric, cash_with_rep numeric,
               customers integer, open_leads integer)
language sql stable security definer set search_path = '' as $$
  select r.id, r.code, p.full_name, r.profile_id, r.employee_id, t.name, r.territory_id, cp.name, r.commission_plan_id, r.phone, r.is_active,
         coalesce(st.sales_target, 0), coalesce(st.collection_target, 0), coalesce(st.new_customers, 0), coalesce(st.visits, 0),
         (f ->> 'sales_net')::numeric, (f ->> 'collections')::numeric, (f ->> 'new_customers')::integer, (f ->> 'visits')::integer,
         case when coalesce(st.sales_target, 0) > 0 then round((f ->> 'sales_net')::numeric / st.sales_target * 100, 1) end,
         (f ->> 'cash_with_rep')::numeric,
         (select count(*)::integer from public.customers c where c.sales_rep_id = r.profile_id and c.status = 'active'),
         (select count(*)::integer from public.leads l where l.owner_id = r.profile_id and l.status not in ('won','lost'))
    from public.sales_reps r join public.profiles p on p.id = r.profile_id
    left join public.territories t on t.id = r.territory_id
    left join public.commission_plans cp on cp.id = r.commission_plan_id
    left join public.sales_targets st on st.rep_id = r.id and st.target_year = p_year and st.target_month = p_month
    cross join lateral app.rep_month_figures(r.id, p_year, p_month) f
   where app.has_permission('sales_reps.manage') or r.profile_id = app.current_user_id()
   order by r.is_active desc, p.full_name
$$;

create or replace function public.rep_details(p_rep uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.sales_reps; v_hist jsonb := '[]'; d date; f jsonb; t public.sales_targets;
begin
  select * into r from public.sales_reps where id = p_rep;
  if not found then return null; end if;
  if not (app.has_permission('sales_reps.manage') or r.profile_id = app.current_user_id()) then return null; end if;
  for i in 0..5 loop
    d := (date_trunc('month', app.today()) - make_interval(months => i))::date;
    f := app.rep_month_figures(r.id, extract(year from d)::int, extract(month from d)::int);
    select * into t from public.sales_targets where rep_id = r.id and target_year = extract(year from d)::int and target_month = extract(month from d)::int;
    v_hist := v_hist || jsonb_build_object('year', extract(year from d)::int, 'month', extract(month from d)::int,
      'sales_net', f -> 'sales_net', 'collections', f -> 'collections', 'new_customers', f -> 'new_customers', 'visits', f -> 'visits',
      'sales_target', coalesce(t.sales_target, 0), 'collection_target', coalesce(t.collection_target, 0),
      'new_customers_target', coalesce(t.new_customers, 0), 'visits_target', coalesce(t.visits, 0));
  end loop;
  return jsonb_build_object(
    'rep', (select to_jsonb(x) from (select r.*, p.full_name, p.email, t2.name territory, cp.name plan_name, e.emp_no, e.full_name employee_name
                                      from public.profiles p left join public.territories t2 on t2.id = r.territory_id
                                      left join public.commission_plans cp on cp.id = r.commission_plan_id
                                      left join public.employees e on e.id = r.employee_id where p.id = r.profile_id) x),
    'history', v_hist,
    'cash_with_rep', (app.rep_month_figures(r.id, extract(year from app.today())::int, extract(month from app.today())::int) ->> 'cash_with_rep')::numeric,
    'customers', (select coalesce(jsonb_agg(x order by x.sales_90d desc nulls last), '[]') from (
        select c.id, c.name, c.customer_no, c.customer_type, app.customer_outstanding(c.id) outstanding,
               (select sum(subtotal_net) from public.invoices i where i.customer_id = c.id and i.status <> 'void' and i.invoice_date >= app.today() - 90) sales_90d,
               (select max(checkin_at) from public.rep_visits v where v.customer_id = c.id and v.rep_id = r.id) last_visit
          from public.customers c where c.sales_rep_id = r.profile_id and c.status = 'active' limit 200) x),
    'visits', (select coalesce(jsonb_agg(x order by x.checkin_at desc), '[]') from (
        select v.id, v.checkin_at, v.checkout_at, v.purpose, v.outcome, v.notes, v.distance_m, v.next_action_on,
               coalesce(c.name, l.name) who, v.customer_id, v.lead_id, o.order_no, pay.payment_no, pay.amount payment_amount
          from public.rep_visits v left join public.customers c on c.id = v.customer_id left join public.leads l on l.id = v.lead_id
          left join public.orders o on o.id = v.order_id left join public.payments pay on pay.id = v.payment_id
         where v.rep_id = r.id order by v.checkin_at desc limit 50) x),
    'collections', (select coalesce(jsonb_agg(x order by x.received_at desc), '[]') from (
        select pay.id, pay.payment_no, pay.received_at, pay.method, pay.amount, c.name customer
          from public.payments pay join public.customers c on c.id = pay.customer_id where pay.rep_id = r.id order by pay.received_at desc limit 30) x),
    'handovers', (select coalesce(jsonb_agg(x order by x.created_at desc), '[]') from (
        select h.handover_no, h.created_at, h.amount, m.name account, h.reference from public.rep_cash_handovers h
          join public.money_accounts m on m.id = h.money_account_id where h.rep_id = r.id order by h.created_at desc limit 20) x),
    'commissions', (select coalesce(jsonb_agg(to_jsonb(s) order by s.period_year desc, s.period_month desc), '[]')
                      from public.commission_statements s where s.rep_id = r.id),
    'leads', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'lead_no', l.lead_no, 'name', l.name, 'status', l.status,
                'next_follow_up', l.next_follow_up) order by l.next_follow_up nulls last), '[]')
                from public.leads l where l.owner_id = r.profile_id and l.status not in ('won','lost')));
end $$;

-- Everything a rep needs on the road today
create or replace function public.my_sales_day()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.sales_reps; f jsonb; t public.sales_targets; v_y integer := extract(year from app.today())::int; v_m integer := extract(month from app.today())::int;
begin
  r := app.my_rep();
  if r.id is null then return null; end if;
  f := app.rep_month_figures(r.id, v_y, v_m);
  select * into t from public.sales_targets where rep_id = r.id and target_year = v_y and target_month = v_m;
  return jsonb_build_object(
    'rep', jsonb_build_object('id', r.id, 'code', r.code, 'territory', (select name from public.territories where id = r.territory_id)),
    'month', f || jsonb_build_object('sales_target', coalesce(t.sales_target, 0), 'collection_target', coalesce(t.collection_target, 0),
                                     'new_customers_target', coalesce(t.new_customers, 0), 'visits_target', coalesce(t.visits, 0)),
    'open_visit', (select to_jsonb(x) from (select v.id, v.checkin_at, v.purpose, v.distance_m, v.customer_id, v.lead_id, coalesce(c.name, l.name) who
                     from public.rep_visits v left join public.customers c on c.id = v.customer_id left join public.leads l on l.id = v.lead_id
                    where v.rep_id = r.id and v.checkout_at is null and v.checkin_at > now() - interval '12 hours'
                    order by v.checkin_at desc limit 1) x),
    'today', (select coalesce(jsonb_agg(x order by x.checkin_at), '[]') from (
        select v.id, v.checkin_at, v.checkout_at, v.purpose, v.outcome, coalesce(c.name, l.name) who, o.order_no, pay.amount payment
          from public.rep_visits v left join public.customers c on c.id = v.customer_id left join public.leads l on l.id = v.lead_id
          left join public.orders o on o.id = v.order_id left join public.payments pay on pay.id = v.payment_id
         where v.rep_id = r.id and (v.checkin_at at time zone 'Asia/Colombo')::date = app.today()) x),
    'customers', (select coalesce(jsonb_agg(x order by x.name), '[]') from (
        select c.id, c.name, c.customer_no, c.phone, app.customer_outstanding(c.id) outstanding,
               (select a.address_line from public.customer_addresses a where a.customer_id = c.id and a.is_active order by a.is_default desc limit 1) address
          from public.customers c where c.sales_rep_id = r.profile_id and c.status <> 'inactive') x),
    'leads', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'lead_no', l.lead_no, 'status', l.status, 'phone', l.phone,
                'city', l.city, 'next_follow_up', l.next_follow_up) order by l.next_follow_up nulls last), '[]')
                from public.leads l where l.owner_id = r.profile_id and l.status not in ('won','lost')),
    'follow_ups', (select coalesce(jsonb_agg(x order by x.due_on), '[]') from (
        select a.id, a.subject, a.kind, a.due_on, coalesce(l.name, c.name) who, a.lead_id, a.customer_id
          from public.crm_activities a left join public.leads l on l.id = a.lead_id left join public.customers c on c.id = a.customer_id
         where a.owner_id = r.profile_id and a.done_at is null and a.due_on <= app.today() + 1) x),
    'cash_with_me', (f ->> 'cash_with_rep')::numeric,
    'can_collect', app.has_permission('payments.collect'));
end $$;

-- ---------------------------------------------------------------------
-- Distributors
-- ---------------------------------------------------------------------
create or replace function public.distributor_overview()
returns table (id uuid, code text, kind text, customer_id uuid, name text, customer_no text, territory text, status text, manager text,
               monthly_target numeric, sales_month numeric, sales_last_month numeric, outstanding numeric, overdue numeric, credit_limit numeric,
               ola_bottles integer, last_stock_report date, agreement_end date)
language sql stable security definer set search_path = '' as $$
  select d.id, d.code, d.kind, c.id, c.name, c.customer_no, t.name, d.status, p.full_name, d.monthly_target,
         coalesce((select sum(i.subtotal_net) from public.invoices i where i.customer_id = c.id and i.status <> 'void'
                     and i.invoice_date >= date_trunc('month', app.today())::date), 0),
         coalesce((select sum(i.subtotal_net) from public.invoices i where i.customer_id = c.id and i.status <> 'void'
                     and i.invoice_date >= (date_trunc('month', app.today()) - interval '1 month')::date
                     and i.invoice_date < date_trunc('month', app.today())::date), 0),
         app.customer_outstanding(c.id),
         coalesce((select sum(i.balance) from public.invoices i where i.customer_id = c.id and i.status in ('open','partially_paid') and i.due_date < app.today()), 0),
         c.credit_limit, app.customer_ola_bottles(c.id)::integer,
         (select max(report_date) from public.distributor_stock_reports r where r.distributor_id = d.id), d.agreement_end
    from public.distributors d join public.customers c on c.id = d.customer_id
    left join public.territories t on t.id = d.territory_id left join public.profiles p on p.id = d.manager_id
   where app.has_permission('distributors.manage') or app.has_permission('customers.view')
   order by d.status, c.name
$$;

create or replace function public.distributor_details(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare d public.distributors; c public.customers; v_hist jsonb := '[]'; m date; lr public.distributor_stock_reports;
begin
  if not (app.has_permission('distributors.manage') or app.has_permission('customers.view')) then return null; end if;
  select * into d from public.distributors where id = p_id;
  if not found then return null; end if;
  select * into c from public.customers where id = d.customer_id;
  for i in 0..11 loop
    m := (date_trunc('month', app.today()) - make_interval(months => i))::date;
    v_hist := v_hist || jsonb_build_object('month', m,
      'sales', coalesce((select sum(subtotal_net) from public.invoices where customer_id = c.id and status <> 'void'
                           and invoice_date >= m and invoice_date < (m + interval '1 month')::date), 0),
      'qty_19l', coalesce((select sum(l.qty) from public.invoice_lines l join public.invoices i on i.id = l.invoice_id join public.products pr on pr.id = l.product_id
                            where i.customer_id = c.id and i.status <> 'void' and l.line_type = 'product' and pr.sku = 'OLA-19L'
                              and i.invoice_date >= m and i.invoice_date < (m + interval '1 month')::date), 0),
      'collections', coalesce((select sum(amount) from public.payments where customer_id = c.id and status = 'received' and coalesce(direction, 'in') = 'in'
                                 and (received_at at time zone 'Asia/Colombo')::date >= m
                                 and (received_at at time zone 'Asia/Colombo')::date < (m + interval '1 month')::date), 0));
  end loop;
  select * into lr from public.distributor_stock_reports where distributor_id = d.id order by report_date desc limit 1;
  return jsonb_build_object(
    'distributor', to_jsonb(d) || jsonb_build_object('territory', (select name from public.territories where id = d.territory_id),
                                                     'manager', (select full_name from public.profiles where id = d.manager_id)),
    'customer', jsonb_build_object('id', c.id, 'name', c.name, 'customer_no', c.customer_no, 'phone', c.phone, 'credit_limit', c.credit_limit,
                  'payment_terms_days', c.payment_terms_days, 'price_list', (select name from public.price_lists where id = c.price_list_id),
                  'outstanding', app.customer_outstanding(c.id), 'ola_bottles', app.customer_ola_bottles(c.id),
                  'overdue', coalesce((select sum(balance) from public.invoices where customer_id = c.id and status in ('open','partially_paid') and due_date < app.today()), 0)),
    'history', v_hist,
    'stock', case when lr.id is null then null else jsonb_build_object('report_date', lr.report_date, 'empty_bottles', lr.empty_bottles,
       'lines', (select coalesce(jsonb_agg(jsonb_build_object('product_id', pr.id, 'product', pr.name, 'reported', (x ->> 'qty')::numeric,
                   'delivered_since', coalesce((select sum(l.qty) from public.invoice_lines l join public.invoices i on i.id = l.invoice_id
                                                  where i.customer_id = c.id and i.status <> 'void' and l.product_id = pr.id and i.invoice_date > lr.report_date), 0))), '[]')
                   from jsonb_array_elements(lr.lines) x join public.products pr on pr.id = (x ->> 'product_id')::uuid)) end,
    'reports', (select coalesce(jsonb_agg(jsonb_build_object('report_date', r.report_date, 'empty_bottles', r.empty_bottles, 'notes', r.notes,
                   'total', (select sum((x ->> 'qty')::numeric) from jsonb_array_elements(r.lines) x)) order by r.report_date desc), '[]')
                 from (select * from public.distributor_stock_reports where distributor_id = d.id order by report_date desc limit 12) r),
    'orders', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'order_no', o.order_no, 'status', o.status, 'requested_date', o.requested_date,
                  'total', o.total) order by o.created_at desc), '[]')
                 from (select * from public.orders where customer_id = c.id order by created_at desc limit 10) o));
end $$;

-- ---------------------------------------------------------------------
-- CRM
-- ---------------------------------------------------------------------
create or replace function public.crm_overview()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not (app.has_permission('crm.manage') or app.has_permission('sales_reps.manage')) then null else jsonb_build_object(
    'pipeline', (select coalesce(jsonb_object_agg(status, jsonb_build_object('count', cnt, 'value', val)), '{}') from (
        select status, count(*) cnt, coalesce(sum(est_monthly_value), 0) val from public.leads group by status) x),
    'opportunities', (select coalesce(jsonb_object_agg(stage, jsonb_build_object('count', cnt, 'value', val, 'weighted', w)), '{}') from (
        select stage, count(*) cnt, sum(monthly_value) val, round(sum(monthly_value * probability / 100.0), 2) w from public.opportunities group by stage) x),
    'follow_ups_due', (select count(*) from public.crm_activities where done_at is null and due_on <= app.today()),
    'my_follow_ups', (select count(*) from public.crm_activities where done_at is null and due_on <= app.today() and owner_id = app.current_user_id())
                      + (select count(*) from public.leads where owner_id = app.current_user_id() and status not in ('won','lost') and next_follow_up <= app.today()),
    'conversion_90d', (select jsonb_build_object('leads', count(*), 'won', count(*) filter (where status = 'won'),
                         'lost', count(*) filter (where status = 'lost'),
                         'rate', round(100.0 * count(*) filter (where status = 'won') / nullif(count(*) filter (where status in ('won','lost')), 0), 0))
                         from public.leads where created_at >= now() - interval '90 days'),
    'by_source', (select coalesce(jsonb_agg(jsonb_build_object('source', source, 'leads', cnt, 'won', won) order by cnt desc), '[]') from (
        select source, count(*) cnt, count(*) filter (where status = 'won') won from public.leads
         where created_at >= now() - interval '180 days' group by source) x)) end
$$;

create or replace function public.lead_details(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare l public.leads;
begin
  select * into l from public.leads where id = p_id;
  if not found or not (app.has_permission('crm.manage') or app.has_permission('sales_reps.manage') or l.owner_id = app.current_user_id()) then
    return null;
  end if;
  return jsonb_build_object(
    'lead', to_jsonb(l) || jsonb_build_object('owner', (select full_name from public.profiles where id = l.owner_id),
              'campaign', (select name from public.campaigns where id = l.campaign_id), 'territory', (select name from public.territories where id = l.territory_id),
              'customer_name', (select name from public.customers where id = l.customer_id)),
    'activities', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'kind', a.kind, 'subject', a.subject, 'notes', a.notes, 'due_on', a.due_on,
                     'done_at', a.done_at, 'outcome', a.outcome, 'owner', p.full_name, 'created_at', a.created_at) order by coalesce(a.done_at, a.created_at) desc), '[]')
                     from public.crm_activities a left join public.profiles p on p.id = a.owner_id where a.lead_id = l.id),
    'opportunities', (select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc), '[]') from public.opportunities o where o.lead_id = l.id),
    'visits', (select coalesce(jsonb_agg(jsonb_build_object('checkin_at', v.checkin_at, 'outcome', v.outcome, 'notes', v.notes, 'rep', r.code) order by v.checkin_at desc), '[]')
                 from public.rep_visits v join public.sales_reps r on r.id = v.rep_id where v.lead_id = l.id));
end $$;

create or replace function public.campaign_performance()
returns table (id uuid, code text, name text, channel text, status text, start_date date, end_date date, budget numeric, spent numeric,
               segment text, segment_size integer, promotion text, leads integer, won integer, new_customers integer, revenue numeric,
               messages_sent integer, messages_failed integer, promo_discount numeric, cost_per_customer numeric)
language sql stable security definer set search_path = '' as $$
  select c.id, c.code, c.name, c.channel, c.status, c.start_date, c.end_date, c.budget, c.spent, s.name,
         case when s.id is not null then (select count(*)::integer from app.segment_customer_ids(s.rules)) end,
         pr.name,
         (select count(*)::integer from public.leads l where l.campaign_id = c.id),
         (select count(*)::integer from public.leads l where l.campaign_id = c.id and l.status = 'won'),
         (select count(*)::integer from public.customers cu where cu.campaign_id = c.id),
         coalesce((select sum(i.subtotal_net) from public.invoices i join public.customers cu on cu.id = i.customer_id
                    where cu.campaign_id = c.id and i.status <> 'void' and i.invoice_date >= c.start_date), 0),
         (select count(*)::integer from public.message_outbox m where m.related_type = 'campaign' and m.related_id = c.id and m.status = 'sent'),
         (select count(*)::integer from public.message_outbox m where m.related_type = 'campaign' and m.related_id = c.id and m.status = 'failed'),
         coalesce((select sum(oi.promo_discount) from public.order_items oi join public.orders o on o.id = oi.order_id
                    where c.promotion_id is not null and oi.promotion_id = c.promotion_id and o.status not in ('cancelled','draft')), 0),
         case when (select count(*) from public.customers cu where cu.campaign_id = c.id) > 0
              then round(c.spent / (select count(*) from public.customers cu where cu.campaign_id = c.id), 2) end
    from public.campaigns c left join public.customer_segments s on s.id = c.segment_id left join public.promotions pr on pr.id = c.promotion_id
   where app.has_permission('crm.manage')
   order by c.start_date desc
$$;

create or replace function public.promotion_performance()
returns table (id uuid, code text, name text, kind text, value numeric, status text, start_date date, end_date date, product text,
               orders integer, qty numeric, discount_given numeric, sales_net numeric)
language sql stable security definer set search_path = '' as $$
  select p.id, p.code, p.name, p.kind, p.value, p.status, p.start_date, p.end_date, pr.name,
         (select count(distinct oi.order_id)::integer from public.order_items oi join public.orders o on o.id = oi.order_id
           where oi.promotion_id = p.id and o.status not in ('cancelled','draft')),
         coalesce((select sum(oi.qty) from public.order_items oi join public.orders o on o.id = oi.order_id
           where oi.promotion_id = p.id and o.status not in ('cancelled','draft')), 0),
         coalesce((select sum(oi.promo_discount) from public.order_items oi join public.orders o on o.id = oi.order_id
           where oi.promotion_id = p.id and o.status not in ('cancelled','draft')), 0),
         coalesce((select sum(oi.line_net) from public.order_items oi join public.orders o on o.id = oi.order_id
           where oi.promotion_id = p.id and o.status not in ('cancelled','draft')), 0)
    from public.promotions p left join public.products pr on pr.id = p.product_id
   where app.has_permission('crm.manage') or app.has_permission('prices.approve')
   order by p.start_date desc
$$;

-- Promotions a customer would get today (shown on the order screen)
create or replace function public.active_promotions_for(p_customer uuid)
returns table (id uuid, code text, name text, kind text, value numeric, buy_qty integer, product_id uuid, min_qty numeric, end_date date)
language sql stable security definer set search_path = '' as $$
  select p.id, p.code, p.name, p.kind, p.value, p.buy_qty, p.product_id, p.min_qty, p.end_date
    from public.promotions p, public.customers c
   where c.id = p_customer and p.status = 'active' and app.today() between p.start_date and p.end_date
     and (p.price_list_id is null or p.price_list_id = c.price_list_id)
     and (p.customer_types is null or cardinality(p.customer_types) = 0 or c.customer_type = any(p.customer_types))
     and (p.segment_id is null or app.segment_has(p.segment_id, c.id))
     and (app.has_permission('orders.view') or app.has_permission('crm.manage'))
$$;

-- Extra alerts, called by refresh_notifications
create or replace function app.refresh_notifications_sales()
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer := 0; x record; v_day text := to_char(app.today(), 'YYYY-MM-DD');
        v_prev date := (date_trunc('month', app.today()) - interval '1 month')::date;
begin
  -- follow-ups due for each owner (once a day)
  for x in select owner_id, count(*) cnt from (
             select owner_id from public.crm_activities where done_at is null and due_on <= app.today() and owner_id is not null
             union all
             select owner_id from public.leads where status not in ('won','lost') and next_follow_up <= app.today() and owner_id is not null) f
            group by owner_id loop
    n := n + app.notify('follow_ups_due', x.cnt || ' follow-up(s) due today', null, '/crm', 'followups:' || x.owner_id || ':' || v_day, x.owner_id);
  end loop;
  -- cash held by reps for more than a day
  for x in select r.id, r.code, sum(l.debit - l.credit) held, min(e.entry_date) since
             from public.journal_lines l join public.accounts a on a.id = l.account_id and a.system_key = 'rep_cash'
             join public.journal_entries e on e.id = l.entry_id join public.sales_reps r on r.id = l.party_id
            where l.party_type = 'sales_rep' group by r.id, r.code having sum(l.debit - l.credit) > 0 loop
    if x.since < app.today() then
      n := n + app.notify('rep_cash', 'Rep ' || x.code || ' holds Rs. ' || to_char(x.held, 'FM999,999,990.00'), 'Collected cash not handed in yet',
                          '/sales/reps/' || x.id, 'repcash:' || x.id || ':' || v_day);
    end if;
  end loop;
  -- last month's commissions not prepared / approved (from the 3rd of the month)
  if extract(day from app.today()) >= 3 and exists (
       select 1 from public.sales_reps r where r.is_active and r.commission_plan_id is not null
          and not exists (select 1 from public.commission_statements s where s.rep_id = r.id and s.status in ('approved','paid')
                           and s.period_year = extract(year from v_prev)::int and s.period_month = extract(month from v_prev)::int)) then
    n := n + app.notify('commissions_due', 'Sales commissions for ' || to_char(v_prev, 'FMMonth') || ' are not approved yet', null,
                        '/sales/commissions', 'commissions:' || v_prev);
  end if;
  -- distributor agreements ending within 30 days
  for x in select d.id, d.code, d.agreement_end, c.name from public.distributors d join public.customers c on c.id = d.customer_id
            where d.status = 'active' and d.agreement_end between app.today() and app.today() + 30 loop
    n := n + app.notify('distributor_agreement', 'Agreement with ' || x.name || ' ends ' || to_char(x.agreement_end, 'DD Mon'), null,
                        '/distributors/' || x.id, 'dist-agr:' || x.id || ':' || x.agreement_end);
  end loop;
  return n;
end $$;

-- Staff names are also needed to give leads and distributors an owner
create or replace function public.staff_directory()
returns table (id uuid, full_name text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.full_name from public.profiles p
   where p.is_active and app.current_user_id() is not null
     and (app.has_permission('complaints.manage') or app.has_permission('complaints.view') or app.has_permission('users.manage')
          or app.has_permission('sales_reps.manage') or app.has_permission('crm.manage') or app.has_permission('distributors.manage'))
   order by p.full_name
$$;

-- refresh_notifications now also runs the sales alerts ([3B] marks the change)
create or replace function public.refresh_notifications(p_force boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare st public.notification_scan_state; n integer := 0; v_day text := to_char(app.today(), 'YYYY-MM-DD'); x record;
        v_minutes integer := coalesce((app.get_setting('notifications.scan_minutes') #>> '{}')::integer, 10);
        v_after integer := coalesce((app.get_setting('messaging.reminder_after_days') #>> '{}')::integer, 7);
        v_repeat integer := coalesce((app.get_setting('messaging.reminder_repeat_days') #>> '{}')::integer, 7);
        v_reminders integer := 0;
begin
  if app.current_user_id() is null and not app.can_dispatch() then raise exception 'Not signed in' using errcode = '42501'; end if;
  if p_force and not (app.has_permission('settings.manage') or app.can_dispatch()) then p_force := false; end if;
  select * into st from public.notification_scan_state where id = 1 for update skip locked;
  if not found then return jsonb_build_object('ran', false); end if;
  if not p_force and st.last_run_at > now() - make_interval(mins => v_minutes) then
    return jsonb_build_object('ran', false, 'last_run_at', st.last_run_at);
  end if;
  update public.notification_scan_state set last_run_at = now() where id = 1;

  -- low stock (one alert per item per day)
  for x in select p.id, p.name, p.reorder_level, coalesce(sum(b.qty), 0) qty
             from public.products p left join public.inventory_balances b on b.product_id = p.id and b.stock_status = 'available'
            where p.is_active and p.reorder_level > 0 group by p.id having coalesce(sum(b.qty), 0) <= p.reorder_level loop
    n := n + app.notify('low_stock', 'Low stock: ' || x.name, format('%s left (reorder level %s)', x.qty, x.reorder_level), '/inventory',
                        'low-stock:' || x.id || ':' || v_day);
  end loop;

  -- vehicles
  for x in select f.id, f.registration_no, f.alerts from public.fleet_overview() f where f.is_active and cardinality(f.alerts) > 0 loop
    n := n + app.notify('vehicle_alert', x.registration_no || ': ' || array_to_string(x.alerts, ', '), null, '/fleet/' || x.id,
                        'vehicle:' || x.id || ':' || md5(array_to_string(x.alerts, ',')) || ':' || v_day);
  end loop;

  -- documents expiring (the people who manage that kind of document are told)
  for x in select d.id, d.doc_no, d.title, d.expires_on, c.manage_permission
             from public.documents d join public.document_categories c on c.code = d.category_code
            where d.status = 'active' and d.expires_on is not null and d.expires_on <= app.today() + d.alert_days loop
    n := n + app.notify('document_expiry',
      case when x.expires_on < app.today() then 'Expired: ' else 'Expiring ' || to_char(x.expires_on, 'DD Mon') || ': ' end || x.title,
      x.doc_no, '/documents?show=expiring', 'doc-expiry:' || x.id || ':' || (x.expires_on < app.today()), null,
      case when x.expires_on < app.today() then 'critical' end, x.manage_permission);
  end loop;

  -- external bottles above the alert level (once a day)
  for x in select c.name, h.qty, h.alert from (
             select b.company_id, sum(b.qty) qty,
                    coalesce(bc.holding_alert_qty, (app.get_setting('bottles.external_holding_alert_qty') #>> '{}')::integer) alert
               from public.bottle_balances b join public.locations l on l.id = b.holder_id
               join public.bottle_companies bc on bc.id = b.company_id
              where b.holder_type = 'location' and l.location_type = 'external_holding' and not bc.is_own
              group by b.company_id, bc.holding_alert_qty) h join public.bottle_companies c on c.id = h.company_id
            where h.qty > h.alert loop
    n := n + app.notify('external_bottles', x.name || ': ' || x.qty || ' bottles held', 'Alert level ' || x.alert || ' — arrange a hand-over',
                        '/bottles/external', 'ext:' || x.name || ':' || v_day);
  end loop;

  -- failed deliveries today
  select count(*) cnt into x from public.deliveries d join public.route_runs r on r.id = d.run_id
   where d.status = 'failed' and r.run_date = app.today();
  if x.cnt > 0 then
    n := n + app.notify('failed_delivery', x.cnt || ' failed delivery(ies) today', null, '/dispatch', 'failed:' || v_day || ':' || x.cnt);
  end if;

  -- complaints past their due time
  for x in select id, complaint_no, subject, assigned_to from public.complaints
            where status not in ('resolved','closed') and due_at < now() loop
    n := n + app.notify('complaint_overdue', 'Overdue complaint ' || x.complaint_no, x.subject, '/complaints/' || x.id, 'cmp-overdue:' || x.id);
    if x.assigned_to is not null then
      n := n + app.notify('complaint_overdue', 'Overdue complaint ' || x.complaint_no, x.subject, '/complaints/' || x.id,
                          'cmp-overdue-me:' || x.id, x.assigned_to);
    end if;
  end loop;

  -- QC holds
  for x in select b.id, b.batch_no, p.name from public.production_batches b join public.products p on p.id = b.product_id
            where b.status = 'qc_hold' loop
    n := n + app.notify('qc_hold', 'Batch ' || x.batch_no || ' waiting for QC release', x.name, '/production/' || x.id, 'qc-hold:' || x.id);
  end loop;

  -- items waiting for approval in modules (one reminder a day per kind)
  for x in select * from (values
      ('expenses.approve', (select count(*) from public.expenses where status = 'pending_approval'), 'expense(s)', '/expenses?show=pending_approval'),
      ('procurement.approve', (select count(*) from public.purchase_orders where status = 'pending_approval')
                              + (select count(*) from public.purchase_requests where status = 'submitted'), 'purchase(s)', '/purchasing'),
      ('accounting.manual_journal', (select count(*) from public.journal_drafts where status = 'pending'), 'manual journal(s)', '/accounting/journals'),
      ('payroll.approve', (select count(*) from public.payroll_runs where status = 'draft'), 'payroll run(s)', '/payroll'),
      ('hr.manage', (select count(*) from public.leave_requests where status = 'pending'), 'leave request(s)', '/hr/attendance'),
      ('shops.stock_approve', (select count(*) from public.shop_stock_requests where status = 'submitted'), 'shop stock request(s)', '/shops/requests'),
      ('customers.credit', (select count(*) from public.orders where status = 'on_hold'), 'order(s) on credit hold', '/orders?status=on_hold')
    ) as t(perm, cnt, what, href) where t.cnt > 0 loop
    n := n + app.notify('pending_approvals', x.cnt || ' ' || x.what || ' waiting for approval', null, x.href,
                        'pending:' || x.perm || ':' || v_day, null, null, x.perm);
  end loop;

  -- overdue customer balances: staff summary once a day, customer reminders
  select count(distinct customer_id) cnt, coalesce(sum(balance), 0) amt into x from public.invoices
   where status in ('open','partially_paid') and due_date < app.today() and balance > 0;
  if x.cnt > 0 then
    n := n + app.notify('overdue_invoices', x.cnt || ' customer(s) overdue', 'Rs. ' || to_char(x.amt, 'FM999,999,999,990.00') || ' past due',
                        '/accounting/reports/ar-ageing', 'overdue:' || v_day);
  end if;
  for x in select i.customer_id, sum(i.balance) overdue, min(i.due_date) oldest
             from public.invoices i join public.customers c on c.id = i.customer_id
            where i.status in ('open','partially_paid') and i.balance > 0 and i.due_date <= app.today() - v_after
              and not c.messages_opt_out and not c.is_walk_in
            group by i.customer_id loop
    if not exists (select 1 from public.message_outbox m where m.customer_id = x.customer_id and m.template_code = 'PAYMENT_REMINDER'
                     and m.status <> 'cancelled' and m.created_at > now() - make_interval(days => v_repeat)) then
      if app.queue_customer_message('PAYMENT_REMINDER', x.customer_id,
           jsonb_build_object('overdue', to_char(x.overdue, 'FM999,999,990.00'), 'due_date', to_char(x.oldest, 'DD Mon YYYY')),
           'reminder', null, 'reminder:' || x.customer_id || ':' || v_day) is not null then
        v_reminders := v_reminders + 1;
      end if;
    end if;
  end loop;

  -- messages that failed today
  select count(*) cnt into x from public.message_outbox where status = 'failed' and created_at > now() - interval '1 day';
  if x.cnt > 0 then
    n := n + app.notify('messages_failed', x.cnt || ' message(s) could not be sent', 'Check Messages for the reason', '/messages?show=failed',
                        'msg-failed:' || v_day || ':' || x.cnt);
  end if;

  n := n + app.refresh_notifications_sales();  -- [3B]
  return jsonb_build_object('ran', true, 'created', n, 'reminders', v_reminders);
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
