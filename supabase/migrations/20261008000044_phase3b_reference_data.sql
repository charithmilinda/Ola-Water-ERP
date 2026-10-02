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
