-- =====================================================================
-- OLA Water ERP — Phase 2A
-- 0024: read models for production, QC, recalls, stock and purchasing
-- =====================================================================

-- Stock per item: sellable, on hold, quarantined, value and reorder warning
create or replace function public.stock_summary(p_item_type text default null)
returns table (product_id uuid, sku text, name text, item_type text, unit text, available numeric, qc_hold numeric,
               quarantine numeric, damaged numeric, cost_price numeric, value numeric, reorder_level numeric, low boolean,
               by_location jsonb)
language sql stable security definer set search_path = '' as $$
  select p.id, p.sku, p.name, p.item_type, p.unit,
    coalesce(sum(b.qty) filter (where b.stock_status = 'available'), 0),
    coalesce(sum(b.qty) filter (where b.stock_status = 'qc_hold'), 0),
    coalesce(sum(b.qty) filter (where b.stock_status = 'quarantine'), 0),
    coalesce(sum(b.qty) filter (where b.stock_status = 'damaged'), 0),
    p.cost_price,
    round(coalesce(sum(b.qty), 0) * p.cost_price, 2),
    p.reorder_level,
    p.reorder_level > 0 and coalesce(sum(b.qty) filter (where b.stock_status = 'available'), 0) <= p.reorder_level,
    coalesce(jsonb_agg(jsonb_build_object('location', l.name, 'location_id', l.id, 'status', b.stock_status, 'qty', b.qty)
               order by l.name) filter (where b.qty <> 0), '[]')
  from public.products p
  left join public.inventory_balances b on b.product_id = p.id and b.qty <> 0
  left join public.locations l on l.id = b.location_id
  where app.has_permission('inventory.view') and p.is_active
    and (p_item_type is null or (p_item_type = 'materials' and p.item_type <> 'finished_good') or p.item_type = p_item_type)
  group by p.id
  order by p.item_type, p.sort_order, p.name
$$;

-- Batch stock that expires soon (or already has)
create or replace function public.expiring_stock(p_days integer default null)
returns table (batch_id uuid, batch_no text, product text, location text, stock_status text, qty numeric, expiry_date date, days_left integer)
language sql stable security definer set search_path = '' as $$
  select b.id, b.batch_no, p.name, l.name, lt.stock_status, lt.qty, b.expiry_date, (b.expiry_date - app.today())::integer
    from public.inventory_lots lt
    join public.production_batches b on b.id = lt.batch_id
    join public.products p on p.id = lt.product_id
    join public.locations l on l.id = lt.location_id
   where (app.has_permission('inventory.view') or app.has_permission('production.view'))
     and lt.qty > 0 and lt.stock_status in ('available','qc_hold') and b.expiry_date is not null
     and b.expiry_date <= app.today() + coalesce(p_days, (app.get_setting('production.expiry_alert_days') #>> '{}')::integer, 30)
   order by b.expiry_date, b.batch_no
$$;

create or replace function public.batch_details(p_batch uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare b public.production_batches; v jsonb;
begin
  if not (app.has_permission('production.view') or app.has_permission('qc.view') or app.has_permission('inventory.view')) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  select * into b from public.production_batches where id = p_batch;
  if not found then raise exception 'Batch not found' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'batch', to_jsonb(b),
    'product', (select jsonb_build_object('id', p.id, 'name', p.name, 'sku', p.sku, 'is_returnable', p.is_returnable,
                  'shelf_life_days', p.shelf_life_days, 'bottle_type_id', p.bottle_type_id) from public.products p where p.id = b.product_id),
    'line', (select jsonb_build_object('id', ln.id, 'code', ln.code, 'name', ln.name) from public.production_lines ln where ln.id = b.line_id),
    'location', (select name from public.locations where id = b.location_id),
    'created_by', (select full_name from public.profiles where id = b.created_by),
    'released_by', (select full_name from public.profiles where id = b.released_by),
    'stages', (select coalesce(jsonb_agg(jsonb_build_object('stage', s.stage, 'recorded_at', s.recorded_at, 'reading', s.reading,
                 'notes', s.notes, 'by', (select full_name from public.profiles where id = s.recorded_by)) order by s.recorded_at), '[]')
                 from public.production_stage_logs s where s.batch_id = b.id),
    'materials', (select coalesce(jsonb_agg(jsonb_build_object('material_id', m.material_id, 'name', p.name, 'unit', p.unit, 'qty', m.qty,
                    'unit_cost', m.unit_cost, 'value', round(m.qty * m.unit_cost, 2)) order by p.name), '[]')
                    from public.production_batch_materials m join public.products p on p.id = m.material_id where m.batch_id = b.id),
    'bom', (select coalesce(jsonb_agg(jsonb_build_object('material_id', m.material_id, 'name', p.name, 'unit', p.unit,
              'qty_per_unit', m.qty_per_unit,
              'available', coalesce((select qty from public.inventory_balances ib where ib.location_id = b.location_id
                                      and ib.product_id = m.material_id and ib.stock_status = 'available'), 0)) order by p.name), '[]')
              from public.product_materials m join public.products p on p.id = m.material_id where m.product_id = b.product_id),
    'tests', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'test_no', t.test_no, 'tested_at', t.tested_at, 'result', t.result,
                'template', (select name from public.qc_templates where id = t.template_id), 'lab_name', t.lab_name,
                'sample_ref', t.sample_ref, 'notes', t.notes, 'certificate_path', t.certificate_path,
                'by', (select full_name from public.profiles where id = t.tested_by),
                'results', (select coalesce(jsonb_agg(jsonb_build_object('name', r.parameter_name, 'unit', r.unit, 'min', r.min_value,
                              'max', r.max_value, 'value', coalesce(r.value_num::text, r.value_text), 'passed', r.passed,
                              'required', r.is_required) order by r.sort_order), '[]')
                              from public.qc_test_results r where r.test_id = t.id)) order by t.tested_at desc), '[]')
                from public.qc_tests t where t.batch_id = b.id),
    'stock', (select coalesce(jsonb_agg(jsonb_build_object('location_id', lt.location_id, 'location', l.name, 'location_type', l.location_type,
                'status', lt.stock_status, 'qty', lt.qty) order by l.name, lt.stock_status), '[]')
                from public.inventory_lots lt join public.locations l on l.id = lt.location_id
               where lt.batch_id = b.id and lt.qty > 0),
    'sold', coalesce((select sum(qty) from public.inventory_transactions where batch_id = b.id and txn_type = 'sale'), 0),
    'disposed', coalesce((select sum(qty) from public.inventory_transactions where batch_id = b.id and txn_type = 'dispose'), 0),
    'bottles', (select coalesce(jsonb_agg(jsonb_build_object('code', bo.code, 'holder', app.holder_label(bo.holder_type, bo.holder_id),
                  'still_from_batch', bo.last_batch_id = b.id) order by bo.code), '[]')
                  from public.production_batch_bottles bb join public.bottles bo on bo.id = bb.bottle_id where bb.batch_id = b.id),
    'recalls', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'recall_no', r.recall_no, 'status', r.status, 'created_at', r.created_at)
                  order by r.created_at desc), '[]') from public.batch_recalls r where r.batch_id = b.id),
    'journals', (select coalesce(jsonb_agg(jsonb_build_object('entry_no', j.entry_no, 'entry_date', j.entry_date, 'event_type', j.event_type,
                   'total', j.total) order by j.created_at), '[]')
                   from public.journal_entries j where j.source_type = 'production_batch' and j.source_id = b.id)
  ) into v;
  return v;
end $$;

create or replace function public.recall_details(p_recall uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.batch_recalls; b public.production_batches; v jsonb;
begin
  if not app.has_permission('qc.view') then raise exception 'Permission denied' using errcode = '42501'; end if;
  select * into r from public.batch_recalls where id = p_recall;
  if not found then raise exception 'Recall not found' using errcode = 'P0002'; end if;
  select * into b from public.production_batches where id = r.batch_id;
  select jsonb_build_object(
    'recall', to_jsonb(r) || jsonb_build_object('created_by_name', (select full_name from public.profiles where id = r.created_by),
                                                'closed_by_name', (select full_name from public.profiles where id = r.closed_by)),
    'batch', jsonb_build_object('id', b.id, 'batch_no', b.batch_no, 'production_date', b.production_date, 'produced_qty', b.produced_qty,
                                'expiry_date', b.expiry_date, 'product', (select name from public.products where id = b.product_id)),
    'locations', (select coalesce(jsonb_agg(jsonb_build_object('location_id', l.id, 'location', l.name, 'type', l.location_type,
                    'status', lt.stock_status, 'qty', lt.qty) order by l.location_type, l.name), '[]')
                    from public.inventory_lots lt join public.locations l on l.id = lt.location_id
                   where lt.batch_id = b.id and lt.qty > 0),
    'customers', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'customer_id', c.id, 'name', c.name, 'customer_no', c.customer_no,
                    'phone', c.phone, 'is_walk_in', c.is_walk_in,
                    'address', (select a.address_line || coalesce(', ' || a.city, '') from public.customer_addresses a
                                 where a.customer_id = c.id order by a.is_default desc limit 1),
                    'qty_supplied', i.qty_supplied, 'bottles_held', i.bottles_held, 'qty_recovered', i.qty_recovered,
                    'status', i.status, 'note', i.note) order by i.status, c.name), '[]')
                    from public.batch_recall_customers i join public.customers c on c.id = i.customer_id where i.recall_id = r.id),
    'totals', jsonb_build_object(
        'produced', b.produced_qty,
        'sold', coalesce((select sum(qty) from public.inventory_transactions where batch_id = b.id and txn_type = 'sale'), 0),
        'in_circulation', coalesce((select sum(lt.qty) from public.inventory_lots lt where lt.batch_id = b.id and lt.stock_status = 'available'), 0),
        'quarantined', coalesce((select sum(lt.qty) from public.inventory_lots lt where lt.batch_id = b.id and lt.stock_status = 'quarantine'), 0),
        'recovered', coalesce((select sum(qty_recovered) from public.batch_recall_customers where recall_id = r.id), 0),
        'disposed', coalesce((select sum(qty) from public.inventory_transactions where batch_id = b.id and txn_type = 'dispose'), 0))
  ) into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Suppliers
-- ---------------------------------------------------------------------
create or replace function public.supplier_list()
returns table (id uuid, code text, name text, phone text, city text, vat_no text, payment_terms_days integer, is_active boolean,
               outstanding numeric, overdue numeric, open_orders bigint, receipts bigint, on_time_pct numeric, rejected_pct numeric)
language sql stable security definer set search_path = '' as $$
  select s.id, s.code, s.name, s.phone, s.city, s.vat_no, s.payment_terms_days, s.is_active,
    app.supplier_outstanding(s.id),
    coalesce((select sum(total - amount_paid) from public.supplier_invoices i where i.supplier_id = s.id
               and i.status in ('approved','partially_paid') and i.due_date < app.today()), 0),
    (select count(*) from public.purchase_orders o where o.supplier_id = s.id and o.status in ('pending_approval','approved','partially_received')),
    (select count(*) from public.goods_receipts g where g.supplier_id = s.id),
    (select round(100.0 * count(*) filter (where g.on_time) / nullif(count(*), 0), 0) from public.goods_receipts g where g.supplier_id = s.id),
    (select round(100.0 * sum(gl.qty_rejected) / nullif(sum(gl.qty_received + gl.qty_rejected), 0), 1)
       from public.goods_receipt_lines gl join public.goods_receipts g on g.id = gl.grn_id where g.supplier_id = s.id)
  from public.suppliers s
  where app.has_permission('procurement.view') or app.has_permission('suppliers.manage') or app.has_permission('payments.view')
  order by s.is_active desc, s.name
$$;

create or replace function public.supplier_details(p_supplier uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare s public.suppliers; v jsonb;
begin
  if not (app.has_permission('procurement.view') or app.has_permission('suppliers.manage') or app.has_permission('payments.view')) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  select * into s from public.suppliers where id = p_supplier;
  if not found then raise exception 'Supplier not found' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'supplier', to_jsonb(s),
    'outstanding', app.supplier_outstanding(s.id),
    'advance', coalesce((select sum(unallocated) from public.supplier_payments where supplier_id = s.id), 0),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('product_id', p.id, 'name', p.name, 'unit', p.unit, 'supplier_sku', si.supplier_sku,
                'unit_price', si.unit_price, 'lead_time_days', si.lead_time_days, 'is_preferred', si.is_preferred) order by p.name), '[]')
                from public.supplier_items si join public.products p on p.id = si.product_id where si.supplier_id = s.id),
    'orders', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'po_no', o.po_no, 'order_date', o.order_date,
                 'expected_date', o.expected_date, 'status', o.status, 'total', o.total) order by o.order_date desc, o.po_no desc), '[]')
                 from (select * from public.purchase_orders where supplier_id = s.id order by order_date desc limit 30) o),
    'invoices', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'ref_no', i.ref_no, 'supplier_invoice_no', i.supplier_invoice_no,
                   'invoice_date', i.invoice_date, 'due_date', i.due_date, 'total', i.total, 'amount_paid', i.amount_paid,
                   'balance', i.total - i.amount_paid, 'status', i.status, 'match_status', i.match_status,
                   'po_no', (select po_no from public.purchase_orders where id = i.po_id)) order by i.invoice_date desc), '[]')
                   from (select * from public.supplier_invoices where supplier_id = s.id order by invoice_date desc limit 50) i),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'payment_no', x.payment_no, 'paid_at', x.paid_at, 'method', x.method,
                   'amount', x.amount, 'unallocated', x.unallocated, 'reference', x.reference) order by x.paid_at desc), '[]')
                   from (select * from public.supplier_payments where supplier_id = s.id order by paid_at desc limit 30) x),
    'performance', jsonb_build_object(
        'receipts', (select count(*) from public.goods_receipts g where g.supplier_id = s.id),
        'on_time', (select count(*) from public.goods_receipts g where g.supplier_id = s.id and g.on_time),
        'qty_received', coalesce((select sum(gl.qty_received) from public.goods_receipt_lines gl join public.goods_receipts g on g.id = gl.grn_id
                                   where g.supplier_id = s.id), 0),
        'qty_rejected', coalesce((select sum(gl.qty_rejected) from public.goods_receipt_lines gl join public.goods_receipts g on g.id = gl.grn_id
                                   where g.supplier_id = s.id), 0),
        'mismatched_invoices', (select count(*) from public.supplier_invoices i where i.supplier_id = s.id and i.match_status <> 'matched'
                                  and i.status <> 'void'))
  ) into v;
  return v;
end $$;

create or replace function public.purchase_order_details(p_po uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o public.purchase_orders; v jsonb;
begin
  select * into o from public.purchase_orders where id = p_po;
  if not found then raise exception 'Purchase order not found' using errcode = 'P0002'; end if;
  if not (app.has_permission('procurement.view') or app.has_permission('inventory.manage') or app.has_permission('payments.view')) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'order', to_jsonb(o) || jsonb_build_object(
        'created_by_name', (select full_name from public.profiles where id = o.created_by),
        'approved_by_name', (select full_name from public.profiles where id = o.approved_by),
        'request_no', (select request_no from public.purchase_requests where id = o.request_id),
        'location', (select name from public.locations where id = o.location_id),
        'purchase_limit', coalesce((app.get_setting('approvals.purchase_amount') #>> '{}')::numeric, 0)),
    'supplier', (select jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name, 'phone', s.phone, 'email', s.email,
                   'address', s.address, 'city', s.city, 'vat_no', s.vat_no, 'payment_terms_days', s.payment_terms_days)
                   from public.suppliers s where s.id = o.supplier_id),
    'company', jsonb_build_object('name', app.get_setting('company.name') #>> '{}',
                                  'vat_no', app.get_setting('company.vat_registration_no') #>> '{}'),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'line_no', l.line_no, 'product_id', p.id, 'name', p.name, 'sku', p.sku,
                'unit', p.unit, 'qty_ordered', l.qty_ordered, 'unit_price', l.unit_price, 'tax_rate', l.tax_rate, 'net', l.net, 'tax', l.tax,
                'total', l.total, 'qty_received', l.qty_received, 'qty_rejected', l.qty_rejected, 'qty_invoiced', l.qty_invoiced)
                order by l.line_no), '[]')
                from public.purchase_order_lines l join public.products p on p.id = l.product_id where l.po_id = o.id),
    'receipts', (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'grn_no', g.grn_no, 'received_at', g.received_at,
                   'delivery_note_no', g.delivery_note_no, 'on_time', g.on_time,
                   'received_by', (select full_name from public.profiles where id = g.received_by),
                   'value', (select coalesce(sum(round(gl.qty_received * gl.unit_price, 2)), 0) from public.goods_receipt_lines gl where gl.grn_id = g.id),
                   'lines', (select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'qty_received', gl.qty_received,
                              'qty_rejected', gl.qty_rejected, 'reject_reason', gl.reject_reason, 'supplier_lot', gl.supplier_lot,
                              'expiry_date', gl.expiry_date)), '[]')
                              from public.goods_receipt_lines gl join public.products p on p.id = gl.product_id where gl.grn_id = g.id))
                   order by g.received_at), '[]')
                   from public.goods_receipts g where g.po_id = o.id),
    'invoices', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'ref_no', i.ref_no, 'supplier_invoice_no', i.supplier_invoice_no,
                   'invoice_date', i.invoice_date, 'due_date', i.due_date, 'total', i.total, 'amount_paid', i.amount_paid, 'status', i.status,
                   'match_status', i.match_status, 'match_notes', i.match_notes, 'decision_note', i.decision_note) order by i.created_at), '[]')
                   from public.supplier_invoices i where i.po_id = o.id)
  ) into v;
  return v;
end $$;

-- Figures for the dashboard and the operations pages
create or replace function public.operations_summary()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'production', case when app.has_permission('production.view') or app.has_permission('qc.view') then jsonb_build_object(
        'today_produced', coalesce((select sum(produced_qty) from public.production_batches where production_date = app.today()
                                     and status not in ('cancelled','planned','in_production')), 0),
        'in_production', (select count(*) from public.production_batches where status in ('planned','in_production')),
        'qc_hold', (select count(*) from public.production_batches where status = 'qc_hold'),
        'qc_hold_qty', coalesce((select sum(qty) from public.inventory_lots where stock_status = 'qc_hold'), 0),
        'quarantine_qty', coalesce((select sum(qty) from public.inventory_lots where stock_status = 'quarantine'), 0),
        'open_recalls', (select count(*) from public.batch_recalls where status = 'open'),
        'month_rejected', coalesce((select sum(rejected_qty) from public.production_batches
                                     where production_date >= date_trunc('month', app.today())::date), 0),
        'month_produced', coalesce((select sum(produced_qty) from public.production_batches
                                     where production_date >= date_trunc('month', app.today())::date), 0)) end,
    'stock', case when app.has_permission('inventory.view') then jsonb_build_object(
        'low_items', (select count(*) from (select p.id from public.products p
                         left join public.inventory_balances b on b.product_id = p.id and b.stock_status = 'available'
                        where p.is_active and p.reorder_level > 0 group by p.id, p.reorder_level
                       having coalesce(sum(b.qty), 0) <= p.reorder_level) x),
        'expiring', (select count(*) from public.expiring_stock(null)),
        'materials_value', coalesce((select round(sum(b.qty * p.cost_price), 2) from public.inventory_balances b
                                      join public.products p on p.id = b.product_id where p.item_type <> 'finished_good'), 0),
        'finished_value', coalesce((select round(sum(b.qty * p.cost_price), 2) from public.inventory_balances b
                                     join public.products p on p.id = b.product_id where p.item_type = 'finished_good'), 0)) end,
    'purchasing', case when app.has_permission('procurement.view') or app.has_permission('payments.view') then jsonb_build_object(
        'requests_waiting', (select count(*) from public.purchase_requests where status = 'submitted'),
        'orders_waiting', (select count(*) from public.purchase_orders where status = 'pending_approval'),
        'orders_open', (select count(*) from public.purchase_orders where status in ('approved','partially_received')),
        'orders_late', (select count(*) from public.purchase_orders where status in ('approved','partially_received')
                          and expected_date < app.today()),
        'invoices_on_hold', (select count(*) from public.supplier_invoices where status = 'on_hold'),
        'payable', coalesce((select sum(total - amount_paid) from public.supplier_invoices where status in ('approved','partially_paid')), 0),
        'payable_overdue', coalesce((select sum(total - amount_paid) from public.supplier_invoices
                                      where status in ('approved','partially_paid') and due_date < app.today()), 0),
        'due_7_days', coalesce((select sum(total - amount_paid) from public.supplier_invoices
                                 where status in ('approved','partially_paid') and due_date between app.today() and app.today() + 7), 0)) end
  )
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
revoke execute on function public.log_failed_login(text, text, text, text) from authenticated;
revoke execute on function public.bootstrap_super_admin(text)              from authenticated;
