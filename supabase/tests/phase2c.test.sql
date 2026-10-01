-- =====================================================================
-- Phase 2C database tests — HR & payroll (attendance, leave, advances,
-- EPF/ETF/APIT, approval by a second person, payment), fleet (documents,
-- fuel, services, driver expenses in the cash check-in) and fixed assets
-- (register, depreciation, disposal).
-- Runs after the Phase 0 – 2B tests in the same database.
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = notice;

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000c1', 'hr@ola.test', '{"full_name":"Shanika Weerasinghe"}');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.admin_assign_role('00000000-0000-0000-0000-0000000000c1', (select id from public.roles where code = 'hr_manager'), null, 'HR');
reset role;
select (select id from public.money_accounts where kind = 'bank' and is_default) as bank \gset
select (select id from public.money_accounts where kind = 'cash' and is_default) as cash \gset

-- ---------------------------------------------------------------------
-- Employees
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false);
set role authenticated;
select public.save_employee(null, jsonb_build_object('emp_no', 'E001', 'full_name', 'Kasun Perera', 'nic_no', '199012345678', 'join_date', '2024-01-01',
  'department_id', (select id from public.departments where code = 'PROD'), 'epf_no', '1001', 'basic_salary', 100000), 'New employee') as e1 \gset
select public.save_employee(null, jsonb_build_object('emp_no', 'E002', 'full_name', 'Nimali Silva', 'join_date', '2023-06-01',
  'department_id', (select id from public.departments where code = 'FIN'), 'epf_no', '1002', 'basic_salary', 200000), 'New employee') as e2 \gset
select public.save_employee(null, jsonb_build_object('emp_no', 'C001', 'full_name', 'Saman Kumara', 'join_date', '2026-08-01', 'employment_type', 'casual',
  'pay_basis', 'daily', 'daily_rate', 2500, 'epf_applicable', false, 'etf_applicable', false, 'apit_applicable', false), 'Casual worker') as e3 \gset
select tests.throws($$select public.save_employee(null, '{"emp_no":"E009","full_name":"No date"}', 'x')$$, 'joining date', 'joining date is required');
select public.set_employee_pay_items(:'e1', jsonb_build_array(
  jsonb_build_object('component_id', (select id from public.pay_components where code = 'ALLOW_FIXED'), 'amount', 10000),
  jsonb_build_object('component_id', (select id from public.pay_components where code = 'ALLOW_TRAVEL'), 'amount', 5000)), 'Contract');
reset role;

-- personal and salary data is private
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', false);
set role authenticated;
select tests.ok((select count(*) = 0 from public.employees) and (select count(*) = 0 from public.payslips), 'a driver cannot read employee or salary records');
reset role;

-- ---------------------------------------------------------------------
-- Attendance and leave (September 2026)
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false);
set role authenticated;
select public.record_attendance(date '2026-09-08', jsonb_build_array(jsonb_build_object('employee_id', :'e1', 'status', 'absent')));
select public.record_attendance(date '2026-09-09', jsonb_build_array(jsonb_build_object('employee_id', :'e1', 'status', 'absent')));
select public.record_attendance(date '2026-09-10', jsonb_build_array(jsonb_build_object('employee_id', :'e1', 'status', 'present', 'ot_hours', 10)));
select public.record_attendance(d::date, jsonb_build_array(jsonb_build_object('employee_id', :'e3', 'status', 'present')))
  from generate_series(date '2026-09-01', date '2026-09-23', interval '1 day') d where extract(isodow from d) <> 7;   -- 20 working days
select tests.throws($$select public.record_attendance(app.today() + 1, '[]')$$, 'future', 'attendance cannot be entered for the future');
select public.request_leave(jsonb_build_object('employee_id', :'e2', 'leave_type_id', (select id from public.leave_types where code = 'ANNUAL'),
  'from_date', '2026-09-15', 'to_date', '2026-09-15', 'reason', 'Family function')) as lv \gset
select public.decide_leave((:'lv'::jsonb ->> 'request_id')::uuid, 'approve', null);
select tests.throws(format($$select public.request_leave(jsonb_build_object('employee_id', %L, 'leave_type_id', %L, 'from_date', '2026-09-15'))$$,
  :'e2', (select id from public.leave_types where code = 'CASUAL')), 'already requested', 'overlapping leave is refused');
reset role;
select tests.ok((select status = 'leave' from public.attendance where employee_id = :'e2' and work_date = date '2026-09-15'), 'approved leave is marked in attendance');
select tests.ok((select (x ->> 'left')::numeric = 13 from jsonb_array_elements(app.leave_balances(:'e2', 2026)) x where x ->> 'code' = 'ANNUAL'),
                'annual leave balance: 14 − 1 = 13');

-- ---------------------------------------------------------------------
-- Salary advance and payroll for September
-- ---------------------------------------------------------------------
set role authenticated;
select public.give_salary_advance(jsonb_build_object('employee_id', :'e1', 'amount', 20000, 'installment', 5000, 'money_account_id', :'cash',
  'reason', 'Medical bill'), gen_random_uuid());
select tests.throws($$select public.create_payroll_run(2026, 12, null, gen_random_uuid())$$, 'future month', 'payroll cannot be prepared for a future month');
select public.create_payroll_run(2026, 9, 'September salaries', gen_random_uuid()) as run \gset
select (:'run'::jsonb ->> 'run_id') as run_id \gset
select public.set_payslip_adjustments((select id from public.payslips where run_id = :'run_id' and employee_id = :'e3'),
  jsonb_build_array(jsonb_build_object('component_id', (select id from public.pay_components where code = 'BONUS'), 'amount', 5000)), 'Festival bonus');
reset role;
select tests.ok((select basic = 100000 and nopay_days = 2 and nopay_amount = 6666.67 and ot_amount = 6250 and gross = 114583.33
                    and epf_earnings = 103333.33 and epf_employee = 8266.67 and epf_employer = 12400 and etf = 3100 and apit = 0
                    and advance_recovery = 5000 and net = 101316.66
                   from public.payslips where run_id = :'run_id' and employee_id = :'e1'),
                'monthly payslip: 2 no-pay days, 10 h overtime, EPF on basic + EPF-liable allowance, advance recovered');
select tests.ok((select gross = 200000 and epf_employee = 16000 and apit = 3000 and net = 181000 from public.payslips where run_id = :'run_id' and employee_id = :'e2'),
                'APIT: Rs. 200,000 → 6% on the Rs. 50,000 above Rs. 150,000 = Rs. 3,000; paid leave is not deducted');
select tests.ok((select basic = 50000 and gross = 55000 and epf_employee = 0 and net = 55000 from public.payslips where run_id = :'run_id' and employee_id = :'e3'),
                'daily-paid casual: 20 days × 2,500 + 5,000 bonus, no EPF');
select tests.ok((select gross = 369583.33 and net = 337316.66 and employees = 3 from public.payroll_runs where id = :'run_id'), 'payroll totals');

set role authenticated;
select tests.throws(format($$select public.approve_payroll_run(%L, null)$$, :'run_id'), 'permission denied', 'HR cannot approve the payroll it prepared');
select tests.throws($$select public.create_payroll_run(2026, 9, null, gen_random_uuid())$$, 'already exists', 'one payroll per month');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
select public.approve_payroll_run(:'run_id', 'Checked against attendance') as appr \gset
reset role;
select tests.ok((select sum(l.credit) filter (where a.system_key = 'epf_payable') = 60666.67
                    and sum(l.credit) filter (where a.system_key = 'etf_payable') = 9100
                    and sum(l.credit) filter (where a.system_key = 'paye_payable') = 3000
                    and sum(l.credit) filter (where a.system_key = 'salaries_payable') = 337316.66
                    and sum(l.credit) filter (where a.system_key = 'staff_advances') = 5000
                    and sum(l.debit) filter (where a.system_key = 'exp_salaries') = 369583.33
                    and sum(l.debit) filter (where a.system_key = 'exp_epf_etf') = 45500
                   from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
                  where e.source_type = 'payroll_run' and e.source_id = :'run_id'::uuid),
                'payroll journal: gross + employer EPF/ETF = net + EPF + ETF + APIT + advances');
select tests.ok((select outstanding = 15000 from public.salary_advances where employee_id = :'e1'), 'advance outstanding reduced to Rs. 15,000');

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false);
select tests.throws(format($$select public.record_attendance(date '2026-09-30', jsonb_build_array(jsonb_build_object('employee_id', %L, 'status', 'absent')))$$, :'e1'),
                    'locked', 'attendance of an approved payroll month is locked');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
select tests.throws(format($$select public.pay_payroll_run(%L, %L, '', gen_random_uuid())$$, :'run_id', :'bank'), 'reference', 'bank salary payment needs a reference');
select public.pay_payroll_run(:'run_id', :'bank', 'HNB bulk transfer 0930', gen_random_uuid());
select public.pay_statutory(jsonb_build_object('kind', 'epf', 'pay_year', 2026, 'pay_month', 9, 'amount', 60666.67, 'money_account_id', :'bank',
  'reference', 'EPF C-form Sep'), gen_random_uuid());
select tests.ok(jsonb_array_length(public.statutory_report(2026, 9) -> 'rows') = 3, 'EPF / ETF / APIT list for September');
reset role;
select tests.ok((select balance = 0 from public.trial_balance(date '2026-01-01', date '2027-12-31') where account_code = '2500')
                and (select balance = 0 from public.trial_balance(date '2026-01-01', date '2027-12-31') where account_code = '2400'),
                'salaries payable and EPF payable cleared after payment');

-- ---------------------------------------------------------------------
-- Fixed assets and depreciation
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.save_vehicle(null, '{"registration_no":"WP LC-7788","name":"Lorry 2","capacity_19l":180}', 'New lorry') as veh2 \gset
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
select public.register_asset(jsonb_build_object('name', 'RO plant 2000 L/h', 'category_id', (select id from public.asset_categories where code = 'PLANT'),
  'purchase_date', '2026-09-05', 'cost', 1200000, 'funding', 'paid', 'money_account_id', :'bank', 'location_id', (select id from public.locations where code = 'WH1')),
  gen_random_uuid()) as ro \gset
select public.register_asset(jsonb_build_object('name', 'Isuzu lorry WP LC-7788', 'category_id', (select id from public.asset_categories where code = 'VEHICLE'),
  'purchase_date', '2023-04-01', 'cost', 6000000, 'funding', 'opening', 'opening_accumulated', 1200000, 'vehicle_id', :'veh2'), gen_random_uuid()) as lorry \gset
select tests.throws($$select public.register_asset(jsonb_build_object('name', 'x', 'category_id', (select id from public.asset_categories where code = 'IT'),
  'purchase_date', '2026-09-01', 'cost', 100, 'funding', 'paid', 'opening_accumulated', 10), gen_random_uuid())$$, 'go-live', 'depreciation to date only for opening assets');
select public.run_depreciation(2026, 9) as dep9 \gset
select tests.throws($$select public.run_depreciation(2026, 9)$$, 'already been run', 'a month is depreciated once');
select tests.throws($$select public.run_depreciation(2026, 8)$$, 'later month', 'months are depreciated in order');
select tests.throws($$select public.run_depreciation(2026, 12)$$, 'future', 'no depreciation for a future month');
select public.run_depreciation(2026, 10);
reset role;
select tests.ok((:'dep9'::jsonb ->> 'total')::numeric = 99500, 'September depreciation: RO (1,200,000 − 5%) ÷ 120 = 9,500 + lorry (6,000,000 − 10%) ÷ 60 = 90,000');
select tests.ok((select accumulated = 1380000 from public.fixed_assets where id = (:'lorry'::jsonb ->> 'asset_id')::uuid)
                and (select asset_id = (:'lorry'::jsonb ->> 'asset_id')::uuid from public.vehicles where id = :'veh2'),
                'opening depreciation + two months; lorry linked to its vehicle');
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
select public.dispose_asset((:'ro'::jsonb ->> 'asset_id')::uuid, jsonb_build_object('proceeds', 1100000, 'money_account_id', :'bank',
  'reason', 'Replaced by a larger plant'), gen_random_uuid()) as disp \gset
reset role;
select tests.ok((:'disp'::jsonb ->> 'book_value')::numeric = 1181000 and (:'disp'::jsonb ->> 'gain')::numeric = -81000,
                'disposal: book value 1,200,000 − 19,000 = 1,181,000; sold for 1,100,000 → loss 81,000');
select tests.ok((select balance = 81000 from public.trial_balance(date '2026-01-01', date '2027-12-31') where account_code = '6410'), 'loss on disposal posted');

-- ---------------------------------------------------------------------
-- Fleet: documents, fuel, service
-- ---------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select public.save_vehicle_details(:'veh2', '{"make":"Isuzu","model":"NPR","fuel_type":"diesel","service_interval_km":5000}', 'Details');
select public.record_vehicle_document(jsonb_build_object('vehicle_id', :'veh2', 'doc_type', 'insurance', 'doc_no', 'POL-77812', 'provider', 'Ceylinco',
  'issued_on', app.today() - 355, 'expires_on', app.today() + 10), gen_random_uuid());
select public.record_fuel(jsonb_build_object('vehicle_id', :'veh2', 'date', app.today(), 'litres', 50, 'amount', 18000, 'odometer_km', 10000,
  'station', 'Ceypetco Kiribathgoda', 'pay_method', 'cash', 'money_account_id', :'cash'), gen_random_uuid());
select public.record_fuel(jsonb_build_object('vehicle_id', :'veh2', 'date', app.today(), 'litres', 40, 'amount', 14400, 'odometer_km', 10400,
  'pay_method', 'cash', 'money_account_id', :'cash'), gen_random_uuid());
select tests.throws(format($$select public.record_fuel(jsonb_build_object('vehicle_id', %L, 'litres', 10, 'amount', 3600, 'odometer_km', 9000,
  'pay_method', 'cash', 'money_account_id', %L), gen_random_uuid())$$, :'veh2', :'cash'), 'lower than the last', 'odometer cannot go backwards');
select public.record_vehicle_service(jsonb_build_object('vehicle_id', :'veh2', 'kind', 'service', 'description', 'Oil and filters', 'odometer_km', 10400,
  'cost', 12500, 'vendor', 'Isuzu service centre', 'pay_method', 'cash', 'money_account_id', :'cash'), gen_random_uuid());
select tests.ok((select km_per_litre = 10 and next_service_km = 15400 and alerts[1] like 'Insurance expires%' from public.fleet_overview() where id = :'veh2'),
                'fleet overview: 400 km on 40 L = 10 km/L, next service at 15,400 km, insurance expiry warned');
reset role;

-- ---------------------------------------------------------------------
-- Driver expenses on the road reduce the cash expected at check-in
-- ---------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select public.receive_stock((select id from public.locations where code = 'WH1'),
  jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-5L'), 'qty', 5)), 'opening', 'Test stock', gen_random_uuid());
select public.save_order(null, jsonb_build_object('customer_id', (select id from public.customers where phone = '+94771234567'), 'items', jsonb_build_array(
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-5L'), 'qty', 1))), true, gen_random_uuid()) as ord9 \gset
select public.create_route_run(app.today(), null, :'veh2', '00000000-0000-0000-0000-0000000000d1', array[(:'ord9'::jsonb ->> 'order_id')::uuid],
  null, null, gen_random_uuid()) as run2 \gset
select public.load_route_run((:'run2'::jsonb ->> 'run_id')::uuid, jsonb_build_array(
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-5L'), 'qty', 1)), 30000, gen_random_uuid());
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', false);
set role authenticated;
select public.driver_start_run((:'run2'::jsonb ->> 'run_id')::uuid);
select public.driver_record_expense((:'run2'::jsonb ->> 'run_id')::uuid, jsonb_build_object('category_code', 'FUEL', 'amount', 2000, 'litres', 5.5,
  'odometer_km', 10450), '44444444-4444-4444-4444-444444444444') as dx1 \gset
select public.driver_record_expense((:'run2'::jsonb ->> 'run_id')::uuid, jsonb_build_object('category_code', 'FUEL', 'amount', 2000, 'litres', 5.5),
  '44444444-4444-4444-4444-444444444444') as dx1b \gset
select public.driver_record_expense((:'run2'::jsonb ->> 'run_id')::uuid, jsonb_build_object('category_code', 'TOLLS', 'amount', 300), gen_random_uuid());
select public.driver_record_expense((:'run2'::jsonb ->> 'run_id')::uuid, jsonb_build_object('category_code', 'VEHICLE_REPAIR', 'amount', 26000,
  'description', 'Tyre burst — new tyre'), gen_random_uuid()) as dx3 \gset
select tests.throws(format($$select public.driver_record_expense(%L, '{"category_code":"OFFICE","amount":100}', gen_random_uuid())$$, :'run2'::jsonb ->> 'run_id'),
                    'choose fuel', 'drivers can only claim road expenses');
select tests.throws(format($$select public.driver_record_expense(%L, '{"category_code":"TOLLS","amount":90000}', gen_random_uuid())$$, :'run2'::jsonb ->> 'run_id'),
                    'more than the cash', 'a driver cannot spend more than the cash carried');
select tests.ok(jsonb_array_length(public.driver_get_run((:'run2'::jsonb ->> 'run_id')::uuid) -> 'driver_expenses') = 3, 'the driver app lists the run''s expenses');
select public.fail_delivery((select id from public.deliveries where run_id = (:'run2'::jsonb ->> 'run_id')::uuid), 'Customer not available', null, null, null,
  gen_random_uuid());
reset role;
select tests.ok((:'dx1'::jsonb ->> 'expense_no') = (:'dx1b'::jsonb ->> 'expense_no') and (:'dx1'::jsonb ->> 'status') = 'paid'
                and (:'dx3'::jsonb ->> 'status') = 'pending_approval', 'offline replay is not duplicated; small expenses post at once, a large one waits');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);
set role authenticated;
select public.checkin_route_run((:'run2'::jsonb ->> 'run_id')::uuid, jsonb_build_object(
  'products', jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-5L'), 'qty', 1)),
  'bottles', '[]'::jsonb, 'scanned_codes', '[]'::jsonb, 'cash_handed', 1700), gen_random_uuid()) as ci2 \gset
reset role;
select tests.ok((:'ci2'::jsonb ->> 'cash_expected')::numeric = 1700 and (:'ci2'::jsonb ->> 'exceptions')::integer = 0,
                'check-in expects 30,000 float − 2,000 fuel − 300 tolls − 26,000 repair = 1,700');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
set role authenticated;
select public.decide_expense((:'dx3'::jsonb ->> 'expense_id')::uuid, false, 'No receipt and the tyre was under warranty');
reset role;
select tests.ok((select count(*) = 1 from public.operation_exceptions where run_id = (:'run2'::jsonb ->> 'run_id')::uuid and exception_type = 'cash_shortage'
                   and expected = 26000 and status = 'open'), 'a rejected driver expense becomes cash the driver owes');
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
select tests.ok((select fuel = 32400 + 2000 and repairs = 12500 and depreciation = 180000 from public.vehicle_profitability(date '2026-09-01', app.today())
                  where vehicle_id = :'veh2'), 'vehicle profitability: fuel, repairs and depreciation of the lorry');
select tests.ok((public.people_assets_summary() -> 'assets' ->> 'count')::integer = 1, 'dashboard summary for people and assets');
select tests.ok((select sum(balance) = 0 from public.trial_balance(date '2026-01-01', date '2027-12-31')), 'ledger balances after all Phase 2C flows');
reset role;

-- read models used by the screens all run for an admin
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select tests.ok((select count(*) >= 3 from public.employee_directory()), 'employee directory');
select tests.ok((select count(*) >= 1 from public.list_user_logins() where is_driver), 'user logins for linking employees and drivers');
select tests.ok(public.hr_overview() is not null, 'HR overview');
select tests.ok(public.employee_details(:'e1') -> 'employee' is not null, 'employee details');
select tests.ok((select count(*) >= 3 from public.attendance_sheet(date '2026-09-10')), 'attendance sheet');
select tests.ok(jsonb_array_length(public.payroll_run_details(:'run_id') -> 'payslips') >= 3, 'payroll run details');
select tests.ok(public.payslip_details((select id from public.payslips where run_id = :'run_id' limit 1)) is not null, 'payslip details');
select tests.ok((select count(*) >= 1 from public.asset_register()), 'asset register');
select tests.ok(public.asset_details((:'lorry'::jsonb ->> 'asset_id')::uuid) -> 'asset' is not null, 'asset details');
select tests.ok(public.vehicle_details(:'veh2') is not null, 'vehicle details');
reset role;

do $$ begin raise notice 'ALL PHASE 2C DATABASE TESTS PASSED'; end $$;
