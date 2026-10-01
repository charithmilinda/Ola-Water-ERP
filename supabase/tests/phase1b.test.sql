-- =====================================================================
-- Phase 1B database tests — acceptance scenario 4 (water shop), dealer
-- shops, head-office counter, shop isolation and offline replay.
-- Runs after phase0 and phase1a tests in the same database.
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = notice;

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000f1', 'shop1@ola.test', '{"full_name":"Malini Rajapaksha"}'),
  ('00000000-0000-0000-0000-0000000000f2', 'shop2@ola.test', '{"full_name":"Tharindu Silva"}');

-- ---------------------------------------------------------------------
-- Set-up: transfer prices, two shops, staff limited to their shop
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.set_prices((select id from public.price_lists where code = 'SHOP_TRANSFER'), jsonb_build_array(
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'unit_price', 380),
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-5L'), 'unit_price', 200)), app.today(), 'Transfer prices');
select public.save_water_shop(null, '{"code":"SHOP01","name":"OLA Water Point Nugegoda","operating_model":"company_owned",
  "phone":"0112812345","address":"112 High Level Road","city":"Nugegoda"}', 'New shop') as shop1 \gset
select public.save_water_shop(null, '{"code":"SHOP02","name":"Kandy Pure Water","operating_model":"dealer","owner_name":"S. Bandara",
  "phone":"0812234567","address":"21 Peradeniya Road","city":"Kandy","credit_limit":50000,"payment_terms_days":14}', 'New dealer') as shop2 \gset
select (select location_id from public.water_shops where id = :'shop1') as loc1 \gset
select (select location_id from public.water_shops where id = :'shop2') as loc2 \gset
select tests.throws($$select public.save_water_shop(null, '{"code":"x","name":"Bad"}', 'x')$$, 'shop code', 'shop codes are validated');
select public.admin_assign_role('00000000-0000-0000-0000-0000000000f1', (select id from public.roles where code = 'shop_manager'), :'loc1', 'Manager');
select public.admin_assign_role('00000000-0000-0000-0000-0000000000f2', (select id from public.roles where code = 'shop_cashier'), :'loc2', 'Cashier');
reset role;
select tests.ok((select operating_model = 'dealer' and account_customer_id is not null from public.water_shops where id = :'shop2'),
                'dealer shop gets its own customer account for OLA invoices');
select tests.ok((select is_walk_in from public.customers where id = (select walk_in_customer_id from public.water_shops where id = :'shop1')),
                'each shop gets a pooled walk-in account');

-- Location scoping
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f1', false);
set role authenticated;
select tests.ok(not app.has_permission('shop_pos.use') and app.has_permission_at('shop_pos.use', :'loc1') and not app.has_permission_at('shop_pos.use', :'loc2'),
                'a role limited to a shop only works at that shop');
select tests.ok((select count(*) = 0 from public.inventory_balances), 'shop manager cannot browse company-wide stock');
select tests.ok((select count(*) = 1 from public.shop_list()), 'shop manager sees only their own shop');
select tests.ok((public.get_my_access() -> 'scoped') @> '[{"permission":"shop_pos.use"}]'::jsonb, 'access lists shop-limited permissions');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f2', false);
set role authenticated;
select tests.throws(format($$select public.create_stock_request(%L, '[]', null, null, gen_random_uuid())$$, :'shop1'),
  'permission denied', 'a cashier cannot request stock for another shop');
select tests.throws(format($$select public.open_pos_session(%L, 0, gen_random_uuid())$$, :'loc1'), 'permission denied',
  'a cashier cannot open another shop''s till');
reset role;

-- ---------------------------------------------------------------------
-- Scenario 4: request → approve → dispatch → receive (one item short)
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);
set role authenticated;
select public.receive_stock((select id from public.locations where code = 'WH1'), jsonb_build_array(
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 30),
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-5L'), 'qty', 30)), 'opening', 'More stock', gen_random_uuid());
reset role;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f1', false);
set role authenticated;
select public.create_stock_request(:'shop1', jsonb_build_array(
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 20),
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-5L'), 'qty', 10)), null, 'Weekend stock', gen_random_uuid()) as req1 \gset
select tests.ok((:'req1'::jsonb ->> 'request_no') like 'SRQ-SHOP01-%', 'request numbered per shop');
select tests.throws(format($$select public.approve_stock_request(%L, null, null)$$, :'req1'::jsonb ->> 'request_id'), 'permission denied',
  'shops cannot approve their own requests');
reset role;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);
set role authenticated;
select public.approve_stock_request((:'req1'::jsonb ->> 'request_id')::uuid, null, 'OK');
select tests.throws(format($$select public.dispatch_stock_request(%L, jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 25)), gen_random_uuid())$$,
  :'req1'::jsonb ->> 'request_id'), 'more than approved', 'cannot dispatch more than approved');
select public.dispatch_stock_request((:'req1'::jsonb ->> 'request_id')::uuid, null, gen_random_uuid());
reset role;
select tests.ok((select qty = 20 from public.inventory_balances where location_id = app.transit_id()
                   and product_id = (select id from public.products where sku = 'OLA-19L')), 'dispatched stock is in transit');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f1', false);
set role authenticated;
select public.receive_stock_request((:'req1'::jsonb ->> 'request_id')::uuid, jsonb_build_array(
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 20),
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-5L'), 'qty', 9)), 'One 5L case missing', gen_random_uuid()) as rcv1 \gset
select tests.ok((:'rcv1'::jsonb ->> 'differences')::integer = 1 and (:'rcv1'::jsonb ->> 'invoice_id') is null,
                'company shop receipt: one difference, no invoice (still OLA''s stock)');
select tests.ok((select count(*) = 1 from public.operation_exceptions), 'shop manager sees the shortage on their shop');
reset role;
select tests.ok((select status = 'received_with_differences' from public.shop_stock_requests where id = (:'req1'::jsonb ->> 'request_id')::uuid),
                'request flagged as received with differences');
select tests.ok((select qty = 20 from public.bottle_balances where holder_type = 'location' and holder_id = :'loc1' and fill_state = 'full'),
                'full OLA bottles moved to the shop with the 19L stock');

-- ---------------------------------------------------------------------
-- Shop till: walk-in sales with bottles, deposits, refunds, offline replay
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f1', false);
set role authenticated;
select public.open_pos_session(:'loc1', 1000, gen_random_uuid()) as sess1 \gset
select tests.throws(format($$select public.open_pos_session(%L, 0, gen_random_uuid())$$, :'loc1'), 'already open', 'one till open per shop');
select tests.ok((public.pos_bootstrap(:'loc1') -> 'session' ->> 'next_seq')::integer = 1, 'till data for the device includes the open session');

-- Sale 1: 2 × 19L, one OLA empty and one XYZ bottle back, cash 2,000 tendered
select public.pos_sale((:'sess1'::jsonb ->> 'session_id')::uuid, jsonb_build_object('seq', 1,
  'lines', jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 2)),
  'ola_returned_counts', jsonb_build_array(jsonb_build_object('qty', 1)),
  'external', jsonb_build_array(jsonb_build_object('company_id', (select id from public.bottle_companies where code = 'XYZ'), 'qty', 1)),
  'payments', jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', 2000)), 'tendered', 2000),
  '33333333-3333-3333-3333-333333333333') as s1 \gset
select tests.ok((:'s1'::jsonb ->> 'total')::numeric = 1000 and (:'s1'::jsonb ->> 'change')::numeric = 1000,
                'swap sale: Rs. 1,000, no deposit, Rs. 1,000 change');
select tests.ok((:'s1'::jsonb ->> 'receipt_no') like 'RSHOP01-%-0001', 'receipt numbered by till session');
-- Sale 2: 1 × 19L, no bottle back → deposit, paid by card
select public.pos_sale((:'sess1'::jsonb ->> 'session_id')::uuid, jsonb_build_object('seq', 2,
  'lines', jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 1)),
  'payments', jsonb_build_array(jsonb_build_object('method', 'card', 'amount', 1500))), gen_random_uuid()) as s2 \gset
select tests.ok((:'s2'::jsonb ->> 'total')::numeric = 1500, 'no empty returned: Rs. 500 water + Rs. 1,000 deposit');
-- Sale 3: walk-in brings one bottle back, buys nothing → deposit refunded in cash
select public.pos_sale((:'sess1'::jsonb ->> 'session_id')::uuid, jsonb_build_object('seq', 3,
  'ola_returned_counts', jsonb_build_array(jsonb_build_object('qty', 1))), gen_random_uuid()) as s3 \gset
select tests.ok((:'s3'::jsonb ->> 'total')::numeric = -1000, 'returned bottle: Rs. 1,000 deposit paid back');
-- Sale 4: more 5L than recorded (9) — accepted and flagged
select public.pos_sale((:'sess1'::jsonb ->> 'session_id')::uuid, jsonb_build_object('seq', 4, 'sold_at', now() - interval '5 minutes',
  'lines', jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-5L'), 'qty', 10)),
  'payments', jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', 2500))), gen_random_uuid()) as s4 \gset
-- Offline replay of sale 1
select public.pos_sale((:'sess1'::jsonb ->> 'session_id')::uuid, '{}', '33333333-3333-3333-3333-333333333333') as s1b \gset
reset role;
select tests.ok((:'s1b'::jsonb ->> 'receipt_no') = (:'s1'::jsonb ->> 'receipt_no') and (select count(*) = 4 from public.pos_sales),
                'a re-sent sale is not duplicated');
select tests.ok((select count(*) = 1 from public.operation_exceptions where exception_type = 'negative_balance' and location_id = :'loc1'),
                'selling more than recorded stock is accepted and flagged');
select tests.ok((select bool_and(posted) and count(invoice_id) = 4 from public.pos_sales where location_id = :'loc1'),
                'company shop sales are OLA invoices');
select tests.ok((select qty = 2 from public.bottle_balances where holder_type = 'location' and holder_id = :'loc1'
                   and company_id = app.own_company_id() and fill_state = 'empty'), 'two OLA empties now at the shop');
select tests.ok((select qty = 1 from public.bottle_balances where holder_type = 'location' and holder_id = :'loc1'
                   and company_id = (select id from public.bottle_companies where code = 'XYZ')), 'XYZ bottle held at the shop');

-- Daily closing: Rs. 100 short in the drawer, stock and bottles match
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f1', false);
set role authenticated;
select public.close_pos_session((:'sess1'::jsonb ->> 'session_id')::uuid, jsonb_build_object('cash_counted', 3400, 'card_counted', 1500,
  'products', jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 17),
                                jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-5L'), 'qty', 0)),
  'bottles', jsonb_build_array(
     jsonb_build_object('company_id', app.own_company_id(), 'bottle_type_id', (select id from public.bottle_types where code = '19L'), 'qty', 2),
     jsonb_build_object('company_id', (select id from public.bottle_companies where code = 'XYZ'), 'bottle_type_id', (select id from public.bottle_types where code = '19L'), 'qty', 1))),
  gen_random_uuid()) as close1 \gset
reset role;
select tests.ok((:'close1'::jsonb ->> 'cash_expected')::numeric = 3500 and (:'close1'::jsonb ->> 'exceptions')::integer = 1,
                'closing: Rs. 3,500 expected (1,000 float + 1,000 + 2,500 − 1,000 refund), only the cash differs');

-- Settlement: bank what was counted (Rs. 2,400 after keeping the float)
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
set role authenticated;
select tests.throws(format($$select public.create_shop_settlement(%L, app.today(), app.today(), '{"amount_received":2400}', gen_random_uuid())$$, :'shop1'),
  'deposit reference', 'banking needs a deposit reference');
select public.create_shop_settlement(:'shop1', app.today(), app.today(),
  '{"amount_received":2400,"method":"bank_transfer","reference":"BOC slip 5521"}', gen_random_uuid()) as set1 \gset
select tests.ok((:'set1'::jsonb ->> 'expected')::numeric = 2400, 'settlement expects the counted takings less the float');
select public.resolve_exception((select id from public.operation_exceptions where exception_type = 'cash_shortage' and location_id = :'loc1'),
  'write_off', 'Small change error', gen_random_uuid());
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select tests.ok((select coalesce(sum(balance), 0) = 0 from public.trial_balance(date '2026-01-01', date '2027-12-31') where account_code = '1130'),
                'shop cash clearing is back to zero once banked and the shortage written off');
select tests.ok((select balance < 0 from public.trial_balance(date '2026-01-01', date '2027-12-31') where account_code = '4110'),
                'shop sales are credited to Sales — Water Shops');
select public.resolve_exception((select id from public.operation_exceptions where exception_type = 'stock_shortage' and target_location_id = :'loc1'),
  'found', 'Case was on the lorry', gen_random_uuid());
reset role;
select tests.ok((select status = 'received' from public.shop_stock_requests where id = (:'req1'::jsonb ->> 'request_id')::uuid),
                'request completes when its difference is resolved');
select tests.ok((select qty = 1 from public.inventory_balances where location_id = :'loc1' and product_id = (select id from public.products where sku = 'OLA-5L')),
                'the found case reached the shop');

-- Bottles sent back from the shop to the warehouse
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);
set role authenticated;
select public.receive_shop_bottles(:'shop1', jsonb_build_array(
  jsonb_build_object('company_id', app.own_company_id(), 'bottle_type_id', (select id from public.bottle_types where code = '19L'), 'qty', 2),
  jsonb_build_object('company_id', (select id from public.bottle_companies where code = 'XYZ'), 'bottle_type_id', (select id from public.bottle_types where code = '19L'), 'qty', 1)),
  null, 'Lorry back from Nugegoda', gen_random_uuid()) as sbr \gset
reset role;
select tests.ok((:'sbr'::jsonb ->> 'bottles')::integer = 3
                and (select coalesce(sum(qty), 0) = 0 from public.bottle_balances where holder_type = 'location' and holder_id = :'loc1' and fill_state = 'empty'),
                'shop empties and XYZ bottle returned to the warehouse / external holding');

-- ---------------------------------------------------------------------
-- Dealer shop: stock is invoiced on arrival; the dealer's own sales post nothing
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f2', false);
set role authenticated;
select public.create_stock_request(:'shop2', jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 10)),
  null, null, gen_random_uuid()) as req2 \gset
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);
set role authenticated;
select public.approve_stock_request((:'req2'::jsonb ->> 'request_id')::uuid, null, null);
select public.dispatch_stock_request((:'req2'::jsonb ->> 'request_id')::uuid, null, gen_random_uuid());
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f2', false);
set role authenticated;
select public.receive_stock_request((:'req2'::jsonb ->> 'request_id')::uuid, jsonb_build_array(
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 10)), null, gen_random_uuid()) as rcv2 \gset
reset role;
select tests.ok((:'rcv2'::jsonb ->> 'invoice_no') is not null
                and (select total = 3800 from public.invoices where id = (:'rcv2'::jsonb ->> 'invoice_id')::uuid),
                'dealer invoiced Rs. 3,800 (10 × Rs. 380 transfer price) on receipt');
select (select count(*) from public.journal_entries) as je_before \gset
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f2', false);
set role authenticated;
select public.open_pos_session(:'loc2', 0, gen_random_uuid()) as sess2 \gset
select public.pos_sale((:'sess2'::jsonb ->> 'session_id')::uuid, jsonb_build_object('seq', 1,
  'lines', jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 1)),
  'ola_returned_counts', jsonb_build_array(jsonb_build_object('qty', 1)),
  'payments', jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', 500))), gen_random_uuid()) as d1 \gset
select tests.ok((public.get_pos_receipt((:'d1'::jsonb ->> 'sale_id')::uuid) -> 'company' ->> 'name') = 'Kandy Pure Water',
                'dealer receipts carry the dealer''s name');
reset role;
select tests.ok((select count(*) from public.journal_entries) = :je_before and (:'d1'::jsonb ->> 'invoice_id') is null,
                'dealer counter sale creates no OLA invoice or journal');
select tests.ok((select qty = 9 from public.inventory_balances where location_id = :'loc2' and product_id = (select id from public.products where sku = 'OLA-19L')),
                'dealer stock is still tracked');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
set role authenticated;
select public.create_shop_settlement(:'shop2', app.today(), app.today(),
  '{"amount_received":3000,"method":"bank_transfer","reference":"HNB 7781"}', gen_random_uuid()) as set2 \gset
reset role;
select tests.ok((select (figures ->> 'outstanding_after')::numeric = 800 from public.shop_settlements where id = (:'set2'::jsonb ->> 'settlement_id')::uuid),
                'dealer settlement records the payment: Rs. 800 still owed');

-- ---------------------------------------------------------------------
-- Head-office counter (no shop)
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.open_pos_session((select id from public.locations where code = 'WH1'), 500, gen_random_uuid()) as sess3 \gset
select public.pos_sale((:'sess3'::jsonb ->> 'session_id')::uuid, jsonb_build_object('seq', 1, 'customer_id', (select id from public.customers where phone = '+94112501234'),
  'lines', jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 2)),
  'payments', '[]'::jsonb), gen_random_uuid()) as h1 \gset
select tests.ok((:'h1'::jsonb ->> 'total')::numeric = 900 and (:'h1'::jsonb -> 'flags') = '[]'::jsonb,
                'registered credit customer buys at the counter on account at their own prices');
select tests.ok((select count(*) = 1 from jsonb_array_elements(public.my_pos_locations()) x where x ->> 'code' = 'WH1' and (x ->> 'till_open')::boolean),
                'counter appears as an open till');
select tests.ok((select sum(balance) = 0 from public.trial_balance(date '2026-01-01', date '2027-12-31')), 'ledger balances after all Phase 1B flows');
select tests.ok((public.shop_statement(:'shop2', app.today(), app.today()) ->> 'opening_balance')::numeric = 0
                and jsonb_array_length(public.shop_statement(:'shop2', app.today(), app.today()) -> 'invoices') = 1, 'dealer statement lists the period''s invoices');
select tests.ok((public.shop_dashboard(:'shop1') -> 'today' ->> 'sales_count')::integer = 4, 'shop dashboard shows today''s sales');
select tests.ok((public.dashboard_summary() ->> 'shop_outstanding')::numeric = 800, 'main dashboard shows what dealers owe');
reset role;

do $$ begin raise notice 'ALL PHASE 1B DATABASE TESTS PASSED'; end $$;
