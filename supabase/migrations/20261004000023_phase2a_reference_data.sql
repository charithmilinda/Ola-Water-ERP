-- =====================================================================
-- OLA Water ERP — Phase 2A
-- 0023: accounts, posting rules, document numbers, settings, roles, grants
-- =====================================================================

insert into public.accounts (code, name, account_type, system_key, parent_id)
select v.code, v.name, v.type, v.key, (select id from public.accounts where code = v.parent)
  from (values
    ('2110', 'Goods Received Not Invoiced',        'liability', 'grni',            '2000'),
    ('5150', 'Production Losses & QC Write-offs',  'expense',   'production_loss', '5000'),
    ('5200', 'Purchase Price Variance',            'expense',   'ppv',             '5000')
  ) as v(code, name, type, key, parent);

insert into public.posting_event_types (code, module, description, amount_keys) values
  ('production.complete',  'production',  'Materials used by a finished production batch',     array['value']),
  ('production.loss',      'production',  'Materials used by a batch with no good output',     array['value']),
  ('stock.qc_writeoff',    'production',  'Failed or recalled stock destroyed',                array['value']),
  ('material.opening',     'inventory',   'Opening materials at go-live',                      array['value']),
  ('material.adjust_gain', 'inventory',   'Materials count gain',                              array['value']),
  ('material.adjust_loss', 'inventory',   'Materials count loss',                              array['value']),
  ('purchase.receipt',     'procurement', 'Goods received from a supplier',                    array['raw','finished','total']),
  ('purchase.invoice',     'procurement', 'Supplier invoice approved (3-way matched)',          array['grni','ppv_dr','ppv_cr','vat','total']),
  ('supplier.payment',     'procurement', 'Payment to a supplier',                             array['amount','bank','cash']);

insert into public.posting_rules (event_type, line_no, side, account_key, amount_key, description) values
  ('production.complete',  1, 'debit',  'inv_finished',         'value',    'Finished goods produced'),
  ('production.complete',  2, 'credit', 'inv_raw',              'value',    'Materials used'),
  ('production.loss',      1, 'debit',  'production_loss',      'value',    'Production loss'),
  ('production.loss',      2, 'credit', 'inv_raw',              'value',    'Materials used'),
  ('stock.qc_writeoff',    1, 'debit',  'production_loss',      'value',    'QC / recall write-off'),
  ('stock.qc_writeoff',    2, 'credit', 'inv_finished',         'value',    'Finished goods destroyed'),
  ('material.opening',     1, 'debit',  'inv_raw',              'value',    'Opening materials'),
  ('material.opening',     2, 'credit', 'opening_equity',       'value',    'Opening balance'),
  ('material.adjust_gain', 1, 'debit',  'inv_raw',              'value',    'Materials gain'),
  ('material.adjust_gain', 2, 'credit', 'inventory_adjustment', 'value',    'Materials gain'),
  ('material.adjust_loss', 1, 'debit',  'inventory_adjustment', 'value',    'Materials loss'),
  ('material.adjust_loss', 2, 'credit', 'inv_raw',              'value',    'Materials loss'),
  ('purchase.receipt',     1, 'debit',  'inv_raw',              'raw',      'Materials received'),
  ('purchase.receipt',     2, 'debit',  'inv_finished',         'finished', 'Goods for resale received'),
  ('purchase.receipt',     3, 'credit', 'grni',                 'total',    'Received, not yet invoiced'),
  ('purchase.invoice',     1, 'debit',  'grni',                 'grni',     'Received goods invoiced'),
  ('purchase.invoice',     2, 'debit',  'ppv',                  'ppv_dr',   'Price above order'),
  ('purchase.invoice',     3, 'credit', 'ppv',                  'ppv_cr',   'Price below order'),
  ('purchase.invoice',     4, 'debit',  'vat_input',            'vat',      'VAT input'),
  ('purchase.invoice',     5, 'credit', 'ap',                   'total',    'Owed to supplier'),
  ('supplier.payment',     1, 'debit',  'ap',                   'amount',   'Supplier paid'),
  ('supplier.payment',     2, 'credit', 'bank',                 'bank',     'Paid from bank'),
  ('supplier.payment',     3, 'credit', 'cash',                 'cash',     'Paid in cash');

insert into public.document_types (code, name, padding) values
  ('BAT', 'Production batch', 6),
  ('QCT', 'QC test', 6),
  ('RCL', 'Batch recall', 6),
  ('PR',  'Purchase request', 6),
  ('PO',  'Purchase order', 6),
  ('GRN', 'Goods received note', 6),
  ('SIN', 'Supplier invoice', 6),
  ('SPY', 'Supplier payment', 6);

insert into public.setting_definitions (key, module, label, description, value_type, choices, min_value, max_value, sort_order) values
  ('production.allow_manual_receipt', 'Production', 'Allow water into stock without a batch',
   'Off = filled water only enters stock through a production batch and QC. Turn on only for a short changeover period.',
   'boolean', null, null, null, 70),
  ('production.expiry_alert_days', 'Production', 'Expiry warning (days)',
   'Warn when stock of a batch expires within this many days', 'integer', null, 1, 365, 71),
  ('procurement.price_tolerance_percent', 'Procurement', 'Invoice price tolerance (%)',
   'Supplier invoice prices within this percentage of the order price match automatically', 'percent', null, 0, 50, 72);
insert into public.system_settings (key, value, effective_from) values
  ('production.allow_manual_receipt',      'false', date '2026-01-01'),
  ('production.expiry_alert_days',         '30',    date '2026-01-01'),
  ('procurement.price_tolerance_percent',  '2',     date '2026-01-01');

-- Roles: the people who run each step get what they need
insert into public.role_permissions (role_id, permission_code)
select r.id, x.code
  from public.roles r
  join (values
    ('warehouse_manager',   array['procurement.view']),
    ('production_manager',  array['qc.view','products.manage']),
    ('quality_officer',     array['inventory.view','products.view','bottles.view']),
    ('accountant',          array['procurement.view']),
    ('procurement_officer', array['inventory.manage','payments.view'])
  ) as m(role_code, perms) on m.role_code = r.code
  cross join lateral unnest(m.perms) as x(code)
 where not exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_code = x.code);

-- ---------------------------------------------------------------------
-- Tills only offer finished products (materials are never sold)
-- ---------------------------------------------------------------------
create or replace function public.pos_find_customer(p_location uuid, p_search text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; s public.water_shops; v_digits text := regexp_replace(regexp_replace(coalesce(p_search, ''), '[^0-9]', '', 'g'), '^0', '');
begin
  perform app.require_pos(p_location);
  s := app.shop_by_location(p_location);
  if length(trim(coalesce(p_search, ''))) < 2 then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(x), '[]') into v from (
    select jsonb_build_object('id', c.id, 'customer_no', c.customer_no, 'name', c.name, 'phone', c.phone,
             'bottle_model', c.bottle_model, 'allowed_bottles', c.allowed_bottles, 'credit_limit', c.credit_limit,
             'outstanding', app.customer_outstanding(c.id), 'ola_bottles', app.customer_ola_bottles(c.id),
             'external_policy', c.external_policy, 'status', c.status,
             'deposits_held', (select coalesce(jsonb_object_agg(bottle_type_id, qty_held), '{}') from public.customer_deposit_balances
                                where customer_id = c.id),
             'prices', case when s.operating_model = 'dealer' then null else
                (select coalesce(jsonb_object_agg(p.id, app.unit_price(p.id, c.price_list_id)), '{}') from public.products p
                  where p.is_active and p.item_type = 'finished_good' and exists (select 1 from public.price_list_items i where i.product_id = p.id
                        and i.price_list_id = c.price_list_id and i.effective_from <= app.today())) end) as x
      from public.customers c
     where not c.is_walk_in and c.status <> 'inactive'
       and (c.name ilike '%' || trim(p_search) || '%' or c.customer_no ilike '%' || trim(p_search) || '%'
            or (length(v_digits) >= 4 and c.phone like '%' || v_digits || '%'))
     order by c.name limit 10) q;
  return v;
end $$;

create or replace function public.pos_bootstrap(p_location uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare l public.locations; s public.water_shops; v_list uuid; v_walk uuid; v jsonb; v_own uuid := app.own_company_id();
begin
  perform app.require_pos(p_location);
  select * into l from public.locations where id = p_location;
  s := app.shop_by_location(p_location);
  v_list := coalesce(s.retail_price_list_id, (select id from public.price_lists where code = 'RETAIL'));
  v_walk := coalesce(s.walk_in_customer_id, (select c.id from public.customers c where c.is_walk_in and c.notes = 'counter:' || p_location::text));
  select jsonb_build_object(
    'location', jsonb_build_object('id', l.id, 'code', l.code, 'name', l.name, 'type', l.location_type),
    'shop', case when s.id is null then null else jsonb_build_object('id', s.id, 'name', s.name, 'operating_model', s.operating_model,
                                                                     'phone', s.phone, 'address', s.address) end,
    'is_dealer', coalesce(s.operating_model = 'dealer', false),
    'walk_in_customer_id', v_walk,
    'walk_in_deposits', case when v_walk is null then '{}'::jsonb else
        (select coalesce(jsonb_object_agg(bottle_type_id, qty_held), '{}') from public.customer_deposit_balances where customer_id = v_walk) end,
    'walk_in_bottles', case when v_walk is null then 0 else app.customer_ola_bottles(v_walk) end,
    'includes_tax', (select prices_include_tax from public.price_lists where id = v_list),
    'company', jsonb_build_object('name', app.get_setting('company.name') #>> '{}', 'vat_no', app.get_setting('company.vat_registration_no') #>> '{}',
                                  'footer', app.get_setting('receipts.footer_text') #>> '{}'),
    'own_company_id', v_own,
    'companies', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'name', name, 'is_own', is_own, 'policy', acceptance_policy)
                    order by is_own desc, name), '[]') from public.bottle_companies where is_active),
    'bottle_types', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'name', name) order by size_litres desc), '[]')
                       from public.bottle_types where is_active),
    'products', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'sku', p.sku, 'name', p.name, 'barcode', p.barcode,
                    'is_returnable', p.is_returnable, 'bottle_type_id', p.bottle_type_id,
                    'price', (select unit_price from public.price_list_items i where i.product_id = p.id and i.price_list_id = v_list
                               and i.effective_from <= app.today() order by effective_from desc limit 1),
                    'tax_rate', (select rate_percent from public.tax_rates t where t.tax_code = p.tax_code and t.effective_from <= app.today()
                                  order by effective_from desc limit 1),
                    'stock', coalesce((select qty from public.inventory_balances b where b.location_id = p_location and b.product_id = p.id
                                        and b.stock_status = 'available'), 0)) order by p.sort_order, p.name), '[]')
                   from public.products p where p.is_active and p.item_type = 'finished_good'),
    'bottle_values', (select coalesce(jsonb_agg(jsonb_build_object('bottle_type_id', bt.id, 'company_id', bc.id,
                        'deposit', coalesce((app.bottle_value(bt.id, bc.id)).deposit_amount, 0),
                        'external_charge', coalesce((app.bottle_value(bt.id, bc.id)).external_charge, 0))), '[]')
                        from public.bottle_types bt cross join public.bottle_companies bc where bt.is_active and bc.is_active),
    'bottles_here', (select coalesce(jsonb_agg(jsonb_build_object('company_id', company_id, 'bottle_type_id', bottle_type_id,
                        'fill_state', fill_state, 'qty', qty)), '[]')
                        from public.bottle_balances where holder_type = 'location' and holder_id = p_location and qty <> 0),
    'settings', jsonb_build_object(
        'external_policy_default', app.get_setting('bottles.external_policy_default') #>> '{}',
        'discount_percent', coalesce((app.get_setting('approvals.discount_percent') #>> '{}')::numeric, 0),
        'can_discount', app.has_permission_at('pos.discount', p_location)),
    'session', (select jsonb_build_object('id', id, 'session_no', session_no, 'receipt_prefix', receipt_prefix, 'opening_float', opening_float,
                  'opened_at', opened_at, 'opened_by', (select full_name from public.profiles where id = opened_by),
                  'next_seq', (select count(*) + 1 from public.pos_sales ps where ps.session_id = s2.id),
                  'cash_in', (select coalesce(sum(cash_in - cash_out), 0) from public.pos_sales ps where ps.session_id = s2.id),
                  'card_in', (select coalesce(sum(card_in), 0) from public.pos_sales ps where ps.session_id = s2.id),
                  'sales', (select count(*) from public.pos_sales ps where ps.session_id = s2.id))
                  from public.pos_sessions s2 where s2.location_id = p_location and s2.status = 'open'),
    'fetched_at', now()
  ) into v;
  return v;
end $$;

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
