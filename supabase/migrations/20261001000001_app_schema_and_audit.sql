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
