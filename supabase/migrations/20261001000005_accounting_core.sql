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
