-- =====================================================================
-- OLA Water ERP — Phase 3A
-- 0039: numbering, permissions, approval rules, notification types,
--       message templates, complaint and document categories, settings
-- =====================================================================
insert into public.document_types (code, name, padding) values
  ('APR', 'Approval request', 6), ('CMP', 'Complaint', 6), ('DOC', 'Document', 6)
on conflict (code) do nothing;

insert into public.permissions (code, module, action, description, sort_order) values
  ('prices.approve', 'Products', 'prices_approve', 'Approve price list changes', 33)
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, x.code
  from public.roles r
  join (values
    ('director',            array['prices.approve','documents.manage','complaints.manage']),
    ('delivery_manager',    array['complaints.manage','approvals.act']),
    ('shop_manager',        array['complaints.view']),
    ('quality_officer',     array['complaints.manage']),
    ('finance_manager',     array['documents.manage','complaints.view']),
    ('operations_manager',  array['documents.manage']),
    ('procurement_officer', array['documents.manage']),
    ('hr_manager',          array['approvals.act'])
  ) as m(role_code, perms) on m.role_code = r.code
  cross join lateral unnest(m.perms) as x(code)
 where exists (select 1 from public.permissions p where p.code = x.code)
   and not exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_code = x.code);

-- ---------------------------------------------------------------------
-- Approval rules (approver permission and number of approvers editable in Approvals → Rules)
-- ---------------------------------------------------------------------
insert into public.approval_rules (kind, name, description, approver_permission, levels, threshold_setting, functions, sort_order) values
  ('stock_adjustment', 'Large stock adjustment', 'A stock count that changes stock by more than the limit',
     'inventory.adjust', 1, 'approvals.stock_adjustment_qty', array['adjust_stock'], 10),
  ('order_discount', 'Discount above the limit', 'An order line discounted by more than the limit (the order is created when approved)',
     'pos.discount', 1, 'approvals.discount_percent', array['save_order'], 20),
  ('credit_change', 'Credit limit / payment terms', 'A new credit customer or a change to a credit limit or payment terms (the customer stays on the old terms until approved)',
     'customers.credit', 1, null, array['set_customer_credit'], 30),
  ('price_change', 'Price list change', 'New prices on a price list (they take effect from the chosen date, or the approval date if later)',
     'prices.approve', 1, null, array['set_prices'], 40),
  ('bottle_write_off', 'Bottle write-off', 'Writing off lost or damaged bottles (from an exception, or a single bottle)',
     'bottles.writeoff', 1, null, array['resolve_exception','mark_bottle'], 50);

-- ---------------------------------------------------------------------
-- Notification types
-- ---------------------------------------------------------------------
insert into public.notification_types (code, name, description, permission, severity, sort_order) values
  ('approval_request',  'Approval needed',              'A request waits for your approval', null, 'warning', 10),
  ('approval_decision', 'Your request was decided',     'Approved or rejected', null, 'info', 11),
  ('pending_approvals', 'Items waiting for approval',   'Daily reminder of expenses, purchases, journals, payroll, leave … waiting', null, 'info', 12),
  ('complaint_new',     'New complaint',                'A complaint nobody is handling yet', 'complaints.manage', 'info', 20),
  ('complaint_assigned','Complaint for you',            'Assigned to you, or an update on one you logged', null, 'info', 21),
  ('complaint_overdue', 'Complaint past its due time',  'Not resolved within the SLA', 'complaints.manage', 'warning', 22),
  ('qc_review',         'Quality complaint to review',  'A customer complaint about a batch', 'qc.manage', 'warning', 30),
  ('qc_hold',           'Batch waiting for QC release', 'Production batch on QC hold', 'qc.release', 'info', 31),
  ('low_stock',         'Low stock',                    'Items at or below the reorder level', 'inventory.manage', 'warning', 40),
  ('overdue_invoices',  'Overdue customer balances',    'Daily summary of overdue invoices', 'payments.manage', 'info', 50),
  ('failed_delivery',   'Failed deliveries',            'Deliveries marked not delivered today', 'deliveries.manage', 'warning', 60),
  ('vehicle_alert',     'Vehicle needs attention',      'Service due or vehicle document expiring', 'fleet.manage', 'warning', 70),
  ('document_expiry',   'Document expiring',            'Licence, insurance, contract … about to expire', 'documents.manage', 'warning', 71),
  ('external_bottles',  'External bottles to hand over','Bottles held for another company above the alert level', 'bottles.external', 'info', 80),
  ('messages_failed',   'Messages not sent',            'SMS / WhatsApp / email that failed', 'settings.manage', 'warning', 90);

-- ---------------------------------------------------------------------
-- Customer message templates (English). Nothing is sent until
-- "Customer messages" is switched on in System Settings and a provider
-- is set up in Vercel.
-- ---------------------------------------------------------------------
insert into public.message_templates (code, name, audience, channel, subject, body, variables, is_active) values
  ('ORDER_CONFIRMED', 'Order confirmed', 'customer', 'sms', 'Your order {{order_no}}',
   'Dear {{customer_name}}, your {{company_name}} order {{order_no}} is confirmed for {{delivery_date}}. Total Rs. {{total}}. Thank you!',
   array['customer_name','order_no','delivery_date','total'], true),
  ('DELIVERED', 'Delivered', 'customer', 'sms', 'Delivery {{delivery_no}}',
   '{{company_name}}: delivered ({{delivery_no}}). Bill Rs. {{invoice_total}}, paid Rs. {{paid}}. Your balance is Rs. {{balance}}. Thank you!',
   array['delivery_no','invoice_total','paid','balance'], true),
  ('DELIVERY_MISSED', 'Delivery missed', 'customer', 'sms', 'We missed you',
   'Sorry, {{company_name}} could not deliver today ({{delivery_no}}). We will contact you to deliver again. {{company_phone}}',
   array['delivery_no','company_phone'], true),
  ('PAYMENT_RECEIVED', 'Payment received', 'customer', 'sms', 'Payment received',
   'Thank you! {{company_name}} received Rs. {{amount}} ({{payment_no}}). Your balance is Rs. {{balance}}.',
   array['amount','payment_no','balance'], true),
  ('PAYMENT_REMINDER', 'Payment reminder', 'customer', 'sms', 'Payment reminder',
   'Dear {{customer_name}}, Rs. {{overdue}} is overdue on your {{company_name}} account (since {{due_date}}). Please pay at your next delivery or call {{company_phone}}.',
   array['customer_name','overdue','due_date','company_phone'], true),
  ('COMPLAINT_RECEIVED', 'Complaint received', 'customer', 'sms', 'Complaint {{complaint_no}}',
   '{{company_name}}: we received your complaint {{complaint_no}} ({{subject}}). We will contact you shortly.',
   array['complaint_no','subject'], true),
  ('COMPLAINT_RESOLVED', 'Complaint resolved', 'customer', 'sms', 'Complaint {{complaint_no}} resolved',
   '{{company_name}}: your complaint {{complaint_no}} is resolved — {{resolution}}. Thank you for your patience.',
   array['complaint_no','resolution'], true);

insert into public.complaint_categories (code, name, default_priority, needs_qc_review, sort_order) values
  ('delivery', 'Delivery (late, missed, wrong address)', 'normal', false, 10),
  ('product',  'Product (taste, smell, colour)',          'high',   true,  20),
  ('quality',  'Quality (particles, contamination)',      'urgent', true,  30),
  ('bottle',   'Bottle (leaking, dirty, damaged)',        'normal', false, 40),
  ('driver',   'Driver behaviour',                        'normal', false, 50),
  ('payment',  'Payment / billing',                       'normal', false, 60),
  ('quantity', 'Quantity (short, wrong items)',           'normal', false, 70),
  ('shop',     'Water shop',                              'normal', false, 80);

insert into public.document_categories (code, name, view_permission, manage_permission, has_expiry, sort_order) values
  ('contract',       'Contracts & agreements',          'documents.view',   'documents.manage',  false, 10),
  ('licence',        'Business licences & permits',     'documents.view',   'documents.manage',  true,  20),
  ('insurance',      'Insurance policies',              'documents.view',   'documents.manage',  true,  30),
  ('vehicle',        'Vehicle documents',               'fleet.manage',     'fleet.manage',      false, 40),
  ('employee',       'Employee documents',              'hr.view',          'hr.manage',         false, 50),
  ('qc_certificate', 'QC certificates',                 'qc.view',          'qc.manage',         false, 60),
  ('lab_report',     'Lab reports (water tests)',       'qc.view',          'qc.manage',         false, 70),
  ('purchase',       'Purchase & supplier documents',   'procurement.view', 'procurement.manage',false, 80),
  ('finance',        'Invoices & finance documents',    'payments.view',    'payments.manage',   false, 90),
  ('other',          'Other',                           'documents.view',   'documents.manage',  false, 100);

insert into public.setting_definitions (key, module, label, description, value_type, choices, min_value, max_value, sort_order) values
  ('company.phone', 'Company', 'Customer hotline', 'Phone number shown in customer messages', 'text', null, null, null, 7),
  ('messaging.enabled', 'Messages', 'Send customer messages (SMS / WhatsApp)', 'Master switch. Set up the provider in Vercel first.', 'boolean', null, null, null, 60),
  ('messaging.reminder_after_days', 'Messages', 'Payment reminder: days overdue', 'First reminder when the oldest unpaid invoice is this many days past due', 'integer', null, 1, 90, 61),
  ('messaging.reminder_repeat_days', 'Messages', 'Payment reminder: repeat every (days)', null, 'integer', null, 1, 60, 62),
  ('complaints.sla_hours_urgent', 'Complaints', 'Resolve urgent complaints within (hours)', null, 'integer', null, 1, 720, 70),
  ('complaints.sla_hours_high', 'Complaints', 'Resolve high-priority complaints within (hours)', null, 'integer', null, 1, 720, 71),
  ('complaints.sla_hours_normal', 'Complaints', 'Resolve normal complaints within (hours)', null, 'integer', null, 1, 720, 72),
  ('complaints.sla_hours_low', 'Complaints', 'Resolve low-priority complaints within (hours)', null, 'integer', null, 1, 720, 73),
  ('documents.alert_days', 'Documents', 'Warn before a document expires (days)', 'Default for new documents', 'integer', null, 1, 365, 80),
  ('notifications.scan_minutes', 'Notifications', 'Check for new alerts every (minutes)', null, 'integer', null, 5, 240, 85);

insert into public.system_settings (key, value, effective_from) values
  ('company.phone', '""', date '2026-01-01'),
  ('messaging.enabled', 'false', date '2026-01-01'),
  ('messaging.reminder_after_days', '7', date '2026-01-01'),
  ('messaging.reminder_repeat_days', '7', date '2026-01-01'),
  ('complaints.sla_hours_urgent', '4', date '2026-01-01'),
  ('complaints.sla_hours_high', '24', date '2026-01-01'),
  ('complaints.sla_hours_normal', '48', date '2026-01-01'),
  ('complaints.sla_hours_low', '72', date '2026-01-01'),
  ('documents.alert_days', '30', date '2026-01-01'),
  ('notifications.scan_minutes', '10', date '2026-01-01');
