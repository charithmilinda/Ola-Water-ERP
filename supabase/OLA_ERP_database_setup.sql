-- OLA Water ERP — complete database setup (Phase 0 + Phase 1A + Phase 1B)
-- For a NEW, empty Supabase project only. Paste into SQL Editor → New query → Run. Run it ONCE.

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
security definer   -- must see every line regardless of the poster's RLS
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

-- >>> 20261002000008_fix_balance_check.sql
-- =====================================================================
-- OLA Water ERP — Phase 1A
-- 0008b: fix — the balanced-journal check must see every journal line,
-- whatever the poster's own read permissions (warehouse, drivers).
-- =====================================================================
create or replace function app.check_entry_balanced()
returns trigger
language plpgsql
security definer
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
revoke execute on function app.check_entry_balanced() from public, anon, authenticated;

-- >>> 20261002000009_catalogue_customers.sql
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

-- >>> 20261002000010_stock_and_bottles.sql
-- =====================================================================
-- OLA Water ERP — Phase 1A
-- 0010: stock ledger (products) and bottle ledger (containers)
-- =====================================================================
-- Two separate, append-only ledgers:
--   inventory_transactions  — filled product units (water) by location
--   bottle_transactions     — returnable containers by holder, owner company
--                             and fill state, serialised (per bottle) or
--                             counted (count mode)
-- Holders: 'location' (warehouse, vehicle, shop, external holding),
--          'customer', 'company' (an external water company),
--          'outside' (source/sink for bottles entering or leaving).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Product stock
-- ---------------------------------------------------------------------
create table public.inventory_balances (
  location_id  uuid not null references public.locations(id),
  product_id   uuid not null references public.products(id),
  stock_status text not null default 'available' check (stock_status in ('available','damaged')),
  qty          numeric(14,3) not null default 0 check (qty >= 0),
  updated_at   timestamptz not null default now(),
  primary key (location_id, product_id, stock_status)
);

create table public.inventory_transactions (
  id              bigint generated always as identity primary key,
  txn_type        text not null check (txn_type in
                    ('opening','receipt','transfer','load_out','check_in','sale','adjust_gain','adjust_loss','damaged','return')),
  product_id      uuid not null references public.products(id),
  qty             numeric(14,3) not null check (qty > 0),
  from_location   uuid references public.locations(id),
  to_location     uuid references public.locations(id),
  stock_status    text not null default 'available',
  unit_cost       numeric(12,2),
  reference_type  text,
  reference_id    uuid,
  reason          text,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  client_txn_id   uuid,
  check (from_location is not null or to_location is not null)
);
create index inventory_transactions_product_idx on public.inventory_transactions (product_id, created_at desc);
create index inventory_transactions_ref_idx on public.inventory_transactions (reference_type, reference_id);
create trigger inventory_transactions_append_only before update or delete on public.inventory_transactions
  for each row execute function app.forbid_change();

create or replace function app.stock_move(
  p_txn_type text, p_product uuid, p_qty numeric, p_from uuid, p_to uuid,
  p_ref_type text default null, p_ref_id uuid default null, p_reason text default null,
  p_status text default 'available')
returns void language plpgsql security definer set search_path = '' as $$
declare v_have numeric; v_name text; v_loc text;
begin
  if p_qty is null or p_qty = 0 then return; end if;
  if p_qty < 0 then raise exception 'Quantity cannot be negative' using errcode = '22023'; end if;

  if p_from is not null then
    select qty into v_have from public.inventory_balances
     where location_id = p_from and product_id = p_product and stock_status = p_status for update;
    if coalesce(v_have, 0) < p_qty then
      select name into v_name from public.products where id = p_product;
      select name into v_loc from public.locations where id = p_from;
      raise exception 'Not enough stock: % at % has %, needs %', v_name, v_loc, coalesce(v_have, 0)::numeric(14,0), p_qty::numeric(14,0)
        using errcode = 'P0001';
    end if;
    update public.inventory_balances set qty = qty - p_qty, updated_at = now()
     where location_id = p_from and product_id = p_product and stock_status = p_status;
  end if;

  if p_to is not null then
    insert into public.inventory_balances (location_id, product_id, stock_status, qty)
    values (p_to, p_product, p_status, p_qty)
    on conflict (location_id, product_id, stock_status) do update set qty = public.inventory_balances.qty + excluded.qty, updated_at = now();
  end if;

  insert into public.inventory_transactions (txn_type, product_id, qty, from_location, to_location, stock_status,
    unit_cost, reference_type, reference_id, reason, created_by, client_txn_id)
  values (p_txn_type, p_product, p_qty, p_from, p_to, p_status,
    (select cost_price from public.products where id = p_product), p_ref_type, p_ref_id,
    coalesce(p_reason, nullif(current_setting('app.reason', true), '')), app.current_user_id(),
    nullif(current_setting('app.client_txn_id', true), '')::uuid);
end $$;

-- ---------------------------------------------------------------------
-- Bottles (serialised containers)
-- ---------------------------------------------------------------------
create table public.bottles (
  id                uuid primary key default gen_random_uuid(),
  code              text not null unique,
  identifier_id     uuid unique references public.identifiers(id),
  company_id        uuid not null references public.bottle_companies(id),
  bottle_type_id    uuid not null references public.bottle_types(id),
  holder_type       text not null check (holder_type in ('location','customer','company','outside')),
  holder_id         uuid,
  fill_state        text not null default 'empty' check (fill_state in ('full','empty')),
  condition         text not null default 'good' check (condition in ('good','needs_inspection','damaged')),
  lifecycle         text not null default 'active' check (lifecycle in ('active','lost','written_off','retired','returned_to_owner')),
  fill_count        integer not null default 0 check (fill_count >= 0),
  last_batch_no     text,
  intake_photo_path text,
  last_movement_at  timestamptz,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now()
);
create index bottles_holder_idx on public.bottles (holder_type, holder_id);
create index bottles_company_idx on public.bottles (company_id, lifecycle);

create table public.bottle_balances (
  holder_type     text not null check (holder_type in ('location','customer','company','outside')),
  holder_id       uuid not null,
  company_id      uuid not null references public.bottle_companies(id),
  bottle_type_id  uuid not null references public.bottle_types(id),
  fill_state      text not null check (fill_state in ('full','empty')),
  qty             integer not null default 0,
  updated_at      timestamptz not null default now(),
  primary key (holder_type, holder_id, company_id, bottle_type_id, fill_state)
);
comment on table public.bottle_balances is 'Running counts, updated in the same transaction as bottle_transactions. Negative values are allowed and flagged (e.g. bottles held before go-live).';

create table public.bottle_transactions (
  id               bigint generated always as identity primary key,
  txn_type         text not null check (txn_type in
                     ('opening','fill','load_out','deliver','collect','external_intake','check_in','to_external_holding',
                      'return_to_owner','received_from_company','transfer','mark_damaged','write_off','found','relabel','retire','adjust')),
  bottle_id        uuid references public.bottles(id),
  company_id       uuid not null references public.bottle_companies(id),
  bottle_type_id   uuid not null references public.bottle_types(id),
  qty              integer not null check (qty > 0),
  from_type        text not null,
  from_id          uuid not null,
  from_fill        text not null,
  to_type          text not null,
  to_id            uuid not null,
  to_fill          text not null,
  reference_type   text,
  reference_id     uuid,
  reason           text,
  gps_lat          numeric(9,6),
  gps_lng          numeric(9,6),
  created_at       timestamptz not null default now(),
  created_by       uuid,
  client_txn_id    uuid,
  check (bottle_id is null or qty = 1)
);
create index bottle_transactions_bottle_idx on public.bottle_transactions (bottle_id, created_at desc);
create index bottle_transactions_ref_idx    on public.bottle_transactions (reference_type, reference_id);
create index bottle_transactions_from_idx   on public.bottle_transactions (from_type, from_id, created_at desc);
create index bottle_transactions_to_idx     on public.bottle_transactions (to_type, to_id, created_at desc);
create trigger bottle_transactions_append_only before update or delete on public.bottle_transactions
  for each row execute function app.forbid_change();

create or replace function app.outside_id() returns uuid
language sql immutable set search_path = '' as $$ select '00000000-0000-0000-0000-000000000000'::uuid $$;

-- ---------------------------------------------------------------------
-- Exceptions (bottle location mismatches, reconciliation differences...)
-- ---------------------------------------------------------------------
create table public.operation_exceptions (
  id               uuid primary key default gen_random_uuid(),
  exception_type   text not null check (exception_type in
                     ('bottle_location','bottle_shortage','bottle_surplus','stock_shortage','stock_surplus','cash_shortage',
                      'cash_surplus','over_bottle_limit','credit_limit','negative_balance')),
  severity         text not null default 'warning' check (severity in ('info','warning','critical')),
  status           text not null default 'open' check (status in ('open','resolved')),
  run_id           uuid,
  location_id      uuid references public.locations(id),
  customer_id      uuid references public.customers(id),
  bottle_id        uuid references public.bottles(id),
  company_id       uuid references public.bottle_companies(id),
  bottle_type_id   uuid references public.bottle_types(id),
  product_id       uuid references public.products(id),
  expected         numeric(14,2),
  actual           numeric(14,2),
  difference       numeric(14,2),
  description      text not null,
  resolution       text check (resolution in ('found','charge_driver','write_off','accepted')),
  resolution_note  text,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  resolved_at      timestamptz,
  resolved_by      uuid,
  updated_at       timestamptz not null default now()
);
create index operation_exceptions_open_idx on public.operation_exceptions (status, created_at desc);
create index operation_exceptions_run_idx  on public.operation_exceptions (run_id);
create trigger operation_exceptions_touch before update on public.operation_exceptions for each row execute function app.touch_updated_at();
create trigger operation_exceptions_audit after insert or update on public.operation_exceptions for each row execute function app.audit_row('exceptions');

create or replace function app.raise_exception_record(
  p_type text, p_description text, p_severity text default 'warning',
  p_run uuid default null, p_location uuid default null, p_customer uuid default null, p_bottle uuid default null,
  p_company uuid default null, p_bottle_type uuid default null, p_product uuid default null,
  p_expected numeric default null, p_actual numeric default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  insert into public.operation_exceptions (exception_type, severity, run_id, location_id, customer_id, bottle_id, company_id,
    bottle_type_id, product_id, expected, actual, difference, description, created_by)
  values (p_type, p_severity, p_run, p_location, p_customer, p_bottle, p_company, p_bottle_type, p_product,
    p_expected, p_actual, case when p_expected is not null and p_actual is not null then p_actual - p_expected end,
    p_description, app.current_user_id())
  returning id into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Core bottle movement
--   Serialised (p_bottle given): moves that bottle. Counts always follow the
--   physical event (p_from -> p_to). If the bottle's record says it was
--   somewhere else, the scan is still accepted (never block the field), the
--   bottle record is corrected and a bottle_location exception is raised.
--   Counted (p_bottle null): moves p_qty bottles of a company/type.
-- ---------------------------------------------------------------------
create or replace function app.bottle_move(
  p_txn_type text, p_company uuid, p_bottle_type uuid, p_qty integer,
  p_from_type text, p_from_id uuid, p_from_fill text,
  p_to_type text, p_to_id uuid, p_to_fill text,
  p_ref_type text default null, p_ref_id uuid default null,
  p_bottle uuid default null, p_reason text default null,
  p_gps_lat numeric default null, p_gps_lng numeric default null,
  p_run uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  b public.bottles;
  v_from_type text := p_from_type; v_from_id uuid := p_from_id; v_from_fill text := p_from_fill;
  v_company uuid := p_company; v_type uuid := p_bottle_type; v_qty integer := coalesce(p_qty, 0);
begin
  if p_bottle is not null then
    select * into b from public.bottles where id = p_bottle for update;
    if not found then raise exception 'Bottle not found' using errcode = 'P0002'; end if;
    v_company := b.company_id; v_type := b.bottle_type_id; v_qty := 1;
    if b.holder_type <> p_from_type or b.holder_id is distinct from p_from_id then
      -- Bottles moved in count mode keep their old record; a mismatch with a
      -- company location is routine (info). Another customer is a warning.
      perform app.raise_exception_record('bottle_location',
        format('Bottle %s was recorded at %s but was handled at %s', b.code,
               app.holder_label(b.holder_type, b.holder_id), app.holder_label(p_from_type, p_from_id)),
        case when b.holder_type = 'customer' then 'warning' else 'info' end,
        p_run, null, case when p_from_type = 'customer' then p_from_id end, b.id, b.company_id, b.bottle_type_id);
    end if;
    update public.bottles set holder_type = p_to_type, holder_id = p_to_id, fill_state = p_to_fill,
           last_movement_at = now(), updated_at = now(),
           fill_count = fill_count + case when p_txn_type = 'fill' then 1 else 0 end,
           lifecycle = case when p_to_type = 'company' and company_id <> app.own_company_id() then 'returned_to_owner'
                            when p_txn_type = 'write_off' then 'written_off'
                            when p_txn_type = 'retire' then 'retired'
                            when lifecycle in ('lost','returned_to_owner','written_off') and p_txn_type in ('found','received_from_company','collect','external_intake') then 'active'
                            else lifecycle end
     where id = p_bottle;
  end if;

  if v_qty <= 0 then return; end if;

  insert into public.bottle_balances (holder_type, holder_id, company_id, bottle_type_id, fill_state, qty)
  values (v_from_type, coalesce(v_from_id, app.outside_id()), v_company, v_type, v_from_fill, -v_qty)
  on conflict (holder_type, holder_id, company_id, bottle_type_id, fill_state)
  do update set qty = public.bottle_balances.qty - v_qty, updated_at = now();

  insert into public.bottle_balances (holder_type, holder_id, company_id, bottle_type_id, fill_state, qty)
  values (p_to_type, coalesce(p_to_id, app.outside_id()), v_company, v_type, p_to_fill, v_qty)
  on conflict (holder_type, holder_id, company_id, bottle_type_id, fill_state)
  do update set qty = public.bottle_balances.qty + v_qty, updated_at = now();

  insert into public.bottle_transactions (txn_type, bottle_id, company_id, bottle_type_id, qty, from_type, from_id, from_fill,
    to_type, to_id, to_fill, reference_type, reference_id, reason, gps_lat, gps_lng, created_by, client_txn_id)
  values (p_txn_type, p_bottle, v_company, v_type, v_qty, v_from_type, coalesce(v_from_id, app.outside_id()), v_from_fill,
    p_to_type, coalesce(p_to_id, app.outside_id()), p_to_fill, p_ref_type, p_ref_id,
    coalesce(p_reason, nullif(current_setting('app.reason', true), '')), p_gps_lat, p_gps_lng, app.current_user_id(),
    nullif(current_setting('app.client_txn_id', true), '')::uuid);
end $$;

-- Human-readable name of a holder
create or replace function app.holder_label(p_type text, p_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case p_type
    when 'location' then (select name || ' (' || code || ')' from public.locations where id = p_id)
    when 'customer' then (select name || ' (' || customer_no || ')' from public.customers where id = p_id)
    when 'company'  then (select name from public.bottle_companies where id = p_id)
    else 'Outside the company' end
$$;

-- Register a new serialised bottle against a printed label
create or replace function app.register_bottle(
  p_code text, p_company uuid, p_bottle_type uuid, p_holder_type text, p_holder_id uuid, p_fill text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_ident public.identifiers; v uuid; v_entity text;
begin
  select * into v_ident from public.identifiers where value = upper(trim(p_code)) for update;
  if not found then
    raise exception 'Label % was not issued by this system', upper(trim(p_code)) using errcode = 'P0002';
  end if;
  if v_ident.status = 'void' then
    raise exception 'Label % belongs to a cancelled batch', v_ident.value using errcode = '22023';
  end if;
  if v_ident.status = 'assigned' then
    raise exception 'Label % is already on another bottle', v_ident.value using errcode = '23505';
  end if;
  v_entity := case when p_company = app.own_company_id() then 'bottle' else 'external_bottle' end;
  if v_ident.entity_type <> v_entity then
    raise exception 'Label % is a % label, not a % label', v_ident.value, replace(v_ident.entity_type, '_', ' '), replace(v_entity, '_', ' ')
      using errcode = '22023';
  end if;
  if v_entity = 'external_bottle' and v_ident.series_code <> 'EXT-UNK'
     and v_ident.series_code <> 'EXT-' || (select code from public.bottle_companies where id = p_company) then
    raise exception 'Label % is for a different company''s bottles', v_ident.value using errcode = '22023';
  end if;

  insert into public.bottles (code, identifier_id, company_id, bottle_type_id, holder_type, holder_id, fill_state, created_by, last_movement_at)
  values (v_ident.value, v_ident.id, p_company, p_bottle_type, p_holder_type, p_holder_id, p_fill, app.current_user_id(), now())
  returning id into v;

  perform set_config('app.audit_action', 'assign', true);
  update public.identifiers set status = 'assigned', entity_id = v, assigned_at = now(), assigned_by = app.current_user_id()
   where id = v_ident.id;
  perform set_config('app.audit_action', '', true);
  return v;
end $$;

create or replace function app.bottle_by_code(p_code text)
returns public.bottles language sql stable security definer set search_path = '' as $$
  select * from public.bottles where code = upper(trim(p_code))
$$;

-- ---------------------------------------------------------------------
-- Customer bottle deposits (liability)
-- ---------------------------------------------------------------------
create table public.deposit_transactions (
  id               bigint generated always as identity primary key,
  customer_id      uuid not null references public.customers(id),
  bottle_type_id   uuid not null references public.bottle_types(id),
  txn_type         text not null check (txn_type in ('collected','refunded','forfeited','opening')),
  qty              integer not null,
  amount           numeric(12,2) not null,
  reference_type   text,
  reference_id     uuid,
  created_at       timestamptz not null default now(),
  created_by       uuid
);
create index deposit_transactions_customer_idx on public.deposit_transactions (customer_id, bottle_type_id);
create trigger deposit_transactions_append_only before update or delete on public.deposit_transactions
  for each row execute function app.forbid_change();

create or replace view public.customer_deposit_balances with (security_invoker = true) as
  select customer_id, bottle_type_id,
         sum(case when txn_type in ('collected','opening') then qty else -qty end)::integer as qty_held,
         sum(case when txn_type in ('collected','opening') then amount else -amount end) as amount_held
    from public.deposit_transactions
   group by customer_id, bottle_type_id;

-- ---------------------------------------------------------------------
-- External bottle hand-overs to their owners
-- ---------------------------------------------------------------------
create table public.external_handovers (
  id               uuid primary key default gen_random_uuid(),
  handover_no      text not null unique,
  company_id       uuid not null references public.bottle_companies(id),
  handover_date    date not null,
  rep_name         text not null,
  rep_phone        text,
  bottles_given    integer not null default 0,
  ola_received     integer not null default 0,
  proof_path       text,
  notes            text,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  client_txn_id    uuid unique
);
create trigger external_handovers_append_only before update or delete on public.external_handovers
  for each row execute function app.forbid_change();
create trigger external_handovers_audit after insert on public.external_handovers
  for each row execute function app.audit_row('bottles');

-- =====================================================================
-- RPCs: stock
-- =====================================================================

-- Receive stock into a location. p_source: 'opening' (balances at go-live)
-- or 'receipt' (finished goods received, e.g. from production before the
-- Production module exists). Returnable products also fill bottles:
-- 'receipt' fills empties already at that location; 'opening' brings full
-- bottles in from outside.
create or replace function public.receive_stock(
  p_location uuid, p_lines jsonb, p_source text, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v_line jsonb; pr public.products; v_qty numeric; v_value numeric := 0; v_res jsonb;
begin
  perform app.require_permission('inventory.manage');
  if p_source not in ('opening','receipt') then raise exception 'Unknown source' using errcode = '22023'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'receive_stock');
  if v_done is not null then return v_done; end if;
  perform app.set_context(trim(p_reason), p_client_txn_id, null);

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_qty := app.jnum(v_line, 'qty');
    continue when coalesce(v_qty, 0) = 0;
    if v_qty < 0 or v_qty <> trunc(v_qty) then raise exception 'Quantities must be whole positive numbers' using errcode = '22023'; end if;
    select * into pr from public.products where id = app.juuid(v_line, 'product_id');
    if not found then raise exception 'Product not found' using errcode = 'P0002'; end if;

    perform app.stock_move(p_source, pr.id, v_qty, null, p_location, 'stock_receipt', p_client_txn_id);
    if pr.is_returnable then
      if p_source = 'opening' then
        perform app.bottle_move('opening', app.own_company_id(), pr.bottle_type_id, v_qty::integer,
          'outside', app.outside_id(), 'full', 'location', p_location, 'full', 'stock_receipt', p_client_txn_id);
      else
        perform app.bottle_move('fill', app.own_company_id(), pr.bottle_type_id, v_qty::integer,
          'location', p_location, 'empty', 'location', p_location, 'full', 'stock_receipt', p_client_txn_id);
      end if;
    end if;
    v_value := v_value + v_qty * pr.cost_price;
  end loop;

  if p_source = 'opening' and v_value > 0 then
    perform app.post_event('stock.opening', jsonb_build_object('value', v_value), app.today(),
      'Opening stock: ' || trim(p_reason), 'stock_receipt', p_client_txn_id, p_location);
  end if;

  v_res := jsonb_build_object('ok', true, 'value', v_value);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.transfer_stock(
  p_from uuid, p_to uuid, p_lines jsonb, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v_line jsonb; pr public.products; v_qty numeric; v_res jsonb;
begin
  perform app.require_permission('inventory.manage');
  if p_from = p_to then raise exception 'Choose two different locations' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'transfer_stock');
  if v_done is not null then return v_done; end if;
  perform app.set_context(nullif(trim(p_reason), ''), p_client_txn_id, null);
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_qty := app.jnum(v_line, 'qty');
    continue when coalesce(v_qty, 0) = 0;
    select * into pr from public.products where id = app.juuid(v_line, 'product_id');
    perform app.stock_move('transfer', pr.id, v_qty, p_from, p_to, 'stock_transfer', p_client_txn_id);
    if pr.is_returnable then
      perform app.bottle_move('transfer', app.own_company_id(), pr.bottle_type_id, v_qty::integer,
        'location', p_from, 'full', 'location', p_to, 'full', 'stock_transfer', p_client_txn_id);
    end if;
  end loop;
  v_res := jsonb_build_object('ok', true);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Counted stock differs from the system: post a gain or loss.
create or replace function public.adjust_stock(
  p_location uuid, p_product uuid, p_counted numeric, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v_have numeric; v_diff numeric; pr public.products; v_limit numeric; v_res jsonb;
begin
  perform app.require_permission('inventory.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required for a stock adjustment' using errcode = '22023'; end if;
  if p_counted is null or p_counted < 0 then raise exception 'Enter the counted quantity' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'adjust_stock');
  if v_done is not null then return v_done; end if;

  select * into pr from public.products where id = p_product;
  select coalesce(qty, 0) into v_have from public.inventory_balances
   where location_id = p_location and product_id = p_product and stock_status = 'available';
  v_have := coalesce(v_have, 0);
  v_diff := p_counted - v_have;
  v_limit := coalesce((app.get_setting('approvals.stock_adjustment_qty') #>> '{}')::numeric, 0);
  if abs(v_diff) > v_limit and not app.has_permission('inventory.adjust') then
    raise exception 'Adjustments over % units need a Warehouse Manager (inventory.adjust)', v_limit using errcode = '42501';
  end if;
  perform app.set_context(trim(p_reason), p_client_txn_id, 'stock_adjustment');

  if v_diff > 0 then
    perform app.stock_move('adjust_gain', p_product, v_diff, null, p_location, 'stock_adjustment', p_client_txn_id);
    if pr.cost_price > 0 then
      perform app.post_event('stock.adjust_gain', jsonb_build_object('value', v_diff * pr.cost_price), app.today(),
        'Stock count gain: ' || pr.name, 'stock_adjustment', p_client_txn_id, p_location);
    end if;
  elsif v_diff < 0 then
    perform app.stock_move('adjust_loss', p_product, -v_diff, p_location, null, 'stock_adjustment', p_client_txn_id);
    if pr.cost_price > 0 then
      perform app.post_event('stock.adjust_loss', jsonb_build_object('value', -v_diff * pr.cost_price), app.today(),
        'Stock count loss: ' || pr.name, 'stock_adjustment', p_client_txn_id, p_location);
    end if;
  end if;
  v_res := jsonb_build_object('previous', v_have, 'counted', p_counted, 'difference', v_diff);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- =====================================================================
-- RPCs: bottles
-- =====================================================================

-- Register printed OLA labels on bottles that are physically at a location
-- (bottles already in circulation before go-live, or new bottles bought).
create or replace function public.register_bottles(
  p_codes text[], p_bottle_type uuid, p_location uuid, p_fill text, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; c text; v uuid; n integer := 0; v_res jsonb;
begin
  perform app.require_permission('bottles.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'register_bottles');
  if v_done is not null then return v_done; end if;
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Bottle labelled'), p_client_txn_id, null);
  foreach c in array p_codes loop
    continue when nullif(trim(c), '') is null;
    v := app.register_bottle(c, app.own_company_id(), p_bottle_type, 'outside', app.outside_id(), p_fill);
    -- counted bottles at this location become serialised: no net count change
    update public.bottles set holder_type = 'location', holder_id = p_location where id = v;
    n := n + 1;
  end loop;
  v_res := jsonb_build_object('registered', n);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Bottle opening balances (e.g. bottles customers already hold at go-live)
create or replace function public.set_opening_bottles(
  p_holder_type text, p_holder_id uuid, p_company uuid, p_bottle_type uuid, p_fill text, p_qty integer,
  p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v_res jsonb;
begin
  perform app.require_permission('bottles.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  if p_holder_type not in ('location','customer') then raise exception 'Opening bottles go to a location or a customer' using errcode = '22023'; end if;
  if coalesce(p_qty, 0) <= 0 then raise exception 'Quantity must be at least 1' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'set_opening_bottles');
  if v_done is not null then return v_done; end if;
  perform app.set_context(trim(p_reason), p_client_txn_id, null);
  perform app.bottle_move('opening', p_company, p_bottle_type, p_qty, 'outside', app.outside_id(), p_fill,
    p_holder_type, p_holder_id, p_fill, 'opening_balance', p_client_txn_id);
  perform app.write_audit('opening_balance', 'bottles', 'bottle_balances', p_holder_id::text, null,
    jsonb_build_object('holder', app.holder_label(p_holder_type, p_holder_id), 'qty', p_qty, 'fill', p_fill,
      'company', (select name from public.bottle_companies where id = p_company),
      'bottle_type', (select name from public.bottle_types where id = p_bottle_type)));
  v_res := jsonb_build_object('ok', true);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Hand external bottles back to their owner, optionally receiving OLA bottles back.
-- p_give_codes: tagged bottles handed over; p_give_counts: [{bottle_type_id, qty}] untagged
-- p_receive_counts: [{bottle_type_id, qty}] OLA bottles received; p_receive_codes: scanned OLA bottles
create or replace function public.record_external_handover(
  p_company uuid, p_give_codes text[], p_give_counts jsonb, p_receive_codes text[], p_receive_counts jsonb,
  p_rep_name text, p_rep_phone text, p_notes text, p_proof_path text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; v_id uuid := gen_random_uuid(); v_no text; v_hold uuid; b public.bottles; c text; r jsonb;
  v_given integer := 0; v_recv integer := 0; v_wh uuid; v_res jsonb; v_avail integer;
begin
  perform app.require_permission('bottles.external');
  if nullif(trim(p_rep_name), '') is null then
    raise exception 'Enter the name of the company representative who received the bottles' using errcode = '22023';
  end if;
  if p_company = app.own_company_id() then raise exception 'Choose an external company' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'record_external_handover');
  if v_done is not null then return v_done; end if;
  perform app.set_context(null, p_client_txn_id, null);

  select id into v_hold from public.locations where location_type = 'external_holding' order by created_at limit 1;
  select id into v_wh from public.locations where code = 'WH1';
  v_no := app.next_document_number('EHO');

  foreach c in array coalesce(p_give_codes, '{}') loop
    continue when nullif(trim(c), '') is null;
    b := app.bottle_by_code(c);
    if b.id is null then raise exception 'Bottle % not found', c using errcode = 'P0002'; end if;
    if b.company_id <> p_company then raise exception 'Bottle % belongs to another company', b.code using errcode = '22023'; end if;
    perform app.bottle_move('return_to_owner', null, null, 1, 'location', v_hold, 'empty', 'company', p_company, 'empty',
      'external_handover', v_id, b.id);
    v_given := v_given + 1;
  end loop;

  for r in select * from jsonb_array_elements(coalesce(p_give_counts, '[]')) loop
    continue when coalesce(app.jint(r, 'qty'), 0) = 0;
    select coalesce(qty, 0) into v_avail from public.bottle_balances
     where holder_type = 'location' and holder_id = v_hold and company_id = p_company
       and bottle_type_id = app.juuid(r, 'bottle_type_id') and fill_state = 'empty';
    if coalesce(v_avail, 0) - (select count(*) from public.bottles where holder_type = 'location' and holder_id = v_hold
                                and company_id = p_company and bottle_type_id = app.juuid(r, 'bottle_type_id')) < app.jint(r, 'qty') then
      raise exception 'Only % untagged bottles of this type are in external holding', greatest(coalesce(v_avail, 0) - (select count(*) from public.bottles
        where holder_type = 'location' and holder_id = v_hold and company_id = p_company and bottle_type_id = app.juuid(r, 'bottle_type_id')), 0)
        using errcode = '22023';
    end if;
    perform app.bottle_move('return_to_owner', p_company, app.juuid(r, 'bottle_type_id'), app.jint(r, 'qty'),
      'location', v_hold, 'empty', 'company', p_company, 'empty', 'external_handover', v_id);
    v_given := v_given + app.jint(r, 'qty');
  end loop;

  foreach c in array coalesce(p_receive_codes, '{}') loop
    continue when nullif(trim(c), '') is null;
    b := app.bottle_by_code(c);
    if b.id is null then raise exception 'Bottle % not found', c using errcode = 'P0002'; end if;
    perform app.bottle_move('received_from_company', null, null, 1, b.holder_type, b.holder_id, b.fill_state,
      'location', v_wh, 'empty', 'external_handover', v_id, b.id);
    v_recv := v_recv + 1;
  end loop;

  for r in select * from jsonb_array_elements(coalesce(p_receive_counts, '[]')) loop
    continue when coalesce(app.jint(r, 'qty'), 0) = 0;
    perform app.bottle_move('received_from_company', app.own_company_id(), app.juuid(r, 'bottle_type_id'), app.jint(r, 'qty'),
      'company', p_company, 'empty', 'location', v_wh, 'empty', 'external_handover', v_id);
    v_recv := v_recv + app.jint(r, 'qty');
  end loop;

  if v_given + v_recv = 0 then raise exception 'Nothing was handed over or received' using errcode = '22023'; end if;

  insert into public.external_handovers (id, handover_no, company_id, handover_date, rep_name, rep_phone, bottles_given,
    ola_received, proof_path, notes, created_by, client_txn_id)
  values (v_id, v_no, p_company, app.today(), trim(p_rep_name), app.normalize_phone(p_rep_phone), v_given, v_recv,
    p_proof_path, nullif(trim(p_notes), ''), app.current_user_id(), p_client_txn_id);

  v_res := jsonb_build_object('handover_id', v_id, 'handover_no', v_no, 'given', v_given, 'received', v_recv);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Mark a bottle damaged (stays where it is, flagged) or retire it
create or replace function public.mark_bottle(p_code text, p_action text, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare b public.bottles;
begin
  perform app.require_permission('bottles.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  b := app.bottle_by_code(p_code);
  if b.id is null then raise exception 'Bottle not found' using errcode = 'P0002'; end if;
  perform app.set_context(trim(p_reason), null, p_action);
  if p_action = 'damaged' then
    update public.bottles set condition = 'damaged' where id = b.id;
  elsif p_action = 'repaired' then
    update public.bottles set condition = 'good' where id = b.id;
  elsif p_action = 'retire' then
    perform app.bottle_move('retire', null, null, 1, b.holder_type, b.holder_id, b.fill_state, 'outside', app.outside_id(), 'empty',
      'bottle', b.id, b.id, trim(p_reason));
  else
    raise exception 'Unknown action' using errcode = '22023';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.inventory_balances     enable row level security;
alter table public.inventory_transactions enable row level security;
alter table public.bottles                enable row level security;
alter table public.bottle_balances        enable row level security;
alter table public.bottle_transactions    enable row level security;
alter table public.operation_exceptions   enable row level security;
alter table public.deposit_transactions   enable row level security;
alter table public.external_handovers     enable row level security;

create policy inventory_balances_read on public.inventory_balances for select to authenticated
  using (app.has_permission('inventory.view') or app.has_permission('deliveries.manage'));
create policy inventory_transactions_read on public.inventory_transactions for select to authenticated
  using (app.has_permission('inventory.view'));
create policy bottles_read on public.bottles for select to authenticated using (app.has_permission('bottles.view'));
create policy bottle_balances_read on public.bottle_balances for select to authenticated
  using (app.has_permission('bottles.view') or app.has_permission('customers.view'));
create policy bottle_transactions_read on public.bottle_transactions for select to authenticated
  using (app.has_permission('bottles.view'));
create policy operation_exceptions_read on public.operation_exceptions for select to authenticated
  using (app.has_permission('deliveries.reconcile') or app.has_permission('bottles.view') or app.has_permission('inventory.view'));
create policy deposit_transactions_read on public.deposit_transactions for select to authenticated
  using (app.has_permission('customers.view'));
create policy external_handovers_read on public.external_handovers for select to authenticated
  using (app.has_permission('bottles.view'));

revoke insert, update, delete, truncate on
  public.inventory_transactions, public.bottle_transactions, public.deposit_transactions, public.external_handovers
  from anon, authenticated, service_role;

-- >>> 20261002000011_orders_invoices_payments.sql
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

-- >>> 20261002000012_runs_deliveries.sql
-- =====================================================================
-- OLA Water ERP — Phase 1A
-- 0012: route runs, deliveries, driver app RPCs, check-in reconciliation
-- =====================================================================

create table public.route_runs (
  id                 uuid primary key default gen_random_uuid(),
  run_no             text not null unique,
  run_date           date not null,
  route_id           uuid references public.routes(id),
  vehicle_id         uuid not null references public.vehicles(id),
  driver_id          uuid not null references public.profiles(id),
  helper_name        text,
  load_location_id   uuid not null references public.locations(id),
  status             text not null default 'planned' check (status in ('planned','loaded','in_progress','checked_in','closed','cancelled')),
  cash_float         numeric(12,2) not null default 0 check (cash_float >= 0),
  cash_expected      numeric(12,2),
  cash_handed        numeric(12,2),
  loaded_at          timestamptz,
  loaded_by          uuid,
  driver_confirmed_at timestamptz,
  checked_in_at      timestamptz,
  checked_in_by      uuid,
  closed_at          timestamptz,
  notes              text,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  client_txn_id      uuid unique
);
create index route_runs_date_idx on public.route_runs (run_date desc, status);
create index route_runs_driver_idx on public.route_runs (driver_id, run_date desc);
-- one active run per vehicle at a time
create unique index route_runs_one_active_per_vehicle on public.route_runs (vehicle_id)
  where status in ('planned','loaded','in_progress');

create table public.deliveries (
  id                   uuid primary key default gen_random_uuid(),
  delivery_no          text not null unique,
  run_id               uuid not null references public.route_runs(id),
  order_id             uuid not null references public.orders(id),
  customer_id          uuid not null references public.customers(id),
  address_id           uuid references public.customer_addresses(id),
  stop_sequence        integer not null,
  status               text not null default 'pending' check (status in ('pending','delivered','partially_delivered','failed','cancelled')),
  failure_reason       text,
  arrived_at           timestamptz,
  completed_at         timestamptz,
  synced_at            timestamptz,
  gps_lat              numeric(9,6),
  gps_lng              numeric(9,6),
  confirmation_method  text check (confirmation_method in ('signature','otp','photo','none')),
  recipient_name       text,
  signature_data       text check (signature_data is null or length(signature_data) < 120000),
  photo_path           text,
  otp_verified         boolean not null default false,
  invoice_id           uuid references public.invoices(id),
  summary              jsonb,
  notes                text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  client_txn_id        uuid unique
);
create index deliveries_run_idx on public.deliveries (run_id, stop_sequence);
create index deliveries_customer_idx on public.deliveries (customer_id, created_at desc);
create unique index deliveries_one_open_per_order on public.deliveries (order_id) where status = 'pending';

alter table public.invoices add constraint invoices_delivery_fk foreign key (delivery_id) references public.deliveries(id);
alter table public.invoices add constraint invoices_run_fk foreign key (run_id) references public.route_runs(id);
alter table public.payments add constraint payments_run_fk foreign key (run_id) references public.route_runs(id);
alter table public.payments add constraint payments_delivery_fk foreign key (delivery_id) references public.deliveries(id);
alter table public.operation_exceptions add constraint operation_exceptions_run_fk foreign key (run_id) references public.route_runs(id);

create trigger route_runs_touch before update on public.route_runs for each row execute function app.touch_updated_at();
create trigger deliveries_touch before update on public.deliveries for each row execute function app.touch_updated_at();
create trigger route_runs_audit after insert or update on public.route_runs for each row execute function app.audit_row('deliveries');
create trigger deliveries_audit after insert or update on public.deliveries for each row execute function app.audit_row('deliveries');
create trigger deliveries_no_delete before delete on public.deliveries for each row execute function app.forbid_change();

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create or replace function app.require_run_access(p_run uuid)
returns public.route_runs language plpgsql stable security definer set search_path = '' as $$
declare r public.route_runs;
begin
  select * into r from public.route_runs where id = p_run;
  if not found then raise exception 'Route run not found' using errcode = 'P0002'; end if;
  if app.has_permission('deliveries.manage') then return r; end if;
  if app.has_permission('driver.app') and r.driver_id = app.current_user_id() then return r; end if;
  raise exception 'Permission denied: this run belongs to another driver' using errcode = '42501';
end $$;

create or replace function app.vehicle_location(p_run uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select v.location_id from public.route_runs r join public.vehicles v on v.id = r.vehicle_id where r.id = p_run
$$;

create or replace function app.is_driver(p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.user_roles ur join public.roles r on r.id = ur.role_id
                  join public.profiles p on p.id = ur.user_id and p.is_active
                 where ur.user_id = p_user and r.code in ('driver','super_admin','delivery_manager'))
$$;

-- =====================================================================
-- Dispatch
-- =====================================================================
create or replace function public.create_route_run(
  p_run_date date, p_route uuid, p_vehicle uuid, p_driver uuid, p_order_ids uuid[],
  p_helper text, p_notes text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v uuid; v_no text; o record; n integer := 0; v_res jsonb; v_veh public.vehicles;
begin
  perform app.require_permission('deliveries.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'create_route_run');
  if v_done is not null then return v_done; end if;
  perform app.set_context(null, p_client_txn_id, null);

  select * into v_veh from public.vehicles where id = p_vehicle and is_active;
  if not found then raise exception 'Choose an active vehicle' using errcode = '22023'; end if;
  if not app.is_driver(p_driver) then raise exception 'The selected person does not have the Driver role' using errcode = '22023'; end if;
  if exists (select 1 from public.route_runs where vehicle_id = p_vehicle and status in ('planned','loaded','in_progress')) then
    raise exception 'Vehicle % already has an open run. Check it in first.', v_veh.registration_no using errcode = '22023';
  end if;
  if coalesce(array_length(p_order_ids, 1), 0) = 0 then raise exception 'Select at least one order' using errcode = '22023'; end if;

  v_no := app.next_document_number('RUN');
  insert into public.route_runs (run_no, run_date, route_id, vehicle_id, driver_id, helper_name, load_location_id, notes, created_by, client_txn_id)
  values (v_no, p_run_date, p_route, p_vehicle, p_driver, nullif(trim(p_helper), ''),
          (select id from public.locations where code = 'WH1'), nullif(trim(p_notes), ''), app.current_user_id(), p_client_txn_id)
  returning id into v;

  for o in
    select ord.*, c.route_sequence from public.orders ord join public.customers c on c.id = ord.customer_id
     where ord.id = any (p_order_ids) order by c.route_sequence nulls last, c.name for update of ord
  loop
    if o.status <> 'confirmed' then
      raise exception 'Order % is % — only confirmed orders can be dispatched', o.order_no, replace(o.status, '_', ' ') using errcode = '22023';
    end if;
    n := n + 1;
    insert into public.deliveries (delivery_no, run_id, order_id, customer_id, address_id, stop_sequence)
    values (app.next_document_number('DN'), v, o.id, o.customer_id, o.address_id, n);
    perform set_config('app.audit_action', 'assign', true);
    update public.orders set status = 'assigned' where id = o.id;
  end loop;
  perform set_config('app.audit_action', '', true);

  v_res := jsonb_build_object('run_id', v, 'run_no', v_no, 'stops', n);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Suggested load: everything on the run's orders
create or replace function public.run_suggested_load(p_run uuid)
returns table (product_id uuid, product_name text, qty numeric, available numeric)
language sql stable security definer set search_path = '' as $$
  select oi.product_id, p.name, sum(oi.qty - oi.delivered_qty),
         coalesce((select qty from public.inventory_balances b where b.location_id = r.load_location_id
                   and b.product_id = oi.product_id and b.stock_status = 'available'), 0)
    from public.route_runs r
    join public.deliveries d on d.run_id = r.id and d.status = 'pending'
    join public.order_items oi on oi.order_id = d.order_id
    join public.products p on p.id = oi.product_id
   where r.id = p_run and (app.has_permission('deliveries.manage') or app.has_permission('inventory.manage'))
   group by oi.product_id, p.name, p.sort_order, r.load_location_id
   order by p.sort_order, p.name
$$;

-- Warehouse loads the vehicle. p_lines: [{product_id, qty}]
create or replace function public.load_route_run(p_run uuid, p_lines jsonb, p_cash_float numeric, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; r public.route_runs; v_veh uuid; l jsonb; pr public.products; v_qty numeric; v_res jsonb; n integer := 0;
begin
  if not (app.has_permission('inventory.manage') or app.has_permission('deliveries.manage')) then
    raise exception 'Permission denied: inventory.manage is required' using errcode = '42501';
  end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'load_route_run');
  if v_done is not null then return v_done; end if;
  select * into r from public.route_runs where id = p_run for update;
  if r.status <> 'planned' then raise exception 'Run % is already %', r.run_no, replace(r.status, '_', ' ') using errcode = '22023'; end if;
  perform app.set_context(null, p_client_txn_id, 'load_out');
  v_veh := app.vehicle_location(p_run);

  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    v_qty := app.jnum(l, 'qty');
    continue when coalesce(v_qty, 0) <= 0;
    select * into pr from public.products where id = app.juuid(l, 'product_id');
    perform app.stock_move('load_out', pr.id, v_qty, r.load_location_id, v_veh, 'route_run', p_run);
    if pr.is_returnable then
      perform app.bottle_move('load_out', app.own_company_id(), pr.bottle_type_id, v_qty::integer,
        'location', r.load_location_id, 'full', 'location', v_veh, 'full', 'route_run', p_run);
    end if;
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Load at least one product' using errcode = '22023'; end if;

  if coalesce(p_cash_float, 0) > 0 then
    perform app.post_event('driver.cash_float', jsonb_build_object('amount', p_cash_float), app.today(),
      'Cash float for ' || r.run_no, 'route_run', p_run, v_veh, 'driver', r.driver_id);
  end if;

  update public.route_runs set status = 'loaded', cash_float = coalesce(p_cash_float, 0), loaded_at = now(), loaded_by = app.current_user_id()
   where id = p_run;
  perform set_config('app.audit_action', 'load_out', true);
  update public.orders set status = 'loaded' where id in (select order_id from public.deliveries where run_id = p_run and status = 'pending');
  perform set_config('app.audit_action', '', true);

  v_res := jsonb_build_object('ok', true, 'run_no', r.run_no);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Driver confirms what was loaded and starts the run
create or replace function public.driver_start_run(p_run uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.route_runs;
begin
  r := app.require_run_access(p_run);
  if r.status = 'in_progress' then return jsonb_build_object('ok', true); end if;
  if r.status <> 'loaded' then raise exception 'The vehicle has not been loaded yet' using errcode = '22023'; end if;
  perform app.set_context(null, null, 'start_run');
  update public.route_runs set status = 'in_progress', driver_confirmed_at = now() where id = p_run;
  update public.orders set status = 'out_for_delivery' where id in (select order_id from public.deliveries where run_id = p_run and status = 'pending');
  perform set_config('app.audit_action', '', true);
  return jsonb_build_object('ok', true);
end $$;

-- Cancel an order (before it leaves on a vehicle)
create or replace function public.cancel_order(p_order uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.orders;
begin
  perform app.require_permission('orders.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required to cancel an order' using errcode = '22023'; end if;
  select * into o from public.orders where id = p_order for update;
  if o.status not in ('draft','on_hold','confirmed','assigned') then
    raise exception 'Order % is % and can no longer be cancelled', o.order_no, replace(o.status, '_', ' ') using errcode = '22023';
  end if;
  perform app.set_context(trim(p_reason), null, 'cancel');
  update public.deliveries set status = 'cancelled', failure_reason = 'Order cancelled: ' || trim(p_reason)
   where order_id = p_order and status = 'pending';
  update public.orders set status = 'cancelled', cancel_reason = trim(p_reason) where id = p_order;
end $$;

-- =====================================================================
-- Driver app: read everything needed for a run (also cached offline)
-- =====================================================================
create or replace function public.driver_my_runs()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'run_no', r.run_no, 'run_date', r.run_date, 'status', r.status,
           'route', rt.name, 'vehicle', v.registration_no,
           'stops', (select count(*) from public.deliveries d where d.run_id = r.id and d.status <> 'cancelled'),
           'done', (select count(*) from public.deliveries d where d.run_id = r.id and d.status in ('delivered','partially_delivered','failed')))
         order by r.run_date, r.run_no), '[]'::jsonb)
    from public.route_runs r
    join public.vehicles v on v.id = r.vehicle_id
    left join public.routes rt on rt.id = r.route_id
   where r.driver_id = app.current_user_id()
     and (r.status in ('planned','loaded','in_progress') or (r.status in ('checked_in','closed') and r.run_date >= app.today() - 1))
$$;

create or replace function public.driver_get_run(p_run uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.route_runs; v_res jsonb; v_veh uuid; v_own uuid := app.own_company_id();
begin
  r := app.require_run_access(p_run);
  v_veh := app.vehicle_location(p_run);
  select jsonb_build_object(
    'run', jsonb_build_object('id', r.id, 'run_no', r.run_no, 'run_date', r.run_date, 'status', r.status, 'cash_float', r.cash_float,
             'route', (select name from public.routes where id = r.route_id),
             'vehicle', (select registration_no from public.vehicles where id = r.vehicle_id)),
    'company', jsonb_build_object('name', app.get_setting('company.name') #>> '{}',
             'vat_no', app.get_setting('company.vat_registration_no') #>> '{}',
             'receipt_footer', app.get_setting('receipts.footer_text') #>> '{}'),
    'own_company_id', v_own,
    'companies', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'name', name, 'is_own', is_own,
                    'policy', acceptance_policy) order by is_own desc, name), '[]') from public.bottle_companies where is_active),
    'bottle_types', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'name', name) order by size_litres desc), '[]')
                       from public.bottle_types where is_active),
    'products', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'sku', sku, 'name', name, 'barcode', barcode,
                    'is_returnable', is_returnable, 'bottle_type_id', bottle_type_id) order by sort_order, name), '[]')
                   from public.products where is_active),
    'vehicle_stock', (select coalesce(jsonb_agg(jsonb_build_object('product_id', product_id, 'qty', qty)), '[]')
                        from public.inventory_balances where location_id = v_veh and qty > 0),
    'vehicle_bottles', (select coalesce(jsonb_agg(jsonb_build_object('company_id', company_id, 'bottle_type_id', bottle_type_id,
                          'fill_state', fill_state, 'qty', qty)), '[]')
                          from public.bottle_balances where holder_type = 'location' and holder_id = v_veh and qty <> 0),
    'cash_collected', (select coalesce(sum(amount), 0) from public.payments where run_id = r.id and method = 'cash' and status = 'received'),
    'bottle_values', (select coalesce(jsonb_agg(jsonb_build_object('bottle_type_id', bt.id, 'company_id', bc.id,
                        'deposit', coalesce((app.bottle_value(bt.id, bc.id)).deposit_amount, 0),
                        'external_charge', coalesce((app.bottle_value(bt.id, bc.id)).external_charge, 0))), '[]')
                        from public.bottle_types bt cross join public.bottle_companies bc where bt.is_active and bc.is_active),
    'settings', jsonb_build_object(
        'external_policy_default', app.get_setting('bottles.external_policy_default') #>> '{}',
        'require_confirmation', coalesce((app.get_setting('deliveries.require_confirmation') #>> '{}')::boolean, false)),
    'stops', (select coalesce(jsonb_agg(stop order by (stop ->> 'stop_sequence')::integer), '[]') from (
       select jsonb_build_object(
         'delivery_id', d.id, 'delivery_no', d.delivery_no, 'stop_sequence', d.stop_sequence, 'status', d.status,
         'failure_reason', d.failure_reason, 'summary', d.summary, 'invoice_id', d.invoice_id,
         'order', jsonb_build_object('id', o.id, 'order_no', o.order_no, 'notes', o.notes, 'time_window', o.time_window,
             'expected_ola_returns', o.expected_ola_returns, 'delivery_charge', o.delivery_charge, 'total', o.total,
             'items', (select coalesce(jsonb_agg(jsonb_build_object('product_id', oi.product_id, 'qty', oi.qty - oi.delivered_qty,
                         'unit_price', oi.unit_price, 'discount', oi.discount) order by oi.line_no), '[]')
                         from public.order_items oi where oi.order_id = o.id)),
         'customer', jsonb_build_object('id', c.id, 'customer_no', c.customer_no, 'name', c.name, 'company_name', c.company_name,
             'phone', c.phone, 'phone2', c.phone2, 'bottle_model', c.bottle_model, 'allowed_bottles', c.allowed_bottles,
             'ola_bottles', app.customer_ola_bottles(c.id), 'outstanding', app.customer_outstanding(c.id),
             'credit_limit', c.credit_limit, 'external_policy', c.external_policy, 'payment_terms_days', c.payment_terms_days,
             'deposits_held', (select coalesce(jsonb_object_agg(bottle_type_id, qty_held), '{}') from public.customer_deposit_balances where customer_id = c.id),
             'prices_include_tax', (select prices_include_tax from public.price_lists where id = c.price_list_id),
             'prices', (select coalesce(jsonb_object_agg(p.id, app.unit_price(p.id, c.price_list_id)), '{}')
                          from public.products p
                         where p.is_active and exists (select 1 from public.price_list_items pli
                               where pli.product_id = p.id and pli.price_list_id = c.price_list_id and pli.effective_from <= app.today()))),
         'address', (select jsonb_build_object('address_line', a.address_line, 'city', a.city, 'gps_lat', a.gps_lat, 'gps_lng', a.gps_lng,
             'delivery_instructions', a.delivery_instructions) from public.customer_addresses a where a.id = d.address_id)
       ) as stop
         from public.deliveries d
         join public.orders o on o.id = d.order_id
         join public.customers c on c.id = d.customer_id
        where d.run_id = r.id and d.status <> 'cancelled') s)
  ) into v_res;
  return v_res;
end $$;

-- =====================================================================
-- Complete a delivery (the heart of Phase 1A)
-- p: {
--   lines: [{product_id, qty}],                 -- delivered quantities
--   issued_codes: [code],                       -- optional: scanned full OLA bottles handed over
--   ola_returned_codes: [code],                 -- scanned empty OLA bottles collected
--   ola_returned_counts: [{bottle_type_id, qty}],  -- unscanned empty OLA bottles collected
--   external: [{company_id, bottle_type_id, code, new_tag, qty}],
--             code    = an existing EXT-… tag already on the bottle
--             new_tag = a fresh EXT-… label being applied now
--             neither = count mode (qty bottles)
--   payment: {method, amount, reference, tendered},
--   confirmation: {method, signature_data, photo_path, otp_verified, recipient_name},
--   gps: {lat, lng}, notes, completed_at
-- }
-- =====================================================================
create or replace function public.complete_delivery(p_delivery uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; d public.deliveries; r public.route_runs; o public.orders; c public.customers; pr public.products;
  v_veh uuid; v_own uuid := app.own_company_id(); v_today date := app.today();
  l jsonb; v_qty numeric; v_price numeric; v_disc numeric; v_rate numeric; calc record; oi public.order_items;
  v_lines jsonb := '[]'; v_ln integer := 0; v_net numeric := 0; v_tax numeric := 0; v_total numeric := 0;
  v_cogs numeric := 0; v_deposit numeric := 0; v_refund numeric := 0; v_charge numeric := 0;
  v_issued jsonb := '{}'; v_returned jsonb := '{}'; v_ext_summary jsonb := '[]';
  v_code text; b public.bottles; v_bid uuid; v_left integer; v_type uuid; v_policy text; v_company public.bottle_companies;
  v_ext_qty integer; v_gps_lat numeric := app.jnum(p -> 'gps', 'lat'); v_gps_lng numeric := app.jnum(p -> 'gps', 'lng');
  v_held integer; v_target integer; v_delta integer; bv public.bottle_values; bt record;
  v_inv uuid; v_inv_no text; v_je uuid; v_pay uuid; v_pay_amount numeric := coalesce(app.jnum(p -> 'payment', 'amount'), 0);
  v_status text; v_res jsonb; v_all_done boolean; v_balance integer; v_credit_used numeric;
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

  -- 1. Products delivered -------------------------------------------------
  for l in select * from jsonb_array_elements(coalesce(p -> 'lines', '[]')) loop
    v_qty := app.jnum(l, 'qty');
    continue when coalesce(v_qty, 0) <= 0;
    if v_qty <> trunc(v_qty) then raise exception 'Quantities must be whole numbers' using errcode = '22023'; end if;
    select * into pr from public.products where id = app.juuid(l, 'product_id');
    if not found then raise exception 'Unknown product' using errcode = 'P0002'; end if;

    select * into oi from public.order_items where order_id = o.id and product_id = pr.id order by line_no limit 1;
    if oi.id is not null then
      v_price := oi.unit_price;
      v_disc := case when oi.qty > 0 then round(oi.discount * least(v_qty, oi.qty) / oi.qty, 2) else 0 end;
      update public.order_items set delivered_qty = delivered_qty + v_qty where id = oi.id;
    else
      v_price := app.unit_price(pr.id, o.price_list_id, v_today);
      v_disc := 0;
    end if;
    v_rate := app.tax_rate(pr.tax_code, v_today);
    select * into calc from app.calc_line(v_qty, v_price, v_disc, v_rate, o.prices_include_tax);

    perform app.stock_move('sale', pr.id, v_qty, v_veh, null, 'delivery', d.id);
    v_cogs := v_cogs + v_qty * pr.cost_price;

    v_ln := v_ln + 1;
    v_lines := v_lines || jsonb_build_object('line_type', 'product', 'product_id', pr.id, 'description', pr.name, 'qty', v_qty,
      'unit_price', v_price, 'discount', v_disc, 'tax_rate', v_rate, 'net', calc.net, 'tax', calc.tax, 'total', calc.total);
    v_net := v_net + calc.net; v_tax := v_tax + calc.tax; v_total := v_total + calc.total;

    if pr.is_returnable then
      v_left := v_qty::integer;
      -- scanned full bottles of this type first
      for v_code in select jsonb_array_elements_text(coalesce(p -> 'issued_codes', '[]')) loop
        exit when v_left = 0;
        b := app.bottle_by_code(v_code);
        continue when b.id is null or b.bottle_type_id <> pr.bottle_type_id or b.company_id <> v_own
              or (b.holder_type = 'customer' and b.holder_id = c.id);
        perform app.bottle_move('deliver', null, null, 1, 'location', v_veh, 'full', 'customer', c.id, 'full',
          'delivery', d.id, b.id, null, v_gps_lat, v_gps_lng, r.id);
        v_left := v_left - 1;
      end loop;
      if v_left > 0 then
        perform app.bottle_move('deliver', v_own, pr.bottle_type_id, v_left, 'location', v_veh, 'full', 'customer', c.id, 'full',
          'delivery', d.id, null, null, v_gps_lat, v_gps_lng, r.id);
      end if;
      v_issued := jsonb_set(v_issued, array[pr.bottle_type_id::text],
                            to_jsonb(coalesce((v_issued ->> pr.bottle_type_id::text)::integer, 0) + v_qty::integer));
    end if;
  end loop;

  -- 2. OLA empties collected ---------------------------------------------
  --    A scanned label that is printed but not yet on a bottle is registered
  --    on the spot; an unknown label is counted and flagged. Never block.
  for v_code in select jsonb_array_elements_text(coalesce(p -> 'ola_returned_codes', '[]')) loop
    b := app.bottle_by_code(v_code);
    if b.id is null and upper(trim(v_code)) like 'EXT-%' then
      -- an external tag in the OLA list: hand it to the external-bottle step (company from the tag prefix)
      select id into v_bid from public.bottle_companies
       where code = split_part(upper(trim(v_code)), '-', 2) and not is_own;
      if v_bid is not null then
        p := jsonb_set(p, '{external}', coalesce(p -> 'external', '[]') || jsonb_build_array(jsonb_build_object(
               'company_id', v_bid, 'code', upper(trim(v_code)))));
        continue;
      end if;
    end if;
    if b.id is null then
      if exists (select 1 from public.identifiers where value = upper(trim(v_code)) and status = 'unassigned' and entity_type = 'bottle') then
        v_bid := app.register_bottle(v_code, v_own, coalesce(app.juuid(p, 'default_bottle_type_id'),
                   (select id from public.bottle_types where is_active order by size_litres desc limit 1)), 'customer', c.id, 'full');
        select * into b from public.bottles where id = v_bid;
      else
        v_type := coalesce(app.juuid(p, 'default_bottle_type_id'), (select id from public.bottle_types where is_active order by size_litres desc limit 1));
        perform app.bottle_move('collect', v_own, v_type, 1, 'customer', c.id, 'full', 'location', v_veh, 'empty',
          'delivery', d.id, null, 'Unknown label ' || upper(trim(v_code)), v_gps_lat, v_gps_lng, r.id);
        perform app.raise_exception_record('bottle_location', format('Unknown label %s scanned at %s — counted as an OLA bottle', upper(trim(v_code)), c.name),
          'warning', r.id, null, c.id, null, v_own, v_type);
        v_returned := jsonb_set(v_returned, array[v_type::text], to_jsonb(coalesce((v_returned ->> v_type::text)::integer, 0) + 1));
        continue;
      end if;
    end if;
    if b.company_id <> v_own then
      -- an external tag scanned in the OLA list: treat it as an external bottle
      p := jsonb_set(p, '{external}', coalesce(p -> 'external', '[]') || jsonb_build_array(jsonb_build_object(
             'company_id', b.company_id, 'bottle_type_id', b.bottle_type_id, 'code', b.code)));
      continue;
    end if;
    perform app.bottle_move('collect', null, null, 1, 'customer', c.id, 'full', 'location', v_veh, 'empty',
      'delivery', d.id, b.id, null, v_gps_lat, v_gps_lng, r.id);
    v_returned := jsonb_set(v_returned, array[b.bottle_type_id::text],
                            to_jsonb(coalesce((v_returned ->> b.bottle_type_id::text)::integer, 0) + 1));
  end loop;
  for l in select * from jsonb_array_elements(coalesce(p -> 'ola_returned_counts', '[]')) loop
    v_qty := app.jint(l, 'qty');
    continue when coalesce(v_qty, 0) <= 0;
    perform app.bottle_move('collect', v_own, app.juuid(l, 'bottle_type_id'), v_qty::integer, 'customer', c.id, 'full',
      'location', v_veh, 'empty', 'delivery', d.id, null, null, v_gps_lat, v_gps_lng, r.id);
    v_returned := jsonb_set(v_returned, array[app.jtext(l, 'bottle_type_id')],
                            to_jsonb(coalesce((v_returned ->> app.jtext(l, 'bottle_type_id'))::integer, 0) + v_qty::integer));
  end loop;

  -- 3. External bottles collected -----------------------------------------
  for l in select * from jsonb_array_elements(coalesce(p -> 'external', '[]')) loop
    select * into v_company from public.bottle_companies where id = app.juuid(l, 'company_id');
    if not found or v_company.is_own then raise exception 'Choose the bottle''s company' using errcode = '22023'; end if;
    v_type := coalesce(app.juuid(l, 'bottle_type_id'), app.juuid(p, 'default_bottle_type_id'),
                       (select id from public.bottle_types where is_active order by size_litres desc limit 1));
    v_policy := app.external_policy(c.id, v_company.id);
    if v_policy = 'refuse' then
      raise exception '% bottles are not accepted from this customer', v_company.name using errcode = '22023';
    end if;

    v_code := coalesce(app.jtext(l, 'code'), app.jtext(l, 'new_tag'));
    if v_code is not null then
      b := app.bottle_by_code(v_code);
      if b.id is not null then
        v_type := b.bottle_type_id;
        perform app.bottle_move('external_intake', null, null, 1, b.holder_type, b.holder_id, b.fill_state, 'location', v_veh, 'empty',
          'delivery', d.id, b.id, null, v_gps_lat, v_gps_lng, r.id);
      elsif exists (select 1 from public.identifiers where value = upper(trim(v_code)) and status = 'unassigned') then
        v_bid := app.register_bottle(v_code, v_company.id, v_type, 'outside', app.outside_id(), 'empty');
        perform app.bottle_move('external_intake', null, null, 1, 'outside', app.outside_id(), 'empty', 'location', v_veh, 'empty',
          'delivery', d.id, v_bid, null, v_gps_lat, v_gps_lng, r.id);
      else
        perform app.bottle_move('external_intake', v_company.id, v_type, 1, 'outside', app.outside_id(), 'empty',
          'location', v_veh, 'empty', 'delivery', d.id, null, 'Unknown label ' || upper(trim(v_code)), v_gps_lat, v_gps_lng, r.id);
        perform app.raise_exception_record('bottle_location', format('Unknown label %s scanned at %s — counted as a %s bottle',
          upper(trim(v_code)), c.name, v_company.name), 'warning', r.id, null, c.id, null, v_company.id, v_type);
      end if;
      v_ext_qty := 1;
    else
      v_ext_qty := coalesce(app.jint(l, 'qty'), 1);
      if v_ext_qty <= 0 then continue; end if;
      perform app.bottle_move('external_intake', v_company.id, v_type, v_ext_qty, 'outside', app.outside_id(), 'empty',
        'location', v_veh, 'empty', 'delivery', d.id, null, null, v_gps_lat, v_gps_lng, r.id);
    end if;

    -- the customer's OLA bottle that this external bottle replaces is gone
    if v_policy in ('accept_one_for_one','accept_with_charge') then
      perform app.bottle_move('adjust', v_own, v_type, v_ext_qty, 'customer', c.id, 'full', 'outside', app.outside_id(), 'empty',
        'delivery', d.id, null, format('Exchanged for %s %s bottle(s)', v_ext_qty, v_company.name), v_gps_lat, v_gps_lng, r.id);
      v_returned := jsonb_set(v_returned, array[v_type::text],
                              to_jsonb(coalesce((v_returned ->> v_type::text)::integer, 0) + v_ext_qty));
    end if;
    if v_policy = 'accept_with_charge' then
      bv := app.bottle_value(v_type, v_company.id, v_today);
      if coalesce(bv.external_charge, 0) > 0 then
        v_ln := v_ln + 1;
        v_lines := v_lines || jsonb_build_object('line_type', 'bottle_charge', 'bottle_type_id', v_type,
          'description', v_company.name || ' bottle charge', 'qty', v_ext_qty, 'unit_price', bv.external_charge, 'discount', 0,
          'tax_rate', 0, 'net', v_ext_qty * bv.external_charge, 'tax', 0, 'total', v_ext_qty * bv.external_charge);
        v_charge := v_charge + v_ext_qty * bv.external_charge;
      end if;
    end if;
    v_ext_summary := v_ext_summary || jsonb_build_object('company', v_company.name, 'company_id', v_company.id, 'qty', v_ext_qty,
                                                         'policy', v_policy);
  end loop;

  -- 4. Deposits and bottle limits -----------------------------------------
  for bt in select id, name from public.bottle_types loop
    v_balance := app.customer_ola_bottles(c.id, bt.id);
    if c.bottle_model = 'deposit' then
      select coalesce(sum(qty_held), 0) into v_held from public.customer_deposit_balances
       where customer_id = c.id and bottle_type_id = bt.id;
      v_target := greatest(v_balance, 0);
      v_delta := v_target - v_held;
      continue when v_delta = 0;
      bv := app.bottle_value(bt.id, v_own, v_today);
      continue when coalesce(bv.deposit_amount, 0) = 0;
      v_ln := v_ln + 1;
      if v_delta > 0 then
        v_lines := v_lines || jsonb_build_object('line_type', 'deposit', 'bottle_type_id', bt.id, 'description', 'Bottle deposit ' || bt.name,
          'qty', v_delta, 'unit_price', bv.deposit_amount, 'discount', 0, 'tax_rate', 0,
          'net', v_delta * bv.deposit_amount, 'tax', 0, 'total', v_delta * bv.deposit_amount);
        v_deposit := v_deposit + v_delta * bv.deposit_amount;
        insert into public.deposit_transactions (customer_id, bottle_type_id, txn_type, qty, amount, reference_type, reference_id, created_by)
        values (c.id, bt.id, 'collected', v_delta, v_delta * bv.deposit_amount, 'delivery', d.id, app.current_user_id());
      else
        v_lines := v_lines || jsonb_build_object('line_type', 'deposit_refund', 'bottle_type_id', bt.id, 'description', 'Deposit refund ' || bt.name,
          'qty', -v_delta, 'unit_price', -bv.deposit_amount, 'discount', 0, 'tax_rate', 0,
          'net', v_delta * bv.deposit_amount, 'tax', 0, 'total', v_delta * bv.deposit_amount);
        v_refund := v_refund - v_delta * bv.deposit_amount;
        insert into public.deposit_transactions (customer_id, bottle_type_id, txn_type, qty, amount, reference_type, reference_id, created_by)
        values (c.id, bt.id, 'refunded', -v_delta, -v_delta * bv.deposit_amount, 'delivery', d.id, app.current_user_id());
      end if;
    elsif c.bottle_model = 'loan' and v_balance > c.allowed_bottles and (v_issued ? bt.id::text) then
      perform app.raise_exception_record('over_bottle_limit',
        format('%s now holds %s %s bottles (limit %s)', c.name, v_balance, bt.name, c.allowed_bottles),
        'info', r.id, null, c.id, null, v_own, bt.id, null, c.allowed_bottles, v_balance);
    end if;
  end loop;

  -- 5. Delivery charge ------------------------------------------------------
  if o.delivery_charge > 0 and not exists (select 1 from public.invoices where order_id = o.id) then
    v_ln := v_ln + 1;
    v_lines := v_lines || jsonb_build_object('line_type', 'delivery_charge', 'description', 'Delivery charge', 'qty', 1,
      'unit_price', o.delivery_charge, 'discount', 0, 'tax_rate', 0, 'net', o.delivery_charge, 'tax', 0, 'total', o.delivery_charge);
  end if;

  -- 6. Invoice + journal ----------------------------------------------------
  if jsonb_array_length(v_lines) > 0 then
    v_inv := gen_random_uuid();
    v_inv_no := app.next_document_number('INV');
    v_total := v_total + v_deposit - v_refund + v_charge +
               case when o.delivery_charge > 0 and v_lines @> '[{"line_type":"delivery_charge"}]' then o.delivery_charge else 0 end;
    insert into public.invoices (id, invoice_no, customer_id, order_id, delivery_id, run_id, location_id, invoice_date, due_date,
      is_tax_invoice, subtotal_net, tax_total, deposit_net, other_charges, total, status, created_by, client_txn_id)
    values (v_inv, v_inv_no, c.id, o.id, d.id, r.id, v_veh, v_today, v_today + c.payment_terms_days, c.vat_no is not null,
      v_net, v_tax, v_deposit - v_refund, v_charge + case when v_lines @> '[{"line_type":"delivery_charge"}]' then o.delivery_charge else 0 end,
      v_total, case when v_total <= 0 then 'credit' else 'open' end, app.current_user_id(), p_client_txn_id);
    insert into public.invoice_lines (invoice_id, line_no, line_type, product_id, bottle_type_id, description, qty, unit_price,
      discount, tax_rate, net, tax, total)
    select v_inv, ord, x ->> 'line_type', nullif(x ->> 'product_id', '')::uuid, nullif(x ->> 'bottle_type_id', '')::uuid,
           x ->> 'description', (x ->> 'qty')::numeric, (x ->> 'unit_price')::numeric, (x ->> 'discount')::numeric,
           (x ->> 'tax_rate')::numeric, (x ->> 'net')::numeric, (x ->> 'tax')::numeric, (x ->> 'total')::numeric
      from jsonb_array_elements(v_lines) with ordinality as t(x, ord);

    v_je := app.post_event('invoice.issued', jsonb_build_object(
        'ar_debit', greatest(v_total, 0), 'ar_credit', greatest(-v_total, 0),
        'net', v_net, 'vat', v_tax, 'delivery', case when v_lines @> '[{"line_type":"delivery_charge"}]' then o.delivery_charge else 0 end,
        'deposit', v_deposit, 'deposit_refund', v_refund, 'bottle_charge', v_charge),
      v_today, format('Invoice %s — %s', v_inv_no, c.name), 'invoice', v_inv, v_veh, 'customer', c.id);
    update public.invoices set journal_entry_id = v_je where id = v_inv;

    if v_cogs > 0 then
      perform app.post_event('cogs.sale', jsonb_build_object('value', v_cogs), v_today,
        format('Cost of goods — %s', v_inv_no), 'invoice', v_inv, v_veh);
    end if;

    -- apply any credit the customer already has on account
    for v_pay in select id from public.payments where customer_id = c.id and status = 'received' and unallocated > 0 order by received_at loop
      perform app.allocate_payment(v_pay, v_inv);
    end loop;
    perform app.refresh_invoice_status(v_inv);
  end if;

  -- 7. Payment collected ------------------------------------------------------
  if v_pay_amount > 0 then
    v_pay := app.create_payment(c.id, coalesce(app.jtext(p -> 'payment', 'method'), 'cash'), v_pay_amount,
      app.jtext(p -> 'payment', 'reference'), r.id, d.id, v_inv, null, null);
  end if;

  -- 8. Order + delivery status ------------------------------------------------
  select bool_and(delivered_qty >= qty) into v_all_done from public.order_items where order_id = o.id;
  v_status := case when v_all_done then 'delivered'
                   when exists (select 1 from public.order_items where order_id = o.id and delivered_qty > 0) then 'partially_delivered'
                   else 'delivered' end;   -- bottle-collection-only stops count as delivered
  update public.orders set status = v_status where id = o.id;

  v_res := jsonb_build_object(
    'delivery_id', d.id, 'delivery_no', d.delivery_no, 'invoice_id', v_inv, 'invoice_no', v_inv_no,
    'customer', jsonb_build_object('name', c.name, 'customer_no', c.customer_no),
    'lines', v_lines, 'subtotal_net', v_net, 'tax_total', v_tax, 'total', coalesce(v_total, 0),
    'paid', v_pay_amount, 'method', app.jtext(p -> 'payment', 'method'),
    'tendered', app.jnum(p -> 'payment', 'tendered'),
    'change', greatest(coalesce(app.jnum(p -> 'payment', 'tendered'), v_pay_amount) - v_pay_amount, 0),
    'outstanding', app.customer_outstanding(c.id),
    'bottles', jsonb_build_object('issued', v_issued, 'returned', v_returned, 'external', v_ext_summary,
                                  'balance', app.customer_ola_bottles(c.id)));

  update public.deliveries set
    status = v_status,
    completed_at = coalesce((app.jtext(p, 'completed_at'))::timestamptz, now()),
    synced_at = now(),
    gps_lat = v_gps_lat, gps_lng = v_gps_lng,
    confirmation_method = coalesce(app.jtext(p -> 'confirmation', 'method'), 'none'),
    recipient_name = app.jtext(p -> 'confirmation', 'recipient_name'),
    signature_data = app.jtext(p -> 'confirmation', 'signature_data'),
    photo_path = app.jtext(p -> 'confirmation', 'photo_path'),
    otp_verified = app.jbool(p -> 'confirmation', 'otp_verified', false),
    invoice_id = v_inv, summary = v_res, notes = app.jtext(p, 'notes'), client_txn_id = p_client_txn_id
  where id = d.id;

  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- A stop that could not be delivered. Optionally re-books the order for another day.
create or replace function public.fail_delivery(p_delivery uuid, p_reason text, p_notes text, p_reschedule_date date,
  p_gps jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; d public.deliveries; r public.route_runs; v_res jsonb;
begin
  v_done := app.idempotency_begin(p_client_txn_id, 'fail_delivery');
  if v_done is not null then return v_done; end if;
  select * into d from public.deliveries where id = p_delivery for update;
  if not found then raise exception 'Delivery not found' using errcode = 'P0002'; end if;
  r := app.require_run_access(d.run_id);
  if d.status <> 'pending' then raise exception 'Delivery % is already %', d.delivery_no, d.status using errcode = '22023'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'Choose a reason' using errcode = '22023'; end if;
  perform app.set_context(trim(p_reason), p_client_txn_id, 'fail');

  update public.deliveries set status = 'failed', failure_reason = trim(p_reason), notes = nullif(trim(p_notes), ''),
         completed_at = now(), synced_at = now(), gps_lat = app.jnum(p_gps, 'lat'), gps_lng = app.jnum(p_gps, 'lng'),
         client_txn_id = p_client_txn_id
   where id = d.id;
  if p_reschedule_date is not null then
    perform set_config('app.audit_action', 'reschedule', true);
    update public.orders set status = 'confirmed', requested_date = p_reschedule_date where id = d.order_id;
  else
    update public.orders set status = 'failed' where id = d.order_id;
  end if;
  perform set_config('app.audit_action', '', true);
  v_res := jsonb_build_object('ok', true, 'rescheduled', p_reschedule_date);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- =====================================================================
-- Check-in: expected vs actual, with exceptions for every difference
-- p: { products: [{product_id, qty}],                       -- full units returned
--      bottles:  [{company_id, bottle_type_id, fill_state, qty}],  -- bottles counted (empties + external)
--      scanned_codes: [code],                                -- optional, tagged bottles verified one by one
--      cash_handed, notes }
-- =====================================================================
create or replace function public.checkin_route_run(p_run uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; r public.route_runs; v_veh uuid; v_wh uuid; v_ext uuid; v_own uuid := app.own_company_id();
  bal record; v_actual numeric; v_diff numeric; pr public.products; v_code text; b public.bottles; v_dest uuid;
  v_moved integer; v_exc integer := 0; v_cash_expected numeric; v_cash_handed numeric := coalesce(app.jnum(p, 'cash_handed'), 0);
  v_res jsonb; v_lines jsonb := '[]'; bser record; v_remaining integer;
begin
  if not (app.has_permission('inventory.manage') or app.has_permission('deliveries.manage')) then
    raise exception 'Permission denied: check-in is done by the warehouse (inventory.manage)' using errcode = '42501';
  end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'checkin_route_run');
  if v_done is not null then return v_done; end if;
  select * into r from public.route_runs where id = p_run for update;
  if r.status not in ('in_progress','loaded') then
    raise exception 'Run % cannot be checked in (status: %)', r.run_no, replace(r.status, '_', ' ') using errcode = '22023';
  end if;
  if exists (select 1 from public.deliveries where run_id = p_run and status = 'pending') then
    if r.status = 'in_progress' then
      raise exception 'Some stops are still pending. The driver must complete or fail every stop first.' using errcode = '22023';
    end if;
  end if;
  perform app.set_context(nullif(trim(app.jtext(p, 'notes')), ''), p_client_txn_id, 'check_in');
  v_veh := app.vehicle_location(p_run);
  v_wh := r.load_location_id;
  select id into v_ext from public.locations where location_type = 'external_holding' order by created_at limit 1;

  -- unstarted run: put pending orders back to confirmed
  update public.deliveries set status = 'cancelled', failure_reason = 'Run checked in before departure'
   where run_id = p_run and status = 'pending';
  update public.orders set status = 'confirmed'
   where id in (select order_id from public.deliveries where run_id = p_run and failure_reason = 'Run checked in before departure')
     and status in ('loaded','assigned','out_for_delivery');

  -- 1. Products ---------------------------------------------------------------
  for bal in select * from public.inventory_balances where location_id = v_veh and stock_status = 'available' and qty > 0 loop
    select coalesce(sum(app.jnum(x, 'qty')), 0) into v_actual
      from jsonb_array_elements(coalesce(p -> 'products', '[]')) x where app.juuid(x, 'product_id') = bal.product_id;
    select * into pr from public.products where id = bal.product_id;
    v_moved := least(v_actual, bal.qty)::integer;
    if v_moved > 0 then
      perform app.stock_move('check_in', pr.id, v_moved, v_veh, v_wh, 'route_run', p_run);
      if pr.is_returnable then
        perform app.bottle_move('check_in', v_own, pr.bottle_type_id, v_moved, 'location', v_veh, 'full', 'location', v_wh, 'full',
          'route_run', p_run, null, null, null, null, p_run);
      end if;
    end if;
    v_lines := v_lines || jsonb_build_object('item', pr.name, 'expected', bal.qty, 'actual', v_actual);
    if v_actual <> bal.qty then
      v_exc := v_exc + 1;
      perform app.raise_exception_record(case when v_actual < bal.qty then 'stock_shortage' else 'stock_surplus' end,
        format('%s: %s expected back, %s counted', pr.name, bal.qty::integer, v_actual::integer),
        case when v_actual < bal.qty then 'critical' else 'warning' end, p_run, v_veh, null, null, null, null, pr.id, bal.qty, v_actual);
    end if;
  end loop;

  -- 2. Scanned bottles (verified one by one) ----------------------------------
  for v_code in select jsonb_array_elements_text(coalesce(p -> 'scanned_codes', '[]')) loop
    b := app.bottle_by_code(v_code);
    continue when b.id is null;
    v_dest := case when b.company_id = v_own then v_wh else v_ext end;
    perform app.bottle_move(case when b.company_id = v_own then 'check_in' else 'to_external_holding' end, null, null, 1,
      'location', v_veh, 'empty', 'location', v_dest, 'empty', 'route_run', p_run, b.id, null, null, null, p_run);
  end loop;

  -- 3. Bottle counts (empties of all companies; full external bottles are not expected) ---
  for bal in
    select company_id, bottle_type_id, fill_state, qty from public.bottle_balances
     where holder_type = 'location' and holder_id = v_veh and not (company_id = v_own and fill_state = 'full') and qty <> 0
    union
    select app.juuid(x, 'company_id'), app.juuid(x, 'bottle_type_id'), coalesce(app.jtext(x, 'fill_state'), 'empty'), 0
      from jsonb_array_elements(coalesce(p -> 'bottles', '[]')) x
     where not exists (select 1 from public.bottle_balances bb where bb.holder_type = 'location' and bb.holder_id = v_veh
                         and bb.company_id = app.juuid(x, 'company_id') and bb.bottle_type_id = app.juuid(x, 'bottle_type_id')
                         and bb.fill_state = coalesce(app.jtext(x, 'fill_state'), 'empty'))
  loop
    -- expected = what is on the vehicle now (scanned bottles already moved) + scanned of this kind
    select coalesce(sum(app.jint(x, 'qty')), 0) into v_actual
      from jsonb_array_elements(coalesce(p -> 'bottles', '[]')) x
     where app.juuid(x, 'company_id') = bal.company_id and app.juuid(x, 'bottle_type_id') = bal.bottle_type_id
       and coalesce(app.jtext(x, 'fill_state'), 'empty') = bal.fill_state;
    -- counted totals include scanned bottles; subtract the ones already moved
    select v_actual - count(*) into v_actual from public.bottle_transactions bt
     where bt.reference_type = 'route_run' and bt.reference_id = p_run and bt.bottle_id is not null
       and bt.client_txn_id = p_client_txn_id and bt.company_id = bal.company_id and bt.bottle_type_id = bal.bottle_type_id;
    v_actual := greatest(v_actual, 0);
    v_dest := case when bal.company_id = v_own then v_wh else v_ext end;
    v_moved := least(v_actual, greatest(bal.qty, 0))::integer;

    if v_moved > 0 then
      v_remaining := v_moved;
      -- tagged bottles still on the vehicle go first, one by one
      for bser in select id from public.bottles where holder_type = 'location' and holder_id = v_veh and company_id = bal.company_id
                   and bottle_type_id = bal.bottle_type_id and fill_state = bal.fill_state order by last_movement_at limit v_remaining loop
        perform app.bottle_move(case when bal.company_id = v_own then 'check_in' else 'to_external_holding' end, null, null, 1,
          'location', v_veh, bal.fill_state, 'location', v_dest, 'empty', 'route_run', p_run, bser.id, null, null, null, p_run);
        v_remaining := v_remaining - 1;
      end loop;
      if v_remaining > 0 then
        perform app.bottle_move(case when bal.company_id = v_own then 'check_in' else 'to_external_holding' end,
          bal.company_id, bal.bottle_type_id, v_remaining, 'location', v_veh, bal.fill_state, 'location', v_dest, 'empty',
          'route_run', p_run, null, null, null, null, p_run);
      end if;
    end if;

    v_lines := v_lines || jsonb_build_object('item', (select name from public.bottle_companies where id = bal.company_id) || ' '
               || (select name from public.bottle_types where id = bal.bottle_type_id) || ' ' || bal.fill_state,
               'expected', bal.qty, 'actual', v_actual);
    if v_actual <> bal.qty then
      v_exc := v_exc + 1;
      if v_actual > bal.qty then
        -- extra bottles physically present: bring them into stock and flag
        perform app.bottle_move('found', bal.company_id, bal.bottle_type_id, (v_actual - greatest(bal.qty, 0))::integer,
          'outside', app.outside_id(), 'empty', 'location', v_dest, 'empty', 'route_run', p_run, null,
          'More bottles counted than recorded at check-in', null, null, p_run);
      end if;
      perform app.raise_exception_record(case when v_actual < bal.qty then 'bottle_shortage' else 'bottle_surplus' end,
        format('%s %s bottles (%s): %s expected, %s counted',
          (select name from public.bottle_companies where id = bal.company_id),
          (select name from public.bottle_types where id = bal.bottle_type_id), bal.fill_state, bal.qty, v_actual::integer),
        case when v_actual < bal.qty then 'critical' else 'warning' end,
        p_run, v_veh, null, null, bal.company_id, bal.bottle_type_id, null, bal.qty, v_actual);
    end if;
  end loop;

  -- 4. Cash -----------------------------------------------------------------------
  select r.cash_float + coalesce(sum(amount), 0) into v_cash_expected
    from public.payments where run_id = p_run and method = 'cash' and status = 'received';
  if v_cash_handed > 0 then
    perform app.post_event('driver.cash_handover', jsonb_build_object('amount', v_cash_handed), app.today(),
      'Cash handed in for ' || r.run_no, 'route_run', p_run, v_veh, 'driver', r.driver_id);
  end if;
  if v_cash_handed <> v_cash_expected then
    v_exc := v_exc + 1;
    perform app.raise_exception_record(case when v_cash_handed < v_cash_expected then 'cash_shortage' else 'cash_surplus' end,
      format('Cash: Rs. %s expected, Rs. %s handed in', to_char(v_cash_expected, 'FM999,999,990.00'), to_char(v_cash_handed, 'FM999,999,990.00')),
      case when v_cash_handed < v_cash_expected then 'critical' else 'warning' end, p_run, null, null, null, null, null, null,
      v_cash_expected, v_cash_handed);
  end if;

  update public.route_runs set status = case when v_exc = 0 then 'closed' else 'checked_in' end,
         cash_expected = v_cash_expected, cash_handed = v_cash_handed, checked_in_at = now(), checked_in_by = app.current_user_id(),
         closed_at = case when v_exc = 0 then now() end
   where id = p_run;

  v_res := jsonb_build_object('run_no', r.run_no, 'exceptions', v_exc, 'lines', v_lines,
                              'cash_expected', v_cash_expected, 'cash_handed', v_cash_handed,
                              'status', case when v_exc = 0 then 'closed' else 'checked_in' end);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- =====================================================================
-- Resolve an exception
--   found         — the missing items were found (moved to the warehouse / cash handed in)
--   charge_driver — the driver pays (bottles/cash remain the driver's debt)
--   write_off     — loss accepted and expensed (needs bottles.writeoff for bottles)
--   accepted      — information only, nothing moves
-- =====================================================================
create or replace function public.resolve_exception(p_id uuid, p_resolution text, p_note text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; e public.operation_exceptions; r public.route_runs; v_qty integer; v_amount numeric; v_own uuid := app.own_company_id();
  v_dest uuid; bv public.bottle_values; pr public.products; v_veh uuid;
begin
  perform app.require_permission('deliveries.reconcile');
  if nullif(trim(p_note), '') is null then raise exception 'Explain the resolution' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'resolve_exception');
  if v_done is not null then return v_done; end if;
  select * into e from public.operation_exceptions where id = p_id for update;
  if not found then raise exception 'Exception not found' using errcode = 'P0002'; end if;
  if e.status = 'resolved' then raise exception 'Already resolved' using errcode = '22023'; end if;
  perform app.set_context(trim(p_note), p_client_txn_id, 'resolve');
  if e.run_id is not null then select * into r from public.route_runs where id = e.run_id; v_veh := app.vehicle_location(e.run_id); end if;

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

  update public.operation_exceptions set status = 'resolved', resolution = p_resolution, resolution_note = trim(p_note),
         resolved_at = now(), resolved_by = app.current_user_id()
   where id = p_id;

  if e.run_id is not null and not exists (select 1 from public.operation_exceptions where run_id = e.run_id and status = 'open'
       and exception_type in ('bottle_shortage','bottle_surplus','stock_shortage','stock_surplus','cash_shortage','cash_surplus')) then
    update public.route_runs set status = 'closed', closed_at = now() where id = e.run_id and status = 'checked_in';
  end if;

  perform app.idempotency_finish(p_client_txn_id, jsonb_build_object('ok', true));
  return jsonb_build_object('ok', true);
end $$;

-- Receipt print / reprint (audited)
create or replace function public.record_receipt_print(p_invoice uuid, p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
declare i public.invoices; d public.deliveries;
begin
  select * into i from public.invoices where id = p_invoice for update;
  if not found then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if not (app.has_permission('payments.view') or app.has_permission('orders.view')) then
    select * into d from public.deliveries where id = i.delivery_id;
    perform app.require_run_access(d.run_id);
  end if;
  if i.print_count > 0 and nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required to reprint a receipt' using errcode = '22023';
  end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, case when i.print_count > 0 then 'reprint' else 'print' end);
  update public.invoices set print_count = print_count + 1 where id = p_invoice;
  perform set_config('app.audit_action', '', true);
  return i.print_count + 1;
end $$;

-- Everything a receipt needs (office or the run's driver)
create or replace function public.get_receipt(p_invoice uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare i public.invoices; d public.deliveries; v jsonb;
begin
  select * into i from public.invoices where id = p_invoice;
  if not found then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if not (app.has_permission('payments.view') or app.has_permission('orders.view') or app.has_permission('customers.view')) then
    select * into d from public.deliveries where id = i.delivery_id;
    perform app.require_run_access(d.run_id);
  end if;
  select jsonb_build_object(
    'invoice_no', i.invoice_no, 'invoice_date', i.invoice_date, 'created_at', i.created_at, 'is_tax_invoice', i.is_tax_invoice,
    'print_count', i.print_count, 'subtotal_net', i.subtotal_net, 'tax_total', i.tax_total, 'total', i.total,
    'amount_paid', i.amount_paid, 'balance', i.balance,
    'company', jsonb_build_object('name', app.get_setting('company.name') #>> '{}', 'vat_no', app.get_setting('company.vat_registration_no') #>> '{}',
                                  'footer', app.get_setting('receipts.footer_text') #>> '{}'),
    'customer', (select jsonb_build_object('name', name, 'customer_no', customer_no, 'vat_no', vat_no, 'phone', phone)
                   from public.customers where id = i.customer_id),
    'staff', (select full_name from public.profiles where id = i.created_by),
    'lines', (select jsonb_agg(jsonb_build_object('description', description, 'qty', qty, 'unit_price', unit_price, 'discount', discount,
                'total', total, 'line_type', line_type) order by line_no) from public.invoice_lines where invoice_id = i.id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', p.method, 'amount', pa.amount, 'payment_no', p.payment_no)), '[]')
                   from public.payment_allocations pa join public.payments p on p.id = pa.payment_id where pa.invoice_id = i.id),
    'summary', (select summary from public.deliveries where id = i.delivery_id),
    'outstanding', app.customer_outstanding(i.customer_id),
    'ola_bottles', app.customer_ola_bottles(i.customer_id)
  ) into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.route_runs enable row level security;
alter table public.deliveries enable row level security;
create policy route_runs_read on public.route_runs for select to authenticated
  using (app.has_permission('deliveries.view') or driver_id = app.current_user_id());
create policy deliveries_read on public.deliveries for select to authenticated
  using (app.has_permission('deliveries.view')
         or exists (select 1 from public.route_runs r where r.id = run_id and r.driver_id = app.current_user_id()));

-- >>> 20261002000013_phase1a_reference_data.sql
-- =====================================================================
-- OLA Water ERP — Phase 1A
-- 0013: reference data for Phase 1A + function privileges
-- (Prices, VAT rate and deposit amounts are NOT seeded — management sets
--  them in the ERP before the first order.)
-- =====================================================================

-- Accounts ---------------------------------------------------------------
insert into public.accounts (code, name, account_type, system_key, parent_id)
select '1140', 'Cheques in Hand', 'asset', 'cheques_in_hand', id from public.accounts where code = '1000';

-- Document types ----------------------------------------------------------
insert into public.document_types (code, name, padding) values ('ADJ', 'Stock adjustment', 6)
on conflict (code) do nothing;

-- Posting events ------------------------------------------------------------
insert into public.posting_event_types (code, module, description, amount_keys) values
  ('invoice.issued',       'sales',    'Delivery / sales invoice issued on account',
     array['ar_debit','ar_credit','net','vat','delivery','deposit','deposit_refund','bottle_charge']),
  ('cogs.sale',            'sales',    'Cost of goods sold',                         array['value']),
  ('payment.driver_cash',  'payments', 'Cash collected by a driver',                 array['amount']),
  ('payment.card',         'payments', 'Card or QR payment',                          array['amount']),
  ('payment.cheque',       'payments', 'Cheque received',                             array['amount']),
  ('driver.cash_float',    'delivery', 'Cash float given to a driver',                array['amount']),
  ('driver.bottle_charge', 'delivery', 'Missing bottles charged to the driver',       array['amount']),
  ('driver.stock_charge',  'delivery', 'Missing stock charged to the driver',         array['amount']),
  ('stock.opening',        'inventory','Opening stock at go-live',                    array['value']),
  ('stock.adjust_gain',    'inventory','Stock count gain',                            array['value']),
  ('stock.adjust_loss',    'inventory','Stock count loss',                            array['value']);

insert into public.posting_rules (event_type, line_no, side, account_key, amount_key, description) values
  ('invoice.issued', 1, 'debit',  'ar',                   'ar_debit',       'Receivable'),
  ('invoice.issued', 2, 'debit',  'bottle_deposits',      'deposit_refund', 'Deposit refunded'),
  ('invoice.issued', 3, 'credit', 'ar',                   'ar_credit',      'Credit to customer'),
  ('invoice.issued', 4, 'credit', 'sales',                'net',            'Sales'),
  ('invoice.issued', 5, 'credit', 'vat_output',           'vat',            'VAT output'),
  ('invoice.issued', 6, 'credit', 'delivery_income',      'delivery',       'Delivery charge'),
  ('invoice.issued', 7, 'credit', 'bottle_deposits',      'deposit',        'Bottle deposit held'),
  ('invoice.issued', 8, 'credit', 'bottle_charge_income', 'bottle_charge',  'Bottle charge'),
  ('cogs.sale',            1, 'debit',  'cogs',                 'value',  'Cost of goods sold'),
  ('cogs.sale',            2, 'credit', 'inv_finished',         'value',  'Finished goods issued'),
  ('payment.driver_cash',  1, 'debit',  'driver_cash',          'amount', 'Cash with driver'),
  ('payment.driver_cash',  2, 'credit', 'ar',                   'amount', 'Receivable settled'),
  ('payment.card',         1, 'debit',  'card_clearing',        'amount', 'Card / QR receipt'),
  ('payment.card',         2, 'credit', 'ar',                   'amount', 'Receivable settled'),
  ('payment.cheque',       1, 'debit',  'cheques_in_hand',      'amount', 'Cheque received'),
  ('payment.cheque',       2, 'credit', 'ar',                   'amount', 'Receivable settled'),
  ('driver.cash_float',    1, 'debit',  'driver_cash',          'amount', 'Float with driver'),
  ('driver.cash_float',    2, 'credit', 'cash',                 'amount', 'Float issued'),
  ('driver.bottle_charge', 1, 'debit',  'driver_cash',          'amount', 'Owed by driver'),
  ('driver.bottle_charge', 2, 'credit', 'bottle_charge_income', 'amount', 'Bottles charged'),
  ('driver.stock_charge',  1, 'debit',  'driver_cash',          'amount', 'Owed by driver'),
  ('driver.stock_charge',  2, 'credit', 'inv_finished',         'amount', 'Stock charged'),
  ('stock.opening',        1, 'debit',  'inv_finished',         'value',  'Opening stock'),
  ('stock.opening',        2, 'credit', 'opening_equity',       'value',  'Opening balance'),
  ('stock.adjust_gain',    1, 'debit',  'inv_finished',         'value',  'Stock gain'),
  ('stock.adjust_gain',    2, 'credit', 'inventory_adjustment', 'value',  'Stock gain'),
  ('stock.adjust_loss',    1, 'debit',  'inventory_adjustment', 'value',  'Stock loss'),
  ('stock.adjust_loss',    2, 'credit', 'inv_finished',         'value',  'Stock loss');

-- Settings ------------------------------------------------------------------------
insert into public.setting_definitions (key, module, label, description, value_type, choices, sort_order) values
  ('bottles.external_policy_default', 'Bottles', 'Other companies'' bottles (default)',
   'What happens when a customer hands in another company''s empty bottle. Can be overridden per company and per customer.',
   'choice', array['accept_one_for_one','accept_with_charge','accept_no_credit','refuse'], 19),
  ('deliveries.require_confirmation', 'Deliveries', 'Delivery confirmation required',
   'Driver must capture a signature, OTP or photo before completing a delivery', 'boolean', null, 60);
insert into public.system_settings (key, value, effective_from) values
  ('bottles.external_policy_default', '"accept_one_for_one"', date '2026-01-01'),
  ('deliveries.require_confirmation', 'false', date '2026-01-01');

-- Tax codes (rates are set by management) ------------------------------------------
insert into public.tax_codes (code, name) values ('VAT', 'Value Added Tax'), ('NONE', 'No tax / exempt');
insert into public.tax_rates (tax_code, rate_percent, effective_from) values ('NONE', 0, date '2026-01-01');

-- Bottle owners (OLA + external companies matching the tag series from Phase 0) -------
insert into public.bottle_companies (code, name, is_own) values
  ('OLA',  'OLA Water',     true),
  ('AQUA', 'Aqua Water',    false),
  ('XYZ',  'XYZ Water',     false),
  ('ABC',  'ABC Water',     false),
  ('UNK',  'Unknown brand', false);

insert into public.bottle_types (code, name, size_litres) values ('19L', '19 litre', 19);

-- Price lists ---------------------------------------------------------------------------
insert into public.price_lists (code, name, prices_include_tax) values
  ('RETAIL',        'Retail',               true),
  ('DEALER',        'Dealer',               true),
  ('DISTRIBUTOR',   'Distributor',          true),
  ('CORPORATE',     'Corporate',            true),
  ('SHOP_TRANSFER', 'Water shop transfer',  true);

-- Products (OLA's range; prices are entered in Products → Price lists) -----------------
insert into public.products (sku, name, size_label, unit, units_per_pack, is_returnable, bottle_type_id, tax_code, sort_order)
select v.sku, v.name, v.size_label, v.unit, v.per_pack, v.returnable, case when v.returnable then (select id from public.bottle_types where code = '19L') end, 'VAT', v.sort
  from (values
    ('OLA-19L',      'OLA 19L',               '19 L',   'bottle', 1,  true,  1),
    ('OLA-5L',       'OLA 5L',                '5 L',    'bottle', 1,  false, 2),
    ('OLA-1.5L',     'OLA 1.5L',              '1.5 L',  'bottle', 1,  false, 3),
    ('OLA-500ML',    'OLA 500ml',             '500 ml', 'bottle', 1,  false, 4),
    ('OLA-1.5L-12',  'OLA 1.5L — case of 12', '1.5 L',  'case',   12, false, 5),
    ('OLA-500ML-24', 'OLA 500ml — case of 24','500 ml', 'case',   24, false, 6)
  ) as v(sku, name, size_label, unit, per_pack, returnable, sort);

-- Customer type defaults (households pay a deposit; businesses borrow up to a limit) -----
insert into public.customer_type_defaults (customer_type, label, bottle_model, allowed_bottles, price_list_id, payment_terms_days)
select v.t, v.label, v.model, v.allowed, (select id from public.price_lists where code = v.pl), v.terms
  from (values
    ('household',   'Household',   'deposit', 0,  'RETAIL',        0),
    ('office',      'Office',      'loan',    10, 'CORPORATE',     30),
    ('hotel',       'Hotel',       'loan',    20, 'CORPORATE',     30),
    ('restaurant',  'Restaurant',  'loan',    10, 'CORPORATE',     14),
    ('shop',        'Shop',        'loan',    10, 'DEALER',        14),
    ('supermarket', 'Supermarket', 'loan',    20, 'DEALER',        30),
    ('institution', 'Institution', 'loan',    20, 'CORPORATE',     30),
    ('distributor', 'Distributor', 'loan',    50, 'DISTRIBUTOR',   30),
    ('water_shop',  'Water shop',  'loan',    50, 'SHOP_TRANSFER', 7),
    ('corporate',   'Corporate',   'loan',    20, 'CORPORATE',     30)
  ) as v(t, label, model, allowed, pl, terms);

-- Extra permission for the driver role so it can read its own receipts (RPC-checked) ---
-- (drivers use RPCs only; no table permissions are needed)

-- ---------------------------------------------------------------------------------------
-- Function privileges (re-applied after every migration that adds functions)
-- PostgreSQL grants EXECUTE to PUBLIC on new functions by default; remove that
-- globally and grant signed-in users explicitly.
-- ---------------------------------------------------------------------------------------
alter default privileges revoke execute on functions from public;
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app    from public, anon, authenticated;
grant execute on all functions in schema public to authenticated, service_role;
grant execute on function app.current_user_id()   to authenticated, service_role;
grant execute on function app.has_permission(text) to authenticated, service_role;
grant execute on function app.is_super_admin(uuid) to authenticated, service_role;
grant execute on function app.today()              to authenticated, service_role;
grant execute on function app.own_company_id()     to authenticated, service_role;
revoke execute on function public.log_failed_login(text, text, text, text) from authenticated;
revoke execute on function public.bootstrap_super_admin(text)              from authenticated;

grant usage on schema public to anon, authenticated, service_role;
grant select on all tables in schema public to authenticated, service_role;
grant usage, select on all sequences in schema public to service_role;
revoke all on all tables in schema public from anon;

-- >>> 20261002000014_read_models.sql
-- =====================================================================
-- OLA Water ERP — Phase 1A
-- 0014: read models for screens (dashboard, customer summary, bottles)
-- =====================================================================

create or replace function public.dashboard_summary()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_today date := app.today(); v_own uuid := app.own_company_id(); v jsonb;
begin
  perform app.require_permission('dashboard.view');
  select jsonb_build_object(
    'today', v_today,
    'sales_today', coalesce((select sum(subtotal_net + tax_total) from public.invoices where invoice_date = v_today and status <> 'void'), 0),
    'invoices_today', (select count(*) from public.invoices where invoice_date = v_today and status <> 'void'),
    'collected_today', coalesce((select sum(amount) from public.payments where (received_at at time zone 'Asia/Colombo')::date = v_today
                                   and status = 'received'), 0),
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
    'customer_outstanding', coalesce((select sum(total) from public.invoices where status <> 'void'), 0)
                            - coalesce((select sum(amount) from public.payments where status = 'received'), 0),
    'overdue', coalesce((select sum(balance) from public.invoices where status in ('open','partially_paid') and due_date < v_today), 0),
    'bottles', jsonb_build_object(
      'warehouse_full', coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
                         where b.holder_type = 'location' and l.location_type in ('warehouse','head_office') and b.company_id = v_own and b.fill_state = 'full'), 0),
      'warehouse_empty', coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
                         where b.holder_type = 'location' and l.location_type in ('warehouse','head_office') and b.company_id = v_own and b.fill_state = 'empty'), 0),
      'on_vehicles', coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
                         where b.holder_type = 'location' and l.location_type = 'vehicle' and b.company_id = v_own), 0),
      'with_customers', coalesce((select sum(qty) from public.bottle_balances where holder_type = 'customer' and company_id = v_own), 0),
      'external_held', coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
                         where b.holder_type = 'location' and l.location_type = 'external_holding' and b.company_id <> v_own), 0),
      'external_on_vehicles', coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
                         where b.holder_type = 'location' and l.location_type = 'vehicle' and b.company_id <> v_own), 0)),
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

create or replace function public.customer_summary(p_customer uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c public.customers; v jsonb;
begin
  perform app.require_permission('customers.view');
  select * into c from public.customers where id = p_customer;
  if not found then raise exception 'Customer not found' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'outstanding', app.customer_outstanding(c.id),
    'overdue', app.customer_overdue(c.id),
    'credit_available', case when c.credit_limit > 0 then c.credit_limit - app.customer_outstanding(c.id) end,
    'ola_bottles', app.customer_ola_bottles(c.id),
    'bottles_by_type', (select coalesce(jsonb_agg(jsonb_build_object('type', bt.name, 'qty', s.qty)), '[]') from (
        select bottle_type_id, sum(qty) qty from public.bottle_balances
         where holder_type = 'customer' and holder_id = c.id and company_id = app.own_company_id() group by bottle_type_id) s
        join public.bottle_types bt on bt.id = s.bottle_type_id),
    'deposits', (select coalesce(jsonb_agg(jsonb_build_object('type', bt.name, 'qty', d.qty_held, 'amount', d.amount_held)), '[]')
                   from public.customer_deposit_balances d join public.bottle_types bt on bt.id = d.bottle_type_id
                  where d.customer_id = c.id and d.qty_held <> 0),
    'last_delivery', (select max(completed_at) from public.deliveries where customer_id = c.id and status in ('delivered','partially_delivered')),
    'open_orders', (select count(*) from public.orders where customer_id = c.id and status in ('draft','on_hold','confirmed','assigned','loaded','out_for_delivery'))
  ) into v;
  return v;
end $$;

-- Where every bottle is: by owner company, type and kind of holder
create or replace function public.bottle_overview()
returns table (company_id uuid, company text, is_own boolean, bottle_type text, holder_kind text, fill_state text, qty bigint, value numeric)
language sql stable security definer set search_path = '' as $$
  select bc.id, bc.name, bc.is_own, bt.name,
         case b.holder_type when 'location' then l.location_type else b.holder_type end,
         b.fill_state, sum(b.qty),
         sum(b.qty) * coalesce((app.bottle_value(bt.id, bc.id)).replacement_value, 0)
    from public.bottle_balances b
    join public.bottle_companies bc on bc.id = b.company_id
    join public.bottle_types bt on bt.id = b.bottle_type_id
    left join public.locations l on b.holder_type = 'location' and l.id = b.holder_id
   where app.has_permission('bottles.view') and b.qty <> 0 and b.holder_type <> 'outside'
   group by bc.id, bc.name, bc.is_own, bt.id, bt.name, 5, b.fill_state
   order by bc.is_own desc, bc.name, bt.name, 5
$$;

-- External bottles: collected, returned, held — per company
create or replace function public.external_bottle_accounts()
returns table (company_id uuid, company text, code text, held bigint, on_vehicles bigint, tagged_held bigint,
               collected bigint, returned bigint, ola_received bigint, held_value numeric, alert_qty integer, last_handover date)
language sql stable security definer set search_path = '' as $$
  select bc.id, bc.name, bc.code,
    coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
               where b.company_id = bc.id and b.holder_type = 'location' and l.location_type = 'external_holding'), 0),
    coalesce((select sum(b.qty) from public.bottle_balances b join public.locations l on l.id = b.holder_id
               where b.company_id = bc.id and b.holder_type = 'location' and l.location_type = 'vehicle'), 0),
    (select count(*) from public.bottles bo join public.locations l on l.id = bo.holder_id
      where bo.company_id = bc.id and bo.holder_type = 'location' and l.location_type = 'external_holding'),
    coalesce((select sum(qty) from public.bottle_transactions where company_id = bc.id and txn_type = 'external_intake'), 0),
    coalesce((select sum(qty) from public.bottle_transactions where company_id = bc.id and txn_type = 'return_to_owner'), 0),
    coalesce((select sum(ola_received) from public.external_handovers where company_id = bc.id), 0),
    coalesce((select sum(b.qty * coalesce((app.bottle_value(b.bottle_type_id, bc.id)).replacement_value, 0))
                from public.bottle_balances b join public.locations l on l.id = b.holder_id
               where b.company_id = bc.id and b.holder_type = 'location' and l.location_type in ('external_holding','vehicle')), 0),
    coalesce(bc.holding_alert_qty, (app.get_setting('bottles.external_holding_alert_qty') #>> '{}')::integer),
    (select max(handover_date) from public.external_handovers where company_id = bc.id)
  from public.bottle_companies bc
  where not bc.is_own and app.has_permission('bottles.view')
  order by bc.name
$$;

-- Bottle lookup by scanned code (with its history)
create or replace function public.bottle_details(p_code text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare b public.bottles; v jsonb;
begin
  perform app.require_permission('bottles.view');
  b := app.bottle_by_code(p_code);
  if b.id is null then
    return (select jsonb_build_object('found', false, 'identifier', to_jsonb(i)) from public.identifiers i where i.value = upper(trim(p_code)));
  end if;
  select jsonb_build_object('found', true,
    'bottle', jsonb_build_object('id', b.id, 'code', b.code, 'company', (select name from public.bottle_companies where id = b.company_id),
      'is_own', b.company_id = app.own_company_id(), 'type', (select name from public.bottle_types where id = b.bottle_type_id),
      'holder', app.holder_label(b.holder_type, b.holder_id), 'holder_type', b.holder_type, 'fill_state', b.fill_state,
      'condition', b.condition, 'lifecycle', b.lifecycle, 'fill_count', b.fill_count, 'created_at', b.created_at,
      'last_movement_at', b.last_movement_at),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('at', t.created_at, 'type', t.txn_type,
        'from', app.holder_label(t.from_type, t.from_id), 'to', app.holder_label(t.to_type, t.to_id), 'to_fill', t.to_fill,
        'by', (select full_name from public.profiles where id = t.created_by), 'reference_type', t.reference_type,
        'reason', t.reason) order by t.created_at desc, t.id desc), '[]')
      from public.bottle_transactions t where t.bottle_id = b.id)
  ) into v;
  return v;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;
revoke execute on function public.log_failed_login(text, text, text, text) from authenticated;
revoke execute on function public.bootstrap_super_admin(text)              from authenticated;

-- Customer list with balances (server-side search + pagination)
create or replace function public.customer_list(
  p_search text, p_type text, p_route uuid, p_status text, p_limit integer, p_offset integer)
returns table (id uuid, customer_no text, name text, company_name text, customer_type text, phone text, route text,
               status text, bottle_model text, ola_bottles integer, outstanding numeric, total_count bigint)
language sql stable security definer set search_path = '' as $$
  with f as (
    select c.* from public.customers c
     where app.has_permission('customers.view')
       and (p_search is null or p_search = '' or c.name ilike '%' || p_search || '%' or c.company_name ilike '%' || p_search || '%'
            or c.customer_no ilike '%' || p_search || '%'
            or c.phone like '%' || regexp_replace(regexp_replace(p_search, '[^0-9]', '', 'g'), '^0', '') || '%')
       and (p_type is null or p_type = '' or c.customer_type = p_type)
       and (p_route is null or c.route_id = p_route)
       and (p_status is null or p_status = '' or c.status = p_status))
  select f.id, f.customer_no, f.name, f.company_name, f.customer_type, f.phone, r.name, f.status, f.bottle_model,
         app.customer_ola_bottles(f.id), app.customer_outstanding(f.id), count(*) over ()
    from f left join public.routes r on r.id = f.route_id
   order by f.name
   limit least(coalesce(p_limit, 50), 200) offset coalesce(p_offset, 0)
$$;
grant execute on function public.customer_list(text, text, uuid, text, integer, integer) to authenticated;

-- Active staff who can drive (for dispatch and route screens)
create or replace function public.list_drivers()
returns table (id uuid, full_name text, phone text)
language sql stable security definer set search_path = '' as $$
  select distinct p.id, p.full_name, p.phone
    from public.profiles p
    join public.user_roles ur on ur.user_id = p.id
    join public.roles r on r.id = ur.role_id and r.code = 'driver' and r.archived_at is null
   where p.is_active
     and (app.has_permission('deliveries.manage') or app.has_permission('routes.manage') or app.has_permission('deliveries.view'))
   order by p.full_name
$$;
grant execute on function public.list_drivers() to authenticated;

-- >>> 20261002000015_storage.sql
-- =====================================================================
-- OLA Water ERP — Phase 1A
-- 0015: private storage for delivery proof photos
-- Path convention: delivery-proofs/{run_id}/{delivery_id}-{client_txn_id}.jpg
-- (Skipped automatically where the Supabase storage schema is not present.)
-- =====================================================================
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('delivery-proofs', 'delivery-proofs', false, 2097152, array['image/jpeg','image/png','image/webp'])
    on conflict (id) do nothing;

    execute $p$
      create policy "Drivers upload proofs for their own runs" on storage.objects
        for insert to authenticated
        with check (
          bucket_id = 'delivery-proofs'
          and exists (select 1 from public.route_runs r
                       where r.id::text = (storage.foldername(name))[1]
                         and (r.driver_id = auth.uid() or app.has_permission('deliveries.manage')))
        )
    $p$;
    execute $p$
      create policy "Staff read delivery proofs" on storage.objects
        for select to authenticated
        using (
          bucket_id = 'delivery-proofs'
          and (app.has_permission('deliveries.view')
               or exists (select 1 from public.route_runs r where r.id::text = (storage.foldername(name))[1] and r.driver_id = auth.uid()))
        )
    $p$;
  end if;
exception when others then
  -- Never stop the rest of the update because of storage permissions.
  raise notice 'Storage bucket/policies not created (%). Delivery photos cannot be stored until this is fixed (signatures still work).', sqlerrm;
end $$;

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
