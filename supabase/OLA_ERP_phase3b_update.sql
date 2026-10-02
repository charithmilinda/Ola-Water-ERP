-- OLA Water ERP — Phase 3B database update (sales team, commissions, distributors, CRM)
-- Run ONCE in Supabase → SQL Editor → New query, on the database that already has Phase 3A.
-- It runs as one transaction: if anything fails, nothing is changed.
begin;

-- >>> 20261008000041_sales_team.sql
-- =====================================================================
-- OLA Water ERP — Phase 3B
-- 0041: territories, sales representatives, monthly targets, customer
--       visits with GPS check-in, collections by reps (cash with rep →
--       handed in), commission plans and monthly commission statements
--       (accrued, then paid through payroll or directly)
-- =====================================================================

create table public.territories (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (code ~ '^[A-Z0-9_-]{2,12}$'),
  name        text not null check (length(trim(name)) > 0),
  districts   text[] not null default '{}',
  notes       text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create trigger territories_audit after insert or update on public.territories for each row execute function app.audit_row('sales');

create table public.commission_plans (
  id                   uuid primary key default gen_random_uuid(),
  code                 text not null unique check (code ~ '^[A-Z0-9_-]{2,12}$'),
  name                 text not null,
  sales_rate_pct       numeric(6,3) not null default 0 check (sales_rate_pct between 0 and 100),
  collection_rate_pct  numeric(6,3) not null default 0 check (collection_rate_pct between 0 and 100),
  target_bonus_pct     numeric(6,3) not null default 0 check (target_bonus_pct between 0 and 100),
  new_customer_bonus   numeric(12,2) not null default 0 check (new_customer_bonus >= 0),
  notes                text,
  is_active            boolean not null default true,
  updated_at           timestamptz not null default now()
);
comment on table public.commission_plans is 'Commission = sales × sales rate + collections × collection rate + (target met: sales × bonus rate) + new customers × bonus.';
create trigger commission_plans_touch before update on public.commission_plans for each row execute function app.touch_updated_at();
create trigger commission_plans_audit after insert or update on public.commission_plans for each row execute function app.audit_row('sales');

create table public.sales_reps (
  id                  uuid primary key default gen_random_uuid(),
  profile_id          uuid not null unique references public.profiles(id),
  employee_id         uuid unique references public.employees(id),
  code                text not null unique check (code ~ '^[A-Z0-9_-]{2,12}$'),
  territory_id        uuid references public.territories(id),
  commission_plan_id  uuid references public.commission_plans(id),
  phone               text,
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create trigger sales_reps_touch before update on public.sales_reps for each row execute function app.touch_updated_at();
create trigger sales_reps_audit after insert or update on public.sales_reps for each row execute function app.audit_row('sales');

create table public.sales_targets (
  id                uuid primary key default gen_random_uuid(),
  rep_id            uuid not null references public.sales_reps(id),
  target_year       integer not null check (target_year between 2020 and 2100),
  target_month      integer not null check (target_month between 1 and 12),
  sales_target      numeric(14,2) not null default 0 check (sales_target >= 0),
  collection_target numeric(14,2) not null default 0 check (collection_target >= 0),
  new_customers     integer not null default 0 check (new_customers >= 0),
  visits            integer not null default 0 check (visits >= 0),
  updated_at        timestamptz not null default now(),
  unique (rep_id, target_year, target_month)
);
create trigger sales_targets_touch before update on public.sales_targets for each row execute function app.touch_updated_at();
create trigger sales_targets_audit after insert or update on public.sales_targets for each row execute function app.audit_row('sales');

create table public.rep_visits (
  id              uuid primary key default gen_random_uuid(),
  rep_id          uuid not null references public.sales_reps(id),
  customer_id     uuid references public.customers(id),
  lead_id         uuid,                         -- FK added with CRM
  purpose         text not null check (purpose in ('sales_call','collection','new_customer','follow_up','complaint','merchandising','other')),
  checkin_at      timestamptz not null default now(),
  checkin_lat     numeric(9,6),
  checkin_lng     numeric(9,6),
  gps_accuracy_m  numeric(8,1),
  distance_m      integer,                      -- from the customer's saved location
  checkout_at     timestamptz,
  outcome         text check (outcome in ('order','payment','interested','not_interested','no_one_there','follow_up','other')),
  notes           text,
  next_action_on  date,
  order_id        uuid references public.orders(id),
  payment_id      uuid references public.payments(id),
  created_at      timestamptz not null default now(),
  client_txn_id   uuid unique,
  check (customer_id is not null or lead_id is not null)
);
create index rep_visits_rep_idx on public.rep_visits (rep_id, checkin_at desc);
create index rep_visits_customer_idx on public.rep_visits (customer_id, checkin_at desc);
create trigger rep_visits_audit after insert or update on public.rep_visits for each row execute function app.audit_row('sales');

-- Collections by reps
alter table public.payments add column rep_id uuid references public.sales_reps(id);
alter table public.journal_lines drop constraint if exists journal_lines_party_type_check;
alter table public.journal_lines add constraint journal_lines_party_type_check
  check (party_type in ('customer','water_shop','supplier','employee','driver','distributor','external_company','sales_rep'));

create table public.rep_cash_handovers (
  id                uuid primary key default gen_random_uuid(),
  handover_no       text not null unique,
  rep_id            uuid not null references public.sales_reps(id),
  amount            numeric(14,2) not null check (amount > 0),
  money_account_id  uuid not null references public.money_accounts(id),
  reference         text,
  notes             text,
  journal_entry_id  uuid references public.journal_entries(id),
  created_at        timestamptz not null default now(),
  created_by        uuid,
  client_txn_id     uuid unique
);
create trigger rep_cash_handovers_append_only before update or delete on public.rep_cash_handovers for each row execute function app.forbid_change();
create trigger rep_cash_handovers_audit after insert on public.rep_cash_handovers for each row execute function app.audit_row('sales');

-- Commission statements (one per rep per month)
create table public.commission_statements (
  id                 uuid primary key default gen_random_uuid(),
  statement_no       text not null unique,
  rep_id             uuid not null references public.sales_reps(id),
  period_year        integer not null,
  period_month       integer not null check (period_month between 1 and 12),
  plan_id            uuid references public.commission_plans(id),
  sales_net          numeric(14,2) not null default 0,
  collections        numeric(14,2) not null default 0,
  new_customers      integer not null default 0,
  visits             integer not null default 0,
  sales_target       numeric(14,2) not null default 0,
  achievement_pct    numeric(7,1),
  sales_commission   numeric(14,2) not null default 0,
  collection_commission numeric(14,2) not null default 0,
  target_bonus       numeric(14,2) not null default 0,
  new_customer_bonus numeric(14,2) not null default 0,
  adjustment         numeric(14,2) not null default 0,
  adjustment_note    text,
  total              numeric(14,2) not null default 0,
  status             text not null default 'draft' check (status in ('draft','approved','paid','cancelled')),
  prepared_by        uuid,
  prepared_at        timestamptz not null default now(),
  approved_by        uuid,
  approved_at        timestamptz,
  journal_entry_id   uuid references public.journal_entries(id),
  paid_via           text check (paid_via in ('payroll','direct')),
  payslip_id         uuid references public.payslips(id),
  paid_at            timestamptz,
  pay_journal_id     uuid references public.journal_entries(id),
  updated_at         timestamptz not null default now(),
  unique (rep_id, period_year, period_month)
);
create trigger commission_statements_touch before update on public.commission_statements for each row execute function app.touch_updated_at();
create trigger commission_statements_audit after insert or update on public.commission_statements for each row execute function app.audit_row('sales');

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create or replace function app.my_rep()
returns public.sales_reps language sql stable security definer set search_path = '' as $$
  select * from public.sales_reps where profile_id = app.current_user_id() and is_active
$$;

-- Great-circle distance in metres
create or replace function app.distance_m(p_lat1 numeric, p_lng1 numeric, p_lat2 numeric, p_lng2 numeric)
returns integer language sql immutable set search_path = '' as $$
  select case when p_lat1 is null or p_lng1 is null or p_lat2 is null or p_lng2 is null then null else
    round(6371000 * 2 * asin(sqrt(power(sin(radians((p_lat2 - p_lat1) / 2)), 2)
      + cos(radians(p_lat1)) * cos(radians(p_lat2)) * power(sin(radians((p_lng2 - p_lng1) / 2)), 2))))::integer end
$$;

-- A rep's numbers for a month: own customers' invoiced sales (before VAT), their payments, new customers who bought, visits.
create or replace function app.rep_month_figures(p_rep uuid, p_year integer, p_month integer)
returns jsonb language sql stable security definer set search_path = '' as $$
  with r as (select * from public.sales_reps where id = p_rep),
       per as (select make_date(p_year, p_month, 1) d1, (make_date(p_year, p_month, 1) + interval '1 month')::date d2)
  select jsonb_build_object(
    'sales_net', coalesce((select sum(i.subtotal_net) from public.invoices i join public.customers c on c.id = i.customer_id, per
                            where c.sales_rep_id = (select profile_id from r) and i.status <> 'void'
                              and i.invoice_date >= per.d1 and i.invoice_date < per.d2), 0)
               - coalesce((select sum(cn.net) from public.credit_notes cn join public.customers c on c.id = cn.customer_id, per
                            where c.sales_rep_id = (select profile_id from r) and cn.credit_date >= per.d1 and cn.credit_date < per.d2), 0),
    'collections', coalesce((select sum(p.amount) from public.payments p join public.customers c on c.id = p.customer_id, per
                              where c.sales_rep_id = (select profile_id from r) and p.status = 'received' and coalesce(p.direction, 'in') = 'in'
                                and (p.received_at at time zone 'Asia/Colombo')::date >= per.d1
                                and (p.received_at at time zone 'Asia/Colombo')::date < per.d2), 0),
    'new_customers', (select count(*) from public.customers c, per
                       where c.sales_rep_id = (select profile_id from r)
                         and (select min(i.invoice_date) from public.invoices i where i.customer_id = c.id and i.status <> 'void') >= per.d1
                         and (select min(i.invoice_date) from public.invoices i where i.customer_id = c.id and i.status <> 'void') < per.d2),
    'visits', (select count(*) from public.rep_visits v, per where v.rep_id = p_rep
                 and (v.checkin_at at time zone 'Asia/Colombo')::date >= per.d1 and (v.checkin_at at time zone 'Asia/Colombo')::date < per.d2),
    'cash_with_rep', coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.accounts a on a.id = l.account_id
                                where a.system_key = 'rep_cash' and l.party_type = 'sales_rep' and l.party_id = p_rep), 0))
$$;

-- ---------------------------------------------------------------------
-- Territories, plans, reps, targets
-- ---------------------------------------------------------------------
create or replace function public.save_territory(p_id uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  if not (app.has_permission('sales_reps.manage') or app.has_permission('distributors.manage')) then
    raise exception 'Permission denied: sales_reps.manage is required' using errcode = '42501';
  end if;
  if app.jtext(p, 'code') is null or app.jtext(p, 'name') is null then raise exception 'Enter a code and a name' using errcode = '22023'; end if;
  if p_id is null then
    insert into public.territories (code, name, districts, notes)
    values (upper(app.jtext(p, 'code')), app.jtext(p, 'name'),
            coalesce((select array_agg(trim(x)) from jsonb_array_elements_text(coalesce(p -> 'districts', '[]')) x where trim(x) <> ''), '{}'),
            app.jtext(p, 'notes'))
    returning id into v;
  else
    update public.territories set code = upper(app.jtext(p, 'code')), name = app.jtext(p, 'name'),
      districts = coalesce((select array_agg(trim(x)) from jsonb_array_elements_text(coalesce(p -> 'districts', '[]')) x where trim(x) <> ''), '{}'),
      notes = app.jtext(p, 'notes'), is_active = app.jbool(p, 'is_active', true)
     where id = p_id returning id into v;
    if v is null then raise exception 'Territory not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

create or replace function public.save_commission_plan(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform app.require_permission('sales_reps.manage');
  if app.jtext(p, 'code') is null or app.jtext(p, 'name') is null then raise exception 'Enter a code and a name' using errcode = '22023'; end if;
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Commission plan saved'), null, null);
  if p_id is null then
    insert into public.commission_plans (code, name, sales_rate_pct, collection_rate_pct, target_bonus_pct, new_customer_bonus, notes)
    values (upper(app.jtext(p, 'code')), app.jtext(p, 'name'), coalesce(app.jnum(p, 'sales_rate_pct'), 0), coalesce(app.jnum(p, 'collection_rate_pct'), 0),
            coalesce(app.jnum(p, 'target_bonus_pct'), 0), coalesce(app.jnum(p, 'new_customer_bonus'), 0), app.jtext(p, 'notes'))
    returning id into v;
  else
    update public.commission_plans set code = upper(app.jtext(p, 'code')), name = app.jtext(p, 'name'),
      sales_rate_pct = coalesce(app.jnum(p, 'sales_rate_pct'), 0), collection_rate_pct = coalesce(app.jnum(p, 'collection_rate_pct'), 0),
      target_bonus_pct = coalesce(app.jnum(p, 'target_bonus_pct'), 0), new_customer_bonus = coalesce(app.jnum(p, 'new_customer_bonus'), 0),
      notes = app.jtext(p, 'notes'), is_active = app.jbool(p, 'is_active', true)
     where id = p_id returning id into v;
    if v is null then raise exception 'Plan not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

-- p: profile_id, employee_id, code, territory_id, commission_plan_id, phone, is_active
create or replace function public.save_sales_rep(p_id uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform app.require_permission('sales_reps.manage');
  if app.jtext(p, 'code') is null then raise exception 'Enter a rep code' using errcode = '22023'; end if;
  if p_id is null then
    if not exists (select 1 from public.profiles where id = app.juuid(p, 'profile_id') and is_active) then
      raise exception 'Choose the rep''s login' using errcode = '22023';
    end if;
    if exists (select 1 from public.sales_reps where profile_id = app.juuid(p, 'profile_id')) then
      raise exception 'This login already exists as a sales rep' using errcode = '23505';
    end if;
    insert into public.sales_reps (profile_id, employee_id, code, territory_id, commission_plan_id, phone)
    values (app.juuid(p, 'profile_id'), app.juuid(p, 'employee_id'), upper(app.jtext(p, 'code')), app.juuid(p, 'territory_id'),
            app.juuid(p, 'commission_plan_id'), app.normalize_phone(app.jtext(p, 'phone')))
    returning id into v;
  else
    update public.sales_reps set employee_id = app.juuid(p, 'employee_id'), code = upper(app.jtext(p, 'code')),
      territory_id = app.juuid(p, 'territory_id'), commission_plan_id = app.juuid(p, 'commission_plan_id'),
      phone = app.normalize_phone(app.jtext(p, 'phone')), is_active = app.jbool(p, 'is_active', true)
     where id = p_id returning id into v;
    if v is null then raise exception 'Rep not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

-- p_rows: [{rep_id, sales_target, collection_target, new_customers, visits}]
create or replace function public.set_sales_targets(p_year integer, p_month integer, p_rows jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare x jsonb; n integer := 0;
begin
  perform app.require_permission('sales_reps.manage');
  if p_month not between 1 and 12 then raise exception 'Choose a month' using errcode = '22023'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    insert into public.sales_targets (rep_id, target_year, target_month, sales_target, collection_target, new_customers, visits)
    values (app.juuid(x, 'rep_id'), p_year, p_month, coalesce(app.jnum(x, 'sales_target'), 0), coalesce(app.jnum(x, 'collection_target'), 0),
            coalesce(app.jint(x, 'new_customers'), 0), coalesce(app.jint(x, 'visits'), 0))
    on conflict (rep_id, target_year, target_month) do update set
      sales_target = excluded.sales_target, collection_target = excluded.collection_target,
      new_customers = excluded.new_customers, visits = excluded.visits;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Assign customers to a rep (account ownership)
create or replace function public.assign_customers_to_rep(p_customers uuid[], p_rep uuid, p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_profile uuid; n integer;
begin
  perform app.require_permission('sales_reps.manage');
  if p_rep is not null then
    select profile_id into v_profile from public.sales_reps where id = p_rep;
    if v_profile is null then raise exception 'Rep not found' using errcode = 'P0002'; end if;
  end if;
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Customers assigned to a sales rep'), null, null);
  update public.customers set sales_rep_id = v_profile where id = any(p_customers);
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Visits (GPS check-in / check-out)
-- p: customer_id | lead_id, purpose, lat, lng, accuracy, notes
-- ---------------------------------------------------------------------
create or replace function public.rep_check_in(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; r public.sales_reps; v uuid; v_dist integer; a record; v_res jsonb; v_radius integer;
begin
  r := app.my_rep();
  if r.id is null then raise exception 'You are not set up as a sales rep' using errcode = '42501'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'rep_check_in');
  if v_done is not null then return v_done; end if;
  if app.juuid(p, 'customer_id') is null and app.juuid(p, 'lead_id') is null then
    raise exception 'Choose the customer or lead you are visiting' using errcode = '22023';
  end if;
  if exists (select 1 from public.rep_visits where rep_id = r.id and checkout_at is null and checkin_at > now() - interval '12 hours') then
    raise exception 'Check out of your current visit first' using errcode = '22023';
  end if;
  if app.juuid(p, 'customer_id') is not null then
    select gps_lat, gps_lng into a from public.customer_addresses where customer_id = app.juuid(p, 'customer_id') and is_active
     order by is_default desc limit 1;
    v_dist := app.distance_m(app.jnum(p, 'lat'), app.jnum(p, 'lng'), a.gps_lat, a.gps_lng);
  end if;
  insert into public.rep_visits (rep_id, customer_id, lead_id, purpose, checkin_lat, checkin_lng, gps_accuracy_m, distance_m, notes, client_txn_id)
  values (r.id, app.juuid(p, 'customer_id'), app.juuid(p, 'lead_id'), coalesce(app.jtext(p, 'purpose'), 'sales_call'),
          app.jnum(p, 'lat'), app.jnum(p, 'lng'), app.jnum(p, 'accuracy'), v_dist, app.jtext(p, 'notes'), p_client_txn_id)
  returning id into v;
  v_radius := coalesce((app.get_setting('sales.visit_radius_m') #>> '{}')::integer, 300);
  v_res := jsonb_build_object('visit_id', v, 'distance_m', v_dist,
             'warning', case when app.jnum(p, 'lat') is null then 'No GPS position — the visit is recorded without location'
                             when v_dist > v_radius then format('You are %s m from the customer''s saved location', v_dist) end);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.rep_check_out(p_visit uuid, p jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v public.rep_visits;
begin
  select * into v from public.rep_visits where id = p_visit for update;
  if not found then raise exception 'Visit not found' using errcode = 'P0002'; end if;
  if v.rep_id is distinct from (app.my_rep()).id and not app.has_permission('sales_reps.manage') then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  if v.checkout_at is not null then raise exception 'Already checked out' using errcode = '22023'; end if;
  if app.jtext(p, 'outcome') is null then raise exception 'Choose how the visit went' using errcode = '22023'; end if;
  update public.rep_visits set checkout_at = now(), outcome = app.jtext(p, 'outcome'),
    notes = coalesce(nullif(trim(coalesce(notes, '') || ' ' || coalesce(app.jtext(p, 'notes'), '')), ''), notes),
    next_action_on = (app.jtext(p, 'next_action_on'))::date,
    order_id = coalesce(app.juuid(p, 'order_id'), order_id), payment_id = coalesce(app.juuid(p, 'payment_id'), payment_id)
   where id = p_visit;
end $$;

-- ---------------------------------------------------------------------
-- Collections by a rep. Cash stays "with the rep" until handed in.
-- ---------------------------------------------------------------------
create or replace function public.rep_collect_payment(p_customer uuid, p_method text, p_amount numeric, p_reference text, p_notes text,
                                                      p_visit uuid, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; r public.sales_reps; v uuid; v_je uuid; pay public.payments; v_res jsonb;
begin
  perform app.require_permission('payments.collect');
  r := app.my_rep();
  if r.id is null then raise exception 'You are not set up as a sales rep' using errcode = '42501'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'rep_collect_payment');
  if v_done is not null then return v_done; end if;
  if p_method not in ('cash','cheque','bank_transfer') then raise exception 'Choose cash, cheque or bank transfer' using errcode = '22023'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Enter the amount' using errcode = '22023'; end if;
  if p_method in ('cheque','bank_transfer') and nullif(trim(p_reference), '') is null then
    raise exception 'Enter the % number', replace(p_method, '_', ' ') using errcode = '22023';
  end if;
  if not exists (select 1 from public.customers where id = p_customer and status <> 'inactive') then raise exception 'Customer not found' using errcode = '22023'; end if;
  perform app.set_context(null, p_client_txn_id, null);
  insert into public.payments (payment_no, customer_id, method, amount, reference, received_by, unallocated, notes, client_txn_id, rep_id)
  values (app.next_document_number('PAY'), p_customer, p_method, round(p_amount, 2), nullif(trim(p_reference), ''), app.current_user_id(),
          round(p_amount, 2), nullif(trim(p_notes), ''), p_client_txn_id, r.id)
  returning * into pay;
  if p_method = 'cash' then
    v_je := app.post_journal(app.today(), format('Payment %s collected by rep %s', pay.payment_no, r.code), 'payment.rep_cash',
      jsonb_build_array(
        jsonb_build_object('account_key', 'rep_cash', 'debit', pay.amount, 'credit', 0, 'memo', 'Cash with sales rep', 'party_type', 'sales_rep', 'party_id', r.id),
        jsonb_build_object('account_key', 'ar', 'debit', 0, 'credit', pay.amount, 'memo', 'Receivable settled', 'party_type', 'customer', 'party_id', p_customer)),
      'payment', pay.id);
    update public.payments set journal_entry_id = v_je where id = pay.id;
  else
    perform app.post_payment(pay.id);
  end if;
  perform app.allocate_payment(pay.id, null);
  if p_visit is not null then
    update public.rep_visits set payment_id = pay.id where id = p_visit and rep_id = r.id;
  end if;
  v_res := jsonb_build_object('payment_id', pay.id, 'payment_no', pay.payment_no, 'outstanding', app.customer_outstanding(p_customer),
                              'cash_with_rep', (app.rep_month_figures(r.id, extract(year from app.today())::int, extract(month from app.today())::int) ->> 'cash_with_rep')::numeric);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.rep_cash_handover(p_rep uuid, p_amount numeric, p_money_account uuid, p_reference text, p_notes text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; r public.sales_reps; m public.money_accounts; v_held numeric; v uuid; v_no text; v_je uuid; v_res jsonb;
begin
  perform app.require_permission('payments.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'rep_cash_handover');
  if v_done is not null then return v_done; end if;
  select * into r from public.sales_reps where id = p_rep;
  if not found then raise exception 'Rep not found' using errcode = 'P0002'; end if;
  m := app.money_account(p_money_account);
  if m.kind not in ('cash','bank') then raise exception 'Choose the cash or bank account the money went into' using errcode = '22023'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Enter the amount handed in' using errcode = '22023'; end if;
  select coalesce(sum(l.debit - l.credit), 0) into v_held from public.journal_lines l join public.accounts a on a.id = l.account_id
   where a.system_key = 'rep_cash' and l.party_type = 'sales_rep' and l.party_id = r.id;
  if p_amount > v_held then
    raise exception 'The rep holds only Rs. %', to_char(v_held, 'FM999,999,990.00') using errcode = '22023';
  end if;
  perform app.set_context(coalesce(nullif(trim(p_notes), ''), 'Rep cash handed in'), p_client_txn_id, null);
  v_no := app.next_document_number('RCH');
  v_je := app.post_journal(app.today(), format('Cash handed in by rep %s (%s)', r.code, v_no), 'rep.cash_handover',
    jsonb_build_array(
      jsonb_build_object('account_id', m.account_id, 'debit', p_amount, 'credit', 0, 'memo', 'Cash received from rep'),
      jsonb_build_object('account_key', 'rep_cash', 'debit', 0, 'credit', p_amount, 'memo', 'Rep cash cleared', 'party_type', 'sales_rep', 'party_id', r.id)),
    'rep_cash_handover', null);
  insert into public.rep_cash_handovers (handover_no, rep_id, amount, money_account_id, reference, notes, journal_entry_id, created_by, client_txn_id)
  values (v_no, r.id, round(p_amount, 2), m.id, nullif(trim(p_reference), ''), nullif(trim(p_notes), ''), v_je, app.current_user_id(), p_client_txn_id)
  returning id into v;
  v_res := jsonb_build_object('handover_id', v, 'handover_no', v_no, 'still_held', v_held - p_amount);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- Commission statements
-- ---------------------------------------------------------------------
create or replace function app.refresh_commission_statement(p_statement uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare s public.commission_statements; pl public.commission_plans; f jsonb; t public.sales_targets; v_ach numeric;
        v_sc numeric; v_cc numeric; v_tb numeric; v_nb numeric;
begin
  select * into s from public.commission_statements where id = p_statement for update;
  select * into pl from public.commission_plans where id = (select commission_plan_id from public.sales_reps where id = s.rep_id);
  f := app.rep_month_figures(s.rep_id, s.period_year, s.period_month);
  select * into t from public.sales_targets where rep_id = s.rep_id and target_year = s.period_year and target_month = s.period_month;
  v_ach := case when coalesce(t.sales_target, 0) > 0 then round((f ->> 'sales_net')::numeric / t.sales_target * 100, 1) end;
  v_sc := round(greatest((f ->> 'sales_net')::numeric, 0) * coalesce(pl.sales_rate_pct, 0) / 100, 2);
  v_cc := round((f ->> 'collections')::numeric * coalesce(pl.collection_rate_pct, 0) / 100, 2);
  v_tb := case when v_ach >= 100 then round((f ->> 'sales_net')::numeric * coalesce(pl.target_bonus_pct, 0) / 100, 2) else 0 end;
  v_nb := (f ->> 'new_customers')::integer * coalesce(pl.new_customer_bonus, 0);
  update public.commission_statements set plan_id = pl.id, sales_net = (f ->> 'sales_net')::numeric, collections = (f ->> 'collections')::numeric,
    new_customers = (f ->> 'new_customers')::integer, visits = (f ->> 'visits')::integer, sales_target = coalesce(t.sales_target, 0),
    achievement_pct = v_ach, sales_commission = v_sc, collection_commission = v_cc, target_bonus = v_tb, new_customer_bonus = v_nb,
    total = greatest(v_sc + v_cc + v_tb + v_nb + adjustment, 0)
   where id = s.id;
end $$;

-- Create (or refresh the drafts of) the statements for a month that has ended
create or replace function public.prepare_commissions(p_year integer, p_month integer)
returns integer language plpgsql security definer set search_path = '' as $$
declare r record; v uuid; n integer := 0;
begin
  perform app.require_permission('sales_reps.manage');
  if make_date(p_year, p_month, 1) > date_trunc('month', app.today())::date then
    raise exception 'That month has not started yet' using errcode = '22023';
  end if;
  for r in select * from public.sales_reps where is_active and commission_plan_id is not null loop
    select id into v from public.commission_statements where rep_id = r.id and period_year = p_year and period_month = p_month;
    if v is null then
      insert into public.commission_statements (statement_no, rep_id, period_year, period_month, prepared_by)
      values (app.next_document_number('COM'), r.id, p_year, p_month, app.current_user_id()) returning id into v;
    elsif (select status from public.commission_statements where id = v) <> 'draft' then
      continue;
    end if;
    perform app.refresh_commission_statement(v);
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.adjust_commission(p_statement uuid, p_amount numeric, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare s public.commission_statements;
begin
  perform app.require_permission('sales_reps.manage');
  select * into s from public.commission_statements where id = p_statement for update;
  if s.status <> 'draft' then raise exception 'Only a draft can be adjusted' using errcode = '22023'; end if;
  if coalesce(p_amount, 0) <> 0 and nullif(trim(p_note), '') is null then raise exception 'Explain the adjustment' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_note), ''), null, null);
  update public.commission_statements set adjustment = coalesce(p_amount, 0), adjustment_note = nullif(trim(p_note), '') where id = s.id;
  perform app.refresh_commission_statement(s.id);
end $$;

create or replace function public.approve_commission(p_statement uuid, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.commission_statements; r public.sales_reps; v_je uuid;
begin
  if not (app.has_permission('payroll.approve') or app.has_permission('expenses.approve')) then
    raise exception 'Permission denied: payroll.approve or expenses.approve is required' using errcode = '42501';
  end if;
  select * into s from public.commission_statements where id = p_statement for update;
  if not found then raise exception 'Statement not found' using errcode = 'P0002'; end if;
  if s.status <> 'draft' then raise exception 'Only a draft can be approved' using errcode = '22023'; end if;
  if make_date(s.period_year, s.period_month, 1) + interval '1 month' > app.today() then
    raise exception 'Approve commission after the month has ended' using errcode = '22023';
  end if;
  select * into r from public.sales_reps where id = s.rep_id;
  if r.profile_id = app.current_user_id() then raise exception 'You cannot approve your own commission' using errcode = '42501'; end if;
  perform app.refresh_commission_statement(s.id);
  select * into s from public.commission_statements where id = p_statement;
  perform app.set_context(coalesce(nullif(trim(p_note), ''), 'Commission approved'), null, 'approve');
  if s.total > 0 then
    v_je := app.post_journal(app.open_posting_date((make_date(s.period_year, s.period_month, 1) + interval '1 month - 1 day')::date),
      format('Sales commission %s — rep %s, %s', s.statement_no, r.code, to_char(make_date(s.period_year, s.period_month, 1), 'FMMonth YYYY')),
      'commission.approved',
      jsonb_build_array(
        jsonb_build_object('account_key', 'exp_sales_commission', 'debit', s.total, 'credit', 0, 'memo', 'Sales commission'),
        jsonb_build_object('account_key', 'commission_payable', 'debit', 0, 'credit', s.total, 'memo', 'Commission owed', 'party_type', 'sales_rep', 'party_id', r.id)),
      'commission_statement', s.id);
  end if;
  update public.commission_statements set status = case when s.total > 0 then 'approved' else 'paid' end,
         approved_by = app.current_user_id(), approved_at = now(), journal_entry_id = v_je,
         paid_at = case when s.total > 0 then null else now() end where id = s.id;
  return jsonb_build_object('status', case when s.total > 0 then 'approved' else 'paid' end, 'total', s.total,
                            'via_payroll', r.employee_id is not null);
end $$;

-- Pay a commission directly (reps who are not on the payroll, or paid separately)
create or replace function public.pay_commission(p_statement uuid, p_money_account uuid, p_reference text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; s public.commission_statements; r public.sales_reps; m public.money_accounts; v_je uuid; v_res jsonb;
begin
  perform app.require_permission('payments.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'pay_commission');
  if v_done is not null then return v_done; end if;
  select * into s from public.commission_statements where id = p_statement for update;
  if s.status <> 'approved' then raise exception 'Only an approved, unpaid commission can be paid' using errcode = '22023'; end if;
  select * into r from public.sales_reps where id = s.rep_id;
  m := app.money_account(p_money_account);
  if m.kind = 'bank' and nullif(trim(p_reference), '') is null then raise exception 'Enter the bank transfer reference' using errcode = '22023'; end if;
  perform app.set_context('Commission paid', p_client_txn_id, null);
  v_je := app.post_journal(app.today(), format('Commission %s paid to rep %s', s.statement_no, r.code), 'commission.paid',
    jsonb_build_array(
      jsonb_build_object('account_key', 'commission_payable', 'debit', s.total, 'credit', 0, 'memo', 'Commission paid', 'party_type', 'sales_rep', 'party_id', r.id),
      jsonb_build_object('account_id', m.account_id, 'debit', 0, 'credit', s.total, 'memo', coalesce(p_reference, 'Commission'))),
    'commission_statement', s.id);
  update public.commission_statements set status = 'paid', paid_via = 'direct', paid_at = now(), pay_journal_id = v_je where id = s.id;
  v_res := jsonb_build_object('status', 'paid', 'statement_no', s.statement_no);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- Payroll: approved commissions of reps who are employees are paid on
-- their next payslip (the expense was already booked at approval).
-- ---------------------------------------------------------------------
alter table public.payslip_lines drop constraint if exists payslip_lines_source_check;
alter table public.payslip_lines add constraint payslip_lines_source_check check (source in ('fixed','adjustment','commission'));
alter table public.payslip_lines add column commission_statement_id uuid references public.commission_statements(id);

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.territories           enable row level security;
alter table public.commission_plans      enable row level security;
alter table public.sales_reps            enable row level security;
alter table public.sales_targets         enable row level security;
alter table public.rep_visits            enable row level security;
alter table public.rep_cash_handovers    enable row level security;
alter table public.commission_statements enable row level security;

create policy territories_read on public.territories for select to authenticated using (true);
create policy commission_plans_read on public.commission_plans for select to authenticated
  using (app.has_permission('sales_reps.manage') or app.has_permission('payroll.approve') or app.has_permission('accounting.view')
         or exists (select 1 from public.sales_reps r where r.commission_plan_id = commission_plans.id and r.profile_id = app.current_user_id()));
create policy sales_reps_read on public.sales_reps for select to authenticated
  using (app.has_permission('sales_reps.manage') or app.has_permission('customers.view') or profile_id = app.current_user_id());
create policy sales_targets_read on public.sales_targets for select to authenticated
  using (app.has_permission('sales_reps.manage') or exists (select 1 from public.sales_reps r where r.id = rep_id and r.profile_id = app.current_user_id()));
create policy rep_visits_read on public.rep_visits for select to authenticated
  using (app.has_permission('sales_reps.manage')
         or exists (select 1 from public.sales_reps r where r.id = rep_id and r.profile_id = app.current_user_id())
         or (customer_id is not null and app.has_permission('customers.manage')));
create policy rep_cash_handovers_read on public.rep_cash_handovers for select to authenticated
  using (app.has_permission('payments.manage') or app.has_permission('sales_reps.manage')
         or exists (select 1 from public.sales_reps r where r.id = rep_id and r.profile_id = app.current_user_id()));
create policy commission_statements_read on public.commission_statements for select to authenticated
  using (app.has_permission('sales_reps.manage') or app.has_permission('payroll.approve') or app.has_permission('expenses.approve')
         or app.has_permission('payments.manage')
         or exists (select 1 from public.sales_reps r where r.id = rep_id and r.profile_id = app.current_user_id()));

-- Payroll replacements (only the marked [3B] parts changed)


create or replace function app.calc_payslip(p_payslip uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  s public.payslips; r public.payroll_runs; e public.employees;
  v_days numeric; v_present numeric; v_nopay numeric; v_paid_leave numeric; v_basic numeric; v_nopay_amt numeric := 0; v_ot_hours numeric;
  v_ot numeric; v_earn numeric; v_epf_earn numeric; v_nontax numeric; v_gross numeric; v_epf numeric; v_epfer numeric; v_etf numeric;
  v_taxable numeric; v_apit numeric; v_other numeric; v_adv numeric := 0; v_take numeric; a record; v_net numeric; v_warn text;
  v_from date; v_to date; v_nopay_div numeric; v_ot_div numeric; v_ot_mult numeric; v_monthly_equiv numeric; v_recorded integer;
begin
  select * into s from public.payslips where id = p_payslip for update;
  select * into r from public.payroll_runs where id = s.run_id;
  select * into e from public.employees where id = s.employee_id;
  v_from := greatest(r.period_start, e.join_date);
  v_to := least(r.period_end, coalesce(e.end_date, r.period_end));
  v_days := (r.period_end - r.period_start + 1);
  v_nopay_div := coalesce((app.get_setting('payroll.nopay_divisor', r.period_end) #>> '{}')::numeric, 30);
  v_ot_div := coalesce((app.get_setting('payroll.ot_divisor', r.period_end) #>> '{}')::numeric, 240);
  v_ot_mult := coalesce((app.get_setting('payroll.ot_multiplier', r.period_end) #>> '{}')::numeric, 1.5);

  -- attendance in the employee's part of the month
  select count(*),
         coalesce(sum(case status when 'present' then 1 when 'half_day' then 0.5 else 0 end), 0),
         coalesce(sum(case when status = 'absent' then 1 when status = 'half_day' then 0.5
                           when status = 'leave' and not lt.is_paid then case when a2.notes = 'Half day' then 0.5 else 1 end else 0 end), 0),
         coalesce(sum(case when status = 'leave' and lt.is_paid then case when a2.notes = 'Half day' then 0.5 else 1 end else 0 end), 0),
         coalesce(sum(ot_hours), 0)
    into v_recorded, v_present, v_nopay, v_paid_leave, v_ot_hours
    from public.attendance a2 left join public.leave_types lt on lt.id = a2.leave_type_id
   where a2.employee_id = e.id and a2.work_date between v_from and v_to;

  if e.pay_basis = 'daily' then
    v_basic := round(e.daily_rate * (v_present + v_paid_leave), 2);
    v_monthly_equiv := e.daily_rate * 30;
    v_nopay := 0;
  else
    -- joined or left during the month: pay the calendar days employed
    v_basic := case when v_to - v_from + 1 < v_days then round(e.basic_salary * (v_to - v_from + 1) / v_days, 2) else e.basic_salary end;
    v_monthly_equiv := e.basic_salary;
    v_nopay_amt := round(e.basic_salary / v_nopay_div * v_nopay, 2);
    if v_nopay_amt > v_basic then v_nopay_amt := v_basic; end if;
  end if;
  v_ot := round(v_monthly_equiv / v_ot_div * v_ot_mult * v_ot_hours, 2);

  -- fixed allowances and deductions (refreshed every time a draft is recalculated)
  delete from public.payslip_lines where payslip_id = s.id and source = 'fixed';
  insert into public.payslip_lines (payslip_id, source, component_id, name, kind, amount, epf_liable, taxable, account_id)
  select s.id, 'fixed', c.id, c.name, c.kind, i.amount, c.epf_liable, c.taxable, c.account_id
    from public.employee_pay_items i join public.pay_components c on c.id = i.component_id
   where i.employee_id = e.id and c.is_active;

  -- [3B] approved sales commissions of reps who are employees
  delete from public.payslip_lines where payslip_id = s.id and source = 'commission';
  insert into public.payslip_lines (payslip_id, source, component_id, name, kind, amount, epf_liable, taxable, account_id, commission_statement_id)
  select s.id, 'commission', (select id from public.pay_components where code = 'INCENTIVE'),
         'Sales commission ' || to_char(make_date(cs.period_year, cs.period_month, 1), 'Mon YYYY'), 'earning', cs.total, false, true,
         (select id from public.accounts where system_key = 'commission_payable'), cs.id
    from public.commission_statements cs join public.sales_reps sr on sr.id = cs.rep_id
   where sr.employee_id = e.id and cs.status = 'approved' and cs.total > 0
     and cs.period_year * 100 + cs.period_month <= r.pay_year * 100 + r.pay_month;

  select coalesce(sum(amount) filter (where kind = 'earning'), 0),
         coalesce(sum(amount) filter (where kind = 'earning' and epf_liable), 0),
         coalesce(sum(amount) filter (where kind = 'earning' and not taxable), 0),
         coalesce(sum(amount) filter (where kind = 'deduction'), 0)
    into v_earn, v_epf_earn, v_nontax, v_other
    from public.payslip_lines where payslip_id = s.id;

  v_gross := v_basic - v_nopay_amt + v_ot + v_earn;
  v_epf_earn := v_basic - v_nopay_amt + v_epf_earn;
  v_epf := case when e.epf_applicable then round(v_epf_earn * app.statutory_rate('epf_employee', r.period_end) / 100, 2) else 0 end;
  v_epfer := case when e.epf_applicable then round(v_epf_earn * app.statutory_rate('epf_employer', r.period_end) / 100, 2) else 0 end;
  v_etf := case when e.etf_applicable then round(v_epf_earn * app.statutory_rate('etf_employer', r.period_end) / 100, 2) else 0 end;
  v_taxable := v_gross - v_nontax;
  v_apit := case when e.apit_applicable then app.apit_monthly(v_taxable, r.period_end) else 0 end;

  -- advance recovery, never more than what is left to pay
  v_net := v_gross - v_epf - v_apit - v_other;
  for a in select id, installment, outstanding from public.salary_advances where employee_id = e.id and status = 'active' order by advance_date loop
    v_take := least(a.installment, a.outstanding, greatest(v_net - v_adv, 0));
    v_adv := v_adv + v_take;
  end loop;
  if v_net - v_adv < 0 then v_warn := 'Deductions are more than the pay'; end if;
  if e.pay_basis = 'monthly' and v_recorded = 0 then v_warn := coalesce(v_warn || '; ', '') || 'No attendance recorded — paid in full'; end if;

  update public.payslips set
    emp_no = e.emp_no, employee_name = e.full_name,
    department = (select name from public.departments where id = e.department_id),
    position = (select name from public.positions where id = e.position_id),
    epf_no = e.epf_no, bank_name = e.bank_name, bank_account_no = e.bank_account_no, pay_basis = e.pay_basis,
    basic = v_basic, days_paid = case when e.pay_basis = 'daily' then v_present + v_paid_leave else (v_to - v_from + 1) - v_nopay end,
    nopay_days = v_nopay, nopay_amount = v_nopay_amt, ot_hours = v_ot_hours, ot_amount = v_ot, earnings = v_earn, gross = v_gross,
    epf_earnings = v_epf_earn, epf_employee = v_epf, epf_employer = v_epfer, etf = v_etf, taxable = v_taxable, apit = v_apit,
    advance_recovery = v_adv, other_deductions = v_other, total_deductions = v_epf + v_apit + v_other + v_adv,
    net = v_gross - (v_epf + v_apit + v_other + v_adv), warning = v_warn
  where id = s.id;
end $$;

create or replace function public.approve_payroll_run(p_run uuid, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs; v_lines jsonb; v_je uuid; x record; v_deduct jsonb := '[]'; v_comm numeric;
begin
  perform app.require_permission('payroll.approve');
  select * into r from public.payroll_runs where id = p_run for update;
  if not found or r.status <> 'draft' then raise exception 'Only a draft payroll can be approved' using errcode = '22023'; end if;
  if r.prepared_by = app.current_user_id() and not app.is_super_admin(app.current_user_id()) then
    raise exception 'Someone other than the person who prepared the payroll must approve it' using errcode = '42501';
  end if;
  if r.employees = 0 then raise exception 'There is nobody on this payroll' using errcode = '22023'; end if;
  if exists (select 1 from public.payslips where run_id = r.id and net < 0) then raise exception 'A payslip has a negative net pay — fix it first' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_note), ''), null, 'approve_payroll');
  -- [3B] commissions on payslips were expensed when approved: they clear Commission Payable instead
  select coalesce(sum(l.amount), 0) into v_comm from public.payslip_lines l join public.payslips s on s.id = l.payslip_id
   where s.run_id = r.id and l.source = 'commission';

  v_lines := jsonb_build_array(
    jsonb_build_object('account_key', 'exp_salaries', 'debit', r.gross - v_comm, 'credit', 0, 'memo', 'Gross pay'),
    jsonb_build_object('account_key', 'commission_payable', 'debit', v_comm, 'credit', 0, 'memo', 'Sales commission paid through payroll'),
    jsonb_build_object('account_key', 'exp_epf_etf', 'debit', r.epf_employer + r.etf, 'credit', 0, 'memo', 'Employer EPF and ETF'),
    jsonb_build_object('account_key', 'salaries_payable', 'debit', 0, 'credit', r.net, 'memo', 'Net pay'),
    jsonb_build_object('account_key', 'epf_payable', 'debit', 0, 'credit', r.epf_employee + r.epf_employer, 'memo', 'EPF 8% + 12%'),
    jsonb_build_object('account_key', 'etf_payable', 'debit', 0, 'credit', r.etf, 'memo', 'ETF'),
    jsonb_build_object('account_key', 'paye_payable', 'debit', 0, 'credit', r.apit, 'memo', 'APIT'),
    jsonb_build_object('account_key', 'staff_advances', 'debit', 0, 'credit', r.advances, 'memo', 'Advances recovered'));
  for x in select coalesce(l.account_id, (select id from public.accounts where system_key = 'payroll_deductions')) acc, sum(l.amount) amt
             from public.payslip_lines l join public.payslips s on s.id = l.payslip_id
            where s.run_id = r.id and l.kind = 'deduction' group by 1 loop
    v_lines := v_lines || jsonb_build_object('account_id', x.acc, 'debit', 0, 'credit', x.amt, 'memo', 'Payroll deductions');
  end loop;
  select coalesce(jsonb_agg(z), '[]') into v_lines from jsonb_array_elements(v_lines) z
   where (z ->> 'debit')::numeric > 0 or (z ->> 'credit')::numeric > 0;
  v_je := app.post_journal(app.open_posting_date(r.period_end), format('Payroll %s — %s', r.run_no, to_char(r.period_start, 'FMMonth YYYY')), 'payroll.approved',
    v_lines, 'payroll_run', r.id);

  -- recover advances
  for x in select s.id payslip_id, s.employee_id, s.advance_recovery from public.payslips s where s.run_id = r.id and s.advance_recovery > 0 loop
    declare a record; v_left numeric := x.advance_recovery; v_take numeric;
    begin
      for a in select id, installment, outstanding from public.salary_advances where employee_id = x.employee_id and status = 'active'
                order by advance_date for update loop
        exit when v_left <= 0;
        v_take := least(a.installment, a.outstanding, v_left);
        insert into public.advance_recoveries (advance_id, payslip_id, amount) values (a.id, x.payslip_id, v_take);
        update public.salary_advances set outstanding = outstanding - v_take,
               status = case when outstanding - v_take <= 0 then 'settled' else 'active' end where id = a.id;
        v_left := v_left - v_take;
      end loop;
    end;
  end loop;

  -- [3B] mark the commissions as paid through this payroll
  update public.commission_statements cs set status = 'paid', paid_via = 'payroll', payslip_id = l.payslip_id, paid_at = now()
    from public.payslip_lines l join public.payslips s on s.id = l.payslip_id
   where s.run_id = r.id and l.source = 'commission' and l.commission_statement_id = cs.id;

  update public.payroll_runs set status = 'approved', approved_by = app.current_user_id(), approved_at = now(),
         decision_note = nullif(trim(p_note), ''), journal_entry_id = v_je where id = r.id;
  return jsonb_build_object('status', 'approved', 'entry_no', (select entry_no from public.journal_entries where id = v_je));
end $$;

-- >>> 20261008000042_distributors.sql
-- =====================================================================
-- OLA Water ERP — Phase 3B
-- 0042: distributors / dealers — profile on top of their customer
--       account (price list, credit, orders, invoices, payments and
--       bottles stay on the customer), territory, agreement, monthly
--       targets, and stock they report holding
-- =====================================================================

create table public.distributors (
  id               uuid primary key default gen_random_uuid(),
  customer_id      uuid not null unique references public.customers(id),
  code             text not null unique check (code ~ '^[A-Z0-9_-]{2,12}$'),
  kind             text not null default 'distributor' check (kind in ('distributor','dealer','wholesaler')),
  territory_id     uuid references public.territories(id),
  manager_id       uuid references public.profiles(id),        -- staff member who looks after them
  agreement_start  date,
  agreement_end    date,
  monthly_target   numeric(14,2) not null default 0 check (monthly_target >= 0),
  min_stock_19l    integer,                                    -- agreed minimum 19L stock to hold
  exclusive        boolean not null default false,
  status           text not null default 'active' check (status in ('active','suspended','ended')),
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (agreement_end is null or agreement_start is null or agreement_end >= agreement_start)
);
create trigger distributors_touch before update on public.distributors for each row execute function app.touch_updated_at();
create trigger distributors_audit after insert or update on public.distributors for each row execute function app.audit_row('distributors');

create table public.distributor_stock_reports (
  id              uuid primary key default gen_random_uuid(),
  distributor_id  uuid not null references public.distributors(id),
  report_date     date not null,
  lines           jsonb not null,        -- [{product_id, qty}]
  empty_bottles   integer,
  notes           text,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  unique (distributor_id, report_date)
);
create trigger distributor_stock_reports_append_only before update or delete on public.distributor_stock_reports for each row execute function app.forbid_change();
create trigger distributor_stock_reports_audit after insert on public.distributor_stock_reports for each row execute function app.audit_row('distributors');

-- p: customer_id, code, kind, territory_id, manager_id, agreement_start, agreement_end, monthly_target, min_stock_19l, exclusive, status, notes
create or replace function public.save_distributor(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; c public.customers;
begin
  perform app.require_permission('distributors.manage');
  if app.jtext(p, 'code') is null then raise exception 'Enter a distributor code' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    select * into c from public.customers where id = app.juuid(p, 'customer_id');
    if not found then raise exception 'Choose the customer account the distributor buys on (create it under Customers first)' using errcode = '22023'; end if;
    insert into public.distributors (customer_id, code, kind, territory_id, manager_id, agreement_start, agreement_end, monthly_target,
      min_stock_19l, exclusive, notes)
    values (c.id, upper(app.jtext(p, 'code')), coalesce(app.jtext(p, 'kind'), 'distributor'), app.juuid(p, 'territory_id'), app.juuid(p, 'manager_id'),
      (app.jtext(p, 'agreement_start'))::date, (app.jtext(p, 'agreement_end'))::date, coalesce(app.jnum(p, 'monthly_target'), 0),
      app.jint(p, 'min_stock_19l'), app.jbool(p, 'exclusive', false), app.jtext(p, 'notes'))
    returning id into v;
  else
    update public.distributors set code = upper(app.jtext(p, 'code')), kind = coalesce(app.jtext(p, 'kind'), kind),
      territory_id = app.juuid(p, 'territory_id'), manager_id = app.juuid(p, 'manager_id'),
      agreement_start = (app.jtext(p, 'agreement_start'))::date, agreement_end = (app.jtext(p, 'agreement_end'))::date,
      monthly_target = coalesce(app.jnum(p, 'monthly_target'), 0), min_stock_19l = app.jint(p, 'min_stock_19l'),
      exclusive = app.jbool(p, 'exclusive', false), status = coalesce(app.jtext(p, 'status'), status), notes = app.jtext(p, 'notes')
     where id = p_id returning id into v;
    if v is null then raise exception 'Distributor not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

create or replace function public.record_distributor_stock(p_distributor uuid, p_date date, p_lines jsonb, p_empty integer, p_notes text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; x jsonb; v_clean jsonb := '[]';
begin
  perform app.require_permission('distributors.manage');
  if coalesce(p_date, app.today()) > app.today() then raise exception 'The count cannot be in the future' using errcode = '22023'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    continue when app.juuid(x, 'product_id') is null or app.jnum(x, 'qty') is null;
    if app.jnum(x, 'qty') < 0 then raise exception 'Quantities cannot be negative' using errcode = '22023'; end if;
    v_clean := v_clean || jsonb_build_object('product_id', app.juuid(x, 'product_id'), 'qty', app.jnum(x, 'qty'));
  end loop;
  if jsonb_array_length(v_clean) = 0 and p_empty is null then raise exception 'Enter at least one count' using errcode = '22023'; end if;
  insert into public.distributor_stock_reports (distributor_id, report_date, lines, empty_bottles, notes, created_by)
  values (p_distributor, coalesce(p_date, app.today()), v_clean, p_empty, nullif(trim(p_notes), ''), app.current_user_id())
  returning id into v;
  return v;
end $$;

alter table public.distributors              enable row level security;
alter table public.distributor_stock_reports enable row level security;
create policy distributors_read on public.distributors for select to authenticated
  using (app.has_permission('distributors.manage') or app.has_permission('customers.view'));
create policy distributor_stock_reports_read on public.distributor_stock_reports for select to authenticated
  using (app.has_permission('distributors.manage'));

-- >>> 20261008000043_crm.sql
-- =====================================================================
-- OLA Water ERP — Phase 3B
-- 0043: CRM — leads and prospects, follow-ups / activities,
--       opportunities, customer segments, campaigns (with SMS to a
--       segment), promotions applied automatically to orders, and
--       conversion tracking (lead → customer → first sale)
-- =====================================================================

create table public.customer_segments (
  id           uuid primary key default gen_random_uuid(),
  name         text not null unique check (length(trim(name)) > 0),
  description  text,
  rules        jsonb not null default '{}',
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now()
);
comment on column public.customer_segments.rules is
  '{customer_types[], route_ids[], sales_rep_ids[], bottle_models[], cities[], min_days_since_order, max_days_since_order, has_overdue, created_after, min_monthly_sales}';
create trigger customer_segments_touch before update on public.customer_segments for each row execute function app.touch_updated_at();
create trigger customer_segments_audit after insert or update on public.customer_segments for each row execute function app.audit_row('crm');

create table public.promotions (
  id             uuid primary key default gen_random_uuid(),
  code           text not null unique check (code ~ '^[A-Z0-9_-]{2,16}$'),
  name           text not null,
  kind           text not null check (kind in ('percent','amount_per_unit','fixed_price','buy_x_get_y')),
  value          numeric(12,2) not null check (value > 0),     -- %, Rs. off per unit, special unit price, or free units
  buy_qty        integer check (buy_qty > 0),                  -- buy_x_get_y: buy this many
  product_id     uuid references public.products(id),          -- null = every product
  customer_types text[],                                       -- null = every type
  segment_id     uuid references public.customer_segments(id),
  price_list_id  uuid references public.price_lists(id),
  min_qty        numeric(12,3) not null default 0,
  start_date     date not null,
  end_date       date not null,
  status         text not null default 'draft' check (status in ('draft','active','ended')),
  approved_by    uuid,
  approved_at    timestamptz,
  notes          text,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  check (end_date >= start_date),
  check (kind <> 'percent' or value <= 100),
  check (kind <> 'buy_x_get_y' or buy_qty is not null)
);
create trigger promotions_touch before update on public.promotions for each row execute function app.touch_updated_at();
create trigger promotions_audit after insert or update on public.promotions for each row execute function app.audit_row('crm');

create table public.campaigns (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique check (code ~ '^[A-Z0-9_-]{2,16}$'),
  name          text not null,
  channel       text not null check (channel in ('sms','whatsapp','facebook','instagram','flyers','radio','event','field','referral','other')),
  objective     text,
  segment_id    uuid references public.customer_segments(id),
  promotion_id  uuid references public.promotions(id),
  start_date    date not null,
  end_date      date,
  budget        numeric(14,2) not null default 0 check (budget >= 0),
  spent         numeric(14,2) not null default 0 check (spent >= 0),
  status        text not null default 'planned' check (status in ('planned','active','completed','cancelled')),
  notes         text,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now()
);
create trigger campaigns_touch before update on public.campaigns for each row execute function app.touch_updated_at();
create trigger campaigns_audit after insert or update on public.campaigns for each row execute function app.audit_row('crm');

create table public.leads (
  id                   uuid primary key default gen_random_uuid(),
  lead_no              text not null unique,
  name                 text not null check (length(trim(name)) > 0),
  company_name         text,
  contact_person       text,
  phone                text check (phone ~ '^\+[1-9][0-9]{7,14}$'),
  email                text,
  address_line         text,
  city                 text,
  gps_lat              numeric(9,6),
  gps_lng              numeric(9,6),
  customer_type        text references public.customer_type_defaults(customer_type),
  source               text not null default 'phone' check (source in ('phone','walk_in','referral','website','facebook','instagram','whatsapp','campaign','field_visit','event','other')),
  campaign_id          uuid references public.campaigns(id),
  territory_id         uuid references public.territories(id),
  owner_id             uuid references public.profiles(id),
  status               text not null default 'new' check (status in ('new','contacted','qualified','proposal','won','lost')),
  est_monthly_bottles  integer check (est_monthly_bottles >= 0),
  est_monthly_value    numeric(14,2) check (est_monthly_value >= 0),
  next_follow_up       date,
  lost_reason          text,
  customer_id          uuid references public.customers(id),
  converted_at         timestamptz,
  notes                text,
  created_at           timestamptz not null default now(),
  created_by           uuid,
  updated_at           timestamptz not null default now(),
  check (phone is not null or email is not null or address_line is not null)
);
create index leads_status_idx on public.leads (status, next_follow_up);
create index leads_phone_idx on public.leads (phone);
create trigger leads_touch before update on public.leads for each row execute function app.touch_updated_at();
create trigger leads_audit after insert or update on public.leads for each row execute function app.audit_row('crm');

alter table public.rep_visits add constraint rep_visits_lead_fk foreign key (lead_id) references public.leads(id);
alter table public.customers add column lead_id uuid references public.leads(id);
alter table public.customers add column campaign_id uuid references public.campaigns(id);

create table public.opportunities (
  id              uuid primary key default gen_random_uuid(),
  opp_no          text not null unique,
  title           text not null check (length(trim(title)) > 0),
  lead_id         uuid references public.leads(id),
  customer_id     uuid references public.customers(id),
  owner_id        uuid references public.profiles(id),
  stage           text not null default 'prospecting' check (stage in ('prospecting','proposal','negotiation','won','lost')),
  monthly_value   numeric(14,2) not null default 0 check (monthly_value >= 0),
  probability     integer not null default 20 check (probability between 0 and 100),
  expected_close  date,
  lost_reason     text,
  closed_at       timestamptz,
  notes           text,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  check (lead_id is not null or customer_id is not null)
);
create trigger opportunities_touch before update on public.opportunities for each row execute function app.touch_updated_at();
create trigger opportunities_audit after insert or update on public.opportunities for each row execute function app.audit_row('crm');

create table public.crm_activities (
  id              uuid primary key default gen_random_uuid(),
  lead_id         uuid references public.leads(id),
  customer_id     uuid references public.customers(id),
  opportunity_id  uuid references public.opportunities(id),
  kind            text not null check (kind in ('call','visit','whatsapp','sms','email','meeting','note','task')),
  subject         text not null check (length(trim(subject)) > 0),
  notes           text,
  due_on          date,
  done_at         timestamptz,
  outcome         text,
  owner_id        uuid references public.profiles(id),
  created_at      timestamptz not null default now(),
  created_by      uuid,
  check (lead_id is not null or customer_id is not null or opportunity_id is not null)
);
create index crm_activities_due_idx on public.crm_activities (owner_id, due_on) where done_at is null;
create trigger crm_activities_audit after insert or update on public.crm_activities for each row execute function app.audit_row('crm');

alter table public.order_items add column promotion_id uuid references public.promotions(id);
alter table public.order_items add column promo_discount numeric(12,2) not null default 0 check (promo_discount >= 0);

-- ---------------------------------------------------------------------
-- Segments
-- ---------------------------------------------------------------------
create or replace function app.segment_customer_ids(p_rules jsonb)
returns setof uuid language sql stable security definer set search_path = '' as $$
  with last_order as (select customer_id, max(invoice_date) last_date from public.invoices where status <> 'void' group by customer_id),
       avg_sales as (select customer_id, sum(subtotal_net) / 3 avg_net from public.invoices
                      where status <> 'void' and invoice_date >= app.today() - 90 group by customer_id)
  select c.id from public.customers c
    left join last_order lo on lo.customer_id = c.id
    left join avg_sales s on s.customer_id = c.id
   where c.status = 'active' and not c.is_walk_in
     and (jsonb_array_length(coalesce(p_rules -> 'customer_types', '[]')) = 0 or c.customer_type in (select jsonb_array_elements_text(p_rules -> 'customer_types')))
     and (jsonb_array_length(coalesce(p_rules -> 'route_ids', '[]')) = 0 or c.route_id::text in (select jsonb_array_elements_text(p_rules -> 'route_ids')))
     and (jsonb_array_length(coalesce(p_rules -> 'sales_rep_ids', '[]')) = 0 or c.sales_rep_id::text in (select jsonb_array_elements_text(p_rules -> 'sales_rep_ids')))
     and (jsonb_array_length(coalesce(p_rules -> 'bottle_models', '[]')) = 0 or c.bottle_model in (select jsonb_array_elements_text(p_rules -> 'bottle_models')))
     and (jsonb_array_length(coalesce(p_rules -> 'cities', '[]')) = 0 or exists (
            select 1 from public.customer_addresses a where a.customer_id = c.id and a.is_active
               and lower(a.city) in (select lower(jsonb_array_elements_text(p_rules -> 'cities')))))
     and (app.jint(p_rules, 'min_days_since_order') is null or coalesce(lo.last_date, date '1900-01-01') <= app.today() - app.jint(p_rules, 'min_days_since_order'))
     and (app.jint(p_rules, 'max_days_since_order') is null or lo.last_date >= app.today() - app.jint(p_rules, 'max_days_since_order'))
     and (app.jbool(p_rules, 'has_overdue', null) is null or app.jbool(p_rules, 'has_overdue', null) = exists (
            select 1 from public.invoices i where i.customer_id = c.id and i.status in ('open','partially_paid') and i.balance > 0 and i.due_date < app.today()))
     and (app.jtext(p_rules, 'created_after') is null or c.created_at >= (app.jtext(p_rules, 'created_after'))::date)
     and (app.jnum(p_rules, 'min_monthly_sales') is null or coalesce(s.avg_net, 0) >= app.jnum(p_rules, 'min_monthly_sales'))
$$;

create or replace function app.segment_has(p_segment uuid, p_customer uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.customer_segments s, app.segment_customer_ids(s.rules) x(id)
                  where s.id = p_segment and s.is_active and x.id = p_customer)
$$;

create or replace function public.save_segment(p_id uuid, p_name text, p_description text, p_rules jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform app.require_permission('crm.manage');
  if nullif(trim(p_name), '') is null then raise exception 'Name the segment' using errcode = '22023'; end if;
  if p_id is null then
    insert into public.customer_segments (name, description, rules, created_by) values (trim(p_name), p_description, coalesce(p_rules, '{}'), app.current_user_id())
    returning id into v;
  else
    update public.customer_segments set name = trim(p_name), description = p_description, rules = coalesce(p_rules, '{}') where id = p_id returning id into v;
    if v is null then raise exception 'Segment not found' using errcode = 'P0002'; end if;
  end if;
  return jsonb_build_object('segment_id', v, 'customers', (select count(*) from app.segment_customer_ids(coalesce(p_rules, '{}'))));
end $$;

create or replace function public.segment_preview(p_rules jsonb, p_limit integer default 50)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not app.has_permission('crm.manage') then null else jsonb_build_object(
    'count', (select count(*) from app.segment_customer_ids(coalesce(p_rules, '{}'))),
    'with_phone', (select count(*) from app.segment_customer_ids(coalesce(p_rules, '{}')) x(id) join public.customers c on c.id = x.id
                    where not c.messages_opt_out),
    'sample', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'customer_no', c.customer_no, 'type', c.customer_type)), '[]')
                 from (select c.* from app.segment_customer_ids(coalesce(p_rules, '{}')) x(id) join public.customers c on c.id = x.id
                        order by c.name limit p_limit) c)) end
$$;

-- ---------------------------------------------------------------------
-- Promotions (applied automatically to order lines)
-- ---------------------------------------------------------------------
create or replace function app.promotion_discount(p_product uuid, p_customer uuid, p_qty numeric, p_price numeric, p_date date)
returns table (promotion_id uuid, amount numeric) language plpgsql stable security definer set search_path = '' as $$
declare c public.customers; pr record; v_best uuid; v_amt numeric := 0; a numeric;
begin
  select * into c from public.customers where id = p_customer;
  for pr in select * from public.promotions p
             where p.status = 'active' and p_date between p.start_date and p.end_date
               and (p.product_id is null or p.product_id = p_product)
               and (p.price_list_id is null or p.price_list_id = c.price_list_id)
               and (p.customer_types is null or cardinality(p.customer_types) = 0 or c.customer_type = any(p.customer_types))
               and p_qty >= p.min_qty loop
    continue when pr.segment_id is not null and not app.segment_has(pr.segment_id, p_customer);
    a := case pr.kind
           when 'percent' then round(p_qty * p_price * pr.value / 100, 2)
           when 'amount_per_unit' then round(least(pr.value, p_price) * p_qty, 2)
           when 'fixed_price' then round(greatest(p_price - pr.value, 0) * p_qty, 2)
           when 'buy_x_get_y' then round(floor(p_qty / (pr.buy_qty + pr.value)) * pr.value * p_price, 2) end;
    if a > v_amt then v_amt := a; v_best := pr.id; end if;
  end loop;
  return query select v_best, least(v_amt, round(p_qty * p_price, 2));
end $$;

-- p: code, name, kind, value, buy_qty, product_id, customer_types[], segment_id, price_list_id, min_qty, start_date, end_date, notes
create or replace function public.save_promotion(p_id uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; o public.promotions;
begin
  perform app.require_permission('crm.manage');
  if app.jtext(p, 'code') is null or app.jtext(p, 'name') is null then raise exception 'Enter a code and a name' using errcode = '22023'; end if;
  if p_id is not null then
    select * into o from public.promotions where id = p_id for update;
    if not found then raise exception 'Promotion not found' using errcode = 'P0002'; end if;
    if o.status <> 'draft' then raise exception 'An active promotion cannot be changed — end it and create a new one' using errcode = '22023'; end if;
  end if;
  if p_id is null then
    insert into public.promotions (code, name, kind, value, buy_qty, product_id, customer_types, segment_id, price_list_id, min_qty, start_date, end_date, notes, created_by)
    values (upper(app.jtext(p, 'code')), app.jtext(p, 'name'), app.jtext(p, 'kind'), app.jnum(p, 'value'), app.jint(p, 'buy_qty'),
      app.juuid(p, 'product_id'), nullif((select array_agg(x) from jsonb_array_elements_text(coalesce(p -> 'customer_types', '[]')) x), '{}'),
      app.juuid(p, 'segment_id'), app.juuid(p, 'price_list_id'), coalesce(app.jnum(p, 'min_qty'), 0),
      (app.jtext(p, 'start_date'))::date, (app.jtext(p, 'end_date'))::date, app.jtext(p, 'notes'), app.current_user_id())
    returning id into v;
  else
    update public.promotions set code = upper(app.jtext(p, 'code')), name = app.jtext(p, 'name'), kind = app.jtext(p, 'kind'), value = app.jnum(p, 'value'),
      buy_qty = app.jint(p, 'buy_qty'), product_id = app.juuid(p, 'product_id'),
      customer_types = nullif((select array_agg(x) from jsonb_array_elements_text(coalesce(p -> 'customer_types', '[]')) x), '{}'),
      segment_id = app.juuid(p, 'segment_id'), price_list_id = app.juuid(p, 'price_list_id'), min_qty = coalesce(app.jnum(p, 'min_qty'), 0),
      start_date = (app.jtext(p, 'start_date'))::date, end_date = (app.jtext(p, 'end_date'))::date, notes = app.jtext(p, 'notes')
     where id = p_id returning id into v;
  end if;
  return v;
end $$;

-- Switching a promotion on is a price change: it needs the price approver (see Approvals → Rules).
create or replace function public.activate_promotion(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.promotions;
begin
  perform app.require_permission('crm.manage');
  select * into o from public.promotions where id = p_id for update;
  if not found then raise exception 'Promotion not found' using errcode = 'P0002'; end if;
  if o.status <> 'draft' then raise exception 'Only a draft promotion can be switched on' using errcode = '22023'; end if;
  if o.end_date < app.today() then raise exception 'This promotion has already ended' using errcode = '22023'; end if;
  perform app.require_approval('promotion', 'Switching on a promotion needs approval');
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Promotion switched on'), null, 'activate');
  update public.promotions set status = 'active', approved_by = app.current_user_id(), approved_at = now() where id = p_id;
end $$;

create or replace function public.end_promotion(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_permission('crm.manage');
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Promotion ended'), null, null);
  update public.promotions set status = 'ended', end_date = least(end_date, app.today()) where id = p_id and status in ('draft','active');
  if not found then raise exception 'Promotion not found or already ended' using errcode = '22023'; end if;
end $$;

-- ---------------------------------------------------------------------
-- Campaigns
-- ---------------------------------------------------------------------
create or replace function public.save_campaign(p_id uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform app.require_permission('crm.manage');
  if app.jtext(p, 'code') is null or app.jtext(p, 'name') is null then raise exception 'Enter a code and a name' using errcode = '22023'; end if;
  if p_id is null then
    insert into public.campaigns (code, name, channel, objective, segment_id, promotion_id, start_date, end_date, budget, spent, notes, created_by)
    values (upper(app.jtext(p, 'code')), app.jtext(p, 'name'), coalesce(app.jtext(p, 'channel'), 'other'), app.jtext(p, 'objective'),
      app.juuid(p, 'segment_id'), app.juuid(p, 'promotion_id'), coalesce((app.jtext(p, 'start_date'))::date, app.today()),
      (app.jtext(p, 'end_date'))::date, coalesce(app.jnum(p, 'budget'), 0), coalesce(app.jnum(p, 'spent'), 0), app.jtext(p, 'notes'), app.current_user_id())
    returning id into v;
  else
    update public.campaigns set code = upper(app.jtext(p, 'code')), name = app.jtext(p, 'name'), channel = coalesce(app.jtext(p, 'channel'), channel),
      objective = app.jtext(p, 'objective'), segment_id = app.juuid(p, 'segment_id'), promotion_id = app.juuid(p, 'promotion_id'),
      start_date = coalesce((app.jtext(p, 'start_date'))::date, start_date), end_date = (app.jtext(p, 'end_date'))::date,
      budget = coalesce(app.jnum(p, 'budget'), 0), spent = coalesce(app.jnum(p, 'spent'), 0), status = coalesce(app.jtext(p, 'status'), status),
      notes = app.jtext(p, 'notes')
     where id = p_id returning id into v;
    if v is null then raise exception 'Campaign not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

-- Queue an SMS / WhatsApp to every customer in the campaign's segment (once per customer per campaign).
create or replace function public.send_campaign_message(p_campaign uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare cp public.campaigns; seg public.customer_segments; c record; n integer := 0; v_skipped integer := 0; v_max integer; v_vars jsonb; v_id uuid;
        v_channel text;
begin
  perform app.require_permission('crm.manage');
  select * into cp from public.campaigns where id = p_campaign;
  if not found then raise exception 'Campaign not found' using errcode = 'P0002'; end if;
  if cp.status in ('completed','cancelled') then raise exception 'This campaign is %', cp.status using errcode = '22023'; end if;
  if nullif(trim(p_body), '') is null then raise exception 'Write the message' using errcode = '22023'; end if;
  if length(p_body) > 480 then raise exception 'Keep the message under 480 characters (3 SMS)' using errcode = '22023'; end if;
  if not coalesce((app.get_setting('messaging.enabled') #>> '{}')::boolean, false) then
    raise exception 'Customer messages are switched off (Messages & Alerts)' using errcode = '22023';
  end if;
  select * into seg from public.customer_segments where id = cp.segment_id;
  if seg.id is null then raise exception 'Choose the customer segment for this campaign first' using errcode = '22023'; end if;
  v_max := coalesce((app.get_setting('crm.max_campaign_messages') #>> '{}')::integer, 2000);
  if (select count(*) from app.segment_customer_ids(seg.rules)) > v_max then
    raise exception 'The segment has more than % customers — narrow it, or raise the limit in System Settings', v_max using errcode = '22023';
  end if;
  v_channel := case when cp.channel = 'whatsapp' then 'whatsapp' else 'sms' end;
  perform app.set_context('Campaign message ' || cp.code, null, 'campaign_message');
  for c in select cu.* from app.segment_customer_ids(seg.rules) x(id) join public.customers cu on cu.id = x.id loop
    if c.messages_opt_out then v_skipped := v_skipped + 1; continue; end if;
    v_vars := jsonb_build_object('customer_name', c.name, 'customer_no', c.customer_no,
                'company_name', coalesce(app.get_setting('company.name') #>> '{}', 'OLA Water'),
                'company_phone', coalesce(app.get_setting('company.phone') #>> '{}', ''));
    v_id := null;
    insert into public.message_outbox (channel, to_address, to_name, body, customer_id, related_type, related_id, dedupe_key, created_by)
    values (v_channel, c.phone, c.name, app.render_template(p_body, v_vars), c.id, 'campaign', cp.id, 'campaign:' || cp.id || ':' || c.id, app.current_user_id())
    on conflict (dedupe_key) do nothing returning id into v_id;
    if v_id is null then v_skipped := v_skipped + 1; else n := n + 1; end if;
  end loop;
  update public.campaigns set status = case when status = 'planned' then 'active' else status end where id = cp.id;
  return jsonb_build_object('queued', n, 'skipped', v_skipped);
end $$;

-- ---------------------------------------------------------------------
-- Leads, activities, opportunities
-- p: name, company_name, contact_person, phone, email, address_line, city, gps_lat, gps_lng, customer_type, source, campaign_id,
--    territory_id, owner_id, status, est_monthly_bottles, est_monthly_value, next_follow_up, notes
-- ---------------------------------------------------------------------
create or replace function public.save_lead(p_id uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid; v_no text; v_phone text := app.normalize_phone(app.jtext(p, 'phone')); c public.customers; o public.leads; v_status text;
begin
  perform app.require_permission('crm.manage');
  if app.jtext(p, 'name') is null then raise exception 'Enter a name' using errcode = '22023'; end if;
  if app.jtext(p, 'phone') is not null and v_phone is null then raise exception 'The phone number is not valid' using errcode = '22023'; end if;
  if v_phone is not null then
    select * into c from public.customers where (phone = v_phone or phone2 = v_phone) and status <> 'inactive' limit 1;
    if found then raise exception '% is already a customer (%)', c.name, c.customer_no using errcode = '23505'; end if;
  end if;
  if p_id is not null then
    select * into o from public.leads where id = p_id for update;
    if not found then raise exception 'Lead not found' using errcode = 'P0002'; end if;
    if o.status = 'won' then raise exception 'This lead is already a customer' using errcode = '22023'; end if;
  end if;
  v_status := coalesce(app.jtext(p, 'status'), o.status, 'new');
  if v_status = 'won' then raise exception 'Use "Make customer" to win a lead' using errcode = '22023'; end if;
  if v_status = 'lost' and app.jtext(p, 'lost_reason') is null then raise exception 'Say why the lead was lost' using errcode = '22023'; end if;
  if p_id is null then
    v_no := app.next_document_number('LEAD');
    insert into public.leads (lead_no, name, company_name, contact_person, phone, email, address_line, city, gps_lat, gps_lng, customer_type, source,
      campaign_id, territory_id, owner_id, status, est_monthly_bottles, est_monthly_value, next_follow_up, notes, created_by)
    values (v_no, app.jtext(p, 'name'), app.jtext(p, 'company_name'), app.jtext(p, 'contact_person'), v_phone, lower(app.jtext(p, 'email')),
      app.jtext(p, 'address_line'), app.jtext(p, 'city'), app.jnum(p, 'gps_lat'), app.jnum(p, 'gps_lng'), app.jtext(p, 'customer_type'),
      coalesce(app.jtext(p, 'source'), 'phone'), app.juuid(p, 'campaign_id'), app.juuid(p, 'territory_id'),
      coalesce(app.juuid(p, 'owner_id'), app.current_user_id()), v_status, app.jint(p, 'est_monthly_bottles'), app.jnum(p, 'est_monthly_value'),
      (app.jtext(p, 'next_follow_up'))::date, app.jtext(p, 'notes'), app.current_user_id())
    returning id into v;
    if app.juuid(p, 'owner_id') is not null and app.juuid(p, 'owner_id') <> app.current_user_id() then
      perform app.notify('lead_assigned', 'New lead for you: ' || app.jtext(p, 'name'), app.jtext(p, 'notes'), '/crm/leads/' || v,
        'lead:' || v, app.juuid(p, 'owner_id'));
    end if;
  else
    update public.leads set name = app.jtext(p, 'name'), company_name = app.jtext(p, 'company_name'), contact_person = app.jtext(p, 'contact_person'),
      phone = v_phone, email = lower(app.jtext(p, 'email')), address_line = app.jtext(p, 'address_line'), city = app.jtext(p, 'city'),
      gps_lat = coalesce(app.jnum(p, 'gps_lat'), gps_lat), gps_lng = coalesce(app.jnum(p, 'gps_lng'), gps_lng),
      customer_type = app.jtext(p, 'customer_type'), source = coalesce(app.jtext(p, 'source'), source), campaign_id = app.juuid(p, 'campaign_id'),
      territory_id = app.juuid(p, 'territory_id'), owner_id = coalesce(app.juuid(p, 'owner_id'), owner_id), status = v_status,
      est_monthly_bottles = app.jint(p, 'est_monthly_bottles'), est_monthly_value = app.jnum(p, 'est_monthly_value'),
      next_follow_up = (app.jtext(p, 'next_follow_up'))::date, lost_reason = case when v_status = 'lost' then app.jtext(p, 'lost_reason') end,
      notes = app.jtext(p, 'notes')
     where id = p_id;
    v := p_id;
    if o.owner_id is distinct from app.juuid(p, 'owner_id') and app.juuid(p, 'owner_id') is not null and app.juuid(p, 'owner_id') <> app.current_user_id() then
      perform app.notify('lead_assigned', 'Lead passed to you: ' || app.jtext(p, 'name'), null, '/crm/leads/' || v,
        'lead:' || v || ':' || app.juuid(p, 'owner_id'), app.juuid(p, 'owner_id'));
    end if;
  end if;
  return jsonb_build_object('lead_id', v, 'lead_no', coalesce(v_no, o.lead_no));
end $$;

-- Win a lead: create the customer (credit terms go through approval as usual) and keep the link for conversion reports.
-- p: customer payload for save_customer (name, phone, customer_type … address)
create or replace function public.convert_lead(p_lead uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare l public.leads; v_cust uuid; v_payload jsonb;
begin
  perform app.require_permission('crm.manage');
  perform app.require_permission('customers.manage');
  select * into l from public.leads where id = p_lead for update;
  if not found then raise exception 'Lead not found' using errcode = 'P0002'; end if;
  if l.status = 'won' then raise exception 'Already a customer' using errcode = '22023'; end if;
  v_payload := jsonb_strip_nulls(jsonb_build_object('name', l.name, 'company_name', l.company_name, 'contact_person', l.contact_person,
                 'phone', l.phone, 'email', l.email, 'customer_type', l.customer_type, 'notes', l.notes,
                 'address', case when l.address_line is not null then jsonb_build_object('address_line', l.address_line, 'city', l.city,
                                  'gps_lat', l.gps_lat, 'gps_lng', l.gps_lng) end)) || coalesce(jsonb_strip_nulls(p), '{}');
  v_cust := public.save_customer(null, v_payload, 'Converted from lead ' || l.lead_no);
  update public.customers set lead_id = l.id, campaign_id = l.campaign_id,
         sales_rep_id = coalesce(sales_rep_id, (select profile_id from public.sales_reps where profile_id = l.owner_id)) where id = v_cust;
  update public.leads set status = 'won', customer_id = v_cust, converted_at = now(), next_follow_up = null where id = l.id;
  update public.opportunities set customer_id = v_cust where lead_id = l.id;
  update public.crm_activities set customer_id = v_cust where lead_id = l.id;
  return jsonb_build_object('customer_id', v_cust);
end $$;

-- p: lead_id | customer_id | opportunity_id, kind, subject, notes, due_on, done (boolean), outcome, owner_id
create or replace function public.log_crm_activity(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  if not (app.has_permission('crm.manage') or app.has_permission('customers.manage')) then raise exception 'Permission denied' using errcode = '42501'; end if;
  if app.jtext(p, 'subject') is null then raise exception 'Write what it is about' using errcode = '22023'; end if;
  insert into public.crm_activities (lead_id, customer_id, opportunity_id, kind, subject, notes, due_on, done_at, outcome, owner_id, created_by)
  values (app.juuid(p, 'lead_id'), app.juuid(p, 'customer_id'), app.juuid(p, 'opportunity_id'), coalesce(app.jtext(p, 'kind'), 'note'),
    app.jtext(p, 'subject'), app.jtext(p, 'notes'), (app.jtext(p, 'due_on'))::date,
    case when app.jbool(p, 'done', true) then now() end, app.jtext(p, 'outcome'),
    coalesce(app.juuid(p, 'owner_id'), app.current_user_id()), app.current_user_id())
  returning id into v;
  if app.juuid(p, 'lead_id') is not null then
    update public.leads set status = case when status = 'new' and app.jbool(p, 'done', true) then 'contacted' else status end,
           next_follow_up = case when not app.jbool(p, 'done', true) and app.jtext(p, 'due_on') is not null
                                 then least(coalesce(next_follow_up, (app.jtext(p, 'due_on'))::date), (app.jtext(p, 'due_on'))::date) else next_follow_up end
     where id = app.juuid(p, 'lead_id');
  end if;
  return v;
end $$;

create or replace function public.complete_crm_activity(p_id uuid, p_outcome text)
returns void language plpgsql security definer set search_path = '' as $$
declare a public.crm_activities;
begin
  if not (app.has_permission('crm.manage') or app.has_permission('customers.manage')) then raise exception 'Permission denied' using errcode = '42501'; end if;
  select * into a from public.crm_activities where id = p_id for update;
  if not found then raise exception 'Not found' using errcode = 'P0002'; end if;
  if a.done_at is not null then raise exception 'Already done' using errcode = '22023'; end if;
  update public.crm_activities set done_at = now(), outcome = nullif(trim(p_outcome), '') where id = p_id;
  if a.lead_id is not null then
    update public.leads set status = case when status = 'new' then 'contacted' else status end,
      next_follow_up = (select min(due_on) from public.crm_activities where lead_id = a.lead_id and done_at is null)
     where id = a.lead_id;
  end if;
end $$;

-- p: title, lead_id, customer_id, owner_id, stage, monthly_value, probability, expected_close, lost_reason, notes
create or replace function public.save_opportunity(p_id uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; o public.opportunities; v_stage text;
begin
  perform app.require_permission('crm.manage');
  if app.jtext(p, 'title') is null then raise exception 'Give the opportunity a title' using errcode = '22023'; end if;
  v_stage := coalesce(app.jtext(p, 'stage'), 'prospecting');
  if v_stage = 'lost' and app.jtext(p, 'lost_reason') is null then raise exception 'Say why it was lost' using errcode = '22023'; end if;
  if p_id is null then
    insert into public.opportunities (opp_no, title, lead_id, customer_id, owner_id, stage, monthly_value, probability, expected_close, lost_reason,
      closed_at, notes, created_by)
    values (app.next_document_number('OPP'), app.jtext(p, 'title'), app.juuid(p, 'lead_id'), app.juuid(p, 'customer_id'),
      coalesce(app.juuid(p, 'owner_id'), app.current_user_id()), v_stage, coalesce(app.jnum(p, 'monthly_value'), 0),
      coalesce(app.jint(p, 'probability'), case v_stage when 'won' then 100 when 'lost' then 0 when 'negotiation' then 60 when 'proposal' then 40 else 20 end),
      (app.jtext(p, 'expected_close'))::date, app.jtext(p, 'lost_reason'), case when v_stage in ('won','lost') then now() end, app.jtext(p, 'notes'),
      app.current_user_id())
    returning id into v;
  else
    select * into o from public.opportunities where id = p_id for update;
    if not found then raise exception 'Opportunity not found' using errcode = 'P0002'; end if;
    update public.opportunities set title = app.jtext(p, 'title'), owner_id = coalesce(app.juuid(p, 'owner_id'), owner_id), stage = v_stage,
      monthly_value = coalesce(app.jnum(p, 'monthly_value'), monthly_value),
      probability = coalesce(app.jint(p, 'probability'), case v_stage when 'won' then 100 when 'lost' then 0 else probability end),
      expected_close = (app.jtext(p, 'expected_close'))::date, lost_reason = case when v_stage = 'lost' then app.jtext(p, 'lost_reason') end,
      closed_at = case when v_stage in ('won','lost') then coalesce(closed_at, now()) end, notes = app.jtext(p, 'notes')
     where id = p_id returning id into v;
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.customer_segments enable row level security;
alter table public.promotions        enable row level security;
alter table public.campaigns         enable row level security;
alter table public.leads             enable row level security;
alter table public.opportunities     enable row level security;
alter table public.crm_activities    enable row level security;
create policy customer_segments_read on public.customer_segments for select to authenticated using (app.has_permission('crm.manage'));
create policy promotions_read on public.promotions for select to authenticated
  using (app.has_permission('crm.manage') or app.has_permission('orders.view') or app.has_permission('prices.approve') or app.has_permission('products.view'));
create policy campaigns_read on public.campaigns for select to authenticated using (app.has_permission('crm.manage') or app.has_permission('customers.view'));
create policy leads_read on public.leads for select to authenticated
  using (app.has_permission('crm.manage') or app.has_permission('sales_reps.manage') or owner_id = app.current_user_id());
create policy opportunities_read on public.opportunities for select to authenticated
  using (app.has_permission('crm.manage') or app.has_permission('sales_reps.manage') or owner_id = app.current_user_id());
create policy crm_activities_read on public.crm_activities for select to authenticated
  using (app.has_permission('crm.manage') or app.has_permission('sales_reps.manage') or owner_id = app.current_user_id()
         or (customer_id is not null and app.has_permission('customers.view')));

-- ---------------------------------------------------------------------
-- Orders: promotions applied automatically (replacement; [3B] marks the change)
-- ---------------------------------------------------------------------
create or replace function public.save_order(p_id uuid, p jsonb, p_confirm boolean, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; v uuid; c public.customers; o public.orders; it jsonb; n integer := 0; v_price numeric;
  v_disc_limit numeric; v_line_gross numeric; v_res jsonb; v_addr uuid; v_include boolean;
  v_promo record; v_manual numeric;  -- [3B]
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
       and app.jnum(it, 'discount') / v_line_gross * 100 > v_disc_limit then  -- [3A] was: refused without pos.discount
      perform app.require_approval('order_discount', format('Discounts above %s%% need approval', v_disc_limit));
    end if;
    -- [3B] the best active promotion is added on top of any manual discount (it needs no further approval)
    v_manual := least(coalesce(app.jnum(it, 'discount'), 0), v_line_gross);
    select * into v_promo from app.promotion_discount(app.juuid(it, 'product_id'), c.id, app.jnum(it, 'qty'), v_price,
                                                       coalesce((app.jtext(p, 'requested_date'))::date, app.today()));
    v_promo.amount := least(coalesce(v_promo.amount, 0), greatest(v_line_gross - v_manual, 0));
    insert into public.order_items (order_id, line_no, product_id, qty, unit_price, discount, line_net, line_tax, line_total, promotion_id, promo_discount)
    values (v, n, app.juuid(it, 'product_id'), app.jnum(it, 'qty'), v_price, v_manual + v_promo.amount, 0, 0, 0,
            case when v_promo.amount > 0 then v_promo.promotion_id end, v_promo.amount);
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

-- >>> 20261008000044_phase3b_reference_data.sql
-- =====================================================================
-- OLA Water ERP — Phase 3B
-- 0044: accounts, numbering, permissions, approval rule for promotions,
--       notification types, settings, sample commission plan
-- =====================================================================
insert into public.accounts (code, name, account_type, system_key, parent_id)
select v.code, v.name, v.type, v.key, (select id from public.accounts where code = v.parent)
  from (values
    ('1150', 'Cash with Sales Reps',       'asset',     'rep_cash',             '1000'),
    ('2520', 'Sales Commissions Payable',  'liability', 'commission_payable',   '2000'),
    ('6215', 'Sales Commissions',          'expense',   'exp_sales_commission', '6000')
  ) as v(code, name, type, key, parent)
 where not exists (select 1 from public.accounts a where a.code = v.code);

insert into public.document_types (code, name, padding) values
  ('LEAD', 'Lead', 6), ('OPP', 'Opportunity', 6), ('COM', 'Commission statement', 6), ('RCH', 'Rep cash hand-in', 6)
on conflict (code) do nothing;

insert into public.permissions (code, module, action, description, sort_order) values
  ('payments.collect', 'Payments', 'collect', 'Collect payments from customers in the field (sales reps)', 152)
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, x.code
  from public.roles r
  join (values
    ('sales_representative', array['payments.collect','customers.view']),
    ('distributor_manager',  array['crm.manage','customers.manage','payments.view','documents.view']),
    ('director',             array['sales_reps.manage','distributors.manage','crm.manage']),
    ('finance_manager',      array['sales_reps.manage']),
    ('operations_manager',   array['distributors.manage'])
  ) as m(role_code, perms) on m.role_code = r.code
  cross join lateral unnest(m.perms) as x(code)
 where exists (select 1 from public.permissions p where p.code = x.code)
   and not exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_code = x.code);

insert into public.roles (code, name, role_group, is_system, description)
values ('sales_manager', 'Sales Manager', 'commercial', true, 'Sales team, targets, commissions, distributors and CRM')
on conflict (code) do nothing;
insert into public.role_permissions (role_id, permission_code)
select (select id from public.roles where code = 'sales_manager'), x
  from unnest(array['dashboard.view','customers.view','customers.manage','products.view','orders.view','orders.manage','payments.view',
                    'complaints.view','complaints.manage','crm.manage','sales_reps.manage','distributors.manage','approvals.act','reports.view',
                    'reports.export','documents.view','pos.discount']) x
 where exists (select 1 from public.permissions p where p.code = x)
on conflict do nothing;

insert into public.approval_rules (kind, name, description, approver_permission, levels, threshold_setting, functions, sort_order) values
  ('promotion', 'Promotion switched on', 'A promotion lowers prices automatically on orders, so it needs the price approver',
   'prices.approve', 1, null, array['activate_promotion'], 45)
on conflict (kind) do nothing;

insert into public.notification_types (code, name, description, permission, severity, sort_order) values
  ('lead_assigned', 'Lead for you', 'A lead was given to you', null, 'info', 100),
  ('follow_ups_due', 'Follow-ups due', 'Your CRM follow-ups due today or overdue', null, 'info', 101),
  ('rep_cash', 'Cash held by sales reps', 'Reps holding collected cash for more than a day', 'payments.manage', 'warning', 102),
  ('commissions_due', 'Commissions to prepare', 'Last month''s sales commissions are not prepared or approved', 'sales_reps.manage', 'info', 103),
  ('distributor_agreement', 'Distributor agreement ending', 'A distributor agreement ends within 30 days', 'distributors.manage', 'warning', 104)
on conflict (code) do nothing;

insert into public.setting_definitions (key, module, label, description, value_type, choices, min_value, max_value, sort_order) values
  ('sales.visit_radius_m', 'Sales', 'Visit check-in distance warning (metres)', 'Warn when a rep checks in further than this from the customer''s saved location', 'integer', null, 50, 5000, 100),
  ('crm.max_campaign_messages', 'Sales', 'Most customers one campaign message can go to', null, 'integer', null, 10, 100000, 101);
insert into public.system_settings (key, value, effective_from) values
  ('sales.visit_radius_m', '300', date '2026-01-01'),
  ('crm.max_campaign_messages', '2000', date '2026-01-01');

insert into public.commission_plans (code, name, sales_rate_pct, collection_rate_pct, target_bonus_pct, new_customer_bonus, notes) values
  ('STD', 'Standard rep plan (example — edit)', 2, 0.5, 1, 500, 'Example only: 2% of sales, 0.5% of collections, +1% when the monthly target is met, Rs. 500 per new customer');

-- >>> 20261008000045_phase3b_read_models.sql
-- =====================================================================
-- OLA Water ERP — Phase 3B
-- 0045: read models — sales team, rep's day, distributors, CRM,
--       campaigns and promotions; extra alerts
-- =====================================================================

create or replace function public.sales_team_overview(p_year integer, p_month integer)
returns table (id uuid, code text, full_name text, profile_id uuid, employee_id uuid, territory text, territory_id uuid, plan text, plan_id uuid,
               phone text, is_active boolean, sales_target numeric, collection_target numeric, new_customers_target integer, visits_target integer,
               sales_net numeric, collections numeric, new_customers integer, visits integer, achievement_pct numeric, cash_with_rep numeric,
               customers integer, open_leads integer)
language sql stable security definer set search_path = '' as $$
  select r.id, r.code, p.full_name, r.profile_id, r.employee_id, t.name, r.territory_id, cp.name, r.commission_plan_id, r.phone, r.is_active,
         coalesce(st.sales_target, 0), coalesce(st.collection_target, 0), coalesce(st.new_customers, 0), coalesce(st.visits, 0),
         (f ->> 'sales_net')::numeric, (f ->> 'collections')::numeric, (f ->> 'new_customers')::integer, (f ->> 'visits')::integer,
         case when coalesce(st.sales_target, 0) > 0 then round((f ->> 'sales_net')::numeric / st.sales_target * 100, 1) end,
         (f ->> 'cash_with_rep')::numeric,
         (select count(*)::integer from public.customers c where c.sales_rep_id = r.profile_id and c.status = 'active'),
         (select count(*)::integer from public.leads l where l.owner_id = r.profile_id and l.status not in ('won','lost'))
    from public.sales_reps r join public.profiles p on p.id = r.profile_id
    left join public.territories t on t.id = r.territory_id
    left join public.commission_plans cp on cp.id = r.commission_plan_id
    left join public.sales_targets st on st.rep_id = r.id and st.target_year = p_year and st.target_month = p_month
    cross join lateral app.rep_month_figures(r.id, p_year, p_month) f
   where app.has_permission('sales_reps.manage') or r.profile_id = app.current_user_id()
   order by r.is_active desc, p.full_name
$$;

create or replace function public.rep_details(p_rep uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.sales_reps; v_hist jsonb := '[]'; d date; f jsonb; t public.sales_targets;
begin
  select * into r from public.sales_reps where id = p_rep;
  if not found then return null; end if;
  if not (app.has_permission('sales_reps.manage') or r.profile_id = app.current_user_id()) then return null; end if;
  for i in 0..5 loop
    d := (date_trunc('month', app.today()) - make_interval(months => i))::date;
    f := app.rep_month_figures(r.id, extract(year from d)::int, extract(month from d)::int);
    select * into t from public.sales_targets where rep_id = r.id and target_year = extract(year from d)::int and target_month = extract(month from d)::int;
    v_hist := v_hist || jsonb_build_object('year', extract(year from d)::int, 'month', extract(month from d)::int,
      'sales_net', f -> 'sales_net', 'collections', f -> 'collections', 'new_customers', f -> 'new_customers', 'visits', f -> 'visits',
      'sales_target', coalesce(t.sales_target, 0), 'collection_target', coalesce(t.collection_target, 0),
      'new_customers_target', coalesce(t.new_customers, 0), 'visits_target', coalesce(t.visits, 0));
  end loop;
  return jsonb_build_object(
    'rep', (select to_jsonb(x) from (select r.*, p.full_name, p.email, t2.name territory, cp.name plan_name, e.emp_no, e.full_name employee_name
                                      from public.profiles p left join public.territories t2 on t2.id = r.territory_id
                                      left join public.commission_plans cp on cp.id = r.commission_plan_id
                                      left join public.employees e on e.id = r.employee_id where p.id = r.profile_id) x),
    'history', v_hist,
    'cash_with_rep', (app.rep_month_figures(r.id, extract(year from app.today())::int, extract(month from app.today())::int) ->> 'cash_with_rep')::numeric,
    'customers', (select coalesce(jsonb_agg(x order by x.sales_90d desc nulls last), '[]') from (
        select c.id, c.name, c.customer_no, c.customer_type, app.customer_outstanding(c.id) outstanding,
               (select sum(subtotal_net) from public.invoices i where i.customer_id = c.id and i.status <> 'void' and i.invoice_date >= app.today() - 90) sales_90d,
               (select max(checkin_at) from public.rep_visits v where v.customer_id = c.id and v.rep_id = r.id) last_visit
          from public.customers c where c.sales_rep_id = r.profile_id and c.status = 'active' limit 200) x),
    'visits', (select coalesce(jsonb_agg(x order by x.checkin_at desc), '[]') from (
        select v.id, v.checkin_at, v.checkout_at, v.purpose, v.outcome, v.notes, v.distance_m, v.next_action_on,
               coalesce(c.name, l.name) who, v.customer_id, v.lead_id, o.order_no, pay.payment_no, pay.amount payment_amount
          from public.rep_visits v left join public.customers c on c.id = v.customer_id left join public.leads l on l.id = v.lead_id
          left join public.orders o on o.id = v.order_id left join public.payments pay on pay.id = v.payment_id
         where v.rep_id = r.id order by v.checkin_at desc limit 50) x),
    'collections', (select coalesce(jsonb_agg(x order by x.received_at desc), '[]') from (
        select pay.id, pay.payment_no, pay.received_at, pay.method, pay.amount, c.name customer
          from public.payments pay join public.customers c on c.id = pay.customer_id where pay.rep_id = r.id order by pay.received_at desc limit 30) x),
    'handovers', (select coalesce(jsonb_agg(x order by x.created_at desc), '[]') from (
        select h.handover_no, h.created_at, h.amount, m.name account, h.reference from public.rep_cash_handovers h
          join public.money_accounts m on m.id = h.money_account_id where h.rep_id = r.id order by h.created_at desc limit 20) x),
    'commissions', (select coalesce(jsonb_agg(to_jsonb(s) order by s.period_year desc, s.period_month desc), '[]')
                      from public.commission_statements s where s.rep_id = r.id),
    'leads', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'lead_no', l.lead_no, 'name', l.name, 'status', l.status,
                'next_follow_up', l.next_follow_up) order by l.next_follow_up nulls last), '[]')
                from public.leads l where l.owner_id = r.profile_id and l.status not in ('won','lost')));
end $$;

-- Everything a rep needs on the road today
create or replace function public.my_sales_day()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.sales_reps; f jsonb; t public.sales_targets; v_y integer := extract(year from app.today())::int; v_m integer := extract(month from app.today())::int;
begin
  r := app.my_rep();
  if r.id is null then return null; end if;
  f := app.rep_month_figures(r.id, v_y, v_m);
  select * into t from public.sales_targets where rep_id = r.id and target_year = v_y and target_month = v_m;
  return jsonb_build_object(
    'rep', jsonb_build_object('id', r.id, 'code', r.code, 'territory', (select name from public.territories where id = r.territory_id)),
    'month', f || jsonb_build_object('sales_target', coalesce(t.sales_target, 0), 'collection_target', coalesce(t.collection_target, 0),
                                     'new_customers_target', coalesce(t.new_customers, 0), 'visits_target', coalesce(t.visits, 0)),
    'open_visit', (select to_jsonb(x) from (select v.id, v.checkin_at, v.purpose, v.distance_m, v.customer_id, v.lead_id, coalesce(c.name, l.name) who
                     from public.rep_visits v left join public.customers c on c.id = v.customer_id left join public.leads l on l.id = v.lead_id
                    where v.rep_id = r.id and v.checkout_at is null and v.checkin_at > now() - interval '12 hours'
                    order by v.checkin_at desc limit 1) x),
    'today', (select coalesce(jsonb_agg(x order by x.checkin_at), '[]') from (
        select v.id, v.checkin_at, v.checkout_at, v.purpose, v.outcome, coalesce(c.name, l.name) who, o.order_no, pay.amount payment
          from public.rep_visits v left join public.customers c on c.id = v.customer_id left join public.leads l on l.id = v.lead_id
          left join public.orders o on o.id = v.order_id left join public.payments pay on pay.id = v.payment_id
         where v.rep_id = r.id and (v.checkin_at at time zone 'Asia/Colombo')::date = app.today()) x),
    'customers', (select coalesce(jsonb_agg(x order by x.name), '[]') from (
        select c.id, c.name, c.customer_no, c.phone, app.customer_outstanding(c.id) outstanding,
               (select a.address_line from public.customer_addresses a where a.customer_id = c.id and a.is_active order by a.is_default desc limit 1) address
          from public.customers c where c.sales_rep_id = r.profile_id and c.status <> 'inactive') x),
    'leads', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'lead_no', l.lead_no, 'status', l.status, 'phone', l.phone,
                'city', l.city, 'next_follow_up', l.next_follow_up) order by l.next_follow_up nulls last), '[]')
                from public.leads l where l.owner_id = r.profile_id and l.status not in ('won','lost')),
    'follow_ups', (select coalesce(jsonb_agg(x order by x.due_on), '[]') from (
        select a.id, a.subject, a.kind, a.due_on, coalesce(l.name, c.name) who, a.lead_id, a.customer_id
          from public.crm_activities a left join public.leads l on l.id = a.lead_id left join public.customers c on c.id = a.customer_id
         where a.owner_id = r.profile_id and a.done_at is null and a.due_on <= app.today() + 1) x),
    'cash_with_me', (f ->> 'cash_with_rep')::numeric,
    'can_collect', app.has_permission('payments.collect'));
end $$;

-- ---------------------------------------------------------------------
-- Distributors
-- ---------------------------------------------------------------------
create or replace function public.distributor_overview()
returns table (id uuid, code text, kind text, customer_id uuid, name text, customer_no text, territory text, status text, manager text,
               monthly_target numeric, sales_month numeric, sales_last_month numeric, outstanding numeric, overdue numeric, credit_limit numeric,
               ola_bottles integer, last_stock_report date, agreement_end date)
language sql stable security definer set search_path = '' as $$
  select d.id, d.code, d.kind, c.id, c.name, c.customer_no, t.name, d.status, p.full_name, d.monthly_target,
         coalesce((select sum(i.subtotal_net) from public.invoices i where i.customer_id = c.id and i.status <> 'void'
                     and i.invoice_date >= date_trunc('month', app.today())::date), 0),
         coalesce((select sum(i.subtotal_net) from public.invoices i where i.customer_id = c.id and i.status <> 'void'
                     and i.invoice_date >= (date_trunc('month', app.today()) - interval '1 month')::date
                     and i.invoice_date < date_trunc('month', app.today())::date), 0),
         app.customer_outstanding(c.id),
         coalesce((select sum(i.balance) from public.invoices i where i.customer_id = c.id and i.status in ('open','partially_paid') and i.due_date < app.today()), 0),
         c.credit_limit, app.customer_ola_bottles(c.id)::integer,
         (select max(report_date) from public.distributor_stock_reports r where r.distributor_id = d.id), d.agreement_end
    from public.distributors d join public.customers c on c.id = d.customer_id
    left join public.territories t on t.id = d.territory_id left join public.profiles p on p.id = d.manager_id
   where app.has_permission('distributors.manage') or app.has_permission('customers.view')
   order by d.status, c.name
$$;

create or replace function public.distributor_details(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare d public.distributors; c public.customers; v_hist jsonb := '[]'; m date; lr public.distributor_stock_reports;
begin
  if not (app.has_permission('distributors.manage') or app.has_permission('customers.view')) then return null; end if;
  select * into d from public.distributors where id = p_id;
  if not found then return null; end if;
  select * into c from public.customers where id = d.customer_id;
  for i in 0..11 loop
    m := (date_trunc('month', app.today()) - make_interval(months => i))::date;
    v_hist := v_hist || jsonb_build_object('month', m,
      'sales', coalesce((select sum(subtotal_net) from public.invoices where customer_id = c.id and status <> 'void'
                           and invoice_date >= m and invoice_date < (m + interval '1 month')::date), 0),
      'qty_19l', coalesce((select sum(l.qty) from public.invoice_lines l join public.invoices i on i.id = l.invoice_id join public.products pr on pr.id = l.product_id
                            where i.customer_id = c.id and i.status <> 'void' and l.line_type = 'product' and pr.sku = 'OLA-19L'
                              and i.invoice_date >= m and i.invoice_date < (m + interval '1 month')::date), 0),
      'collections', coalesce((select sum(amount) from public.payments where customer_id = c.id and status = 'received' and coalesce(direction, 'in') = 'in'
                                 and (received_at at time zone 'Asia/Colombo')::date >= m
                                 and (received_at at time zone 'Asia/Colombo')::date < (m + interval '1 month')::date), 0));
  end loop;
  select * into lr from public.distributor_stock_reports where distributor_id = d.id order by report_date desc limit 1;
  return jsonb_build_object(
    'distributor', to_jsonb(d) || jsonb_build_object('territory', (select name from public.territories where id = d.territory_id),
                                                     'manager', (select full_name from public.profiles where id = d.manager_id)),
    'customer', jsonb_build_object('id', c.id, 'name', c.name, 'customer_no', c.customer_no, 'phone', c.phone, 'credit_limit', c.credit_limit,
                  'payment_terms_days', c.payment_terms_days, 'price_list', (select name from public.price_lists where id = c.price_list_id),
                  'outstanding', app.customer_outstanding(c.id), 'ola_bottles', app.customer_ola_bottles(c.id),
                  'overdue', coalesce((select sum(balance) from public.invoices where customer_id = c.id and status in ('open','partially_paid') and due_date < app.today()), 0)),
    'history', v_hist,
    'stock', case when lr.id is null then null else jsonb_build_object('report_date', lr.report_date, 'empty_bottles', lr.empty_bottles,
       'lines', (select coalesce(jsonb_agg(jsonb_build_object('product_id', pr.id, 'product', pr.name, 'reported', (x ->> 'qty')::numeric,
                   'delivered_since', coalesce((select sum(l.qty) from public.invoice_lines l join public.invoices i on i.id = l.invoice_id
                                                  where i.customer_id = c.id and i.status <> 'void' and l.product_id = pr.id and i.invoice_date > lr.report_date), 0))), '[]')
                   from jsonb_array_elements(lr.lines) x join public.products pr on pr.id = (x ->> 'product_id')::uuid)) end,
    'reports', (select coalesce(jsonb_agg(jsonb_build_object('report_date', r.report_date, 'empty_bottles', r.empty_bottles, 'notes', r.notes,
                   'total', (select sum((x ->> 'qty')::numeric) from jsonb_array_elements(r.lines) x)) order by r.report_date desc), '[]')
                 from (select * from public.distributor_stock_reports where distributor_id = d.id order by report_date desc limit 12) r),
    'orders', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'order_no', o.order_no, 'status', o.status, 'requested_date', o.requested_date,
                  'total', o.total) order by o.created_at desc), '[]')
                 from (select * from public.orders where customer_id = c.id order by created_at desc limit 10) o));
end $$;

-- ---------------------------------------------------------------------
-- CRM
-- ---------------------------------------------------------------------
create or replace function public.crm_overview()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not (app.has_permission('crm.manage') or app.has_permission('sales_reps.manage')) then null else jsonb_build_object(
    'pipeline', (select coalesce(jsonb_object_agg(status, jsonb_build_object('count', cnt, 'value', val)), '{}') from (
        select status, count(*) cnt, coalesce(sum(est_monthly_value), 0) val from public.leads group by status) x),
    'opportunities', (select coalesce(jsonb_object_agg(stage, jsonb_build_object('count', cnt, 'value', val, 'weighted', w)), '{}') from (
        select stage, count(*) cnt, sum(monthly_value) val, round(sum(monthly_value * probability / 100.0), 2) w from public.opportunities group by stage) x),
    'follow_ups_due', (select count(*) from public.crm_activities where done_at is null and due_on <= app.today()),
    'my_follow_ups', (select count(*) from public.crm_activities where done_at is null and due_on <= app.today() and owner_id = app.current_user_id())
                      + (select count(*) from public.leads where owner_id = app.current_user_id() and status not in ('won','lost') and next_follow_up <= app.today()),
    'conversion_90d', (select jsonb_build_object('leads', count(*), 'won', count(*) filter (where status = 'won'),
                         'lost', count(*) filter (where status = 'lost'),
                         'rate', round(100.0 * count(*) filter (where status = 'won') / nullif(count(*) filter (where status in ('won','lost')), 0), 0))
                         from public.leads where created_at >= now() - interval '90 days'),
    'by_source', (select coalesce(jsonb_agg(jsonb_build_object('source', source, 'leads', cnt, 'won', won) order by cnt desc), '[]') from (
        select source, count(*) cnt, count(*) filter (where status = 'won') won from public.leads
         where created_at >= now() - interval '180 days' group by source) x)) end
$$;

create or replace function public.lead_details(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare l public.leads;
begin
  select * into l from public.leads where id = p_id;
  if not found or not (app.has_permission('crm.manage') or app.has_permission('sales_reps.manage') or l.owner_id = app.current_user_id()) then
    return null;
  end if;
  return jsonb_build_object(
    'lead', to_jsonb(l) || jsonb_build_object('owner', (select full_name from public.profiles where id = l.owner_id),
              'campaign', (select name from public.campaigns where id = l.campaign_id), 'territory', (select name from public.territories where id = l.territory_id),
              'customer_name', (select name from public.customers where id = l.customer_id)),
    'activities', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'kind', a.kind, 'subject', a.subject, 'notes', a.notes, 'due_on', a.due_on,
                     'done_at', a.done_at, 'outcome', a.outcome, 'owner', p.full_name, 'created_at', a.created_at) order by coalesce(a.done_at, a.created_at) desc), '[]')
                     from public.crm_activities a left join public.profiles p on p.id = a.owner_id where a.lead_id = l.id),
    'opportunities', (select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc), '[]') from public.opportunities o where o.lead_id = l.id),
    'visits', (select coalesce(jsonb_agg(jsonb_build_object('checkin_at', v.checkin_at, 'outcome', v.outcome, 'notes', v.notes, 'rep', r.code) order by v.checkin_at desc), '[]')
                 from public.rep_visits v join public.sales_reps r on r.id = v.rep_id where v.lead_id = l.id));
end $$;

create or replace function public.campaign_performance()
returns table (id uuid, code text, name text, channel text, status text, start_date date, end_date date, budget numeric, spent numeric,
               segment text, segment_size integer, promotion text, leads integer, won integer, new_customers integer, revenue numeric,
               messages_sent integer, messages_failed integer, promo_discount numeric, cost_per_customer numeric)
language sql stable security definer set search_path = '' as $$
  select c.id, c.code, c.name, c.channel, c.status, c.start_date, c.end_date, c.budget, c.spent, s.name,
         case when s.id is not null then (select count(*)::integer from app.segment_customer_ids(s.rules)) end,
         pr.name,
         (select count(*)::integer from public.leads l where l.campaign_id = c.id),
         (select count(*)::integer from public.leads l where l.campaign_id = c.id and l.status = 'won'),
         (select count(*)::integer from public.customers cu where cu.campaign_id = c.id),
         coalesce((select sum(i.subtotal_net) from public.invoices i join public.customers cu on cu.id = i.customer_id
                    where cu.campaign_id = c.id and i.status <> 'void' and i.invoice_date >= c.start_date), 0),
         (select count(*)::integer from public.message_outbox m where m.related_type = 'campaign' and m.related_id = c.id and m.status = 'sent'),
         (select count(*)::integer from public.message_outbox m where m.related_type = 'campaign' and m.related_id = c.id and m.status = 'failed'),
         coalesce((select sum(oi.promo_discount) from public.order_items oi join public.orders o on o.id = oi.order_id
                    where c.promotion_id is not null and oi.promotion_id = c.promotion_id and o.status not in ('cancelled','draft')), 0),
         case when (select count(*) from public.customers cu where cu.campaign_id = c.id) > 0
              then round(c.spent / (select count(*) from public.customers cu where cu.campaign_id = c.id), 2) end
    from public.campaigns c left join public.customer_segments s on s.id = c.segment_id left join public.promotions pr on pr.id = c.promotion_id
   where app.has_permission('crm.manage')
   order by c.start_date desc
$$;

create or replace function public.promotion_performance()
returns table (id uuid, code text, name text, kind text, value numeric, status text, start_date date, end_date date, product text,
               orders integer, qty numeric, discount_given numeric, sales_net numeric)
language sql stable security definer set search_path = '' as $$
  select p.id, p.code, p.name, p.kind, p.value, p.status, p.start_date, p.end_date, pr.name,
         (select count(distinct oi.order_id)::integer from public.order_items oi join public.orders o on o.id = oi.order_id
           where oi.promotion_id = p.id and o.status not in ('cancelled','draft')),
         coalesce((select sum(oi.qty) from public.order_items oi join public.orders o on o.id = oi.order_id
           where oi.promotion_id = p.id and o.status not in ('cancelled','draft')), 0),
         coalesce((select sum(oi.promo_discount) from public.order_items oi join public.orders o on o.id = oi.order_id
           where oi.promotion_id = p.id and o.status not in ('cancelled','draft')), 0),
         coalesce((select sum(oi.line_net) from public.order_items oi join public.orders o on o.id = oi.order_id
           where oi.promotion_id = p.id and o.status not in ('cancelled','draft')), 0)
    from public.promotions p left join public.products pr on pr.id = p.product_id
   where app.has_permission('crm.manage') or app.has_permission('prices.approve')
   order by p.start_date desc
$$;

-- Promotions a customer would get today (shown on the order screen)
create or replace function public.active_promotions_for(p_customer uuid)
returns table (id uuid, code text, name text, kind text, value numeric, buy_qty integer, product_id uuid, min_qty numeric, end_date date)
language sql stable security definer set search_path = '' as $$
  select p.id, p.code, p.name, p.kind, p.value, p.buy_qty, p.product_id, p.min_qty, p.end_date
    from public.promotions p, public.customers c
   where c.id = p_customer and p.status = 'active' and app.today() between p.start_date and p.end_date
     and (p.price_list_id is null or p.price_list_id = c.price_list_id)
     and (p.customer_types is null or cardinality(p.customer_types) = 0 or c.customer_type = any(p.customer_types))
     and (p.segment_id is null or app.segment_has(p.segment_id, c.id))
     and (app.has_permission('orders.view') or app.has_permission('crm.manage'))
$$;

-- Extra alerts, called by refresh_notifications
create or replace function app.refresh_notifications_sales()
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer := 0; x record; v_day text := to_char(app.today(), 'YYYY-MM-DD');
        v_prev date := (date_trunc('month', app.today()) - interval '1 month')::date;
begin
  -- follow-ups due for each owner (once a day)
  for x in select owner_id, count(*) cnt from (
             select owner_id from public.crm_activities where done_at is null and due_on <= app.today() and owner_id is not null
             union all
             select owner_id from public.leads where status not in ('won','lost') and next_follow_up <= app.today() and owner_id is not null) f
            group by owner_id loop
    n := n + app.notify('follow_ups_due', x.cnt || ' follow-up(s) due today', null, '/crm', 'followups:' || x.owner_id || ':' || v_day, x.owner_id);
  end loop;
  -- cash held by reps for more than a day
  for x in select r.id, r.code, sum(l.debit - l.credit) held, min(e.entry_date) since
             from public.journal_lines l join public.accounts a on a.id = l.account_id and a.system_key = 'rep_cash'
             join public.journal_entries e on e.id = l.entry_id join public.sales_reps r on r.id = l.party_id
            where l.party_type = 'sales_rep' group by r.id, r.code having sum(l.debit - l.credit) > 0 loop
    if x.since < app.today() then
      n := n + app.notify('rep_cash', 'Rep ' || x.code || ' holds Rs. ' || to_char(x.held, 'FM999,999,990.00'), 'Collected cash not handed in yet',
                          '/sales/reps/' || x.id, 'repcash:' || x.id || ':' || v_day);
    end if;
  end loop;
  -- last month's commissions not prepared / approved (from the 3rd of the month)
  if extract(day from app.today()) >= 3 and exists (
       select 1 from public.sales_reps r where r.is_active and r.commission_plan_id is not null
          and not exists (select 1 from public.commission_statements s where s.rep_id = r.id and s.status in ('approved','paid')
                           and s.period_year = extract(year from v_prev)::int and s.period_month = extract(month from v_prev)::int)) then
    n := n + app.notify('commissions_due', 'Sales commissions for ' || to_char(v_prev, 'FMMonth') || ' are not approved yet', null,
                        '/sales/commissions', 'commissions:' || v_prev);
  end if;
  -- distributor agreements ending within 30 days
  for x in select d.id, d.code, d.agreement_end, c.name from public.distributors d join public.customers c on c.id = d.customer_id
            where d.status = 'active' and d.agreement_end between app.today() and app.today() + 30 loop
    n := n + app.notify('distributor_agreement', 'Agreement with ' || x.name || ' ends ' || to_char(x.agreement_end, 'DD Mon'), null,
                        '/distributors/' || x.id, 'dist-agr:' || x.id || ':' || x.agreement_end);
  end loop;
  return n;
end $$;

-- Staff names are also needed to give leads and distributors an owner
create or replace function public.staff_directory()
returns table (id uuid, full_name text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.full_name from public.profiles p
   where p.is_active and app.current_user_id() is not null
     and (app.has_permission('complaints.manage') or app.has_permission('complaints.view') or app.has_permission('users.manage')
          or app.has_permission('sales_reps.manage') or app.has_permission('crm.manage') or app.has_permission('distributors.manage'))
   order by p.full_name
$$;

-- refresh_notifications now also runs the sales alerts ([3B] marks the change)
create or replace function public.refresh_notifications(p_force boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare st public.notification_scan_state; n integer := 0; v_day text := to_char(app.today(), 'YYYY-MM-DD'); x record;
        v_minutes integer := coalesce((app.get_setting('notifications.scan_minutes') #>> '{}')::integer, 10);
        v_after integer := coalesce((app.get_setting('messaging.reminder_after_days') #>> '{}')::integer, 7);
        v_repeat integer := coalesce((app.get_setting('messaging.reminder_repeat_days') #>> '{}')::integer, 7);
        v_reminders integer := 0;
begin
  if app.current_user_id() is null and not app.can_dispatch() then raise exception 'Not signed in' using errcode = '42501'; end if;
  if p_force and not (app.has_permission('settings.manage') or app.can_dispatch()) then p_force := false; end if;
  select * into st from public.notification_scan_state where id = 1 for update skip locked;
  if not found then return jsonb_build_object('ran', false); end if;
  if not p_force and st.last_run_at > now() - make_interval(mins => v_minutes) then
    return jsonb_build_object('ran', false, 'last_run_at', st.last_run_at);
  end if;
  update public.notification_scan_state set last_run_at = now() where id = 1;

  -- low stock (one alert per item per day)
  for x in select p.id, p.name, p.reorder_level, coalesce(sum(b.qty), 0) qty
             from public.products p left join public.inventory_balances b on b.product_id = p.id and b.stock_status = 'available'
            where p.is_active and p.reorder_level > 0 group by p.id having coalesce(sum(b.qty), 0) <= p.reorder_level loop
    n := n + app.notify('low_stock', 'Low stock: ' || x.name, format('%s left (reorder level %s)', x.qty, x.reorder_level), '/inventory',
                        'low-stock:' || x.id || ':' || v_day);
  end loop;

  -- vehicles
  for x in select f.id, f.registration_no, f.alerts from public.fleet_overview() f where f.is_active and cardinality(f.alerts) > 0 loop
    n := n + app.notify('vehicle_alert', x.registration_no || ': ' || array_to_string(x.alerts, ', '), null, '/fleet/' || x.id,
                        'vehicle:' || x.id || ':' || md5(array_to_string(x.alerts, ',')) || ':' || v_day);
  end loop;

  -- documents expiring (the people who manage that kind of document are told)
  for x in select d.id, d.doc_no, d.title, d.expires_on, c.manage_permission
             from public.documents d join public.document_categories c on c.code = d.category_code
            where d.status = 'active' and d.expires_on is not null and d.expires_on <= app.today() + d.alert_days loop
    n := n + app.notify('document_expiry',
      case when x.expires_on < app.today() then 'Expired: ' else 'Expiring ' || to_char(x.expires_on, 'DD Mon') || ': ' end || x.title,
      x.doc_no, '/documents?show=expiring', 'doc-expiry:' || x.id || ':' || (x.expires_on < app.today()), null,
      case when x.expires_on < app.today() then 'critical' end, x.manage_permission);
  end loop;

  -- external bottles above the alert level (once a day)
  for x in select c.name, h.qty, h.alert from (
             select b.company_id, sum(b.qty) qty,
                    coalesce(bc.holding_alert_qty, (app.get_setting('bottles.external_holding_alert_qty') #>> '{}')::integer) alert
               from public.bottle_balances b join public.locations l on l.id = b.holder_id
               join public.bottle_companies bc on bc.id = b.company_id
              where b.holder_type = 'location' and l.location_type = 'external_holding' and not bc.is_own
              group by b.company_id, bc.holding_alert_qty) h join public.bottle_companies c on c.id = h.company_id
            where h.qty > h.alert loop
    n := n + app.notify('external_bottles', x.name || ': ' || x.qty || ' bottles held', 'Alert level ' || x.alert || ' — arrange a hand-over',
                        '/bottles/external', 'ext:' || x.name || ':' || v_day);
  end loop;

  -- failed deliveries today
  select count(*) cnt into x from public.deliveries d join public.route_runs r on r.id = d.run_id
   where d.status = 'failed' and r.run_date = app.today();
  if x.cnt > 0 then
    n := n + app.notify('failed_delivery', x.cnt || ' failed delivery(ies) today', null, '/dispatch', 'failed:' || v_day || ':' || x.cnt);
  end if;

  -- complaints past their due time
  for x in select id, complaint_no, subject, assigned_to from public.complaints
            where status not in ('resolved','closed') and due_at < now() loop
    n := n + app.notify('complaint_overdue', 'Overdue complaint ' || x.complaint_no, x.subject, '/complaints/' || x.id, 'cmp-overdue:' || x.id);
    if x.assigned_to is not null then
      n := n + app.notify('complaint_overdue', 'Overdue complaint ' || x.complaint_no, x.subject, '/complaints/' || x.id,
                          'cmp-overdue-me:' || x.id, x.assigned_to);
    end if;
  end loop;

  -- QC holds
  for x in select b.id, b.batch_no, p.name from public.production_batches b join public.products p on p.id = b.product_id
            where b.status = 'qc_hold' loop
    n := n + app.notify('qc_hold', 'Batch ' || x.batch_no || ' waiting for QC release', x.name, '/production/' || x.id, 'qc-hold:' || x.id);
  end loop;

  -- items waiting for approval in modules (one reminder a day per kind)
  for x in select * from (values
      ('expenses.approve', (select count(*) from public.expenses where status = 'pending_approval'), 'expense(s)', '/expenses?show=pending_approval'),
      ('procurement.approve', (select count(*) from public.purchase_orders where status = 'pending_approval')
                              + (select count(*) from public.purchase_requests where status = 'submitted'), 'purchase(s)', '/purchasing'),
      ('accounting.manual_journal', (select count(*) from public.journal_drafts where status = 'pending'), 'manual journal(s)', '/accounting/journals'),
      ('payroll.approve', (select count(*) from public.payroll_runs where status = 'draft'), 'payroll run(s)', '/payroll'),
      ('hr.manage', (select count(*) from public.leave_requests where status = 'pending'), 'leave request(s)', '/hr/attendance'),
      ('shops.stock_approve', (select count(*) from public.shop_stock_requests where status = 'submitted'), 'shop stock request(s)', '/shops/requests'),
      ('customers.credit', (select count(*) from public.orders where status = 'on_hold'), 'order(s) on credit hold', '/orders?status=on_hold')
    ) as t(perm, cnt, what, href) where t.cnt > 0 loop
    n := n + app.notify('pending_approvals', x.cnt || ' ' || x.what || ' waiting for approval', null, x.href,
                        'pending:' || x.perm || ':' || v_day, null, null, x.perm);
  end loop;

  -- overdue customer balances: staff summary once a day, customer reminders
  select count(distinct customer_id) cnt, coalesce(sum(balance), 0) amt into x from public.invoices
   where status in ('open','partially_paid') and due_date < app.today() and balance > 0;
  if x.cnt > 0 then
    n := n + app.notify('overdue_invoices', x.cnt || ' customer(s) overdue', 'Rs. ' || to_char(x.amt, 'FM999,999,999,990.00') || ' past due',
                        '/accounting/reports/ar-ageing', 'overdue:' || v_day);
  end if;
  for x in select i.customer_id, sum(i.balance) overdue, min(i.due_date) oldest
             from public.invoices i join public.customers c on c.id = i.customer_id
            where i.status in ('open','partially_paid') and i.balance > 0 and i.due_date <= app.today() - v_after
              and not c.messages_opt_out and not c.is_walk_in
            group by i.customer_id loop
    if not exists (select 1 from public.message_outbox m where m.customer_id = x.customer_id and m.template_code = 'PAYMENT_REMINDER'
                     and m.status <> 'cancelled' and m.created_at > now() - make_interval(days => v_repeat)) then
      if app.queue_customer_message('PAYMENT_REMINDER', x.customer_id,
           jsonb_build_object('overdue', to_char(x.overdue, 'FM999,999,990.00'), 'due_date', to_char(x.oldest, 'DD Mon YYYY')),
           'reminder', null, 'reminder:' || x.customer_id || ':' || v_day) is not null then
        v_reminders := v_reminders + 1;
      end if;
    end if;
  end loop;

  -- messages that failed today
  select count(*) cnt into x from public.message_outbox where status = 'failed' and created_at > now() - interval '1 day';
  if x.cnt > 0 then
    n := n + app.notify('messages_failed', x.cnt || ' message(s) could not be sent', 'Check Messages for the reason', '/messages?show=failed',
                        'msg-failed:' || v_day || ':' || x.cnt);
  end if;

  n := n + app.refresh_notifications_sales();  -- [3B]
  return jsonb_build_object('ran', true, 'created', n, 'reminders', v_reminders);
end $$;

-- ---------------------------------------------------------------------
-- Function privileges (re-applied after functions are added)
-- ---------------------------------------------------------------------
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
grant execute on function app.document_can(text, boolean)      to authenticated, service_role;
revoke execute on function public.log_failed_login(text, text, text, text) from authenticated;
revoke execute on function public.bootstrap_super_admin(text)              from authenticated;

grant select on all tables in schema public to authenticated, service_role;
revoke all on all tables in schema public from anon;

commit;
