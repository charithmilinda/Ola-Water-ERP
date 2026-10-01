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
