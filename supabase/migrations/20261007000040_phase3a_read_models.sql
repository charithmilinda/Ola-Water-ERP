-- =====================================================================
-- OLA Water ERP — Phase 3A
-- 0040: approvals inbox, rules overview, alert scan, complaint and
--       document read models, control summary for the dashboard
-- =====================================================================

-- ---------------------------------------------------------------------
-- Approvals inbox: everything the current user can decide, from every module
-- ---------------------------------------------------------------------
create or replace function public.approval_inbox()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_me uuid := app.current_user_id(); v_items jsonb := '[]';
begin
  if v_me is null then raise exception 'Not signed in' using errcode = '42501'; end if;

  -- requests from approval rules
  v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
      'source', 'request', 'id', q.id, 'ref', q.request_no, 'title', q.title, 'detail', q.details, 'amount', q.amount,
      'kind', q.kind, 'kind_name', r.name, 'reason', q.reason, 'requested_by', p.full_name, 'requested_at', q.requested_at,
      'href', q.href, 'level', q.levels_done + 1, 'levels', q.levels_required,
      'approved_by', (select string_agg(pp.full_name, ', ') from public.approval_steps s join public.profiles pp on pp.id = s.approver_id
                       where s.request_id = q.id and s.decision = 'approve')) order by q.requested_at)
    from public.approval_requests q join public.approval_rules r on r.kind = q.kind
    left join public.profiles p on p.id = q.requested_by
   where q.status = 'pending' and q.requested_by <> v_me and app.has_permission(r.approver_permission)
     and not exists (select 1 from public.approval_steps s where s.request_id = q.id and s.approver_id = v_me)), '[]');

  if app.has_permission('expenses.approve') then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'expense', 'id', x.id, 'ref', x.expense_no, 'title', 'Expense — ' || coalesce(c.name, ''), 'detail', x.description,
        'amount', x.total, 'kind_name', 'Expense', 'requested_by', p.full_name, 'requested_at', x.created_at,
        'href', '/expenses?show=pending_approval') order by x.created_at)
      from public.expenses x left join public.expense_categories c on c.id = x.category_id left join public.profiles p on p.id = x.created_by
     where x.status = 'pending_approval' and x.created_by is distinct from v_me), '[]');
  end if;

  if app.has_permission('accounting.manual_journal') then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'journal', 'id', j.id, 'ref', j.draft_no, 'title', 'Manual journal', 'detail', j.description, 'amount', j.total,
        'kind_name', 'Manual journal', 'requested_by', p.full_name, 'requested_at', j.created_at, 'href', '/accounting/journals') order by j.created_at)
      from public.journal_drafts j left join public.profiles p on p.id = j.created_by
     where j.status = 'pending' and (j.created_by is distinct from v_me or app.is_super_admin())), '[]');
  end if;

  if app.has_permission('procurement.approve') then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'purchase_request', 'id', r.id, 'ref', r.request_no, 'title', 'Purchase request — ' || l.name, 'detail', r.notes,
        'kind_name', 'Purchase request', 'requested_by', p.full_name, 'requested_at', r.requested_at, 'href', '/purchasing') order by r.requested_at)
      from public.purchase_requests r join public.locations l on l.id = r.location_id left join public.profiles p on p.id = r.requested_by
     where r.status = 'submitted'), '[]');
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'purchase_order', 'id', o.id, 'ref', o.po_no, 'title', 'Purchase order — ' || s.name, 'amount', o.total,
        'kind_name', 'Purchase order', 'requested_by', p.full_name, 'requested_at', o.created_at, 'href', '/purchasing/' || o.id) order by o.created_at)
      from public.purchase_orders o join public.suppliers s on s.id = o.supplier_id left join public.profiles p on p.id = o.created_by
     where o.status = 'pending_approval' and (o.created_by is distinct from v_me or app.is_super_admin())), '[]');
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'supplier_invoice', 'id', i.id, 'ref', i.ref_no, 'title', 'Supplier invoice on hold — ' || s.name,
        'detail', 'Invoice ' || i.supplier_invoice_no || ' does not match the order / goods received', 'amount', i.total,
        'kind_name', 'Supplier invoice', 'requested_by', p.full_name, 'requested_at', i.created_at, 'href', '/purchasing') order by i.created_at)
      from public.supplier_invoices i join public.suppliers s on s.id = i.supplier_id left join public.profiles p on p.id = i.created_by
     where i.status = 'on_hold'), '[]');
  end if;

  if app.has_permission('payroll.approve') then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'payroll', 'id', r.id, 'ref', r.run_no, 'title', 'Payroll ' || to_char(make_date(r.pay_year, r.pay_month, 1), 'Mon YYYY'),
        'detail', r.employees || ' employee(s)', 'amount', r.net, 'kind_name', 'Payroll', 'requested_by', p.full_name,
        'requested_at', r.prepared_at, 'href', '/payroll/' || r.id) order by r.prepared_at)
      from public.payroll_runs r left join public.profiles p on p.id = r.prepared_by
     where r.status = 'draft' and (r.prepared_by is distinct from v_me or app.is_super_admin())), '[]');
  end if;

  if app.has_permission('hr.manage') then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'leave', 'id', l.id, 'ref', l.request_no, 'title', 'Leave — ' || e.full_name,
        'detail', t.name || ', ' || l.days || ' day(s) from ' || to_char(l.from_date, 'DD Mon'), 'kind_name', 'Leave',
        'requested_by', p.full_name, 'requested_at', l.requested_at, 'href', '/hr/attendance') order by l.from_date)
      from public.leave_requests l join public.employees e on e.id = l.employee_id join public.leave_types t on t.id = l.leave_type_id
      left join public.profiles p on p.id = l.requested_by
     where l.status = 'pending'), '[]');
  end if;

  if app.has_permission('customers.credit') then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'order_hold', 'id', o.id, 'ref', o.order_no, 'title', 'Order on hold — ' || c.name, 'detail', o.hold_reason,
        'amount', o.total, 'kind_name', 'Order on hold', 'requested_by', p.full_name, 'requested_at', o.created_at,
        'href', '/orders/' || o.id) order by o.created_at)
      from public.orders o join public.customers c on c.id = o.customer_id left join public.profiles p on p.id = o.created_by
     where o.status = 'on_hold'), '[]');
  end if;

  if app.has_permission('shops.stock_approve') then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'shop_request', 'id', r.id, 'ref', r.request_no, 'title', 'Shop stock request — ' || s.name,
        'kind_name', 'Shop stock request', 'requested_by', p.full_name, 'requested_at', r.requested_at, 'href', '/shops/requests') order by r.requested_at)
      from public.shop_stock_requests r join public.water_shops s on s.id = r.shop_id left join public.profiles p on p.id = r.requested_by
     where r.status = 'submitted'), '[]');
  end if;

  if app.has_permission('qc.release') then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'qc_hold', 'id', b.id, 'ref', b.batch_no, 'title', 'Batch on QC hold — ' || pr.name,
        'detail', b.planned_qty || ' planned', 'kind_name', 'QC release', 'requested_at', b.created_at,
        'href', '/production/' || b.id) order by b.created_at)
      from public.production_batches b join public.products pr on pr.id = b.product_id
     where b.status = 'qc_hold'), '[]');
  end if;

  return jsonb_build_object(
    'items', v_items,
    'mine', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'ref', q.request_no, 'title', q.title, 'detail', q.details,
               'amount', q.amount, 'status', q.status, 'requested_at', q.requested_at, 'decided_at', q.decided_at,
               'decided_by', p.full_name, 'decision_note', q.decision_note, 'levels', q.levels_required, 'levels_done', q.levels_done,
               'href', q.href) order by q.requested_at desc)
       from (select * from public.approval_requests where requested_by = v_me order by requested_at desc limit 50) q
       left join public.profiles p on p.id = q.decided_by), '[]'));
end $$;

create or replace function public.approval_history(p_from date, p_to date)
returns table (id uuid, request_no text, kind_name text, title text, details text, amount numeric, status text,
               requested_by text, requested_at timestamptz, decided_by text, decided_at timestamptz, decision_note text, steps jsonb)
language sql stable security definer set search_path = '' as $$
  select q.id, q.request_no, r.name, q.title, q.details, q.amount, q.status, rp.full_name, q.requested_at, dp.full_name, q.decided_at,
         q.decision_note,
         (select coalesce(jsonb_agg(jsonb_build_object('level', s.level, 'by', sp.full_name, 'decision', s.decision, 'note', s.note,
                   'at', s.created_at) order by s.created_at), '[]')
            from public.approval_steps s join public.profiles sp on sp.id = s.approver_id where s.request_id = q.id)
    from public.approval_requests q join public.approval_rules r on r.kind = q.kind
    left join public.profiles rp on rp.id = q.requested_by left join public.profiles dp on dp.id = q.decided_by
   where (app.has_permission('approvals.act') or app.has_permission('audit.view') or app.has_permission(r.approver_permission))
     and q.requested_at >= p_from and q.requested_at < p_to + 1
   order by q.requested_at desc
   limit 500
$$;

-- Rules with their limits and who can approve, plus the approvals built into modules.
create or replace function public.approval_rules_overview()
returns jsonb language sql stable security definer set search_path = '' as $$
  with holders as (
    select rp.permission_code, string_agg(distinct r.name, ', ' order by r.name) roles
      from public.role_permissions rp join public.roles r on r.id = rp.role_id and r.archived_at is null
     group by rp.permission_code)
  select jsonb_build_object(
    'rules', (select coalesce(jsonb_agg(jsonb_build_object('kind', a.kind, 'name', a.name, 'description', a.description,
                'approver_permission', a.approver_permission, 'approver_roles', coalesce(h.roles, 'Super Admin only'),
                'levels', a.levels, 'is_active', a.is_active, 'threshold_setting', a.threshold_setting,
                'threshold_label', d.label, 'threshold', app.get_setting(a.threshold_setting),
                'pending', (select count(*) from public.approval_requests q where q.kind = a.kind and q.status = 'pending'))
              order by a.sort_order), '[]')
       from public.approval_rules a left join holders h on h.permission_code = a.approver_permission
       left join public.setting_definitions d on d.key = a.threshold_setting),
    'built_in', (select coalesce(jsonb_agg(jsonb_build_object('name', b.name, 'rule', b.rule, 'permission', b.perm,
                   'approver_roles', coalesce(h.roles, 'Super Admin only'), 'threshold_setting', b.setting,
                   'threshold', case when b.setting is not null then app.get_setting(b.setting) end, 'href', b.href) order by b.ord), '[]')
       from (values
         (1, 'Expenses', 'Above the limit, approved by someone other than the person who entered it', 'expenses.approve', 'approvals.expense_amount', '/expenses'),
         (2, 'Purchases', 'Purchase requests, and purchase orders above the limit', 'procurement.approve', 'approvals.purchase_amount', '/purchasing'),
         (3, 'Supplier invoices that do not match', '3-way match failed — released by an approver', 'procurement.approve', null, '/purchasing'),
         (4, 'Manual journals', 'Prepared by one person, posted by another', 'accounting.manual_journal', null, '/accounting/journals'),
         (5, 'Payroll', 'Prepared by one person, approved by another', 'payroll.approve', null, '/payroll'),
         (6, 'Leave', 'Leave requests', 'hr.manage', null, '/hr/attendance'),
         (7, 'Orders on credit hold', 'Customer over the credit limit or overdue', 'customers.credit', null, '/orders?status=on_hold'),
         (8, 'Shop stock requests', 'Stock asked for by a water shop', 'shops.stock_approve', null, '/shops/requests'),
         (9, 'QC release', 'Batches on QC hold, and releasing a failed batch (override)', 'qc.release', null, '/quality')
       ) as b(ord, name, rule, perm, setting, href)
       left join holders h on h.permission_code = b.perm),
    'permissions', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'label', module || ' — ' || description) order by sort_order), '[]')
                      from public.permissions))
$$;

-- ---------------------------------------------------------------------
-- Alert scan. Cheap to call often: it only runs every
-- notifications.scan_minutes (unless forced by an administrator).
-- ---------------------------------------------------------------------
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

  return jsonb_build_object('ran', true, 'created', n, 'reminders', v_reminders);
end $$;

-- ---------------------------------------------------------------------
-- Complaints
-- ---------------------------------------------------------------------
create or replace function public.complaint_details(p_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not (app.has_permission('complaints.view') or app.has_permission('complaints.manage')
                        or (c.batch_id is not null and app.has_permission('qc.view')) or c.assigned_to = app.current_user_id()) then null
  else jsonb_build_object(
    'complaint', to_jsonb(c) || jsonb_build_object(
        'category', cat.name, 'assigned_name', a.full_name, 'created_by_name', cb.full_name,
        'overdue', c.status not in ('resolved','closed') and c.due_at < now()),
    'customer', (select jsonb_build_object('id', cu.id, 'name', cu.name, 'customer_no', cu.customer_no, 'phone', cu.phone,
                   'outstanding', app.customer_outstanding(cu.id), 'complaints', (select count(*) from public.complaints z where z.customer_id = cu.id))
                   from public.customers cu where cu.id = c.customer_id),
    'links', jsonb_build_object(
        'order', (select jsonb_build_object('id', o.id, 'no', o.order_no) from public.orders o where o.id = c.order_id),
        'delivery', (select jsonb_build_object('id', d.id, 'no', d.delivery_no, 'run_id', d.run_id) from public.deliveries d where d.id = c.delivery_id),
        'invoice', (select jsonb_build_object('id', i.id, 'no', i.invoice_no) from public.invoices i where i.id = c.invoice_id),
        'batch', (select jsonb_build_object('id', b.id, 'no', b.batch_no, 'status', b.status, 'product', p.name)
                    from public.production_batches b join public.products p on p.id = b.product_id where b.id = c.batch_id),
        'bottle', (select jsonb_build_object('id', bt.id, 'code', bt.code) from public.bottles bt where bt.id = c.bottle_id),
        'product', (select jsonb_build_object('id', p.id, 'name', p.name) from public.products p where p.id = c.product_id),
        'driver', (select jsonb_build_object('id', p.id, 'name', p.full_name) from public.profiles p where p.id = c.driver_id),
        'location', (select jsonb_build_object('id', l.id, 'name', l.name) from public.locations l where l.id = c.location_id)),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'event', e.event, 'from_status', e.from_status,
                 'to_status', e.to_status, 'note', e.note, 'photo_path', e.photo_path, 'created_at', e.created_at, 'by', p.full_name)
                 order by e.created_at), '[]')
                 from public.complaint_events e left join public.profiles p on p.id = e.created_by where e.complaint_id = c.id))
  end
  from public.complaints c join public.complaint_categories cat on cat.code = c.category_code
  left join public.profiles a on a.id = c.assigned_to left join public.profiles cb on cb.id = c.created_by
  where c.id = p_id
$$;

create or replace function public.complaints_summary(p_from date, p_to date)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not (app.has_permission('complaints.view') or app.has_permission('complaints.manage')) then null else jsonb_build_object(
    'open', (select count(*) from public.complaints where status not in ('resolved','closed')),
    'overdue', (select count(*) from public.complaints where status not in ('resolved','closed') and due_at < now()),
    'unassigned', (select count(*) from public.complaints where status = 'new'),
    'qc_review', (select count(*) from public.complaints where qc_review_status = 'requested'),
    'logged', (select count(*) from public.complaints where created_at >= p_from and created_at < p_to + 1),
    'resolved', (select count(*) from public.complaints where resolved_at >= p_from and resolved_at < p_to + 1),
    'within_sla_pct', (select round(100.0 * count(*) filter (where resolved_at <= due_at) / nullif(count(*), 0), 0)
                         from public.complaints where resolved_at >= p_from and resolved_at < p_to + 1),
    'avg_hours_to_resolve', (select round(avg(extract(epoch from resolved_at - created_at) / 3600)::numeric, 1)
                               from public.complaints where resolved_at >= p_from and resolved_at < p_to + 1),
    'by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', cat.name, 'count', x.cnt) order by x.cnt desc), '[]')
                      from (select category_code, count(*) cnt from public.complaints
                             where created_at >= p_from and created_at < p_to + 1 group by category_code) x
                      join public.complaint_categories cat on cat.code = x.category_code))
  end
$$;

-- ---------------------------------------------------------------------
-- Documents: what expires soon (library + vehicle documents)
-- ---------------------------------------------------------------------
create or replace function public.expiring_documents(p_days integer default 60)
returns table (source text, id uuid, title text, category text, reference_no text, expires_on date, days_left integer, href text)
language sql stable security definer set search_path = '' as $$
  select 'document', d.id, d.title, c.name, d.reference_no, d.expires_on, (d.expires_on - app.today())::integer,
         '/documents/' || d.id
    from public.documents d join public.document_categories c on c.code = d.category_code
   where d.status = 'active' and d.expires_on is not null and d.expires_on <= app.today() + greatest(coalesce(p_days, 60), d.alert_days)
     and app.has_permission(c.view_permission)
  union all
  select 'vehicle', v.id, v.registration_no || ' — ' || replace(x.doc_type, '_', ' '), 'Vehicle documents', x.doc_no, x.expires_on,
         (x.expires_on - app.today())::integer, '/fleet/' || v.id
    from (select distinct on (vehicle_id, doc_type) * from public.vehicle_documents order by vehicle_id, doc_type, expires_on desc) x
    join public.vehicles v on v.id = x.vehicle_id
   where v.is_active and x.expires_on <= app.today() + coalesce(p_days, 60) and app.has_permission('fleet.manage')
  order by 6
$$;

create or replace function public.entity_documents(p_type text, p_id uuid)
returns table (id uuid, doc_no text, category text, title text, reference_no text, file_path text, file_name text, mime_type text,
               issued_on date, expires_on date, created_at timestamptz, uploaded_by text, can_manage boolean)
language sql stable security definer set search_path = '' as $$
  select d.id, d.doc_no, c.name, d.title, d.reference_no, d.file_path, d.file_name, d.mime_type, d.issued_on, d.expires_on, d.created_at,
         p.full_name, app.has_permission(c.manage_permission)
    from public.documents d join public.document_categories c on c.code = d.category_code
    left join public.profiles p on p.id = d.created_by
   where d.entity_type = p_type and d.entity_id = p_id and d.status = 'active' and app.has_permission(c.view_permission)
   order by d.created_at desc
$$;

-- Names of active staff (to assign complaints); no contact details.
create or replace function public.staff_directory()
returns table (id uuid, full_name text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.full_name from public.profiles p
   where p.is_active and app.current_user_id() is not null
     and (app.has_permission('complaints.manage') or app.has_permission('complaints.view') or app.has_permission('users.manage'))
   order by p.full_name
$$;

-- ---------------------------------------------------------------------
-- Dashboard: approvals, complaints, documents, messages
-- ---------------------------------------------------------------------
create or replace function public.control_summary()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'approvals_waiting', jsonb_array_length(public.approval_inbox() -> 'items'),
    'complaints', case when app.has_permission('complaints.view') or app.has_permission('complaints.manage') then jsonb_build_object(
        'open', (select count(*) from public.complaints where status not in ('resolved','closed')),
        'overdue', (select count(*) from public.complaints where status not in ('resolved','closed') and due_at < now()),
        'unassigned', (select count(*) from public.complaints where status = 'new'),
        'mine', (select count(*) from public.complaints where status not in ('resolved','closed') and assigned_to = app.current_user_id())) end,
    'qc_reviews', case when app.has_permission('qc.manage') then (select count(*) from public.complaints where qc_review_status = 'requested') end,
    'documents_expiring', (select count(*) from public.expiring_documents(30) where days_left <= 30),
    'documents_expired', (select count(*) from public.expiring_documents(30) where days_left < 0),
    'messages', case when app.has_permission('settings.manage') then jsonb_build_object(
        'queued', (select count(*) from public.message_outbox where status in ('queued','sending')),
        'failed', (select count(*) from public.message_outbox where status = 'failed' and created_at > now() - interval '7 days'),
        'sent_today', (select count(*) from public.message_outbox where status = 'sent' and sent_at >= app.today()),
        'enabled', coalesce((app.get_setting('messaging.enabled') #>> '{}')::boolean, false)) end)
$$;

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
