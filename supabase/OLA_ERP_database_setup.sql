-- OLA Water ERP — complete database setup (Phase 0)
-- Paste this whole file into Supabase → SQL Editor → New query, then press Run. Run it ONCE.


-- >>> 20261001000001_app_schema_and_audit.sql
-- =====================================================================
-- OLA Water ERP — Phase 0
-- 0001: internal "app" schema, request context and the immutable audit trail
-- =====================================================================
-- Rules implemented here (see master prompt, Part A §4 and D-1):
--   * Audit is written by database triggers / definer functions, so no
--     code path can skip it.
--   * audit_logs is INSERT-only: UPDATE / DELETE / TRUNCATE are blocked by
--     triggers (for every role, including the table owner) and revoked.
-- =====================================================================

create schema if not exists app;
comment on schema app is 'Internal helpers for OLA ERP. Not exposed through the API.';
grant usage on schema app to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- Request context
-- ---------------------------------------------------------------------

-- The acting user. Normally the Supabase JWT subject. Server-side code
-- running with the service role may declare the acting user with
-- set_config('app.acting_user_id', ..., true) inside its transaction.
create or replace function app.current_user_id()
returns uuid
language sql stable
set search_path = ''
as $$
  select coalesce(
    auth.uid(),
    nullif(current_setting('app.acting_user_id', true), '')::uuid
  )
$$;

-- Read a PostgREST request header (lower-case name). Null outside the API.
create or replace function app.request_header(p_name text)
returns text
language sql stable
set search_path = ''
as $$
  select nullif(current_setting('request.headers', true), '')::jsonb ->> lower(p_name)
$$;

-- Set per-transaction audit context. Called at the start of every RPC.
create or replace function app.set_context(
  p_reason text default null,
  p_client_txn_id uuid default null,
  p_audit_action text default null
)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_reason is not null then
    perform set_config('app.reason', p_reason, true);
  end if;
  if p_client_txn_id is not null then
    perform set_config('app.client_txn_id', p_client_txn_id::text, true);
  end if;
  if p_audit_action is not null then
    perform set_config('app.audit_action', p_audit_action, true);
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Audit log table
-- ---------------------------------------------------------------------
create table public.audit_logs (
  id              bigint generated always as identity primary key,
  occurred_at     timestamptz not null default now(),
  user_id         uuid,
  user_name       text,
  roles           text[],
  action          text not null,
  module          text not null,
  record_type     text,
  record_id       text,
  old_values      jsonb,
  new_values      jsonb,
  changed_fields  text[],
  reason          text,
  ip_address      text,
  device          text,
  location        text,
  client_txn_id   uuid,
  request_id      text
);

comment on table public.audit_logs is 'Immutable audit trail. INSERT-only; written by triggers and definer functions.';

create index audit_logs_occurred_at_idx on public.audit_logs (occurred_at desc);
create index audit_logs_record_idx      on public.audit_logs (record_type, record_id);
create index audit_logs_user_idx        on public.audit_logs (user_id, occurred_at desc);
create index audit_logs_module_idx      on public.audit_logs (module, occurred_at desc);
create index audit_logs_action_idx      on public.audit_logs (action, occurred_at desc);

-- ---------------------------------------------------------------------
-- Append-only guard (reused by every ledger table)
-- ---------------------------------------------------------------------
create or replace function app.forbid_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception '% is append-only: % is not allowed', tg_table_name, tg_op
    using errcode = 'P0001',
          hint = 'Post a reversal or adjustment instead of changing history.';
end;
$$;

create trigger audit_logs_no_update_delete
  before update or delete on public.audit_logs
  for each row execute function app.forbid_change();

create trigger audit_logs_no_truncate
  before truncate on public.audit_logs
  for each statement execute function app.forbid_change();

-- ---------------------------------------------------------------------
-- Writing audit records
-- ---------------------------------------------------------------------
create or replace function app.write_audit(
  p_action       text,
  p_module       text,
  p_record_type  text,
  p_record_id    text,
  p_old          jsonb default null,
  p_new          jsonb default null,
  p_reason       text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := app.current_user_id();
  v_name     text;
  v_roles    text[];
  v_changed  text[];
  v_ip       text;
  v_id       bigint;
begin
  if v_uid is not null then
    select p.full_name into v_name from public.profiles p where p.id = v_uid;
    select array_agg(distinct r.code order by r.code) into v_roles
      from public.user_roles ur
      join public.roles r on r.id = ur.role_id
     where ur.user_id = v_uid;
  end if;

  if p_old is not null and p_new is not null then
    select array_agg(n.key order by n.key) into v_changed
      from jsonb_each(p_new) n
     where n.key not in ('updated_at')
       and n.value is distinct from (p_old -> n.key);
  end if;

  -- Prefer the end-user IP forwarded by the Next.js server, then the proxy chain
  v_ip := coalesce(
    nullif(current_setting('app.ip_address', true), ''),
    app.request_header('x-client-ip'),
    split_part(coalesce(app.request_header('x-forwarded-for'), ''), ',', 1)
  );

  insert into public.audit_logs (
    user_id, user_name, roles, action, module, record_type, record_id,
    old_values, new_values, changed_fields, reason,
    ip_address, device, location, client_txn_id, request_id
  ) values (
    v_uid,
    coalesce(v_name, case when v_uid is null then 'system' end),
    v_roles,
    p_action,
    p_module,
    p_record_type,
    p_record_id,
    p_old,
    p_new,
    v_changed,
    coalesce(p_reason, nullif(current_setting('app.reason', true), '')),
    nullif(trim(v_ip), ''),
    coalesce(nullif(current_setting('app.device', true), ''), app.request_header('x-device-id')),
    coalesce(nullif(current_setting('app.location', true), ''), app.request_header('x-geo-location')),
    nullif(current_setting('app.client_txn_id', true), '')::uuid,
    app.request_header('x-request-id')
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- Generic row trigger.  TG_ARGV[0] = module, TG_ARGV[1] = key column (default 'id').
create or replace function app.audit_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old    jsonb;
  v_new    jsonb;
  v_action text;
  v_key    text := coalesce(tg_argv[1], 'id');
begin
  if tg_op = 'INSERT' then
    v_action := coalesce(nullif(current_setting('app.audit_action', true), ''), 'create');
    v_new := to_jsonb(new);
  elsif tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
    v_new := to_jsonb(new);
    if (v_old - 'updated_at') = (v_new - 'updated_at') then
      return new;
    end if;
    v_action := coalesce(nullif(current_setting('app.audit_action', true), ''), 'edit');
  else
    v_action := coalesce(nullif(current_setting('app.audit_action', true), ''), 'delete');
    v_old := to_jsonb(old);
  end if;

  perform app.write_audit(
    v_action,
    tg_argv[0],
    tg_table_name,
    coalesce(v_new, v_old) ->> v_key,
    v_old,
    v_new
  );

  return coalesce(new, old);
end;
$$;

-- updated_at maintenance
create or replace function app.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Privileges on the audit table
-- ---------------------------------------------------------------------
alter table public.audit_logs enable row level security;
revoke insert, update, delete, truncate on public.audit_logs from anon, authenticated, service_role;

-- >>> 20261001000002_access_control.sql
-- =====================================================================
-- OLA Water ERP — Phase 0
-- 0002: locations, users (profiles), roles, permissions, devices
-- =====================================================================

-- ---------------------------------------------------------------------
-- Locations (head office, warehouses, water shops, vehicles, holding areas)
-- ---------------------------------------------------------------------
create table public.locations (
  id             uuid primary key default gen_random_uuid(),
  code           text not null unique check (code ~ '^[A-Z0-9]{2,10}$'),
  name           text not null check (length(trim(name)) > 0),
  location_type  text not null check (location_type in
                   ('head_office','warehouse','water_shop','vehicle','external_holding','virtual')),
  address        text,
  gps_lat        numeric(9,6) check (gps_lat between -90 and 90),
  gps_lng        numeric(9,6) check (gps_lng between -180 and 180),
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  archived_at    timestamptz
);
comment on column public.locations.code is 'Short code used in document numbers, e.g. INV-HQ-2026-000123.';

-- ---------------------------------------------------------------------
-- Profiles (one per auth user)
-- ---------------------------------------------------------------------
create table public.profiles (
  id                   uuid primary key references auth.users(id) on delete restrict,
  full_name            text not null check (length(trim(full_name)) > 0),
  email                text,
  phone                text check (phone is null or phone ~ '^\+[1-9][0-9]{7,14}$'),
  employee_code        text unique,
  default_location_id  uuid references public.locations(id),
  is_active            boolean not null default true,
  last_login_at        timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
comment on column public.profiles.phone is 'E.164, e.g. +94771234567';

-- ---------------------------------------------------------------------
-- Roles & permissions
-- ---------------------------------------------------------------------
create table public.roles (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique check (code ~ '^[a-z][a-z0-9_]{2,40}$'),
  name         text not null check (length(trim(name)) > 0),
  description  text,
  role_group   text not null default 'custom'
               check (role_group in ('management','operations','commercial','administration','custom')),
  is_system    boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  archived_at  timestamptz
);

create table public.permissions (
  code         text primary key check (code ~ '^[a-z_]+\.[a-z_]+$'),
  module       text not null,
  action       text not null,
  description  text not null,
  sort_order   integer not null default 0
);

create table public.role_permissions (
  role_id          uuid not null references public.roles(id) on delete restrict,
  permission_code  text not null references public.permissions(code) on delete restrict,
  granted_at       timestamptz not null default now(),
  granted_by       uuid,
  primary key (role_id, permission_code)
);

create table public.user_roles (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete restrict,
  role_id      uuid not null references public.roles(id) on delete restrict,
  location_id  uuid references public.locations(id) on delete restrict,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  unique nulls not distinct (user_id, role_id, location_id)
);
comment on column public.user_roles.location_id is 'Optional scope, e.g. a Shop Cashier limited to one water shop.';

create index user_roles_user_idx on public.user_roles (user_id);
create index role_permissions_perm_idx on public.role_permissions (permission_code);

-- ---------------------------------------------------------------------
-- Registered devices (POS terminals, driver phones, warehouse tablets)
-- ---------------------------------------------------------------------
create table public.devices (
  id             uuid primary key default gen_random_uuid(),
  device_code    text not null unique check (device_code ~ '^[A-Z0-9-]{3,30}$'),
  name           text not null,
  device_type    text not null check (device_type in ('pos','driver_phone','tablet','desktop','scanner_station')),
  location_id    uuid references public.locations(id),
  assigned_user  uuid references public.profiles(id),
  is_active      boolean not null default true,
  registered_at  timestamptz not null default now(),
  registered_by  uuid,
  updated_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Permission helpers
-- ---------------------------------------------------------------------
create or replace function app.is_super_admin(p_user uuid default null)
returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.user_roles ur
      join public.roles r    on r.id = ur.role_id and r.archived_at is null
      join public.profiles p on p.id = ur.user_id and p.is_active
     where ur.user_id = coalesce(p_user, app.current_user_id())
       and r.code = 'super_admin'
  )
$$;

create or replace function app.has_permission(p_code text)
returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select app.is_super_admin()
      or exists (
        select 1
          from public.user_roles ur
          join public.roles r             on r.id = ur.role_id and r.archived_at is null
          join public.profiles p          on p.id = ur.user_id and p.is_active
          join public.role_permissions rp on rp.role_id = r.id
         where ur.user_id = app.current_user_id()
           and rp.permission_code = p_code
      )
$$;

create or replace function app.require_permission(p_code text)
returns void
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  if app.current_user_id() is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  if not app.has_permission(p_code) then
    raise exception 'Permission denied: % is required', p_code using errcode = '42501';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Create a profile whenever an auth user is created
-- ---------------------------------------------------------------------
create or replace function app.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, email, phone)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''), split_part(coalesce(new.email, 'user'), '@', 1)),
    new.email,
    nullif(new.raw_user_meta_data ->> 'phone', '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app.handle_new_auth_user();

-- ---------------------------------------------------------------------
-- Audit + updated_at triggers
-- ---------------------------------------------------------------------
create trigger locations_touch   before update on public.locations   for each row execute function app.touch_updated_at();
create trigger profiles_touch    before update on public.profiles    for each row execute function app.touch_updated_at();
create trigger roles_touch       before update on public.roles       for each row execute function app.touch_updated_at();
create trigger devices_touch     before update on public.devices     for each row execute function app.touch_updated_at();

create trigger locations_audit        after insert or update or delete on public.locations        for each row execute function app.audit_row('admin');
create trigger profiles_audit         after insert or update or delete on public.profiles         for each row execute function app.audit_row('users');
create trigger roles_audit            after insert or update or delete on public.roles            for each row execute function app.audit_row('roles');
create trigger role_permissions_audit after insert or update or delete on public.role_permissions for each row execute function app.audit_row('roles', 'role_id');
create trigger user_roles_audit       after insert or update or delete on public.user_roles       for each row execute function app.audit_row('users');
create trigger devices_audit          after insert or update or delete on public.devices          for each row execute function app.audit_row('admin');

-- ---------------------------------------------------------------------
-- Row Level Security.  Reads are permission-based; all writes go through
-- SECURITY DEFINER functions (no write policies are defined).
-- ---------------------------------------------------------------------
alter table public.locations        enable row level security;
alter table public.profiles         enable row level security;
alter table public.roles            enable row level security;
alter table public.permissions      enable row level security;
alter table public.role_permissions enable row level security;
alter table public.user_roles       enable row level security;
alter table public.devices          enable row level security;

create policy locations_read on public.locations
  for select to authenticated using (true);

create policy profiles_read on public.profiles
  for select to authenticated
  using (id = app.current_user_id() or app.has_permission('users.manage'));

create policy roles_read on public.roles
  for select to authenticated
  using (app.has_permission('roles.manage') or app.has_permission('users.manage'));

create policy permissions_read on public.permissions
  for select to authenticated using (true);

create policy role_permissions_read on public.role_permissions
  for select to authenticated
  using (app.has_permission('roles.manage') or app.has_permission('users.manage'));

create policy user_roles_read on public.user_roles
  for select to authenticated
  using (user_id = app.current_user_id() or app.has_permission('users.manage'));

create policy devices_read on public.devices
  for select to authenticated
  using (assigned_user = app.current_user_id() or app.has_permission('devices.manage'));

-- Audit log visibility (table created in 0001)
create policy audit_logs_read on public.audit_logs
  for select to authenticated using (app.has_permission('audit.view'));

-- >>> 20261001000003_settings_numbering_idempotency.sql
-- =====================================================================
-- OLA Water ERP — Phase 0
-- 0003: effective-dated settings, document numbering, idempotency
-- =====================================================================

-- ---------------------------------------------------------------------
-- Settings: definitions + effective-dated values (append-only history)
-- ---------------------------------------------------------------------
create table public.setting_definitions (
  key           text primary key check (key ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'),
  module        text not null,
  label         text not null,
  description   text,
  value_type    text not null check (value_type in ('text','number','integer','money','percent','boolean','choice')),
  choices       text[],
  min_value     numeric,
  max_value     numeric,
  sort_order    integer not null default 0,
  check (value_type <> 'choice' or choices is not null)
);

create table public.system_settings (
  id              uuid primary key default gen_random_uuid(),
  key             text not null references public.setting_definitions(key) on delete restrict,
  value           jsonb not null,
  effective_from  date not null,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  unique (key, effective_from)
);
comment on table public.system_settings is 'Append-only. A change is a new row with a new effective_from date.';
create index system_settings_key_idx on public.system_settings (key, effective_from desc);

create trigger system_settings_append_only
  before update or delete on public.system_settings
  for each row execute function app.forbid_change();
create trigger system_settings_audit
  after insert on public.system_settings
  for each row execute function app.audit_row('settings');

-- Value of a setting on a given date (null if never set)
create or replace function app.get_setting(p_key text, p_at date default null)
returns jsonb
language sql stable
security definer
set search_path = ''
as $$
  select s.value
    from public.system_settings s
   where s.key = p_key
     and s.effective_from <= coalesce(p_at, (now() at time zone 'Asia/Colombo')::date)
   order by s.effective_from desc
   limit 1
$$;

create or replace function app.company_timezone()
returns text
language sql stable
security definer
set search_path = ''
as $$
  select coalesce(app.get_setting('company.timezone') #>> '{}', 'Asia/Colombo')
$$;

-- Today's business date in the company time zone
create or replace function app.today()
returns date
language sql stable
security definer
set search_path = ''
as $$
  select (now() at time zone app.company_timezone())::date
$$;

create or replace function app.validate_setting_value(p_key text, p_value jsonb)
returns void
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  d public.setting_definitions;
  v numeric;
begin
  select * into d from public.setting_definitions where key = p_key;
  if not found then
    raise exception 'Unknown setting: %', p_key using errcode = '22023';
  end if;

  case d.value_type
    when 'text' then
      if jsonb_typeof(p_value) <> 'string' then
        raise exception 'Setting % must be text', p_key using errcode = '22023';
      end if;
    when 'boolean' then
      if jsonb_typeof(p_value) <> 'boolean' then
        raise exception 'Setting % must be true or false', p_key using errcode = '22023';
      end if;
    when 'choice' then
      if jsonb_typeof(p_value) <> 'string' or not ((p_value #>> '{}') = any (d.choices)) then
        raise exception 'Setting % must be one of: %', p_key, array_to_string(d.choices, ', ') using errcode = '22023';
      end if;
    else
      if jsonb_typeof(p_value) <> 'number' then
        raise exception 'Setting % must be a number', p_key using errcode = '22023';
      end if;
      v := (p_value #>> '{}')::numeric;
      if d.value_type = 'integer' and v <> trunc(v) then
        raise exception 'Setting % must be a whole number', p_key using errcode = '22023';
      end if;
      if d.value_type in ('money') and v < 0 then
        raise exception 'Setting % cannot be negative', p_key using errcode = '22023';
      end if;
      if d.value_type = 'percent' and (v < 0 or v > 100) then
        raise exception 'Setting % must be between 0 and 100', p_key using errcode = '22023';
      end if;
      if d.min_value is not null and v < d.min_value then
        raise exception 'Setting % must be at least %', p_key, d.min_value using errcode = '22023';
      end if;
      if d.max_value is not null and v > d.max_value then
        raise exception 'Setting % must be at most %', p_key, d.max_value using errcode = '22023';
      end if;
  end case;
end;
$$;

-- ---------------------------------------------------------------------
-- Document numbering — gapless, per document type, location and year.
-- Format: {TYPE}-{LOCATION}-{YEAR}-{000123}
-- The counter row is locked and incremented inside the caller's
-- transaction, so a rolled-back transaction does not consume a number.
-- ---------------------------------------------------------------------
create table public.document_types (
  code      text primary key check (code ~ '^[A-Z]{2,5}$'),
  name      text not null,
  padding   integer not null default 6 check (padding between 4 and 10),
  gapless   boolean not null default true
);

create table public.document_sequences (
  doc_type     text not null references public.document_types(code),
  location_id  uuid not null references public.locations(id),
  fiscal_year  integer not null check (fiscal_year between 2000 and 2999),
  next_value   bigint not null default 1 check (next_value >= 1),
  primary key (doc_type, location_id, fiscal_year)
);

create or replace function app.head_office_id()
returns uuid
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_code text := coalesce(app.get_setting('company.head_office_location') #>> '{}', 'HQ');
begin
  select id into v_id from public.locations where code = v_code;
  if v_id is null then
    raise exception 'Head office location % is not configured', v_code using errcode = 'P0002';
  end if;
  return v_id;
end;
$$;

create or replace function app.next_document_number(
  p_doc_type    text,
  p_location_id uuid default null,
  p_date        date default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_loc_id   uuid := coalesce(p_location_id, app.head_office_id());
  v_loc_code text;
  v_year     integer := extract(year from coalesce(p_date, app.today()))::integer;
  v_padding  integer;
  v_value    bigint;
begin
  select padding into v_padding from public.document_types where code = p_doc_type;
  if v_padding is null then
    raise exception 'Unknown document type %', p_doc_type using errcode = '22023';
  end if;

  select code into v_loc_code from public.locations where id = v_loc_id;
  if v_loc_code is null then
    raise exception 'Unknown location %', v_loc_id using errcode = '22023';
  end if;

  insert into public.document_sequences (doc_type, location_id, fiscal_year)
  values (p_doc_type, v_loc_id, v_year)
  on conflict do nothing;

  update public.document_sequences
     set next_value = next_value + 1
   where doc_type = p_doc_type and location_id = v_loc_id and fiscal_year = v_year
  returning next_value - 1 into v_value;

  return format('%s-%s-%s-%s', p_doc_type, v_loc_code, v_year, lpad(v_value::text, v_padding, '0'));
end;
$$;

-- ---------------------------------------------------------------------
-- Idempotency: every transaction-creating RPC takes a client_txn_id.
--   v := app.idempotency_begin(id, 'operation');
--   if v is not null then return v; end if;   -- already processed
--   ... do the work ...
--   perform app.idempotency_finish(id, result);
-- A concurrent duplicate blocks on the unique key until the first
-- transaction commits, then receives the stored result.
-- ---------------------------------------------------------------------
create table public.idempotency_keys (
  client_txn_id  uuid primary key,
  operation      text not null,
  user_id        uuid,
  result         jsonb,
  created_at     timestamptz not null default now(),
  completed_at   timestamptz
);
create index idempotency_keys_created_idx on public.idempotency_keys (created_at);

create or replace function app.idempotency_begin(p_client_txn_id uuid, p_operation text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rows integer;
  v_row  public.idempotency_keys;
begin
  if p_client_txn_id is null then
    raise exception 'client_txn_id is required' using errcode = '22023';
  end if;

  insert into public.idempotency_keys (client_txn_id, operation, user_id)
  values (p_client_txn_id, p_operation, app.current_user_id())
  on conflict (client_txn_id) do nothing;
  get diagnostics v_rows = row_count;

  if v_rows = 1 then
    perform set_config('app.client_txn_id', p_client_txn_id::text, true);
    return null;  -- new request, proceed
  end if;

  select * into v_row from public.idempotency_keys where client_txn_id = p_client_txn_id;
  if v_row.operation <> p_operation then
    raise exception 'client_txn_id % was already used for %', p_client_txn_id, v_row.operation
      using errcode = '23505';
  end if;
  return coalesce(v_row.result, '{}'::jsonb) || jsonb_build_object('duplicate', true);
end;
$$;

create or replace function app.idempotency_finish(p_client_txn_id uuid, p_result jsonb)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.idempotency_keys
     set result = p_result, completed_at = now()
   where client_txn_id = p_client_txn_id
$$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.setting_definitions enable row level security;
alter table public.system_settings     enable row level security;
alter table public.document_types      enable row level security;
alter table public.document_sequences  enable row level security;
alter table public.idempotency_keys    enable row level security;

create policy setting_definitions_read on public.setting_definitions
  for select to authenticated using (true);
create policy system_settings_read on public.system_settings
  for select to authenticated using (true);
create policy document_types_read on public.document_types
  for select to authenticated using (true);
create policy document_sequences_read on public.document_sequences
  for select to authenticated using (app.has_permission('settings.manage'));
-- idempotency_keys: no policies (internal only)

revoke update, delete, truncate on public.system_settings from anon, authenticated, service_role;

-- >>> 20261001000004_identifiers_and_labels.sql
-- =====================================================================
-- OLA Water ERP — Phase 0
-- 0004: identifier service (barcodes / QR / Data Matrix, future RFID/NFC)
--        and label batches
-- =====================================================================
-- Barcodes only identify a record; business data stays in the database.
-- Identifiers are generated in numbered series, printed as label batches,
-- and later bound to an entity (bottle, crate, bin...) by Phase 1 RPCs.
-- =====================================================================

create table public.identifier_series (
  code         text primary key check (code ~ '^[A-Z0-9]{2,8}(-[A-Z0-9]{2,8}){1,2}$'),
  name         text not null,
  entity_type  text not null check (entity_type in ('bottle','external_bottle','crate','location_bin','product')),
  padding      integer not null default 8 check (padding between 4 and 12),
  next_value   bigint not null default 1 check (next_value >= 1),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
comment on table public.identifier_series is 'e.g. OLA-BTL -> OLA-BTL-00000001, EXT-AQUA -> EXT-AQUA-00000001';

create table public.label_batches (
  id             uuid primary key default gen_random_uuid(),
  batch_no       text not null unique,
  series_code    text not null references public.identifier_series(code),
  first_value    bigint not null,
  last_value     bigint not null,
  quantity       integer not null check (quantity between 1 and 5000),
  symbology      text not null check (symbology in ('qrcode','datamatrix','code128')),
  label_size     text not null check (label_size in ('50x25','40x30','30x20')),
  status         text not null default 'generated' check (status in ('generated','printed','cancelled')),
  print_count    integer not null default 0 check (print_count >= 0),
  notes          text,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  last_printed_at timestamptz,
  last_printed_by uuid,
  cancelled_at   timestamptz,
  cancelled_by   uuid,
  updated_at     timestamptz not null default now(),
  check (last_value - first_value + 1 = quantity)
);
create index label_batches_created_idx on public.label_batches (created_at desc);

create table public.identifiers (
  id               uuid primary key default gen_random_uuid(),
  value            text not null unique,
  identifier_type  text not null check (identifier_type in ('barcode','qrcode','datamatrix','rfid','nfc')),
  series_code      text references public.identifier_series(code),
  label_batch_id   uuid references public.label_batches(id),
  entity_type      text not null check (entity_type in ('bottle','external_bottle','crate','location_bin','product')),
  entity_id        uuid,
  status           text not null default 'unassigned' check (status in ('unassigned','assigned','void')),
  assigned_at      timestamptz,
  assigned_by      uuid,
  voided_at        timestamptz,
  void_reason      text,
  created_at       timestamptz not null default now(),
  check ((status = 'assigned') = (entity_id is not null)),
  check (status <> 'void' or void_reason is not null)
);
create index identifiers_entity_idx on public.identifiers (entity_type, entity_id) where entity_id is not null;
create index identifiers_batch_idx  on public.identifiers (label_batch_id);

-- Triggers.  Identifier inserts are logged once per batch (not per label);
-- every later change to an identifier is audited row by row.
create trigger identifier_series_touch before update on public.identifier_series for each row execute function app.touch_updated_at();
create trigger label_batches_touch     before update on public.label_batches     for each row execute function app.touch_updated_at();

create trigger identifier_series_audit after insert or update or delete on public.identifier_series
  for each row execute function app.audit_row('labels', 'code');
create trigger label_batches_audit after insert or update or delete on public.label_batches
  for each row execute function app.audit_row('labels');
create trigger identifiers_audit after update or delete on public.identifiers
  for each row execute function app.audit_row('labels');

create trigger identifiers_no_delete before delete on public.identifiers
  for each row execute function app.forbid_change();
create trigger label_batches_no_delete before delete on public.label_batches
  for each row execute function app.forbid_change();

-- Look up an identifier by its scanned value (used by every scan field)
create or replace function public.lookup_identifier(p_value text)
returns table (
  id uuid, value text, identifier_type text, series_code text,
  entity_type text, entity_id uuid, status text, label_batch_id uuid
)
language sql stable
security definer
set search_path = ''
as $$
  select i.id, i.value, i.identifier_type, i.series_code, i.entity_type, i.entity_id, i.status, i.label_batch_id
    from public.identifiers i
   where app.current_user_id() is not null
     and i.value = upper(trim(p_value))
$$;

-- ---------------------------------------------------------------------
-- Generate a label batch
-- ---------------------------------------------------------------------
create or replace function public.generate_label_batch(
  p_series_code    text,
  p_quantity       integer,
  p_symbology      text,
  p_label_size     text,
  p_notes          text,
  p_client_txn_id  uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_done     jsonb;
  v_series   public.identifier_series;
  v_first    bigint;
  v_last     bigint;
  v_batch_id uuid;
  v_batch_no text;
  v_type     text;
  v_result   jsonb;
begin
  perform app.require_permission('labels.print');
  v_done := app.idempotency_begin(p_client_txn_id, 'generate_label_batch');
  if v_done is not null then return v_done; end if;

  if p_quantity is null or p_quantity < 1 or p_quantity > 5000 then
    raise exception 'Quantity must be between 1 and 5000' using errcode = '22023';
  end if;

  select * into v_series from public.identifier_series where code = p_series_code for update;
  if not found or not v_series.is_active then
    raise exception 'Identifier series % is not available', p_series_code using errcode = '22023';
  end if;

  v_first := v_series.next_value;
  v_last  := v_first + p_quantity - 1;
  if length(v_last::text) > v_series.padding then
    raise exception 'Series % would exceed % digits', p_series_code, v_series.padding using errcode = '22023';
  end if;

  perform app.set_context(null, p_client_txn_id, null);

  update public.identifier_series set next_value = v_last + 1 where code = p_series_code;

  v_batch_no := app.next_document_number('LBL');
  v_type := case p_symbology when 'code128' then 'barcode' else p_symbology end;

  insert into public.label_batches (
    batch_no, series_code, first_value, last_value, quantity, symbology, label_size, notes, created_by
  ) values (
    v_batch_no, p_series_code, v_first, v_last, p_quantity, p_symbology, p_label_size,
    nullif(trim(p_notes), ''), app.current_user_id()
  ) returning id into v_batch_id;

  insert into public.identifiers (value, identifier_type, series_code, label_batch_id, entity_type)
  select p_series_code || '-' || lpad(n::text, v_series.padding, '0'),
         v_type, p_series_code, v_batch_id, v_series.entity_type
    from generate_series(v_first, v_last) as n;

  v_result := jsonb_build_object(
    'batch_id', v_batch_id,
    'batch_no', v_batch_no,
    'first', p_series_code || '-' || lpad(v_first::text, v_series.padding, '0'),
    'last',  p_series_code || '-' || lpad(v_last::text,  v_series.padding, '0'),
    'quantity', p_quantity
  );
  perform app.idempotency_finish(p_client_txn_id, v_result);
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- Record that a batch was printed (reprints require a reason)
-- ---------------------------------------------------------------------
create or replace function public.record_label_print(
  p_batch_id uuid,
  p_reason   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch public.label_batches;
begin
  perform app.require_permission('labels.print');

  select * into v_batch from public.label_batches where id = p_batch_id for update;
  if not found then
    raise exception 'Label batch not found' using errcode = 'P0002';
  end if;
  if v_batch.status = 'cancelled' then
    raise exception 'Label batch % is cancelled', v_batch.batch_no using errcode = '22023';
  end if;
  if v_batch.print_count > 0 and nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required to reprint labels' using errcode = '22023';
  end if;

  perform app.set_context(
    nullif(trim(p_reason), ''), null,
    case when v_batch.print_count > 0 then 'reprint' else 'print' end
  );

  update public.label_batches
     set status = 'printed',
         print_count = print_count + 1,
         last_printed_at = now(),
         last_printed_by = app.current_user_id()
   where id = p_batch_id;

  return jsonb_build_object('batch_id', p_batch_id, 'print_count', v_batch.print_count + 1);
end;
$$;

-- ---------------------------------------------------------------------
-- Cancel a batch (only if none of its labels have been applied)
-- ---------------------------------------------------------------------
create or replace function public.cancel_label_batch(p_batch_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch public.label_batches;
begin
  perform app.require_permission('labels.print');
  if nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required' using errcode = '22023';
  end if;

  select * into v_batch from public.label_batches where id = p_batch_id for update;
  if not found then
    raise exception 'Label batch not found' using errcode = 'P0002';
  end if;
  if v_batch.status = 'cancelled' then
    raise exception 'Label batch % is already cancelled', v_batch.batch_no using errcode = '22023';
  end if;
  if exists (select 1 from public.identifiers where label_batch_id = p_batch_id and status = 'assigned') then
    raise exception 'Some labels in % are already applied and cannot be cancelled', v_batch.batch_no
      using errcode = '22023';
  end if;

  perform app.set_context(trim(p_reason), null, 'cancel');

  update public.identifiers
     set status = 'void', voided_at = now(), void_reason = trim(p_reason)
   where label_batch_id = p_batch_id and status = 'unassigned';

  update public.label_batches
     set status = 'cancelled', cancelled_at = now(), cancelled_by = app.current_user_id()
   where id = p_batch_id;

  return jsonb_build_object('batch_id', p_batch_id, 'status', 'cancelled');
end;
$$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.identifier_series enable row level security;
alter table public.label_batches     enable row level security;
alter table public.identifiers       enable row level security;

create policy identifier_series_read on public.identifier_series
  for select to authenticated using (true);
create policy label_batches_read on public.label_batches
  for select to authenticated using (app.has_permission('labels.print') or app.has_permission('labels.view'));
create policy identifiers_read on public.identifiers
  for select to authenticated using (app.has_permission('labels.print') or app.has_permission('labels.view'));

-- >>> 20261001000005_accounting_core.sql
-- =====================================================================
-- OLA Water ERP — Phase 0
-- 0005: accounting core — chart of accounts, periods, journals,
--        posting rules engine
-- =====================================================================
-- Every operational transaction (Phase 1 onwards) posts through
-- app.post_event(), which turns an event + amounts into a balanced
-- journal entry using the posting_rules table.  Journals are immutable;
-- corrections are reversals.
-- =====================================================================

create table public.accounts (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique check (code ~ '^[0-9]{4,8}$'),
  name          text not null check (length(trim(name)) > 0),
  account_type  text not null check (account_type in ('asset','liability','equity','income','expense')),
  parent_id     uuid references public.accounts(id),
  is_postable   boolean not null default true,
  system_key    text unique check (system_key ~ '^[a-z][a-z0-9_]*$'),
  is_active     boolean not null default true,
  description   text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on column public.accounts.system_key is 'Stable key used by posting rules, e.g. cash, ar, sales, bottle_deposits.';

create table public.accounting_periods (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  starts_on  date not null,
  ends_on    date not null,
  status     text not null default 'open' check (status in ('open','closed')),
  closed_at  timestamptz,
  closed_by  uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_on >= starts_on),
  exclude using gist (daterange(starts_on, ends_on, '[]') with &&)
);

create table public.journal_entries (
  id                 uuid primary key default gen_random_uuid(),
  entry_no           text not null unique,
  entry_date         date not null,
  period_id          uuid not null references public.accounting_periods(id),
  event_type         text not null,
  source_type        text,
  source_id          uuid,
  description        text not null,
  location_id        uuid references public.locations(id),
  reverses_entry_id  uuid unique references public.journal_entries(id),
  total              numeric(16,2) not null check (total > 0),
  created_at         timestamptz not null default now(),
  created_by         uuid,
  client_txn_id      uuid
);
create index journal_entries_date_idx   on public.journal_entries (entry_date desc);
create index journal_entries_source_idx on public.journal_entries (source_type, source_id);
create index journal_entries_event_idx  on public.journal_entries (event_type, entry_date desc);

create table public.journal_lines (
  id          bigint generated always as identity primary key,
  entry_id    uuid not null references public.journal_entries(id),
  line_no     integer not null check (line_no > 0),
  account_id  uuid not null references public.accounts(id),
  debit       numeric(16,2) not null default 0 check (debit >= 0),
  credit      numeric(16,2) not null default 0 check (credit >= 0),
  memo        text,
  party_type  text check (party_type in ('customer','water_shop','supplier','employee','driver','distributor','external_company')),
  party_id    uuid,
  location_id uuid references public.locations(id),
  unique (entry_id, line_no),
  check ((debit > 0) <> (credit > 0))
);
create index journal_lines_account_idx on public.journal_lines (account_id);
create index journal_lines_party_idx   on public.journal_lines (party_type, party_id) where party_id is not null;

-- Immutability
create trigger journal_entries_append_only before update or delete on public.journal_entries
  for each row execute function app.forbid_change();
create trigger journal_lines_append_only before update or delete on public.journal_lines
  for each row execute function app.forbid_change();
create trigger journal_entries_no_truncate before truncate on public.journal_entries
  for each statement execute function app.forbid_change();
create trigger journal_lines_no_truncate before truncate on public.journal_lines
  for each statement execute function app.forbid_change();

-- Balanced-entry check, evaluated at COMMIT (deferred) so that the entry
-- and its lines can be inserted in any order within one transaction.
create or replace function app.check_entry_balanced()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_entry_id uuid;
  v_total    numeric;
  v_debit    numeric;
  v_credit   numeric;
  v_lines    integer;
begin
  if tg_table_name = 'journal_entries' then
    v_entry_id := new.id;
  else
    v_entry_id := new.entry_id;
  end if;

  select total into v_total from public.journal_entries where id = v_entry_id;
  select coalesce(sum(debit), 0), coalesce(sum(credit), 0), count(*)
    into v_debit, v_credit, v_lines
    from public.journal_lines where entry_id = v_entry_id;

  if v_lines < 2 then
    raise exception 'Journal entry % must have at least two lines', v_entry_id using errcode = 'P0001';
  end if;
  if v_debit <> v_credit then
    raise exception 'Journal entry % is not balanced (debit %, credit %)', v_entry_id, v_debit, v_credit
      using errcode = 'P0001';
  end if;
  if v_debit <> v_total then
    raise exception 'Journal entry % total % does not match lines %', v_entry_id, v_total, v_debit
      using errcode = 'P0001';
  end if;
  return null;
end;
$$;

create constraint trigger journal_entries_balanced
  after insert on public.journal_entries
  deferrable initially deferred
  for each row execute function app.check_entry_balanced();

create constraint trigger journal_lines_balanced
  after insert on public.journal_lines
  deferrable initially deferred
  for each row execute function app.check_entry_balanced();

-- ---------------------------------------------------------------------
-- Posting rules
-- ---------------------------------------------------------------------
create table public.posting_event_types (
  code         text primary key check (code ~ '^[a-z_]+(\.[a-z_]+)+$'),
  module       text not null,
  description  text not null,
  amount_keys  text[] not null
);

create table public.posting_rules (
  id              uuid primary key default gen_random_uuid(),
  event_type      text not null references public.posting_event_types(code),
  line_no         integer not null check (line_no > 0),
  side            text not null check (side in ('debit','credit')),
  account_key     text not null references public.accounts(system_key),
  amount_key      text not null check (amount_key ~ '^[a-z_]+$'),
  description     text,
  effective_from  date not null default date '2000-01-01',
  unique (event_type, effective_from, line_no)
);
comment on table public.posting_rules is 'Event -> journal lines. A new rule set for an event takes effect from effective_from.';

create trigger accounts_touch before update on public.accounts
  for each row execute function app.touch_updated_at();
create trigger accounting_periods_touch before update on public.accounting_periods
  for each row execute function app.touch_updated_at();
create trigger accounts_audit after insert or update or delete on public.accounts
  for each row execute function app.audit_row('accounting');
create trigger accounting_periods_audit after insert or update or delete on public.accounting_periods
  for each row execute function app.audit_row('accounting');
create trigger posting_rules_audit after insert or update or delete on public.posting_rules
  for each row execute function app.audit_row('accounting');

-- ---------------------------------------------------------------------
-- Core posting function
-- p_lines: [{"account_key"|"account_id", "debit", "credit", "memo",
--            "party_type", "party_id", "location_id"}]
-- ---------------------------------------------------------------------
create or replace function app.post_journal(
  p_entry_date     date,
  p_description    text,
  p_event_type     text,
  p_lines          jsonb,
  p_source_type    text default null,
  p_source_id      uuid default null,
  p_location_id    uuid default null,
  p_reverses       uuid default null,
  p_client_txn_id  uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_period   public.accounting_periods;
  v_entry_id uuid;
  v_entry_no text;
  v_line     jsonb;
  v_n        integer := 0;
  v_acc      public.accounts;
  v_debit    numeric(16,2);
  v_credit   numeric(16,2);
  v_tdebit   numeric(16,2) := 0;
  v_tcredit  numeric(16,2) := 0;
  v_out      jsonb := '[]'::jsonb;
begin
  if p_entry_date is null then
    raise exception 'Entry date is required' using errcode = '22023';
  end if;
  if nullif(trim(p_description), '') is null then
    raise exception 'Description is required' using errcode = '22023';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'A journal entry needs at least two lines' using errcode = '22023';
  end if;

  select * into v_period from public.accounting_periods
   where p_entry_date between starts_on and ends_on;
  if not found then
    raise exception 'No accounting period exists for %', p_entry_date using errcode = 'P0002';
  end if;
  if v_period.status <> 'open' then
    raise exception 'Accounting period % is closed', v_period.name using errcode = 'P0001';
  end if;

  -- Validate lines and totals before writing anything
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_debit  := round(coalesce((v_line ->> 'debit')::numeric, 0), 2);
    v_credit := round(coalesce((v_line ->> 'credit')::numeric, 0), 2);
    if v_debit < 0 or v_credit < 0 or (v_debit > 0) = (v_credit > 0) then
      raise exception 'Each line needs either a debit or a credit amount greater than zero' using errcode = '22023';
    end if;
    v_tdebit  := v_tdebit + v_debit;
    v_tcredit := v_tcredit + v_credit;
  end loop;

  if v_tdebit <> v_tcredit then
    raise exception 'Journal is not balanced: debits % / credits %', v_tdebit, v_tcredit using errcode = '22023';
  end if;

  v_entry_no := app.next_document_number('JE', p_location_id, p_entry_date);

  insert into public.journal_entries (
    entry_no, entry_date, period_id, event_type, source_type, source_id, description,
    location_id, reverses_entry_id, total, created_by, client_txn_id
  ) values (
    v_entry_no, p_entry_date, v_period.id, p_event_type, p_source_type, p_source_id, trim(p_description),
    p_location_id, p_reverses, v_tdebit, app.current_user_id(),
    coalesce(p_client_txn_id, nullif(current_setting('app.client_txn_id', true), '')::uuid)
  ) returning id into v_entry_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_n := v_n + 1;
    if v_line ? 'account_id' then
      select * into v_acc from public.accounts where id = (v_line ->> 'account_id')::uuid;
    else
      select * into v_acc from public.accounts where system_key = v_line ->> 'account_key';
    end if;
    if v_acc.id is null then
      raise exception 'Line %: account not found (%)', v_n, coalesce(v_line ->> 'account_id', v_line ->> 'account_key')
        using errcode = '22023';
    end if;
    if not v_acc.is_postable or not v_acc.is_active then
      raise exception 'Line %: account % % cannot be posted to', v_n, v_acc.code, v_acc.name using errcode = '22023';
    end if;

    insert into public.journal_lines (
      entry_id, line_no, account_id, debit, credit, memo, party_type, party_id, location_id
    ) values (
      v_entry_id, v_n, v_acc.id,
      round(coalesce((v_line ->> 'debit')::numeric, 0), 2),
      round(coalesce((v_line ->> 'credit')::numeric, 0), 2),
      v_line ->> 'memo',
      v_line ->> 'party_type',
      (v_line ->> 'party_id')::uuid,
      coalesce((v_line ->> 'location_id')::uuid, p_location_id)
    );

    v_out := v_out || jsonb_build_object(
      'account', v_acc.code || ' ' || v_acc.name,
      'debit',  round(coalesce((v_line ->> 'debit')::numeric, 0), 2),
      'credit', round(coalesce((v_line ->> 'credit')::numeric, 0), 2)
    );
    v_acc := null;
  end loop;

  perform app.write_audit(
    case when p_reverses is null then 'post' else 'reverse' end,
    'accounting', 'journal_entries', v_entry_id::text, null,
    jsonb_build_object('entry_no', v_entry_no, 'entry_date', p_entry_date, 'event_type', p_event_type,
                       'description', trim(p_description), 'total', v_tdebit, 'lines', v_out,
                       'source_type', p_source_type, 'source_id', p_source_id)
  );

  return v_entry_id;
end;
$$;

-- Post an operational event through the posting rules.
-- p_amounts: {"gross": 1180, "net": 1000, "vat": 180, ...}
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

  return app.post_journal(
    p_entry_date, p_description, p_event_type, v_lines,
    p_source_type, p_source_id, p_location_id, null, p_client_txn_id
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Public RPCs
-- ---------------------------------------------------------------------
create or replace function public.post_manual_journal(
  p_entry_date     date,
  p_description    text,
  p_lines          jsonb,
  p_reason         text,
  p_client_txn_id  uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_done jsonb;
  v_id   uuid;
  v_res  jsonb;
begin
  perform app.require_permission('accounting.manual_journal');
  if nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required for a manual journal' using errcode = '22023';
  end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'post_manual_journal');
  if v_done is not null then return v_done; end if;

  perform app.set_context(trim(p_reason), p_client_txn_id, null);
  v_id := app.post_journal(p_entry_date, p_description, 'manual.journal', p_lines,
                           'manual', null, null, null, p_client_txn_id);

  select jsonb_build_object('entry_id', id, 'entry_no', entry_no) into v_res
    from public.journal_entries where id = v_id;
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end;
$$;

create or replace function public.reverse_journal_entry(
  p_entry_id       uuid,
  p_reason         text,
  p_reversal_date  date,
  p_client_txn_id  uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_done   jsonb;
  v_entry  public.journal_entries;
  v_lines  jsonb;
  v_id     uuid;
  v_res    jsonb;
begin
  perform app.require_permission('accounting.reverse');
  if nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required to reverse an entry' using errcode = '22023';
  end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'reverse_journal_entry');
  if v_done is not null then return v_done; end if;

  select * into v_entry from public.journal_entries where id = p_entry_id;
  if not found then
    raise exception 'Journal entry not found' using errcode = 'P0002';
  end if;
  if v_entry.reverses_entry_id is not null then
    raise exception 'Entry % is itself a reversal', v_entry.entry_no using errcode = '22023';
  end if;
  if exists (select 1 from public.journal_entries where reverses_entry_id = p_entry_id) then
    raise exception 'Entry % has already been reversed', v_entry.entry_no using errcode = '22023';
  end if;

  select jsonb_agg(jsonb_build_object(
           'account_id', account_id, 'debit', credit, 'credit', debit,
           'memo', 'Reversal of ' || v_entry.entry_no,
           'party_type', party_type, 'party_id', party_id, 'location_id', location_id)
         order by line_no)
    into v_lines
    from public.journal_lines where entry_id = p_entry_id;

  perform app.set_context(trim(p_reason), p_client_txn_id, null);
  v_id := app.post_journal(
    coalesce(p_reversal_date, app.today()),
    'Reversal of ' || v_entry.entry_no || ': ' || trim(p_reason),
    v_entry.event_type || '.reversal',
    v_lines, v_entry.source_type, v_entry.source_id, v_entry.location_id, p_entry_id, p_client_txn_id
  );

  select jsonb_build_object('entry_id', id, 'entry_no', entry_no) into v_res
    from public.journal_entries where id = v_id;
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end;
$$;

-- Create the twelve monthly periods for a year (idempotent)
create or replace function public.ensure_accounting_year(p_year integer)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_month integer;
  v_start date;
  v_count integer := 0;
begin
  if app.current_user_id() is not null then
    perform app.require_permission('accounting.period_close');
  end if;
  for v_month in 1..12 loop
    v_start := make_date(p_year, v_month, 1);
    if not exists (select 1 from public.accounting_periods where starts_on = v_start) then
      insert into public.accounting_periods (name, starts_on, ends_on)
      values (to_char(v_start, 'YYYY-MM'), v_start, (v_start + interval '1 month - 1 day')::date);
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;

create or replace function public.close_accounting_period(p_period_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_period public.accounting_periods;
begin
  perform app.require_permission('accounting.period_close');
  select * into v_period from public.accounting_periods where id = p_period_id for update;
  if not found then
    raise exception 'Period not found' using errcode = 'P0002';
  end if;
  if v_period.status = 'closed' then
    raise exception 'Period % is already closed', v_period.name using errcode = '22023';
  end if;
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Period close'), null, 'close');
  update public.accounting_periods
     set status = 'closed', closed_at = now(), closed_by = app.current_user_id()
   where id = p_period_id;
  return jsonb_build_object('period', v_period.name, 'status', 'closed');
end;
$$;

-- Trial balance (used by tests now, and by the accounting UI in Phase 2)
create or replace function public.trial_balance(p_from date, p_to date)
returns table (account_code text, account_name text, account_type text, debit numeric, credit numeric, balance numeric)
language sql stable
security definer
set search_path = ''
as $$
  select a.code, a.name, a.account_type,
         coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0),
         coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0)
    from public.accounts a
    join public.journal_lines l on l.account_id = a.id
    join public.journal_entries e on e.id = l.entry_id
   where app.has_permission('accounting.view')
     and e.entry_date between p_from and p_to
   group by a.code, a.name, a.account_type
   order by a.code
$$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.accounts            enable row level security;
alter table public.accounting_periods  enable row level security;
alter table public.journal_entries     enable row level security;
alter table public.journal_lines       enable row level security;
alter table public.posting_event_types enable row level security;
alter table public.posting_rules       enable row level security;

create policy accounts_read on public.accounts
  for select to authenticated using (app.has_permission('accounting.view'));
create policy accounting_periods_read on public.accounting_periods
  for select to authenticated using (app.has_permission('accounting.view'));
create policy journal_entries_read on public.journal_entries
  for select to authenticated using (app.has_permission('accounting.view'));
create policy journal_lines_read on public.journal_lines
  for select to authenticated using (app.has_permission('accounting.view'));
create policy posting_event_types_read on public.posting_event_types
  for select to authenticated using (app.has_permission('accounting.view'));
create policy posting_rules_read on public.posting_rules
  for select to authenticated using (app.has_permission('accounting.view'));

revoke insert, update, delete, truncate on public.journal_entries from anon, authenticated, service_role;
revoke insert, update, delete, truncate on public.journal_lines   from anon, authenticated, service_role;

-- >>> 20261001000006_admin_rpcs_and_grants.sql
-- =====================================================================
-- OLA Water ERP — Phase 0
-- 0006: administration RPCs (users, roles, settings, auth events)
--        and function privileges
-- =====================================================================

-- ---------------------------------------------------------------------
-- Who am I and what can I do?  (drives permission-based navigation)
-- ---------------------------------------------------------------------
create or replace function public.get_my_access()
returns jsonb
language sql stable
security definer
set search_path = ''
as $$
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
        select jsonb_agg(jsonb_build_object('code', r.code, 'name', r.name,
                                            'location_code', l.code) order by r.name)
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
           where ur.user_id = p.id), '[]'::jsonb)
      end
    )
  end
    from public.profiles p
   where p.id = app.current_user_id()
$$;

-- ---------------------------------------------------------------------
-- Auth events (login / logout). Failed logins are recorded by the
-- server with the service role, because there is no user yet.
-- ---------------------------------------------------------------------
create or replace function public.log_auth_event(p_action text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app.current_user_id();
begin
  if v_uid is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  if p_action not in ('login','logout') then
    raise exception 'Unsupported auth event %', p_action using errcode = '22023';
  end if;
  if p_action = 'login' then
    -- update without a profile-level audit row; the login row below is the record
    perform set_config('app.audit_action', 'login', true);
    update public.profiles set last_login_at = now() where id = v_uid;
  else
    perform app.write_audit('logout', 'auth', 'profiles', v_uid::text, null, null);
  end if;
end;
$$;

create or replace function public.log_failed_login(p_email text, p_ip text, p_device text, p_message text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config('app.ip_address', coalesce(p_ip, ''), true);
  perform set_config('app.device', coalesce(p_device, ''), true);
  perform app.write_audit('failed_login', 'auth', 'auth_users', null, null,
    jsonb_build_object('email', lower(trim(p_email)), 'message', p_message));
end;
$$;

-- ---------------------------------------------------------------------
-- Users
-- ---------------------------------------------------------------------
create or replace function public.admin_list_users()
returns table (
  id uuid, full_name text, email text, phone text, employee_code text,
  default_location_code text, is_active boolean, last_login_at timestamptz,
  created_at timestamptz, roles jsonb
)
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  perform app.require_permission('users.manage');
  return query
  select p.id, p.full_name, p.email, p.phone, p.employee_code, l.code, p.is_active, p.last_login_at, p.created_at,
         coalesce((select jsonb_agg(jsonb_build_object('user_role_id', ur.id, 'role_id', r.id, 'code', r.code,
                                                       'name', r.name, 'location_code', rl.code) order by r.name)
                     from public.user_roles ur
                     join public.roles r on r.id = ur.role_id
                     left join public.locations rl on rl.id = ur.location_id
                    where ur.user_id = p.id), '[]'::jsonb)
    from public.profiles p
    left join public.locations l on l.id = p.default_location_id
   order by p.is_active desc, p.full_name;
end;
$$;

-- Called by the server right after it creates an auth user, so the
-- creation is attributed to the administrator who did it.
create or replace function public.admin_log_user_created(p_user_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
begin
  perform app.require_permission('users.manage');
  select * into v_profile from public.profiles where id = p_user_id;
  if not found then
    raise exception 'User not found' using errcode = 'P0002';
  end if;
  perform app.write_audit('create_user', 'users', 'profiles', p_user_id::text, null,
                          to_jsonb(v_profile), nullif(trim(p_reason), ''));
end;
$$;

create or replace function public.admin_log_password_reset(p_user_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_permission('users.manage');
  if nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'User not found' using errcode = 'P0002';
  end if;
  perform app.write_audit('reset_password', 'users', 'profiles', p_user_id::text, null, null, trim(p_reason));
end;
$$;

create or replace function public.admin_update_profile(
  p_user_id              uuid,
  p_full_name            text,
  p_phone                text,
  p_employee_code        text,
  p_default_location_id  uuid,
  p_reason               text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_permission('users.manage');
  if nullif(trim(p_full_name), '') is null then
    raise exception 'Full name is required' using errcode = '22023';
  end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  update public.profiles
     set full_name = trim(p_full_name),
         phone = nullif(trim(p_phone), ''),
         employee_code = nullif(trim(p_employee_code), ''),
         default_location_id = p_default_location_id
   where id = p_user_id;
  if not found then
    raise exception 'User not found' using errcode = 'P0002';
  end if;
end;
$$;

create or replace function public.admin_set_user_active(p_user_id uuid, p_active boolean, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.require_permission('users.manage');
  if nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required' using errcode = '22023';
  end if;
  if p_user_id = app.current_user_id() and not p_active then
    raise exception 'You cannot deactivate your own account' using errcode = '22023';
  end if;
  if not p_active and app.is_super_admin(p_user_id) and (
       select count(*) from public.user_roles ur
         join public.roles r on r.id = ur.role_id and r.code = 'super_admin'
         join public.profiles p on p.id = ur.user_id and p.is_active) <= 1 then
    raise exception 'The last active Super Admin cannot be deactivated' using errcode = '22023';
  end if;

  perform app.set_context(trim(p_reason), null, case when p_active then 'reactivate' else 'deactivate' end);
  update public.profiles set is_active = p_active where id = p_user_id;
  if not found then
    raise exception 'User not found' using errcode = 'P0002';
  end if;
end;
$$;

create or replace function public.admin_assign_role(
  p_user_id      uuid,
  p_role_id      uuid,
  p_location_id  uuid,
  p_reason       text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id   uuid;
  v_code text;
begin
  perform app.require_permission('users.manage');
  select code into v_code from public.roles where id = p_role_id and archived_at is null;
  if v_code is null then
    raise exception 'Role not found' using errcode = 'P0002';
  end if;
  if v_code = 'super_admin' and not app.is_super_admin() then
    raise exception 'Only a Super Admin can grant the Super Admin role' using errcode = '42501';
  end if;
  if exists (select 1 from public.user_roles
              where user_id = p_user_id and role_id = p_role_id
                and location_id is not distinct from p_location_id) then
    raise exception 'The user already has this role' using errcode = '23505';
  end if;

  perform app.set_context(nullif(trim(p_reason), ''), null, 'assign_role');
  insert into public.user_roles (user_id, role_id, location_id, created_by)
  values (p_user_id, p_role_id, p_location_id, app.current_user_id())
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.admin_revoke_role(p_user_role_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ur   public.user_roles;
  v_code text;
begin
  perform app.require_permission('users.manage');
  if nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required' using errcode = '22023';
  end if;
  select * into v_ur from public.user_roles where id = p_user_role_id for update;
  if not found then
    raise exception 'Role assignment not found' using errcode = 'P0002';
  end if;
  select code into v_code from public.roles where id = v_ur.role_id;
  if v_code = 'super_admin' then
    if not app.is_super_admin() then
      raise exception 'Only a Super Admin can revoke the Super Admin role' using errcode = '42501';
    end if;
    if (select count(*) from public.user_roles ur
          join public.profiles p on p.id = ur.user_id and p.is_active
         where ur.role_id = v_ur.role_id) <= 1 then
      raise exception 'The last active Super Admin cannot be removed' using errcode = '22023';
    end if;
  end if;

  perform app.set_context(trim(p_reason), null, 'revoke_role');
  delete from public.user_roles where id = p_user_role_id;
end;
$$;

-- Assign Super Admin to the first user. Service role / SQL console only.
create or replace function public.bootstrap_super_admin(p_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
  v_role uuid;
begin
  if exists (select 1 from public.user_roles ur join public.roles r on r.id = ur.role_id where r.code = 'super_admin') then
    raise exception 'A Super Admin already exists. Use the Users screen instead.' using errcode = '22023';
  end if;
  select id into v_user from public.profiles where lower(email) = lower(trim(p_email));
  if v_user is null then
    raise exception 'No user with email %', p_email using errcode = 'P0002';
  end if;
  select id into v_role from public.roles where code = 'super_admin';
  perform app.set_context('Initial system setup', null, 'assign_role');
  insert into public.user_roles (user_id, role_id) values (v_user, v_role);
  return v_user;
end;
$$;

-- ---------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------
create or replace function public.admin_save_role(
  p_role_id      uuid,          -- null = create
  p_code         text,
  p_name         text,
  p_description  text,
  p_permissions  text[],
  p_reason       text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role    public.roles;
  v_id      uuid;
  v_unknown text;
begin
  perform app.require_permission('roles.manage');

  select string_agg(x, ', ') into v_unknown
    from unnest(coalesce(p_permissions, '{}')) x
   where not exists (select 1 from public.permissions where code = x);
  if v_unknown is not null then
    raise exception 'Unknown permissions: %', v_unknown using errcode = '22023';
  end if;

  perform app.set_context(nullif(trim(p_reason), ''), null, null);

  if p_role_id is null then
    insert into public.roles (code, name, description, role_group)
    values (lower(trim(p_code)), trim(p_name), nullif(trim(p_description), ''), 'custom')
    returning id into v_id;
  else
    select * into v_role from public.roles where id = p_role_id for update;
    if not found then
      raise exception 'Role not found' using errcode = 'P0002';
    end if;
    if v_role.code = 'super_admin' then
      raise exception 'The Super Admin role always has every permission and cannot be edited' using errcode = '22023';
    end if;
    if nullif(trim(p_reason), '') is null then
      raise exception 'A reason is required to change a role' using errcode = '22023';
    end if;
    update public.roles
       set name = trim(p_name), description = nullif(trim(p_description), '')
     where id = p_role_id;
    v_id := p_role_id;
  end if;

  perform set_config('app.audit_action', 'revoke_permission', true);
  delete from public.role_permissions
   where role_id = v_id and not (permission_code = any (coalesce(p_permissions, '{}')));

  perform set_config('app.audit_action', 'grant_permission', true);
  insert into public.role_permissions (role_id, permission_code, granted_by)
  select v_id, x, app.current_user_id()
    from unnest(coalesce(p_permissions, '{}')) x
  on conflict do nothing;

  perform set_config('app.audit_action', '', true);
  return v_id;
end;
$$;

create or replace function public.admin_archive_role(p_role_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.roles;
begin
  perform app.require_permission('roles.manage');
  select * into v_role from public.roles where id = p_role_id for update;
  if not found then
    raise exception 'Role not found' using errcode = 'P0002';
  end if;
  if v_role.is_system then
    raise exception 'System roles cannot be archived' using errcode = '22023';
  end if;
  if exists (select 1 from public.user_roles where role_id = p_role_id) then
    raise exception 'Remove this role from all users before archiving it' using errcode = '22023';
  end if;
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Archived'), null, 'archive');
  update public.roles set archived_at = now() where id = p_role_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------
create or replace function public.list_settings()
returns table (
  key text, module text, label text, description text, value_type text, choices text[],
  current_value jsonb, current_from date, scheduled_value jsonb, scheduled_from date, sort_order integer
)
language sql stable
security definer
set search_path = ''
as $$
  select d.key, d.module, d.label, d.description, d.value_type, d.choices,
         cur.value, cur.effective_from, nxt.value, nxt.effective_from, d.sort_order
    from public.setting_definitions d
    left join lateral (
      select s.value, s.effective_from from public.system_settings s
       where s.key = d.key and s.effective_from <= app.today()
       order by s.effective_from desc limit 1) cur on true
    left join lateral (
      select s.value, s.effective_from from public.system_settings s
       where s.key = d.key and s.effective_from > app.today()
       order by s.effective_from asc limit 1) nxt on true
   where app.current_user_id() is not null
   order by d.module, d.sort_order, d.key
$$;

create or replace function public.set_setting(
  p_key            text,
  p_value          jsonb,
  p_effective_from date,
  p_reason         text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.require_permission('settings.manage');
  if nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required to change a setting' using errcode = '22023';
  end if;
  if p_effective_from is null or p_effective_from < app.today() then
    raise exception 'Effective date must be today or later (history cannot be rewritten)' using errcode = '22023';
  end if;
  perform app.validate_setting_value(p_key, p_value);
  if exists (select 1 from public.system_settings where key = p_key and effective_from = p_effective_from) then
    raise exception 'A value for % already takes effect on %. Choose another date.', p_key, p_effective_from
      using errcode = '23505';
  end if;

  perform app.set_context(trim(p_reason), null, 'change_setting');
  insert into public.system_settings (key, value, effective_from, created_by)
  values (p_key, p_value, p_effective_from, app.current_user_id())
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Function privileges
--   * nothing is executable by anon
--   * app.* helpers: only those used inside RLS policies are granted
--   * service-only RPCs are revoked from authenticated
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app    from public, anon, authenticated;

grant execute on all functions in schema public to authenticated, service_role;
grant execute on function app.current_user_id()      to authenticated, service_role;
grant execute on function app.has_permission(text)    to authenticated, service_role;
grant execute on function app.is_super_admin(uuid)    to authenticated, service_role;
grant execute on function app.today()                 to authenticated, service_role;

revoke execute on function public.log_failed_login(text, text, text, text) from authenticated;
revoke execute on function public.bootstrap_super_admin(text)              from authenticated;

alter default privileges in schema public revoke execute on functions from public, anon;

-- >>> 20261001000007_reference_data.sql
-- =====================================================================
-- OLA Water ERP — Phase 0
-- 0007: reference data required in every environment
--   permissions, default roles, head office + main warehouse,
--   document types, identifier series, settings, chart of accounts,
--   posting rules, accounting periods for 2026–2027
-- (Demo/test business data lives in supabase/seed.sql, not here.)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Permissions (all modules, so roles can be configured from day one)
-- ---------------------------------------------------------------------
insert into public.permissions (code, module, action, description, sort_order) values
  ('dashboard.view',            'Dashboard',        'view',            'View the management dashboard', 10),
  ('customers.view',            'Customers',        'view',            'View customers', 20),
  ('customers.manage',          'Customers',        'manage',          'Create and edit customers', 21),
  ('customers.credit',          'Customers',        'credit',          'Approve credit customers and limits', 22),
  ('products.view',             'Products',         'view',            'View products and price lists', 30),
  ('products.manage',           'Products',         'manage',          'Create and edit products', 31),
  ('prices.manage',             'Products',         'prices',          'Change price lists', 32),
  ('orders.view',               'Orders',           'view',            'View orders', 40),
  ('orders.manage',             'Orders',           'manage',          'Create, confirm and cancel orders', 41),
  ('pos.use',                   'Sales / POS',      'use',             'Use the head-office POS', 50),
  ('pos.discount',              'Sales / POS',      'discount',        'Approve discounts above the limit', 51),
  ('bottles.view',              'Bottles',          'view',            'View bottles and bottle ledgers', 60),
  ('bottles.manage',            'Bottles',          'manage',          'Record bottle movements', 61),
  ('bottles.writeoff',          'Bottles',          'writeoff',        'Approve bottle write-offs', 62),
  ('bottles.external',          'Bottles',          'external',        'Manage external bottle holding and hand-overs', 63),
  ('labels.view',               'Labels',           'view',            'View label batches and identifiers', 70),
  ('labels.print',              'Labels',           'print',           'Generate and print labels', 71),
  ('deliveries.view',           'Deliveries',       'view',            'View deliveries', 80),
  ('deliveries.manage',         'Deliveries',       'manage',          'Assign and manage deliveries', 81),
  ('deliveries.reconcile',      'Deliveries',       'reconcile',       'Resolve route reconciliation exceptions', 82),
  ('driver.app',                'Driver app',       'use',             'Use the driver application', 90),
  ('routes.manage',             'Routes',           'manage',          'Manage routes and zones', 95),
  ('shops.view',                'Water Shops',      'view',            'View water shops', 100),
  ('shops.manage',              'Water Shops',      'manage',          'Manage water shops', 101),
  ('shops.stock_approve',       'Water Shops',      'stock_approve',   'Approve shop stock requests', 102),
  ('shop_pos.use',              'Water Shops',      'pos',             'Use the shop POS and daily closing', 103),
  ('shops.settle',              'Water Shops',      'settle',          'Run shop settlements', 104),
  ('inventory.view',            'Inventory',        'view',            'View stock', 110),
  ('inventory.manage',          'Inventory',        'manage',          'Receive, issue and transfer stock', 111),
  ('inventory.adjust',          'Inventory',        'adjust',          'Approve stock adjustments', 112),
  ('production.view',           'Production',       'view',            'View production batches', 120),
  ('production.manage',         'Production',       'manage',          'Record production', 121),
  ('qc.view',                   'Quality Control',  'view',            'View QC results', 130),
  ('qc.manage',                 'Quality Control',  'manage',          'Record QC tests and results', 131),
  ('qc.release',                'Quality Control',  'release',         'Release held or failed batches', 132),
  ('procurement.view',          'Procurement',      'view',            'View purchasing', 140),
  ('procurement.manage',        'Procurement',      'manage',          'Create purchase requests and orders', 141),
  ('procurement.approve',       'Procurement',      'approve',         'Approve purchases', 142),
  ('suppliers.manage',          'Suppliers',        'manage',          'Manage suppliers', 145),
  ('payments.view',             'Payments',         'view',            'View payments', 150),
  ('payments.manage',           'Payments',         'manage',          'Record payments and refunds', 151),
  ('accounting.view',           'Accounting',       'view',            'View the general ledger and reports', 160),
  ('accounting.manual_journal', 'Accounting',       'manual_journal',  'Post manual journals', 161),
  ('accounting.reverse',        'Accounting',       'reverse',         'Reverse journal entries', 162),
  ('accounting.period_close',   'Accounting',       'period_close',    'Open and close accounting periods', 163),
  ('expenses.view',             'Expenses',         'view',            'View expenses', 170),
  ('expenses.manage',           'Expenses',         'manage',          'Record expenses', 171),
  ('expenses.approve',          'Expenses',         'approve',         'Approve expenses', 172),
  ('hr.view',                   'HR & Payroll',     'view',            'View employee records', 180),
  ('hr.manage',                 'HR & Payroll',     'manage',          'Manage employees, attendance and leave', 181),
  ('payroll.run',               'HR & Payroll',     'payroll',         'Run payroll', 182),
  ('sales_reps.manage',         'Sales Reps',       'manage',          'Manage sales representatives and targets', 190),
  ('distributors.manage',       'Distributors',     'manage',          'Manage distributors and dealers', 195),
  ('fleet.manage',              'Fleet',            'manage',          'Manage vehicles, fuel and maintenance', 200),
  ('assets.manage',             'Assets',           'manage',          'Manage fixed assets', 205),
  ('complaints.view',           'Complaints',       'view',            'View complaints', 210),
  ('complaints.manage',         'Complaints',       'manage',          'Handle complaints', 211),
  ('crm.manage',                'Marketing / CRM',  'manage',          'Manage leads, campaigns and promotions', 215),
  ('documents.view',            'Documents',        'view',            'View documents', 220),
  ('documents.manage',          'Documents',        'manage',          'Upload and manage documents', 221),
  ('approvals.act',             'Approvals',        'act',             'Approve or reject requests', 225),
  ('reports.view',              'Reports',          'view',            'View reports', 230),
  ('reports.export',            'Reports',          'export',          'Export data', 231),
  ('ai.ask',                    'AI Assistant',     'use',             'Use the read-only AI assistant', 235),
  ('audit.view',                'Audit Trail',      'view',            'View the audit trail', 240),
  ('users.manage',              'Administration',   'users',           'Manage users and role assignments', 250),
  ('roles.manage',              'Administration',   'roles',           'Create and edit roles', 251),
  ('settings.manage',           'Administration',   'settings',        'Change system settings', 252),
  ('devices.manage',            'Administration',   'devices',         'Register devices', 253);

-- ---------------------------------------------------------------------
-- Default roles (configurable afterwards)
-- ---------------------------------------------------------------------
insert into public.roles (code, name, role_group, is_system, description) values
  ('super_admin',          'Super Admin',          'management',     true,  'Full access to everything'),
  ('director',             'Director',             'management',     true,  'Company-wide visibility and approvals'),
  ('finance_manager',      'Finance Manager',      'management',     true,  'Accounting, payments, credit and approvals'),
  ('operations_manager',   'Operations Manager',   'management',     true,  'Production, warehouse, delivery and shops'),
  ('warehouse_manager',    'Warehouse Manager',    'operations',     true,  'Warehouse, stock and bottle handling'),
  ('production_manager',   'Production Manager',   'operations',     true,  'Production batches'),
  ('quality_officer',      'Quality Officer',      'operations',     true,  'Quality control'),
  ('delivery_manager',     'Delivery Manager',     'operations',     true,  'Routes, drivers and reconciliation'),
  ('driver',               'Driver',               'operations',     true,  'Driver application only'),
  ('sales_representative', 'Sales Representative', 'operations',     true,  'Customers, orders and collections'),
  ('accountant',           'Accountant',           'commercial',     true,  'Day-to-day accounting'),
  ('shop_manager',         'Shop Manager',         'commercial',     true,  'Runs a water shop'),
  ('shop_cashier',         'Shop Cashier',         'commercial',     true,  'Shop POS only'),
  ('distributor_manager',  'Distributor Manager',  'commercial',     true,  'Distributors and dealers'),
  ('hr_manager',           'HR Manager',           'administration', true,  'Employees and payroll'),
  ('procurement_officer',  'Procurement Officer',  'administration', true,  'Purchasing and suppliers');

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  join (values
    ('director', array['dashboard.view','customers.view','customers.credit','products.view','prices.manage','orders.view',
                       'pos.discount','bottles.view','bottles.writeoff','deliveries.view','shops.view','shops.stock_approve',
                       'inventory.view','inventory.adjust','production.view','qc.view','qc.release','procurement.view',
                       'procurement.approve','payments.view','accounting.view','expenses.view','expenses.approve','hr.view',
                       'complaints.view','documents.view','approvals.act','reports.view','reports.export','ai.ask','audit.view',
                       'labels.view']),
    ('finance_manager', array['dashboard.view','customers.view','customers.credit','products.view','prices.manage','orders.view',
                       'bottles.view','bottles.writeoff','shops.view','shops.settle','inventory.view','procurement.view',
                       'procurement.approve','suppliers.manage','payments.view','payments.manage','accounting.view',
                       'accounting.manual_journal','accounting.reverse','accounting.period_close','expenses.view',
                       'expenses.manage','expenses.approve','approvals.act','reports.view','reports.export','audit.view',
                       'documents.view','ai.ask']),
    ('operations_manager', array['dashboard.view','customers.view','products.view','orders.view','orders.manage','bottles.view',
                       'bottles.manage','bottles.external','bottles.writeoff','labels.view','labels.print','deliveries.view',
                       'deliveries.manage','deliveries.reconcile','routes.manage','shops.view','shops.manage','shops.stock_approve',
                       'inventory.view','inventory.manage','inventory.adjust','production.view','production.manage','qc.view',
                       'qc.release','fleet.manage','assets.manage','complaints.view','complaints.manage','approvals.act',
                       'reports.view','documents.view','ai.ask']),
    ('warehouse_manager', array['dashboard.view','products.view','orders.view','bottles.view','bottles.manage','bottles.external',
                       'labels.view','labels.print','deliveries.view','shops.view','shops.stock_approve','inventory.view',
                       'inventory.manage','inventory.adjust','production.view','qc.view','approvals.act','reports.view']),
    ('production_manager', array['dashboard.view','products.view','inventory.view','production.view','production.manage',
                       'qc.view','bottles.view','labels.view','reports.view']),
    ('quality_officer', array['production.view','qc.view','qc.manage','complaints.view','documents.view','documents.manage']),
    ('delivery_manager', array['dashboard.view','customers.view','orders.view','orders.manage','bottles.view','bottles.manage',
                       'bottles.external','deliveries.view','deliveries.manage','deliveries.reconcile','routes.manage',
                       'fleet.manage','complaints.view','reports.view']),
    ('driver', array['driver.app']),
    ('sales_representative', array['customers.view','customers.manage','products.view','orders.view','orders.manage',
                       'payments.view','complaints.view','complaints.manage','crm.manage']),
    ('accountant', array['customers.view','products.view','orders.view','payments.view','payments.manage','accounting.view',
                       'accounting.manual_journal','expenses.view','expenses.manage','shops.view','shops.settle',
                       'reports.view','documents.view']),
    ('shop_manager', array['shops.view','shop_pos.use','customers.view','products.view','bottles.view','inventory.view',
                       'reports.view']),
    ('shop_cashier', array['shop_pos.use','customers.view','products.view']),
    ('distributor_manager', array['customers.view','products.view','orders.view','orders.manage','distributors.manage',
                       'bottles.view','reports.view']),
    ('hr_manager', array['hr.view','hr.manage','payroll.run','documents.view','documents.manage']),
    ('procurement_officer', array['products.view','inventory.view','procurement.view','procurement.manage','suppliers.manage',
                       'documents.view'])
  ) as m(role_code, perms) on m.role_code = r.code
  cross join lateral unnest(m.perms) as x(code)
  join public.permissions p on p.code = x.code;

-- ---------------------------------------------------------------------
-- Locations
-- ---------------------------------------------------------------------
insert into public.locations (code, name, location_type) values
  ('HQ',  'Head Office',    'head_office'),
  ('WH1', 'Main Warehouse', 'warehouse'),
  ('EXT', 'External Bottle Holding Area', 'external_holding');

-- ---------------------------------------------------------------------
-- Document types
-- ---------------------------------------------------------------------
insert into public.document_types (code, name, padding) values
  ('JE',  'Journal entry', 6),
  ('LBL', 'Label batch', 6),
  ('ORD', 'Sales order', 6),
  ('INV', 'Tax invoice', 6),
  ('RCP', 'Receipt', 6),
  ('DN',  'Delivery note', 6),
  ('RUN', 'Route run', 6),
  ('STR', 'Stock transfer', 6),
  ('SRQ', 'Shop stock request', 6),
  ('SET', 'Shop settlement', 6),
  ('EHO', 'External bottle hand-over', 6),
  ('PAY', 'Payment', 6),
  ('CN',  'Credit note', 6);

-- ---------------------------------------------------------------------
-- Identifier series
-- ---------------------------------------------------------------------
insert into public.identifier_series (code, name, entity_type, padding) values
  ('OLA-BTL',  'OLA returnable bottles',           'bottle',          8),
  ('OLA-CRT',  'OLA crates / pallets',             'crate',           8),
  ('EXT-AQUA', 'External tags — Aqua Water',       'external_bottle', 8),
  ('EXT-XYZ',  'External tags — XYZ Water',        'external_bottle', 8),
  ('EXT-ABC',  'External tags — ABC Water',        'external_bottle', 8),
  ('EXT-UNK',  'External tags — unknown brand',    'external_bottle', 8);

-- ---------------------------------------------------------------------
-- Settings (definitions + initial values; all editable later)
-- ---------------------------------------------------------------------
insert into public.setting_definitions (key, module, label, description, value_type, choices, min_value, max_value, sort_order) values
  ('company.name',                         'Company',   'Company name',                    'Shown on receipts and documents', 'text', null, null, null, 1),
  ('company.vat_registration_no',          'Company',   'VAT registration number',         'Printed on tax invoices', 'text', null, null, null, 2),
  ('company.timezone',                     'Company',   'Time zone',                       'Business day boundary', 'choice', array['Asia/Colombo'], null, null, 3),
  ('company.currency',                     'Company',   'Base currency',                   null, 'choice', array['LKR'], null, null, 4),
  ('company.head_office_location',         'Company',   'Head office location code',       'Used for company-wide document numbers', 'text', null, null, null, 5),
  ('receipts.footer_text',                 'Receipts',  'Receipt footer',                  'Printed at the bottom of every receipt', 'text', null, null, null, 10),
  ('bottles.external_tracking_mode',       'Bottles',   'External bottle tracking',        'tagged = each bottle gets an EXT- label; count = counted per company', 'choice', array['tagged','count'], null, null, 20),
  ('bottles.external_intake_photo',        'Bottles',   'Photo on external intake',        null, 'choice', array['always','unknown_brand_only','never'], null, null, 21),
  ('bottles.external_holding_alert_qty',   'Bottles',   'External holding alert (per company)', 'Alert when bottles held for one company exceed this', 'integer', null, 0, null, 22),
  ('bottles.inactive_days_alert',          'Bottles',   'Bottle inactivity alert (days)',  'Flag bottles with no movement for this many days', 'integer', null, 1, null, 23),
  ('approvals.discount_percent',           'Approvals', 'Discount needing approval (%)',   null, 'percent', null, null, null, 30),
  ('approvals.purchase_amount',            'Approvals', 'Purchase needing approval (Rs.)', null, 'money', null, null, null, 31),
  ('approvals.expense_amount',             'Approvals', 'Expense needing approval (Rs.)',  null, 'money', null, null, null, 32),
  ('approvals.stock_adjustment_qty',       'Approvals', 'Stock adjustment needing approval (units)', null, 'integer', null, 0, null, 33),
  ('offline.unsynced_alert_hours',         'Offline',   'Unsynced data alert (hours)',     'Warn managers about devices with unsynced transactions', 'integer', null, 1, 72, 40);

insert into public.system_settings (key, value, effective_from) values
  ('company.name',                       '"OLA Water"',     date '2026-01-01'),
  ('company.vat_registration_no',        '""',              date '2026-01-01'),
  ('company.timezone',                   '"Asia/Colombo"',  date '2026-01-01'),
  ('company.currency',                   '"LKR"',           date '2026-01-01'),
  ('company.head_office_location',       '"HQ"',            date '2026-01-01'),
  ('receipts.footer_text',               '"Thank you for choosing OLA Water. Please return empty bottles."', date '2026-01-01'),
  ('bottles.external_tracking_mode',     '"tagged"',        date '2026-01-01'),
  ('bottles.external_intake_photo',      '"unknown_brand_only"', date '2026-01-01'),
  ('bottles.external_holding_alert_qty', '100',             date '2026-01-01'),
  ('bottles.inactive_days_alert',        '60',              date '2026-01-01'),
  ('approvals.discount_percent',         '10',              date '2026-01-01'),
  ('approvals.purchase_amount',          '100000',          date '2026-01-01'),
  ('approvals.expense_amount',           '25000',           date '2026-01-01'),
  ('approvals.stock_adjustment_qty',     '50',              date '2026-01-01'),
  ('offline.unsynced_alert_hours',       '4',               date '2026-01-01');

-- ---------------------------------------------------------------------
-- Chart of accounts (default template; editable)
-- ---------------------------------------------------------------------
insert into public.accounts (code, name, account_type, is_postable, system_key) values
  ('1000', 'Assets',                               'asset',     false, null),
  ('2000', 'Liabilities',                          'liability', false, null),
  ('3000', 'Equity',                               'equity',    false, null),
  ('4000', 'Income',                               'income',    false, null),
  ('5000', 'Cost of Sales',                        'expense',   false, null),
  ('6000', 'Operating Expenses',                   'expense',   false, null);

insert into public.accounts (code, name, account_type, system_key, parent_id)
select v.code, v.name, v.type, v.key, (select id from public.accounts where code = v.parent)
  from (values
    ('1100', 'Cash in Hand',                        'asset',     'cash',                   '1000'),
    ('1110', 'Petty Cash',                          'asset',     'petty_cash',             '1000'),
    ('1120', 'Driver Cash in Transit',              'asset',     'driver_cash',            '1000'),
    ('1130', 'Shop Cash Clearing',                  'asset',     'shop_cash',              '1000'),
    ('1200', 'Bank — Current Account',              'asset',     'bank',                   '1000'),
    ('1210', 'Card / QR Settlement Clearing',       'asset',     'card_clearing',          '1000'),
    ('1300', 'Accounts Receivable — Customers',     'asset',     'ar',                     '1000'),
    ('1310', 'Accounts Receivable — Water Shops',   'asset',     'ar_shops',               '1000'),
    ('1320', 'Accounts Receivable — Distributors',  'asset',     'ar_distributors',        '1000'),
    ('1400', 'Inventory — Finished Goods',          'asset',     'inv_finished',           '1000'),
    ('1410', 'Inventory — Raw Materials',           'asset',     'inv_raw',                '1000'),
    ('1420', 'Inventory — Returnable Bottles',      'asset',     'inv_bottles',            '1000'),
    ('1500', 'VAT Input',                           'asset',     'vat_input',              '1000'),
    ('1600', 'Plant & Machinery',                   'asset',     'fa_plant',               '1000'),
    ('1610', 'Motor Vehicles',                      'asset',     'fa_vehicles',            '1000'),
    ('1620', 'Office Equipment',                    'asset',     'fa_office',              '1000'),
    ('1690', 'Accumulated Depreciation',            'asset',     'accum_depreciation',     '1000'),
    ('2100', 'Accounts Payable',                    'liability', 'ap',                     '2000'),
    ('2200', 'Bottle Deposits Held',                'liability', 'bottle_deposits',        '2000'),
    ('2300', 'VAT Output',                          'liability', 'vat_output',             '2000'),
    ('2310', 'SSCL Payable',                        'liability', 'sscl_payable',           '2000'),
    ('2400', 'EPF Payable',                         'liability', 'epf_payable',            '2000'),
    ('2410', 'ETF Payable',                         'liability', 'etf_payable',            '2000'),
    ('2420', 'PAYE / APIT Payable',                 'liability', 'paye_payable',           '2000'),
    ('2500', 'Salaries Payable',                    'liability', 'salaries_payable',       '2000'),
    ('2600', 'Customer Advances',                   'liability', 'customer_advances',      '2000'),
    ('3100', 'Share Capital',                       'equity',    'share_capital',          '3000'),
    ('3200', 'Retained Earnings',                   'equity',    'retained_earnings',      '3000'),
    ('3900', 'Opening Balance Equity',              'equity',    'opening_equity',         '3000'),
    ('4100', 'Sales — Bottled Water',               'income',    'sales',                  '4000'),
    ('4110', 'Sales — Water Shops',                 'income',    'sales_shops',            '4000'),
    ('4150', 'Sales Discounts',                     'income',    'sales_discounts',        '4000'),
    ('4200', 'Delivery Charges',                    'income',    'delivery_income',        '4000'),
    ('4300', 'Forfeited Bottle Deposits',           'income',    'deposit_forfeit_income', '4000'),
    ('4400', 'Bottle Replacement Charges',          'income',    'bottle_charge_income',   '4000'),
    ('4900', 'Other Income',                        'income',    'other_income',           '4000'),
    ('5100', 'Cost of Goods Sold',                  'expense',   'cogs',                   '5000'),
    ('6100', 'Fuel',                                'expense',   'exp_fuel',               '6000'),
    ('6110', 'Electricity',                         'expense',   'exp_electricity',        '6000'),
    ('6120', 'Water',                               'expense',   'exp_water',              '6000'),
    ('6130', 'Rent',                                'expense',   'exp_rent',               '6000'),
    ('6140', 'Salaries & Wages',                    'expense',   'exp_salaries',           '6000'),
    ('6150', 'Vehicle Repairs',                     'expense',   'exp_vehicle_repair',     '6000'),
    ('6160', 'Maintenance',                         'expense',   'exp_maintenance',        '6000'),
    ('6170', 'Marketing',                           'expense',   'exp_marketing',          '6000'),
    ('6180', 'Packaging',                           'expense',   'exp_packaging',          '6000'),
    ('6190', 'Office Expenses',                     'expense',   'exp_office',             '6000'),
    ('6200', 'Utilities',                           'expense',   'exp_utilities',          '6000'),
    ('6300', 'Bottle Losses & Write-offs',          'expense',   'bottle_writeoff',        '6000'),
    ('6310', 'Cash Shortages',                      'expense',   'cash_shortage',          '6000'),
    ('6320', 'Inventory Adjustments',               'expense',   'inventory_adjustment',   '6000'),
    ('6400', 'Depreciation',                        'expense',   'exp_depreciation',       '6000'),
    ('6900', 'Other Expenses',                      'expense',   'exp_other',              '6000')
  ) as v(code, name, type, key, parent);

-- ---------------------------------------------------------------------
-- Posting events and rules (Phase 1 events defined up front)
-- ---------------------------------------------------------------------
insert into public.posting_event_types (code, module, description, amount_keys) values
  ('sale.cash',              'sales',    'Cash sale (POS or delivery)',                  array['gross','net','vat','levy']),
  ('sale.credit',            'sales',    'Credit sale to a customer',                    array['gross','net','vat','levy']),
  ('sale.card',              'sales',    'Card / QR sale',                               array['gross','net','vat','levy']),
  ('sale.shop_transfer',     'shops',    'Stock issued to a water shop on account',      array['gross','net','vat','levy']),
  ('payment.cash',           'payments', 'Customer payment received in cash',            array['amount']),
  ('payment.bank',           'payments', 'Customer payment received by bank transfer',   array['amount']),
  ('payment.shop',           'payments', 'Water shop payment to OLA',                    array['amount']),
  ('deposit.collected',      'bottles',  'Bottle deposit collected in cash',             array['deposit']),
  ('deposit.refunded',       'bottles',  'Bottle deposit refunded in cash',              array['deposit']),
  ('deposit.forfeited',      'bottles',  'Deposit kept for a lost bottle',               array['deposit']),
  ('bottle.writeoff',        'bottles',  'Bottle written off at replacement value',      array['value']),
  ('bottle.charge',          'bottles',  'Customer charged for a lost bottle (on account)', array['value']),
  ('driver.cash_shortage',   'delivery', 'Driver cash shortage written off',             array['amount']),
  ('driver.cash_handover',   'delivery', 'Driver hands collected cash to the office',   array['amount']),
  ('manual.journal',         'accounting', 'Manual journal entry',                       array[]::text[]);

insert into public.posting_rules (event_type, line_no, side, account_key, amount_key, description) values
  ('sale.cash',            1, 'debit',  'cash',                   'gross',   'Cash received'),
  ('sale.cash',            2, 'credit', 'sales',                  'net',     'Sales'),
  ('sale.cash',            3, 'credit', 'vat_output',             'vat',     'VAT output'),
  ('sale.cash',            4, 'credit', 'sscl_payable',           'levy',    'SSCL'),
  ('sale.credit',          1, 'debit',  'ar',                     'gross',   'Receivable'),
  ('sale.credit',          2, 'credit', 'sales',                  'net',     'Sales'),
  ('sale.credit',          3, 'credit', 'vat_output',             'vat',     'VAT output'),
  ('sale.credit',          4, 'credit', 'sscl_payable',           'levy',    'SSCL'),
  ('sale.card',            1, 'debit',  'card_clearing',          'gross',   'Card / QR receipt'),
  ('sale.card',            2, 'credit', 'sales',                  'net',     'Sales'),
  ('sale.card',            3, 'credit', 'vat_output',             'vat',     'VAT output'),
  ('sale.card',            4, 'credit', 'sscl_payable',           'levy',    'SSCL'),
  ('sale.shop_transfer',   1, 'debit',  'ar_shops',               'gross',   'Shop receivable'),
  ('sale.shop_transfer',   2, 'credit', 'sales_shops',            'net',     'Sales to water shops'),
  ('sale.shop_transfer',   3, 'credit', 'vat_output',             'vat',     'VAT output'),
  ('sale.shop_transfer',   4, 'credit', 'sscl_payable',           'levy',    'SSCL'),
  ('payment.cash',         1, 'debit',  'cash',                   'amount',  'Cash received'),
  ('payment.cash',         2, 'credit', 'ar',                     'amount',  'Receivable settled'),
  ('payment.bank',         1, 'debit',  'bank',                   'amount',  'Bank receipt'),
  ('payment.bank',         2, 'credit', 'ar',                     'amount',  'Receivable settled'),
  ('payment.shop',         1, 'debit',  'bank',                   'amount',  'Shop payment received'),
  ('payment.shop',         2, 'credit', 'ar_shops',               'amount',  'Shop receivable settled'),
  ('deposit.collected',    1, 'debit',  'cash',                   'deposit', 'Deposit received'),
  ('deposit.collected',    2, 'credit', 'bottle_deposits',        'deposit', 'Deposit held'),
  ('deposit.refunded',     1, 'debit',  'bottle_deposits',        'deposit', 'Deposit released'),
  ('deposit.refunded',     2, 'credit', 'cash',                   'deposit', 'Deposit refunded'),
  ('deposit.forfeited',    1, 'debit',  'bottle_deposits',        'deposit', 'Deposit released'),
  ('deposit.forfeited',    2, 'credit', 'deposit_forfeit_income', 'deposit', 'Deposit forfeited'),
  ('bottle.writeoff',      1, 'debit',  'bottle_writeoff',        'value',   'Bottle written off'),
  ('bottle.writeoff',      2, 'credit', 'inv_bottles',            'value',   'Bottle stock reduced'),
  ('bottle.charge',        1, 'debit',  'ar',                     'value',   'Customer charged'),
  ('bottle.charge',        2, 'credit', 'bottle_charge_income',   'value',   'Bottle replacement charge'),
  ('driver.cash_shortage', 1, 'debit',  'cash_shortage',          'amount',  'Cash shortage'),
  ('driver.cash_shortage', 2, 'credit', 'driver_cash',            'amount',  'Driver cash cleared'),
  ('driver.cash_handover', 1, 'debit',  'cash',                   'amount',  'Cash received from driver'),
  ('driver.cash_handover', 2, 'credit', 'driver_cash',            'amount',  'Driver cash cleared');

-- ---------------------------------------------------------------------
-- Accounting periods
-- ---------------------------------------------------------------------
select public.ensure_accounting_year(2026);
select public.ensure_accounting_year(2027);

-- >>> 20261001000008_api_grants.sql
-- =====================================================================
-- OLA Water ERP — Phase 0
-- 0008: explicit read grants for the Supabase Data API
-- Some Supabase projects do not grant table access to API roles
-- automatically. Reads are still filtered by Row Level Security, and
-- all writes go through the permission-checked functions.
-- =====================================================================
grant usage on schema public to anon, authenticated, service_role;
grant select on all tables in schema public to authenticated, service_role;
revoke all on all tables in schema public from anon;
