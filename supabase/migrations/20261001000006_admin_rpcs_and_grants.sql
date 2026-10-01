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
