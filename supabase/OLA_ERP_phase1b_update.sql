-- OLA Water ERP — Phase 1B database update (water shops, tills, settlements)
-- Run ONCE in Supabase → SQL Editor → New query, on the database that already has Phase 1A.
-- It runs as one transaction: if anything fails, nothing is changed.
begin;

-- >>> 20261003000016_scoping_and_sale_core.sql
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

-- >>> 20261003000017_water_shops_pos.sql
-- =====================================================================
-- OLA Water ERP — Phase 1B
-- 0017: water shops, stock requests, POS (shops + head office),
--        daily closing, shop bottle returns, settlements
-- =====================================================================
-- Two shop models, set per shop:
--   company_owned  OLA's stock, OLA's sales. Takings sit in "Shop Cash
--                  Clearing" until banked at settlement.
--   dealer         Stock is sold to the dealer when it arrives (invoice to
--                  the dealer's account at the transfer price). The dealer's
--                  own counter sales are recorded for stock and bottle
--                  control only — no OLA invoice, deposit or journal.
-- OLA bottles at any shop always remain OLA's (on loan to dealers).
-- =====================================================================

insert into public.locations (code, name, location_type) values ('TRN', 'Goods in transit to shops', 'virtual')
on conflict (code) do nothing;
insert into public.document_types (code, name, padding) values
  ('PSN', 'Till session', 6), ('SBR', 'Shop bottle return', 6)
on conflict (code) do nothing;

alter table public.customers add column is_walk_in boolean not null default false;
comment on column public.customers.is_walk_in is 'Pooled account for counter customers who are not registered (one per counter)';

create or replace function app.transit_id() returns uuid
language sql stable security definer set search_path = '' as $$ select id from public.locations where code = 'TRN' $$;

-- ---------------------------------------------------------------------
-- Water shops
-- ---------------------------------------------------------------------
create table public.water_shops (
  id                     uuid primary key default gen_random_uuid(),
  code                   text not null unique check (code ~ '^[A-Z0-9]{2,10}$'),
  name                   text not null check (length(trim(name)) > 0),
  location_id            uuid not null unique references public.locations(id),
  operating_model        text not null check (operating_model in ('company_owned','dealer')),
  owner_name             text,
  contact_person         text,
  phone                  text check (phone ~ '^\+[1-9][0-9]{7,14}$'),
  email                  text,
  address                text,
  city                   text,
  district               text,
  territory              text,
  gps_lat                numeric(9,6),
  gps_lng                numeric(9,6),
  retail_price_list_id   uuid not null references public.price_lists(id),
  transfer_price_list_id uuid references public.price_lists(id),
  account_customer_id    uuid references public.customers(id),
  walk_in_customer_id    uuid not null references public.customers(id),
  commission_percent     numeric(5,2) not null default 0 check (commission_percent between 0 and 100),
  status                 text not null default 'active' check (status in ('active','suspended','closed')),
  notes                  text,
  created_at             timestamptz not null default now(),
  created_by             uuid,
  updated_at             timestamptz not null default now(),
  check (operating_model <> 'dealer' or (account_customer_id is not null and transfer_price_list_id is not null))
);
comment on column public.water_shops.account_customer_id is 'Dealer shops: the customer account OLA invoices for stock and receives payments on';
comment on column public.water_shops.commission_percent is 'Company-owned shops: commission on net sales, accrued at settlement';
create trigger water_shops_touch before update on public.water_shops for each row execute function app.touch_updated_at();
create trigger water_shops_audit after insert or update on public.water_shops for each row execute function app.audit_row('shops');

create or replace function app.shop_by_location(p_location uuid)
returns public.water_shops language sql stable security definer set search_path = '' as $$
  select * from public.water_shops where location_id = p_location
$$;

-- Does OLA own the stock at this location? (false only at dealer shops)
create or replace function app.location_is_ola(p_location uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select not exists (select 1 from public.water_shops where location_id = p_location and operating_model = 'dealer')
$$;

-- Pooled walk-in account for a counter (shop or head office)
create or replace function app.walk_in_customer(p_location uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; l public.locations;
begin
  select walk_in_customer_id into v from public.water_shops where location_id = p_location;
  if v is not null then return v; end if;
  select c.id into v from public.customers c where c.is_walk_in and c.notes = 'counter:' || p_location::text;
  if v is not null then return v; end if;
  select * into l from public.locations where id = p_location;
  insert into public.customers (name, customer_type, phone, price_list_id, bottle_model, allowed_bottles, is_walk_in, notes, created_by)
  values ('Walk-in — ' || l.name, 'household', '+94000000000', (select id from public.price_lists where code = 'RETAIL'),
          'deposit', 0, true, 'counter:' || p_location::text, app.current_user_id())
  returning id into v;
  return v;
end $$;

create or replace function public.save_water_shop(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  s public.water_shops; v uuid; v_loc uuid; v_walk uuid; v_acct uuid; v_code text := upper(app.jtext(p, 'code'));
  v_model text := coalesce(app.jtext(p, 'operating_model'), 'company_owned');
  v_retail uuid := coalesce(app.juuid(p, 'retail_price_list_id'), (select id from public.price_lists where code = 'RETAIL'));
  v_transfer uuid := coalesce(app.juuid(p, 'transfer_price_list_id'), (select id from public.price_lists where code = 'SHOP_TRANSFER'));
  v_phone text := app.normalize_phone(app.jtext(p, 'phone'));
begin
  perform app.require_permission('shops.manage');
  if app.jtext(p, 'name') is null then raise exception 'Shop name is required' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, null);

  if p_id is null then
    if v_code is null or v_code !~ '^[A-Z0-9]{2,10}$' then
      raise exception 'Shop code must be 2–10 capital letters or numbers, e.g. SHOP01' using errcode = '22023';
    end if;
    insert into public.locations (code, name, location_type, address, gps_lat, gps_lng)
    values (v_code, app.jtext(p, 'name'), 'water_shop', app.jtext(p, 'address'), app.jnum(p, 'gps_lat'), app.jnum(p, 'gps_lng'))
    returning id into v_loc;
    insert into public.customers (name, customer_type, phone, price_list_id, bottle_model, allowed_bottles, is_walk_in, notes, created_by)
    values ('Walk-in — ' || app.jtext(p, 'name'), 'household', coalesce(v_phone, '+94000000000'), v_retail,
            case when v_model = 'dealer' then 'none' else 'deposit' end, 0, true, 'counter:' || v_loc::text, app.current_user_id())
    returning id into v_walk;
    if v_model = 'dealer' then
      if v_phone is null then raise exception 'A phone number is required for a dealer shop' using errcode = '22023'; end if;
      if coalesce(app.jnum(p, 'credit_limit'), 0) > 0 and not app.has_permission('customers.credit') then
        raise exception 'Giving a dealer credit needs Finance approval (customers.credit)' using errcode = '42501';
      end if;
      insert into public.customers (name, company_name, customer_type, contact_person, phone, email, price_list_id, credit_limit,
                                    payment_terms_days, bottle_model, allowed_bottles, created_by)
      values (app.jtext(p, 'name'), app.jtext(p, 'owner_name'), 'water_shop', app.jtext(p, 'contact_person'), v_phone,
              lower(app.jtext(p, 'email')), v_transfer, coalesce(app.jnum(p, 'credit_limit'), 0),
              coalesce(app.jint(p, 'payment_terms_days'), 7), 'loan', 100000, app.current_user_id())
      returning id into v_acct;
      insert into public.customer_addresses (customer_id, label, address_line, city, district, gps_lat, gps_lng, is_default)
      select v_acct, 'Shop', app.jtext(p, 'address'), app.jtext(p, 'city'), app.jtext(p, 'district'),
             app.jnum(p, 'gps_lat'), app.jnum(p, 'gps_lng'), true
       where app.jtext(p, 'address') is not null;
    end if;
    insert into public.water_shops (code, name, location_id, operating_model, owner_name, contact_person, phone, email, address,
      city, district, territory, gps_lat, gps_lng, retail_price_list_id, transfer_price_list_id, account_customer_id,
      walk_in_customer_id, commission_percent, notes, created_by)
    values (v_code, app.jtext(p, 'name'), v_loc, v_model, app.jtext(p, 'owner_name'), app.jtext(p, 'contact_person'), v_phone,
      lower(app.jtext(p, 'email')), app.jtext(p, 'address'), app.jtext(p, 'city'), app.jtext(p, 'district'), app.jtext(p, 'territory'),
      app.jnum(p, 'gps_lat'), app.jnum(p, 'gps_lng'), v_retail, case when v_model = 'dealer' then v_transfer end, v_acct, v_walk,
      coalesce(app.jnum(p, 'commission_percent'), 0), app.jtext(p, 'notes'), app.current_user_id())
    returning id into v;
  else
    select * into s from public.water_shops where id = p_id for update;
    if not found then raise exception 'Shop not found' using errcode = 'P0002'; end if;
    update public.water_shops set
      name = app.jtext(p, 'name'), owner_name = app.jtext(p, 'owner_name'), contact_person = app.jtext(p, 'contact_person'),
      phone = v_phone, email = lower(app.jtext(p, 'email')), address = app.jtext(p, 'address'), city = app.jtext(p, 'city'),
      district = app.jtext(p, 'district'), territory = app.jtext(p, 'territory'), gps_lat = app.jnum(p, 'gps_lat'),
      gps_lng = app.jnum(p, 'gps_lng'), retail_price_list_id = v_retail,
      transfer_price_list_id = case when s.operating_model = 'dealer' then v_transfer end,
      commission_percent = coalesce(app.jnum(p, 'commission_percent'), 0),
      status = coalesce(app.jtext(p, 'status'), s.status), notes = app.jtext(p, 'notes')
    where id = p_id;
    update public.locations set name = app.jtext(p, 'name'), address = app.jtext(p, 'address'),
           is_active = coalesce(app.jtext(p, 'status'), s.status) <> 'closed'
     where id = s.location_id;
    update public.customers set price_list_id = v_retail where id = s.walk_in_customer_id;
    if s.account_customer_id is not null then
      update public.customers set price_list_id = v_transfer where id = s.account_customer_id;
    end if;
    v := p_id;
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Stock requests: request → approve → dispatch → receive
-- ---------------------------------------------------------------------
create table public.shop_stock_requests (
  id              uuid primary key default gen_random_uuid(),
  request_no      text not null unique,
  shop_id         uuid not null references public.water_shops(id),
  status          text not null default 'submitted' check (status in
                    ('submitted','approved','rejected','dispatched','received','received_with_differences','cancelled')),
  needed_by       date,
  notes           text,
  requested_at    timestamptz not null default now(),
  requested_by    uuid,
  approved_at     timestamptz,
  approved_by     uuid,
  decision_note   text,
  dispatch_no     text,
  dispatched_at   timestamptz,
  dispatched_by   uuid,
  received_at     timestamptz,
  received_by     uuid,
  invoice_id      uuid references public.invoices(id),
  updated_at      timestamptz not null default now(),
  client_txn_id   uuid unique
);
create index shop_stock_requests_shop_idx on public.shop_stock_requests (shop_id, requested_at desc);
create index shop_stock_requests_status_idx on public.shop_stock_requests (status, requested_at);

create table public.shop_stock_request_items (
  id              uuid primary key default gen_random_uuid(),
  request_id      uuid not null references public.shop_stock_requests(id),
  product_id      uuid not null references public.products(id),
  requested_qty   integer not null check (requested_qty >= 0),
  approved_qty    integer check (approved_qty >= 0),
  dispatched_qty  integer check (dispatched_qty >= 0),
  received_qty    integer check (received_qty >= 0),
  unique (request_id, product_id)
);
create trigger shop_stock_requests_touch before update on public.shop_stock_requests for each row execute function app.touch_updated_at();
create trigger shop_stock_requests_audit after insert or update on public.shop_stock_requests for each row execute function app.audit_row('shops');
create trigger shop_stock_request_items_audit after insert or update on public.shop_stock_request_items for each row execute function app.audit_row('shops');

-- Invoice a dealer for stock that reached the shop (no stock movement here)
create or replace function app.invoice_dealer_transfer(p_shop uuid, p_lines jsonb, p_ref_type text, p_ref_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  s public.water_shops; c public.customers; l jsonb; pr public.products; v_qty numeric; v_price numeric; v_rate numeric; calc record;
  v_inc boolean; v_lines jsonb := '[]'; v_net numeric := 0; v_tax numeric := 0; v_total numeric := 0; v_cogs numeric := 0;
  v_inv uuid := gen_random_uuid(); v_no text; v_je uuid; v_today date := app.today(); v_pay uuid;
begin
  select * into s from public.water_shops where id = p_shop;
  select * into c from public.customers where id = s.account_customer_id;
  select prices_include_tax into v_inc from public.price_lists where id = s.transfer_price_list_id;
  for l in select * from jsonb_array_elements(p_lines) loop
    v_qty := app.jnum(l, 'qty');
    continue when coalesce(v_qty, 0) <= 0;
    select * into pr from public.products where id = app.juuid(l, 'product_id');
    v_price := app.unit_price(pr.id, s.transfer_price_list_id, v_today);
    v_rate := app.tax_rate(pr.tax_code, v_today);
    select * into calc from app.calc_line(v_qty, v_price, 0, v_rate, v_inc);
    v_lines := v_lines || jsonb_build_object('product_id', pr.id, 'description', pr.name, 'qty', v_qty, 'unit_price', v_price,
                                             'tax_rate', v_rate, 'net', calc.net, 'tax', calc.tax, 'total', calc.total);
    v_net := v_net + calc.net; v_tax := v_tax + calc.tax; v_total := v_total + calc.total;
    v_cogs := v_cogs + v_qty * pr.cost_price;
  end loop;
  if jsonb_array_length(v_lines) = 0 then return null; end if;

  v_no := app.next_document_number('INV');
  insert into public.invoices (id, invoice_no, customer_id, location_id, invoice_date, due_date, is_tax_invoice, subtotal_net,
    tax_total, total, status, created_by)
  values (v_inv, v_no, c.id, s.location_id, v_today, v_today + c.payment_terms_days, c.vat_no is not null, v_net, v_tax, v_total,
    'open', app.current_user_id());
  insert into public.invoice_lines (invoice_id, line_no, line_type, product_id, description, qty, unit_price, discount, tax_rate, net, tax, total)
  select v_inv, ord, 'product', (x ->> 'product_id')::uuid, x ->> 'description', (x ->> 'qty')::numeric, (x ->> 'unit_price')::numeric,
         0, (x ->> 'tax_rate')::numeric, (x ->> 'net')::numeric, (x ->> 'tax')::numeric, (x ->> 'total')::numeric
    from jsonb_array_elements(v_lines) with ordinality t(x, ord);
  v_je := app.post_event('invoice.shop', jsonb_build_object('ar_debit', v_total, 'ar_credit', 0, 'net', v_net, 'vat', v_tax,
            'delivery', 0, 'deposit', 0, 'deposit_refund', 0, 'bottle_charge', 0),
          v_today, format('Invoice %s — stock to %s', v_no, s.name), 'invoice', v_inv, s.location_id, 'customer', c.id);
  update public.invoices set journal_entry_id = v_je where id = v_inv;
  if v_cogs > 0 then
    perform app.post_event('cogs.sale', jsonb_build_object('value', v_cogs), v_today, format('Cost of goods — %s', v_no),
      'invoice', v_inv, s.location_id);
  end if;
  for v_pay in select id from public.payments where customer_id = c.id and status = 'received' and direction = 'in'
                 and unallocated > 0 order by received_at loop
    perform app.allocate_payment(v_pay, v_inv);
  end loop;
  perform app.refresh_invoice_status(v_inv);
  return v_inv;
end $$;

create or replace function public.create_stock_request(p_shop uuid, p_lines jsonb, p_needed_by date, p_notes text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; s public.water_shops; v uuid; v_no text; l jsonb; n integer := 0; v_res jsonb;
begin
  select * into s from public.water_shops where id = p_shop;
  if not found then raise exception 'Shop not found' using errcode = 'P0002'; end if;
  if not (app.has_permission('shops.manage') or app.has_permission_at('shop_pos.use', s.location_id)) then
    raise exception 'Permission denied: only this shop''s staff can request stock for it' using errcode = '42501';
  end if;
  if s.status <> 'active' then raise exception 'Shop % is %', s.name, s.status using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'create_stock_request');
  if v_done is not null then return v_done; end if;
  perform app.set_context(null, p_client_txn_id, null);
  v_no := app.next_document_number('SRQ', s.location_id);
  insert into public.shop_stock_requests (request_no, shop_id, needed_by, notes, requested_by, client_txn_id)
  values (v_no, s.id, p_needed_by, nullif(trim(p_notes), ''), app.current_user_id(), p_client_txn_id) returning id into v;
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    continue when coalesce(app.jint(l, 'qty'), 0) <= 0;
    insert into public.shop_stock_request_items (request_id, product_id, requested_qty) values (v, app.juuid(l, 'product_id'), app.jint(l, 'qty'));
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Request at least one product' using errcode = '22023'; end if;
  v_res := jsonb_build_object('request_id', v, 'request_no', v_no);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- p_lines: [{product_id, qty}] approved quantities (0 = not approved)
create or replace function public.approve_stock_request(p_id uuid, p_lines jsonb, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.shop_stock_requests; s public.water_shops; it record; v_total numeric := 0; v_warn text; v_approved integer := 0;
begin
  perform app.require_permission('shops.stock_approve');
  select * into r from public.shop_stock_requests where id = p_id for update;
  if not found then raise exception 'Request not found' using errcode = 'P0002'; end if;
  if r.status <> 'submitted' then raise exception 'Request % is already %', r.request_no, r.status using errcode = '22023'; end if;
  select * into s from public.water_shops where id = r.shop_id;
  perform app.set_context(nullif(trim(p_note), ''), null, 'approve');
  for it in select * from public.shop_stock_request_items where request_id = p_id loop
    update public.shop_stock_request_items set approved_qty = coalesce(
      (select app.jint(x, 'qty') from jsonb_array_elements(coalesce(p_lines, '[]')) x where app.juuid(x, 'product_id') = it.product_id limit 1),
      it.requested_qty)
     where id = it.id;
  end loop;
  select coalesce(sum(approved_qty), 0) into v_approved from public.shop_stock_request_items where request_id = p_id;
  if v_approved = 0 then raise exception 'Nothing approved — reject the request instead' using errcode = '22023'; end if;
  if s.operating_model = 'dealer' then
    select coalesce(sum(i.approved_qty * app.unit_price(i.product_id, s.transfer_price_list_id)), 0) into v_total
      from public.shop_stock_request_items i where i.request_id = p_id and i.approved_qty > 0;
    if (select credit_limit from public.customers where id = s.account_customer_id) > 0
       and app.customer_outstanding(s.account_customer_id) + v_total > (select credit_limit from public.customers where id = s.account_customer_id) then
      v_warn := format('This takes %s over its credit limit (owes Rs. %s, this stock Rs. %s)', s.name,
                       to_char(app.customer_outstanding(s.account_customer_id), 'FM999,999,990.00'), to_char(v_total, 'FM999,999,990.00'));
    end if;
  end if;
  update public.shop_stock_requests set status = 'approved', approved_at = now(), approved_by = app.current_user_id(),
         decision_note = coalesce(nullif(trim(p_note), ''), v_warn) where id = p_id;
  perform set_config('app.audit_action', '', true);
  return jsonb_build_object('status', 'approved', 'warning', v_warn, 'value', v_total);
end $$;

create or replace function public.reject_stock_request(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.shop_stock_requests;
begin
  select * into r from public.shop_stock_requests where id = p_id for update;
  if not found then raise exception 'Request not found' using errcode = 'P0002'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  if r.status not in ('submitted','approved') then raise exception 'Request % is already %', r.request_no, r.status using errcode = '22023'; end if;
  -- the approver can reject; the shop can withdraw its own request before dispatch
  if not (app.has_permission('shops.stock_approve')
          or app.has_permission_at('shop_pos.use', (select location_id from public.water_shops where id = r.shop_id))) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  perform app.set_context(trim(p_reason), null, case when app.has_permission('shops.stock_approve') then 'reject' else 'cancel' end);
  update public.shop_stock_requests set status = case when app.has_permission('shops.stock_approve') then 'rejected' else 'cancelled' end,
         decision_note = trim(p_reason) where id = p_id;
  perform set_config('app.audit_action', '', true);
end $$;

-- Warehouse dispatch. p_lines: [{product_id, qty}] (≤ approved)
create or replace function public.dispatch_stock_request(p_id uuid, p_lines jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; r public.shop_stock_requests; it record; v_qty integer; pr public.products; v_wh uuid; v_no text; n integer := 0; v_res jsonb;
begin
  perform app.require_permission('inventory.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'dispatch_stock_request');
  if v_done is not null then return v_done; end if;
  select * into r from public.shop_stock_requests where id = p_id for update;
  if not found then raise exception 'Request not found' using errcode = 'P0002'; end if;
  if r.status <> 'approved' then raise exception 'Request % is % — only approved requests can be dispatched', r.request_no, r.status using errcode = '22023'; end if;
  perform app.set_context(null, p_client_txn_id, 'dispatch');
  select id into v_wh from public.locations where code = 'WH1';
  v_no := app.next_document_number('STR', v_wh);
  for it in select * from public.shop_stock_request_items where request_id = p_id loop
    v_qty := coalesce((select app.jint(x, 'qty') from jsonb_array_elements(coalesce(p_lines, '[]')) x
                        where app.juuid(x, 'product_id') = it.product_id limit 1), it.approved_qty, 0);
    if v_qty > coalesce(it.approved_qty, 0) then
      raise exception 'Cannot dispatch more than approved (% approved)', it.approved_qty using errcode = '22023';
    end if;
    update public.shop_stock_request_items set dispatched_qty = v_qty where id = it.id;
    continue when v_qty = 0;
    select * into pr from public.products where id = it.product_id;
    perform app.stock_move('transfer', pr.id, v_qty, v_wh, app.transit_id(), 'stock_request', p_id, 'Dispatched ' || v_no);
    if pr.is_returnable then
      perform app.bottle_move('transfer', app.own_company_id(), pr.bottle_type_id, v_qty, 'location', v_wh, 'full',
        'location', app.transit_id(), 'full', 'stock_request', p_id);
    end if;
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Dispatch at least one product' using errcode = '22023'; end if;
  update public.shop_stock_requests set status = 'dispatched', dispatch_no = v_no, dispatched_at = now(), dispatched_by = app.current_user_id()
   where id = p_id;
  perform set_config('app.audit_action', '', true);
  v_res := jsonb_build_object('dispatch_no', v_no);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Shop receives. p_lines: [{product_id, qty}] actually received. Differences become exceptions.
create or replace function public.receive_stock_request(p_id uuid, p_lines jsonb, p_notes text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; r public.shop_stock_requests; s public.water_shops; it record; v_qty integer; v_moved integer; pr public.products;
  v_inv uuid; v_invoice_lines jsonb := '[]'; v_diff integer := 0; v_res jsonb;
begin
  v_done := app.idempotency_begin(p_client_txn_id, 'receive_stock_request');
  if v_done is not null then return v_done; end if;
  select * into r from public.shop_stock_requests where id = p_id for update;
  if not found then raise exception 'Request not found' using errcode = 'P0002'; end if;
  select * into s from public.water_shops where id = r.shop_id;
  if not (app.has_permission('shops.manage') or app.has_permission_at('shop_pos.use', s.location_id)) then
    raise exception 'Permission denied: only this shop''s staff can receive its stock' using errcode = '42501';
  end if;
  if r.status <> 'dispatched' then raise exception 'Request % is % — nothing is on the way', r.request_no, r.status using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_notes), ''), p_client_txn_id, 'receive');

  for it in select * from public.shop_stock_request_items where request_id = p_id and coalesce(dispatched_qty, 0) > 0 loop
    v_qty := coalesce((select app.jint(x, 'qty') from jsonb_array_elements(coalesce(p_lines, '[]')) x
                        where app.juuid(x, 'product_id') = it.product_id limit 1), 0);
    if v_qty < 0 then raise exception 'Quantities cannot be negative' using errcode = '22023'; end if;
    update public.shop_stock_request_items set received_qty = v_qty where id = it.id;
    select * into pr from public.products where id = it.product_id;
    v_moved := least(v_qty, it.dispatched_qty);
    if v_moved > 0 then
      perform app.stock_move('transfer', pr.id, v_moved, app.transit_id(), s.location_id, 'stock_request', p_id, 'Received at ' || s.name);
      if pr.is_returnable then
        perform app.bottle_move('transfer', app.own_company_id(), pr.bottle_type_id, v_moved, 'location', app.transit_id(), 'full',
          'location', s.location_id, 'full', 'stock_request', p_id);
      end if;
      v_invoice_lines := v_invoice_lines || jsonb_build_object('product_id', pr.id, 'qty', v_moved);
    end if;
    if v_qty <> it.dispatched_qty then
      v_diff := v_diff + 1;
      insert into public.operation_exceptions (exception_type, severity, location_id, target_location_id, product_id, fill_state,
        expected, actual, difference, description, source_type, source_id, created_by)
      values (case when v_qty < it.dispatched_qty then 'stock_shortage' else 'stock_surplus' end,
        case when v_qty < it.dispatched_qty then 'critical' else 'warning' end, app.transit_id(), s.location_id, pr.id,
        case when pr.is_returnable then 'full' end, it.dispatched_qty, v_qty, v_qty - it.dispatched_qty,
        format('%s: %s %s dispatched to %s, %s received', r.request_no, it.dispatched_qty, pr.name, s.name, v_qty),
        'stock_request', p_id, app.current_user_id());
    end if;
  end loop;

  if s.operating_model = 'dealer' then
    v_inv := app.invoice_dealer_transfer(s.id, v_invoice_lines, 'stock_request', p_id);
  end if;
  update public.shop_stock_requests set status = case when v_diff = 0 then 'received' else 'received_with_differences' end,
         received_at = now(), received_by = app.current_user_id(), invoice_id = v_inv where id = p_id;
  perform set_config('app.audit_action', '', true);
  v_res := jsonb_build_object('differences', v_diff, 'invoice_id', v_inv,
                              'invoice_no', (select invoice_no from public.invoices where id = v_inv));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- Empty and external bottles sent back from a shop to the warehouse
-- p_lines: [{company_id, bottle_type_id, qty}]   p_codes: tagged bottles
-- ---------------------------------------------------------------------
create or replace function public.receive_shop_bottles(p_shop uuid, p_lines jsonb, p_codes text[], p_notes text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; s public.water_shops; v_no text; l jsonb; v_qty integer; v_own uuid := app.own_company_id(); v_wh uuid; v_ext uuid;
  v_have integer; c text; b public.bottles; v_total integer := 0; v_res jsonb; v_id uuid := gen_random_uuid();
begin
  perform app.require_permission('inventory.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'receive_shop_bottles');
  if v_done is not null then return v_done; end if;
  select * into s from public.water_shops where id = p_shop;
  if not found then raise exception 'Shop not found' using errcode = 'P0002'; end if;
  perform app.set_context(nullif(trim(p_notes), ''), p_client_txn_id, null);
  select id into v_wh from public.locations where code = 'WH1';
  select id into v_ext from public.locations where location_type = 'external_holding' order by created_at limit 1;
  v_no := app.next_document_number('SBR', v_wh);

  foreach c in array coalesce(p_codes, '{}') loop
    continue when nullif(trim(c), '') is null;
    b := app.bottle_by_code(c);
    continue when b.id is null;
    perform app.bottle_move(case when b.company_id = v_own then 'transfer' else 'to_external_holding' end, null, null, 1,
      'location', s.location_id, 'empty', 'location', case when b.company_id = v_own then v_wh else v_ext end, 'empty',
      'shop_bottle_return', v_id, b.id);
    v_total := v_total + 1;
  end loop;

  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    v_qty := coalesce(app.jint(l, 'qty'), 0);
    continue when v_qty <= 0;
    select coalesce(sum(qty), 0) - (select count(*) from public.bottles where holder_type = 'location' and holder_id = s.location_id
             and company_id = app.juuid(l, 'company_id') and bottle_type_id = app.juuid(l, 'bottle_type_id') and fill_state = 'empty')
      into v_have from public.bottle_balances
     where holder_type = 'location' and holder_id = s.location_id and company_id = app.juuid(l, 'company_id')
       and bottle_type_id = app.juuid(l, 'bottle_type_id') and fill_state = 'empty';
    if v_qty > v_have then
      perform app.raise_exception_record('bottle_surplus',
        format('%s sent %s %s empties, but the system had %s at the shop', s.name, v_qty,
               (select name from public.bottle_companies where id = app.juuid(l, 'company_id')), greatest(v_have, 0)),
        'warning', null, s.location_id, null, null, app.juuid(l, 'company_id'), app.juuid(l, 'bottle_type_id'), null, v_have, v_qty);
    end if;
    perform app.bottle_move(case when app.juuid(l, 'company_id') = v_own then 'transfer' else 'to_external_holding' end,
      app.juuid(l, 'company_id'), app.juuid(l, 'bottle_type_id'), v_qty, 'location', s.location_id, 'empty',
      'location', case when app.juuid(l, 'company_id') = v_own then v_wh else v_ext end, 'empty', 'shop_bottle_return', v_id);
    v_total := v_total + v_qty;
  end loop;
  if v_total = 0 then raise exception 'Enter the bottles received' using errcode = '22023'; end if;
  perform app.write_audit('receive_bottles', 'shops', 'water_shops', s.id::text, null,
    jsonb_build_object('document', v_no, 'shop', s.name, 'bottles', v_total, 'lines', p_lines, 'codes', to_jsonb(p_codes)));
  v_res := jsonb_build_object('document_no', v_no, 'bottles', v_total);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- POS: till sessions and sales (shops and head-office counters)
-- ---------------------------------------------------------------------
create table public.pos_sessions (
  id              uuid primary key default gen_random_uuid(),
  session_no      text not null unique,
  receipt_prefix  text not null unique,
  location_id     uuid not null references public.locations(id),
  status          text not null default 'open' check (status in ('open','closed')),
  opening_float   numeric(12,2) not null default 0 check (opening_float >= 0),
  opened_at       timestamptz not null default now(),
  opened_by       uuid,
  closed_at       timestamptz,
  closed_by       uuid,
  cash_expected   numeric(12,2),
  cash_counted    numeric(12,2),
  card_expected   numeric(12,2),
  card_counted    numeric(12,2),
  counts          jsonb,
  exceptions      integer,
  notes           text,
  settlement_id   uuid,
  updated_at      timestamptz not null default now(),
  client_txn_id   uuid unique
);
create unique index pos_sessions_one_open on public.pos_sessions (location_id) where status = 'open';
create index pos_sessions_location_idx on public.pos_sessions (location_id, opened_at desc);
create trigger pos_sessions_touch before update on public.pos_sessions for each row execute function app.touch_updated_at();
create trigger pos_sessions_audit after insert or update on public.pos_sessions for each row execute function app.audit_row('pos');

create table public.pos_sales (
  id              uuid primary key default gen_random_uuid(),
  receipt_no      text not null unique,
  session_id      uuid not null references public.pos_sessions(id),
  location_id     uuid not null references public.locations(id),
  customer_id     uuid not null references public.customers(id),
  is_walk_in      boolean not null,
  posted          boolean not null,
  sold_at         timestamptz not null,
  synced_at       timestamptz not null default now(),
  subtotal_net    numeric(14,2) not null,
  tax_total       numeric(14,2) not null,
  total           numeric(14,2) not null,
  cash_in         numeric(14,2) not null default 0,
  cash_out        numeric(14,2) not null default 0,
  card_in         numeric(14,2) not null default 0,
  other_in        numeric(14,2) not null default 0,
  on_account      numeric(14,2) not null default 0,
  tendered        numeric(14,2),
  change_given    numeric(14,2) not null default 0,
  payments        jsonb not null default '[]',
  invoice_id      uuid references public.invoices(id),
  summary         jsonb not null,
  print_count     integer not null default 0,
  created_by      uuid,
  client_txn_id   uuid unique
);
create index pos_sales_session_idx on public.pos_sales (session_id);
create index pos_sales_location_idx on public.pos_sales (location_id, sold_at desc);
create trigger pos_sales_no_delete before delete on public.pos_sales for each row execute function app.forbid_change();
create trigger pos_sales_audit after insert on public.pos_sales for each row execute function app.audit_row('pos');

create table public.pos_sale_lines (
  id          bigint generated always as identity primary key,
  sale_id     uuid not null references public.pos_sales(id),
  line_no     integer not null,
  line_type   text not null,
  product_id  uuid references public.products(id),
  description text not null,
  qty         numeric(12,3) not null,
  unit_price  numeric(12,2) not null,
  discount    numeric(12,2) not null default 0,
  net         numeric(14,2) not null,
  tax         numeric(14,2) not null,
  total       numeric(14,2) not null,
  unit_cost   numeric(12,2),
  unique (sale_id, line_no)
);
create trigger pos_sale_lines_append_only before update or delete on public.pos_sale_lines for each row execute function app.forbid_change();

alter table public.payments add column location_id uuid references public.locations(id);

-- Payments can now record where they were taken (till location)
drop function app.create_payment(uuid, text, numeric, text, uuid, uuid, uuid, text, uuid);
create function app.create_payment(
  p_customer uuid, p_method text, p_amount numeric, p_reference text, p_run uuid, p_delivery uuid,
  p_first_invoice uuid, p_notes text, p_client_txn_id uuid, p_location uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  if coalesce(p_amount, 0) <= 0 then raise exception 'Payment amount must be greater than zero' using errcode = '22023'; end if;
  if p_method in ('bank_transfer','cheque') and nullif(trim(p_reference), '') is null then
    raise exception 'Enter the % reference number', replace(p_method, '_', ' ') using errcode = '22023';
  end if;
  insert into public.payments (payment_no, customer_id, method, amount, reference, run_id, delivery_id, location_id, received_by,
                               unallocated, notes, client_txn_id)
  values (app.next_document_number('PAY'), p_customer, p_method, round(p_amount, 2), nullif(trim(p_reference), ''), p_run, p_delivery,
          p_location, app.current_user_id(), round(p_amount, 2), nullif(trim(p_notes), ''), p_client_txn_id)
  returning id into v;
  perform app.post_payment(v);
  perform app.allocate_payment(v, p_first_invoice);
  return v;
end $$;

-- Which permission runs the till at this location
create or replace function app.pos_permission(p_location uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case (select location_type from public.locations where id = p_location) when 'water_shop' then 'shop_pos.use' else 'pos.use' end
$$;

create or replace function app.require_pos(p_location uuid)
returns void language plpgsql stable security definer set search_path = '' as $$
declare t text;
begin
  select location_type into t from public.locations where id = p_location and is_active;
  if t is null or t not in ('water_shop','warehouse','head_office') then
    raise exception 'This location does not have a till' using errcode = '22023';
  end if;
  perform app.require_permission_at(app.pos_permission(p_location), p_location);
end $$;

-- Payment posting picks the right cash account for counters and refunds
create or replace function app.post_payment(p_payment uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare pay public.payments; v_event text; v_je uuid; v_shop boolean;
begin
  select * into pay from public.payments where id = p_payment;
  v_shop := exists (select 1 from public.locations where id = pay.location_id and location_type = 'water_shop');
  v_event := case
    when pay.direction = 'out' and v_shop then 'refund.shop_cash'
    when pay.direction = 'out' then 'refund.cash'
    when pay.method = 'cash' and pay.run_id is not null then 'payment.driver_cash'
    when pay.method = 'cash' and v_shop then 'payment.shop_cash'
    when pay.method = 'cash' then 'payment.cash'
    when pay.method in ('card','qr') then 'payment.card'
    when pay.method = 'bank_transfer' then 'payment.bank'
    when pay.method = 'cheque' then 'payment.cheque' end;
  v_je := app.post_event(v_event, jsonb_build_object('amount', pay.amount), app.today(),
    format('%s %s (%s)', case when pay.direction = 'out' then 'Refund' else 'Payment' end, pay.payment_no, replace(pay.method, '_', ' ')),
    'payment', pay.id, pay.location_id, 'customer', pay.customer_id);
  update public.payments set journal_entry_id = v_je where id = p_payment;
end $$;

create or replace function public.open_pos_session(p_location uuid, p_float numeric, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v uuid; v_no text; v_prefix text; l public.locations; v_res jsonb;
begin
  perform app.require_pos(p_location);
  v_done := app.idempotency_begin(p_client_txn_id, 'open_pos_session');
  if v_done is not null then return v_done; end if;
  if exists (select 1 from public.pos_sessions where location_id = p_location and status = 'open') then
    raise exception 'A till is already open here. Close it first.' using errcode = '22023';
  end if;
  if (select status from public.water_shops where location_id = p_location) in ('suspended','closed') then
    raise exception 'This shop is not active' using errcode = '22023';
  end if;
  perform app.set_context(null, p_client_txn_id, 'open_till');
  select * into l from public.locations where id = p_location;
  v_no := app.next_document_number('PSN', p_location);
  v_prefix := 'R' || l.code || '-' || to_char(app.today(), 'YY') || right(v_no, 4);
  insert into public.pos_sessions (session_no, receipt_prefix, location_id, opening_float, opened_by, client_txn_id)
  values (v_no, v_prefix, p_location, coalesce(p_float, 0), app.current_user_id(), p_client_txn_id) returning id into v;
  perform set_config('app.audit_action', '', true);
  v_res := jsonb_build_object('session_id', v, 'session_no', v_no, 'receipt_prefix', v_prefix);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Find a registered customer at the counter
create or replace function public.pos_find_customer(p_location uuid, p_search text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; s public.water_shops; v_digits text := regexp_replace(regexp_replace(coalesce(p_search, ''), '[^0-9]', '', 'g'), '^0', '');
begin
  perform app.require_pos(p_location);
  s := app.shop_by_location(p_location);
  if length(trim(coalesce(p_search, ''))) < 2 then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(x), '[]') into v from (
    select jsonb_build_object('id', c.id, 'customer_no', c.customer_no, 'name', c.name, 'phone', c.phone,
             'bottle_model', c.bottle_model, 'allowed_bottles', c.allowed_bottles, 'credit_limit', c.credit_limit,
             'outstanding', app.customer_outstanding(c.id), 'ola_bottles', app.customer_ola_bottles(c.id),
             'external_policy', c.external_policy, 'status', c.status,
             'deposits_held', (select coalesce(jsonb_object_agg(bottle_type_id, qty_held), '{}') from public.customer_deposit_balances
                                where customer_id = c.id),
             'prices', case when s.operating_model = 'dealer' then null else
                (select coalesce(jsonb_object_agg(p.id, app.unit_price(p.id, c.price_list_id)), '{}') from public.products p
                  where p.is_active and exists (select 1 from public.price_list_items i where i.product_id = p.id
                        and i.price_list_id = c.price_list_id and i.effective_from <= app.today())) end) as x
      from public.customers c
     where not c.is_walk_in and c.status <> 'inactive'
       and (c.name ilike '%' || trim(p_search) || '%' or c.customer_no ilike '%' || trim(p_search) || '%'
            or (length(v_digits) >= 4 and c.phone like '%' || v_digits || '%'))
     order by c.name limit 10) q;
  return v;
end $$;

-- Everything the till needs, also cached on the device for offline use
create or replace function public.pos_bootstrap(p_location uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare l public.locations; s public.water_shops; v_list uuid; v_walk uuid; v jsonb; v_own uuid := app.own_company_id();
begin
  perform app.require_pos(p_location);
  select * into l from public.locations where id = p_location;
  s := app.shop_by_location(p_location);
  v_list := coalesce(s.retail_price_list_id, (select id from public.price_lists where code = 'RETAIL'));
  v_walk := coalesce(s.walk_in_customer_id, (select c.id from public.customers c where c.is_walk_in and c.notes = 'counter:' || p_location::text));
  select jsonb_build_object(
    'location', jsonb_build_object('id', l.id, 'code', l.code, 'name', l.name, 'type', l.location_type),
    'shop', case when s.id is null then null else jsonb_build_object('id', s.id, 'name', s.name, 'operating_model', s.operating_model,
                                                                     'phone', s.phone, 'address', s.address) end,
    'is_dealer', coalesce(s.operating_model = 'dealer', false),
    'walk_in_customer_id', v_walk,
    'walk_in_deposits', case when v_walk is null then '{}'::jsonb else
        (select coalesce(jsonb_object_agg(bottle_type_id, qty_held), '{}') from public.customer_deposit_balances where customer_id = v_walk) end,
    'walk_in_bottles', case when v_walk is null then 0 else app.customer_ola_bottles(v_walk) end,
    'includes_tax', (select prices_include_tax from public.price_lists where id = v_list),
    'company', jsonb_build_object('name', app.get_setting('company.name') #>> '{}', 'vat_no', app.get_setting('company.vat_registration_no') #>> '{}',
                                  'footer', app.get_setting('receipts.footer_text') #>> '{}'),
    'own_company_id', v_own,
    'companies', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'name', name, 'is_own', is_own, 'policy', acceptance_policy)
                    order by is_own desc, name), '[]') from public.bottle_companies where is_active),
    'bottle_types', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'name', name) order by size_litres desc), '[]')
                       from public.bottle_types where is_active),
    'products', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'sku', p.sku, 'name', p.name, 'barcode', p.barcode,
                    'is_returnable', p.is_returnable, 'bottle_type_id', p.bottle_type_id,
                    'price', (select unit_price from public.price_list_items i where i.product_id = p.id and i.price_list_id = v_list
                               and i.effective_from <= app.today() order by effective_from desc limit 1),
                    'tax_rate', (select rate_percent from public.tax_rates t where t.tax_code = p.tax_code and t.effective_from <= app.today()
                                  order by effective_from desc limit 1),
                    'stock', coalesce((select qty from public.inventory_balances b where b.location_id = p_location and b.product_id = p.id
                                        and b.stock_status = 'available'), 0)) order by p.sort_order, p.name), '[]')
                   from public.products p where p.is_active),
    'bottle_values', (select coalesce(jsonb_agg(jsonb_build_object('bottle_type_id', bt.id, 'company_id', bc.id,
                        'deposit', coalesce((app.bottle_value(bt.id, bc.id)).deposit_amount, 0),
                        'external_charge', coalesce((app.bottle_value(bt.id, bc.id)).external_charge, 0))), '[]')
                        from public.bottle_types bt cross join public.bottle_companies bc where bt.is_active and bc.is_active),
    'bottles_here', (select coalesce(jsonb_agg(jsonb_build_object('company_id', company_id, 'bottle_type_id', bottle_type_id,
                        'fill_state', fill_state, 'qty', qty)), '[]')
                        from public.bottle_balances where holder_type = 'location' and holder_id = p_location and qty <> 0),
    'settings', jsonb_build_object(
        'external_policy_default', app.get_setting('bottles.external_policy_default') #>> '{}',
        'discount_percent', coalesce((app.get_setting('approvals.discount_percent') #>> '{}')::numeric, 0),
        'can_discount', app.has_permission_at('pos.discount', p_location)),
    'session', (select jsonb_build_object('id', id, 'session_no', session_no, 'receipt_prefix', receipt_prefix, 'opening_float', opening_float,
                  'opened_at', opened_at, 'opened_by', (select full_name from public.profiles where id = opened_by),
                  'next_seq', (select count(*) + 1 from public.pos_sales ps where ps.session_id = s2.id),
                  'cash_in', (select coalesce(sum(cash_in - cash_out), 0) from public.pos_sales ps where ps.session_id = s2.id),
                  'card_in', (select coalesce(sum(card_in), 0) from public.pos_sales ps where ps.session_id = s2.id),
                  'sales', (select count(*) from public.pos_sales ps where ps.session_id = s2.id))
                  from public.pos_sessions s2 where s2.location_id = p_location and s2.status = 'open'),
    'fetched_at', now()
  ) into v;
  return v;
end $$;

-- A counter sale. p: {customer_id (null = walk-in), seq, lines:[{product_id, qty, discount}],
--   ola_returned_codes, ola_returned_counts, external, default_bottle_type_id,
--   payments:[{method, amount, reference}], tendered, sold_at}
create or replace function public.pos_sale(p_session uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; ss public.pos_sessions; s public.water_shops; c public.customers; l jsonb; v_list uuid; v_inc boolean;
  v_priced jsonb := '[]'; v_price numeric; v_gross numeric; v_limit numeric; v_post boolean; core jsonb; v_id uuid := gen_random_uuid();
  v_receipt text; v_seq integer := app.jint(p, 'seq'); pay jsonb; v_amount numeric; v_due numeric; v_applied numeric;
  v_cash numeric := 0; v_cash_out numeric := 0; v_card numeric := 0; v_other numeric := 0; v_paid numeric := 0; v_tendered numeric := app.jnum(p, 'tendered');
  v_change numeric := 0; v_payments jsonb := '[]'; v_res jsonb; v_ln integer := 0; v_walk boolean; v_flags text[] := '{}';
  v_sold_at timestamptz := coalesce((app.jtext(p, 'sold_at'))::timestamptz, now()); v_refund_id uuid;
begin
  v_done := app.idempotency_begin(p_client_txn_id, 'pos_sale');
  if v_done is not null then return v_done; end if;
  select * into ss from public.pos_sessions where id = p_session for update;
  if not found then raise exception 'Till session not found' using errcode = 'P0002'; end if;
  perform app.require_pos(ss.location_id);
  perform app.set_context(null, p_client_txn_id, null);
  s := app.shop_by_location(ss.location_id);
  v_post := coalesce(s.operating_model, 'company_owned') <> 'dealer';

  if app.juuid(p, 'customer_id') is not null then
    select * into c from public.customers where id = app.juuid(p, 'customer_id');
    if not found then raise exception 'Customer not found' using errcode = 'P0002'; end if;
  else
    select * into c from public.customers where id = app.walk_in_customer(ss.location_id);
  end if;
  v_walk := c.is_walk_in;

  -- price list: dealer shops always sell at the shop's retail prices; otherwise the customer's own list
  v_list := case when not v_post or v_walk then coalesce(s.retail_price_list_id, (select id from public.price_lists where code = 'RETAIL'))
                 else c.price_list_id end;
  select prices_include_tax into v_inc from public.price_lists where id = v_list;
  v_limit := coalesce((app.get_setting('approvals.discount_percent') #>> '{}')::numeric, 0);

  for l in select * from jsonb_array_elements(coalesce(p -> 'lines', '[]')) loop
    continue when coalesce(app.jnum(l, 'qty'), 0) <= 0;
    v_price := app.unit_price(app.juuid(l, 'product_id'), v_list);
    v_gross := app.jnum(l, 'qty') * v_price;
    if coalesce(app.jnum(l, 'discount'), 0) > 0 and v_gross > 0 and app.jnum(l, 'discount') / v_gross * 100 > v_limit
       and not app.has_permission_at('pos.discount', ss.location_id) then
      v_flags := v_flags || format('Discount over %s%% without approval', v_limit);
    end if;
    v_priced := v_priced || jsonb_build_object('product_id', app.juuid(l, 'product_id'), 'qty', app.jnum(l, 'qty'),
                                               'unit_price', v_price, 'discount', coalesce(app.jnum(l, 'discount'), 0));
  end loop;

  core := app.sale_core(c.id, ss.location_id, v_priced, v_inc, p, 'pos_sale', v_id, null, v_post, true, null,
            jsonb_build_object('event', case when s.id is null then 'invoice.issued' else 'invoice.shop' end, 'client_txn_id', p_client_txn_id));
  v_due := (core ->> 'total')::numeric;

  -- payments
  for pay in select * from jsonb_array_elements(coalesce(p -> 'payments', '[]')) loop
    v_amount := round(coalesce(app.jnum(pay, 'amount'), 0), 2);
    continue when v_amount <= 0 or app.jtext(pay, 'method') = 'credit';
    if app.jtext(pay, 'method') not in ('cash','card','qr','bank_transfer','cheque') then
      raise exception 'Unknown payment method' using errcode = '22023';
    end if;
    v_applied := case when v_walk then least(v_amount, greatest(v_due - v_paid, 0)) else v_amount end;
    continue when v_applied <= 0;
    if v_post then
      perform app.create_payment(c.id, app.jtext(pay, 'method'), v_applied,
        case when app.jtext(pay, 'method') in ('bank_transfer','cheque') then coalesce(app.jtext(pay, 'reference'), 'Not recorded at the counter')
             else app.jtext(pay, 'reference') end, null, null,
        (core ->> 'invoice_id')::uuid, 'Receipt ' || coalesce(ss.receipt_prefix || '-' || lpad(v_seq::text, 4, '0'), ''), null, ss.location_id);
    end if;
    v_paid := v_paid + v_applied;
    if app.jtext(pay, 'method') = 'cash' then v_cash := v_cash + v_applied;
    elsif app.jtext(pay, 'method') in ('card','qr') then v_card := v_card + v_applied;
    else v_other := v_other + v_applied; end if;
    v_payments := v_payments || jsonb_build_object('method', app.jtext(pay, 'method'), 'amount', v_applied, 'reference', app.jtext(pay, 'reference'));
  end loop;

  -- a negative total (deposit refund bigger than the purchase) is paid out in cash
  if v_due < 0 then
    v_cash_out := -v_due;
    if v_post then
      insert into public.payments (payment_no, customer_id, method, amount, direction, location_id, received_by, unallocated, notes)
      values (app.next_document_number('PAY'), c.id, 'cash', v_cash_out, 'out', ss.location_id, app.current_user_id(), 0, 'Deposit refund at the counter')
      returning id into v_refund_id;
      perform app.post_payment(v_refund_id);
    end if;
    v_payments := v_payments || jsonb_build_object('method', 'cash', 'amount', -v_cash_out, 'reference', 'Refund');
  end if;

  if v_tendered is not null and v_cash > 0 then v_change := greatest(v_tendered - v_cash, 0); end if;
  if v_due > 0 and v_paid < v_due then
    if v_walk then
      v_flags := v_flags || format('Walk-in sale not fully paid (Rs. %s short)', to_char(v_due - v_paid, 'FM999,999,990.00'));
    elsif c.credit_limit <= 0 then
      v_flags := v_flags || format('%s has no credit but left Rs. %s unpaid', c.name, to_char(v_due - v_paid, 'FM999,999,990.00'));
    elsif app.customer_outstanding(c.id) > c.credit_limit then
      v_flags := v_flags || format('%s is now over the credit limit', c.name);
    end if;
  end if;
  if ss.status = 'closed' then v_flags := v_flags || 'Sale reached the system after the till was closed'::text; end if;
  if array_length(v_flags, 1) > 0 then
    perform app.raise_exception_record('credit_limit', array_to_string(v_flags, '; ') || ' — receipt ' ||
      coalesce(ss.receipt_prefix || '-' || lpad(v_seq::text, 4, '0'), ''), 'warning', null, ss.location_id, c.id);
  end if;

  v_receipt := ss.receipt_prefix || '-' || lpad(coalesce(v_seq, (select count(*) + 1 from public.pos_sales where session_id = ss.id))::text, 4, '0');
  if exists (select 1 from public.pos_sales where receipt_no = v_receipt) then
    v_receipt := v_receipt || '-' || left(replace(p_client_txn_id::text, '-', ''), 4);
  end if;

  v_res := jsonb_build_object(
    'sale_id', v_id, 'receipt_no', v_receipt, 'invoice_id', core -> 'invoice_id', 'invoice_no', core -> 'invoice_no', 'is_walk_in', v_walk,
    'is_tax_invoice', c.vat_no is not null and v_post, 'created_at', v_sold_at,
    'customer', jsonb_build_object('name', c.name, 'customer_no', c.customer_no, 'vat_no', c.vat_no),
    'location', (select name from public.locations where id = ss.location_id),
    'staff', (select full_name from public.profiles where id = app.current_user_id()),
    'lines', core -> 'lines', 'subtotal_net', core -> 'net', 'tax_total', core -> 'tax', 'total', v_due,
    'paid', v_paid, 'payments', v_payments, 'method', (v_payments -> 0 ->> 'method'), 'tendered', v_tendered, 'change', v_change,
    'outstanding', case when v_walk or not v_post then 0 else app.customer_outstanding(c.id) end,
    'bottles', jsonb_build_object('issued', core -> 'issued', 'returned', core -> 'returned', 'external', core -> 'external',
                                  'balance', case when v_walk then null else app.customer_ola_bottles(c.id) end),
    'flags', to_jsonb(v_flags));

  insert into public.pos_sales (id, receipt_no, session_id, location_id, customer_id, is_walk_in, posted, sold_at, subtotal_net, tax_total,
    total, cash_in, cash_out, card_in, other_in, on_account, tendered, change_given, payments, invoice_id, summary, created_by, client_txn_id)
  values (v_id, v_receipt, ss.id, ss.location_id, c.id, v_walk, v_post, v_sold_at, (core ->> 'net')::numeric, (core ->> 'tax')::numeric,
    v_due, v_cash, v_cash_out, v_card, v_other, greatest(v_due - v_paid, 0), v_tendered, v_change, v_payments,
    (core ->> 'invoice_id')::uuid, v_res, app.current_user_id(), p_client_txn_id);

  for l in select * from jsonb_array_elements(core -> 'lines') loop
    v_ln := v_ln + 1;
    insert into public.pos_sale_lines (sale_id, line_no, line_type, product_id, description, qty, unit_price, discount, net, tax, total, unit_cost)
    values (v_id, v_ln, app.jtext(l, 'line_type'), app.juuid(l, 'product_id'), app.jtext(l, 'description'), app.jnum(l, 'qty'),
      app.jnum(l, 'unit_price'), coalesce(app.jnum(l, 'discount'), 0), app.jnum(l, 'net'), coalesce(app.jnum(l, 'tax'), 0), app.jnum(l, 'total'),
      (select cost_price from public.products where id = app.juuid(l, 'product_id')));
  end loop;

  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Daily closing: count cash, card slips, stock and bottles; every difference becomes an exception.
-- p: {cash_counted, card_counted, products:[{product_id, qty}], bottles:[{company_id, bottle_type_id, fill_state, qty}], notes}
create or replace function public.close_pos_session(p_session uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; ss public.pos_sessions; v_cash_exp numeric; v_card_exp numeric; v_counted numeric := app.jnum(p, 'cash_counted');
  bal record; v_actual numeric; v_exc integer := 0; v_lines jsonb := '[]'; v_own uuid := app.own_company_id(); v_res jsonb;
  v_loc_name text;
begin
  v_done := app.idempotency_begin(p_client_txn_id, 'close_pos_session');
  if v_done is not null then return v_done; end if;
  select * into ss from public.pos_sessions where id = p_session for update;
  if not found then raise exception 'Till session not found' using errcode = 'P0002'; end if;
  perform app.require_pos(ss.location_id);
  if ss.status <> 'open' then raise exception 'This till is already closed' using errcode = '22023'; end if;
  if v_counted is null then raise exception 'Count the cash in the drawer' using errcode = '22023'; end if;
  perform app.set_context(app.jtext(p, 'notes'), p_client_txn_id, 'close_till');
  select name into v_loc_name from public.locations where id = ss.location_id;

  select ss.opening_float + coalesce(sum(cash_in - cash_out), 0), coalesce(sum(card_in), 0) into v_cash_exp, v_card_exp
    from public.pos_sales where session_id = ss.id;

  if v_counted <> v_cash_exp then
    v_exc := v_exc + 1;
    insert into public.operation_exceptions (exception_type, severity, location_id, expected, actual, difference, description,
      source_type, source_id, created_by)
    values (case when v_counted < v_cash_exp then 'cash_shortage' else 'cash_surplus' end,
      case when v_counted < v_cash_exp then 'critical' else 'warning' end, ss.location_id, v_cash_exp, v_counted, v_counted - v_cash_exp,
      format('%s till %s: Rs. %s expected in the drawer, Rs. %s counted', v_loc_name, ss.session_no,
             to_char(v_cash_exp, 'FM999,999,990.00'), to_char(v_counted, 'FM999,999,990.00')),
      'pos_session', ss.id, app.current_user_id());
  end if;
  v_lines := v_lines || jsonb_build_object('item', 'Cash', 'expected', v_cash_exp, 'actual', v_counted);
  if app.jnum(p, 'card_counted') is not null then
    v_lines := v_lines || jsonb_build_object('item', 'Card / QR (terminal)', 'expected', v_card_exp, 'actual', app.jnum(p, 'card_counted'));
  end if;

  -- products: only counted when a count was entered
  if jsonb_array_length(coalesce(p -> 'products', '[]')) > 0 then
    for bal in select b.product_id, b.qty, pr.name, pr.is_returnable from public.inventory_balances b join public.products pr on pr.id = b.product_id
                where b.location_id = ss.location_id and b.stock_status = 'available'
               union
               select app.juuid(x, 'product_id'), 0, pr.name, pr.is_returnable
                 from jsonb_array_elements(p -> 'products') x join public.products pr on pr.id = app.juuid(x, 'product_id')
                where not exists (select 1 from public.inventory_balances b where b.location_id = ss.location_id
                                    and b.product_id = app.juuid(x, 'product_id') and b.stock_status = 'available')
    loop
      select sum(app.jnum(x, 'qty')) into v_actual from jsonb_array_elements(p -> 'products') x where app.juuid(x, 'product_id') = bal.product_id;
      continue when v_actual is null;
      v_lines := v_lines || jsonb_build_object('item', bal.name, 'expected', bal.qty, 'actual', v_actual);
      continue when v_actual = bal.qty;
      v_exc := v_exc + 1;
      insert into public.operation_exceptions (exception_type, severity, location_id, product_id, fill_state, expected, actual, difference,
        description, source_type, source_id, created_by)
      values (case when v_actual < bal.qty then 'stock_shortage' else 'stock_surplus' end, case when v_actual < bal.qty then 'critical' else 'warning' end,
        ss.location_id, bal.product_id, case when bal.is_returnable then 'full' end, bal.qty, v_actual, v_actual - bal.qty,
        format('%s closing: %s — %s expected, %s counted', v_loc_name, bal.name, bal.qty::integer, v_actual::integer),
        'pos_session', ss.id, app.current_user_id());
    end loop;
  end if;

  -- bottles: empties of every company (full OLA bottles are the 19L stock above)
  if jsonb_array_length(coalesce(p -> 'bottles', '[]')) > 0 then
    for bal in select company_id, bottle_type_id, fill_state, sum(qty)::integer qty from (
                 select company_id, bottle_type_id, fill_state, qty from public.bottle_balances
                  where holder_type = 'location' and holder_id = ss.location_id and not (company_id = v_own and fill_state = 'full')
                 union all
                 select app.juuid(x, 'company_id'), app.juuid(x, 'bottle_type_id'), coalesce(app.jtext(x, 'fill_state'), 'empty'), 0
                   from jsonb_array_elements(p -> 'bottles') x) t
                group by company_id, bottle_type_id, fill_state
    loop
      select sum(app.jint(x, 'qty')) into v_actual from jsonb_array_elements(p -> 'bottles') x
       where app.juuid(x, 'company_id') = bal.company_id and app.juuid(x, 'bottle_type_id') = bal.bottle_type_id
         and coalesce(app.jtext(x, 'fill_state'), 'empty') = bal.fill_state;
      continue when v_actual is null;
      v_lines := v_lines || jsonb_build_object('item', (select name from public.bottle_companies where id = bal.company_id) || ' ' ||
                 (select name from public.bottle_types where id = bal.bottle_type_id) || ' ' || bal.fill_state, 'expected', bal.qty, 'actual', v_actual);
      continue when v_actual = bal.qty;
      v_exc := v_exc + 1;
      insert into public.operation_exceptions (exception_type, severity, location_id, company_id, bottle_type_id, fill_state, expected, actual,
        difference, description, source_type, source_id, created_by)
      values (case when v_actual < bal.qty then 'bottle_shortage' else 'bottle_surplus' end, case when v_actual < bal.qty then 'critical' else 'warning' end,
        ss.location_id, bal.company_id, bal.bottle_type_id, bal.fill_state, bal.qty, v_actual, v_actual - bal.qty,
        format('%s closing: %s %s bottles (%s) — %s expected, %s counted', v_loc_name,
          (select name from public.bottle_companies where id = bal.company_id), (select name from public.bottle_types where id = bal.bottle_type_id),
          bal.fill_state, bal.qty, v_actual::integer), 'pos_session', ss.id, app.current_user_id());
    end loop;
  end if;

  update public.pos_sessions set status = 'closed', closed_at = now(), closed_by = app.current_user_id(), cash_expected = v_cash_exp,
         cash_counted = v_counted, card_expected = v_card_exp, card_counted = app.jnum(p, 'card_counted'), counts = v_lines,
         exceptions = v_exc, notes = app.jtext(p, 'notes')
   where id = ss.id;
  perform set_config('app.audit_action', '', true);
  v_res := jsonb_build_object('session_no', ss.session_no, 'exceptions', v_exc, 'lines', v_lines, 'cash_expected', v_cash_exp,
                              'cash_counted', v_counted, 'card_expected', v_card_exp);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.record_pos_receipt_print(p_sale uuid, p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
declare s public.pos_sales;
begin
  select * into s from public.pos_sales where id = p_sale for update;
  if not found then raise exception 'Sale not found' using errcode = 'P0002'; end if;
  perform app.require_pos(s.location_id);
  if s.print_count > 0 and nullif(trim(p_reason), '') is null then raise exception 'A reason is required to reprint' using errcode = '22023'; end if;
  perform app.write_audit(case when s.print_count > 0 then 'reprint' else 'print' end, 'pos', 'pos_sales', s.id::text, null,
    jsonb_build_object('receipt_no', s.receipt_no), nullif(trim(p_reason), ''));
  update public.pos_sales set print_count = print_count + 1 where id = p_sale;
  return s.print_count + 1;
end $$;

-- ---------------------------------------------------------------------
-- Settlements
-- ---------------------------------------------------------------------
create table public.shop_settlements (
  id               uuid primary key default gen_random_uuid(),
  settlement_no    text not null unique,
  shop_id          uuid not null references public.water_shops(id),
  period_from      date not null,
  period_to        date not null,
  operating_model  text not null,
  figures          jsonb not null,
  cash_expected    numeric(14,2) not null default 0,
  amount_received  numeric(14,2) not null default 0,
  method           text,
  reference        text,
  payment_id       uuid references public.payments(id),
  commission       numeric(14,2) not null default 0,
  notes            text,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  client_txn_id    uuid unique,
  check (period_to >= period_from)
);
create index shop_settlements_shop_idx on public.shop_settlements (shop_id, period_to desc);
create trigger shop_settlements_append_only before update or delete on public.shop_settlements for each row execute function app.forbid_change();
create trigger shop_settlements_audit after insert on public.shop_settlements for each row execute function app.audit_row('shops');
alter table public.pos_sessions add constraint pos_sessions_settlement_fk foreign key (settlement_id) references public.shop_settlements(id);

-- Figures for a shop over a period (used by settlements, statements and the shop dashboard)
create or replace function app.shop_figures(p_shop uuid, p_from date, p_to date)
returns jsonb language sql stable security definer set search_path = '' as $$
  with s as (select * from public.water_shops where id = p_shop),
  sales as (
    select ps.* from public.pos_sales ps, s
     where ps.location_id = s.location_id and (ps.sold_at at time zone 'Asia/Colombo')::date between p_from and p_to),
  lines as (select l.* from public.pos_sale_lines l join sales on sales.id = l.sale_id)
  select jsonb_build_object(
    'sales_count', (select count(*) from sales),
    'sales_total', (select coalesce(sum(total), 0) from sales),
    'net_sales', (select coalesce(sum(net), 0) from lines where line_type = 'product'),
    'vat', (select coalesce(sum(tax), 0) from lines),
    'deposits_net', (select coalesce(sum(case when line_type = 'deposit' then total when line_type = 'deposit_refund' then total else 0 end), 0) from lines),
    'cash', (select coalesce(sum(cash_in - cash_out), 0) from sales),
    'card_qr', (select coalesce(sum(card_in), 0) from sales),
    'bank_cheque', (select coalesce(sum(other_in), 0) from sales),
    'credit', (select coalesce(sum(on_account), 0) from sales),
    'cost_of_sales', (select coalesce(sum(qty * coalesce(unit_cost, 0)), 0) from lines where line_type = 'product'),
    'by_product', (select coalesce(jsonb_agg(x order by x ->> 'product'), '[]') from (
        select jsonb_build_object('product', description, 'qty', sum(qty), 'total', sum(total)) x
          from lines where line_type = 'product' group by description) q),
    'transfers_received', (select coalesce(sum(i.total), 0) from public.invoices i, s
        where s.operating_model = 'dealer' and i.customer_id = s.account_customer_id and i.status <> 'void' and i.invoice_date between p_from and p_to),
    'payments_to_ola', (select coalesce(sum(p.amount), 0) from public.payments p, s
        where s.operating_model = 'dealer' and p.customer_id = s.account_customer_id and p.direction = 'in' and p.status = 'received'
          and (p.received_at at time zone 'Asia/Colombo')::date between p_from and p_to),
    'outstanding_to_ola', (select case when s.operating_model = 'dealer' then app.customer_outstanding(s.account_customer_id) else 0 end from s),
    'stock', (select coalesce(jsonb_agg(jsonb_build_object('product', pr.name, 'qty', b.qty, 'value', b.qty * pr.cost_price)), '[]')
                from public.inventory_balances b join public.products pr on pr.id = b.product_id, s
               where b.location_id = s.location_id and b.stock_status = 'available' and b.qty <> 0),
    'bottles', (select coalesce(jsonb_agg(jsonb_build_object('company', bc.name, 'type', bt.name, 'fill_state', b.fill_state, 'qty', b.qty)), '[]')
                  from public.bottle_balances b join public.bottle_companies bc on bc.id = b.company_id
                  join public.bottle_types bt on bt.id = b.bottle_type_id, s
                 where b.holder_type = 'location' and b.holder_id = s.location_id and b.qty <> 0),
    'walk_in_bottles', (select app.customer_ola_bottles(s.walk_in_customer_id) from s),
    'open_exceptions', (select count(*) from public.operation_exceptions e, s
        where e.status = 'open' and (e.location_id = s.location_id or e.target_location_id = s.location_id)))
$$;

-- p: {amount_received, method, reference, notes}
--   company-owned: amount banked from the shop's takings (closed, unsettled tills)
--   dealer:        payment received from the dealer against its account
create or replace function public.create_shop_settlement(p_shop uuid, p_from date, p_to date, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; s public.water_shops; f jsonb; v_no text; v_id uuid := gen_random_uuid(); v_amt numeric := coalesce(app.jnum(p, 'amount_received'), 0);
  v_method text := coalesce(app.jtext(p, 'method'), 'bank_transfer'); v_expected numeric := 0; v_commission numeric := 0; v_pay uuid; v_res jsonb;
begin
  perform app.require_permission('shops.settle');
  if p_to < p_from then raise exception 'The period end is before its start' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'create_shop_settlement');
  if v_done is not null then return v_done; end if;
  select * into s from public.water_shops where id = p_shop for update;
  if not found then raise exception 'Shop not found' using errcode = 'P0002'; end if;
  perform app.set_context(app.jtext(p, 'notes'), p_client_txn_id, 'settle');
  f := app.shop_figures(s.id, p_from, p_to);
  v_no := app.next_document_number('SET', s.location_id);

  if s.operating_model = 'company_owned' then
    if exists (select 1 from public.pos_sessions where location_id = s.location_id and status = 'open'
                 and (opened_at at time zone 'Asia/Colombo')::date <= p_to) then
      raise exception 'Close the till for this period before settling' using errcode = '22023';
    end if;
    select coalesce(sum(cash_counted - opening_float), 0) into v_expected from public.pos_sessions
     where location_id = s.location_id and status = 'closed' and settlement_id is null
       and (opened_at at time zone 'Asia/Colombo')::date between p_from and p_to;
    if v_amt > 0 then
      if v_method = 'bank_transfer' and app.jtext(p, 'reference') is null then
        raise exception 'Enter the bank deposit reference' using errcode = '22023';
      end if;
      perform app.post_event('shop.cash_remit', jsonb_build_object('amount', v_amt), app.today(),
        format('%s — takings banked from %s', v_no, s.name), 'shop_settlement', v_id, s.location_id);
    end if;
    if v_amt < v_expected then
      update public.operation_exceptions set source_type = 'shop_settlement', source_id = v_id
       where id = app.raise_exception_record('cash_shortage', format('%s: Rs. %s counted at closing, Rs. %s banked', v_no,
        to_char(v_expected, 'FM999,999,990.00'), to_char(v_amt, 'FM999,999,990.00')), 'critical', null, s.location_id,
        null, null, null, null, null, v_expected, v_amt);
    end if;
    v_commission := round((f ->> 'net_sales')::numeric * s.commission_percent / 100, 2);
    if v_commission > 0 then
      perform app.post_event('shop.commission', jsonb_build_object('amount', v_commission), app.today(),
        format('%s — commission %s%% on %s', v_no, s.commission_percent, s.name), 'shop_settlement', v_id, s.location_id);
    end if;
  else
    v_expected := (f ->> 'outstanding_to_ola')::numeric;
    if v_amt > 0 then
      v_pay := app.create_payment(s.account_customer_id, v_method, v_amt, app.jtext(p, 'reference'), null, null, null,
                                  'Settlement ' || v_no, null, null);
    end if;
  end if;

  insert into public.shop_settlements (id, settlement_no, shop_id, period_from, period_to, operating_model, figures, cash_expected,
    amount_received, method, reference, payment_id, commission, notes, created_by, client_txn_id)
  values (v_id, v_no, s.id, p_from, p_to, s.operating_model, f || jsonb_build_object('outstanding_after',
      case when s.operating_model = 'dealer' then app.customer_outstanding(s.account_customer_id) end),
    v_expected, v_amt, case when v_amt > 0 then v_method end, app.jtext(p, 'reference'), v_pay, v_commission, app.jtext(p, 'notes'),
    app.current_user_id(), p_client_txn_id);
  if s.operating_model = 'company_owned' then
    update public.pos_sessions set settlement_id = v_id where location_id = s.location_id and status = 'closed' and settlement_id is null
       and (opened_at at time zone 'Asia/Colombo')::date between p_from and p_to;
  end if;
  v_res := jsonb_build_object('settlement_id', v_id, 'settlement_no', v_no, 'expected', v_expected, 'received', v_amt, 'commission', v_commission);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- Exceptions: resolution for shops, transfers and tills (runs unchanged)
-- ---------------------------------------------------------------------
create or replace function public.resolve_exception(p_id uuid, p_resolution text, p_note text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; e public.operation_exceptions; r public.route_runs; v_qty integer; v_amount numeric; v_own uuid := app.own_company_id();
  v_dest uuid; bv public.bottle_values; pr public.products; v_veh uuid; v_ola boolean; v_shop public.water_shops;
begin
  if nullif(trim(p_note), '') is null then raise exception 'Explain the resolution' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'resolve_exception');
  if v_done is not null then return v_done; end if;
  select * into e from public.operation_exceptions where id = p_id for update;
  if not found then raise exception 'Exception not found' using errcode = 'P0002'; end if;
  if e.status = 'resolved' then raise exception 'Already resolved' using errcode = '22023'; end if;
  if e.run_id is not null then
    perform app.require_permission('deliveries.reconcile');
  elsif not (app.has_permission('deliveries.reconcile') or app.has_permission('shops.settle') or app.has_permission('inventory.adjust')) then
    raise exception 'Permission denied: deliveries.reconcile, shops.settle or inventory.adjust is required' using errcode = '42501';
  end if;
  perform app.set_context(trim(p_note), p_client_txn_id, 'resolve');

  if e.run_id is not null then
    select * into r from public.route_runs where id = e.run_id; v_veh := app.vehicle_location(e.run_id);

    if e.exception_type = 'bottle_shortage' then
      v_qty := (e.expected - e.actual)::integer;
      v_dest := case when e.company_id = v_own then r.load_location_id
                     else (select id from public.locations where location_type = 'external_holding' order by created_at limit 1) end;
      bv := app.bottle_value(e.bottle_type_id, e.company_id);
      if p_resolution = 'found' then
        perform app.bottle_move(case when e.company_id = v_own then 'check_in' else 'to_external_holding' end, e.company_id, e.bottle_type_id,
          v_qty, 'location', v_veh, 'empty', 'location', v_dest, 'empty', 'exception', e.id);
      elsif p_resolution in ('write_off','charge_driver') then
        if p_resolution = 'write_off' then perform app.require_permission('bottles.writeoff'); end if;
        perform app.bottle_move('write_off', e.company_id, e.bottle_type_id, v_qty, 'location', v_veh, 'empty', 'outside', app.outside_id(), 'empty',
          'exception', e.id);
        v_amount := v_qty * coalesce(bv.replacement_value, 0);
        if p_resolution = 'write_off' and e.company_id = v_own and v_amount > 0 then
          perform app.post_event('bottle.writeoff', jsonb_build_object('value', v_amount), app.today(),
            'Bottles written off: ' || e.description, 'exception', e.id);
        elsif p_resolution = 'charge_driver' and v_amount > 0 then
          perform app.post_event('driver.bottle_charge', jsonb_build_object('amount', v_amount), app.today(),
            'Bottles charged to driver: ' || e.description, 'exception', e.id, null, 'driver', r.driver_id);
        end if;
      elsif p_resolution <> 'accepted' then
        raise exception 'Unsupported resolution' using errcode = '22023';
      end if;

    elsif e.exception_type = 'stock_shortage' then
      v_qty := (e.expected - e.actual)::integer;
      select * into pr from public.products where id = e.product_id;
      if p_resolution = 'found' then
        perform app.stock_move('check_in', pr.id, v_qty, v_veh, r.load_location_id, 'exception', e.id);
        if pr.is_returnable then
          perform app.bottle_move('check_in', v_own, pr.bottle_type_id, v_qty, 'location', v_veh, 'full', 'location', r.load_location_id, 'full',
            'exception', e.id);
        end if;
      elsif p_resolution in ('write_off','charge_driver') then
        perform app.require_permission('inventory.adjust');
        perform app.stock_move('adjust_loss', pr.id, v_qty, v_veh, null, 'exception', e.id);
        if pr.is_returnable then
          perform app.bottle_move('write_off', v_own, pr.bottle_type_id, v_qty, 'location', v_veh, 'full', 'outside', app.outside_id(), 'empty',
            'exception', e.id);
        end if;
        if pr.cost_price > 0 then
          perform app.post_event(case when p_resolution = 'write_off' then 'stock.adjust_loss' else 'driver.stock_charge' end,
            jsonb_build_object('value', v_qty * pr.cost_price, 'amount', v_qty * pr.cost_price), app.today(),
            'Stock shortage: ' || e.description, 'exception', e.id, null,
            case when p_resolution = 'charge_driver' then 'driver' end, case when p_resolution = 'charge_driver' then r.driver_id end);
        end if;
      elsif p_resolution <> 'accepted' then
        raise exception 'Unsupported resolution' using errcode = '22023';
      end if;

    elsif e.exception_type = 'cash_shortage' then
      v_amount := e.expected - e.actual;
      if p_resolution = 'found' then
        perform app.post_event('driver.cash_handover', jsonb_build_object('amount', v_amount), app.today(),
          'Shortage handed in: ' || r.run_no, 'exception', e.id, null, 'driver', r.driver_id);
      elsif p_resolution = 'write_off' then
        perform app.require_permission('accounting.manual_journal');
        perform app.post_event('driver.cash_shortage', jsonb_build_object('amount', v_amount), app.today(),
          'Cash shortage written off: ' || r.run_no, 'exception', e.id, null, 'driver', r.driver_id);
      elsif p_resolution not in ('charge_driver','accepted') then
        raise exception 'Unsupported resolution' using errcode = '22023';
      end if;

    elsif p_resolution <> 'accepted' then
      raise exception 'This exception can only be acknowledged' using errcode = '22023';
    end if;

  else
    -- shops, transfers in transit, tills and counters
    v_ola := app.location_is_ola(e.location_id);
    v_shop := app.shop_by_location(coalesce(e.target_location_id, e.location_id));

    if e.exception_type = 'stock_shortage' then
      v_qty := (e.expected - e.actual)::integer;
      select * into pr from public.products where id = e.product_id;
      if p_resolution = 'found' then
        if e.target_location_id is not null then
          -- goods turned up at the shop after all
          perform app.stock_move('transfer', pr.id, v_qty, e.location_id, e.target_location_id, 'exception', e.id);
          if pr.is_returnable then
            perform app.bottle_move('transfer', v_own, pr.bottle_type_id, v_qty, 'location', e.location_id, 'full',
              'location', e.target_location_id, 'full', 'exception', e.id);
          end if;
          if v_shop.operating_model = 'dealer' then
            perform app.invoice_dealer_transfer(v_shop.id, jsonb_build_array(jsonb_build_object('product_id', pr.id, 'qty', v_qty)), 'exception', e.id);
          end if;
        end if;  -- otherwise: recount found the stock, nothing moves
      elsif p_resolution = 'write_off' then
        perform app.require_permission('inventory.adjust');
        perform app.stock_move('adjust_loss', pr.id, v_qty, e.location_id, null, 'exception', e.id);
        if pr.is_returnable then
          perform app.bottle_move('write_off', v_own, pr.bottle_type_id, v_qty, 'location', e.location_id, 'full', 'outside', app.outside_id(), 'empty',
            'exception', e.id);
        end if;
        if v_ola and pr.cost_price > 0 then
          perform app.post_event('stock.adjust_loss', jsonb_build_object('value', v_qty * pr.cost_price), app.today(),
            'Stock shortage: ' || e.description, 'exception', e.id, e.location_id);
        end if;
      elsif p_resolution <> 'accepted' then
        raise exception 'Unsupported resolution' using errcode = '22023';
      end if;

    elsif e.exception_type in ('stock_surplus','negative_balance') then
      if p_resolution = 'found' and e.exception_type = 'stock_surplus' and e.target_location_id is null then
        v_qty := (e.actual - e.expected)::integer;
        select * into pr from public.products where id = e.product_id;
        perform app.require_permission('inventory.adjust');
        perform app.stock_move('adjust_gain', pr.id, v_qty, null, e.location_id, 'exception', e.id);
        if v_ola and pr.cost_price > 0 then
          perform app.post_event('stock.adjust_gain', jsonb_build_object('value', v_qty * pr.cost_price), app.today(),
            'Stock surplus: ' || e.description, 'exception', e.id, e.location_id);
        end if;
      elsif p_resolution <> 'accepted' then
        raise exception 'This difference can only be acknowledged or (for a counted surplus) brought into stock' using errcode = '22023';
      end if;

    elsif e.exception_type = 'bottle_shortage' then
      v_qty := (e.expected - e.actual)::integer;
      if p_resolution = 'write_off' then
        perform app.require_permission('bottles.writeoff');
        perform app.bottle_move('write_off', e.company_id, e.bottle_type_id, v_qty, 'location', e.location_id, coalesce(e.fill_state, 'empty'),
          'outside', app.outside_id(), 'empty', 'exception', e.id);
        bv := app.bottle_value(e.bottle_type_id, e.company_id);
        if e.company_id = v_own and coalesce(bv.replacement_value, 0) * v_qty > 0 then
          perform app.post_event('bottle.writeoff', jsonb_build_object('value', v_qty * bv.replacement_value), app.today(),
            'Bottles written off: ' || e.description, 'exception', e.id, e.location_id);
        end if;
      elsif p_resolution not in ('found','accepted') then
        raise exception 'Unsupported resolution' using errcode = '22023';
      end if;

    elsif e.exception_type = 'bottle_surplus' then
      if p_resolution = 'found' and e.source_type = 'pos_session' then
        perform app.bottle_move('found', e.company_id, e.bottle_type_id, (e.actual - e.expected)::integer, 'outside', app.outside_id(),
          coalesce(e.fill_state, 'empty'), 'location', e.location_id, coalesce(e.fill_state, 'empty'), 'exception', e.id);
      elsif p_resolution not in ('found','accepted') then
        raise exception 'Unsupported resolution' using errcode = '22023';
      end if;

    elsif e.exception_type = 'cash_shortage' then
      v_amount := e.expected - e.actual;
      if p_resolution = 'write_off' then
        perform app.require_permission('accounting.manual_journal');
        if v_ola and v_shop.id is not null then
          perform app.post_event('shop.cash_shortage', jsonb_build_object('amount', v_amount), app.today(),
            'Till shortage written off: ' || e.description, 'exception', e.id, e.location_id);
        elsif v_shop.id is null then
          perform app.post_event('counter.cash_shortage', jsonb_build_object('amount', v_amount), app.today(),
            'Counter shortage written off: ' || e.description, 'exception', e.id, e.location_id);
        end if;
      elsif p_resolution not in ('found','charge_driver','accepted') then
        raise exception 'Unsupported resolution' using errcode = '22023';
      end if;

    elsif p_resolution <> 'accepted' then
      raise exception 'This exception can only be acknowledged' using errcode = '22023';
    end if;
  end if;

  update public.operation_exceptions set status = 'resolved', resolution = p_resolution, resolution_note = trim(p_note),
         resolved_at = now(), resolved_by = app.current_user_id()
   where id = p_id;

  if e.run_id is not null and not exists (select 1 from public.operation_exceptions where run_id = e.run_id and status = 'open'
       and exception_type in ('bottle_shortage','bottle_surplus','stock_shortage','stock_surplus','cash_shortage','cash_surplus')) then
    update public.route_runs set status = 'closed', closed_at = now() where id = e.run_id and status = 'checked_in';
  end if;
  if e.source_type = 'stock_request' and not exists (select 1 from public.operation_exceptions where source_id = e.source_id and status = 'open') then
    update public.shop_stock_requests set status = 'received' where id = e.source_id and status = 'received_with_differences';
  end if;

  perform app.idempotency_finish(p_client_txn_id, jsonb_build_object('ok', true));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- RLS: shop staff see only their own shop
-- ---------------------------------------------------------------------
alter table public.water_shops              enable row level security;
alter table public.shop_stock_requests      enable row level security;
alter table public.shop_stock_request_items enable row level security;
alter table public.pos_sessions             enable row level security;
alter table public.pos_sales                enable row level security;
alter table public.pos_sale_lines           enable row level security;
alter table public.shop_settlements         enable row level security;

create policy water_shops_read on public.water_shops for select to authenticated
  using (app.has_permission('shops.view') or app.has_permission_at('shops.view', location_id) or app.has_permission_at('shop_pos.use', location_id));
create policy shop_stock_requests_read on public.shop_stock_requests for select to authenticated
  using (app.has_permission('shops.view') or app.has_permission('inventory.manage') or app.has_permission('shops.stock_approve')
         or app.has_permission_at('shop_pos.use', (select location_id from public.water_shops w where w.id = shop_id)));
create policy shop_stock_request_items_read on public.shop_stock_request_items for select to authenticated
  using (exists (select 1 from public.shop_stock_requests r where r.id = request_id));
create policy pos_sessions_read on public.pos_sessions for select to authenticated
  using (app.has_permission('shops.view') or app.has_permission('payments.view') or app.has_permission_at(app.pos_permission(location_id), location_id));
create policy pos_sales_read on public.pos_sales for select to authenticated
  using (app.has_permission('shops.view') or app.has_permission('payments.view') or app.has_permission_at(app.pos_permission(location_id), location_id));
create policy pos_sale_lines_read on public.pos_sale_lines for select to authenticated
  using (exists (select 1 from public.pos_sales s where s.id = sale_id));
create policy shop_settlements_read on public.shop_settlements for select to authenticated
  using (app.has_permission('shops.view') or app.has_permission('shops.settle')
         or app.has_permission_at('shops.view', (select location_id from public.water_shops w where w.id = shop_id)));

-- shop staff also see their shop's exceptions
drop policy operation_exceptions_read on public.operation_exceptions;
create policy operation_exceptions_read on public.operation_exceptions for select to authenticated
  using (app.has_permission('deliveries.reconcile') or app.has_permission('bottles.view') or app.has_permission('inventory.view')
         or app.has_permission('shops.settle')
         or (location_id is not null and app.has_permission_at('shop_pos.use', location_id))
         or (target_location_id is not null and app.has_permission_at('shop_pos.use', target_location_id)));

revoke insert, update, delete, truncate on public.pos_sale_lines, public.shop_settlements from anon, authenticated, service_role;

-- >>> 20261003000018_phase1b_reference_data.sql
-- =====================================================================
-- OLA Water ERP — Phase 1B
-- 0018: accounts, posting rules, role, grants for shops and tills
-- =====================================================================

insert into public.accounts (code, name, account_type, system_key, parent_id)
select v.code, v.name, v.type, v.key, (select id from public.accounts where code = v.parent)
  from (values
    ('2510', 'Shop Commissions Payable', 'liability', 'commissions_payable', '2000'),
    ('6210', 'Shop Commissions',         'expense',   'exp_shop_commission', '6000')
  ) as v(code, name, type, key, parent);

insert into public.posting_event_types (code, module, description, amount_keys) values
  ('invoice.shop',          'shops',    'Water shop sale or stock invoiced to a dealer shop',
     array['ar_debit','ar_credit','net','vat','delivery','deposit','deposit_refund','bottle_charge']),
  ('payment.shop_cash',     'shops',    'Cash taken at a company-owned shop till',           array['amount']),
  ('refund.cash',           'payments', 'Deposit refunded in cash at a head-office counter', array['amount']),
  ('refund.shop_cash',      'shops',    'Deposit refunded in cash at a shop till',           array['amount']),
  ('shop.cash_remit',       'shops',    'Shop takings banked',                               array['amount']),
  ('shop.cash_shortage',    'shops',    'Shop till shortage written off',                    array['amount']),
  ('shop.commission',       'shops',    'Commission accrued for a company-owned shop',       array['amount']),
  ('counter.cash_shortage', 'sales',    'Head-office counter shortage written off',          array['amount']);

insert into public.posting_rules (event_type, line_no, side, account_key, amount_key, description) values
  ('invoice.shop', 1, 'debit',  'ar',                   'ar_debit',       'Receivable'),
  ('invoice.shop', 2, 'debit',  'bottle_deposits',      'deposit_refund', 'Deposit refunded'),
  ('invoice.shop', 3, 'credit', 'ar',                   'ar_credit',      'Credit to customer'),
  ('invoice.shop', 4, 'credit', 'sales_shops',          'net',            'Sales — water shops'),
  ('invoice.shop', 5, 'credit', 'vat_output',           'vat',            'VAT output'),
  ('invoice.shop', 6, 'credit', 'delivery_income',      'delivery',       'Delivery charge'),
  ('invoice.shop', 7, 'credit', 'bottle_deposits',      'deposit',        'Bottle deposit held'),
  ('invoice.shop', 8, 'credit', 'bottle_charge_income', 'bottle_charge',  'Bottle charge'),
  ('payment.shop_cash',     1, 'debit',  'shop_cash',           'amount', 'Cash in the shop till'),
  ('payment.shop_cash',     2, 'credit', 'ar',                  'amount', 'Receivable settled'),
  ('refund.cash',           1, 'debit',  'ar',                  'amount', 'Refund owed to customer settled'),
  ('refund.cash',           2, 'credit', 'cash',                'amount', 'Cash paid out'),
  ('refund.shop_cash',      1, 'debit',  'ar',                  'amount', 'Refund owed to customer settled'),
  ('refund.shop_cash',      2, 'credit', 'shop_cash',           'amount', 'Cash paid out of the till'),
  ('shop.cash_remit',       1, 'debit',  'bank',                'amount', 'Shop takings banked'),
  ('shop.cash_remit',       2, 'credit', 'shop_cash',           'amount', 'Shop cash cleared'),
  ('shop.cash_shortage',    1, 'debit',  'cash_shortage',       'amount', 'Till shortage'),
  ('shop.cash_shortage',    2, 'credit', 'shop_cash',           'amount', 'Shop cash cleared'),
  ('shop.commission',       1, 'debit',  'exp_shop_commission', 'amount', 'Shop commission'),
  ('shop.commission',       2, 'credit', 'commissions_payable', 'amount', 'Commission payable'),
  ('counter.cash_shortage', 1, 'debit',  'cash_shortage',       'amount', 'Counter shortage'),
  ('counter.cash_shortage', 2, 'credit', 'cash',                'amount', 'Cash cleared');

-- Head-office counter staff
insert into public.roles (code, name, role_group, is_system, description)
values ('counter_cashier', 'Counter Cashier', 'commercial', true, 'Head-office / depot counter (POS) only');
insert into public.role_permissions (role_id, permission_code)
select (select id from public.roles where code = 'counter_cashier'), x
  from unnest(array['pos.use','customers.view','products.view']) x;

-- Shop managers may request and receive stock and see their exceptions (already via shop_pos.use);
-- warehouse managers receive bottles back from shops (inventory.manage) — no change needed.

-- ---------------------------------------------------------------------------------------
-- Function privileges (re-applied after functions are added)
-- ---------------------------------------------------------------------------------------
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

grant select on all tables in schema public to authenticated, service_role;
revoke all on all tables in schema public from anon;

-- >>> 20261003000019_phase1b_read_models.sql
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

commit;
