-- =====================================================================
-- OLA Water ERP — Phase 2A
-- 0022: suppliers and purchasing
-- =====================================================================
-- Purchase request → approval → purchase order (approval above the
-- purchase limit) → goods received (partial allowed, rejects at the door)
-- → supplier invoice with 3-way match (order × received × invoiced)
-- → supplier payment.
-- Accounting: goods received Dr Inventory / Cr Goods Received Not Invoiced;
-- invoice Dr GRNI (+/- price variance) + VAT input / Cr Accounts Payable;
-- payment Dr Accounts Payable / Cr Bank or Cash.
-- =====================================================================

create table public.suppliers (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique check (code ~ '^[A-Z0-9-]{2,12}$'),
  name                text not null check (length(trim(name)) > 0),
  contact_person      text,
  phone               text,
  email               text,
  address             text,
  city                text,
  vat_no              text,
  payment_terms_days  integer not null default 30 check (payment_terms_days >= 0),
  notes               text,
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create trigger suppliers_touch before update on public.suppliers for each row execute function app.touch_updated_at();
create trigger suppliers_audit after insert or update on public.suppliers for each row execute function app.audit_row('procurement');

create table public.supplier_items (
  supplier_id     uuid not null references public.suppliers(id),
  product_id      uuid not null references public.products(id),
  supplier_sku    text,
  unit_price      numeric(14,4) not null check (unit_price >= 0),
  lead_time_days  integer check (lead_time_days >= 0),
  is_preferred    boolean not null default false,
  updated_at      timestamptz not null default now(),
  primary key (supplier_id, product_id)
);
create trigger supplier_items_audit after insert or update or delete on public.supplier_items for each row execute function app.audit_row('procurement');

-- ---------------------------------------------------------------------
-- Purchase requests
-- ---------------------------------------------------------------------
create table public.purchase_requests (
  id             uuid primary key default gen_random_uuid(),
  request_no     text not null unique,
  location_id    uuid not null references public.locations(id),
  status         text not null default 'submitted' check (status in ('submitted','approved','rejected','ordered','cancelled')),
  needed_by      date,
  notes          text,
  requested_at   timestamptz not null default now(),
  requested_by   uuid,
  decided_at     timestamptz,
  decided_by     uuid,
  decision_note  text,
  updated_at     timestamptz not null default now(),
  client_txn_id  uuid unique
);
create trigger purchase_requests_touch before update on public.purchase_requests for each row execute function app.touch_updated_at();
create trigger purchase_requests_audit after insert or update on public.purchase_requests for each row execute function app.audit_row('procurement');

create table public.purchase_request_items (
  id               uuid primary key default gen_random_uuid(),
  request_id       uuid not null references public.purchase_requests(id),
  product_id       uuid not null references public.products(id),
  qty              numeric(14,3) not null check (qty > 0),
  est_unit_price   numeric(14,4),
  notes            text,
  unique (request_id, product_id)
);

-- ---------------------------------------------------------------------
-- Purchase orders
-- ---------------------------------------------------------------------
create table public.purchase_orders (
  id              uuid primary key default gen_random_uuid(),
  po_no           text not null unique,
  supplier_id     uuid not null references public.suppliers(id),
  location_id     uuid not null references public.locations(id),
  request_id      uuid references public.purchase_requests(id),
  order_date      date not null,
  expected_date   date,
  status          text not null default 'pending_approval' check (status in
                    ('pending_approval','approved','partially_received','received','closed','cancelled')),
  subtotal        numeric(16,2) not null default 0,
  tax_total       numeric(16,2) not null default 0,
  total           numeric(16,2) not null default 0,
  notes           text,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  approved_at     timestamptz,
  approved_by     uuid,
  decision_note   text,
  updated_at      timestamptz not null default now(),
  client_txn_id   uuid unique
);
create index purchase_orders_supplier_idx on public.purchase_orders (supplier_id, order_date desc);
create index purchase_orders_status_idx on public.purchase_orders (status, order_date desc);
create trigger purchase_orders_touch before update on public.purchase_orders for each row execute function app.touch_updated_at();
create trigger purchase_orders_audit after insert or update on public.purchase_orders for each row execute function app.audit_row('procurement');

create table public.purchase_order_lines (
  id             uuid primary key default gen_random_uuid(),
  po_id          uuid not null references public.purchase_orders(id),
  line_no        integer not null,
  product_id     uuid not null references public.products(id),
  qty_ordered    numeric(14,3) not null check (qty_ordered > 0),
  unit_price     numeric(14,4) not null check (unit_price >= 0),
  tax_rate       numeric(5,2) not null default 0 check (tax_rate between 0 and 100),
  net            numeric(16,2) not null,
  tax            numeric(16,2) not null,
  total          numeric(16,2) not null,
  qty_received   numeric(14,3) not null default 0 check (qty_received >= 0),
  qty_rejected   numeric(14,3) not null default 0 check (qty_rejected >= 0),
  qty_invoiced   numeric(14,3) not null default 0 check (qty_invoiced >= 0),
  unique (po_id, line_no),
  unique (po_id, product_id)
);
comment on column public.purchase_order_lines.unit_price is 'Agreed price per unit before VAT';
create trigger purchase_order_lines_audit after insert or update on public.purchase_order_lines for each row execute function app.audit_row('procurement');

-- ---------------------------------------------------------------------
-- Goods received
-- ---------------------------------------------------------------------
create table public.goods_receipts (
  id                uuid primary key default gen_random_uuid(),
  grn_no            text not null unique,
  po_id             uuid not null references public.purchase_orders(id),
  supplier_id       uuid not null references public.suppliers(id),
  location_id       uuid not null references public.locations(id),
  received_at       timestamptz not null default now(),
  delivery_note_no  text,
  notes             text,
  on_time           boolean,
  received_by       uuid,
  client_txn_id     uuid unique
);
create index goods_receipts_po_idx on public.goods_receipts (po_id);
create index goods_receipts_supplier_idx on public.goods_receipts (supplier_id, received_at desc);
create trigger goods_receipts_audit after insert on public.goods_receipts for each row execute function app.audit_row('procurement');
create trigger goods_receipts_append_only before update or delete on public.goods_receipts for each row execute function app.forbid_change();

create table public.goods_receipt_lines (
  id             uuid primary key default gen_random_uuid(),
  grn_id         uuid not null references public.goods_receipts(id),
  po_line_id     uuid not null references public.purchase_order_lines(id),
  product_id     uuid not null references public.products(id),
  qty_received   numeric(14,3) not null default 0 check (qty_received >= 0),
  qty_rejected   numeric(14,3) not null default 0 check (qty_rejected >= 0),
  reject_reason  text,
  supplier_lot   text,
  expiry_date    date,
  unit_price     numeric(14,4) not null
);
create trigger goods_receipt_lines_append_only before update or delete on public.goods_receipt_lines for each row execute function app.forbid_change();

-- ---------------------------------------------------------------------
-- Supplier invoices and payments
-- ---------------------------------------------------------------------
create table public.supplier_invoices (
  id                   uuid primary key default gen_random_uuid(),
  ref_no               text not null unique,
  supplier_id          uuid not null references public.suppliers(id),
  supplier_invoice_no  text not null,
  po_id                uuid not null references public.purchase_orders(id),
  invoice_date         date not null,
  due_date             date not null,
  subtotal             numeric(16,2) not null,
  tax_total            numeric(16,2) not null,
  total                numeric(16,2) not null check (total >= 0),
  amount_paid          numeric(16,2) not null default 0,
  status               text not null check (status in ('on_hold','approved','partially_paid','paid','void')),
  match_status         text not null check (match_status in ('matched','mismatch','override')),
  match_notes          text[] not null default '{}',
  journal_entry_id     uuid references public.journal_entries(id),
  created_at           timestamptz not null default now(),
  created_by           uuid,
  approved_at          timestamptz,
  approved_by          uuid,
  decision_note        text,
  updated_at           timestamptz not null default now(),
  client_txn_id        uuid unique
);
create unique index supplier_invoices_number_uq on public.supplier_invoices (supplier_id, lower(supplier_invoice_no)) where status <> 'void';
create index supplier_invoices_supplier_idx on public.supplier_invoices (supplier_id, invoice_date desc);
create trigger supplier_invoices_touch before update on public.supplier_invoices for each row execute function app.touch_updated_at();
create trigger supplier_invoices_audit after insert or update on public.supplier_invoices for each row execute function app.audit_row('procurement');

create table public.supplier_invoice_lines (
  id           uuid primary key default gen_random_uuid(),
  invoice_id   uuid not null references public.supplier_invoices(id),
  po_line_id   uuid not null references public.purchase_order_lines(id),
  product_id   uuid not null references public.products(id),
  qty          numeric(14,3) not null check (qty > 0),
  unit_price   numeric(14,4) not null check (unit_price >= 0),
  po_price     numeric(14,4) not null,
  tax_rate     numeric(5,2) not null,
  net          numeric(16,2) not null,
  tax          numeric(16,2) not null,
  total        numeric(16,2) not null,
  match_ok     boolean not null,
  match_note   text
);

create table public.supplier_payments (
  id               uuid primary key default gen_random_uuid(),
  payment_no       text not null unique,
  supplier_id      uuid not null references public.suppliers(id),
  paid_at          timestamptz not null default now(),
  method           text not null check (method in ('cash','bank_transfer','cheque')),
  amount           numeric(16,2) not null check (amount > 0),
  unallocated      numeric(16,2) not null default 0 check (unallocated >= 0),
  reference        text,
  notes            text,
  journal_entry_id uuid references public.journal_entries(id),
  created_by       uuid,
  client_txn_id    uuid unique
);
create index supplier_payments_supplier_idx on public.supplier_payments (supplier_id, paid_at desc);
create trigger supplier_payments_audit after insert or update on public.supplier_payments for each row execute function app.audit_row('procurement');

create table public.supplier_payment_allocations (
  payment_id  uuid not null references public.supplier_payments(id),
  invoice_id  uuid not null references public.supplier_invoices(id),
  amount      numeric(16,2) not null check (amount > 0),
  created_at  timestamptz not null default now(),
  primary key (payment_id, invoice_id)
);

-- ---------------------------------------------------------------------
-- Suppliers
-- ---------------------------------------------------------------------
create or replace function public.save_supplier(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; v_phone text := app.jtext(p, 'phone');
begin
  perform app.require_permission('suppliers.manage');
  if nullif(trim(app.jtext(p, 'name')), '') is null then raise exception 'Enter the supplier name' using errcode = '22023'; end if;
  if v_phone is not null then v_phone := coalesce(app.normalize_phone(v_phone), v_phone); end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    insert into public.suppliers (code, name, contact_person, phone, email, address, city, vat_no, payment_terms_days, notes)
    values (upper(trim(app.jtext(p, 'code'))), trim(app.jtext(p, 'name')), app.jtext(p, 'contact_person'), v_phone,
            lower(app.jtext(p, 'email')), app.jtext(p, 'address'), app.jtext(p, 'city'), nullif(trim(app.jtext(p, 'vat_no')), ''),
            coalesce(app.jint(p, 'payment_terms_days'), 30), app.jtext(p, 'notes'))
    returning id into v;
  else
    update public.suppliers set name = trim(app.jtext(p, 'name')), contact_person = app.jtext(p, 'contact_person'), phone = v_phone,
           email = lower(app.jtext(p, 'email')), address = app.jtext(p, 'address'), city = app.jtext(p, 'city'),
           vat_no = nullif(trim(app.jtext(p, 'vat_no')), ''), payment_terms_days = coalesce(app.jint(p, 'payment_terms_days'), 30),
           notes = app.jtext(p, 'notes'), is_active = app.jbool(p, 'is_active', true)
     where id = p_id returning id into v;
    if v is null then raise exception 'Supplier not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

create or replace function public.set_supplier_items(p_supplier uuid, p_lines jsonb, p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
declare l jsonb; n integer := 0;
begin
  perform app.require_permission('suppliers.manage');
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Supplier prices'), null, null);
  delete from public.supplier_items where supplier_id = p_supplier;
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    continue when app.jnum(l, 'unit_price') is null;
    insert into public.supplier_items (supplier_id, product_id, supplier_sku, unit_price, lead_time_days, is_preferred)
    values (p_supplier, app.juuid(l, 'product_id'), app.jtext(l, 'supplier_sku'), app.jnum(l, 'unit_price'),
            app.jint(l, 'lead_time_days'), app.jbool(l, 'is_preferred', false));
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function app.supplier_outstanding(p_supplier uuid)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce((select sum(total - amount_paid) from public.supplier_invoices
                    where supplier_id = p_supplier and status in ('approved','partially_paid')), 0)
       - coalesce((select sum(unallocated) from public.supplier_payments where supplier_id = p_supplier), 0)
$$;

-- ---------------------------------------------------------------------
-- Purchase requests
-- ---------------------------------------------------------------------
create or replace function public.create_purchase_request(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v uuid := gen_random_uuid(); v_no text; l jsonb; n integer := 0; v_res jsonb; v_loc uuid := app.juuid(p, 'location_id');
begin
  perform app.require_permission('procurement.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'create_purchase_request');
  if v_done is not null then return v_done; end if;
  if not exists (select 1 from public.locations where id = v_loc) then raise exception 'Choose where the goods are needed' using errcode = '22023'; end if;
  perform app.set_context(null, p_client_txn_id, 'request');
  v_no := app.next_document_number('PR', v_loc);
  insert into public.purchase_requests (id, request_no, location_id, needed_by, notes, requested_by, client_txn_id)
  values (v, v_no, v_loc, (app.jtext(p, 'needed_by'))::date, app.jtext(p, 'notes'), app.current_user_id(), p_client_txn_id);
  for l in select * from jsonb_array_elements(coalesce(p -> 'items', '[]')) loop
    continue when coalesce(app.jnum(l, 'qty'), 0) <= 0;
    insert into public.purchase_request_items (request_id, product_id, qty, est_unit_price, notes)
    values (v, app.juuid(l, 'product_id'), app.jnum(l, 'qty'), app.jnum(l, 'est_unit_price'), app.jtext(l, 'notes'));
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Add at least one item' using errcode = '22023'; end if;
  v_res := jsonb_build_object('request_id', v, 'request_no', v_no);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.decide_purchase_request(p_id uuid, p_approve boolean, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.purchase_requests;
begin
  select * into r from public.purchase_requests where id = p_id for update;
  if not found then raise exception 'Request not found' using errcode = 'P0002'; end if;
  if r.status <> 'submitted' then raise exception 'This request has already been decided' using errcode = '22023'; end if;
  if p_approve is null then
    -- withdraw (by the requester or a manager)
    if r.requested_by is distinct from app.current_user_id() and not app.has_permission('procurement.approve') then
      raise exception 'Only the requester or an approver can withdraw a request' using errcode = '42501';
    end if;
  else
    perform app.require_permission('procurement.approve');
    if not p_approve and nullif(trim(p_note), '') is null then raise exception 'Give a reason for rejecting' using errcode = '22023'; end if;
  end if;
  perform app.set_context(nullif(trim(p_note), ''), null, case when p_approve then 'approve' when not p_approve then 'reject' else 'withdraw' end);
  update public.purchase_requests set status = case when p_approve then 'approved' when not p_approve then 'rejected' else 'cancelled' end,
         decided_at = now(), decided_by = app.current_user_id(), decision_note = nullif(trim(p_note), '')
   where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- Purchase orders
-- ---------------------------------------------------------------------
--   p: {supplier_id, location_id, expected_date, request_id, notes,
--       lines: [{product_id, qty, unit_price, tax_rate?}]}
create or replace function public.create_purchase_order(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; s public.suppliers; v uuid := gen_random_uuid(); v_no text; l jsonb; pr public.products; n integer := 0;
  v_rate numeric; calc record; v_net numeric := 0; v_tax numeric := 0; v_total numeric := 0; v_limit numeric; v_res jsonb;
  v_loc uuid := app.juuid(p, 'location_id'); v_req uuid := app.juuid(p, 'request_id'); v_status text;
begin
  perform app.require_permission('procurement.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'create_purchase_order');
  if v_done is not null then return v_done; end if;
  select * into s from public.suppliers where id = app.juuid(p, 'supplier_id') and is_active;
  if not found then raise exception 'Choose a supplier' using errcode = '22023'; end if;
  if not exists (select 1 from public.locations where id = v_loc and location_type in ('warehouse','head_office')) then
    raise exception 'Choose the warehouse to deliver to' using errcode = '22023';
  end if;
  if v_req is not null and not exists (select 1 from public.purchase_requests where id = v_req and status = 'approved') then
    raise exception 'The purchase request must be approved first' using errcode = '22023';
  end if;
  perform app.set_context(null, p_client_txn_id, 'order');
  v_no := app.next_document_number('PO', v_loc);
  insert into public.purchase_orders (id, po_no, supplier_id, location_id, request_id, order_date, expected_date, notes, created_by, client_txn_id)
  values (v, v_no, s.id, v_loc, v_req, app.today(), (app.jtext(p, 'expected_date'))::date, app.jtext(p, 'notes'), app.current_user_id(), p_client_txn_id);

  for l in select * from jsonb_array_elements(coalesce(p -> 'lines', '[]')) loop
    continue when coalesce(app.jnum(l, 'qty'), 0) <= 0;
    select * into pr from public.products where id = app.juuid(l, 'product_id') and is_active;
    if not found then raise exception 'Unknown item' using errcode = 'P0002'; end if;
    if app.jnum(l, 'unit_price') is null or app.jnum(l, 'unit_price') < 0 then
      raise exception 'Enter the price for %', pr.name using errcode = '22023';
    end if;
    v_rate := coalesce(app.jnum(l, 'tax_rate'),
                       case when s.vat_no is not null and pr.tax_code is not null then app.tax_rate(pr.tax_code) else 0 end);
    select * into calc from app.calc_line(app.jnum(l, 'qty'), app.jnum(l, 'unit_price'), 0, v_rate, false);
    n := n + 1;
    insert into public.purchase_order_lines (po_id, line_no, product_id, qty_ordered, unit_price, tax_rate, net, tax, total)
    values (v, n, pr.id, app.jnum(l, 'qty'), app.jnum(l, 'unit_price'), v_rate, calc.net, calc.tax, calc.total);
    v_net := v_net + calc.net; v_tax := v_tax + calc.tax; v_total := v_total + calc.total;
  end loop;
  if n = 0 then raise exception 'Add at least one item' using errcode = '22023'; end if;

  v_limit := coalesce((app.get_setting('approvals.purchase_amount') #>> '{}')::numeric, 0);
  v_status := case when v_total < v_limit or app.has_permission('procurement.approve') then 'approved' else 'pending_approval' end;
  update public.purchase_orders set subtotal = v_net, tax_total = v_tax, total = v_total, status = v_status,
         approved_at = case when v_status = 'approved' then now() end,
         approved_by = case when v_status = 'approved' then app.current_user_id() end
   where id = v;
  if v_req is not null then update public.purchase_requests set status = 'ordered' where id = v_req; end if;

  v_res := jsonb_build_object('po_id', v, 'po_no', v_no, 'total', v_total, 'status', v_status);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.decide_purchase_order(p_po uuid, p_approve boolean, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare po public.purchase_orders;
begin
  select * into po from public.purchase_orders where id = p_po for update;
  if not found then raise exception 'Purchase order not found' using errcode = 'P0002'; end if;
  if p_approve then
    perform app.require_permission('procurement.approve');
    if po.status <> 'pending_approval' then raise exception 'This order is not waiting for approval' using errcode = '22023'; end if;
    perform app.set_context(nullif(trim(p_note), ''), null, 'approve');
    update public.purchase_orders set status = 'approved', approved_at = now(), approved_by = app.current_user_id(),
           decision_note = nullif(trim(p_note), '') where id = p_po;
  else
    if not (app.has_permission('procurement.approve') or (po.status = 'pending_approval' and app.has_permission('procurement.manage'))) then
      raise exception 'Permission denied: procurement.approve is required' using errcode = '42501';
    end if;
    if nullif(trim(p_note), '') is null then raise exception 'Give a reason' using errcode = '22023'; end if;
    if po.status not in ('pending_approval','approved') or exists (select 1 from public.goods_receipts where po_id = p_po) then
      raise exception 'Goods have already been received on this order — close it instead' using errcode = '22023';
    end if;
    perform app.set_context(trim(p_note), null, 'cancel');
    update public.purchase_orders set status = 'cancelled', decision_note = trim(p_note) where id = p_po;
  end if;
end $$;

create or replace function public.close_purchase_order(p_po uuid, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare po public.purchase_orders;
begin
  perform app.require_permission('procurement.manage');
  if nullif(trim(p_note), '') is null then raise exception 'Give a reason' using errcode = '22023'; end if;
  select * into po from public.purchase_orders where id = p_po for update;
  if not found then raise exception 'Purchase order not found' using errcode = 'P0002'; end if;
  if po.status not in ('partially_received','received') then raise exception 'Only a received order can be closed' using errcode = '22023'; end if;
  perform app.set_context(trim(p_note), null, 'close');
  update public.purchase_orders set status = 'closed', decision_note = trim(p_note) where id = p_po;
end $$;

-- ---------------------------------------------------------------------
-- Goods received
--   p: {delivery_note_no, notes, lines: [{po_line_id, qty_received, qty_rejected, reject_reason, supplier_lot, expiry_date}]}
-- ---------------------------------------------------------------------
create or replace function public.receive_purchase_order(p_po uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; po public.purchase_orders; pl public.purchase_order_lines; pr public.products; l jsonb; v uuid := gen_random_uuid();
  v_no text; v_ok numeric; v_rej numeric; v_raw numeric := 0; v_fg numeric := 0; n integer := 0; v_res jsonb; v_open integer;
begin
  if not (app.has_permission('inventory.manage') or app.has_permission('procurement.manage')) then
    raise exception 'Permission denied: inventory.manage is required' using errcode = '42501';
  end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'receive_purchase_order');
  if v_done is not null then return v_done; end if;
  select * into po from public.purchase_orders where id = p_po for update;
  if not found then raise exception 'Purchase order not found' using errcode = 'P0002'; end if;
  if po.status not in ('approved','partially_received') then
    raise exception 'Goods can only be received on an approved order' using errcode = '22023';
  end if;
  perform app.set_context(null, p_client_txn_id, 'receive');
  v_no := app.next_document_number('GRN', po.location_id);
  insert into public.goods_receipts (id, grn_no, po_id, supplier_id, location_id, delivery_note_no, notes, on_time, received_by, client_txn_id)
  values (v, v_no, po.id, po.supplier_id, po.location_id, app.jtext(p, 'delivery_note_no'), app.jtext(p, 'notes'),
          po.expected_date is null or app.today() <= po.expected_date, app.current_user_id(), p_client_txn_id);

  for l in select * from jsonb_array_elements(coalesce(p -> 'lines', '[]')) loop
    v_ok := coalesce(app.jnum(l, 'qty_received'), 0); v_rej := coalesce(app.jnum(l, 'qty_rejected'), 0);
    continue when v_ok <= 0 and v_rej <= 0;
    if v_ok < 0 or v_rej < 0 then raise exception 'Quantities cannot be negative' using errcode = '22023'; end if;
    select * into pl from public.purchase_order_lines where id = app.juuid(l, 'po_line_id') and po_id = po.id for update;
    if not found then raise exception 'Line is not on this order' using errcode = 'P0002'; end if;
    select * into pr from public.products where id = pl.product_id;
    if pl.qty_received + v_ok > pl.qty_ordered then
      raise exception '% — % ordered, % already received; % more is too many', pr.name, pl.qty_ordered::numeric(14,0),
        pl.qty_received::numeric(14,0), v_ok::numeric(14,0) using errcode = '22023';
    end if;
    if v_rej > 0 and nullif(trim(app.jtext(l, 'reject_reason')), '') is null then
      raise exception 'Say why % was rejected', pr.name using errcode = '22023';
    end if;
    insert into public.goods_receipt_lines (grn_id, po_line_id, product_id, qty_received, qty_rejected, reject_reason, supplier_lot,
      expiry_date, unit_price)
    values (v, pl.id, pr.id, v_ok, v_rej, nullif(trim(app.jtext(l, 'reject_reason')), ''), app.jtext(l, 'supplier_lot'),
      (app.jtext(l, 'expiry_date'))::date, pl.unit_price);
    if v_ok > 0 then
      perform app.apply_receipt_cost(pr.id, v_ok, pl.unit_price);
      perform app.stock_move('purchase_receipt', pr.id, v_ok, null, po.location_id, 'goods_receipt', v, v_no, 'available', null, null,
        pl.unit_price);
      if pr.item_type = 'finished_good' then v_fg := v_fg + round(v_ok * pl.unit_price, 2);
      else v_raw := v_raw + round(v_ok * pl.unit_price, 2); end if;
    end if;
    update public.purchase_order_lines set qty_received = qty_received + v_ok, qty_rejected = qty_rejected + v_rej where id = pl.id;
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Enter what arrived' using errcode = '22023'; end if;

  if v_raw + v_fg > 0 then
    perform app.post_event('purchase.receipt', jsonb_build_object('raw', v_raw, 'finished', v_fg, 'total', v_raw + v_fg), app.today(),
      format('Goods received %s on %s', v_no, po.po_no), 'goods_receipt', v, po.location_id, 'supplier', po.supplier_id);
  end if;
  select count(*) into v_open from public.purchase_order_lines where po_id = po.id and qty_received < qty_ordered;
  update public.purchase_orders set status = case when v_open = 0 then 'received' else 'partially_received' end where id = po.id;

  v_res := jsonb_build_object('grn_id', v, 'grn_no', v_no, 'value', v_raw + v_fg, 'complete', v_open = 0);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- Supplier invoices with 3-way match
--   p: {supplier_invoice_no, invoice_date, due_date, lines: [{po_line_id, qty, unit_price, tax_rate?}]}
-- ---------------------------------------------------------------------
create or replace function app.post_supplier_invoice(p_inv uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare i public.supplier_invoices; v_grni numeric; v_var numeric; v_je uuid;
begin
  select * into i from public.supplier_invoices where id = p_inv;
  select coalesce(sum(round(qty * po_price, 2)), 0) into v_grni from public.supplier_invoice_lines where invoice_id = p_inv;
  v_var := i.subtotal - v_grni;
  v_je := app.post_event('purchase.invoice', jsonb_build_object('grni', v_grni, 'ppv_dr', greatest(v_var, 0), 'ppv_cr', greatest(-v_var, 0),
            'vat', i.tax_total, 'total', i.total), i.invoice_date,
          format('Supplier invoice %s (%s)', i.supplier_invoice_no, i.ref_no), 'supplier_invoice', i.id, null, 'supplier', i.supplier_id);
  update public.supplier_invoices set journal_entry_id = v_je where id = p_inv;
  return v_je;
end $$;

create or replace function public.record_supplier_invoice(p_po uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; po public.purchase_orders; s public.suppliers; pl public.purchase_order_lines; pr public.products; l jsonb;
  v uuid := gen_random_uuid(); v_no text; v_qty numeric; v_price numeric; v_rate numeric; calc record; v_ok boolean; v_note text;
  v_notes text[] := '{}'; v_tol numeric; v_net numeric := 0; v_tax numeric := 0; v_total numeric := 0; n integer := 0;
  v_date date := coalesce((app.jtext(p, 'invoice_date'))::date, app.today()); v_res jsonb; v_status text;
begin
  if not (app.has_permission('procurement.manage') or app.has_permission('payments.manage')) then
    raise exception 'Permission denied: procurement.manage or payments.manage is required' using errcode = '42501';
  end if;
  if nullif(trim(app.jtext(p, 'supplier_invoice_no')), '') is null then raise exception 'Enter the supplier''s invoice number' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'record_supplier_invoice');
  if v_done is not null then return v_done; end if;
  select * into po from public.purchase_orders where id = p_po for update;
  if not found then raise exception 'Purchase order not found' using errcode = 'P0002'; end if;
  if po.status in ('pending_approval','cancelled') then raise exception 'This order is not approved' using errcode = '22023'; end if;
  select * into s from public.suppliers where id = po.supplier_id;
  if exists (select 1 from public.supplier_invoices where supplier_id = s.id and lower(supplier_invoice_no) = lower(trim(app.jtext(p, 'supplier_invoice_no')))
               and status <> 'void') then
    raise exception 'Invoice % from % is already recorded', trim(app.jtext(p, 'supplier_invoice_no')), s.name using errcode = '23505';
  end if;
  v_tol := coalesce((app.get_setting('procurement.price_tolerance_percent') #>> '{}')::numeric, 0);
  perform app.set_context(null, p_client_txn_id, 'supplier_invoice');
  v_no := app.next_document_number('SIN');
  insert into public.supplier_invoices (id, ref_no, supplier_id, supplier_invoice_no, po_id, invoice_date, due_date, subtotal, tax_total,
    total, status, match_status, created_by, client_txn_id)
  values (v, v_no, s.id, trim(app.jtext(p, 'supplier_invoice_no')), po.id, v_date,
    coalesce((app.jtext(p, 'due_date'))::date, v_date + s.payment_terms_days), 0, 0, 0, 'on_hold', 'mismatch',
    app.current_user_id(), p_client_txn_id);

  for l in select * from jsonb_array_elements(coalesce(p -> 'lines', '[]')) loop
    v_qty := coalesce(app.jnum(l, 'qty'), 0);
    continue when v_qty <= 0;
    select * into pl from public.purchase_order_lines where id = app.juuid(l, 'po_line_id') and po_id = po.id for update;
    if not found then raise exception 'Line is not on this order' using errcode = 'P0002'; end if;
    select * into pr from public.products where id = pl.product_id;
    v_price := coalesce(app.jnum(l, 'unit_price'), pl.unit_price);
    v_rate := coalesce(app.jnum(l, 'tax_rate'), pl.tax_rate);
    select * into calc from app.calc_line(v_qty, v_price, 0, v_rate, false);
    v_ok := true; v_note := null;
    if pl.qty_invoiced + v_qty > pl.qty_received then
      v_ok := false;
      v_note := format('%s: billed %s but only %s received and not yet billed', pr.name, v_qty::numeric(14,0),
                       (pl.qty_received - pl.qty_invoiced)::numeric(14,0));
    elsif abs(v_price - pl.unit_price) > pl.unit_price * v_tol / 100 then
      v_ok := false;
      v_note := format('%s: price %s differs from the order price %s', pr.name, round(v_price, 2), round(pl.unit_price, 2));
    elsif v_rate <> pl.tax_rate then
      v_ok := false;
      v_note := format('%s: VAT %s%% differs from the order (%s%%)', pr.name, v_rate, pl.tax_rate);
    end if;
    if v_note is not null then v_notes := v_notes || v_note; end if;
    insert into public.supplier_invoice_lines (invoice_id, po_line_id, product_id, qty, unit_price, po_price, tax_rate, net, tax, total,
      match_ok, match_note)
    values (v, pl.id, pr.id, v_qty, v_price, pl.unit_price, v_rate, calc.net, calc.tax, calc.total, v_ok, v_note);
    update public.purchase_order_lines set qty_invoiced = qty_invoiced + v_qty where id = pl.id;
    v_net := v_net + calc.net; v_tax := v_tax + calc.tax; v_total := v_total + calc.total; n := n + 1;
  end loop;
  if n = 0 then raise exception 'Add the invoiced lines' using errcode = '22023'; end if;

  v_status := case when cardinality(v_notes) = 0 then 'approved' else 'on_hold' end;
  update public.supplier_invoices set subtotal = v_net, tax_total = v_tax, total = v_total, status = v_status,
         match_status = case when cardinality(v_notes) = 0 then 'matched' else 'mismatch' end, match_notes = v_notes,
         approved_at = case when v_status = 'approved' then now() end
   where id = v;
  if v_status = 'approved' then perform app.post_supplier_invoice(v); end if;

  v_res := jsonb_build_object('invoice_id', v, 'ref_no', v_no, 'total', v_total, 'status', v_status, 'mismatches', to_jsonb(v_notes));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.decide_supplier_invoice(p_inv uuid, p_approve boolean, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare i public.supplier_invoices;
begin
  perform app.require_permission('procurement.approve');
  if nullif(trim(p_note), '') is null then raise exception 'Give a reason' using errcode = '22023'; end if;
  select * into i from public.supplier_invoices where id = p_inv for update;
  if not found then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if i.status <> 'on_hold' then raise exception 'Only an invoice on hold can be decided here' using errcode = '22023'; end if;
  if p_approve then
    perform app.set_context(trim(p_note), null, 'approve_mismatch');
    update public.supplier_invoices set status = 'approved', match_status = 'override', approved_at = now(),
           approved_by = app.current_user_id(), decision_note = trim(p_note) where id = p_inv;
    perform app.post_supplier_invoice(p_inv);
  else
    perform app.set_context(trim(p_note), null, 'void');
    update public.purchase_order_lines pl set qty_invoiced = pl.qty_invoiced - x.qty
      from (select po_line_id, sum(qty) qty from public.supplier_invoice_lines where invoice_id = p_inv group by po_line_id) x
     where pl.id = x.po_line_id;
    update public.supplier_invoices set status = 'void', decision_note = trim(p_note) where id = p_inv;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Supplier payments
--   p: {supplier_id, method, amount, reference, notes, allocations: [{invoice_id, amount}]}
--   No allocations given → oldest approved invoices first.
-- ---------------------------------------------------------------------
create or replace function public.record_supplier_payment(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; s public.suppliers; v uuid := gen_random_uuid(); v_no text; v_amt numeric := app.jnum(p, 'amount');
  v_left numeric; i public.supplier_invoices; a jsonb; v_take numeric; v_method text := app.jtext(p, 'method'); v_je uuid; v_res jsonb;
begin
  perform app.require_permission('payments.manage');
  if coalesce(v_amt, 0) <= 0 then raise exception 'Enter the amount paid' using errcode = '22023'; end if;
  if v_method not in ('cash','bank_transfer','cheque') then raise exception 'Choose how it was paid' using errcode = '22023'; end if;
  if v_method <> 'cash' and nullif(trim(app.jtext(p, 'reference')), '') is null then
    raise exception 'Enter the bank reference or cheque number' using errcode = '22023';
  end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'record_supplier_payment');
  if v_done is not null then return v_done; end if;
  select * into s from public.suppliers where id = app.juuid(p, 'supplier_id');
  if not found then raise exception 'Choose a supplier' using errcode = '22023'; end if;
  perform app.set_context(app.jtext(p, 'notes'), p_client_txn_id, 'supplier_payment');
  v_no := app.next_document_number('SPY');
  insert into public.supplier_payments (id, payment_no, supplier_id, method, amount, unallocated, reference, notes, created_by, client_txn_id)
  values (v, v_no, s.id, v_method, v_amt, v_amt, nullif(trim(app.jtext(p, 'reference')), ''), app.jtext(p, 'notes'),
          app.current_user_id(), p_client_txn_id);
  v_left := v_amt;

  if jsonb_array_length(coalesce(p -> 'allocations', '[]')) > 0 then
    for a in select * from jsonb_array_elements(p -> 'allocations') loop
      continue when coalesce(app.jnum(a, 'amount'), 0) <= 0;
      select * into i from public.supplier_invoices where id = app.juuid(a, 'invoice_id') and supplier_id = s.id for update;
      if not found or i.status not in ('approved','partially_paid') then raise exception 'Invoice is not open for payment' using errcode = '22023'; end if;
      if app.jnum(a, 'amount') > i.total - i.amount_paid then
        raise exception 'Payment to % is more than its balance', i.supplier_invoice_no using errcode = '22023';
      end if;
      if app.jnum(a, 'amount') > v_left then
        raise exception 'The amounts given to invoices add up to more than the payment' using errcode = '22023';
      end if;
      v_take := app.jnum(a, 'amount');
      if v_take > 0 then
        insert into public.supplier_payment_allocations (payment_id, invoice_id, amount) values (v, i.id, v_take);
        update public.supplier_invoices set amount_paid = amount_paid + v_take,
               status = case when amount_paid + v_take >= total then 'paid' else 'partially_paid' end where id = i.id;
        v_left := v_left - v_take;
      end if;
    end loop;
    -- anything not allocated is kept as an advance to the supplier
  else
    for i in select * from public.supplier_invoices where supplier_id = s.id and status in ('approved','partially_paid')
              order by due_date, invoice_date, ref_no for update loop
      exit when v_left <= 0;
      v_take := least(i.total - i.amount_paid, v_left);
      insert into public.supplier_payment_allocations (payment_id, invoice_id, amount) values (v, i.id, v_take);
      update public.supplier_invoices set amount_paid = amount_paid + v_take,
             status = case when amount_paid + v_take >= total then 'paid' else 'partially_paid' end where id = i.id;
      v_left := v_left - v_take;
    end loop;
  end if;

  v_je := app.post_event('supplier.payment', jsonb_build_object('amount', v_amt,
            'bank', case when v_method = 'cash' then 0 else v_amt end, 'cash', case when v_method = 'cash' then v_amt else 0 end),
          app.today(), format('Payment %s to %s', v_no, s.name), 'supplier_payment', v, null, 'supplier', s.id);
  update public.supplier_payments set unallocated = v_left, journal_entry_id = v_je where id = v;

  v_res := jsonb_build_object('payment_id', v, 'payment_no', v_no, 'unallocated', v_left, 'outstanding', app.supplier_outstanding(s.id));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.suppliers                    enable row level security;
alter table public.supplier_items               enable row level security;
alter table public.purchase_requests            enable row level security;
alter table public.purchase_request_items       enable row level security;
alter table public.purchase_orders              enable row level security;
alter table public.purchase_order_lines         enable row level security;
alter table public.goods_receipts               enable row level security;
alter table public.goods_receipt_lines          enable row level security;
alter table public.supplier_invoices            enable row level security;
alter table public.supplier_invoice_lines       enable row level security;
alter table public.supplier_payments            enable row level security;
alter table public.supplier_payment_allocations enable row level security;

create policy suppliers_read on public.suppliers for select to authenticated
  using (app.has_permission('procurement.view') or app.has_permission('suppliers.manage') or app.has_permission('payments.view'));
create policy supplier_items_read on public.supplier_items for select to authenticated
  using (app.has_permission('procurement.view') or app.has_permission('suppliers.manage'));
create policy purchase_requests_read on public.purchase_requests for select to authenticated
  using (app.has_permission('procurement.view') or requested_by = app.current_user_id());
create policy purchase_request_items_read on public.purchase_request_items for select to authenticated
  using (exists (select 1 from public.purchase_requests r where r.id = request_id));
create policy purchase_orders_read on public.purchase_orders for select to authenticated
  using (app.has_permission('procurement.view') or app.has_permission('inventory.manage') or app.has_permission('payments.view'));
create policy purchase_order_lines_read on public.purchase_order_lines for select to authenticated
  using (exists (select 1 from public.purchase_orders o where o.id = po_id));
create policy goods_receipts_read on public.goods_receipts for select to authenticated
  using (app.has_permission('procurement.view') or app.has_permission('inventory.view') or app.has_permission('payments.view'));
create policy goods_receipt_lines_read on public.goods_receipt_lines for select to authenticated
  using (exists (select 1 from public.goods_receipts g where g.id = grn_id));
create policy supplier_invoices_read on public.supplier_invoices for select to authenticated
  using (app.has_permission('procurement.view') or app.has_permission('payments.view'));
create policy supplier_invoice_lines_read on public.supplier_invoice_lines for select to authenticated
  using (exists (select 1 from public.supplier_invoices i where i.id = invoice_id));
create policy supplier_payments_read on public.supplier_payments for select to authenticated
  using (app.has_permission('payments.view') or app.has_permission('procurement.view'));
create policy supplier_payment_allocations_read on public.supplier_payment_allocations for select to authenticated
  using (exists (select 1 from public.supplier_payments x where x.id = payment_id));
revoke insert, update, delete, truncate on public.goods_receipts, public.goods_receipt_lines from anon, authenticated, service_role;
