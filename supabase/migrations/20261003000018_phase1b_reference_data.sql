-- =====================================================================
-- OLA Water ERP — Phase 1B
-- 0018: accounts, posting rules, role, grants for shops and tills
-- =====================================================================

insert into public.accounts (code, name, account_type, system_key, parent_id)
select v.code, v.name, v.type, v.key, (select id from public.accounts where code = v.parent)
  from (values
    ('2510', 'Shop Commissions Payable', 'liability', 'commissions_payable', '2000'),
    ('6210', 'Shop Commissions',         'expense',   'exp_shop_commission', '6000')
  ) as v(code, name, type, key, parent);

insert into public.posting_event_types (code, module, description, amount_keys) values
  ('invoice.shop',          'shops',    'Water shop sale or stock invoiced to a dealer shop',
     array['ar_debit','ar_credit','net','vat','delivery','deposit','deposit_refund','bottle_charge']),
  ('payment.shop_cash',     'shops',    'Cash taken at a company-owned shop till',           array['amount']),
  ('refund.cash',           'payments', 'Deposit refunded in cash at a head-office counter', array['amount']),
  ('refund.shop_cash',      'shops',    'Deposit refunded in cash at a shop till',           array['amount']),
  ('shop.cash_remit',       'shops',    'Shop takings banked',                               array['amount']),
  ('shop.cash_shortage',    'shops',    'Shop till shortage written off',                    array['amount']),
  ('shop.commission',       'shops',    'Commission accrued for a company-owned shop',       array['amount']),
  ('counter.cash_shortage', 'sales',    'Head-office counter shortage written off',          array['amount']);

insert into public.posting_rules (event_type, line_no, side, account_key, amount_key, description) values
  ('invoice.shop', 1, 'debit',  'ar',                   'ar_debit',       'Receivable'),
  ('invoice.shop', 2, 'debit',  'bottle_deposits',      'deposit_refund', 'Deposit refunded'),
  ('invoice.shop', 3, 'credit', 'ar',                   'ar_credit',      'Credit to customer'),
  ('invoice.shop', 4, 'credit', 'sales_shops',          'net',            'Sales — water shops'),
  ('invoice.shop', 5, 'credit', 'vat_output',           'vat',            'VAT output'),
  ('invoice.shop', 6, 'credit', 'delivery_income',      'delivery',       'Delivery charge'),
  ('invoice.shop', 7, 'credit', 'bottle_deposits',      'deposit',        'Bottle deposit held'),
  ('invoice.shop', 8, 'credit', 'bottle_charge_income', 'bottle_charge',  'Bottle charge'),
  ('payment.shop_cash',     1, 'debit',  'shop_cash',           'amount', 'Cash in the shop till'),
  ('payment.shop_cash',     2, 'credit', 'ar',                  'amount', 'Receivable settled'),
  ('refund.cash',           1, 'debit',  'ar',                  'amount', 'Refund owed to customer settled'),
  ('refund.cash',           2, 'credit', 'cash',                'amount', 'Cash paid out'),
  ('refund.shop_cash',      1, 'debit',  'ar',                  'amount', 'Refund owed to customer settled'),
  ('refund.shop_cash',      2, 'credit', 'shop_cash',           'amount', 'Cash paid out of the till'),
  ('shop.cash_remit',       1, 'debit',  'bank',                'amount', 'Shop takings banked'),
  ('shop.cash_remit',       2, 'credit', 'shop_cash',           'amount', 'Shop cash cleared'),
  ('shop.cash_shortage',    1, 'debit',  'cash_shortage',       'amount', 'Till shortage'),
  ('shop.cash_shortage',    2, 'credit', 'shop_cash',           'amount', 'Shop cash cleared'),
  ('shop.commission',       1, 'debit',  'exp_shop_commission', 'amount', 'Shop commission'),
  ('shop.commission',       2, 'credit', 'commissions_payable', 'amount', 'Commission payable'),
  ('counter.cash_shortage', 1, 'debit',  'cash_shortage',       'amount', 'Counter shortage'),
  ('counter.cash_shortage', 2, 'credit', 'cash',                'amount', 'Cash cleared');

-- Head-office counter staff
insert into public.roles (code, name, role_group, is_system, description)
values ('counter_cashier', 'Counter Cashier', 'commercial', true, 'Head-office / depot counter (POS) only');
insert into public.role_permissions (role_id, permission_code)
select (select id from public.roles where code = 'counter_cashier'), x
  from unnest(array['pos.use','customers.view','products.view']) x;

-- Shop managers may request and receive stock and see their exceptions (already via shop_pos.use);
-- warehouse managers receive bottles back from shops (inventory.manage) — no change needed.

-- ---------------------------------------------------------------------------------------
-- Function privileges (re-applied after functions are added)
-- ---------------------------------------------------------------------------------------
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
