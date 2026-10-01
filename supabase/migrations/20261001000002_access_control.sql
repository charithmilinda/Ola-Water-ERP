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
