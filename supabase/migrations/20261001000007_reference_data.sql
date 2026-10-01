-- =====================================================================
-- OLA Water ERP — Phase 0
-- 0007: reference data required in every environment
--   permissions, default roles, head office + main warehouse,
--   document types, identifier series, settings, chart of accounts,
--   posting rules, accounting periods for 2026–2027
-- (Demo/test business data lives in supabase/seed.sql, not here.)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Permissions (all modules, so roles can be configured from day one)
-- ---------------------------------------------------------------------
insert into public.permissions (code, module, action, description, sort_order) values
  ('dashboard.view',            'Dashboard',        'view',            'View the management dashboard', 10),
  ('customers.view',            'Customers',        'view',            'View customers', 20),
  ('customers.manage',          'Customers',        'manage',          'Create and edit customers', 21),
  ('customers.credit',          'Customers',        'credit',          'Approve credit customers and limits', 22),
  ('products.view',             'Products',         'view',            'View products and price lists', 30),
  ('products.manage',           'Products',         'manage',          'Create and edit products', 31),
  ('prices.manage',             'Products',         'prices',          'Change price lists', 32),
  ('orders.view',               'Orders',           'view',            'View orders', 40),
  ('orders.manage',             'Orders',           'manage',          'Create, confirm and cancel orders', 41),
  ('pos.use',                   'Sales / POS',      'use',             'Use the head-office POS', 50),
  ('pos.discount',              'Sales / POS',      'discount',        'Approve discounts above the limit', 51),
  ('bottles.view',              'Bottles',          'view',            'View bottles and bottle ledgers', 60),
  ('bottles.manage',            'Bottles',          'manage',          'Record bottle movements', 61),
  ('bottles.writeoff',          'Bottles',          'writeoff',        'Approve bottle write-offs', 62),
  ('bottles.external',          'Bottles',          'external',        'Manage external bottle holding and hand-overs', 63),
  ('labels.view',               'Labels',           'view',            'View label batches and identifiers', 70),
  ('labels.print',              'Labels',           'print',           'Generate and print labels', 71),
  ('deliveries.view',           'Deliveries',       'view',            'View deliveries', 80),
  ('deliveries.manage',         'Deliveries',       'manage',          'Assign and manage deliveries', 81),
  ('deliveries.reconcile',      'Deliveries',       'reconcile',       'Resolve route reconciliation exceptions', 82),
  ('driver.app',                'Driver app',       'use',             'Use the driver application', 90),
  ('routes.manage',             'Routes',           'manage',          'Manage routes and zones', 95),
  ('shops.view',                'Water Shops',      'view',            'View water shops', 100),
  ('shops.manage',              'Water Shops',      'manage',          'Manage water shops', 101),
  ('shops.stock_approve',       'Water Shops',      'stock_approve',   'Approve shop stock requests', 102),
  ('shop_pos.use',              'Water Shops',      'pos',             'Use the shop POS and daily closing', 103),
  ('shops.settle',              'Water Shops',      'settle',          'Run shop settlements', 104),
  ('inventory.view',            'Inventory',        'view',            'View stock', 110),
  ('inventory.manage',          'Inventory',        'manage',          'Receive, issue and transfer stock', 111),
  ('inventory.adjust',          'Inventory',        'adjust',          'Approve stock adjustments', 112),
  ('production.view',           'Production',       'view',            'View production batches', 120),
  ('production.manage',         'Production',       'manage',          'Record production', 121),
  ('qc.view',                   'Quality Control',  'view',            'View QC results', 130),
  ('qc.manage',                 'Quality Control',  'manage',          'Record QC tests and results', 131),
  ('qc.release',                'Quality Control',  'release',         'Release held or failed batches', 132),
  ('procurement.view',          'Procurement',      'view',            'View purchasing', 140),
  ('procurement.manage',        'Procurement',      'manage',          'Create purchase requests and orders', 141),
  ('procurement.approve',       'Procurement',      'approve',         'Approve purchases', 142),
  ('suppliers.manage',          'Suppliers',        'manage',          'Manage suppliers', 145),
  ('payments.view',             'Payments',         'view',            'View payments', 150),
  ('payments.manage',           'Payments',         'manage',          'Record payments and refunds', 151),
  ('accounting.view',           'Accounting',       'view',            'View the general ledger and reports', 160),
  ('accounting.manual_journal', 'Accounting',       'manual_journal',  'Post manual journals', 161),
  ('accounting.reverse',        'Accounting',       'reverse',         'Reverse journal entries', 162),
  ('accounting.period_close',   'Accounting',       'period_close',    'Open and close accounting periods', 163),
  ('expenses.view',             'Expenses',         'view',            'View expenses', 170),
  ('expenses.manage',           'Expenses',         'manage',          'Record expenses', 171),
  ('expenses.approve',          'Expenses',         'approve',         'Approve expenses', 172),
  ('hr.view',                   'HR & Payroll',     'view',            'View employee records', 180),
  ('hr.manage',                 'HR & Payroll',     'manage',          'Manage employees, attendance and leave', 181),
  ('payroll.run',               'HR & Payroll',     'payroll',         'Run payroll', 182),
  ('sales_reps.manage',         'Sales Reps',       'manage',          'Manage sales representatives and targets', 190),
  ('distributors.manage',       'Distributors',     'manage',          'Manage distributors and dealers', 195),
  ('fleet.manage',              'Fleet',            'manage',          'Manage vehicles, fuel and maintenance', 200),
  ('assets.manage',             'Assets',           'manage',          'Manage fixed assets', 205),
  ('complaints.view',           'Complaints',       'view',            'View complaints', 210),
  ('complaints.manage',         'Complaints',       'manage',          'Handle complaints', 211),
  ('crm.manage',                'Marketing / CRM',  'manage',          'Manage leads, campaigns and promotions', 215),
  ('documents.view',            'Documents',        'view',            'View documents', 220),
  ('documents.manage',          'Documents',        'manage',          'Upload and manage documents', 221),
  ('approvals.act',             'Approvals',        'act',             'Approve or reject requests', 225),
  ('reports.view',              'Reports',          'view',            'View reports', 230),
  ('reports.export',            'Reports',          'export',          'Export data', 231),
  ('ai.ask',                    'AI Assistant',     'use',             'Use the read-only AI assistant', 235),
  ('audit.view',                'Audit Trail',      'view',            'View the audit trail', 240),
  ('users.manage',              'Administration',   'users',           'Manage users and role assignments', 250),
  ('roles.manage',              'Administration',   'roles',           'Create and edit roles', 251),
  ('settings.manage',           'Administration',   'settings',        'Change system settings', 252),
  ('devices.manage',            'Administration',   'devices',         'Register devices', 253);

-- ---------------------------------------------------------------------
-- Default roles (configurable afterwards)
-- ---------------------------------------------------------------------
insert into public.roles (code, name, role_group, is_system, description) values
  ('super_admin',          'Super Admin',          'management',     true,  'Full access to everything'),
  ('director',             'Director',             'management',     true,  'Company-wide visibility and approvals'),
  ('finance_manager',      'Finance Manager',      'management',     true,  'Accounting, payments, credit and approvals'),
  ('operations_manager',   'Operations Manager',   'management',     true,  'Production, warehouse, delivery and shops'),
  ('warehouse_manager',    'Warehouse Manager',    'operations',     true,  'Warehouse, stock and bottle handling'),
  ('production_manager',   'Production Manager',   'operations',     true,  'Production batches'),
  ('quality_officer',      'Quality Officer',      'operations',     true,  'Quality control'),
  ('delivery_manager',     'Delivery Manager',     'operations',     true,  'Routes, drivers and reconciliation'),
  ('driver',               'Driver',               'operations',     true,  'Driver application only'),
  ('sales_representative', 'Sales Representative', 'operations',     true,  'Customers, orders and collections'),
  ('accountant',           'Accountant',           'commercial',     true,  'Day-to-day accounting'),
  ('shop_manager',         'Shop Manager',         'commercial',     true,  'Runs a water shop'),
  ('shop_cashier',         'Shop Cashier',         'commercial',     true,  'Shop POS only'),
  ('distributor_manager',  'Distributor Manager',  'commercial',     true,  'Distributors and dealers'),
  ('hr_manager',           'HR Manager',           'administration', true,  'Employees and payroll'),
  ('procurement_officer',  'Procurement Officer',  'administration', true,  'Purchasing and suppliers');

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  join (values
    ('director', array['dashboard.view','customers.view','customers.credit','products.view','prices.manage','orders.view',
                       'pos.discount','bottles.view','bottles.writeoff','deliveries.view','shops.view','shops.stock_approve',
                       'inventory.view','inventory.adjust','production.view','qc.view','qc.release','procurement.view',
                       'procurement.approve','payments.view','accounting.view','expenses.view','expenses.approve','hr.view',
                       'complaints.view','documents.view','approvals.act','reports.view','reports.export','ai.ask','audit.view',
                       'labels.view']),
    ('finance_manager', array['dashboard.view','customers.view','customers.credit','products.view','prices.manage','orders.view',
                       'bottles.view','bottles.writeoff','shops.view','shops.settle','inventory.view','procurement.view',
                       'procurement.approve','suppliers.manage','payments.view','payments.manage','accounting.view',
                       'accounting.manual_journal','accounting.reverse','accounting.period_close','expenses.view',
                       'expenses.manage','expenses.approve','approvals.act','reports.view','reports.export','audit.view',
                       'documents.view','ai.ask']),
    ('operations_manager', array['dashboard.view','customers.view','products.view','orders.view','orders.manage','bottles.view',
                       'bottles.manage','bottles.external','bottles.writeoff','labels.view','labels.print','deliveries.view',
                       'deliveries.manage','deliveries.reconcile','routes.manage','shops.view','shops.manage','shops.stock_approve',
                       'inventory.view','inventory.manage','inventory.adjust','production.view','production.manage','qc.view',
                       'qc.release','fleet.manage','assets.manage','complaints.view','complaints.manage','approvals.act',
                       'reports.view','documents.view','ai.ask']),
    ('warehouse_manager', array['dashboard.view','products.view','orders.view','bottles.view','bottles.manage','bottles.external',
                       'labels.view','labels.print','deliveries.view','shops.view','shops.stock_approve','inventory.view',
                       'inventory.manage','inventory.adjust','production.view','qc.view','approvals.act','reports.view']),
    ('production_manager', array['dashboard.view','products.view','inventory.view','production.view','production.manage',
                       'qc.view','bottles.view','labels.view','reports.view']),
    ('quality_officer', array['production.view','qc.view','qc.manage','complaints.view','documents.view','documents.manage']),
    ('delivery_manager', array['dashboard.view','customers.view','orders.view','orders.manage','bottles.view','bottles.manage',
                       'bottles.external','deliveries.view','deliveries.manage','deliveries.reconcile','routes.manage',
                       'fleet.manage','complaints.view','reports.view']),
    ('driver', array['driver.app']),
    ('sales_representative', array['customers.view','customers.manage','products.view','orders.view','orders.manage',
                       'payments.view','complaints.view','complaints.manage','crm.manage']),
    ('accountant', array['customers.view','products.view','orders.view','payments.view','payments.manage','accounting.view',
                       'accounting.manual_journal','expenses.view','expenses.manage','shops.view','shops.settle',
                       'reports.view','documents.view']),
    ('shop_manager', array['shops.view','shop_pos.use','customers.view','products.view','bottles.view','inventory.view',
                       'reports.view']),
    ('shop_cashier', array['shop_pos.use','customers.view','products.view']),
    ('distributor_manager', array['customers.view','products.view','orders.view','orders.manage','distributors.manage',
                       'bottles.view','reports.view']),
    ('hr_manager', array['hr.view','hr.manage','payroll.run','documents.view','documents.manage']),
    ('procurement_officer', array['products.view','inventory.view','procurement.view','procurement.manage','suppliers.manage',
                       'documents.view'])
  ) as m(role_code, perms) on m.role_code = r.code
  cross join lateral unnest(m.perms) as x(code)
  join public.permissions p on p.code = x.code;

-- ---------------------------------------------------------------------
-- Locations
-- ---------------------------------------------------------------------
insert into public.locations (code, name, location_type) values
  ('HQ',  'Head Office',    'head_office'),
  ('WH1', 'Main Warehouse', 'warehouse'),
  ('EXT', 'External Bottle Holding Area', 'external_holding');

-- ---------------------------------------------------------------------
-- Document types
-- ---------------------------------------------------------------------
insert into public.document_types (code, name, padding) values
  ('JE',  'Journal entry', 6),
  ('LBL', 'Label batch', 6),
  ('ORD', 'Sales order', 6),
  ('INV', 'Tax invoice', 6),
  ('RCP', 'Receipt', 6),
  ('DN',  'Delivery note', 6),
  ('RUN', 'Route run', 6),
  ('STR', 'Stock transfer', 6),
  ('SRQ', 'Shop stock request', 6),
  ('SET', 'Shop settlement', 6),
  ('EHO', 'External bottle hand-over', 6),
  ('PAY', 'Payment', 6),
  ('CN',  'Credit note', 6);

-- ---------------------------------------------------------------------
-- Identifier series
-- ---------------------------------------------------------------------
insert into public.identifier_series (code, name, entity_type, padding) values
  ('OLA-BTL',  'OLA returnable bottles',           'bottle',          8),
  ('OLA-CRT',  'OLA crates / pallets',             'crate',           8),
  ('EXT-AQUA', 'External tags — Aqua Water',       'external_bottle', 8),
  ('EXT-XYZ',  'External tags — XYZ Water',        'external_bottle', 8),
  ('EXT-ABC',  'External tags — ABC Water',        'external_bottle', 8),
  ('EXT-UNK',  'External tags — unknown brand',    'external_bottle', 8);

-- ---------------------------------------------------------------------
-- Settings (definitions + initial values; all editable later)
-- ---------------------------------------------------------------------
insert into public.setting_definitions (key, module, label, description, value_type, choices, min_value, max_value, sort_order) values
  ('company.name',                         'Company',   'Company name',                    'Shown on receipts and documents', 'text', null, null, null, 1),
  ('company.vat_registration_no',          'Company',   'VAT registration number',         'Printed on tax invoices', 'text', null, null, null, 2),
  ('company.timezone',                     'Company',   'Time zone',                       'Business day boundary', 'choice', array['Asia/Colombo'], null, null, 3),
  ('company.currency',                     'Company',   'Base currency',                   null, 'choice', array['LKR'], null, null, 4),
  ('company.head_office_location',         'Company',   'Head office location code',       'Used for company-wide document numbers', 'text', null, null, null, 5),
  ('receipts.footer_text',                 'Receipts',  'Receipt footer',                  'Printed at the bottom of every receipt', 'text', null, null, null, 10),
  ('bottles.external_tracking_mode',       'Bottles',   'External bottle tracking',        'tagged = each bottle gets an EXT- label; count = counted per company', 'choice', array['tagged','count'], null, null, 20),
  ('bottles.external_intake_photo',        'Bottles',   'Photo on external intake',        null, 'choice', array['always','unknown_brand_only','never'], null, null, 21),
  ('bottles.external_holding_alert_qty',   'Bottles',   'External holding alert (per company)', 'Alert when bottles held for one company exceed this', 'integer', null, 0, null, 22),
  ('bottles.inactive_days_alert',          'Bottles',   'Bottle inactivity alert (days)',  'Flag bottles with no movement for this many days', 'integer', null, 1, null, 23),
  ('approvals.discount_percent',           'Approvals', 'Discount needing approval (%)',   null, 'percent', null, null, null, 30),
  ('approvals.purchase_amount',            'Approvals', 'Purchase needing approval (Rs.)', null, 'money', null, null, null, 31),
  ('approvals.expense_amount',             'Approvals', 'Expense needing approval (Rs.)',  null, 'money', null, null, null, 32),
  ('approvals.stock_adjustment_qty',       'Approvals', 'Stock adjustment needing approval (units)', null, 'integer', null, 0, null, 33),
  ('offline.unsynced_alert_hours',         'Offline',   'Unsynced data alert (hours)',     'Warn managers about devices with unsynced transactions', 'integer', null, 1, 72, 40);

insert into public.system_settings (key, value, effective_from) values
  ('company.name',                       '"OLA Water"',     date '2026-01-01'),
  ('company.vat_registration_no',        '""',              date '2026-01-01'),
  ('company.timezone',                   '"Asia/Colombo"',  date '2026-01-01'),
  ('company.currency',                   '"LKR"',           date '2026-01-01'),
  ('company.head_office_location',       '"HQ"',            date '2026-01-01'),
  ('receipts.footer_text',               '"Thank you for choosing OLA Water. Please return empty bottles."', date '2026-01-01'),
  ('bottles.external_tracking_mode',     '"tagged"',        date '2026-01-01'),
  ('bottles.external_intake_photo',      '"unknown_brand_only"', date '2026-01-01'),
  ('bottles.external_holding_alert_qty', '100',             date '2026-01-01'),
  ('bottles.inactive_days_alert',        '60',              date '2026-01-01'),
  ('approvals.discount_percent',         '10',              date '2026-01-01'),
  ('approvals.purchase_amount',          '100000',          date '2026-01-01'),
  ('approvals.expense_amount',           '25000',           date '2026-01-01'),
  ('approvals.stock_adjustment_qty',     '50',              date '2026-01-01'),
  ('offline.unsynced_alert_hours',       '4',               date '2026-01-01');

-- ---------------------------------------------------------------------
-- Chart of accounts (default template; editable)
-- ---------------------------------------------------------------------
insert into public.accounts (code, name, account_type, is_postable, system_key) values
  ('1000', 'Assets',                               'asset',     false, null),
  ('2000', 'Liabilities',                          'liability', false, null),
  ('3000', 'Equity',                               'equity',    false, null),
  ('4000', 'Income',                               'income',    false, null),
  ('5000', 'Cost of Sales',                        'expense',   false, null),
  ('6000', 'Operating Expenses',                   'expense',   false, null);

insert into public.accounts (code, name, account_type, system_key, parent_id)
select v.code, v.name, v.type, v.key, (select id from public.accounts where code = v.parent)
  from (values
    ('1100', 'Cash in Hand',                        'asset',     'cash',                   '1000'),
    ('1110', 'Petty Cash',                          'asset',     'petty_cash',             '1000'),
    ('1120', 'Driver Cash in Transit',              'asset',     'driver_cash',            '1000'),
    ('1130', 'Shop Cash Clearing',                  'asset',     'shop_cash',              '1000'),
    ('1200', 'Bank — Current Account',              'asset',     'bank',                   '1000'),
    ('1210', 'Card / QR Settlement Clearing',       'asset',     'card_clearing',          '1000'),
    ('1300', 'Accounts Receivable — Customers',     'asset',     'ar',                     '1000'),
    ('1310', 'Accounts Receivable — Water Shops',   'asset',     'ar_shops',               '1000'),
    ('1320', 'Accounts Receivable — Distributors',  'asset',     'ar_distributors',        '1000'),
    ('1400', 'Inventory — Finished Goods',          'asset',     'inv_finished',           '1000'),
    ('1410', 'Inventory — Raw Materials',           'asset',     'inv_raw',                '1000'),
    ('1420', 'Inventory — Returnable Bottles',      'asset',     'inv_bottles',            '1000'),
    ('1500', 'VAT Input',                           'asset',     'vat_input',              '1000'),
    ('1600', 'Plant & Machinery',                   'asset',     'fa_plant',               '1000'),
    ('1610', 'Motor Vehicles',                      'asset',     'fa_vehicles',            '1000'),
    ('1620', 'Office Equipment',                    'asset',     'fa_office',              '1000'),
    ('1690', 'Accumulated Depreciation',            'asset',     'accum_depreciation',     '1000'),
    ('2100', 'Accounts Payable',                    'liability', 'ap',                     '2000'),
    ('2200', 'Bottle Deposits Held',                'liability', 'bottle_deposits',        '2000'),
    ('2300', 'VAT Output',                          'liability', 'vat_output',             '2000'),
    ('2310', 'SSCL Payable',                        'liability', 'sscl_payable',           '2000'),
    ('2400', 'EPF Payable',                         'liability', 'epf_payable',            '2000'),
    ('2410', 'ETF Payable',                         'liability', 'etf_payable',            '2000'),
    ('2420', 'PAYE / APIT Payable',                 'liability', 'paye_payable',           '2000'),
    ('2500', 'Salaries Payable',                    'liability', 'salaries_payable',       '2000'),
    ('2600', 'Customer Advances',                   'liability', 'customer_advances',      '2000'),
    ('3100', 'Share Capital',                       'equity',    'share_capital',          '3000'),
    ('3200', 'Retained Earnings',                   'equity',    'retained_earnings',      '3000'),
    ('3900', 'Opening Balance Equity',              'equity',    'opening_equity',         '3000'),
    ('4100', 'Sales — Bottled Water',               'income',    'sales',                  '4000'),
    ('4110', 'Sales — Water Shops',                 'income',    'sales_shops',            '4000'),
    ('4150', 'Sales Discounts',                     'income',    'sales_discounts',        '4000'),
    ('4200', 'Delivery Charges',                    'income',    'delivery_income',        '4000'),
    ('4300', 'Forfeited Bottle Deposits',           'income',    'deposit_forfeit_income', '4000'),
    ('4400', 'Bottle Replacement Charges',          'income',    'bottle_charge_income',   '4000'),
    ('4900', 'Other Income',                        'income',    'other_income',           '4000'),
    ('5100', 'Cost of Goods Sold',                  'expense',   'cogs',                   '5000'),
    ('6100', 'Fuel',                                'expense',   'exp_fuel',               '6000'),
    ('6110', 'Electricity',                         'expense',   'exp_electricity',        '6000'),
    ('6120', 'Water',                               'expense',   'exp_water',              '6000'),
    ('6130', 'Rent',                                'expense',   'exp_rent',               '6000'),
    ('6140', 'Salaries & Wages',                    'expense',   'exp_salaries',           '6000'),
    ('6150', 'Vehicle Repairs',                     'expense',   'exp_vehicle_repair',     '6000'),
    ('6160', 'Maintenance',                         'expense',   'exp_maintenance',        '6000'),
    ('6170', 'Marketing',                           'expense',   'exp_marketing',          '6000'),
    ('6180', 'Packaging',                           'expense',   'exp_packaging',          '6000'),
    ('6190', 'Office Expenses',                     'expense',   'exp_office',             '6000'),
    ('6200', 'Utilities',                           'expense',   'exp_utilities',          '6000'),
    ('6300', 'Bottle Losses & Write-offs',          'expense',   'bottle_writeoff',        '6000'),
    ('6310', 'Cash Shortages',                      'expense',   'cash_shortage',          '6000'),
    ('6320', 'Inventory Adjustments',               'expense',   'inventory_adjustment',   '6000'),
    ('6400', 'Depreciation',                        'expense',   'exp_depreciation',       '6000'),
    ('6900', 'Other Expenses',                      'expense',   'exp_other',              '6000')
  ) as v(code, name, type, key, parent);

-- ---------------------------------------------------------------------
-- Posting events and rules (Phase 1 events defined up front)
-- ---------------------------------------------------------------------
insert into public.posting_event_types (code, module, description, amount_keys) values
  ('sale.cash',              'sales',    'Cash sale (POS or delivery)',                  array['gross','net','vat','levy']),
  ('sale.credit',            'sales',    'Credit sale to a customer',                    array['gross','net','vat','levy']),
  ('sale.card',              'sales',    'Card / QR sale',                               array['gross','net','vat','levy']),
  ('sale.shop_transfer',     'shops',    'Stock issued to a water shop on account',      array['gross','net','vat','levy']),
  ('payment.cash',           'payments', 'Customer payment received in cash',            array['amount']),
  ('payment.bank',           'payments', 'Customer payment received by bank transfer',   array['amount']),
  ('payment.shop',           'payments', 'Water shop payment to OLA',                    array['amount']),
  ('deposit.collected',      'bottles',  'Bottle deposit collected in cash',             array['deposit']),
  ('deposit.refunded',       'bottles',  'Bottle deposit refunded in cash',              array['deposit']),
  ('deposit.forfeited',      'bottles',  'Deposit kept for a lost bottle',               array['deposit']),
  ('bottle.writeoff',        'bottles',  'Bottle written off at replacement value',      array['value']),
  ('bottle.charge',          'bottles',  'Customer charged for a lost bottle (on account)', array['value']),
  ('driver.cash_shortage',   'delivery', 'Driver cash shortage written off',             array['amount']),
  ('driver.cash_handover',   'delivery', 'Driver hands collected cash to the office',   array['amount']),
  ('manual.journal',         'accounting', 'Manual journal entry',                       array[]::text[]);

insert into public.posting_rules (event_type, line_no, side, account_key, amount_key, description) values
  ('sale.cash',            1, 'debit',  'cash',                   'gross',   'Cash received'),
  ('sale.cash',            2, 'credit', 'sales',                  'net',     'Sales'),
  ('sale.cash',            3, 'credit', 'vat_output',             'vat',     'VAT output'),
  ('sale.cash',            4, 'credit', 'sscl_payable',           'levy',    'SSCL'),
  ('sale.credit',          1, 'debit',  'ar',                     'gross',   'Receivable'),
  ('sale.credit',          2, 'credit', 'sales',                  'net',     'Sales'),
  ('sale.credit',          3, 'credit', 'vat_output',             'vat',     'VAT output'),
  ('sale.credit',          4, 'credit', 'sscl_payable',           'levy',    'SSCL'),
  ('sale.card',            1, 'debit',  'card_clearing',          'gross',   'Card / QR receipt'),
  ('sale.card',            2, 'credit', 'sales',                  'net',     'Sales'),
  ('sale.card',            3, 'credit', 'vat_output',             'vat',     'VAT output'),
  ('sale.card',            4, 'credit', 'sscl_payable',           'levy',    'SSCL'),
  ('sale.shop_transfer',   1, 'debit',  'ar_shops',               'gross',   'Shop receivable'),
  ('sale.shop_transfer',   2, 'credit', 'sales_shops',            'net',     'Sales to water shops'),
  ('sale.shop_transfer',   3, 'credit', 'vat_output',             'vat',     'VAT output'),
  ('sale.shop_transfer',   4, 'credit', 'sscl_payable',           'levy',    'SSCL'),
  ('payment.cash',         1, 'debit',  'cash',                   'amount',  'Cash received'),
  ('payment.cash',         2, 'credit', 'ar',                     'amount',  'Receivable settled'),
  ('payment.bank',         1, 'debit',  'bank',                   'amount',  'Bank receipt'),
  ('payment.bank',         2, 'credit', 'ar',                     'amount',  'Receivable settled'),
  ('payment.shop',         1, 'debit',  'bank',                   'amount',  'Shop payment received'),
  ('payment.shop',         2, 'credit', 'ar_shops',               'amount',  'Shop receivable settled'),
  ('deposit.collected',    1, 'debit',  'cash',                   'deposit', 'Deposit received'),
  ('deposit.collected',    2, 'credit', 'bottle_deposits',        'deposit', 'Deposit held'),
  ('deposit.refunded',     1, 'debit',  'bottle_deposits',        'deposit', 'Deposit released'),
  ('deposit.refunded',     2, 'credit', 'cash',                   'deposit', 'Deposit refunded'),
  ('deposit.forfeited',    1, 'debit',  'bottle_deposits',        'deposit', 'Deposit released'),
  ('deposit.forfeited',    2, 'credit', 'deposit_forfeit_income', 'deposit', 'Deposit forfeited'),
  ('bottle.writeoff',      1, 'debit',  'bottle_writeoff',        'value',   'Bottle written off'),
  ('bottle.writeoff',      2, 'credit', 'inv_bottles',            'value',   'Bottle stock reduced'),
  ('bottle.charge',        1, 'debit',  'ar',                     'value',   'Customer charged'),
  ('bottle.charge',        2, 'credit', 'bottle_charge_income',   'value',   'Bottle replacement charge'),
  ('driver.cash_shortage', 1, 'debit',  'cash_shortage',          'amount',  'Cash shortage'),
  ('driver.cash_shortage', 2, 'credit', 'driver_cash',            'amount',  'Driver cash cleared'),
  ('driver.cash_handover', 1, 'debit',  'cash',                   'amount',  'Cash received from driver'),
  ('driver.cash_handover', 2, 'credit', 'driver_cash',            'amount',  'Driver cash cleared');

-- ---------------------------------------------------------------------
-- Accounting periods
-- ---------------------------------------------------------------------
select public.ensure_accounting_year(2026);
select public.ensure_accounting_year(2027);
