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
