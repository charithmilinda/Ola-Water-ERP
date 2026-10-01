-- =====================================================================
-- OLA Water ERP — Phase 1A
-- 0011: orders, recurring orders, invoices, payments
-- =====================================================================

-- post_event must tolerate events whose amounts are all zero
create or replace function app.post_event(
  p_event_type     text,
  p_amounts        jsonb,
  p_entry_date     date,
  p_description    text,
  p_source_type    text default null,
  p_source_id      uuid default null,
  p_location_id    uuid default null,
  p_party_type     text default null,
  p_party_id       uuid default null,
  p_client_txn_id  uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_effective date;
  v_rule      public.posting_rules;
  v_amount    numeric(16,2);
  v_lines     jsonb := '[]'::jsonb;
begin
  select max(effective_from) into v_effective
    from public.posting_rules
   where event_type = p_event_type and effective_from <= p_entry_date;
  if v_effective is null then
    raise exception 'No posting rules are configured for event %', p_event_type using errcode = 'P0002';
  end if;

  for v_rule in
    select * from public.posting_rules
     where event_type = p_event_type and effective_from = v_effective
     order by line_no
  loop
    if not (p_amounts ? v_rule.amount_key) then
      raise exception 'Event % requires amount "%"', p_event_type, v_rule.amount_key using errcode = '22023';
    end if;
    v_amount := round((p_amounts ->> v_rule.amount_key)::numeric, 2);
    if v_amount < 0 then
      raise exception 'Amount "%" cannot be negative', v_rule.amount_key using errcode = '22023';
    end if;
    continue when v_amount = 0;

    v_lines := v_lines || jsonb_build_object(
      'account_key', v_rule.account_key,
      'debit',  case when v_rule.side = 'debit'  then v_amount else 0 end,
      'credit', case when v_rule.side = 'credit' then v_amount else 0 end,
      'memo', v_rule.description,
      'party_type', p_party_type,
      'party_id', p_party_id
    );
  end loop;

  if jsonb_array_length(v_lines) = 0 then
    return null;  -- nothing to post (all amounts zero)
  end if;

  return app.post_journal(
    p_entry_date, p_description, p_event_type, v_lines,
    p_source_type, p_source_id, p_location_id, null, p_client_txn_id
  );
end;
$$;

-- Line arithmetic: prices may include tax (Sri Lankan retail style) or not
create or replace function app.calc_line(p_qty numeric, p_price numeric, p_discount numeric, p_rate numeric, p_includes boolean,
  out net numeric, out tax numeric, out total numeric)
language plpgsql immutable set search_path = '' as $$
declare v_gross numeric := round(p_qty * p_price - coalesce(p_discount, 0), 2);
begin
  if v_gross < 0 then raise exception 'Discount is larger than the line value' using errcode = '22023'; end if;
  if p_includes then
    total := v_gross;
    tax := round(v_gross * p_rate / (100 + p_rate), 2);
    net := total - tax;
  else
    net := v_gross;
    tax := round(v_gross * p_rate / 100, 2);
    total := net + tax;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Orders
-- ---------------------------------------------------------------------
create table public.orders (
  id                   uuid primary key default gen_random_uuid(),
  order_no             text not null unique,
  customer_id          uuid not null references public.customers(id),
  address_id           uuid references public.customer_addresses(id),
  source               text not null default 'phone' check (source in ('phone','staff','sales_rep','recurring','walk_in','distributor','shop')),
  status               text not null default 'draft' check (status in
                         ('draft','on_hold','confirmed','assigned','loaded','out_for_delivery','delivered','partially_delivered','failed','cancelled')),
  requested_date       date not null,
  time_window          text,
  route_id             uuid references public.routes(id),
  price_list_id        uuid not null references public.price_lists(id),
  prices_include_tax   boolean not null,
  subtotal_net         numeric(14,2) not null default 0,
  discount_total       numeric(14,2) not null default 0,
  tax_total            numeric(14,2) not null default 0,
  delivery_charge      numeric(14,2) not null default 0 check (delivery_charge >= 0),
  total                numeric(14,2) not null default 0,
  expected_ola_returns integer not null default 0 check (expected_ola_returns >= 0),
  hold_reason          text,
  notes                text,
  recurring_order_id   uuid,
  cancel_reason        text,
  created_at           timestamptz not null default now(),
  created_by           uuid,
  confirmed_at         timestamptz,
  confirmed_by         uuid,
  updated_at           timestamptz not null default now(),
  client_txn_id        uuid unique
);
create index orders_customer_idx on public.orders (customer_id, created_at desc);
create index orders_date_idx on public.orders (requested_date, status);
create unique index orders_recurring_once on public.orders (recurring_order_id, requested_date) where recurring_order_id is not null;

create table public.order_items (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid not null references public.orders(id),
  line_no        integer not null,
  product_id     uuid not null references public.products(id),
  qty            numeric(12,3) not null check (qty > 0),
  unit_price     numeric(12,2) not null check (unit_price >= 0),
  discount       numeric(12,2) not null default 0 check (discount >= 0),
  tax_code       text references public.tax_codes(code),
  tax_rate       numeric(6,3) not null default 0,
  line_net       numeric(14,2) not null,
  line_tax       numeric(14,2) not null,
  line_total     numeric(14,2) not null,
  delivered_qty  numeric(12,3) not null default 0,
  unique (order_id, line_no)
);

create trigger orders_touch before update on public.orders for each row execute function app.touch_updated_at();
create trigger orders_audit after insert or update on public.orders for each row execute function app.audit_row('orders');
create trigger order_items_audit after insert or update or delete on public.order_items for each row execute function app.audit_row('orders');

-- ---------------------------------------------------------------------
-- Recurring orders
-- ---------------------------------------------------------------------
create table public.recurring_orders (
  id             uuid primary key default gen_random_uuid(),
  customer_id    uuid not null references public.customers(id),
  address_id     uuid references public.customer_addresses(id),
  frequency      text not null check (frequency in ('daily','alternate_days','weekly','monthly','every_n_days')),
  interval_days  integer check (interval_days between 1 and 90),
  weekdays       integer[] check (weekdays <@ array[1,2,3,4,5,6,7]),
  day_of_month   integer check (day_of_month between 1 and 28),
  start_date     date not null,
  end_date       date,
  next_date      date not null,
  expected_ola_returns integer not null default 0,
  status         text not null default 'active' check (status in ('active','paused','cancelled')),
  notes          text,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now()
);
create table public.recurring_order_items (
  id                  uuid primary key default gen_random_uuid(),
  recurring_order_id  uuid not null references public.recurring_orders(id),
  product_id          uuid not null references public.products(id),
  qty                 numeric(12,3) not null check (qty > 0)
);
alter table public.orders add constraint orders_recurring_fk foreign key (recurring_order_id) references public.recurring_orders(id);
create trigger recurring_orders_touch before update on public.recurring_orders for each row execute function app.touch_updated_at();
create trigger recurring_orders_audit after insert or update on public.recurring_orders for each row execute function app.audit_row('orders');
create trigger recurring_order_items_audit after insert or update or delete on public.recurring_order_items for each row execute function app.audit_row('orders');

create or replace function app.next_occurrence(r public.recurring_orders, p_after date)
returns date language plpgsql stable set search_path = '' as $$
declare d date := p_after + 1; i integer;
begin
  case r.frequency
    when 'daily' then return d;
    when 'alternate_days' then return p_after + 2;
    when 'every_n_days' then return p_after + coalesce(r.interval_days, 1);
    when 'weekly' then
      for i in 0..6 loop
        if extract(isodow from d + i)::integer = any (coalesce(r.weekdays, array[extract(isodow from r.start_date)::integer])) then
          return d + i;
        end if;
      end loop;
      return d + 6;
    when 'monthly' then
      d := make_date(extract(year from p_after)::integer, extract(month from p_after)::integer, coalesce(r.day_of_month, 1));
      if d <= p_after then d := (d + interval '1 month')::date; end if;
      return d;
  end case;
  return d;
end $$;

-- ---------------------------------------------------------------------
-- Invoices and payments
-- ---------------------------------------------------------------------
create table public.invoices (
  id               uuid primary key default gen_random_uuid(),
  invoice_no       text not null unique,
  customer_id      uuid not null references public.customers(id),
  order_id         uuid references public.orders(id),
  delivery_id      uuid,
  run_id           uuid,
  location_id      uuid references public.locations(id),
  invoice_date     date not null,
  due_date         date not null,
  is_tax_invoice   boolean not null default false,
  subtotal_net     numeric(14,2) not null default 0,
  tax_total        numeric(14,2) not null default 0,
  deposit_net      numeric(14,2) not null default 0,
  other_charges    numeric(14,2) not null default 0,
  total            numeric(14,2) not null,
  amount_paid      numeric(14,2) not null default 0,
  balance          numeric(14,2) generated always as (total - amount_paid) stored,
  status           text not null default 'open' check (status in ('open','partially_paid','paid','credit','void')),
  journal_entry_id uuid references public.journal_entries(id),
  print_count      integer not null default 0,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  client_txn_id    uuid unique
);
create index invoices_customer_idx on public.invoices (customer_id, invoice_date desc);
create index invoices_open_idx on public.invoices (customer_id) where status in ('open','partially_paid');

create table public.invoice_lines (
  id              uuid primary key default gen_random_uuid(),
  invoice_id      uuid not null references public.invoices(id),
  line_no         integer not null,
  line_type       text not null check (line_type in ('product','deposit','deposit_refund','bottle_charge','delivery_charge')),
  product_id      uuid references public.products(id),
  bottle_type_id  uuid references public.bottle_types(id),
  description     text not null,
  qty             numeric(12,3) not null,
  unit_price      numeric(12,2) not null,
  discount        numeric(12,2) not null default 0,
  tax_rate        numeric(6,3) not null default 0,
  net             numeric(14,2) not null,
  tax             numeric(14,2) not null default 0,
  total           numeric(14,2) not null,
  unique (invoice_id, line_no)
);
create trigger invoice_lines_append_only before update or delete on public.invoice_lines
  for each row execute function app.forbid_change();
create trigger invoices_no_delete before delete on public.invoices
  for each row execute function app.forbid_change();
create trigger invoices_audit after insert or update on public.invoices for each row execute function app.audit_row('sales');

create table public.payments (
  id               uuid primary key default gen_random_uuid(),
  payment_no       text not null unique,
  customer_id      uuid not null references public.customers(id),
  method           text not null check (method in ('cash','card','qr','bank_transfer','cheque')),
  amount           numeric(14,2) not null check (amount > 0),
  reference        text,
  run_id           uuid,
  delivery_id      uuid,
  received_at      timestamptz not null default now(),
  received_by      uuid,
  unallocated      numeric(14,2) not null default 0 check (unallocated >= 0),
  status           text not null default 'received' check (status in ('received','reversed')),
  journal_entry_id uuid references public.journal_entries(id),
  notes            text,
  client_txn_id    uuid unique
);
create index payments_customer_idx on public.payments (customer_id, received_at desc);
create index payments_run_idx on public.payments (run_id);
create trigger payments_no_delete before delete on public.payments for each row execute function app.forbid_change();
create trigger payments_audit after insert or update on public.payments for each row execute function app.audit_row('payments');

create table public.payment_allocations (
  id          bigint generated always as identity primary key,
  payment_id  uuid not null references public.payments(id),
  invoice_id  uuid not null references public.invoices(id),
  amount      numeric(14,2) not null check (amount > 0),
  created_at  timestamptz not null default now()
);
create index payment_allocations_invoice_idx on public.payment_allocations (invoice_id);
create trigger payment_allocations_append_only before update or delete on public.payment_allocations
  for each row execute function app.forbid_change();

create or replace function app.refresh_invoice_status(p_invoice uuid)
returns void language sql security definer set search_path = '' as $$
  update public.invoices i set
    amount_paid = coalesce((select sum(amount) from public.payment_allocations where invoice_id = i.id), 0),
    status = case
      when i.status = 'void' then 'void'
      when i.total <= 0 then 'credit'
      when coalesce((select sum(amount) from public.payment_allocations where invoice_id = i.id), 0) >= i.total then 'paid'
      when coalesce((select sum(amount) from public.payment_allocations where invoice_id = i.id), 0) > 0 then 'partially_paid'
      else 'open' end
  where i.id = p_invoice
$$;

-- Apply a payment's unallocated amount: the named invoice first, then oldest open invoices.
create or replace function app.allocate_payment(p_payment uuid, p_first_invoice uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare pay public.payments; inv record; v_left numeric; v_apply numeric;
begin
  select * into pay from public.payments where id = p_payment for update;
  v_left := pay.unallocated;
  for inv in
    select id, balance from public.invoices
     where customer_id = pay.customer_id and status in ('open','partially_paid') and balance > 0
     order by (id = p_first_invoice) desc, invoice_date, created_at
     for update
  loop
    exit when v_left <= 0;
    v_apply := least(v_left, inv.balance);
    insert into public.payment_allocations (payment_id, invoice_id, amount) values (p_payment, inv.id, v_apply);
    perform app.refresh_invoice_status(inv.id);
    v_left := v_left - v_apply;
  end loop;
  update public.payments set unallocated = v_left where id = p_payment;
end $$;

-- Customer money position
create or replace function app.customer_outstanding(p_customer uuid)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce((select sum(total) from public.invoices where customer_id = p_customer and status <> 'void'), 0)
       - coalesce((select sum(amount) from public.payments where customer_id = p_customer and status = 'received'), 0)
$$;

create or replace function app.customer_overdue(p_customer uuid)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(sum(balance), 0) from public.invoices
   where customer_id = p_customer and status in ('open','partially_paid') and due_date < app.today()
$$;

-- OLA bottles a customer holds (all types)
create or replace function app.customer_ola_bottles(p_customer uuid, p_type uuid default null)
returns integer language sql stable security definer set search_path = '' as $$
  select coalesce(sum(qty), 0)::integer from public.bottle_balances
   where holder_type = 'customer' and holder_id = p_customer and company_id = app.own_company_id()
     and (p_type is null or bottle_type_id = p_type)
$$;

-- =====================================================================
-- Order RPCs
-- =====================================================================

-- Recalculate an order's lines and totals from its items
create or replace function app.recalc_order(p_order uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.orders; it record; c record; v_rate numeric; v_net numeric := 0; v_tax numeric := 0; v_tot numeric := 0; v_disc numeric := 0;
begin
  select * into o from public.orders where id = p_order;
  for it in select oi.*, p.tax_code as ptax from public.order_items oi join public.products p on p.id = oi.product_id
             where oi.order_id = p_order loop
    v_rate := app.tax_rate(it.ptax, o.requested_date);
    select * into c from app.calc_line(it.qty, it.unit_price, it.discount, v_rate, o.prices_include_tax);
    update public.order_items set tax_code = it.ptax, tax_rate = v_rate, line_net = c.net, line_tax = c.tax, line_total = c.total
     where id = it.id;
    v_net := v_net + c.net; v_tax := v_tax + c.tax; v_tot := v_tot + c.total; v_disc := v_disc + it.discount;
  end loop;
  update public.orders set subtotal_net = v_net, tax_total = v_tax, discount_total = v_disc,
         total = v_tot + delivery_charge
   where id = p_order;
end $$;

-- Create or edit an order (draft / on hold / confirmed, not yet dispatched)
-- p: customer_id, address_id, requested_date, time_window, source, notes, delivery_charge,
--    expected_ola_returns, items: [{product_id, qty, discount}]
create or replace function public.save_order(p_id uuid, p jsonb, p_confirm boolean, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; v uuid; c public.customers; o public.orders; it jsonb; n integer := 0; v_price numeric;
  v_disc_limit numeric; v_line_gross numeric; v_res jsonb; v_addr uuid; v_include boolean;
begin
  perform app.require_permission('orders.manage');
  if p_id is null then
    v_done := app.idempotency_begin(p_client_txn_id, 'save_order');
    if v_done is not null then return v_done; end if;
  end if;
  perform app.set_context(null, p_client_txn_id, null);

  select * into c from public.customers where id = app.juuid(p, 'customer_id');
  if not found then raise exception 'Choose a customer' using errcode = '22023'; end if;
  if c.status = 'inactive' then raise exception 'Customer % is inactive', c.name using errcode = '22023'; end if;
  if jsonb_array_length(coalesce(p -> 'items', '[]')) = 0 then raise exception 'Add at least one product' using errcode = '22023'; end if;

  v_addr := coalesce(app.juuid(p, 'address_id'),
                     (select id from public.customer_addresses where customer_id = c.id and is_default and is_active));
  select prices_include_tax into v_include from public.price_lists where id = c.price_list_id;

  if p_id is null then
    insert into public.orders (order_no, customer_id, address_id, source, requested_date, time_window, route_id, price_list_id,
      prices_include_tax, delivery_charge, expected_ola_returns, notes, created_by, client_txn_id)
    values (app.next_document_number('ORD'), c.id, v_addr, coalesce(app.jtext(p, 'source'), 'phone'),
      coalesce((app.jtext(p, 'requested_date'))::date, app.today()), app.jtext(p, 'time_window'), c.route_id, c.price_list_id,
      v_include, coalesce(app.jnum(p, 'delivery_charge'), 0), coalesce(app.jint(p, 'expected_ola_returns'), 0),
      app.jtext(p, 'notes'), app.current_user_id(), p_client_txn_id)
    returning id into v;
  else
    select * into o from public.orders where id = p_id for update;
    if not found then raise exception 'Order not found' using errcode = 'P0002'; end if;
    if o.status not in ('draft','on_hold','confirmed') then
      raise exception 'Order % is already % and cannot be edited', o.order_no, replace(o.status, '_', ' ') using errcode = '22023';
    end if;
    update public.orders set address_id = v_addr, requested_date = coalesce((app.jtext(p, 'requested_date'))::date, requested_date),
           time_window = app.jtext(p, 'time_window'), delivery_charge = coalesce(app.jnum(p, 'delivery_charge'), 0),
           expected_ola_returns = coalesce(app.jint(p, 'expected_ola_returns'), 0), notes = app.jtext(p, 'notes'),
           status = 'draft', hold_reason = null
     where id = p_id;
    perform set_config('app.audit_action', 'remove_line', true);
    delete from public.order_items where order_id = p_id;
    perform set_config('app.audit_action', '', true);
    v := p_id;
  end if;

  v_disc_limit := coalesce((app.get_setting('approvals.discount_percent') #>> '{}')::numeric, 0);
  for it in select * from jsonb_array_elements(p -> 'items') loop
    continue when coalesce(app.jnum(it, 'qty'), 0) <= 0;
    n := n + 1;
    v_price := app.unit_price(app.juuid(it, 'product_id'), c.price_list_id, coalesce((app.jtext(p, 'requested_date'))::date, app.today()));
    v_line_gross := app.jnum(it, 'qty') * v_price;
    if coalesce(app.jnum(it, 'discount'), 0) > 0 and v_line_gross > 0
       and app.jnum(it, 'discount') / v_line_gross * 100 > v_disc_limit and not app.has_permission('pos.discount') then
      raise exception 'Discounts above % need a Sales Manager (pos.discount)', v_disc_limit || '%' using errcode = '42501';
    end if;
    insert into public.order_items (order_id, line_no, product_id, qty, unit_price, discount, line_net, line_tax, line_total)
    values (v, n, app.juuid(it, 'product_id'), app.jnum(it, 'qty'), v_price, coalesce(app.jnum(it, 'discount'), 0), 0, 0, 0);
  end loop;
  if n = 0 then raise exception 'Add at least one product with a quantity' using errcode = '22023'; end if;
  perform app.recalc_order(v);

  if coalesce(p_confirm, false) then
    perform public.confirm_order(v);
  end if;

  select jsonb_build_object('order_id', id, 'order_no', order_no, 'status', status, 'hold_reason', hold_reason, 'total', total)
    into v_res from public.orders where id = v;
  if p_id is null then perform app.idempotency_finish(p_client_txn_id, v_res); end if;
  return v_res;
end $$;

-- Confirm: checks credit limit, overdue balance and bottle limit. A breach
-- puts the order on hold for someone with customers.credit to release.
create or replace function public.confirm_order(p_order uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o public.orders; c public.customers; v_out numeric; v_overdue numeric; v_reasons text[] := '{}'; v_net_bottles integer; v_status text;
begin
  perform app.require_permission('orders.manage');
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'Order not found' using errcode = 'P0002'; end if;
  if o.status not in ('draft','on_hold') then raise exception 'Order % is already %', o.order_no, replace(o.status, '_', ' ') using errcode = '22023'; end if;
  select * into c from public.customers where id = o.customer_id;

  if c.status = 'on_hold' then v_reasons := v_reasons || 'Customer account is on hold'; end if;
  v_overdue := app.customer_overdue(c.id);
  if v_overdue > 0 then v_reasons := v_reasons || format('Overdue balance Rs. %s', to_char(v_overdue, 'FM999,999,990.00')); end if;
  v_out := app.customer_outstanding(c.id);
  if c.credit_limit > 0 and v_out + o.total > c.credit_limit then
    v_reasons := v_reasons || format('Credit limit Rs. %s would be exceeded (outstanding Rs. %s)',
      to_char(c.credit_limit, 'FM999,999,990.00'), to_char(v_out, 'FM999,999,990.00'));
  end if;
  if c.bottle_model = 'loan' then
    select coalesce(sum(oi.qty), 0)::integer - o.expected_ola_returns into v_net_bottles
      from public.order_items oi join public.products p on p.id = oi.product_id
     where oi.order_id = o.id and p.is_returnable;
    if app.customer_ola_bottles(c.id) + v_net_bottles > c.allowed_bottles then
      v_reasons := v_reasons || format('Bottle limit %s would be exceeded (holds %s)', c.allowed_bottles, app.customer_ola_bottles(c.id));
    end if;
  end if;

  if array_length(v_reasons, 1) > 0 then
    v_status := 'on_hold';
    perform app.set_context(null, null, 'hold');
    update public.orders set status = 'on_hold', hold_reason = array_to_string(v_reasons, '; ') where id = o.id;
  else
    v_status := 'confirmed';
    perform app.set_context(null, null, 'confirm');
    update public.orders set status = 'confirmed', hold_reason = null, confirmed_at = now(), confirmed_by = app.current_user_id()
     where id = o.id;
  end if;
  perform set_config('app.audit_action', '', true);
  return jsonb_build_object('status', v_status, 'reasons', to_jsonb(v_reasons));
end $$;

create or replace function public.release_order_hold(p_order uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.orders;
begin
  perform app.require_permission('customers.credit');
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required to release a hold' using errcode = '22023'; end if;
  select * into o from public.orders where id = p_order for update;
  if o.status <> 'on_hold' then raise exception 'Order is not on hold' using errcode = '22023'; end if;
  perform app.set_context(trim(p_reason), null, 'approve');
  update public.orders set status = 'confirmed', confirmed_at = now(), confirmed_by = app.current_user_id() where id = p_order;
end $$;

-- (cancel_order is defined with deliveries, because assigned orders leave their run)

-- =====================================================================
-- Recurring order RPCs
-- =====================================================================
-- p: customer_id, address_id, frequency, interval_days, weekdays[], day_of_month, start_date, end_date,
--    expected_ola_returns, notes, items [{product_id, qty}]
create or replace function public.save_recurring_order(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; it jsonb; r public.recurring_orders; v_start date := coalesce((app.jtext(p, 'start_date'))::date, app.today() + 1);
begin
  perform app.require_permission('orders.manage');
  if jsonb_array_length(coalesce(p -> 'items', '[]')) = 0 then raise exception 'Add at least one product' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    insert into public.recurring_orders (customer_id, address_id, frequency, interval_days, weekdays, day_of_month, start_date,
      end_date, next_date, expected_ola_returns, notes, created_by)
    values (app.juuid(p, 'customer_id'), app.juuid(p, 'address_id'), app.jtext(p, 'frequency'), app.jint(p, 'interval_days'),
      (select array_agg(x::integer) from jsonb_array_elements_text(coalesce(p -> 'weekdays', '[]')) x),
      app.jint(p, 'day_of_month'), v_start, (app.jtext(p, 'end_date'))::date, v_start,
      coalesce(app.jint(p, 'expected_ola_returns'), 0), app.jtext(p, 'notes'), app.current_user_id())
    returning id into v;
    -- first occurrence on or after start
    select * into r from public.recurring_orders where id = v;
    if r.frequency in ('weekly','monthly') then
      update public.recurring_orders set next_date = app.next_occurrence(r, v_start - 1) where id = v;
    end if;
  else
    update public.recurring_orders set address_id = app.juuid(p, 'address_id'), frequency = app.jtext(p, 'frequency'),
      interval_days = app.jint(p, 'interval_days'),
      weekdays = (select array_agg(x::integer) from jsonb_array_elements_text(coalesce(p -> 'weekdays', '[]')) x),
      day_of_month = app.jint(p, 'day_of_month'), end_date = (app.jtext(p, 'end_date'))::date,
      expected_ola_returns = coalesce(app.jint(p, 'expected_ola_returns'), 0), notes = app.jtext(p, 'notes'),
      next_date = coalesce((app.jtext(p, 'next_date'))::date, next_date)
    where id = p_id returning id into v;
    if v is null then raise exception 'Recurring order not found' using errcode = 'P0002'; end if;
    delete from public.recurring_order_items where recurring_order_id = v;
  end if;
  for it in select * from jsonb_array_elements(p -> 'items') loop
    continue when coalesce(app.jnum(it, 'qty'), 0) <= 0;
    insert into public.recurring_order_items (recurring_order_id, product_id, qty) values (v, app.juuid(it, 'product_id'), app.jnum(it, 'qty'));
  end loop;
  return v;
end $$;

create or replace function public.set_recurring_status(p_id uuid, p_status text, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_permission('orders.manage');
  if p_status not in ('active','paused','cancelled') then raise exception 'Unknown status' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, case p_status when 'active' then 'resume' when 'paused' then 'pause' else 'cancel' end);
  update public.recurring_orders set status = p_status,
         next_date = case when p_status = 'active' and next_date < app.today() then app.today() else next_date end
   where id = p_id and status <> 'cancelled';
  if not found then raise exception 'Recurring order not found or already cancelled' using errcode = 'P0002'; end if;
end $$;

-- Skip the next delivery only
create or replace function public.skip_next_recurring(p_id uuid, p_reason text)
returns date language plpgsql security definer set search_path = '' as $$
declare r public.recurring_orders; v date;
begin
  perform app.require_permission('orders.manage');
  select * into r from public.recurring_orders where id = p_id for update;
  v := app.next_occurrence(r, r.next_date);
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Skipped one delivery'), null, 'skip');
  update public.recurring_orders set next_date = v where id = p_id;
  return v;
end $$;

-- Create orders for all due recurring schedules up to a date. Safe to run repeatedly.
create or replace function public.generate_recurring_orders(p_until date)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.recurring_orders; v_items jsonb; v_res jsonb; n integer := 0; v_held integer := 0; v_errors jsonb := '[]';
begin
  perform app.require_permission('orders.manage');
  if p_until > app.today() + 14 then raise exception 'Generate at most 14 days ahead' using errcode = '22023'; end if;
  for r in select * from public.recurring_orders where status = 'active' and next_date <= p_until order by next_date for update loop
    while r.next_date <= p_until and (r.end_date is null or r.next_date <= r.end_date) loop
      if not exists (select 1 from public.orders where recurring_order_id = r.id and requested_date = r.next_date) then
        select jsonb_agg(jsonb_build_object('product_id', product_id, 'qty', qty)) into v_items
          from public.recurring_order_items where recurring_order_id = r.id;
        begin
          v_res := public.save_order(null, jsonb_build_object(
            'customer_id', r.customer_id, 'address_id', r.address_id, 'requested_date', r.next_date, 'source', 'recurring',
            'expected_ola_returns', r.expected_ola_returns, 'notes', r.notes, 'items', v_items), true, gen_random_uuid());
          update public.orders set recurring_order_id = r.id where id = (v_res ->> 'order_id')::uuid;
          n := n + 1;
          if v_res ->> 'status' = 'on_hold' then v_held := v_held + 1; end if;
        exception when others then
          v_errors := v_errors || jsonb_build_object('customer', (select name from public.customers where id = r.customer_id), 'error', sqlerrm);
        end;
      end if;
      r.next_date := app.next_occurrence(r, r.next_date);
    end loop;
    update public.recurring_orders set next_date = r.next_date,
           status = case when r.end_date is not null and r.next_date > r.end_date then 'cancelled' else status end
     where id = r.id;
  end loop;
  return jsonb_build_object('created', n, 'on_hold', v_held, 'errors', v_errors);
end $$;

-- =====================================================================
-- Payments (office)
-- =====================================================================
create or replace function app.post_payment(p_payment uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare pay public.payments; v_event text; v_je uuid;
begin
  select * into pay from public.payments where id = p_payment;
  v_event := case
    when pay.method = 'cash' and pay.run_id is not null then 'payment.driver_cash'
    when pay.method = 'cash' then 'payment.cash'
    when pay.method in ('card','qr') then 'payment.card'
    when pay.method = 'bank_transfer' then 'payment.bank'
    when pay.method = 'cheque' then 'payment.cheque' end;
  v_je := app.post_event(v_event, jsonb_build_object('amount', pay.amount), app.today(),
    format('Payment %s (%s)', pay.payment_no, replace(pay.method, '_', ' ')), 'payment', pay.id, null, 'customer', pay.customer_id);
  update public.payments set journal_entry_id = v_je where id = p_payment;
end $$;

create or replace function app.create_payment(
  p_customer uuid, p_method text, p_amount numeric, p_reference text, p_run uuid, p_delivery uuid,
  p_first_invoice uuid, p_notes text, p_client_txn_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  if coalesce(p_amount, 0) <= 0 then raise exception 'Payment amount must be greater than zero' using errcode = '22023'; end if;
  if p_method in ('bank_transfer','cheque') and nullif(trim(p_reference), '') is null then
    raise exception 'Enter the % reference number', replace(p_method, '_', ' ') using errcode = '22023';
  end if;
  insert into public.payments (payment_no, customer_id, method, amount, reference, run_id, delivery_id, received_by, unallocated, notes, client_txn_id)
  values (app.next_document_number('PAY'), p_customer, p_method, round(p_amount, 2), nullif(trim(p_reference), ''), p_run, p_delivery,
          app.current_user_id(), round(p_amount, 2), nullif(trim(p_notes), ''), p_client_txn_id)
  returning id into v;
  perform app.post_payment(v);
  perform app.allocate_payment(v, p_first_invoice);
  return v;
end $$;

create or replace function public.record_payment(
  p_customer uuid, p_method text, p_amount numeric, p_reference text, p_invoice uuid, p_notes text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v uuid; v_res jsonb;
begin
  perform app.require_permission('payments.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'record_payment');
  if v_done is not null then return v_done; end if;
  perform app.set_context(null, p_client_txn_id, null);
  v := app.create_payment(p_customer, p_method, p_amount, p_reference, null, null, p_invoice, p_notes, p_client_txn_id);
  select jsonb_build_object('payment_id', id, 'payment_no', payment_no, 'unallocated', unallocated,
                            'outstanding', app.customer_outstanding(p_customer))
    into v_res from public.payments where id = v;
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.orders                enable row level security;
alter table public.order_items           enable row level security;
alter table public.recurring_orders      enable row level security;
alter table public.recurring_order_items enable row level security;
alter table public.invoices              enable row level security;
alter table public.invoice_lines         enable row level security;
alter table public.payments              enable row level security;
alter table public.payment_allocations   enable row level security;

create policy orders_read on public.orders for select to authenticated
  using (app.has_permission('orders.view') or app.has_permission('deliveries.view'));
create policy order_items_read on public.order_items for select to authenticated
  using (app.has_permission('orders.view') or app.has_permission('deliveries.view'));
create policy recurring_orders_read on public.recurring_orders for select to authenticated using (app.has_permission('orders.view'));
create policy recurring_order_items_read on public.recurring_order_items for select to authenticated using (app.has_permission('orders.view'));
create policy invoices_read on public.invoices for select to authenticated
  using (app.has_permission('payments.view') or app.has_permission('customers.view') or app.has_permission('orders.view'));
create policy invoice_lines_read on public.invoice_lines for select to authenticated
  using (app.has_permission('payments.view') or app.has_permission('customers.view') or app.has_permission('orders.view'));
create policy payments_read on public.payments for select to authenticated
  using (app.has_permission('payments.view') or app.has_permission('customers.view'));
create policy payment_allocations_read on public.payment_allocations for select to authenticated
  using (app.has_permission('payments.view') or app.has_permission('customers.view'));

revoke insert, update, delete, truncate on public.invoice_lines, public.payment_allocations from anon, authenticated, service_role;
