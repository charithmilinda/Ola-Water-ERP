-- =====================================================================
-- OLA Water ERP — Phase 1A
-- 0009: catalogue (tax, bottle types, products, price lists),
--        external bottle companies, routes, vehicles, customers
-- =====================================================================

-- ---------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------
create or replace function app.jtext(p jsonb, k text) returns text
language sql immutable set search_path = '' as $$ select nullif(trim(p ->> k), '') $$;

create or replace function app.jnum(p jsonb, k text) returns numeric
language sql immutable set search_path = '' as $$ select nullif(trim(p ->> k), '')::numeric $$;

create or replace function app.jint(p jsonb, k text) returns integer
language sql immutable set search_path = '' as $$ select nullif(trim(p ->> k), '')::integer $$;

create or replace function app.juuid(p jsonb, k text) returns uuid
language sql immutable set search_path = '' as $$ select nullif(trim(p ->> k), '')::uuid $$;

create or replace function app.jbool(p jsonb, k text, d boolean) returns boolean
language sql immutable set search_path = '' as $$ select coalesce((p ->> k)::boolean, d) $$;

-- Sri Lankan / E.164 phone normaliser: 0771234567 -> +94771234567
create or replace function app.normalize_phone(p text) returns text
language plpgsql immutable set search_path = '' as $$
declare d text := regexp_replace(coalesce(p, ''), '[^0-9+]', '', 'g');
begin
  if d = '' then return null; end if;
  if d ~ '^\+[1-9][0-9]{7,14}$' then return d; end if;
  if d ~ '^0[0-9]{9}$' then return '+94' || substr(d, 2); end if;
  if d ~ '^94[0-9]{9}$' then return '+' || d; end if;
  raise exception 'Invalid phone number: %', p using errcode = '22023';
end $$;

-- ---------------------------------------------------------------------
-- Tax codes with effective-dated rates (never hard-coded)
-- ---------------------------------------------------------------------
create table public.tax_codes (
  code        text primary key check (code ~ '^[A-Z0-9_]{2,12}$'),
  name        text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table public.tax_rates (
  id              uuid primary key default gen_random_uuid(),
  tax_code        text not null references public.tax_codes(code),
  rate_percent    numeric(6,3) not null check (rate_percent between 0 and 100),
  effective_from  date not null,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  unique (tax_code, effective_from)
);
create trigger tax_rates_append_only before update or delete on public.tax_rates
  for each row execute function app.forbid_change();
create trigger tax_codes_audit after insert or update on public.tax_codes
  for each row execute function app.audit_row('products', 'code');
create trigger tax_rates_audit after insert on public.tax_rates
  for each row execute function app.audit_row('products');

create or replace function app.tax_rate(p_code text, p_at date default null)
returns numeric language plpgsql stable security definer set search_path = '' as $$
declare v numeric;
begin
  if p_code is null then return 0; end if;
  select rate_percent into v from public.tax_rates
   where tax_code = p_code and effective_from <= coalesce(p_at, app.today())
   order by effective_from desc limit 1;
  if v is null then
    raise exception 'No rate is set for tax code % on %. Set it in Products → Tax.', p_code, coalesce(p_at, app.today())
      using errcode = 'P0002';
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Bottle owners: OLA plus every external water company
-- ---------------------------------------------------------------------
create table public.bottle_companies (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null unique check (code ~ '^[A-Z0-9]{2,8}$'),
  name               text not null,
  is_own             boolean not null default false,
  acceptance_policy  text check (acceptance_policy in ('accept_one_for_one','accept_with_charge','accept_no_credit','refuse')),
  contact_person     text,
  contact_phone      text,
  address            text,
  holding_alert_qty  integer check (holding_alert_qty >= 0),
  is_active          boolean not null default true,
  notes              text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create unique index bottle_companies_one_own on public.bottle_companies (is_own) where is_own;
comment on column public.bottle_companies.acceptance_policy is 'Overrides the default policy for this company''s bottles (null = default)';

create or replace function app.own_company_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select id from public.bottle_companies where is_own
$$;

-- ---------------------------------------------------------------------
-- Bottle types and their deposit / replacement values (effective-dated)
-- ---------------------------------------------------------------------
create table public.bottle_types (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique check (code ~ '^[A-Z0-9_.]{2,12}$'),
  name         text not null,
  size_litres  numeric(6,2) not null check (size_litres > 0),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.bottle_values (
  id                 uuid primary key default gen_random_uuid(),
  bottle_type_id     uuid not null references public.bottle_types(id),
  company_id         uuid not null references public.bottle_companies(id),
  deposit_amount     numeric(12,2) not null default 0 check (deposit_amount >= 0),
  replacement_value  numeric(12,2) not null default 0 check (replacement_value >= 0),
  external_charge    numeric(12,2) not null default 0 check (external_charge >= 0),
  effective_from     date not null,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  unique (bottle_type_id, company_id, effective_from)
);
comment on column public.bottle_values.external_charge is 'Charge to a customer who hands in this company''s bottle under the accept_with_charge policy';
create trigger bottle_values_append_only before update or delete on public.bottle_values
  for each row execute function app.forbid_change();

create or replace function app.bottle_value(p_type uuid, p_company uuid, p_at date default null)
returns public.bottle_values language sql stable security definer set search_path = '' as $$
  select * from public.bottle_values
   where bottle_type_id = p_type and company_id = p_company
     and effective_from <= coalesce(p_at, app.today())
   order by effective_from desc limit 1
$$;

-- ---------------------------------------------------------------------
-- Products & price lists
-- ---------------------------------------------------------------------
create table public.products (
  id              uuid primary key default gen_random_uuid(),
  sku             text not null unique check (sku ~ '^[A-Z0-9.-]{2,20}$'),
  name            text not null,
  category        text not null default 'water' check (category in ('water','accessory','other')),
  size_label      text,
  unit            text not null default 'bottle' check (unit in ('bottle','case','pack','unit')),
  units_per_pack  integer not null default 1 check (units_per_pack >= 1),
  barcode         text unique,
  is_returnable   boolean not null default false,
  bottle_type_id  uuid references public.bottle_types(id),
  tax_code        text references public.tax_codes(code),
  cost_price      numeric(12,2) not null default 0 check (cost_price >= 0),
  sort_order      integer not null default 0,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (not is_returnable or bottle_type_id is not null)
);

create table public.price_lists (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique check (code ~ '^[A-Z0-9_]{2,20}$'),
  name                text not null,
  prices_include_tax  boolean not null default true,
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create table public.price_list_items (
  id              uuid primary key default gen_random_uuid(),
  price_list_id   uuid not null references public.price_lists(id),
  product_id      uuid not null references public.products(id),
  unit_price      numeric(12,2) not null check (unit_price >= 0),
  effective_from  date not null,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  unique (price_list_id, product_id, effective_from)
);
create trigger price_list_items_append_only before update or delete on public.price_list_items
  for each row execute function app.forbid_change();

create or replace function app.unit_price(p_product uuid, p_price_list uuid, p_at date default null)
returns numeric language plpgsql stable security definer set search_path = '' as $$
declare v numeric; v_name text; v_list text;
begin
  select unit_price into v from public.price_list_items
   where product_id = p_product and price_list_id = p_price_list
     and effective_from <= coalesce(p_at, app.today())
   order by effective_from desc limit 1;
  if v is null then
    select name into v_name from public.products where id = p_product;
    select name into v_list from public.price_lists where id = p_price_list;
    raise exception 'No price for % in price list %', v_name, v_list using errcode = 'P0002';
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Routes and vehicles (each vehicle is also a stock location)
-- ---------------------------------------------------------------------
create table public.vehicles (
  id              uuid primary key default gen_random_uuid(),
  registration_no text not null unique,
  name            text,
  vehicle_type    text not null default 'lorry' check (vehicle_type in ('lorry','van','three_wheeler','motorbike','other')),
  capacity_19l    integer check (capacity_19l >= 0),
  location_id     uuid not null unique references public.locations(id),
  is_active       boolean not null default true,
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table public.routes (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null unique check (code ~ '^[A-Z0-9-]{2,12}$'),
  name               text not null,
  area               text,
  default_vehicle_id uuid references public.vehicles(id),
  default_driver_id  uuid references public.profiles(id),
  is_active          boolean not null default true,
  notes              text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Customers
-- ---------------------------------------------------------------------
create table public.customer_type_defaults (
  customer_type    text primary key check (customer_type in
                     ('household','office','hotel','restaurant','shop','supermarket','institution','distributor','water_shop','corporate')),
  label            text not null,
  bottle_model     text not null check (bottle_model in ('deposit','loan','none')),
  allowed_bottles  integer not null default 0 check (allowed_bottles >= 0),
  price_list_id    uuid references public.price_lists(id),
  payment_terms_days integer not null default 0 check (payment_terms_days >= 0),
  updated_at       timestamptz not null default now()
);

create sequence public.customer_no_seq start 1;

create table public.customers (
  id                  uuid primary key default gen_random_uuid(),
  customer_no         text not null unique default ('C' || lpad(nextval('public.customer_no_seq')::text, 6, '0')),
  name                text not null check (length(trim(name)) > 0),
  company_name        text,
  customer_type       text not null references public.customer_type_defaults(customer_type),
  contact_person      text,
  phone               text not null check (phone ~ '^\+[1-9][0-9]{7,14}$'),
  phone2              text check (phone2 ~ '^\+[1-9][0-9]{7,14}$'),
  email               text,
  vat_no              text,
  route_id            uuid references public.routes(id),
  route_sequence      integer,
  sales_rep_id        uuid references public.profiles(id),
  price_list_id       uuid not null references public.price_lists(id),
  credit_limit        numeric(14,2) not null default 0 check (credit_limit >= 0),
  payment_terms_days  integer not null default 0 check (payment_terms_days >= 0),
  bottle_model        text not null check (bottle_model in ('deposit','loan','none')),
  allowed_bottles     integer not null default 0 check (allowed_bottles >= 0),
  external_policy     text check (external_policy in ('accept_one_for_one','accept_with_charge','accept_no_credit','refuse')),
  status              text not null default 'active' check (status in ('active','on_hold','inactive')),
  notes               text,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now()
);
create index customers_name_idx  on public.customers (lower(name));
create index customers_phone_idx on public.customers (phone);
create index customers_route_idx on public.customers (route_id, route_sequence);

create table public.customer_addresses (
  id                     uuid primary key default gen_random_uuid(),
  customer_id            uuid not null references public.customers(id),
  label                  text not null default 'Main',
  address_line           text not null,
  city                   text,
  district               text,
  gps_lat                numeric(9,6) check (gps_lat between -90 and 90),
  gps_lng                numeric(9,6) check (gps_lng between -180 and 180),
  delivery_instructions  text,
  is_default             boolean not null default false,
  is_active              boolean not null default true,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
create unique index customer_addresses_one_default on public.customer_addresses (customer_id) where is_default and is_active;
create index customer_addresses_customer_idx on public.customer_addresses (customer_id);

-- Resolve which external-bottle policy applies
create or replace function app.external_policy(p_customer uuid, p_company uuid)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select external_policy from public.customers where id = p_customer),
    (select acceptance_policy from public.bottle_companies where id = p_company),
    app.get_setting('bottles.external_policy_default') #>> '{}',
    'accept_one_for_one')
$$;

-- ---------------------------------------------------------------------
-- Triggers (updated_at + audit)
-- ---------------------------------------------------------------------
create trigger bottle_companies_touch before update on public.bottle_companies for each row execute function app.touch_updated_at();
create trigger bottle_types_touch     before update on public.bottle_types     for each row execute function app.touch_updated_at();
create trigger products_touch         before update on public.products         for each row execute function app.touch_updated_at();
create trigger price_lists_touch      before update on public.price_lists      for each row execute function app.touch_updated_at();
create trigger vehicles_touch         before update on public.vehicles         for each row execute function app.touch_updated_at();
create trigger routes_touch           before update on public.routes           for each row execute function app.touch_updated_at();
create trigger customers_touch        before update on public.customers        for each row execute function app.touch_updated_at();
create trigger customer_addresses_touch before update on public.customer_addresses for each row execute function app.touch_updated_at();
create trigger customer_type_defaults_touch before update on public.customer_type_defaults for each row execute function app.touch_updated_at();

create trigger bottle_companies_audit after insert or update or delete on public.bottle_companies for each row execute function app.audit_row('bottles');
create trigger bottle_types_audit     after insert or update or delete on public.bottle_types     for each row execute function app.audit_row('bottles');
create trigger bottle_values_audit    after insert on public.bottle_values                         for each row execute function app.audit_row('bottles');
create trigger products_audit         after insert or update or delete on public.products         for each row execute function app.audit_row('products');
create trigger price_lists_audit      after insert or update or delete on public.price_lists      for each row execute function app.audit_row('products');
create trigger price_list_items_audit after insert on public.price_list_items                     for each row execute function app.audit_row('products');
create trigger vehicles_audit         after insert or update or delete on public.vehicles         for each row execute function app.audit_row('fleet');
create trigger routes_audit           after insert or update or delete on public.routes           for each row execute function app.audit_row('routes');
create trigger customers_audit        after insert or update or delete on public.customers        for each row execute function app.audit_row('customers');
create trigger customer_addresses_audit after insert or update or delete on public.customer_addresses for each row execute function app.audit_row('customers');
create trigger customer_type_defaults_audit after insert or update on public.customer_type_defaults for each row execute function app.audit_row('customers', 'customer_type');

-- =====================================================================
-- RPCs
-- =====================================================================

-- Tax ------------------------------------------------------------------
create or replace function public.save_tax_code(p_code text, p_name text, p_active boolean, p_reason text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_permission('products.manage');
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  insert into public.tax_codes (code, name, is_active) values (upper(trim(p_code)), trim(p_name), coalesce(p_active, true))
  on conflict (code) do update set name = excluded.name, is_active = excluded.is_active;
  return upper(trim(p_code));
end $$;

create or replace function public.set_tax_rate(p_code text, p_rate numeric, p_effective_from date, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform app.require_permission('prices.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  if p_effective_from < app.today() then raise exception 'Rates cannot be back-dated' using errcode = '22023'; end if;
  perform app.set_context(trim(p_reason), null, 'change_tax_rate');
  insert into public.tax_rates (tax_code, rate_percent, effective_from, created_by)
  values (p_code, p_rate, p_effective_from, app.current_user_id()) returning id into v;
  return v;
end $$;

-- Bottle companies & types ---------------------------------------------
create or replace function public.save_bottle_company(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; v_code text := upper(app.jtext(p, 'code'));
begin
  perform app.require_permission('bottles.external');
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    insert into public.bottle_companies (code, name, acceptance_policy, contact_person, contact_phone, address, holding_alert_qty, notes)
    values (v_code, app.jtext(p, 'name'), app.jtext(p, 'acceptance_policy'), app.jtext(p, 'contact_person'),
            app.normalize_phone(app.jtext(p, 'contact_phone')), app.jtext(p, 'address'), app.jint(p, 'holding_alert_qty'), app.jtext(p, 'notes'))
    returning id into v;
    -- each company gets its own external tag series, e.g. EXT-AQUA
    insert into public.identifier_series (code, name, entity_type, padding)
    values ('EXT-' || v_code, 'External tags — ' || app.jtext(p, 'name'), 'external_bottle', 8)
    on conflict (code) do nothing;
  else
    update public.bottle_companies set
      name = app.jtext(p, 'name'),
      acceptance_policy = app.jtext(p, 'acceptance_policy'),
      contact_person = app.jtext(p, 'contact_person'),
      contact_phone = app.normalize_phone(app.jtext(p, 'contact_phone')),
      address = app.jtext(p, 'address'),
      holding_alert_qty = app.jint(p, 'holding_alert_qty'),
      is_active = app.jbool(p, 'is_active', true),
      notes = app.jtext(p, 'notes')
    where id = p_id returning id into v;
    if v is null then raise exception 'Company not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

create or replace function public.save_bottle_type(p_id uuid, p_code text, p_name text, p_size numeric, p_active boolean, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform app.require_permission('products.manage');
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    insert into public.bottle_types (code, name, size_litres) values (upper(trim(p_code)), trim(p_name), p_size) returning id into v;
  else
    update public.bottle_types set name = trim(p_name), size_litres = p_size, is_active = coalesce(p_active, true)
     where id = p_id returning id into v;
  end if;
  return v;
end $$;

create or replace function public.set_bottle_value(
  p_bottle_type uuid, p_company uuid, p_deposit numeric, p_replacement numeric, p_external_charge numeric,
  p_effective_from date, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform app.require_permission('prices.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  if p_effective_from < app.today() then raise exception 'Values cannot be back-dated' using errcode = '22023'; end if;
  perform app.set_context(trim(p_reason), null, 'change_bottle_value');
  insert into public.bottle_values (bottle_type_id, company_id, deposit_amount, replacement_value, external_charge, effective_from, created_by)
  values (p_bottle_type, p_company, coalesce(p_deposit, 0), coalesce(p_replacement, 0), coalesce(p_external_charge, 0),
          p_effective_from, app.current_user_id())
  returning id into v;
  return v;
end $$;

-- Products & prices ----------------------------------------------------
create or replace function public.save_product(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform app.require_permission('products.manage');
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    insert into public.products (sku, name, category, size_label, unit, units_per_pack, barcode, is_returnable,
                                 bottle_type_id, tax_code, cost_price, sort_order)
    values (upper(app.jtext(p, 'sku')), app.jtext(p, 'name'), coalesce(app.jtext(p, 'category'), 'water'),
            app.jtext(p, 'size_label'), coalesce(app.jtext(p, 'unit'), 'bottle'), coalesce(app.jint(p, 'units_per_pack'), 1),
            app.jtext(p, 'barcode'), app.jbool(p, 'is_returnable', false), app.juuid(p, 'bottle_type_id'),
            app.jtext(p, 'tax_code'), coalesce(app.jnum(p, 'cost_price'), 0), coalesce(app.jint(p, 'sort_order'), 0))
    returning id into v;
  else
    update public.products set
      name = app.jtext(p, 'name'), category = coalesce(app.jtext(p, 'category'), 'water'),
      size_label = app.jtext(p, 'size_label'), unit = coalesce(app.jtext(p, 'unit'), 'bottle'),
      units_per_pack = coalesce(app.jint(p, 'units_per_pack'), 1), barcode = app.jtext(p, 'barcode'),
      is_returnable = app.jbool(p, 'is_returnable', false), bottle_type_id = app.juuid(p, 'bottle_type_id'),
      tax_code = app.jtext(p, 'tax_code'), cost_price = coalesce(app.jnum(p, 'cost_price'), 0),
      sort_order = coalesce(app.jint(p, 'sort_order'), 0), is_active = app.jbool(p, 'is_active', true)
    where id = p_id returning id into v;
    if v is null then raise exception 'Product not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

create or replace function public.save_price_list(p_id uuid, p_code text, p_name text, p_includes_tax boolean, p_active boolean, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform app.require_permission('prices.manage');
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    insert into public.price_lists (code, name, prices_include_tax) values (upper(trim(p_code)), trim(p_name), coalesce(p_includes_tax, true))
    returning id into v;
  else
    update public.price_lists set name = trim(p_name), prices_include_tax = coalesce(p_includes_tax, true), is_active = coalesce(p_active, true)
     where id = p_id returning id into v;
  end if;
  return v;
end $$;

-- p_prices: [{"product_id": "...", "unit_price": 450}]
create or replace function public.set_prices(p_price_list uuid, p_prices jsonb, p_effective_from date, p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_row jsonb; n integer := 0; v_current numeric;
begin
  perform app.require_permission('prices.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required to change prices' using errcode = '22023'; end if;
  if p_effective_from < app.today() then raise exception 'Prices cannot be back-dated' using errcode = '22023'; end if;
  perform app.set_context(trim(p_reason), null, 'change_price');
  for v_row in select * from jsonb_array_elements(p_prices) loop
    continue when app.jnum(v_row, 'unit_price') is null;
    select unit_price into v_current from public.price_list_items
     where price_list_id = p_price_list and product_id = app.juuid(v_row, 'product_id') and effective_from <= p_effective_from
     order by effective_from desc limit 1;
    continue when v_current = app.jnum(v_row, 'unit_price');
    insert into public.price_list_items (price_list_id, product_id, unit_price, effective_from, created_by)
    values (p_price_list, app.juuid(v_row, 'product_id'), app.jnum(v_row, 'unit_price'), p_effective_from, app.current_user_id())
    on conflict (price_list_id, product_id, effective_from) do nothing;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Routes & vehicles ----------------------------------------------------
create or replace function public.save_vehicle(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; v_loc uuid; v_reg text := upper(regexp_replace(coalesce(app.jtext(p, 'registration_no'), ''), '\s+', ' ', 'g'));
        v_code text;
begin
  perform app.require_permission('fleet.manage');
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if v_reg = '' then raise exception 'Registration number is required' using errcode = '22023'; end if;
  if p_id is null then
    v_code := left(regexp_replace(v_reg, '[^A-Z0-9]', '', 'g'), 10);
    if length(v_code) < 2 then raise exception 'Registration number is too short' using errcode = '22023'; end if;
    insert into public.locations (code, name, location_type) values (v_code, 'Vehicle ' || v_reg, 'vehicle') returning id into v_loc;
    insert into public.vehicles (registration_no, name, vehicle_type, capacity_19l, location_id, notes)
    values (v_reg, app.jtext(p, 'name'), coalesce(app.jtext(p, 'vehicle_type'), 'lorry'), app.jint(p, 'capacity_19l'), v_loc, app.jtext(p, 'notes'))
    returning id into v;
  else
    update public.vehicles set name = app.jtext(p, 'name'), vehicle_type = coalesce(app.jtext(p, 'vehicle_type'), 'lorry'),
           capacity_19l = app.jint(p, 'capacity_19l'), is_active = app.jbool(p, 'is_active', true), notes = app.jtext(p, 'notes')
     where id = p_id returning id into v;
    if v is null then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

create or replace function public.save_route(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform app.require_permission('routes.manage');
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    insert into public.routes (code, name, area, default_vehicle_id, default_driver_id, notes)
    values (upper(app.jtext(p, 'code')), app.jtext(p, 'name'), app.jtext(p, 'area'), app.juuid(p, 'default_vehicle_id'),
            app.juuid(p, 'default_driver_id'), app.jtext(p, 'notes'))
    returning id into v;
  else
    update public.routes set name = app.jtext(p, 'name'), area = app.jtext(p, 'area'),
           default_vehicle_id = app.juuid(p, 'default_vehicle_id'), default_driver_id = app.juuid(p, 'default_driver_id'),
           is_active = app.jbool(p, 'is_active', true), notes = app.jtext(p, 'notes')
     where id = p_id returning id into v;
    if v is null then raise exception 'Route not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

-- Customer type defaults -------------------------------------------------
create or replace function public.save_customer_type_default(
  p_type text, p_bottle_model text, p_allowed integer, p_price_list uuid, p_terms integer, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_permission('customers.credit');
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  perform app.set_context(trim(p_reason), null, null);
  update public.customer_type_defaults
     set bottle_model = p_bottle_model, allowed_bottles = coalesce(p_allowed, 0), price_list_id = p_price_list,
         payment_terms_days = coalesce(p_terms, 0)
   where customer_type = p_type;
  if not found then raise exception 'Unknown customer type' using errcode = 'P0002'; end if;
end $$;

-- Customers ---------------------------------------------------------------
-- p: name, company_name, customer_type, contact_person, phone, phone2, email, vat_no,
--    route_id, route_sequence, sales_rep_id, price_list_id, credit_limit, payment_terms_days,
--    bottle_model, allowed_bottles, external_policy, status, notes,
--    address: {address_line, city, district, gps_lat, gps_lng, delivery_instructions}   (create only)
create or replace function public.save_customer(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v uuid;
  d public.customer_type_defaults;
  v_old public.customers;
  v_phone text := app.normalize_phone(app.jtext(p, 'phone'));
  v_credit numeric := coalesce(app.jnum(p, 'credit_limit'), 0);
  v_addr jsonb := p -> 'address';
begin
  perform app.require_permission('customers.manage');
  if app.jtext(p, 'name') is null then raise exception 'Customer name is required' using errcode = '22023'; end if;
  if v_phone is null then raise exception 'A phone number is required' using errcode = '22023'; end if;

  select * into d from public.customer_type_defaults where customer_type = coalesce(app.jtext(p, 'customer_type'), '');
  if not found then raise exception 'Choose a customer type' using errcode = '22023'; end if;

  if p_id is not null then
    select * into v_old from public.customers where id = p_id for update;
    if not found then raise exception 'Customer not found' using errcode = 'P0002'; end if;
  end if;

  -- Credit limits and payment terms need finance permission to change
  if v_credit <> coalesce(v_old.credit_limit, 0)
     or coalesce(app.jint(p, 'payment_terms_days'), d.payment_terms_days) <> coalesce(v_old.payment_terms_days, d.payment_terms_days) then
    if not app.has_permission('customers.credit') then
      raise exception 'Changing credit limit or payment terms needs Finance approval (customers.credit)' using errcode = '42501';
    end if;
  end if;

  perform app.set_context(nullif(trim(p_reason), ''), null, null);

  if p_id is null then
    if exists (select 1 from public.customers where phone = v_phone and status <> 'inactive') then
      raise exception 'A customer with phone % already exists', v_phone using errcode = '23505';
    end if;
    insert into public.customers (
      name, company_name, customer_type, contact_person, phone, phone2, email, vat_no, route_id, route_sequence,
      sales_rep_id, price_list_id, credit_limit, payment_terms_days, bottle_model, allowed_bottles, external_policy,
      notes, created_by)
    values (
      app.jtext(p, 'name'), app.jtext(p, 'company_name'), d.customer_type, app.jtext(p, 'contact_person'), v_phone,
      app.normalize_phone(app.jtext(p, 'phone2')), lower(app.jtext(p, 'email')), app.jtext(p, 'vat_no'),
      app.juuid(p, 'route_id'), app.jint(p, 'route_sequence'), app.juuid(p, 'sales_rep_id'),
      coalesce(app.juuid(p, 'price_list_id'), d.price_list_id,
               (select id from public.price_lists where code = 'RETAIL')),
      v_credit, coalesce(app.jint(p, 'payment_terms_days'), d.payment_terms_days),
      coalesce(app.jtext(p, 'bottle_model'), d.bottle_model), coalesce(app.jint(p, 'allowed_bottles'), d.allowed_bottles),
      app.jtext(p, 'external_policy'), app.jtext(p, 'notes'), app.current_user_id())
    returning id into v;

    if v_addr is not null and app.jtext(v_addr, 'address_line') is not null then
      insert into public.customer_addresses (customer_id, label, address_line, city, district, gps_lat, gps_lng,
                                             delivery_instructions, is_default)
      values (v, coalesce(app.jtext(v_addr, 'label'), 'Main'), app.jtext(v_addr, 'address_line'), app.jtext(v_addr, 'city'),
              app.jtext(v_addr, 'district'), app.jnum(v_addr, 'gps_lat'), app.jnum(v_addr, 'gps_lng'),
              app.jtext(v_addr, 'delivery_instructions'), true);
    end if;
  else
    update public.customers set
      name = app.jtext(p, 'name'), company_name = app.jtext(p, 'company_name'), customer_type = d.customer_type,
      contact_person = app.jtext(p, 'contact_person'), phone = v_phone, phone2 = app.normalize_phone(app.jtext(p, 'phone2')),
      email = lower(app.jtext(p, 'email')), vat_no = app.jtext(p, 'vat_no'), route_id = app.juuid(p, 'route_id'),
      route_sequence = app.jint(p, 'route_sequence'), sales_rep_id = app.juuid(p, 'sales_rep_id'),
      price_list_id = coalesce(app.juuid(p, 'price_list_id'), v_old.price_list_id),
      credit_limit = v_credit, payment_terms_days = coalesce(app.jint(p, 'payment_terms_days'), v_old.payment_terms_days),
      bottle_model = coalesce(app.jtext(p, 'bottle_model'), v_old.bottle_model),
      allowed_bottles = coalesce(app.jint(p, 'allowed_bottles'), v_old.allowed_bottles),
      external_policy = app.jtext(p, 'external_policy'),
      status = coalesce(app.jtext(p, 'status'), v_old.status), notes = app.jtext(p, 'notes')
    where id = p_id;
    v := p_id;
  end if;
  return v;
end $$;

create or replace function public.save_customer_address(p_customer uuid, p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; v_default boolean := app.jbool(p, 'is_default', false);
begin
  perform app.require_permission('customers.manage');
  if app.jtext(p, 'address_line') is null then raise exception 'Address is required' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if not exists (select 1 from public.customer_addresses where customer_id = p_customer and is_default and is_active and id is distinct from p_id) then
    v_default := true;
  end if;
  if v_default then
    update public.customer_addresses set is_default = false where customer_id = p_customer and is_default and id is distinct from p_id;
  end if;
  if p_id is null then
    insert into public.customer_addresses (customer_id, label, address_line, city, district, gps_lat, gps_lng, delivery_instructions, is_default)
    values (p_customer, coalesce(app.jtext(p, 'label'), 'Main'), app.jtext(p, 'address_line'), app.jtext(p, 'city'), app.jtext(p, 'district'),
            app.jnum(p, 'gps_lat'), app.jnum(p, 'gps_lng'), app.jtext(p, 'delivery_instructions'), v_default)
    returning id into v;
  else
    update public.customer_addresses set label = coalesce(app.jtext(p, 'label'), 'Main'), address_line = app.jtext(p, 'address_line'),
           city = app.jtext(p, 'city'), district = app.jtext(p, 'district'), gps_lat = app.jnum(p, 'gps_lat'), gps_lng = app.jnum(p, 'gps_lng'),
           delivery_instructions = app.jtext(p, 'delivery_instructions'), is_default = v_default,
           is_active = app.jbool(p, 'is_active', true)
     where id = p_id and customer_id = p_customer returning id into v;
    if v is null then raise exception 'Address not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- RLS (reads by permission; writes only through the functions above)
-- ---------------------------------------------------------------------
alter table public.tax_codes              enable row level security;
alter table public.tax_rates              enable row level security;
alter table public.bottle_companies       enable row level security;
alter table public.bottle_types           enable row level security;
alter table public.bottle_values          enable row level security;
alter table public.products               enable row level security;
alter table public.price_lists            enable row level security;
alter table public.price_list_items       enable row level security;
alter table public.vehicles               enable row level security;
alter table public.routes                 enable row level security;
alter table public.customer_type_defaults enable row level security;
alter table public.customers              enable row level security;
alter table public.customer_addresses     enable row level security;

create policy tax_codes_read        on public.tax_codes        for select to authenticated using (true);
create policy tax_rates_read        on public.tax_rates        for select to authenticated using (true);
create policy bottle_companies_read on public.bottle_companies for select to authenticated using (true);
create policy bottle_types_read     on public.bottle_types     for select to authenticated using (true);
create policy bottle_values_read    on public.bottle_values    for select to authenticated using (true);
create policy products_read         on public.products         for select to authenticated using (true);
create policy price_lists_read      on public.price_lists      for select to authenticated using (true);
create policy price_list_items_read on public.price_list_items for select to authenticated using (true);
create policy vehicles_read         on public.vehicles         for select to authenticated using (true);
create policy routes_read           on public.routes           for select to authenticated using (true);
create policy customer_type_defaults_read on public.customer_type_defaults for select to authenticated using (true);
create policy customers_read on public.customers for select to authenticated
  using (app.has_permission('customers.view') or app.has_permission('orders.view') or app.has_permission('deliveries.view'));
create policy customer_addresses_read on public.customer_addresses for select to authenticated
  using (app.has_permission('customers.view') or app.has_permission('orders.view') or app.has_permission('deliveries.view'));

revoke update, delete, truncate on public.tax_rates, public.bottle_values, public.price_list_items from anon, authenticated, service_role;
