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
