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
