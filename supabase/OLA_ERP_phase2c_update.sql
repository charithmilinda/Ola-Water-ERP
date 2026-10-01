-- OLA Water ERP — Phase 2C database update (HR, payroll, fleet, fixed assets)
-- Run ONCE in Supabase → SQL Editor → New query, on the database that already has Phase 2B.
-- It runs as one transaction: if anything fails, nothing is changed.
begin;

-- >>> 20261006000030_hr_payroll.sql
-- =====================================================================
-- OLA Water ERP — Phase 2C
-- 0030: HR & payroll — departments, employees, attendance, leave,
--       salary advances, payroll runs, payslips, EPF / ETF / APIT
-- =====================================================================
-- * Statutory contributions are effective-dated rules, never hard-coded:
--   payroll_statutory_rates (EPF employee / employer, ETF) and apit_bands
--   (monthly progressive tax table). Change them from a date; history stays.
-- * A payroll run is prepared (draft, recalculated as often as needed),
--   approved by a second person (posts the salary journal) and then paid.
-- * Employee personal and salary data is visible only to HR (hr.view) and
--   payroll (payroll.run / payroll.approve).
-- =====================================================================

create table public.departments (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (code ~ '^[A-Z0-9-]{2,12}$'),
  name        text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create trigger departments_audit after insert or update on public.departments for each row execute function app.audit_row('hr');

create table public.positions (
  id             uuid primary key default gen_random_uuid(),
  name           text not null unique,
  department_id  uuid references public.departments(id),
  is_active      boolean not null default true,
  created_at     timestamptz not null default now()
);
create trigger positions_audit after insert or update on public.positions for each row execute function app.audit_row('hr');

create table public.employees (
  id                uuid primary key default gen_random_uuid(),
  emp_no            text not null unique check (emp_no ~ '^[A-Z0-9-]{1,15}$'),
  full_name         text not null check (length(trim(full_name)) > 0),
  name_with_initials text,
  nic_no            text unique,
  date_of_birth     date,
  gender            text check (gender in ('male','female','other')),
  phone             text,
  email             text,
  address           text,
  emergency_contact text,
  department_id     uuid references public.departments(id),
  position_id       uuid references public.positions(id),
  location_id       uuid references public.locations(id),
  employment_type   text not null default 'permanent' check (employment_type in ('permanent','probation','contract','casual')),
  join_date         date not null,
  end_date          date,
  status            text not null default 'active' check (status in ('active','resigned','terminated')),
  profile_id        uuid unique references public.profiles(id),
  epf_no            text,
  pay_basis         text not null default 'monthly' check (pay_basis in ('monthly','daily')),
  basic_salary      numeric(14,2) not null default 0 check (basic_salary >= 0),
  daily_rate        numeric(12,2) not null default 0 check (daily_rate >= 0),
  epf_applicable    boolean not null default true,
  etf_applicable    boolean not null default true,
  apit_applicable   boolean not null default true,
  bank_name         text,
  bank_branch       text,
  bank_account_no   text,
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (end_date is null or end_date >= join_date),
  check (status = 'active' or end_date is not null)
);
comment on column public.employees.profile_id is 'Link to the user login (drivers, staff who use the system)';
create index employees_status_idx on public.employees (status, emp_no);
create trigger employees_touch before update on public.employees for each row execute function app.touch_updated_at();
create trigger employees_audit after insert or update on public.employees for each row execute function app.audit_row('hr');

-- Pay components (allowances and deductions) and each employee's fixed ones
create table public.pay_components (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (code ~ '^[A-Z0-9_]{2,20}$'),
  name        text not null,
  kind        text not null check (kind in ('earning','deduction')),
  epf_liable  boolean not null default false,
  taxable     boolean not null default true,
  account_id  uuid references public.accounts(id),
  is_active   boolean not null default true,
  sort_order  integer not null default 0
);
comment on column public.pay_components.account_id is 'Deductions: the liability they are owed to (empty = Other Payroll Deductions). Earnings: empty = Salaries & Wages.';
create trigger pay_components_audit after insert or update on public.pay_components for each row execute function app.audit_row('payroll');

create table public.employee_pay_items (
  employee_id   uuid not null references public.employees(id),
  component_id  uuid not null references public.pay_components(id),
  amount        numeric(14,2) not null check (amount > 0),
  primary key (employee_id, component_id)
);
create trigger employee_pay_items_audit after insert or update or delete on public.employee_pay_items for each row execute function app.audit_row('payroll');

-- Statutory rates and the APIT table (effective-dated)
create table public.payroll_statutory_rates (
  code            text not null check (code in ('epf_employee','epf_employer','etf_employer')),
  rate_percent    numeric(6,3) not null check (rate_percent between 0 and 100),
  effective_from  date not null,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  primary key (code, effective_from)
);
create trigger payroll_statutory_rates_audit after insert on public.payroll_statutory_rates for each row execute function app.audit_row('payroll');
create trigger payroll_statutory_rates_append_only before update or delete on public.payroll_statutory_rates for each row execute function app.forbid_change();

create table public.apit_bands (
  effective_from  date not null,
  band_no         integer not null check (band_no > 0),
  band_width      numeric(14,2) check (band_width > 0),
  rate_percent    numeric(6,3) not null check (rate_percent between 0 and 100),
  created_at      timestamptz not null default now(),
  created_by      uuid,
  primary key (effective_from, band_no)
);
comment on table public.apit_bands is 'Monthly APIT (Table 1, primary employment): each band taxes the next band_width rupees; an empty width is the top band.';
create trigger apit_bands_audit after insert on public.apit_bands for each row execute function app.audit_row('payroll');
create trigger apit_bands_append_only before update or delete on public.apit_bands for each row execute function app.forbid_change();

-- A month already closed in the books: post into the current open month instead
create or replace function app.open_posting_date(p_date date)
returns date language sql stable security definer set search_path = '' as $$
  select case when exists (select 1 from public.accounting_periods where p_date between starts_on and ends_on and status = 'open')
              then p_date else app.today() end
$$;

create or replace function app.statutory_rate(p_code text, p_at date)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce((select rate_percent from public.payroll_statutory_rates where code = p_code and effective_from <= p_at
                    order by effective_from desc limit 1), 0)
$$;

create or replace function app.apit_monthly(p_taxable numeric, p_at date)
returns numeric language plpgsql stable security definer set search_path = '' as $$
declare v_eff date; b record; v_left numeric := greatest(coalesce(p_taxable, 0), 0); v_tax numeric := 0; v_part numeric;
begin
  select max(effective_from) into v_eff from public.apit_bands where effective_from <= p_at;
  if v_eff is null then return 0; end if;
  for b in select * from public.apit_bands where effective_from = v_eff order by band_no loop
    exit when v_left <= 0;
    v_part := case when b.band_width is null then v_left else least(v_left, b.band_width) end;
    v_tax := v_tax + v_part * b.rate_percent / 100;
    v_left := v_left - v_part;
  end loop;
  return round(v_tax, 2);
end $$;

-- ---------------------------------------------------------------------
-- Holidays, attendance and leave
-- ---------------------------------------------------------------------
create table public.holidays (
  holiday_date  date primary key,
  name          text not null
);
create trigger holidays_audit after insert or update or delete on public.holidays for each row execute function app.audit_row('hr');

create table public.leave_types (
  id             uuid primary key default gen_random_uuid(),
  code           text not null unique check (code ~ '^[A-Z0-9_]{2,12}$'),
  name           text not null,
  days_per_year  numeric(5,1) not null default 0 check (days_per_year >= 0),
  is_paid        boolean not null default true,
  is_active      boolean not null default true
);
create trigger leave_types_audit after insert or update on public.leave_types for each row execute function app.audit_row('hr');

create table public.leave_requests (
  id             uuid primary key default gen_random_uuid(),
  request_no     text not null unique,
  employee_id    uuid not null references public.employees(id),
  leave_type_id  uuid not null references public.leave_types(id),
  from_date      date not null,
  to_date        date not null,
  half_day       boolean not null default false,
  days           numeric(5,1) not null check (days > 0),
  reason         text,
  status         text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  requested_at   timestamptz not null default now(),
  requested_by   uuid,
  decided_at     timestamptz,
  decided_by     uuid,
  decision_note  text,
  updated_at     timestamptz not null default now(),
  check (to_date >= from_date),
  check (not half_day or from_date = to_date)
);
create index leave_requests_employee_idx on public.leave_requests (employee_id, from_date);
create trigger leave_requests_touch before update on public.leave_requests for each row execute function app.touch_updated_at();
create trigger leave_requests_audit after insert or update on public.leave_requests for each row execute function app.audit_row('hr');

create table public.attendance (
  employee_id    uuid not null references public.employees(id),
  work_date      date not null,
  status         text not null check (status in ('present','half_day','absent','leave','holiday','off')),
  leave_type_id  uuid references public.leave_types(id),
  leave_request_id uuid references public.leave_requests(id),
  time_in        time,
  time_out       time,
  ot_hours       numeric(5,2) not null default 0 check (ot_hours between 0 and 24),
  notes          text,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (employee_id, work_date),
  check ((status = 'leave') = (leave_type_id is not null))
);
create index attendance_date_idx on public.attendance (work_date);
create trigger attendance_audit after insert or update or delete on public.attendance for each row execute function app.audit_row('hr');

-- ---------------------------------------------------------------------
-- Salary advances
-- ---------------------------------------------------------------------
create table public.salary_advances (
  id                uuid primary key default gen_random_uuid(),
  advance_no        text not null unique,
  employee_id       uuid not null references public.employees(id),
  advance_date      date not null,
  amount            numeric(14,2) not null check (amount > 0),
  installment       numeric(14,2) not null check (installment > 0),
  outstanding       numeric(14,2) not null check (outstanding >= 0),
  status            text not null default 'active' check (status in ('active','settled')),
  reason            text,
  money_account_id  uuid not null references public.money_accounts(id),
  journal_entry_id  uuid references public.journal_entries(id),
  created_at        timestamptz not null default now(),
  created_by        uuid,
  client_txn_id     uuid unique
);
create trigger salary_advances_audit after insert or update on public.salary_advances for each row execute function app.audit_row('payroll');

-- ---------------------------------------------------------------------
-- Payroll runs and payslips
-- ---------------------------------------------------------------------
create table public.payroll_runs (
  id                uuid primary key default gen_random_uuid(),
  run_no            text not null unique,
  pay_year          integer not null check (pay_year between 2020 and 2100),
  pay_month         integer not null check (pay_month between 1 and 12),
  period_start      date not null,
  period_end        date not null,
  status            text not null default 'draft' check (status in ('draft','approved','paid','cancelled')),
  employees         integer not null default 0,
  gross             numeric(16,2) not null default 0,
  epf_employee      numeric(16,2) not null default 0,
  epf_employer      numeric(16,2) not null default 0,
  etf               numeric(16,2) not null default 0,
  apit              numeric(16,2) not null default 0,
  advances          numeric(16,2) not null default 0,
  other_deductions  numeric(16,2) not null default 0,
  net               numeric(16,2) not null default 0,
  notes             text,
  prepared_by       uuid,
  prepared_at       timestamptz not null default now(),
  approved_by       uuid,
  approved_at       timestamptz,
  decision_note     text,
  paid_at           timestamptz,
  paid_by           uuid,
  money_account_id  uuid references public.money_accounts(id),
  payment_reference text,
  journal_entry_id  uuid references public.journal_entries(id),
  payment_entry_id  uuid references public.journal_entries(id),
  updated_at        timestamptz not null default now(),
  client_txn_id     uuid unique
);
create unique index payroll_runs_one_per_month on public.payroll_runs (pay_year, pay_month) where status <> 'cancelled';
create trigger payroll_runs_touch before update on public.payroll_runs for each row execute function app.touch_updated_at();
create trigger payroll_runs_audit after insert or update on public.payroll_runs for each row execute function app.audit_row('payroll');

create table public.payslips (
  id                uuid primary key default gen_random_uuid(),
  run_id            uuid not null references public.payroll_runs(id),
  employee_id       uuid not null references public.employees(id),
  emp_no            text not null,
  employee_name     text not null,
  department        text,
  position          text,
  epf_no            text,
  bank_name         text,
  bank_account_no   text,
  pay_basis         text not null,
  basic             numeric(14,2) not null default 0,
  days_paid         numeric(5,1) not null default 0,
  nopay_days        numeric(5,1) not null default 0,
  nopay_amount      numeric(14,2) not null default 0,
  ot_hours          numeric(6,2) not null default 0,
  ot_amount         numeric(14,2) not null default 0,
  earnings          numeric(14,2) not null default 0,
  gross             numeric(14,2) not null default 0,
  epf_earnings      numeric(14,2) not null default 0,
  epf_employee      numeric(14,2) not null default 0,
  epf_employer      numeric(14,2) not null default 0,
  etf               numeric(14,2) not null default 0,
  taxable           numeric(14,2) not null default 0,
  apit              numeric(14,2) not null default 0,
  advance_recovery  numeric(14,2) not null default 0,
  other_deductions  numeric(14,2) not null default 0,
  total_deductions  numeric(14,2) not null default 0,
  net               numeric(14,2) not null default 0,
  warning           text,
  unique (run_id, employee_id)
);
create table public.payslip_lines (
  id            bigint generated always as identity primary key,
  payslip_id    uuid not null references public.payslips(id) on delete cascade,
  source        text not null check (source in ('fixed','adjustment')),
  component_id  uuid references public.pay_components(id),
  name          text not null,
  kind          text not null check (kind in ('earning','deduction')),
  amount        numeric(14,2) not null check (amount > 0),
  epf_liable    boolean not null default false,
  taxable       boolean not null default true,
  account_id    uuid references public.accounts(id)
);
create index payslip_lines_payslip_idx on public.payslip_lines (payslip_id);

create table public.advance_recoveries (
  advance_id  uuid not null references public.salary_advances(id),
  payslip_id  uuid not null references public.payslips(id),
  amount      numeric(14,2) not null check (amount > 0),
  primary key (advance_id, payslip_id)
);

create table public.statutory_payments (
  id                uuid primary key default gen_random_uuid(),
  payment_no        text not null unique,
  kind              text not null check (kind in ('epf','etf','apit')),
  pay_year          integer not null,
  pay_month         integer not null check (pay_month between 1 and 12),
  amount            numeric(14,2) not null check (amount > 0),
  money_account_id  uuid not null references public.money_accounts(id),
  reference         text,
  paid_at           timestamptz not null default now(),
  paid_by           uuid,
  journal_entry_id  uuid references public.journal_entries(id),
  client_txn_id     uuid unique
);
create trigger statutory_payments_audit after insert on public.statutory_payments for each row execute function app.audit_row('payroll');

-- ---------------------------------------------------------------------
-- Masters
-- ---------------------------------------------------------------------
create or replace function public.save_department(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform app.require_permission('hr.manage');
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    insert into public.departments (code, name) values (upper(trim(app.jtext(p, 'code'))), trim(app.jtext(p, 'name'))) returning id into v;
  else
    update public.departments set name = trim(app.jtext(p, 'name')), is_active = app.jbool(p, 'is_active', true) where id = p_id returning id into v;
  end if;
  if v is null then raise exception 'Department not found' using errcode = 'P0002'; end if;
  return v;
end $$;

create or replace function public.save_position(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform app.require_permission('hr.manage');
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    insert into public.positions (name, department_id) values (trim(app.jtext(p, 'name')), app.juuid(p, 'department_id')) returning id into v;
  else
    update public.positions set name = trim(app.jtext(p, 'name')), department_id = app.juuid(p, 'department_id'),
           is_active = app.jbool(p, 'is_active', true) where id = p_id returning id into v;
  end if;
  if v is null then raise exception 'Position not found' using errcode = 'P0002'; end if;
  return v;
end $$;

create or replace function public.save_employee(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; v_status text := coalesce(app.jtext(p, 'status'), 'active'); v_pay boolean := app.has_permission('payroll.run');
        v_phone text := app.jtext(p, 'phone'); old public.employees;
begin
  perform app.require_permission('hr.manage');
  if nullif(trim(app.jtext(p, 'full_name')), '') is null then raise exception 'Enter the employee''s name' using errcode = '22023'; end if;
  if app.jtext(p, 'join_date') is null then raise exception 'Enter the joining date' using errcode = '22023'; end if;
  if v_status <> 'active' and app.jtext(p, 'end_date') is null then raise exception 'Enter the last working day' using errcode = '22023'; end if;
  if v_phone is not null then v_phone := coalesce(app.normalize_phone(v_phone), v_phone); end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is not null then
    select * into old from public.employees where id = p_id;
    if not found then raise exception 'Employee not found' using errcode = 'P0002'; end if;
  end if;
  if p_id is null then
    insert into public.employees (emp_no, full_name, name_with_initials, nic_no, date_of_birth, gender, phone, email, address, emergency_contact,
      department_id, position_id, location_id, employment_type, join_date, end_date, status, profile_id, epf_no, pay_basis, basic_salary, daily_rate,
      epf_applicable, etf_applicable, apit_applicable, bank_name, bank_branch, bank_account_no, notes)
    values (upper(trim(app.jtext(p, 'emp_no'))), trim(app.jtext(p, 'full_name')), app.jtext(p, 'name_with_initials'),
      nullif(upper(trim(app.jtext(p, 'nic_no'))), ''), (app.jtext(p, 'date_of_birth'))::date, app.jtext(p, 'gender'), v_phone,
      lower(app.jtext(p, 'email')), app.jtext(p, 'address'), app.jtext(p, 'emergency_contact'), app.juuid(p, 'department_id'),
      app.juuid(p, 'position_id'), app.juuid(p, 'location_id'), coalesce(app.jtext(p, 'employment_type'), 'permanent'),
      (app.jtext(p, 'join_date'))::date, (app.jtext(p, 'end_date'))::date, v_status, app.juuid(p, 'profile_id'), app.jtext(p, 'epf_no'),
      case when v_pay then coalesce(app.jtext(p, 'pay_basis'), 'monthly') else 'monthly' end,
      case when v_pay then coalesce(app.jnum(p, 'basic_salary'), 0) else 0 end,
      case when v_pay then coalesce(app.jnum(p, 'daily_rate'), 0) else 0 end,
      case when v_pay then app.jbool(p, 'epf_applicable', true) else true end,
      case when v_pay then app.jbool(p, 'etf_applicable', true) else true end,
      case when v_pay then app.jbool(p, 'apit_applicable', true) else true end,
      app.jtext(p, 'bank_name'), app.jtext(p, 'bank_branch'), app.jtext(p, 'bank_account_no'), app.jtext(p, 'notes'))
    returning id into v;
  else
    update public.employees set full_name = trim(app.jtext(p, 'full_name')), name_with_initials = app.jtext(p, 'name_with_initials'),
      nic_no = nullif(upper(trim(app.jtext(p, 'nic_no'))), ''), date_of_birth = (app.jtext(p, 'date_of_birth'))::date,
      gender = app.jtext(p, 'gender'), phone = v_phone, email = lower(app.jtext(p, 'email')), address = app.jtext(p, 'address'),
      emergency_contact = app.jtext(p, 'emergency_contact'), department_id = app.juuid(p, 'department_id'), position_id = app.juuid(p, 'position_id'),
      location_id = app.juuid(p, 'location_id'), employment_type = coalesce(app.jtext(p, 'employment_type'), employment_type),
      join_date = (app.jtext(p, 'join_date'))::date, end_date = (app.jtext(p, 'end_date'))::date, status = v_status,
      profile_id = app.juuid(p, 'profile_id'), epf_no = app.jtext(p, 'epf_no'),
      -- pay details change only for payroll staff
      pay_basis = case when v_pay then coalesce(app.jtext(p, 'pay_basis'), pay_basis) else pay_basis end,
      basic_salary = case when v_pay then coalesce(app.jnum(p, 'basic_salary'), basic_salary) else basic_salary end,
      daily_rate = case when v_pay then coalesce(app.jnum(p, 'daily_rate'), daily_rate) else daily_rate end,
      epf_applicable = case when v_pay then app.jbool(p, 'epf_applicable', epf_applicable) else epf_applicable end,
      etf_applicable = case when v_pay then app.jbool(p, 'etf_applicable', etf_applicable) else etf_applicable end,
      apit_applicable = case when v_pay then app.jbool(p, 'apit_applicable', apit_applicable) else apit_applicable end,
      bank_name = app.jtext(p, 'bank_name'), bank_branch = app.jtext(p, 'bank_branch'), bank_account_no = app.jtext(p, 'bank_account_no'),
      notes = app.jtext(p, 'notes')
    where id = p_id returning id into v;
  end if;
  return v;
end $$;

create or replace function public.set_employee_pay_items(p_employee uuid, p_lines jsonb, p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
declare l jsonb; n integer := 0;
begin
  perform app.require_permission('payroll.run');
  if not exists (select 1 from public.employees where id = p_employee) then raise exception 'Employee not found' using errcode = 'P0002'; end if;
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Fixed allowances and deductions'), null, null);
  delete from public.employee_pay_items where employee_id = p_employee;
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    continue when coalesce(app.jnum(l, 'amount'), 0) <= 0;
    insert into public.employee_pay_items (employee_id, component_id, amount) values (p_employee, app.juuid(l, 'component_id'), app.jnum(l, 'amount'));
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.save_pay_component(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform app.require_permission('payroll.approve');
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    insert into public.pay_components (code, name, kind, epf_liable, taxable, account_id, sort_order)
    values (upper(trim(app.jtext(p, 'code'))), trim(app.jtext(p, 'name')), app.jtext(p, 'kind'), app.jbool(p, 'epf_liable', false),
            app.jbool(p, 'taxable', true), app.juuid(p, 'account_id'), coalesce(app.jint(p, 'sort_order'), 50)) returning id into v;
  else
    update public.pay_components set name = trim(app.jtext(p, 'name')), epf_liable = app.jbool(p, 'epf_liable', false),
           taxable = app.jbool(p, 'taxable', true), account_id = app.juuid(p, 'account_id'), is_active = app.jbool(p, 'is_active', true)
     where id = p_id returning id into v;
  end if;
  if v is null then raise exception 'Component not found' using errcode = 'P0002'; end if;
  return v;
end $$;

-- Change a statutory rate or the APIT table from a date (never back-dated)
create or replace function public.set_statutory_rate(p_code text, p_rate numeric, p_effective_from date, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_permission('payroll.approve');
  if nullif(trim(p_reason), '') is null then raise exception 'Give a reason' using errcode = '22023'; end if;
  if p_effective_from < date_trunc('month', app.today())::date then raise exception 'Rates cannot be changed for past months' using errcode = '22023'; end if;
  perform app.set_context(trim(p_reason), null, 'set_rate');
  insert into public.payroll_statutory_rates (code, rate_percent, effective_from, created_by) values (p_code, p_rate, p_effective_from, app.current_user_id());
end $$;

create or replace function public.set_apit_bands(p_effective_from date, p_bands jsonb, p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
declare b jsonb; n integer := 0;
begin
  perform app.require_permission('payroll.approve');
  if nullif(trim(p_reason), '') is null then raise exception 'Give a reason' using errcode = '22023'; end if;
  if p_effective_from < date_trunc('month', app.today())::date then raise exception 'The tax table cannot be changed for past months' using errcode = '22023'; end if;
  if exists (select 1 from public.apit_bands where effective_from = p_effective_from) then
    raise exception 'A tax table already starts on %', p_effective_from using errcode = '22023';
  end if;
  perform app.set_context(trim(p_reason), null, 'set_apit');
  for b in select * from jsonb_array_elements(p_bands) loop
    n := n + 1;
    insert into public.apit_bands (effective_from, band_no, band_width, rate_percent, created_by)
    values (p_effective_from, n, app.jnum(b, 'band_width'), app.jnum(b, 'rate_percent'), app.current_user_id());
  end loop;
  if n = 0 or exists (select 1 from public.apit_bands where effective_from = p_effective_from and band_no < n and band_width is null) then
    raise exception 'Every band except the last needs a width' using errcode = '22023';
  end if;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Attendance and leave
-- ---------------------------------------------------------------------
create or replace function public.save_holiday(p_date date, p_name text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_permission('hr.manage');
  if p_date is null or nullif(trim(p_name), '') is null then raise exception 'Enter the date and the name' using errcode = '22023'; end if;
  perform app.set_context(null, null, 'holiday');
  insert into public.holidays (holiday_date, name) values (p_date, trim(p_name))
  on conflict (holiday_date) do update set name = excluded.name;
end $$;

create or replace function app.payroll_locked(p_date date)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.payroll_runs where status in ('approved','paid')
                  and p_date between period_start and period_end)
$$;

--   p_rows: [{employee_id, status, time_in, time_out, ot_hours, notes}]
create or replace function public.record_attendance(p_date date, p_rows jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare r jsonb; n integer := 0; v_status text;
begin
  perform app.require_permission('hr.manage');
  if p_date > app.today() then raise exception 'Attendance cannot be entered for future days' using errcode = '22023'; end if;
  if app.payroll_locked(p_date) then raise exception 'Payroll for this month is approved — attendance is locked' using errcode = '22023'; end if;
  perform app.set_context(null, null, 'attendance');
  for r in select * from jsonb_array_elements(p_rows) loop
    v_status := app.jtext(r, 'status');
    continue when v_status is null;
    if v_status = 'leave' then continue; end if;  -- leave days come from approved leave
    if exists (select 1 from public.attendance where employee_id = app.juuid(r, 'employee_id') and work_date = p_date and status = 'leave') then
      continue;  -- an approved leave day is not overwritten here
    end if;
    insert into public.attendance (employee_id, work_date, status, time_in, time_out, ot_hours, notes, updated_by)
    values (app.juuid(r, 'employee_id'), p_date, v_status, (app.jtext(r, 'time_in'))::time, (app.jtext(r, 'time_out'))::time,
            coalesce(app.jnum(r, 'ot_hours'), 0), app.jtext(r, 'notes'), app.current_user_id())
    on conflict (employee_id, work_date) do update set status = excluded.status, time_in = excluded.time_in, time_out = excluded.time_out,
       ot_hours = excluded.ot_hours, notes = excluded.notes, updated_at = now(), updated_by = excluded.updated_by;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Working days of a leave: not Sundays, not public holidays
create or replace function app.leave_days(p_from date, p_to date, p_half boolean)
returns numeric language sql stable security definer set search_path = '' as $$
  select case when p_half then 0.5 else count(*)::numeric end
    from generate_series(p_from, p_to, interval '1 day') d
   where extract(isodow from d) <> 7 and not exists (select 1 from public.holidays h where h.holiday_date = d::date)
$$;

create or replace function app.leave_taken(p_employee uuid, p_type uuid, p_year integer)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(sum(days), 0) from public.leave_requests
   where employee_id = p_employee and leave_type_id = p_type and status = 'approved' and extract(year from from_date) = p_year
$$;

create or replace function public.request_leave(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e public.employees; t public.leave_types; v uuid := gen_random_uuid(); v_no text; v_days numeric;
        v_from date := (app.jtext(p, 'from_date'))::date; v_to date := coalesce((app.jtext(p, 'to_date'))::date, (app.jtext(p, 'from_date'))::date);
        v_half boolean := app.jbool(p, 'half_day', false);
begin
  select * into e from public.employees where id = app.juuid(p, 'employee_id');
  if not found then raise exception 'Employee not found' using errcode = 'P0002'; end if;
  if not (app.has_permission('hr.manage') or e.profile_id = app.current_user_id()) then
    raise exception 'Permission denied: hr.manage is required' using errcode = '42501';
  end if;
  select * into t from public.leave_types where id = app.juuid(p, 'leave_type_id') and is_active;
  if not found then raise exception 'Choose the type of leave' using errcode = '22023'; end if;
  if v_from is null or v_to < v_from then raise exception 'Check the dates' using errcode = '22023'; end if;
  if v_half and v_to <> v_from then raise exception 'A half day is a single date' using errcode = '22023'; end if;
  v_days := app.leave_days(v_from, v_to, v_half);
  if v_days = 0 then raise exception 'Those dates are all Sundays or holidays' using errcode = '22023'; end if;
  if exists (select 1 from public.leave_requests where employee_id = e.id and status in ('pending','approved')
              and daterange(from_date, to_date, '[]') && daterange(v_from, v_to, '[]')) then
    raise exception 'Leave already requested for some of these days' using errcode = '22023';
  end if;
  perform app.set_context(app.jtext(p, 'reason'), null, 'request_leave');
  v_no := app.next_document_number('LVE');
  insert into public.leave_requests (id, request_no, employee_id, leave_type_id, from_date, to_date, half_day, days, reason, requested_by)
  values (v, v_no, e.id, t.id, v_from, v_to, v_half, v_days, app.jtext(p, 'reason'), app.current_user_id());
  return jsonb_build_object('request_id', v, 'request_no', v_no, 'days', v_days,
    'balance_after', case when t.days_per_year > 0 then t.days_per_year - app.leave_taken(e.id, t.id, extract(year from v_from)::int) - v_days end);
end $$;

create or replace function public.decide_leave(p_id uuid, p_decision text, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.leave_requests; t public.leave_types; d date; v_bal numeric;
begin
  select * into r from public.leave_requests where id = p_id for update;
  if not found then raise exception 'Leave request not found' using errcode = 'P0002'; end if;
  select * into t from public.leave_types where id = r.leave_type_id;
  if p_decision = 'cancel' then
    if not app.has_permission('hr.manage') and r.requested_by is distinct from app.current_user_id() then
      raise exception 'Permission denied' using errcode = '42501';
    end if;
    if r.status not in ('pending','approved') then raise exception 'This request is already closed' using errcode = '22023'; end if;
    if r.status = 'approved' and app.payroll_locked(r.from_date) then raise exception 'Payroll for that month is approved — cannot cancel' using errcode = '22023'; end if;
  else
    perform app.require_permission('hr.manage');
    if r.status <> 'pending' then raise exception 'This request has already been decided' using errcode = '22023'; end if;
    if p_decision = 'reject' and nullif(trim(p_note), '') is null then raise exception 'Give a reason for rejecting' using errcode = '22023'; end if;
  end if;
  perform app.set_context(nullif(trim(p_note), ''), null, p_decision || '_leave');

  if p_decision = 'approve' then
    if app.payroll_locked(r.from_date) or app.payroll_locked(r.to_date) then
      raise exception 'Payroll for that month is approved — leave can no longer be added' using errcode = '22023';
    end if;
    v_bal := t.days_per_year - app.leave_taken(r.employee_id, t.id, extract(year from r.from_date)::int);
    if t.days_per_year > 0 and r.days > v_bal and t.is_paid then
      raise exception 'Only % day(s) of % left this year', v_bal, t.name using errcode = '22023';
    end if;
    for d in select x::date from generate_series(r.from_date, r.to_date, interval '1 day') x
              where extract(isodow from x) <> 7 and not exists (select 1 from public.holidays h where h.holiday_date = x::date) loop
      insert into public.attendance (employee_id, work_date, status, leave_type_id, leave_request_id, notes, updated_by)
      values (r.employee_id, d, 'leave', t.id, r.id, case when r.half_day then 'Half day' end, app.current_user_id())
      on conflict (employee_id, work_date) do update set status = 'leave', leave_type_id = t.id, leave_request_id = r.id,
        notes = excluded.notes, updated_at = now(), updated_by = excluded.updated_by;
    end loop;
    update public.leave_requests set status = 'approved', decided_at = now(), decided_by = app.current_user_id(), decision_note = nullif(trim(p_note), '')
     where id = p_id;
  elsif p_decision = 'reject' then
    update public.leave_requests set status = 'rejected', decided_at = now(), decided_by = app.current_user_id(), decision_note = trim(p_note) where id = p_id;
  elsif p_decision = 'cancel' then
    delete from public.attendance where leave_request_id = p_id;
    update public.leave_requests set status = 'cancelled', decided_at = now(), decided_by = app.current_user_id(), decision_note = nullif(trim(p_note), '')
     where id = p_id;
  else
    raise exception 'Unknown decision' using errcode = '22023';
  end if;
  return jsonb_build_object('status', (select status from public.leave_requests where id = p_id));
end $$;

-- ---------------------------------------------------------------------
-- Salary advances
-- ---------------------------------------------------------------------
create or replace function public.give_salary_advance(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; e public.employees; m public.money_accounts; v uuid := gen_random_uuid(); v_no text; v_je uuid; v_res jsonb;
        v_amt numeric := round(app.jnum(p, 'amount'), 2); v_inst numeric := round(coalesce(app.jnum(p, 'installment'), app.jnum(p, 'amount')), 2);
begin
  perform app.require_permission('payroll.run');
  if coalesce(v_amt, 0) <= 0 then raise exception 'Enter the amount' using errcode = '22023'; end if;
  if v_inst <= 0 or v_inst > v_amt then raise exception 'The monthly recovery must be between 1 and the amount' using errcode = '22023'; end if;
  select * into e from public.employees where id = app.juuid(p, 'employee_id') and status = 'active';
  if not found then raise exception 'Choose an active employee' using errcode = '22023'; end if;
  m := app.money_account(app.juuid(p, 'money_account_id'));
  v_done := app.idempotency_begin(p_client_txn_id, 'give_salary_advance');
  if v_done is not null then return v_done; end if;
  perform app.set_context(app.jtext(p, 'reason'), p_client_txn_id, 'advance');
  v_no := app.next_document_number('ADV');
  insert into public.salary_advances (id, advance_no, employee_id, advance_date, amount, installment, outstanding, reason, money_account_id, created_by, client_txn_id)
  values (v, v_no, e.id, app.today(), v_amt, v_inst, v_amt, app.jtext(p, 'reason'), m.id, app.current_user_id(), p_client_txn_id);
  v_je := app.post_journal(app.today(), format('Salary advance %s — %s', v_no, e.full_name), 'payroll.advance',
    jsonb_build_array(
      jsonb_build_object('account_key', 'staff_advances', 'debit', v_amt, 'credit', 0, 'memo', 'Advance', 'party_type', 'employee', 'party_id', e.id),
      jsonb_build_object('account_id', m.account_id, 'debit', 0, 'credit', v_amt, 'memo', 'Advance paid')),
    'salary_advance', v);
  update public.salary_advances set journal_entry_id = v_je where id = v;
  v_res := jsonb_build_object('advance_id', v, 'advance_no', v_no);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- Payroll calculation
-- ---------------------------------------------------------------------
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

create or replace function app.refresh_payroll_totals(p_run uuid)
returns void language sql security definer set search_path = '' as $$
  update public.payroll_runs r set
    employees = (select count(*) from public.payslips where run_id = r.id),
    gross = (select coalesce(sum(gross), 0) from public.payslips where run_id = r.id),
    epf_employee = (select coalesce(sum(epf_employee), 0) from public.payslips where run_id = r.id),
    epf_employer = (select coalesce(sum(epf_employer), 0) from public.payslips where run_id = r.id),
    etf = (select coalesce(sum(etf), 0) from public.payslips where run_id = r.id),
    apit = (select coalesce(sum(apit), 0) from public.payslips where run_id = r.id),
    advances = (select coalesce(sum(advance_recovery), 0) from public.payslips where run_id = r.id),
    other_deductions = (select coalesce(sum(other_deductions), 0) from public.payslips where run_id = r.id),
    net = (select coalesce(sum(net), 0) from public.payslips where run_id = r.id)
  where r.id = p_run
$$;

create or replace function public.create_payroll_run(p_year integer, p_month integer, p_notes text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v uuid := gen_random_uuid(); v_no text; v_start date := make_date(p_year, p_month, 1); v_end date; e record; v_res jsonb;
begin
  perform app.require_permission('payroll.run');
  v_end := (v_start + interval '1 month - 1 day')::date;
  if v_start > app.today() then raise exception 'Payroll cannot be prepared for a future month' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'create_payroll_run');
  if v_done is not null then return v_done; end if;
  if exists (select 1 from public.payroll_runs where pay_year = p_year and pay_month = p_month and status <> 'cancelled') then
    raise exception 'Payroll for %-% already exists', p_year, lpad(p_month::text, 2, '0') using errcode = '22023';
  end if;
  perform app.set_context(nullif(trim(p_notes), ''), p_client_txn_id, 'prepare_payroll');
  v_no := app.next_document_number('PRL', null, v_end);
  insert into public.payroll_runs (id, run_no, pay_year, pay_month, period_start, period_end, notes, prepared_by, client_txn_id)
  values (v, v_no, p_year, p_month, v_start, v_end, nullif(trim(p_notes), ''), app.current_user_id(), p_client_txn_id);
  for e in select id, emp_no, full_name, pay_basis from public.employees
            where join_date <= v_end and (end_date is null or end_date >= v_start) order by emp_no loop
    insert into public.payslips (run_id, employee_id, emp_no, employee_name, pay_basis) values (v, e.id, e.emp_no, e.full_name, e.pay_basis);
  end loop;
  perform app.calc_payslip(id) from public.payslips where run_id = v;
  perform app.refresh_payroll_totals(v);
  select jsonb_build_object('run_id', id, 'run_no', run_no, 'employees', employees, 'net', net) into v_res from public.payroll_runs where id = v;
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.recalculate_payroll_run(p_run uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs; e record;
begin
  perform app.require_permission('payroll.run');
  select * into r from public.payroll_runs where id = p_run for update;
  if not found or r.status <> 'draft' then raise exception 'Only a draft payroll can be recalculated' using errcode = '22023'; end if;
  perform app.set_context(null, null, 'recalculate_payroll');
  -- people who joined since it was prepared
  for e in select id, emp_no, full_name, pay_basis from public.employees
            where join_date <= r.period_end and (end_date is null or end_date >= r.period_start)
              and id not in (select employee_id from public.payslips where run_id = r.id) loop
    insert into public.payslips (run_id, employee_id, emp_no, employee_name, pay_basis) values (r.id, e.id, e.emp_no, e.full_name, e.pay_basis);
  end loop;
  perform app.calc_payslip(id) from public.payslips where run_id = r.id;
  perform app.refresh_payroll_totals(r.id);
  return jsonb_build_object('net', (select net from public.payroll_runs where id = r.id));
end $$;

--   p_lines: [{name, kind, amount, epf_liable, taxable, component_id}]  — one-off items for this month only
create or replace function public.set_payslip_adjustments(p_payslip uuid, p_lines jsonb, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.payslips; l jsonb; c public.pay_components;
begin
  perform app.require_permission('payroll.run');
  select * into s from public.payslips where id = p_payslip;
  if not found then raise exception 'Payslip not found' using errcode = 'P0002'; end if;
  if (select status from public.payroll_runs where id = s.run_id) <> 'draft' then raise exception 'The payroll is no longer a draft' using errcode = '22023'; end if;
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Payslip adjustment'), null, 'payslip_adjustment');
  delete from public.payslip_lines where payslip_id = s.id and source = 'adjustment';
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    continue when coalesce(app.jnum(l, 'amount'), 0) <= 0;
    c := null;
    if app.juuid(l, 'component_id') is not null then select * into c from public.pay_components where id = app.juuid(l, 'component_id'); end if;
    insert into public.payslip_lines (payslip_id, source, component_id, name, kind, amount, epf_liable, taxable, account_id)
    values (s.id, 'adjustment', c.id, coalesce(nullif(trim(app.jtext(l, 'name')), ''), c.name), coalesce(c.kind, app.jtext(l, 'kind')),
            round(app.jnum(l, 'amount'), 2), coalesce(c.epf_liable, app.jbool(l, 'epf_liable', false)), coalesce(c.taxable, app.jbool(l, 'taxable', true)),
            c.account_id);
  end loop;
  perform app.write_audit('payslip_adjustment', 'payroll', 'payslips', s.id::text, null, jsonb_build_object('employee', s.employee_name, 'lines', p_lines));
  perform app.calc_payslip(s.id);
  perform app.refresh_payroll_totals(s.run_id);
  return jsonb_build_object('net', (select net from public.payslips where id = s.id));
end $$;

create or replace function public.approve_payroll_run(p_run uuid, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs; v_lines jsonb; v_je uuid; x record; v_deduct jsonb := '[]';
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

  v_lines := jsonb_build_array(
    jsonb_build_object('account_key', 'exp_salaries', 'debit', r.gross, 'credit', 0, 'memo', 'Gross pay'),
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

  update public.payroll_runs set status = 'approved', approved_by = app.current_user_id(), approved_at = now(),
         decision_note = nullif(trim(p_note), ''), journal_entry_id = v_je where id = r.id;
  return jsonb_build_object('status', 'approved', 'entry_no', (select entry_no from public.journal_entries where id = v_je));
end $$;

create or replace function public.cancel_payroll_run(p_run uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.payroll_runs;
begin
  perform app.require_permission('payroll.run');
  if nullif(trim(p_reason), '') is null then raise exception 'Give a reason' using errcode = '22023'; end if;
  select * into r from public.payroll_runs where id = p_run for update;
  if not found or r.status <> 'draft' then raise exception 'Only a draft payroll can be cancelled' using errcode = '22023'; end if;
  perform app.set_context(trim(p_reason), null, 'cancel_payroll');
  update public.payroll_runs set status = 'cancelled', decision_note = trim(p_reason) where id = p_run;
end $$;

create or replace function public.pay_payroll_run(p_run uuid, p_money_account uuid, p_reference text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; r public.payroll_runs; m public.money_accounts; v_je uuid; v_res jsonb;
begin
  perform app.require_permission('payments.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'pay_payroll_run');
  if v_done is not null then return v_done; end if;
  select * into r from public.payroll_runs where id = p_run for update;
  if not found or r.status <> 'approved' then raise exception 'Only an approved payroll can be paid' using errcode = '22023'; end if;
  m := app.money_account(p_money_account);
  if m.kind = 'bank' and nullif(trim(p_reference), '') is null then raise exception 'Enter the bank transfer reference' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_reference), ''), p_client_txn_id, 'pay_payroll');
  if r.net > 0 then
    v_je := app.post_journal(app.today(), format('Salaries paid — %s', r.run_no), 'payroll.paid',
      jsonb_build_array(jsonb_build_object('account_key', 'salaries_payable', 'debit', r.net, 'credit', 0, 'memo', 'Net pay'),
                        jsonb_build_object('account_id', m.account_id, 'debit', 0, 'credit', r.net, 'memo', 'Salaries paid')),
      'payroll_run', r.id);
  end if;
  update public.payroll_runs set status = 'paid', paid_at = now(), paid_by = app.current_user_id(), money_account_id = m.id,
         payment_reference = nullif(trim(p_reference), ''), payment_entry_id = v_je where id = r.id;
  v_res := jsonb_build_object('paid', r.net);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- EPF, ETF and APIT paid to the authorities
create or replace function public.pay_statutory(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; m public.money_accounts; v uuid := gen_random_uuid(); v_no text; v_kind text := app.jtext(p, 'kind');
        v_amt numeric := round(app.jnum(p, 'amount'), 2); v_je uuid; v_res jsonb; v_key text;
begin
  perform app.require_permission('payments.manage');
  if v_kind not in ('epf','etf','apit') then raise exception 'Choose EPF, ETF or APIT' using errcode = '22023'; end if;
  if coalesce(v_amt, 0) <= 0 then raise exception 'Enter the amount' using errcode = '22023'; end if;
  m := app.money_account(app.juuid(p, 'money_account_id'));
  v_done := app.idempotency_begin(p_client_txn_id, 'pay_statutory');
  if v_done is not null then return v_done; end if;
  v_key := case v_kind when 'epf' then 'epf_payable' when 'etf' then 'etf_payable' else 'paye_payable' end;
  perform app.set_context(app.jtext(p, 'reference'), p_client_txn_id, 'pay_statutory');
  v_no := app.next_document_number('STP');
  insert into public.statutory_payments (id, payment_no, kind, pay_year, pay_month, amount, money_account_id, reference, paid_by, client_txn_id)
  values (v, v_no, v_kind, app.jint(p, 'pay_year'), app.jint(p, 'pay_month'), v_amt, m.id, app.jtext(p, 'reference'), app.current_user_id(), p_client_txn_id);
  v_je := app.post_journal(app.today(), format('%s paid for %s-%s (%s)', upper(v_kind), app.jint(p, 'pay_year'), lpad(app.jint(p, 'pay_month')::text, 2, '0'), v_no),
    'payroll.statutory', jsonb_build_array(
      jsonb_build_object('account_key', v_key, 'debit', v_amt, 'credit', 0, 'memo', upper(v_kind) || ' paid'),
      jsonb_build_object('account_id', m.account_id, 'debit', 0, 'credit', v_amt, 'memo', upper(v_kind) || ' paid')),
    'statutory_payment', v);
  update public.statutory_payments set journal_entry_id = v_je where id = v;
  v_res := jsonb_build_object('payment_no', v_no);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- RLS: personal and salary data stays with HR and payroll
-- ---------------------------------------------------------------------
alter table public.departments              enable row level security;
alter table public.positions                enable row level security;
alter table public.employees                enable row level security;
alter table public.pay_components           enable row level security;
alter table public.employee_pay_items       enable row level security;
alter table public.payroll_statutory_rates  enable row level security;
alter table public.apit_bands               enable row level security;
alter table public.holidays                 enable row level security;
alter table public.leave_types              enable row level security;
alter table public.leave_requests           enable row level security;
alter table public.attendance               enable row level security;
alter table public.salary_advances          enable row level security;
alter table public.payroll_runs             enable row level security;
alter table public.payslips                 enable row level security;
alter table public.payslip_lines            enable row level security;
alter table public.advance_recoveries       enable row level security;
alter table public.statutory_payments       enable row level security;

create policy departments_read on public.departments for select to authenticated using (true);
create policy positions_read on public.positions for select to authenticated using (true);
create policy holidays_read on public.holidays for select to authenticated using (true);
create policy leave_types_read on public.leave_types for select to authenticated using (true);
create policy employees_read on public.employees for select to authenticated
  using (app.has_permission('hr.view') or app.has_permission('payroll.run') or app.has_permission('payroll.approve') or profile_id = app.current_user_id());
create policy pay_components_read on public.pay_components for select to authenticated
  using (app.has_permission('payroll.run') or app.has_permission('payroll.approve') or app.has_permission('hr.view'));
create policy employee_pay_items_read on public.employee_pay_items for select to authenticated
  using (app.has_permission('payroll.run') or app.has_permission('payroll.approve'));
create policy payroll_statutory_rates_read on public.payroll_statutory_rates for select to authenticated
  using (app.has_permission('payroll.run') or app.has_permission('payroll.approve'));
create policy apit_bands_read on public.apit_bands for select to authenticated
  using (app.has_permission('payroll.run') or app.has_permission('payroll.approve'));
create policy leave_requests_read on public.leave_requests for select to authenticated
  using (app.has_permission('hr.view') or exists (select 1 from public.employees e where e.id = employee_id and e.profile_id = app.current_user_id()));
create policy attendance_read on public.attendance for select to authenticated
  using (app.has_permission('hr.view') or app.has_permission('payroll.run'));
create policy salary_advances_read on public.salary_advances for select to authenticated
  using (app.has_permission('payroll.run') or app.has_permission('payroll.approve'));
create policy payroll_runs_read on public.payroll_runs for select to authenticated
  using (app.has_permission('payroll.run') or app.has_permission('payroll.approve'));
create policy payslips_read on public.payslips for select to authenticated
  using (app.has_permission('payroll.run') or app.has_permission('payroll.approve'));
create policy payslip_lines_read on public.payslip_lines for select to authenticated
  using (app.has_permission('payroll.run') or app.has_permission('payroll.approve'));
create policy advance_recoveries_read on public.advance_recoveries for select to authenticated
  using (app.has_permission('payroll.run') or app.has_permission('payroll.approve'));
create policy statutory_payments_read on public.statutory_payments for select to authenticated
  using (app.has_permission('payroll.run') or app.has_permission('payroll.approve') or app.has_permission('accounting.view'));
revoke insert, update, delete, truncate on public.payroll_statutory_rates, public.apit_bands from anon, authenticated, service_role;

-- >>> 20261006000031_fixed_assets.sql
-- =====================================================================
-- OLA Water ERP — Phase 2C
-- 0031: fixed assets — register, monthly depreciation, maintenance,
--       disposal
-- =====================================================================
-- Acquisition: Dr asset cost account / Cr cash or bank (or opening equity
--   for assets owned before go-live, with their depreciation to date).
-- Depreciation (monthly run): Dr Depreciation / Cr Accumulated Depreciation.
--   Straight line: (cost − residual) ÷ useful life in months.
--   Reducing balance: book value × annual rate ÷ 12.
-- Disposal: remove cost and accumulated depreciation; proceeds to cash or
--   bank; the difference is a gain or loss on disposal.
-- =====================================================================

create table public.asset_categories (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique check (code ~ '^[A-Z0-9_-]{2,12}$'),
  name                text not null,
  asset_account_id    uuid not null references public.accounts(id),
  method              text not null default 'straight_line' check (method in ('straight_line','reducing_balance')),
  useful_life_months  integer check (useful_life_months > 0),
  rate_percent        numeric(6,2) check (rate_percent > 0 and rate_percent <= 100),
  residual_percent    numeric(5,2) not null default 0 check (residual_percent between 0 and 100),
  is_active           boolean not null default true,
  check (method <> 'straight_line' or useful_life_months is not null),
  check (method <> 'reducing_balance' or rate_percent is not null)
);
create trigger asset_categories_audit after insert or update on public.asset_categories for each row execute function app.audit_row('assets');

create table public.fixed_assets (
  id                     uuid primary key default gen_random_uuid(),
  asset_no               text not null unique,
  name                   text not null check (length(trim(name)) > 0),
  category_id            uuid not null references public.asset_categories(id),
  serial_no              text,
  description            text,
  location_id            uuid references public.locations(id),
  responsible_employee_id uuid references public.employees(id),
  supplier_name          text,
  purchase_date          date not null,
  cost                   numeric(16,2) not null check (cost > 0),
  residual_value         numeric(16,2) not null default 0 check (residual_value >= 0),
  method                 text not null check (method in ('straight_line','reducing_balance')),
  useful_life_months     integer check (useful_life_months > 0),
  rate_percent           numeric(6,2),
  depreciation_start     date not null,
  opening_accumulated    numeric(16,2) not null default 0 check (opening_accumulated >= 0),
  accumulated            numeric(16,2) not null default 0 check (accumulated >= 0),
  warranty_until         date,
  funding                text not null check (funding in ('paid','opening','recorded')),
  money_account_id       uuid references public.money_accounts(id),
  status                 text not null default 'active' check (status in ('active','disposed')),
  disposed_on            date,
  disposal_proceeds      numeric(16,2),
  disposal_note          text,
  journal_entry_id       uuid references public.journal_entries(id),
  disposal_entry_id      uuid references public.journal_entries(id),
  created_at             timestamptz not null default now(),
  created_by             uuid,
  updated_at             timestamptz not null default now(),
  client_txn_id          uuid unique,
  check (residual_value < cost),
  check (opening_accumulated <= cost - residual_value),
  check (accumulated <= cost)
);
create index fixed_assets_category_idx on public.fixed_assets (category_id, status);
create trigger fixed_assets_touch before update on public.fixed_assets for each row execute function app.touch_updated_at();
create trigger fixed_assets_audit after insert or update on public.fixed_assets for each row execute function app.audit_row('assets');

create table public.depreciation_runs (
  id                uuid primary key default gen_random_uuid(),
  run_no            text not null unique,
  dep_year          integer not null,
  dep_month         integer not null check (dep_month between 1 and 12),
  assets            integer not null default 0,
  total             numeric(16,2) not null default 0,
  journal_entry_id  uuid references public.journal_entries(id),
  created_at        timestamptz not null default now(),
  created_by        uuid,
  unique (dep_year, dep_month)
);
create trigger depreciation_runs_audit after insert on public.depreciation_runs for each row execute function app.audit_row('assets');

create table public.asset_depreciation (
  asset_id   uuid not null references public.fixed_assets(id),
  run_id     uuid not null references public.depreciation_runs(id),
  dep_year   integer not null,
  dep_month  integer not null,
  amount     numeric(16,2) not null check (amount > 0),
  primary key (asset_id, dep_year, dep_month)
);
create trigger asset_depreciation_append_only before update or delete on public.asset_depreciation for each row execute function app.forbid_change();

-- Maintenance and repairs are expenses linked to the asset
alter table public.expenses add column asset_id uuid references public.fixed_assets(id);

-- ---------------------------------------------------------------------
create or replace function public.save_asset_category(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; a public.accounts;
begin
  perform app.require_permission('assets.manage');
  select * into a from public.accounts where id = app.juuid(p, 'asset_account_id');
  if not found or a.account_type <> 'asset' or not a.is_postable then raise exception 'Choose the fixed-asset ledger account' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    insert into public.asset_categories (code, name, asset_account_id, method, useful_life_months, rate_percent, residual_percent)
    values (upper(trim(app.jtext(p, 'code'))), trim(app.jtext(p, 'name')), a.id, coalesce(app.jtext(p, 'method'), 'straight_line'),
            app.jint(p, 'useful_life_months'), app.jnum(p, 'rate_percent'), coalesce(app.jnum(p, 'residual_percent'), 0)) returning id into v;
  else
    update public.asset_categories set name = trim(app.jtext(p, 'name')), asset_account_id = a.id, method = coalesce(app.jtext(p, 'method'), method),
           useful_life_months = app.jint(p, 'useful_life_months'), rate_percent = app.jnum(p, 'rate_percent'),
           residual_percent = coalesce(app.jnum(p, 'residual_percent'), 0), is_active = app.jbool(p, 'is_active', true)
     where id = p_id returning id into v;
  end if;
  if v is null then raise exception 'Category not found' using errcode = 'P0002'; end if;
  return v;
end $$;

--   p: {name, category_id, serial_no, description, location_id, responsible_employee_id, supplier_name, purchase_date, cost,
--       residual_value, method, useful_life_months, rate_percent, depreciation_start, warranty_until,
--       funding: paid | opening | recorded, money_account_id, reference, opening_accumulated, vehicle_id}
create or replace function public.register_asset(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; c public.asset_categories; m public.money_accounts; v uuid := gen_random_uuid(); v_no text; v_je uuid; v_res jsonb;
  v_cost numeric := round(app.jnum(p, 'cost'), 2); v_fund text := coalesce(app.jtext(p, 'funding'), 'paid');
  v_date date := (app.jtext(p, 'purchase_date'))::date; v_res_val numeric; v_open numeric := round(coalesce(app.jnum(p, 'opening_accumulated'), 0), 2);
  v_lines jsonb;
begin
  perform app.require_permission('assets.manage');
  select * into c from public.asset_categories where id = app.juuid(p, 'category_id') and is_active;
  if not found then raise exception 'Choose an asset category' using errcode = '22023'; end if;
  if coalesce(v_cost, 0) <= 0 then raise exception 'Enter the cost' using errcode = '22023'; end if;
  if v_date is null or v_date > app.today() then raise exception 'Enter the purchase date (not in the future)' using errcode = '22023'; end if;
  if v_fund not in ('paid','opening','recorded') then raise exception 'Say how the asset was paid for' using errcode = '22023'; end if;
  if v_fund <> 'opening' and v_open > 0 then raise exception 'Depreciation to date is only for assets owned before go-live' using errcode = '22023'; end if;
  if v_fund = 'paid' then m := app.money_account(app.juuid(p, 'money_account_id')); end if;
  v_res_val := coalesce(app.jnum(p, 'residual_value'), round(v_cost * c.residual_percent / 100, 2));
  v_done := app.idempotency_begin(p_client_txn_id, 'register_asset');
  if v_done is not null then return v_done; end if;
  perform app.set_context(null, p_client_txn_id, 'register_asset');
  v_no := app.next_document_number('FA');
  insert into public.fixed_assets (id, asset_no, name, category_id, serial_no, description, location_id, responsible_employee_id, supplier_name,
    purchase_date, cost, residual_value, method, useful_life_months, rate_percent, depreciation_start, opening_accumulated, accumulated,
    warranty_until, funding, money_account_id, created_by, client_txn_id)
  values (v, v_no, trim(app.jtext(p, 'name')), c.id, app.jtext(p, 'serial_no'), app.jtext(p, 'description'), app.juuid(p, 'location_id'),
    app.juuid(p, 'responsible_employee_id'), app.jtext(p, 'supplier_name'), v_date, v_cost, v_res_val,
    coalesce(app.jtext(p, 'method'), c.method), coalesce(app.jint(p, 'useful_life_months'), c.useful_life_months),
    coalesce(app.jnum(p, 'rate_percent'), c.rate_percent),
    coalesce((app.jtext(p, 'depreciation_start'))::date, date_trunc('month', v_date)::date), v_open, v_open,
    (app.jtext(p, 'warranty_until'))::date, v_fund, m.id, app.current_user_id(), p_client_txn_id);

  if v_fund = 'paid' then
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', c.asset_account_id, 'debit', v_cost, 'credit', 0, 'memo', v_no),
      jsonb_build_object('account_id', m.account_id, 'debit', 0, 'credit', v_cost, 'memo', 'Bought ' || trim(app.jtext(p, 'name'))));
  elsif v_fund = 'opening' then
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', c.asset_account_id, 'debit', v_cost, 'credit', 0, 'memo', v_no),
      jsonb_build_object('account_key', 'opening_equity', 'debit', 0, 'credit', v_cost - v_open, 'memo', 'Opening balance'));
    if v_open > 0 then
      v_lines := v_lines || jsonb_build_object('account_key', 'accum_depreciation', 'debit', 0, 'credit', v_open, 'memo', 'Depreciation before go-live');
    end if;
  end if;
  if v_lines is not null then
    v_je := app.post_journal(case when v_fund = 'opening' then app.today() else app.open_posting_date(v_date) end,
      format('Fixed asset %s — %s', v_no, trim(app.jtext(p, 'name'))), 'asset.acquired', v_lines, 'fixed_asset', v);
    update public.fixed_assets set journal_entry_id = v_je where id = v;
  end if;
  if app.juuid(p, 'vehicle_id') is not null then
    update public.vehicles set asset_id = v where id = app.juuid(p, 'vehicle_id');
  end if;
  v_res := jsonb_build_object('asset_id', v, 'asset_no', v_no);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Details that do not change the books
create or replace function public.update_asset(p_id uuid, p jsonb, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_permission('assets.manage');
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  update public.fixed_assets set name = coalesce(nullif(trim(app.jtext(p, 'name')), ''), name), serial_no = app.jtext(p, 'serial_no'),
         description = app.jtext(p, 'description'), location_id = app.juuid(p, 'location_id'),
         responsible_employee_id = app.juuid(p, 'responsible_employee_id'), warranty_until = (app.jtext(p, 'warranty_until'))::date,
         supplier_name = app.jtext(p, 'supplier_name')
   where id = p_id;
  if not found then raise exception 'Asset not found' using errcode = 'P0002'; end if;
end $$;

-- Depreciation for one asset for one month (0 when nothing is due)
create or replace function app.asset_month_depreciation(a public.fixed_assets, p_year integer, p_month integer)
returns numeric language plpgsql stable set search_path = '' as $$
declare v_month_start date := make_date(p_year, p_month, 1); v_left numeric; v numeric;
begin
  if a.status <> 'active' then return 0; end if;  -- run depreciation up to the disposal month before disposing
  if date_trunc('month', a.depreciation_start) > v_month_start then return 0; end if;
  v_left := a.cost - a.residual_value - a.accumulated;
  if v_left <= 0 then return 0; end if;
  if a.method = 'straight_line' then
    v := round((a.cost - a.residual_value) / a.useful_life_months, 2);
  else
    v := round((a.cost - a.accumulated) * a.rate_percent / 100 / 12, 2);
  end if;
  return least(v, v_left);
end $$;

create or replace function public.run_depreciation(p_year integer, p_month integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid := gen_random_uuid(); v_no text; a public.fixed_assets; v_amt numeric; v_total numeric := 0; n integer := 0;
        v_end date := (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date; v_je uuid;
begin
  perform app.require_permission('assets.manage');
  if make_date(p_year, p_month, 1) > date_trunc('month', app.today())::date then
    raise exception 'Depreciation cannot be run for a future month' using errcode = '22023';
  end if;
  if exists (select 1 from public.depreciation_runs where dep_year = p_year and dep_month = p_month) then
    raise exception 'Depreciation for %-% has already been run', p_year, lpad(p_month::text, 2, '0') using errcode = '22023';
  end if;
  if exists (select 1 from public.depreciation_runs where (dep_year, dep_month) > (p_year, p_month)) then
    raise exception 'A later month has already been depreciated — run months in order' using errcode = '22023';
  end if;
  perform app.set_context(null, null, 'depreciation');
  v_no := app.next_document_number('DEP', null, v_end);
  insert into public.depreciation_runs (id, run_no, dep_year, dep_month, created_by) values (v, v_no, p_year, p_month, app.current_user_id());
  for a in select * from public.fixed_assets where status = 'active' order by asset_no for update loop
    v_amt := app.asset_month_depreciation(a, p_year, p_month);
    continue when v_amt <= 0;
    insert into public.asset_depreciation (asset_id, run_id, dep_year, dep_month, amount) values (a.id, v, p_year, p_month, v_amt);
    update public.fixed_assets set accumulated = accumulated + v_amt where id = a.id;
    v_total := v_total + v_amt; n := n + 1;
  end loop;
  if v_total > 0 then
    v_je := app.post_journal(app.open_posting_date(v_end), format('Depreciation %s', to_char(v_end, 'FMMonth YYYY')), 'asset.depreciation',
      jsonb_build_array(jsonb_build_object('account_key', 'exp_depreciation', 'debit', v_total, 'credit', 0, 'memo', 'Depreciation'),
                        jsonb_build_object('account_key', 'accum_depreciation', 'debit', 0, 'credit', v_total, 'memo', 'Depreciation')),
      'depreciation_run', v);
  end if;
  update public.depreciation_runs set assets = n, total = v_total, journal_entry_id = v_je where id = v;
  return jsonb_build_object('run_no', v_no, 'assets', n, 'total', v_total);
end $$;

create or replace function public.dispose_asset(p_id uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; a public.fixed_assets; c public.asset_categories; m public.money_accounts; v_proceeds numeric := round(coalesce(app.jnum(p, 'proceeds'), 0), 2);
        v_date date := coalesce((app.jtext(p, 'disposed_on'))::date, app.today()); v_nbv numeric; v_gain numeric; v_lines jsonb; v_je uuid; v_res jsonb;
begin
  perform app.require_permission('assets.manage');
  if nullif(trim(app.jtext(p, 'reason')), '') is null then raise exception 'Say why the asset is disposed of' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'dispose_asset');
  if v_done is not null then return v_done; end if;
  select * into a from public.fixed_assets where id = p_id for update;
  if not found or a.status <> 'active' then raise exception 'Active asset not found' using errcode = 'P0002'; end if;
  if v_date > app.today() or v_date < a.purchase_date then raise exception 'Check the disposal date' using errcode = '22023'; end if;
  if v_proceeds > 0 then m := app.money_account(app.juuid(p, 'money_account_id')); end if;
  select * into c from public.asset_categories where id = a.category_id;
  perform app.set_context(trim(app.jtext(p, 'reason')), p_client_txn_id, 'dispose_asset');
  v_nbv := a.cost - a.accumulated;
  v_gain := v_proceeds - v_nbv;
  v_lines := jsonb_build_array(jsonb_build_object('account_id', c.asset_account_id, 'debit', 0, 'credit', a.cost, 'memo', 'Cost removed'));
  if a.accumulated > 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'accum_depreciation', 'debit', a.accumulated, 'credit', 0, 'memo', 'Depreciation removed');
  end if;
  if v_proceeds > 0 then
    v_lines := v_lines || jsonb_build_object('account_id', m.account_id, 'debit', v_proceeds, 'credit', 0, 'memo', 'Sale proceeds');
  end if;
  if v_gain > 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'gain_on_disposal', 'debit', 0, 'credit', v_gain, 'memo', 'Gain on disposal');
  elsif v_gain < 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'loss_on_disposal', 'debit', -v_gain, 'credit', 0, 'memo', 'Loss on disposal');
  end if;
  v_je := app.post_journal(v_date, format('Disposal of %s — %s', a.asset_no, a.name), 'asset.disposed', v_lines, 'fixed_asset', a.id);
  update public.fixed_assets set status = 'disposed', disposed_on = v_date, disposal_proceeds = v_proceeds,
         disposal_note = trim(app.jtext(p, 'reason')), disposal_entry_id = v_je where id = a.id;
  update public.vehicles set is_active = false where asset_id = a.id and app.jbool(p, 'deactivate_vehicle', true);
  v_res := jsonb_build_object('book_value', v_nbv, 'gain', v_gain);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

alter table public.asset_categories   enable row level security;
alter table public.fixed_assets       enable row level security;
alter table public.depreciation_runs  enable row level security;
alter table public.asset_depreciation enable row level security;
create policy asset_categories_read on public.asset_categories for select to authenticated
  using (app.has_permission('assets.manage') or app.has_permission('accounting.view') or app.has_permission('fleet.manage'));
create policy fixed_assets_read on public.fixed_assets for select to authenticated
  using (app.has_permission('assets.manage') or app.has_permission('accounting.view') or app.has_permission('fleet.manage'));
create policy depreciation_runs_read on public.depreciation_runs for select to authenticated
  using (app.has_permission('assets.manage') or app.has_permission('accounting.view'));
create policy asset_depreciation_read on public.asset_depreciation for select to authenticated
  using (app.has_permission('assets.manage') or app.has_permission('accounting.view') or app.has_permission('fleet.manage'));

-- >>> 20261006000032_fleet.sql
-- =====================================================================
-- OLA Water ERP — Phase 2C
-- 0032: fleet — vehicle details, documents and expiry, fuel logs,
--       services and repairs, driver expenses on the road
-- =====================================================================
-- Every fuel fill, repair and licence cost is an expense (category, vehicle,
-- approval above the limit, posted to the ledger). Drivers record fuel,
-- tolls and small repairs paid from the cash they carry; the check-in then
-- expects that much less cash. A rejected driver expense becomes a cash
-- shortage the driver owes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Vehicles: more detail
-- ---------------------------------------------------------------------
alter table public.vehicles
  add column make                   text,
  add column model                  text,
  add column year_made              integer check (year_made between 1950 and 2100),
  add column fuel_type              text check (fuel_type in ('diesel','petrol','electric','hybrid','other')),
  add column odometer_km            integer check (odometer_km >= 0),
  add column assigned_driver_id     uuid references public.profiles(id),
  add column service_interval_km    integer check (service_interval_km > 0),
  add column service_interval_days  integer check (service_interval_days > 0),
  add column last_service_km        integer,
  add column last_service_date      date,
  add column asset_id               uuid unique references public.fixed_assets(id);

create table public.vehicle_documents (
  id           uuid primary key default gen_random_uuid(),
  vehicle_id   uuid not null references public.vehicles(id),
  doc_type     text not null check (doc_type in ('insurance','revenue_licence','emission_test','fitness','other')),
  doc_no       text,
  provider     text,
  issued_on    date,
  expires_on   date not null,
  cost         numeric(14,2) check (cost >= 0),
  expense_id   uuid references public.expenses(id),
  notes        text,
  created_at   timestamptz not null default now(),
  created_by   uuid
);
create index vehicle_documents_vehicle_idx on public.vehicle_documents (vehicle_id, doc_type, expires_on desc);
create trigger vehicle_documents_audit after insert or update on public.vehicle_documents for each row execute function app.audit_row('fleet');

create table public.fuel_logs (
  id           uuid primary key default gen_random_uuid(),
  vehicle_id   uuid not null references public.vehicles(id),
  fuel_date    date not null,
  litres       numeric(10,2) not null check (litres > 0),
  amount       numeric(14,2) not null check (amount > 0),
  odometer_km  integer check (odometer_km >= 0),
  station      text,
  driver_id    uuid references public.profiles(id),
  run_id       uuid references public.route_runs(id),
  expense_id   uuid references public.expenses(id),
  created_at   timestamptz not null default now(),
  created_by   uuid
);
create index fuel_logs_vehicle_idx on public.fuel_logs (vehicle_id, fuel_date desc);
create trigger fuel_logs_audit after insert on public.fuel_logs for each row execute function app.audit_row('fleet');

create table public.vehicle_services (
  id            uuid primary key default gen_random_uuid(),
  vehicle_id    uuid not null references public.vehicles(id),
  service_date  date not null,
  kind          text not null check (kind in ('service','repair','tyres','battery','accident','other')),
  description   text not null,
  odometer_km   integer check (odometer_km >= 0),
  cost          numeric(14,2) not null default 0 check (cost >= 0),
  vendor        text,
  expense_id    uuid references public.expenses(id),
  next_due_km   integer,
  next_due_date date,
  created_at    timestamptz not null default now(),
  created_by    uuid
);
create index vehicle_services_vehicle_idx on public.vehicle_services (vehicle_id, service_date desc);
create trigger vehicle_services_audit after insert on public.vehicle_services for each row execute function app.audit_row('fleet');

-- ---------------------------------------------------------------------
-- Expenses: paid from the driver's cash, linked to a run
-- ---------------------------------------------------------------------
alter table public.expenses
  add column run_id     uuid references public.route_runs(id),
  add column driver_id  uuid references public.profiles(id);
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'public.expenses'::regclass and contype = 'c'
            and (pg_get_constraintdef(oid) like '%pay_method%') loop
    execute format('alter table public.expenses drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.expenses add constraint expenses_pay_method_check
  check (pay_method in ('cash','petty_cash','bank_transfer','cheque','card','on_credit','driver_cash'));
alter table public.expenses add constraint expenses_money_account_check
  check (pay_method in ('on_credit','driver_cash') or money_account_id is not null);
alter table public.expenses add constraint expenses_driver_cash_check
  check (pay_method <> 'driver_cash' or (run_id is not null and driver_id is not null));
create index expenses_run_idx on public.expenses (run_id) where run_id is not null;
create index expenses_vehicle_idx on public.expenses (vehicle_id, expense_date) where vehicle_id is not null;

alter table public.expense_categories add column driver_allowed boolean not null default false;

create or replace function app.post_expense(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare x public.expenses; c public.expense_categories; m public.money_accounts; v_je uuid; v_lines jsonb;
begin
  select * into x from public.expenses where id = p_id for update;
  select * into c from public.expense_categories where id = x.category_id;
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', c.account_id, 'debit', x.net_amount, 'credit', 0, 'memo', c.name,
                       'party_type', case when x.supplier_id is not null then 'supplier' end, 'party_id', x.supplier_id));
  if x.vat_amount > 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'vat_input', 'debit', x.vat_amount, 'credit', 0, 'memo', 'VAT input');
  end if;
  if x.pay_method = 'on_credit' then
    v_lines := v_lines || jsonb_build_object('account_key', 'expenses_payable', 'debit', 0, 'credit', x.total, 'memo', 'To pay: ' || coalesce(x.payee, ''),
                                             'party_type', case when x.supplier_id is not null then 'supplier' end, 'party_id', x.supplier_id);
  elsif x.pay_method = 'driver_cash' then
    v_lines := v_lines || jsonb_build_object('account_key', 'driver_cash', 'debit', 0, 'credit', x.total, 'memo', 'Paid by the driver',
                                             'party_type', 'driver', 'party_id', x.driver_id);
  else
    select * into m from public.money_accounts where id = x.money_account_id;
    v_lines := v_lines || jsonb_build_object('account_id', m.account_id, 'debit', 0, 'credit', x.total, 'memo', 'Paid: ' || coalesce(x.payee, ''));
  end if;
  v_je := app.post_journal(x.expense_date, format('Expense %s — %s: %s', x.expense_no, c.name, x.description), 'expense.recorded',
    v_lines, 'expense', x.id, x.location_id);
  update public.expenses set journal_entry_id = v_je,
         status = case when x.pay_method = 'on_credit' then 'approved' else 'paid' end,
         paid_at = case when x.pay_method = 'on_credit' then null else now() end,
         paid_by = case when x.pay_method = 'on_credit' then null else coalesce(x.approved_by, x.created_by) end,
         paid_from = case when x.pay_method in ('on_credit','driver_cash') then null else x.money_account_id end
   where id = x.id;
end $$;

-- Shared by fleet and driver expenses. The caller checks permissions.
--   p: {expense_date, category_code | category_id, description, payee, vehicle_id, asset_id, run_id, driver_id, location_id,
--       net_amount, vat_amount, pay_method, money_account_id, reference, receipt_path}
create or replace function app.create_expense(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid := gen_random_uuid(); v_no text; c public.expense_categories; m public.money_accounts; v_limit numeric; v_auto boolean;
        v_net numeric := round(app.jnum(p, 'net_amount'), 2); v_vat numeric := round(coalesce(app.jnum(p, 'vat_amount'), 0), 2);
        v_method text := coalesce(app.jtext(p, 'pay_method'), 'cash'); v_date date := coalesce((app.jtext(p, 'expense_date'))::date, app.today());
begin
  if app.juuid(p, 'category_id') is not null then
    select * into c from public.expense_categories where id = app.juuid(p, 'category_id') and is_active;
  else
    select * into c from public.expense_categories where code = app.jtext(p, 'category_code') and is_active;
  end if;
  if c.id is null then raise exception 'Choose a category' using errcode = '22023'; end if;
  if coalesce(v_net, 0) <= 0 then raise exception 'Enter the amount' using errcode = '22023'; end if;
  if v_date > app.today() then raise exception 'An expense cannot be dated in the future' using errcode = '22023'; end if;
  if v_method not in ('on_credit','driver_cash') then
    m := app.money_account(app.juuid(p, 'money_account_id'));
    if (v_method = 'cash' and m.kind <> 'cash') or (v_method = 'petty_cash' and m.kind <> 'petty_cash')
       or (v_method in ('bank_transfer','cheque','card') and m.kind <> 'bank') then
      raise exception 'The account does not match how it was paid' using errcode = '22023';
    end if;
  end if;
  v_limit := coalesce((app.get_setting('approvals.expense_amount') #>> '{}')::numeric, 0);
  v_auto := v_net + v_vat < v_limit or app.has_permission('expenses.approve');
  v_no := app.next_document_number('EXP');
  insert into public.expenses (id, expense_no, expense_date, category_id, description, payee, location_id, vehicle_id, asset_id, run_id, driver_id,
    net_amount, vat_amount, total, pay_method, money_account_id, reference, receipt_path, status, created_by, approved_at, approved_by)
  values (v, v_no, v_date, c.id, coalesce(nullif(trim(app.jtext(p, 'description')), ''), c.name), app.jtext(p, 'payee'), app.juuid(p, 'location_id'),
    app.juuid(p, 'vehicle_id'), app.juuid(p, 'asset_id'), app.juuid(p, 'run_id'), app.juuid(p, 'driver_id'), v_net, v_vat, v_net + v_vat,
    v_method, m.id, nullif(trim(app.jtext(p, 'reference')), ''), app.jtext(p, 'receipt_path'), 'pending_approval', app.current_user_id(),
    case when v_auto then now() end, case when v_auto then app.current_user_id() end);
  if v_auto then perform app.post_expense(v); end if;
  return v;
end $$;

-- Rejecting a driver's expense after check-in: the driver owes that cash
create or replace function public.decide_expense(p_id uuid, p_approve boolean, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare x public.expenses; r public.route_runs;
begin
  perform app.require_permission('expenses.approve');
  select * into x from public.expenses where id = p_id for update;
  if not found then raise exception 'Expense not found' using errcode = 'P0002'; end if;
  if x.status <> 'pending_approval' then raise exception 'This expense has already been decided' using errcode = '22023'; end if;
  if x.created_by = app.current_user_id() and not app.is_super_admin(app.current_user_id()) then
    raise exception 'Someone else must approve your own expense' using errcode = '42501';
  end if;
  if not p_approve and nullif(trim(p_note), '') is null then raise exception 'Give a reason for rejecting' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_note), ''), null, case when p_approve then 'approve' else 'reject' end);
  if p_approve then
    update public.expenses set approved_at = now(), approved_by = app.current_user_id(), decision_note = nullif(trim(p_note), '') where id = p_id;
    perform app.post_expense(p_id);
  else
    update public.expenses set status = 'rejected', decision_note = trim(p_note), approved_by = app.current_user_id(), approved_at = now() where id = p_id;
    if x.pay_method = 'driver_cash' then
      select * into r from public.route_runs where id = x.run_id;
      if r.status in ('checked_in','closed') then
        perform app.raise_exception_record('cash_shortage',
          format('Driver expense %s (Rs. %s) was rejected — the driver must hand in that cash: %s', x.expense_no,
                 to_char(x.total, 'FM999,999,990.00'), trim(p_note)),
          'warning', r.id, null, null, null, null, null, null, x.total, 0);
        update public.route_runs set status = 'checked_in' where id = r.id and status = 'closed';
      end if;
    end if;
  end if;
  return jsonb_build_object('status', (select status from public.expenses where id = p_id));
end $$;

-- ---------------------------------------------------------------------
-- Fleet records
-- ---------------------------------------------------------------------
create or replace function public.save_vehicle_details(p_vehicle uuid, p jsonb, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_permission('fleet.manage');
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  update public.vehicles set make = app.jtext(p, 'make'), model = app.jtext(p, 'model'), year_made = app.jint(p, 'year_made'),
         fuel_type = app.jtext(p, 'fuel_type'), assigned_driver_id = app.juuid(p, 'assigned_driver_id'),
         service_interval_km = app.jint(p, 'service_interval_km'), service_interval_days = app.jint(p, 'service_interval_days'),
         odometer_km = greatest(coalesce(odometer_km, 0), coalesce(app.jint(p, 'odometer_km'), 0)),
         last_service_km = coalesce(app.jint(p, 'last_service_km'), last_service_km),
         last_service_date = coalesce((app.jtext(p, 'last_service_date'))::date, last_service_date)
   where id = p_vehicle;
  if not found then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
end $$;

create or replace function app.vehicle_expense_payload(p jsonb, p_vehicle uuid, p_category text, p_description text, p_amount numeric)
returns jsonb language sql immutable as $$
  select jsonb_build_object('expense_date', p ->> 'date', 'category_code', p_category, 'description', p_description,
    'payee', p ->> 'payee', 'vehicle_id', p_vehicle, 'net_amount', p_amount, 'vat_amount', coalesce((p ->> 'vat_amount')::numeric, 0),
    'pay_method', coalesce(p ->> 'pay_method', 'cash'), 'money_account_id', p ->> 'money_account_id', 'reference', p ->> 'reference',
    'receipt_path', p ->> 'receipt_path', 'driver_id', p ->> 'driver_id', 'run_id', p ->> 'run_id')
$$;

--   p: {vehicle_id, date, litres, amount, odometer_km, station, driver_id, pay_method, money_account_id, reference, receipt_path}
create or replace function public.record_fuel(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; ve public.vehicles; v_exp uuid; v uuid := gen_random_uuid(); v_res jsonb;
begin
  perform app.require_permission('fleet.manage');
  select * into ve from public.vehicles where id = app.juuid(p, 'vehicle_id');
  if not found then raise exception 'Choose a vehicle' using errcode = '22023'; end if;
  if coalesce(app.jnum(p, 'litres'), 0) <= 0 then raise exception 'Enter the litres' using errcode = '22023'; end if;
  if app.jint(p, 'odometer_km') is not null and app.jint(p, 'odometer_km') < coalesce(ve.odometer_km, 0) - 5 then
    raise exception 'The odometer reading is lower than the last one (% km)', ve.odometer_km using errcode = '22023';
  end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'record_fuel');
  if v_done is not null then return v_done; end if;
  perform app.set_context(null, p_client_txn_id, 'fuel');
  v_exp := app.create_expense(app.vehicle_expense_payload(p || jsonb_build_object('payee', coalesce(app.jtext(p, 'station'), app.jtext(p, 'payee'))),
             ve.id, 'FUEL', format('Fuel %s L — %s', app.jnum(p, 'litres'), ve.registration_no), app.jnum(p, 'amount')));
  insert into public.fuel_logs (id, vehicle_id, fuel_date, litres, amount, odometer_km, station, driver_id, expense_id, created_by)
  values (v, ve.id, coalesce((app.jtext(p, 'date'))::date, app.today()), app.jnum(p, 'litres'), app.jnum(p, 'amount'), app.jint(p, 'odometer_km'),
          app.jtext(p, 'station'), app.juuid(p, 'driver_id'), v_exp, app.current_user_id());
  update public.vehicles set odometer_km = greatest(coalesce(odometer_km, 0), coalesce(app.jint(p, 'odometer_km'), 0)) where id = ve.id;
  v_res := jsonb_build_object('fuel_log_id', v, 'expense_status', (select status from public.expenses where id = v_exp));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

--   p: {vehicle_id, date, kind, description, odometer_km, cost, vendor, next_due_km, next_due_date, pay_method, money_account_id, reference, receipt_path}
create or replace function public.record_vehicle_service(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; ve public.vehicles; v_exp uuid; v uuid := gen_random_uuid(); v_res jsonb; v_kind text := coalesce(app.jtext(p, 'kind'), 'service');
        v_date date := coalesce((app.jtext(p, 'date'))::date, app.today()); v_km integer := app.jint(p, 'odometer_km');
begin
  perform app.require_permission('fleet.manage');
  select * into ve from public.vehicles where id = app.juuid(p, 'vehicle_id');
  if not found then raise exception 'Choose a vehicle' using errcode = '22023'; end if;
  if nullif(trim(app.jtext(p, 'description')), '') is null then raise exception 'Describe the work done' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'record_vehicle_service');
  if v_done is not null then return v_done; end if;
  perform app.set_context(null, p_client_txn_id, 'vehicle_service');
  if coalesce(app.jnum(p, 'cost'), 0) > 0 then
    v_exp := app.create_expense(app.vehicle_expense_payload(p || jsonb_build_object('payee', app.jtext(p, 'vendor')), ve.id, 'VEHICLE_REPAIR',
               format('%s — %s: %s', initcap(v_kind), ve.registration_no, trim(app.jtext(p, 'description'))), app.jnum(p, 'cost')));
  end if;
  insert into public.vehicle_services (id, vehicle_id, service_date, kind, description, odometer_km, cost, vendor, expense_id, next_due_km, next_due_date, created_by)
  values (v, ve.id, v_date, v_kind, trim(app.jtext(p, 'description')), v_km, coalesce(app.jnum(p, 'cost'), 0), app.jtext(p, 'vendor'), v_exp,
          coalesce(app.jint(p, 'next_due_km'), case when v_kind = 'service' and v_km is not null and ve.service_interval_km is not null then v_km + ve.service_interval_km end),
          coalesce((app.jtext(p, 'next_due_date'))::date, case when v_kind = 'service' and ve.service_interval_days is not null then v_date + ve.service_interval_days end),
          app.current_user_id());
  update public.vehicles set odometer_km = greatest(coalesce(odometer_km, 0), coalesce(v_km, 0)),
         last_service_km = case when v_kind = 'service' then coalesce(v_km, last_service_km) else last_service_km end,
         last_service_date = case when v_kind = 'service' then v_date else last_service_date end
   where id = ve.id;
  v_res := jsonb_build_object('service_id', v, 'expense_status', (select status from public.expenses where id = v_exp));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

--   p: {vehicle_id, doc_type, doc_no, provider, issued_on, expires_on, cost, pay_method, money_account_id, reference, notes}
create or replace function public.record_vehicle_document(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; ve public.vehicles; v_exp uuid; v uuid := gen_random_uuid(); v_res jsonb;
begin
  perform app.require_permission('fleet.manage');
  select * into ve from public.vehicles where id = app.juuid(p, 'vehicle_id');
  if not found then raise exception 'Choose a vehicle' using errcode = '22023'; end if;
  if app.jtext(p, 'expires_on') is null then raise exception 'Enter the expiry date' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'record_vehicle_document');
  if v_done is not null then return v_done; end if;
  perform app.set_context(null, p_client_txn_id, 'vehicle_document');
  if coalesce(app.jnum(p, 'cost'), 0) > 0 then
    v_exp := app.create_expense(app.vehicle_expense_payload(p || jsonb_build_object('payee', app.jtext(p, 'provider'),
               'date', coalesce(app.jtext(p, 'issued_on'), app.today()::text)), ve.id, 'VEHICLE_DOCS',
               format('%s — %s', initcap(replace(app.jtext(p, 'doc_type'), '_', ' ')), ve.registration_no), app.jnum(p, 'cost')));
  end if;
  insert into public.vehicle_documents (id, vehicle_id, doc_type, doc_no, provider, issued_on, expires_on, cost, expense_id, notes, created_by)
  values (v, ve.id, app.jtext(p, 'doc_type'), app.jtext(p, 'doc_no'), app.jtext(p, 'provider'), (app.jtext(p, 'issued_on'))::date,
          (app.jtext(p, 'expires_on'))::date, app.jnum(p, 'cost'), v_exp, app.jtext(p, 'notes'), app.current_user_id());
  v_res := jsonb_build_object('document_id', v);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- An asset's maintenance / repair (recorded as an expense)
create or replace function public.record_asset_maintenance(p_asset uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; a public.fixed_assets; v_exp uuid; v_res jsonb;
begin
  perform app.require_permission('assets.manage');
  select * into a from public.fixed_assets where id = p_asset and status = 'active';
  if not found then raise exception 'Active asset not found' using errcode = 'P0002'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'record_asset_maintenance');
  if v_done is not null then return v_done; end if;
  perform app.set_context(null, p_client_txn_id, 'asset_maintenance');
  v_exp := app.create_expense(jsonb_build_object('expense_date', app.jtext(p, 'date'), 'category_code', coalesce(app.jtext(p, 'category_code'), 'EQUIPMENT'),
    'description', format('%s — %s', a.name, trim(app.jtext(p, 'description'))), 'payee', app.jtext(p, 'vendor'), 'asset_id', a.id,
    'location_id', a.location_id, 'net_amount', app.jnum(p, 'cost'), 'vat_amount', coalesce(app.jnum(p, 'vat_amount'), 0),
    'pay_method', coalesce(app.jtext(p, 'pay_method'), 'cash'), 'money_account_id', app.jtext(p, 'money_account_id'),
    'reference', app.jtext(p, 'reference')));
  v_res := jsonb_build_object('expense_id', v_exp, 'status', (select status from public.expenses where id = v_exp));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- Driver expenses from the driver app (works offline: queued, idempotent)
--   p: {category_code, amount, description, litres, odometer_km, receipt_path, expense_date}
-- ---------------------------------------------------------------------
create or replace function public.driver_record_expense(p_run uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; r public.route_runs; c public.expense_categories; v_exp uuid; v_res jsonb; ve public.vehicles;
begin
  r := app.require_run_access(p_run);
  v_done := app.idempotency_begin(p_client_txn_id, 'driver_record_expense');
  if v_done is not null then return v_done; end if;
  if r.status not in ('loaded','in_progress') then raise exception 'Expenses can be added only while the run is on the road' using errcode = '22023'; end if;
  select * into c from public.expense_categories where code = app.jtext(p, 'category_code') and is_active and driver_allowed;
  if not found then raise exception 'Choose fuel, tolls & parking or a repair' using errcode = '22023'; end if;
  if coalesce(app.jnum(p, 'amount'), 0) <= 0 then raise exception 'Enter the amount' using errcode = '22023'; end if;
  if app.jnum(p, 'amount') > r.cash_float + coalesce((select sum(amount) from public.payments where run_id = r.id and method = 'cash' and status = 'received'), 0) then
    raise exception 'That is more than the cash you are carrying' using errcode = '22023';
  end if;
  select * into ve from public.vehicles where id = r.vehicle_id;
  perform app.set_context(app.jtext(p, 'description'), p_client_txn_id, 'driver_expense');
  v_exp := app.create_expense(jsonb_build_object('expense_date', coalesce(app.jtext(p, 'expense_date'), app.today()::text),
    'category_id', c.id, 'description', coalesce(nullif(trim(app.jtext(p, 'description')), ''), c.name) || ' — ' || r.run_no,
    'vehicle_id', r.vehicle_id, 'run_id', r.id, 'driver_id', r.driver_id, 'net_amount', app.jnum(p, 'amount'),
    'pay_method', 'driver_cash', 'receipt_path', app.jtext(p, 'receipt_path'), 'payee', app.jtext(p, 'payee')));
  if c.code = 'FUEL' and coalesce(app.jnum(p, 'litres'), 0) > 0 then
    insert into public.fuel_logs (vehicle_id, fuel_date, litres, amount, odometer_km, station, driver_id, run_id, expense_id, created_by)
    values (r.vehicle_id, app.today(), app.jnum(p, 'litres'), app.jnum(p, 'amount'), app.jint(p, 'odometer_km'), app.jtext(p, 'payee'),
            r.driver_id, r.id, v_exp, app.current_user_id());
    update public.vehicles set odometer_km = greatest(coalesce(odometer_km, 0), coalesce(app.jint(p, 'odometer_km'), 0)) where id = r.vehicle_id;
  end if;
  v_res := jsonb_build_object('expense_id', v_exp, 'expense_no', (select expense_no from public.expenses where id = v_exp),
                              'status', (select status from public.expenses where id = v_exp));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

alter table public.vehicle_documents enable row level security;
alter table public.fuel_logs         enable row level security;
alter table public.vehicle_services  enable row level security;
create policy vehicle_documents_read on public.vehicle_documents for select to authenticated
  using (app.has_permission('fleet.manage') or app.has_permission('deliveries.manage') or app.has_permission('routes.manage'));
create policy fuel_logs_read on public.fuel_logs for select to authenticated
  using (app.has_permission('fleet.manage') or app.has_permission('expenses.view') or driver_id = app.current_user_id());
create policy vehicle_services_read on public.vehicle_services for select to authenticated
  using (app.has_permission('fleet.manage') or app.has_permission('deliveries.manage'));

-- ---------------------------------------------------------------------
-- Check-in: the driver's expenses reduce the cash expected
-- (same as Phase 1A except the marked lines)
-- ---------------------------------------------------------------------
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
  -- fuel, tolls and repairs the driver paid from that cash
  v_cash_expected := v_cash_expected - coalesce((select sum(total) from public.expenses
                       where run_id = p_run and pay_method = 'driver_cash' and status <> 'rejected'), 0);
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

-- Driver app: run data now includes the driver's expenses and only products for sale
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
                   from public.products where is_active and item_type = 'finished_good'),
    'vehicle_stock', (select coalesce(jsonb_agg(jsonb_build_object('product_id', product_id, 'qty', qty)), '[]')
                        from public.inventory_balances where location_id = v_veh and qty > 0),
    'vehicle_bottles', (select coalesce(jsonb_agg(jsonb_build_object('company_id', company_id, 'bottle_type_id', bottle_type_id,
                          'fill_state', fill_state, 'qty', qty)), '[]')
                          from public.bottle_balances where holder_type = 'location' and holder_id = v_veh and qty <> 0),
    'cash_collected', (select coalesce(sum(amount), 0) from public.payments where run_id = r.id and method = 'cash' and status = 'received'),
    'driver_expenses', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'expense_no', x.expense_no, 'category', c.name, 'total', x.total,
                          'status', x.status, 'description', x.description) order by x.created_at), '[]')
                          from public.expenses x join public.expense_categories c on c.id = x.category_id
                         where x.run_id = r.id and x.pay_method = 'driver_cash'),
    'expense_categories', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name) order by sort_order), '[]')
                             from public.expense_categories where driver_allowed and is_active),
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

-- >>> 20261006000033_phase2c_reference_data.sql
-- =====================================================================
-- OLA Water ERP — Phase 2C
-- 0033: accounts, statutory rates, APIT table, pay components, leave types,
--       asset categories, expense categories, numbering, settings, roles
-- =====================================================================

insert into public.accounts (code, name, account_type, system_key, parent_id)
select v.code, v.name, v.type, v.key, (select id from public.accounts where code = v.parent)
  from (values
    ('1350', 'Staff Salary Advances',           'asset',     'staff_advances',     '1000'),
    ('2430', 'Other Payroll Deductions Payable','liability', 'payroll_deductions', '2000'),
    ('4920', 'Gain on Disposal of Assets',      'income',    'gain_on_disposal',   '4000'),
    ('6145', 'EPF & ETF — Employer',            'expense',   'exp_epf_etf',        '6000'),
    ('6165', 'Vehicle Insurance & Licences',    'expense',   'exp_vehicle_docs',   '6000'),
    ('6410', 'Loss on Disposal of Assets',      'expense',   'loss_on_disposal',   '6000')
  ) as v(code, name, type, key, parent)
 where not exists (select 1 from public.accounts a where a.code = v.code);

-- Statutory contributions (Sri Lanka). Change them from a date in Payroll → Rates.
insert into public.payroll_statutory_rates (code, rate_percent, effective_from) values
  ('epf_employee', 8, date '2000-01-01'),
  ('epf_employer', 12, date '2000-01-01'),
  ('etf_employer', 3, date '2000-01-01');

-- APIT Table 1 (primary employment), monthly, from 1 April 2025:
-- first Rs. 150,000 tax free; 6% on the next 83,333; 18% next 41,667; 24% next 41,667; 30% next 41,667; 36% above.
-- YOUR ACCOUNTANT MUST CONFIRM THIS AGAINST THE CURRENT IRD TABLE.
insert into public.apit_bands (effective_from, band_no, band_width, rate_percent) values
  (date '2025-04-01', 1, 150000, 0),
  (date '2025-04-01', 2, 83333.33, 6),
  (date '2025-04-01', 3, 41666.67, 18),
  (date '2025-04-01', 4, 41666.67, 24),
  (date '2025-04-01', 5, 41666.67, 30),
  (date '2025-04-01', 6, null, 36);

insert into public.pay_components (code, name, kind, epf_liable, taxable, sort_order) values
  ('ALLOW_FIXED',   'Fixed allowance',        'earning',   true,  true, 10),
  ('ALLOW_TRAVEL',  'Travelling allowance',   'earning',   false, true, 20),
  ('ALLOW_ATTEND',  'Attendance allowance',   'earning',   false, true, 30),
  ('INCENTIVE',     'Incentive / commission', 'earning',   false, true, 40),
  ('BONUS',         'Bonus',                  'earning',   false, true, 50),
  ('DED_WELFARE',   'Welfare society',        'deduction', false, true, 60),
  ('DED_LOAN',      'Loan instalment',        'deduction', false, true, 70),
  ('DED_OTHER',     'Other deduction',        'deduction', false, true, 80);

insert into public.leave_types (code, name, days_per_year, is_paid) values
  ('ANNUAL',    'Annual leave',    14, true),
  ('CASUAL',    'Casual leave',     7, true),
  ('MEDICAL',   'Medical leave',    7, true),
  ('MATERNITY', 'Maternity leave', 84, true),
  ('NOPAY',     'No-pay leave',     0, false);

insert into public.departments (code, name) values
  ('ADMIN', 'Administration'), ('FIN', 'Finance'), ('PROD', 'Production'), ('QC', 'Quality'),
  ('WH', 'Warehouse'), ('DEL', 'Delivery'), ('SALES', 'Sales'), ('SHOPS', 'Water shops');

insert into public.asset_categories (code, name, asset_account_id, method, useful_life_months, rate_percent, residual_percent)
select v.code, v.name, (select id from public.accounts where system_key = v.key), v.method, v.life, v.rate, v.residual
  from (values
    ('PLANT',    'Plant & machinery (RO, filling, pumps)', 'fa_plant',    'straight_line', 120, null::numeric, 5),
    ('GEN',      'Generators',                              'fa_plant',    'straight_line', 120, null, 5),
    ('VEHICLE',  'Motor vehicles',                          'fa_vehicles', 'straight_line', 60,  null, 10),
    ('IT',       'Computers & IT equipment',                'fa_office',   'straight_line', 36,  null, 0),
    ('OFFICE',   'Office equipment & furniture',            'fa_office',   'straight_line', 60,  null, 0)
  ) as v(code, name, key, method, life, rate, residual);

-- Expense categories for vehicles and drivers
insert into public.expense_categories (code, name, account_id, sort_order, driver_allowed)
select v.code, v.name, (select id from public.accounts where system_key = v.key), v.ord, v.drv
  from (values ('VEHICLE_DOCS', 'Vehicle insurance & licences', 'exp_vehicle_docs', 15, false),
               ('TOLLS', 'Tolls & parking', 'exp_travel', 16, true)) as v(code, name, key, ord, drv)
 where not exists (select 1 from public.expense_categories c where c.code = v.code);
update public.expense_categories set driver_allowed = true where code in ('FUEL','VEHICLE_REPAIR');

insert into public.document_types (code, name, padding) values
  ('LVE', 'Leave request', 6), ('ADV', 'Salary advance', 6), ('PRL', 'Payroll run', 4), ('STP', 'Statutory payment', 6),
  ('FA', 'Fixed asset', 5), ('DEP', 'Depreciation run', 4)
on conflict (code) do nothing;

insert into public.setting_definitions (key, module, label, description, value_type, choices, min_value, max_value, sort_order) values
  ('payroll.nopay_divisor', 'Payroll', 'No-pay: divide the monthly basic by', 'One no-pay day = basic ÷ this number (commonly 30)', 'number', null, 1, 31, 90),
  ('payroll.ot_divisor', 'Payroll', 'Overtime: hourly rate = monthly basic ÷', 'Commonly 240', 'number', null, 100, 400, 91),
  ('payroll.ot_multiplier', 'Payroll', 'Overtime multiplier', 'Commonly 1.5 (time and a half)', 'number', null, 1, 3, 92),
  ('fleet.document_alert_days', 'Fleet', 'Warn before a vehicle document expires (days)', null, 'integer', null, 1, 120, 95),
  ('fleet.service_alert_km', 'Fleet', 'Warn this many km before a service is due', null, 'integer', null, 0, 5000, 96),
  ('company.epf_registration_no', 'Company', 'EPF employer registration number', 'Printed on the EPF / ETF monthly lists', 'text', null, null, null, 6);
insert into public.system_settings (key, value, effective_from) values
  ('payroll.nopay_divisor', '30', date '2026-01-01'),
  ('payroll.ot_divisor', '240', date '2026-01-01'),
  ('payroll.ot_multiplier', '1.5', date '2026-01-01'),
  ('fleet.document_alert_days', '30', date '2026-01-01'),
  ('fleet.service_alert_km', '500', date '2026-01-01'),
  ('company.epf_registration_no', '""', date '2026-01-01');

insert into public.permissions (code, module, action, description, sort_order) values
  ('payroll.approve', 'HR & Payroll', 'approve', 'Approve payroll, change statutory rates and pay components', 183)
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, x.code
  from public.roles r
  join (values
    ('finance_manager',    array['payroll.approve','assets.manage','hr.view','fleet.manage']),
    ('director',           array['payroll.approve']),
    ('hr_manager',         array['expenses.view']),
    ('accountant',         array['assets.manage']),
    ('operations_manager', array['expenses.manage']),
    ('delivery_manager',   array['expenses.manage'])
  ) as m(role_code, perms) on m.role_code = r.code
  cross join lateral unnest(m.perms) as x(code)
 where exists (select 1 from public.permissions p where p.code = x.code)
   and not exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_code = x.code);

-- >>> 20261006000034_phase2c_read_models.sql
-- =====================================================================
-- OLA Water ERP — Phase 2C
-- 0034: read models for HR, payroll, fleet and assets; grants
-- =====================================================================

-- Names only (no personal or salary data) for pickers in other modules
create or replace function public.employee_directory()
returns table (id uuid, emp_no text, full_name text, department text, job_title text, profile_id uuid, status text)
language sql stable security definer set search_path = '' as $$
  select e.id, e.emp_no, e.full_name, d.name, p.name, e.profile_id, e.status
    from public.employees e left join public.departments d on d.id = e.department_id left join public.positions p on p.id = e.position_id
   where app.has_permission('hr.view') or app.has_permission('fleet.manage') or app.has_permission('assets.manage')
      or app.has_permission('deliveries.manage') or app.has_permission('payroll.run')
   order by e.status, e.full_name
$$;

-- System logins, to link an employee or a vehicle's regular driver
create or replace function public.list_user_logins()
returns table (id uuid, full_name text, email text, is_driver boolean)
language sql stable security definer set search_path = '' as $$
  select p.id, p.full_name, p.email,
         exists (select 1 from public.user_roles ur join public.roles r on r.id = ur.role_id where ur.user_id = p.id and r.code = 'driver')
    from public.profiles p
   where p.is_active and (app.has_permission('hr.manage') or app.has_permission('fleet.manage') or app.has_permission('users.manage'))
   order by p.full_name
$$;

create or replace function app.leave_balances(p_employee uuid, p_year integer)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('leave_type_id', t.id, 'code', t.code, 'name', t.name, 'entitled', t.days_per_year,
           'taken', app.leave_taken(p_employee, t.id, p_year),
           'pending', (select coalesce(sum(days), 0) from public.leave_requests r where r.employee_id = p_employee and r.leave_type_id = t.id
                        and r.status = 'pending' and extract(year from r.from_date) = p_year),
           'left', case when t.days_per_year > 0 then t.days_per_year - app.leave_taken(p_employee, t.id, p_year) end) order by t.days_per_year desc), '[]')
    from public.leave_types t where t.is_active
$$;

create or replace function public.hr_overview()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  if not app.has_permission('hr.view') then raise exception 'Permission denied' using errcode = '42501'; end if;
  select jsonb_build_object(
    'headcount', (select count(*) from public.employees where status = 'active'),
    'by_department', (select coalesce(jsonb_agg(jsonb_build_object('department', coalesce(d.name, 'Not set'), 'count', x.n) order by x.n desc), '[]')
                        from (select department_id, count(*) n from public.employees where status = 'active' group by department_id) x
                        left join public.departments d on d.id = x.department_id),
    'on_leave_today', (select coalesce(jsonb_agg(jsonb_build_object('name', e.full_name, 'type', t.name)), '[]')
                         from public.attendance a join public.employees e on e.id = a.employee_id join public.leave_types t on t.id = a.leave_type_id
                        where a.work_date = app.today() and a.status = 'leave'),
    'attendance_today', (select count(*) from public.attendance where work_date = app.today()),
    'pending_leave', (select count(*) from public.leave_requests where status = 'pending'),
    'advances_outstanding', coalesce((select sum(outstanding) from public.salary_advances where status = 'active'), 0),
    'joined_this_month', (select count(*) from public.employees where join_date >= date_trunc('month', app.today())::date),
    'without_epf_no', (select count(*) from public.employees where status = 'active' and epf_applicable and epf_no is null)
  ) into v;
  return v;
end $$;

create or replace function public.employee_details(p_employee uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare e public.employees; v jsonb; v_pay boolean := app.has_permission('payroll.run') or app.has_permission('payroll.approve');
begin
  select * into e from public.employees where id = p_employee;
  if not found then raise exception 'Employee not found' using errcode = 'P0002'; end if;
  if not (app.has_permission('hr.view') or v_pay or e.profile_id = app.current_user_id()) then raise exception 'Permission denied' using errcode = '42501'; end if;
  select jsonb_build_object(
    'employee', case when v_pay then to_jsonb(e) else to_jsonb(e) - 'basic_salary' - 'daily_rate' end
                || jsonb_build_object('department', (select name from public.departments where id = e.department_id),
                                      'position', (select name from public.positions where id = e.position_id),
                                      'location', (select name from public.locations where id = e.location_id),
                                      'login', (select full_name || coalesce(' (' || email || ')', '') from public.profiles where id = e.profile_id)),
    'can_see_pay', v_pay,
    'pay_items', case when v_pay then (select coalesce(jsonb_agg(jsonb_build_object('component_id', c.id, 'name', c.name, 'kind', c.kind, 'amount', i.amount)
                    order by c.sort_order), '[]') from public.employee_pay_items i join public.pay_components c on c.id = i.component_id where i.employee_id = e.id) end,
    'leave', app.leave_balances(e.id, extract(year from app.today())::int),
    'leave_requests', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'request_no', r.request_no, 'type', t.name, 'from', r.from_date, 'to', r.to_date,
                         'days', r.days, 'status', r.status, 'reason', r.reason) order by r.from_date desc), '[]')
                         from (select * from public.leave_requests where employee_id = e.id order by from_date desc limit 20) r
                         join public.leave_types t on t.id = r.leave_type_id),
    'attendance_month', (select jsonb_build_object(
                           'present', count(*) filter (where status = 'present'), 'half_day', count(*) filter (where status = 'half_day'),
                           'absent', count(*) filter (where status = 'absent'), 'leave', count(*) filter (where status = 'leave'),
                           'ot_hours', coalesce(sum(ot_hours), 0))
                           from public.attendance where employee_id = e.id and work_date >= date_trunc('month', app.today())::date),
    'advances', case when v_pay then (select coalesce(jsonb_agg(jsonb_build_object('advance_no', advance_no, 'date', advance_date, 'amount', amount,
                    'installment', installment, 'outstanding', outstanding, 'status', status) order by advance_date desc), '[]')
                    from public.salary_advances where employee_id = e.id) end,
    'payslips', case when v_pay then (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'run_no', r.run_no, 'year', r.pay_year, 'month', r.pay_month,
                    'gross', s.gross, 'net', s.net, 'status', r.status) order by r.pay_year desc, r.pay_month desc), '[]')
                    from public.payslips s join public.payroll_runs r on r.id = s.run_id where s.employee_id = e.id and r.status <> 'cancelled') end
  ) into v;
  return v;
end $$;

create or replace function public.attendance_sheet(p_date date)
returns table (employee_id uuid, emp_no text, full_name text, department text, status text, leave_type text, time_in time, time_out time,
               ot_hours numeric, notes text, locked boolean)
language sql stable security definer set search_path = '' as $$
  select e.id, e.emp_no, e.full_name, d.name, a.status, t.name, a.time_in, a.time_out, coalesce(a.ot_hours, 0), a.notes,
         app.payroll_locked(p_date)
    from public.employees e
    left join public.departments d on d.id = e.department_id
    left join public.attendance a on a.employee_id = e.id and a.work_date = p_date
    left join public.leave_types t on t.id = a.leave_type_id
   where app.has_permission('hr.view') and e.join_date <= p_date and (e.end_date is null or e.end_date >= p_date)
   order by d.name nulls last, e.full_name
$$;

create or replace function public.payroll_run_details(p_run uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.payroll_runs; v jsonb;
begin
  if not (app.has_permission('payroll.run') or app.has_permission('payroll.approve')) then raise exception 'Permission denied' using errcode = '42501'; end if;
  select * into r from public.payroll_runs where id = p_run;
  if not found then raise exception 'Payroll not found' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'run', to_jsonb(r) || jsonb_build_object('prepared_by_name', (select full_name from public.profiles where id = r.prepared_by),
                                            'approved_by_name', (select full_name from public.profiles where id = r.approved_by),
                                            'paid_from', (select name from public.money_accounts where id = r.money_account_id)),
    'payslips', (select coalesce(jsonb_agg(to_jsonb(s) || jsonb_build_object(
                    'lines', (select coalesce(jsonb_agg(jsonb_build_object('source', l.source, 'component_id', l.component_id, 'name', l.name, 'kind', l.kind,
                               'amount', l.amount, 'epf_liable', l.epf_liable, 'taxable', l.taxable) order by l.kind desc, l.id), '[]')
                               from public.payslip_lines l where l.payslip_id = s.id)) order by s.emp_no), '[]')
                   from public.payslips s where s.run_id = r.id),
    'journals', (select coalesce(jsonb_agg(jsonb_build_object('id', j.id, 'entry_no', j.entry_no, 'event_type', j.event_type, 'total', j.total)), '[]')
                   from public.journal_entries j where j.source_type = 'payroll_run' and j.source_id = r.id)
  ) into v;
  return v;
end $$;

create or replace function public.payslip_details(p_payslip uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare s public.payslips; r public.payroll_runs; v jsonb;
begin
  select * into s from public.payslips where id = p_payslip;
  if not found then raise exception 'Payslip not found' using errcode = 'P0002'; end if;
  if not (app.has_permission('payroll.run') or app.has_permission('payroll.approve')
          or exists (select 1 from public.employees e where e.id = s.employee_id and e.profile_id = app.current_user_id())) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  select * into r from public.payroll_runs where id = s.run_id;
  if r.status = 'draft' and not (app.has_permission('payroll.run') or app.has_permission('payroll.approve')) then
    raise exception 'This payslip is not final yet' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'payslip', to_jsonb(s), 'run', jsonb_build_object('run_no', r.run_no, 'year', r.pay_year, 'month', r.pay_month, 'status', r.status,
      'period_start', r.period_start, 'period_end', r.period_end),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('name', l.name, 'kind', l.kind, 'amount', l.amount) order by l.kind desc, l.id), '[]')
                from public.payslip_lines l where l.payslip_id = s.id),
    'company', jsonb_build_object('name', app.get_setting('company.name') #>> '{}'),
    'rates', jsonb_build_object('epf_employee', app.statutory_rate('epf_employee', r.period_end), 'epf_employer', app.statutory_rate('epf_employer', r.period_end),
                                'etf', app.statutory_rate('etf_employer', r.period_end))
  ) into v;
  return v;
end $$;

-- EPF / ETF / APIT for one month (approved and paid payrolls)
create or replace function public.statutory_report(p_year integer, p_month integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  if not (app.has_permission('payroll.run') or app.has_permission('payroll.approve')) then raise exception 'Permission denied' using errcode = '42501'; end if;
  select jsonb_build_object(
    'year', p_year, 'month', p_month,
    'employer_epf_no', app.get_setting('company.epf_registration_no') #>> '{}',
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('emp_no', s.emp_no, 'name', s.employee_name, 'epf_no', s.epf_no,
               'epf_earnings', s.epf_earnings, 'epf_employee', s.epf_employee, 'epf_employer', s.epf_employer, 'etf', s.etf,
               'taxable', s.taxable, 'apit', s.apit) order by s.emp_no), '[]')
               from public.payslips s join public.payroll_runs r on r.id = s.run_id
              where r.pay_year = p_year and r.pay_month = p_month and r.status in ('approved','paid')),
    'paid', (select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'payment_no', payment_no, 'amount', amount, 'paid_at', paid_at, 'reference', reference)), '[]')
               from public.statutory_payments where pay_year = p_year and pay_month = p_month),
    'payroll_status', (select status from public.payroll_runs where pay_year = p_year and pay_month = p_month and status <> 'cancelled')
  ) into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Fleet
-- ---------------------------------------------------------------------
create or replace function public.fleet_overview()
returns table (id uuid, registration_no text, name text, vehicle_type text, make text, model text, odometer_km integer, is_active boolean,
               driver text, documents jsonb, next_service_km integer, next_service_date date, fuel_month_litres numeric, fuel_month_amount numeric,
               km_per_litre numeric, alerts text[])
language sql stable security definer set search_path = '' as $$
  with docs as (
    select distinct on (vehicle_id, doc_type) vehicle_id, doc_type, expires_on, doc_no
      from public.vehicle_documents order by vehicle_id, doc_type, expires_on desc),
  svc as (
    select distinct on (vehicle_id) vehicle_id, next_due_km, next_due_date
      from public.vehicle_services where kind = 'service' order by vehicle_id, service_date desc),
  fills as (
    select vehicle_id, litres, odometer_km, row_number() over (partition by vehicle_id order by fuel_date desc, created_at desc) rn
      from public.fuel_logs where odometer_km is not null)
  select v.id, v.registration_no, v.name, v.vehicle_type, v.make, v.model, v.odometer_km, v.is_active,
    (select full_name from public.profiles where id = v.assigned_driver_id),
    (select coalesce(jsonb_object_agg(d.doc_type, jsonb_build_object('expires_on', d.expires_on, 'doc_no', d.doc_no)), '{}') from docs d where d.vehicle_id = v.id),
    coalesce(s.next_due_km, case when v.service_interval_km is not null and v.last_service_km is not null then v.last_service_km + v.service_interval_km end),
    coalesce(s.next_due_date, case when v.service_interval_days is not null and v.last_service_date is not null then v.last_service_date + v.service_interval_days end),
    coalesce((select sum(litres) from public.fuel_logs f where f.vehicle_id = v.id and f.fuel_date >= date_trunc('month', app.today())::date), 0),
    coalesce((select sum(amount) from public.fuel_logs f where f.vehicle_id = v.id and f.fuel_date >= date_trunc('month', app.today())::date), 0),
    -- distance between the oldest and newest of the last six fills ÷ fuel put in after the oldest one
    (select round((max(x.odometer_km) - min(x.odometer_km))::numeric / nullif(sum(x.litres) - (array_agg(x.litres order by x.rn desc))[1], 0), 1)
       from fills x where x.vehicle_id = v.id and x.rn <= 6 having count(*) >= 2),
    array_remove(array[
      (select string_agg(initcap(replace(d.doc_type, '_', ' ')) || case when d.expires_on < app.today() then ' expired' else ' expires ' || to_char(d.expires_on, 'DD Mon') end, ', ')
         from docs d where d.vehicle_id = v.id
          and d.expires_on <= app.today() + coalesce((app.get_setting('fleet.document_alert_days') #>> '{}')::int, 30)),
      case when v.odometer_km is not null and coalesce(s.next_due_km, v.last_service_km + v.service_interval_km) is not null
                and v.odometer_km >= coalesce(s.next_due_km, v.last_service_km + v.service_interval_km)
                                     - coalesce((app.get_setting('fleet.service_alert_km') #>> '{}')::int, 500)
           then 'Service due at ' || coalesce(s.next_due_km, v.last_service_km + v.service_interval_km) || ' km' end,
      case when coalesce(s.next_due_date, v.last_service_date + v.service_interval_days) <= app.today() + 7
           then 'Service due ' || to_char(coalesce(s.next_due_date, v.last_service_date + v.service_interval_days), 'DD Mon') end
    ], null)
  from public.vehicles v
  left join svc s on s.vehicle_id = v.id
  where app.has_permission('fleet.manage') or app.has_permission('deliveries.manage') or app.has_permission('routes.manage')
  order by v.is_active desc, v.registration_no
$$;

create or replace function public.vehicle_details(p_vehicle uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare ve public.vehicles; v jsonb;
begin
  if not (app.has_permission('fleet.manage') or app.has_permission('deliveries.manage')) then raise exception 'Permission denied' using errcode = '42501'; end if;
  select * into ve from public.vehicles where id = p_vehicle;
  if not found then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'vehicle', to_jsonb(ve) || jsonb_build_object('driver', (select full_name from public.profiles where id = ve.assigned_driver_id)),
    'overview', (select to_jsonb(f) from public.fleet_overview() f where f.id = ve.id),
    'documents', (select coalesce(jsonb_agg(to_jsonb(d) order by d.expires_on desc), '[]') from public.vehicle_documents d where d.vehicle_id = ve.id),
    'fuel', (select coalesce(jsonb_agg(jsonb_build_object('date', f.fuel_date, 'litres', f.litres, 'amount', f.amount, 'odometer_km', f.odometer_km,
               'station', f.station, 'driver', (select full_name from public.profiles where id = f.driver_id),
               'run_no', (select run_no from public.route_runs where id = f.run_id)) order by f.fuel_date desc, f.created_at desc), '[]')
               from (select * from public.fuel_logs where vehicle_id = ve.id order by fuel_date desc, created_at desc limit 40) f),
    'services', (select coalesce(jsonb_agg(to_jsonb(s) order by s.service_date desc), '[]') from public.vehicle_services s where s.vehicle_id = ve.id),
    'expenses', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'expense_no', x.expense_no, 'date', x.expense_date, 'category', c.name,
                   'description', x.description, 'total', x.total, 'status', x.status, 'pay_method', x.pay_method) order by x.expense_date desc), '[]')
                   from (select * from public.expenses where vehicle_id = ve.id order by expense_date desc limit 40) x
                   join public.expense_categories c on c.id = x.category_id),
    'asset', (select jsonb_build_object('id', a.id, 'asset_no', a.asset_no, 'cost', a.cost, 'accumulated', a.accumulated, 'book_value', a.cost - a.accumulated)
                from public.fixed_assets a where a.id = ve.asset_id),
    'runs_this_month', (select count(*) from public.route_runs where vehicle_id = ve.id and run_date >= date_trunc('month', app.today())::date)
  ) into v;
  return v;
end $$;

create or replace function public.vehicle_profitability(p_from date, p_to date)
returns table (vehicle_id uuid, registration_no text, runs bigint, sales numeric, fuel numeric, repairs numeric, other_costs numeric,
               depreciation numeric, contribution numeric)
language sql stable security definer set search_path = '' as $$
  select q.*, q.sales - q.fuel - q.repairs - q.other_costs - q.depreciation from (
    select v.id, v.registration_no,
      (select count(*) from public.route_runs r where r.vehicle_id = v.id and r.run_date between p_from and p_to and r.status <> 'cancelled') as runs,
      coalesce((select sum(i.subtotal_net) from public.invoices i join public.route_runs r on r.id = i.run_id
                 where r.vehicle_id = v.id and i.invoice_date between p_from and p_to and i.status <> 'void'), 0) as sales,
      coalesce((select sum(x.net_amount) from public.expenses x join public.expense_categories c on c.id = x.category_id
                 where x.vehicle_id = v.id and c.code = 'FUEL' and x.status in ('approved','paid') and x.expense_date between p_from and p_to), 0) as fuel,
      coalesce((select sum(x.net_amount) from public.expenses x join public.expense_categories c on c.id = x.category_id
                 where x.vehicle_id = v.id and c.code = 'VEHICLE_REPAIR' and x.status in ('approved','paid') and x.expense_date between p_from and p_to), 0) as repairs,
      coalesce((select sum(x.net_amount) from public.expenses x join public.expense_categories c on c.id = x.category_id
                 where x.vehicle_id = v.id and c.code not in ('FUEL','VEHICLE_REPAIR') and x.status in ('approved','paid')
                   and x.expense_date between p_from and p_to), 0) as other_costs,
      coalesce((select sum(d.amount) from public.asset_depreciation d where d.asset_id = v.asset_id
                 and make_date(d.dep_year, d.dep_month, 1) between date_trunc('month', p_from)::date and p_to), 0) as depreciation
    from public.vehicles v
    where (app.has_permission('fleet.manage') or app.has_permission('accounting.view'))
  ) q
  order by q.registration_no
$$;

-- ---------------------------------------------------------------------
-- Assets
-- ---------------------------------------------------------------------
create or replace function public.asset_register()
returns table (id uuid, asset_no text, name text, category text, serial_no text, location text, responsible text, purchase_date date,
               cost numeric, accumulated numeric, book_value numeric, status text, warranty_until date, vehicle text, last_depreciation text)
language sql stable security definer set search_path = '' as $$
  select a.id, a.asset_no, a.name, c.name, a.serial_no, l.name, e.full_name, a.purchase_date, a.cost, a.accumulated, a.cost - a.accumulated,
    a.status, a.warranty_until, (select registration_no from public.vehicles v where v.asset_id = a.id),
    (select max(dep_year::text || '-' || lpad(dep_month::text, 2, '0')) from public.asset_depreciation d where d.asset_id = a.id)
    from public.fixed_assets a join public.asset_categories c on c.id = a.category_id
    left join public.locations l on l.id = a.location_id left join public.employees e on e.id = a.responsible_employee_id
   where app.has_permission('assets.manage') or app.has_permission('accounting.view')
   order by a.status, c.name, a.asset_no
$$;

create or replace function public.asset_details(p_asset uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.fixed_assets; v jsonb;
begin
  if not (app.has_permission('assets.manage') or app.has_permission('accounting.view')) then raise exception 'Permission denied' using errcode = '42501'; end if;
  select * into a from public.fixed_assets where id = p_asset;
  if not found then raise exception 'Asset not found' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'asset', to_jsonb(a) || jsonb_build_object('category', (select name from public.asset_categories where id = a.category_id),
             'location', (select name from public.locations where id = a.location_id),
             'responsible', (select full_name from public.employees where id = a.responsible_employee_id),
             'vehicle', (select jsonb_build_object('id', v.id, 'registration_no', v.registration_no) from public.vehicles v where v.asset_id = a.id),
             'book_value', a.cost - a.accumulated,
             'monthly', app.asset_month_depreciation(a, extract(year from app.today())::int, extract(month from app.today())::int)),
    'depreciation', (select coalesce(jsonb_agg(jsonb_build_object('year', d.dep_year, 'month', d.dep_month, 'amount', d.amount) order by d.dep_year desc, d.dep_month desc), '[]')
                       from public.asset_depreciation d where d.asset_id = a.id),
    'maintenance', (select coalesce(jsonb_agg(jsonb_build_object('expense_no', x.expense_no, 'date', x.expense_date, 'description', x.description,
                      'total', x.total, 'status', x.status) order by x.expense_date desc), '[]')
                      from public.expenses x where x.asset_id = a.id),
    'journals', (select coalesce(jsonb_agg(jsonb_build_object('id', j.id, 'entry_no', j.entry_no, 'entry_date', j.entry_date, 'event_type', j.event_type, 'total', j.total)
                   order by j.entry_date), '[]') from public.journal_entries j where j.source_type = 'fixed_asset' and j.source_id = a.id)
  ) into v;
  return v;
end $$;

-- Figures and alerts for the dashboard
create or replace function public.people_assets_summary()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'hr', case when app.has_permission('hr.view') then jsonb_build_object(
        'headcount', (select count(*) from public.employees where status = 'active'),
        'pending_leave', (select count(*) from public.leave_requests where status = 'pending'),
        'attendance_today', (select count(*) from public.attendance where work_date = app.today())) end,
    'payroll', case when app.has_permission('payroll.run') or app.has_permission('payroll.approve') then jsonb_build_object(
        'last_month_status', (select status from public.payroll_runs
                               where pay_year = extract(year from (date_trunc('month', app.today()) - interval '1 day'))::int
                                 and pay_month = extract(month from (date_trunc('month', app.today()) - interval '1 day'))::int and status <> 'cancelled'),
        'drafts', (select count(*) from public.payroll_runs where status = 'draft'),
        'unpaid', (select count(*) from public.payroll_runs where status = 'approved')) end,
    'fleet', case when app.has_permission('fleet.manage') or app.has_permission('deliveries.manage') then jsonb_build_object(
        'alerts', (select count(*) from public.fleet_overview() f where f.is_active and cardinality(f.alerts) > 0),
        'fuel_month', coalesce((select sum(amount) from public.fuel_logs where fuel_date >= date_trunc('month', app.today())::date), 0),
        'driver_expenses_pending', (select count(*) from public.expenses where pay_method = 'driver_cash' and status = 'pending_approval')) end,
    'assets', case when app.has_permission('assets.manage') or app.has_permission('accounting.view') then jsonb_build_object(
        'count', (select count(*) from public.fixed_assets where status = 'active'),
        'book_value', coalesce((select sum(cost - accumulated) from public.fixed_assets where status = 'active'), 0),
        'last_depreciation', (select max(dep_year::text || '-' || lpad(dep_month::text, 2, '0')) from public.depreciation_runs),
        'depreciation_due', not exists (select 1 from public.depreciation_runs
                              where dep_year = extract(year from (date_trunc('month', app.today()) - interval '1 day'))::int
                                and dep_month = extract(month from (date_trunc('month', app.today()) - interval '1 day'))::int)
                            and exists (select 1 from public.fixed_assets where status = 'active')) end
  )
$$;

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
revoke execute on function public.log_failed_login(text, text, text, text) from authenticated;
revoke execute on function public.bootstrap_super_admin(text)              from authenticated;

grant select on all tables in schema public to authenticated, service_role;
revoke all on all tables in schema public from anon;

commit;
