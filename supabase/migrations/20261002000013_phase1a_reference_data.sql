-- =====================================================================
-- OLA Water ERP — Phase 1A
-- 0013: reference data for Phase 1A + function privileges
-- (Prices, VAT rate and deposit amounts are NOT seeded — management sets
--  them in the ERP before the first order.)
-- =====================================================================

-- Accounts ---------------------------------------------------------------
insert into public.accounts (code, name, account_type, system_key, parent_id)
select '1140', 'Cheques in Hand', 'asset', 'cheques_in_hand', id from public.accounts where code = '1000';

-- Document types ----------------------------------------------------------
insert into public.document_types (code, name, padding) values ('ADJ', 'Stock adjustment', 6)
on conflict (code) do nothing;

-- Posting events ------------------------------------------------------------
insert into public.posting_event_types (code, module, description, amount_keys) values
  ('invoice.issued',       'sales',    'Delivery / sales invoice issued on account',
     array['ar_debit','ar_credit','net','vat','delivery','deposit','deposit_refund','bottle_charge']),
  ('cogs.sale',            'sales',    'Cost of goods sold',                         array['value']),
  ('payment.driver_cash',  'payments', 'Cash collected by a driver',                 array['amount']),
  ('payment.card',         'payments', 'Card or QR payment',                          array['amount']),
  ('payment.cheque',       'payments', 'Cheque received',                             array['amount']),
  ('driver.cash_float',    'delivery', 'Cash float given to a driver',                array['amount']),
  ('driver.bottle_charge', 'delivery', 'Missing bottles charged to the driver',       array['amount']),
  ('driver.stock_charge',  'delivery', 'Missing stock charged to the driver',         array['amount']),
  ('stock.opening',        'inventory','Opening stock at go-live',                    array['value']),
  ('stock.adjust_gain',    'inventory','Stock count gain',                            array['value']),
  ('stock.adjust_loss',    'inventory','Stock count loss',                            array['value']);

insert into public.posting_rules (event_type, line_no, side, account_key, amount_key, description) values
  ('invoice.issued', 1, 'debit',  'ar',                   'ar_debit',       'Receivable'),
  ('invoice.issued', 2, 'debit',  'bottle_deposits',      'deposit_refund', 'Deposit refunded'),
  ('invoice.issued', 3, 'credit', 'ar',                   'ar_credit',      'Credit to customer'),
  ('invoice.issued', 4, 'credit', 'sales',                'net',            'Sales'),
  ('invoice.issued', 5, 'credit', 'vat_output',           'vat',            'VAT output'),
  ('invoice.issued', 6, 'credit', 'delivery_income',      'delivery',       'Delivery charge'),
  ('invoice.issued', 7, 'credit', 'bottle_deposits',      'deposit',        'Bottle deposit held'),
  ('invoice.issued', 8, 'credit', 'bottle_charge_income', 'bottle_charge',  'Bottle charge'),
  ('cogs.sale',            1, 'debit',  'cogs',                 'value',  'Cost of goods sold'),
  ('cogs.sale',            2, 'credit', 'inv_finished',         'value',  'Finished goods issued'),
  ('payment.driver_cash',  1, 'debit',  'driver_cash',          'amount', 'Cash with driver'),
  ('payment.driver_cash',  2, 'credit', 'ar',                   'amount', 'Receivable settled'),
  ('payment.card',         1, 'debit',  'card_clearing',        'amount', 'Card / QR receipt'),
  ('payment.card',         2, 'credit', 'ar',                   'amount', 'Receivable settled'),
  ('payment.cheque',       1, 'debit',  'cheques_in_hand',      'amount', 'Cheque received'),
  ('payment.cheque',       2, 'credit', 'ar',                   'amount', 'Receivable settled'),
  ('driver.cash_float',    1, 'debit',  'driver_cash',          'amount', 'Float with driver'),
  ('driver.cash_float',    2, 'credit', 'cash',                 'amount', 'Float issued'),
  ('driver.bottle_charge', 1, 'debit',  'driver_cash',          'amount', 'Owed by driver'),
  ('driver.bottle_charge', 2, 'credit', 'bottle_charge_income', 'amount', 'Bottles charged'),
  ('driver.stock_charge',  1, 'debit',  'driver_cash',          'amount', 'Owed by driver'),
  ('driver.stock_charge',  2, 'credit', 'inv_finished',         'amount', 'Stock charged'),
  ('stock.opening',        1, 'debit',  'inv_finished',         'value',  'Opening stock'),
  ('stock.opening',        2, 'credit', 'opening_equity',       'value',  'Opening balance'),
  ('stock.adjust_gain',    1, 'debit',  'inv_finished',         'value',  'Stock gain'),
  ('stock.adjust_gain',    2, 'credit', 'inventory_adjustment', 'value',  'Stock gain'),
  ('stock.adjust_loss',    1, 'debit',  'inventory_adjustment', 'value',  'Stock loss'),
  ('stock.adjust_loss',    2, 'credit', 'inv_finished',         'value',  'Stock loss');

-- Settings ------------------------------------------------------------------------
insert into public.setting_definitions (key, module, label, description, value_type, choices, sort_order) values
  ('bottles.external_policy_default', 'Bottles', 'Other companies'' bottles (default)',
   'What happens when a customer hands in another company''s empty bottle. Can be overridden per company and per customer.',
   'choice', array['accept_one_for_one','accept_with_charge','accept_no_credit','refuse'], 19),
  ('deliveries.require_confirmation', 'Deliveries', 'Delivery confirmation required',
   'Driver must capture a signature, OTP or photo before completing a delivery', 'boolean', null, 60);
insert into public.system_settings (key, value, effective_from) values
  ('bottles.external_policy_default', '"accept_one_for_one"', date '2026-01-01'),
  ('deliveries.require_confirmation', 'false', date '2026-01-01');

-- Tax codes (rates are set by management) ------------------------------------------
insert into public.tax_codes (code, name) values ('VAT', 'Value Added Tax'), ('NONE', 'No tax / exempt');
insert into public.tax_rates (tax_code, rate_percent, effective_from) values ('NONE', 0, date '2026-01-01');

-- Bottle owners (OLA + external companies matching the tag series from Phase 0) -------
insert into public.bottle_companies (code, name, is_own) values
  ('OLA',  'OLA Water',     true),
  ('AQUA', 'Aqua Water',    false),
  ('XYZ',  'XYZ Water',     false),
  ('ABC',  'ABC Water',     false),
  ('UNK',  'Unknown brand', false);

insert into public.bottle_types (code, name, size_litres) values ('19L', '19 litre', 19);

-- Price lists ---------------------------------------------------------------------------
insert into public.price_lists (code, name, prices_include_tax) values
  ('RETAIL',        'Retail',               true),
  ('DEALER',        'Dealer',               true),
  ('DISTRIBUTOR',   'Distributor',          true),
  ('CORPORATE',     'Corporate',            true),
  ('SHOP_TRANSFER', 'Water shop transfer',  true);

-- Products (OLA's range; prices are entered in Products → Price lists) -----------------
insert into public.products (sku, name, size_label, unit, units_per_pack, is_returnable, bottle_type_id, tax_code, sort_order)
select v.sku, v.name, v.size_label, v.unit, v.per_pack, v.returnable, case when v.returnable then (select id from public.bottle_types where code = '19L') end, 'VAT', v.sort
  from (values
    ('OLA-19L',      'OLA 19L',               '19 L',   'bottle', 1,  true,  1),
    ('OLA-5L',       'OLA 5L',                '5 L',    'bottle', 1,  false, 2),
    ('OLA-1.5L',     'OLA 1.5L',              '1.5 L',  'bottle', 1,  false, 3),
    ('OLA-500ML',    'OLA 500ml',             '500 ml', 'bottle', 1,  false, 4),
    ('OLA-1.5L-12',  'OLA 1.5L — case of 12', '1.5 L',  'case',   12, false, 5),
    ('OLA-500ML-24', 'OLA 500ml — case of 24','500 ml', 'case',   24, false, 6)
  ) as v(sku, name, size_label, unit, per_pack, returnable, sort);

-- Customer type defaults (households pay a deposit; businesses borrow up to a limit) -----
insert into public.customer_type_defaults (customer_type, label, bottle_model, allowed_bottles, price_list_id, payment_terms_days)
select v.t, v.label, v.model, v.allowed, (select id from public.price_lists where code = v.pl), v.terms
  from (values
    ('household',   'Household',   'deposit', 0,  'RETAIL',        0),
    ('office',      'Office',      'loan',    10, 'CORPORATE',     30),
    ('hotel',       'Hotel',       'loan',    20, 'CORPORATE',     30),
    ('restaurant',  'Restaurant',  'loan',    10, 'CORPORATE',     14),
    ('shop',        'Shop',        'loan',    10, 'DEALER',        14),
    ('supermarket', 'Supermarket', 'loan',    20, 'DEALER',        30),
    ('institution', 'Institution', 'loan',    20, 'CORPORATE',     30),
    ('distributor', 'Distributor', 'loan',    50, 'DISTRIBUTOR',   30),
    ('water_shop',  'Water shop',  'loan',    50, 'SHOP_TRANSFER', 7),
    ('corporate',   'Corporate',   'loan',    20, 'CORPORATE',     30)
  ) as v(t, label, model, allowed, pl, terms);

-- Extra permission for the driver role so it can read its own receipts (RPC-checked) ---
-- (drivers use RPCs only; no table permissions are needed)

-- ---------------------------------------------------------------------------------------
-- Function privileges (re-applied after every migration that adds functions)
-- PostgreSQL grants EXECUTE to PUBLIC on new functions by default; remove that
-- globally and grant signed-in users explicitly.
-- ---------------------------------------------------------------------------------------
alter default privileges revoke execute on functions from public;
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app    from public, anon, authenticated;
grant execute on all functions in schema public to authenticated, service_role;
grant execute on function app.current_user_id()   to authenticated, service_role;
grant execute on function app.has_permission(text) to authenticated, service_role;
grant execute on function app.is_super_admin(uuid) to authenticated, service_role;
grant execute on function app.today()              to authenticated, service_role;
grant execute on function app.own_company_id()     to authenticated, service_role;
revoke execute on function public.log_failed_login(text, text, text, text) from authenticated;
revoke execute on function public.bootstrap_super_admin(text)              from authenticated;

grant usage on schema public to anon, authenticated, service_role;
grant select on all tables in schema public to authenticated, service_role;
grant usage, select on all sequences in schema public to service_role;
revoke all on all tables in schema public from anon;
