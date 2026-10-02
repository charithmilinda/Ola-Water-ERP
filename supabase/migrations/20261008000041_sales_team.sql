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
