-- =====================================================================
-- OLA Water ERP — Phase 1B
-- 0016: location-scoped permissions, refunds (money paid out),
--        one shared sale engine used by deliveries and both POS types
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Location-scoped permissions
--    A role assigned "limited to location X" grants its permissions only
--    at X (e.g. a Shop Cashier at one water shop). has_permission() now
--    answers "anywhere in the company" and counts only unscoped roles;
--    has_permission_at() answers "at this location".
-- ---------------------------------------------------------------------
create or replace function app.has_permission(p_code text)
returns boolean language sql stable security definer set search_path = '' as $$
  select app.is_super_admin()
      or exists (
        select 1
          from public.user_roles ur
          join public.roles r             on r.id = ur.role_id and r.archived_at is null
          join public.profiles p          on p.id = ur.user_id and p.is_active
          join public.role_permissions rp on rp.role_id = r.id
         where ur.user_id = app.current_user_id()
           and ur.location_id is null
           and rp.permission_code = p_code)
$$;

create or replace function app.has_permission_at(p_code text, p_location uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select app.is_super_admin()
      or exists (
        select 1
          from public.user_roles ur
          join public.roles r             on r.id = ur.role_id and r.archived_at is null
          join public.profiles p          on p.id = ur.user_id and p.is_active
          join public.role_permissions rp on rp.role_id = r.id
         where ur.user_id = app.current_user_id()
           and (ur.location_id is null or ur.location_id = p_location)
           and rp.permission_code = p_code)
$$;

create or replace function app.require_permission_at(p_code text, p_location uuid)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if app.current_user_id() is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  if not app.has_permission_at(p_code, p_location) then
    raise exception 'Permission denied: % is required at %', p_code,
      coalesce((select name from public.locations where id = p_location), 'this location') using errcode = '42501';
  end if;
end $$;

create or replace function public.get_my_access()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when app.current_user_id() is null then null else
    jsonb_build_object(
      'user_id', p.id,
      'full_name', p.full_name,
      'email', p.email,
      'is_active', p.is_active,
      'is_super_admin', app.is_super_admin(),
      'default_location', (select jsonb_build_object('id', l.id, 'code', l.code, 'name', l.name)
                             from public.locations l where l.id = p.default_location_id),
      'roles', coalesce((
        select jsonb_agg(jsonb_build_object('code', r.code, 'name', r.name, 'location_code', l.code) order by r.name)
          from public.user_roles ur
          join public.roles r on r.id = ur.role_id and r.archived_at is null
          left join public.locations l on l.id = ur.location_id
         where ur.user_id = p.id), '[]'::jsonb),
      'permissions', case
        when not p.is_active then '[]'::jsonb
        when app.is_super_admin() then (select coalesce(jsonb_agg(code order by code), '[]'::jsonb) from public.permissions)
        else coalesce((
          select jsonb_agg(distinct rp.permission_code)
            from public.user_roles ur
            join public.roles r on r.id = ur.role_id and r.archived_at is null
            join public.role_permissions rp on rp.role_id = r.id
           where ur.user_id = p.id and ur.location_id is null), '[]'::jsonb)
      end,
      'scoped', case
        when not p.is_active or app.is_super_admin() then '[]'::jsonb
        else coalesce((
          select jsonb_agg(distinct jsonb_build_object('permission', rp.permission_code, 'location_id', l.id,
                                                       'location_code', l.code, 'location_name', l.name))
            from public.user_roles ur
            join public.roles r on r.id = ur.role_id and r.archived_at is null
            join public.role_permissions rp on rp.role_id = r.id
            join public.locations l on l.id = ur.location_id
           where ur.user_id = p.id), '[]'::jsonb)
      end
    )
  end
    from public.profiles p
   where p.id = app.current_user_id()
$$;

-- ---------------------------------------------------------------------
-- 2. Money paid out to customers (deposit refunds in cash at a counter)
-- ---------------------------------------------------------------------
alter table public.payments add column direction text not null default 'in' check (direction in ('in','out'));
comment on column public.payments.direction is 'in = received from the customer; out = paid to the customer (refund)';

create or replace function app.customer_outstanding(p_customer uuid)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce((select sum(total) from public.invoices where customer_id = p_customer and status <> 'void'), 0)
       - coalesce((select sum(case when direction = 'in' then amount else -amount end)
                     from public.payments where customer_id = p_customer and status = 'received'), 0)
$$;

-- Refunds never get allocated to invoices
create or replace function app.allocate_payment(p_payment uuid, p_first_invoice uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare pay public.payments; inv record; v_left numeric; v_apply numeric;
begin
  select * into pay from public.payments where id = p_payment for update;
  if pay.direction = 'out' then return; end if;
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

-- ---------------------------------------------------------------------
-- 3. Exceptions: link to more kinds of source
-- ---------------------------------------------------------------------
alter table public.operation_exceptions
  add column target_location_id uuid references public.locations(id),
  add column fill_state text check (fill_state in ('full','empty')),
  add column source_type text,
  add column source_id uuid;
comment on column public.operation_exceptions.target_location_id is 'Where missing items should have gone (e.g. the shop for a transfer shortage)';

-- ---------------------------------------------------------------------
-- 4. The shared sale engine
--    Moves stock and bottles at p_location, applies the external-bottle
--    policy, re-balances deposits, writes the invoice and its journals.
--    Used by deliveries (vehicle), the head-office POS and shop POS.
--
--    p_lines: [{product_id, qty, unit_price, discount}]   (prices already decided)
--    p:       {ola_returned_codes, ola_returned_counts, external, issued_codes,
--              default_bottle_type_id, gps:{lat,lng}}
--    p_extra: [{line_type, description, qty, unit_price, total}]  e.g. delivery charge
--    p_post:  false at dealer-owned shops — stock and bottles move, but OLA
--             issues no invoice, no deposits and no journals (the sale is the dealer's)
--    p_tolerant: true at counters — selling more than recorded stock is
--             accepted and flagged instead of refused (never lose a sale)
--    p_inv:   {event, order_id, delivery_id, run_id, client_txn_id}
-- ---------------------------------------------------------------------
create or replace function app.sale_core(
  p_customer uuid, p_location uuid, p_lines jsonb, p_includes_tax boolean, p jsonb,
  p_ref_type text, p_ref_id uuid, p_run uuid, p_post boolean, p_tolerant boolean,
  p_extra jsonb, p_inv jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c public.customers; pr public.products; v_own uuid := app.own_company_id(); v_today date := app.today();
  l jsonb; v_qty numeric; v_price numeric; v_disc numeric; v_rate numeric; calc record; v_have numeric;
  v_lines jsonb := '[]'; v_net numeric := 0; v_tax numeric := 0; v_total numeric := 0; v_extra_total numeric := 0;
  v_cogs numeric := 0; v_deposit numeric := 0; v_refund numeric := 0; v_charge numeric := 0;
  v_issued jsonb := '{}'; v_returned jsonb := '{}'; v_ext_summary jsonb := '[]';
  v_code text; b public.bottles; v_bid uuid; v_left integer; v_type uuid; v_policy text; v_company public.bottle_companies;
  v_ext_qty integer; v_gps_lat numeric := app.jnum(p -> 'gps', 'lat'); v_gps_lng numeric := app.jnum(p -> 'gps', 'lng');
  v_held integer; v_target integer; v_delta integer; bv public.bottle_values; bt record; v_balance integer;
  v_inv uuid; v_inv_no text; v_je uuid; v_pay uuid; v_default_type uuid;
begin
  select * into c from public.customers where id = p_customer;
  if not found then raise exception 'Customer not found' using errcode = 'P0002'; end if;
  v_default_type := coalesce(app.juuid(p, 'default_bottle_type_id'),
                             (select id from public.bottle_types where is_active order by size_litres desc limit 1));

  -- 1. Products -------------------------------------------------------------
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    v_qty := app.jnum(l, 'qty');
    continue when coalesce(v_qty, 0) <= 0;
    if v_qty <> trunc(v_qty) then raise exception 'Quantities must be whole numbers' using errcode = '22023'; end if;
    select * into pr from public.products where id = app.juuid(l, 'product_id');
    if not found then raise exception 'Unknown product' using errcode = 'P0002'; end if;
    v_price := app.jnum(l, 'unit_price');
    v_disc := coalesce(app.jnum(l, 'discount'), 0);
    v_rate := app.tax_rate(pr.tax_code, v_today);
    select * into calc from app.calc_line(v_qty, v_price, v_disc, v_rate, p_includes_tax);

    if p_tolerant then
      select coalesce(sum(qty), 0) into v_have from public.inventory_balances
       where location_id = p_location and product_id = pr.id and stock_status = 'available';
      if v_have < v_qty then
        perform app.stock_move('adjust_gain', pr.id, v_qty - v_have, null, p_location, p_ref_type, p_ref_id,
          'Sold more than the recorded stock');
        perform app.raise_exception_record('negative_balance',
          format('%s sold %s but only %s was recorded at %s — stock count needed', pr.name, v_qty::integer, v_have::integer,
                 (select name from public.locations where id = p_location)),
          'warning', p_run, p_location, c.id, null, null, null, pr.id, v_have, v_qty);
      end if;
    end if;
    perform app.stock_move('sale', pr.id, v_qty, p_location, null, p_ref_type, p_ref_id);
    v_cogs := v_cogs + v_qty * pr.cost_price;

    v_lines := v_lines || jsonb_build_object('line_type', 'product', 'product_id', pr.id, 'description', pr.name, 'qty', v_qty,
      'unit_price', v_price, 'discount', v_disc, 'tax_rate', v_rate, 'net', calc.net, 'tax', calc.tax, 'total', calc.total);
    v_net := v_net + calc.net; v_tax := v_tax + calc.tax; v_total := v_total + calc.total;

    if pr.is_returnable then
      v_left := v_qty::integer;
      for v_code in select jsonb_array_elements_text(coalesce(p -> 'issued_codes', '[]')) loop
        exit when v_left = 0;
        b := app.bottle_by_code(v_code);
        continue when b.id is null or b.bottle_type_id <> pr.bottle_type_id or b.company_id <> v_own
              or (b.holder_type = 'customer' and b.holder_id = c.id);
        perform app.bottle_move('deliver', null, null, 1, 'location', p_location, 'full', 'customer', c.id, 'full',
          p_ref_type, p_ref_id, b.id, null, v_gps_lat, v_gps_lng, p_run);
        v_left := v_left - 1;
      end loop;
      if v_left > 0 then
        perform app.bottle_move('deliver', v_own, pr.bottle_type_id, v_left, 'location', p_location, 'full', 'customer', c.id, 'full',
          p_ref_type, p_ref_id, null, null, v_gps_lat, v_gps_lng, p_run);
      end if;
      v_issued := jsonb_set(v_issued, array[pr.bottle_type_id::text],
                            to_jsonb(coalesce((v_issued ->> pr.bottle_type_id::text)::integer, 0) + v_qty::integer));
    end if;
  end loop;

  -- 2. OLA empties back (never block on a bad label) ---------------------------
  for v_code in select jsonb_array_elements_text(coalesce(p -> 'ola_returned_codes', '[]')) loop
    b := app.bottle_by_code(v_code);
    if b.id is null and upper(trim(v_code)) like 'EXT-%' then
      select id into v_bid from public.bottle_companies where code = split_part(upper(trim(v_code)), '-', 2) and not is_own;
      if v_bid is not null then
        p := jsonb_set(p, '{external}', coalesce(p -> 'external', '[]') || jsonb_build_array(jsonb_build_object(
               'company_id', v_bid, 'code', upper(trim(v_code)))));
        continue;
      end if;
    end if;
    if b.id is null then
      if exists (select 1 from public.identifiers where value = upper(trim(v_code)) and status = 'unassigned' and entity_type = 'bottle') then
        v_bid := app.register_bottle(v_code, v_own, v_default_type, 'customer', c.id, 'full');
        select * into b from public.bottles where id = v_bid;
      else
        perform app.bottle_move('collect', v_own, v_default_type, 1, 'customer', c.id, 'full', 'location', p_location, 'empty',
          p_ref_type, p_ref_id, null, 'Unknown label ' || upper(trim(v_code)), v_gps_lat, v_gps_lng, p_run);
        perform app.raise_exception_record('bottle_location', format('Unknown label %s scanned at %s — counted as an OLA bottle',
          upper(trim(v_code)), c.name), 'warning', p_run, p_location, c.id, null, v_own, v_default_type);
        v_returned := jsonb_set(v_returned, array[v_default_type::text], to_jsonb(coalesce((v_returned ->> v_default_type::text)::integer, 0) + 1));
        continue;
      end if;
    end if;
    if b.company_id <> v_own then
      p := jsonb_set(p, '{external}', coalesce(p -> 'external', '[]') || jsonb_build_array(jsonb_build_object(
             'company_id', b.company_id, 'bottle_type_id', b.bottle_type_id, 'code', b.code)));
      continue;
    end if;
    perform app.bottle_move('collect', null, null, 1, 'customer', c.id, 'full', 'location', p_location, 'empty',
      p_ref_type, p_ref_id, b.id, null, v_gps_lat, v_gps_lng, p_run);
    v_returned := jsonb_set(v_returned, array[b.bottle_type_id::text],
                            to_jsonb(coalesce((v_returned ->> b.bottle_type_id::text)::integer, 0) + 1));
  end loop;
  for l in select * from jsonb_array_elements(coalesce(p -> 'ola_returned_counts', '[]')) loop
    v_qty := app.jint(l, 'qty');
    continue when coalesce(v_qty, 0) <= 0;
    v_type := coalesce(app.juuid(l, 'bottle_type_id'), v_default_type);
    perform app.bottle_move('collect', v_own, v_type, v_qty::integer, 'customer', c.id, 'full',
      'location', p_location, 'empty', p_ref_type, p_ref_id, null, null, v_gps_lat, v_gps_lng, p_run);
    v_returned := jsonb_set(v_returned, array[v_type::text],
                            to_jsonb(coalesce((v_returned ->> v_type::text)::integer, 0) + v_qty::integer));
  end loop;

  -- 3. Other companies' bottles ------------------------------------------------
  for l in select * from jsonb_array_elements(coalesce(p -> 'external', '[]')) loop
    select * into v_company from public.bottle_companies where id = app.juuid(l, 'company_id');
    if not found or v_company.is_own then raise exception 'Choose the bottle''s company' using errcode = '22023'; end if;
    v_type := coalesce(app.juuid(l, 'bottle_type_id'), v_default_type);
    v_policy := app.external_policy(c.id, v_company.id);
    if v_policy = 'refuse' then
      raise exception '% bottles are not accepted from this customer', v_company.name using errcode = '22023';
    end if;

    v_code := coalesce(app.jtext(l, 'code'), app.jtext(l, 'new_tag'));
    if v_code is not null then
      b := app.bottle_by_code(v_code);
      if b.id is not null then
        v_type := b.bottle_type_id;
        perform app.bottle_move('external_intake', null, null, 1, b.holder_type, b.holder_id, b.fill_state, 'location', p_location, 'empty',
          p_ref_type, p_ref_id, b.id, null, v_gps_lat, v_gps_lng, p_run);
      elsif exists (select 1 from public.identifiers where value = upper(trim(v_code)) and status = 'unassigned') then
        v_bid := app.register_bottle(v_code, v_company.id, v_type, 'outside', app.outside_id(), 'empty');
        perform app.bottle_move('external_intake', null, null, 1, 'outside', app.outside_id(), 'empty', 'location', p_location, 'empty',
          p_ref_type, p_ref_id, v_bid, null, v_gps_lat, v_gps_lng, p_run);
      else
        perform app.bottle_move('external_intake', v_company.id, v_type, 1, 'outside', app.outside_id(), 'empty',
          'location', p_location, 'empty', p_ref_type, p_ref_id, null, 'Unknown label ' || upper(trim(v_code)), v_gps_lat, v_gps_lng, p_run);
        perform app.raise_exception_record('bottle_location', format('Unknown label %s scanned at %s — counted as a %s bottle',
          upper(trim(v_code)), c.name, v_company.name), 'warning', p_run, p_location, c.id, null, v_company.id, v_type);
      end if;
      v_ext_qty := 1;
    else
      v_ext_qty := coalesce(app.jint(l, 'qty'), 1);
      continue when v_ext_qty <= 0;
      perform app.bottle_move('external_intake', v_company.id, v_type, v_ext_qty, 'outside', app.outside_id(), 'empty',
        'location', p_location, 'empty', p_ref_type, p_ref_id, null, null, v_gps_lat, v_gps_lng, p_run);
    end if;

    if v_policy in ('accept_one_for_one','accept_with_charge') then
      perform app.bottle_move('adjust', v_own, v_type, v_ext_qty, 'customer', c.id, 'full', 'outside', app.outside_id(), 'empty',
        p_ref_type, p_ref_id, null, format('Exchanged for %s %s bottle(s)', v_ext_qty, v_company.name), v_gps_lat, v_gps_lng, p_run);
      v_returned := jsonb_set(v_returned, array[v_type::text],
                              to_jsonb(coalesce((v_returned ->> v_type::text)::integer, 0) + v_ext_qty));
    end if;
    if v_policy = 'accept_with_charge' then
      bv := app.bottle_value(v_type, v_company.id, v_today);
      if coalesce(bv.external_charge, 0) > 0 then
        v_lines := v_lines || jsonb_build_object('line_type', 'bottle_charge', 'bottle_type_id', v_type,
          'description', v_company.name || ' bottle charge', 'qty', v_ext_qty, 'unit_price', bv.external_charge, 'discount', 0,
          'tax_rate', 0, 'net', v_ext_qty * bv.external_charge, 'tax', 0, 'total', v_ext_qty * bv.external_charge);
        v_charge := v_charge + v_ext_qty * bv.external_charge;
      end if;
    end if;
    v_ext_summary := v_ext_summary || jsonb_build_object('company', v_company.name, 'company_id', v_company.id, 'qty', v_ext_qty,
                                                         'policy', v_policy);
  end loop;

  -- 4. Deposits (OLA sales only) and bottle limits ------------------------------
  for bt in select id, name from public.bottle_types loop
    v_balance := app.customer_ola_bottles(c.id, bt.id);
    if p_post and c.bottle_model = 'deposit' then
      select coalesce(sum(qty_held), 0) into v_held from public.customer_deposit_balances
       where customer_id = c.id and bottle_type_id = bt.id;
      v_target := greatest(v_balance, 0);
      v_delta := v_target - v_held;
      continue when v_delta = 0;
      bv := app.bottle_value(bt.id, v_own, v_today);
      continue when coalesce(bv.deposit_amount, 0) = 0;
      if v_delta > 0 then
        v_lines := v_lines || jsonb_build_object('line_type', 'deposit', 'bottle_type_id', bt.id, 'description', 'Bottle deposit ' || bt.name,
          'qty', v_delta, 'unit_price', bv.deposit_amount, 'discount', 0, 'tax_rate', 0,
          'net', v_delta * bv.deposit_amount, 'tax', 0, 'total', v_delta * bv.deposit_amount);
        v_deposit := v_deposit + v_delta * bv.deposit_amount;
        insert into public.deposit_transactions (customer_id, bottle_type_id, txn_type, qty, amount, reference_type, reference_id, created_by)
        values (c.id, bt.id, 'collected', v_delta, v_delta * bv.deposit_amount, p_ref_type, p_ref_id, app.current_user_id());
      else
        v_lines := v_lines || jsonb_build_object('line_type', 'deposit_refund', 'bottle_type_id', bt.id, 'description', 'Deposit refund ' || bt.name,
          'qty', -v_delta, 'unit_price', -bv.deposit_amount, 'discount', 0, 'tax_rate', 0,
          'net', v_delta * bv.deposit_amount, 'tax', 0, 'total', v_delta * bv.deposit_amount);
        v_refund := v_refund - v_delta * bv.deposit_amount;
        insert into public.deposit_transactions (customer_id, bottle_type_id, txn_type, qty, amount, reference_type, reference_id, created_by)
        values (c.id, bt.id, 'refunded', -v_delta, -v_delta * bv.deposit_amount, p_ref_type, p_ref_id, app.current_user_id());
      end if;
    elsif c.bottle_model = 'loan' and v_balance > c.allowed_bottles and (v_issued ? bt.id::text) then
      perform app.raise_exception_record('over_bottle_limit',
        format('%s now holds %s %s bottles (limit %s)', c.name, v_balance, bt.name, c.allowed_bottles),
        'info', p_run, null, c.id, null, v_own, bt.id, null, c.allowed_bottles, v_balance);
    end if;
  end loop;

  -- 5. Extra lines (delivery charge) ---------------------------------------------
  for l in select * from jsonb_array_elements(coalesce(p_extra, '[]')) loop
    v_lines := v_lines || jsonb_build_object('line_type', app.jtext(l, 'line_type'), 'description', app.jtext(l, 'description'),
      'qty', coalesce(app.jnum(l, 'qty'), 1), 'unit_price', app.jnum(l, 'unit_price'), 'discount', 0, 'tax_rate', 0,
      'net', app.jnum(l, 'total'), 'tax', 0, 'total', app.jnum(l, 'total'));
    v_extra_total := v_extra_total + app.jnum(l, 'total');
  end loop;

  v_total := v_total + v_deposit - v_refund + v_charge + v_extra_total;

  -- 6. Invoice + journals (OLA sales only) ----------------------------------------
  if p_post and jsonb_array_length(v_lines) > 0 then
    v_inv := gen_random_uuid();
    v_inv_no := app.next_document_number('INV');
    insert into public.invoices (id, invoice_no, customer_id, order_id, delivery_id, run_id, location_id, invoice_date, due_date,
      is_tax_invoice, subtotal_net, tax_total, deposit_net, other_charges, total, status, created_by, client_txn_id)
    values (v_inv, v_inv_no, c.id, app.juuid(p_inv, 'order_id'), app.juuid(p_inv, 'delivery_id'), p_run, p_location, v_today,
      v_today + c.payment_terms_days, c.vat_no is not null, v_net, v_tax, v_deposit - v_refund, v_charge + v_extra_total,
      v_total, case when v_total <= 0 then 'credit' else 'open' end, app.current_user_id(), app.juuid(p_inv, 'client_txn_id'));
    insert into public.invoice_lines (invoice_id, line_no, line_type, product_id, bottle_type_id, description, qty, unit_price,
      discount, tax_rate, net, tax, total)
    select v_inv, ord, x ->> 'line_type', nullif(x ->> 'product_id', '')::uuid, nullif(x ->> 'bottle_type_id', '')::uuid,
           x ->> 'description', (x ->> 'qty')::numeric, (x ->> 'unit_price')::numeric, (x ->> 'discount')::numeric,
           (x ->> 'tax_rate')::numeric, (x ->> 'net')::numeric, (x ->> 'tax')::numeric, (x ->> 'total')::numeric
      from jsonb_array_elements(v_lines) with ordinality as t(x, ord);

    v_je := app.post_event(coalesce(app.jtext(p_inv, 'event'), 'invoice.issued'), jsonb_build_object(
        'ar_debit', greatest(v_total, 0), 'ar_credit', greatest(-v_total, 0),
        'net', v_net, 'vat', v_tax, 'delivery', v_extra_total,
        'deposit', v_deposit, 'deposit_refund', v_refund, 'bottle_charge', v_charge),
      v_today, format('Invoice %s — %s', v_inv_no, c.name), 'invoice', v_inv, p_location, 'customer', c.id);
    update public.invoices set journal_entry_id = v_je where id = v_inv;

    if v_cogs > 0 then
      perform app.post_event('cogs.sale', jsonb_build_object('value', v_cogs), v_today,
        format('Cost of goods — %s', v_inv_no), 'invoice', v_inv, p_location);
    end if;

    for v_pay in select id from public.payments where customer_id = c.id and status = 'received' and direction = 'in'
                   and unallocated > 0 order by received_at loop
      perform app.allocate_payment(v_pay, v_inv);
    end loop;
    perform app.refresh_invoice_status(v_inv);
  end if;

  return jsonb_build_object(
    'lines', v_lines, 'net', v_net, 'tax', v_tax, 'total', v_total, 'deposit', v_deposit, 'refund', v_refund,
    'charge', v_charge, 'extra', v_extra_total, 'cogs', v_cogs, 'invoice_id', v_inv, 'invoice_no', v_inv_no,
    'issued', v_issued, 'returned', v_returned, 'external', v_ext_summary);
end $$;

-- ---------------------------------------------------------------------
-- 5. complete_delivery now uses the shared engine (same inputs/outputs)
-- ---------------------------------------------------------------------
create or replace function public.complete_delivery(p_delivery uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; d public.deliveries; r public.route_runs; o public.orders; c public.customers;
  v_veh uuid; v_today date := app.today();
  l jsonb; v_qty numeric; oi public.order_items; v_priced jsonb := '[]'; v_extra jsonb := '[]'; s jsonb;
  v_pay_amount numeric := coalesce(app.jnum(p -> 'payment', 'amount'), 0);
  v_status text; v_res jsonb; v_all_done boolean;
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

  -- prices come from the order (discounts pro-rated on partial deliveries)
  for l in select * from jsonb_array_elements(coalesce(p -> 'lines', '[]')) loop
    v_qty := app.jnum(l, 'qty');
    continue when coalesce(v_qty, 0) <= 0;
    oi := null;
    select * into oi from public.order_items where order_id = o.id and product_id = app.juuid(l, 'product_id') order by line_no limit 1;
    if oi.id is not null then
      v_priced := v_priced || jsonb_build_object('product_id', oi.product_id, 'qty', v_qty, 'unit_price', oi.unit_price,
        'discount', case when oi.qty > 0 then round(oi.discount * least(v_qty, oi.qty) / oi.qty, 2) else 0 end);
      update public.order_items set delivered_qty = delivered_qty + v_qty where id = oi.id;
    else
      v_priced := v_priced || jsonb_build_object('product_id', app.juuid(l, 'product_id'), 'qty', v_qty,
        'unit_price', app.unit_price(app.juuid(l, 'product_id'), o.price_list_id, v_today), 'discount', 0);
    end if;
  end loop;

  if o.delivery_charge > 0 and not exists (select 1 from public.invoices where order_id = o.id) then
    v_extra := jsonb_build_array(jsonb_build_object('line_type', 'delivery_charge', 'description', 'Delivery charge', 'qty', 1,
      'unit_price', o.delivery_charge, 'total', o.delivery_charge));
  end if;

  s := app.sale_core(c.id, v_veh, v_priced, o.prices_include_tax, p, 'delivery', d.id, r.id, true, false, v_extra,
         jsonb_build_object('event', 'invoice.issued', 'order_id', o.id, 'delivery_id', d.id, 'client_txn_id', p_client_txn_id));

  if v_pay_amount > 0 then
    perform app.create_payment(c.id, coalesce(app.jtext(p -> 'payment', 'method'), 'cash'), v_pay_amount,
      app.jtext(p -> 'payment', 'reference'), r.id, d.id, (s ->> 'invoice_id')::uuid, null, null);
  end if;

  select bool_and(delivered_qty >= qty) into v_all_done from public.order_items where order_id = o.id;
  v_status := case when v_all_done then 'delivered'
                   when exists (select 1 from public.order_items where order_id = o.id and delivered_qty > 0) then 'partially_delivered'
                   else 'delivered' end;
  update public.orders set status = v_status where id = o.id;

  v_res := jsonb_build_object(
    'delivery_id', d.id, 'delivery_no', d.delivery_no, 'invoice_id', s -> 'invoice_id', 'invoice_no', s -> 'invoice_no',
    'customer', jsonb_build_object('name', c.name, 'customer_no', c.customer_no),
    'lines', s -> 'lines', 'subtotal_net', s -> 'net', 'tax_total', s -> 'tax', 'total', coalesce((s ->> 'total')::numeric, 0),
    'paid', v_pay_amount, 'method', app.jtext(p -> 'payment', 'method'),
    'tendered', app.jnum(p -> 'payment', 'tendered'),
    'change', greatest(coalesce(app.jnum(p -> 'payment', 'tendered'), v_pay_amount) - v_pay_amount, 0),
    'outstanding', app.customer_outstanding(c.id),
    'bottles', jsonb_build_object('issued', s -> 'issued', 'returned', s -> 'returned', 'external', s -> 'external',
                                  'balance', app.customer_ola_bottles(c.id)));

  update public.deliveries set
    status = v_status,
    completed_at = coalesce((app.jtext(p, 'completed_at'))::timestamptz, now()),
    synced_at = now(),
    gps_lat = app.jnum(p -> 'gps', 'lat'), gps_lng = app.jnum(p -> 'gps', 'lng'),
    confirmation_method = coalesce(app.jtext(p -> 'confirmation', 'method'), 'none'),
    recipient_name = app.jtext(p -> 'confirmation', 'recipient_name'),
    signature_data = app.jtext(p -> 'confirmation', 'signature_data'),
    photo_path = app.jtext(p -> 'confirmation', 'photo_path'),
    otp_verified = app.jbool(p -> 'confirmation', 'otp_verified', false),
    invoice_id = (s ->> 'invoice_id')::uuid, summary = v_res, notes = app.jtext(p, 'notes'), client_txn_id = p_client_txn_id
  where id = d.id;

  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;
