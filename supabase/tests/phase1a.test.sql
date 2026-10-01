-- =====================================================================
-- Phase 1A database tests (acceptance scenarios 1, 2, 3, 7, 8, 9)
-- Runs after phase0.test.sql in the same database.
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = notice;

-- Users: driver, warehouse manager, a second driver
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000d1', 'driver@ola.test',  '{"full_name":"Sunil Jayasinghe"}'),
  ('00000000-0000-0000-0000-0000000000d2', 'driver2@ola.test', '{"full_name":"Ruwan Bandara"}'),
  ('00000000-0000-0000-0000-0000000000e1', 'wh@ola.test',      '{"full_name":"Chathura Wickrama"}');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.admin_assign_role('00000000-0000-0000-0000-0000000000d1', (select id from public.roles where code = 'driver'), null, 'Driver');
select public.admin_assign_role('00000000-0000-0000-0000-0000000000d2', (select id from public.roles where code = 'driver'), null, 'Driver');
select public.admin_assign_role('00000000-0000-0000-0000-0000000000e1', (select id from public.roles where code = 'warehouse_manager'), null, 'WH');

-- ---------------------------------------------------------------------
-- Configuration: VAT, prices, bottle values
-- ---------------------------------------------------------------------
select tests.throws($$select public.save_order(null, jsonb_build_object('customer_id', gen_random_uuid(), 'items', '[]'::jsonb), false, gen_random_uuid())$$,
  'choose a customer', 'order needs a customer');

select public.set_tax_rate('VAT', 18, app.today(), 'VAT 18%');
select public.set_prices((select id from public.price_lists where code = 'RETAIL'),
  jsonb_build_array(
    jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'unit_price', 500),
    jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-5L'),  'unit_price', 250)),
  app.today(), 'Launch prices');
select public.set_prices((select id from public.price_lists where code = 'CORPORATE'),
  jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'unit_price', 450)),
  app.today(), 'Launch prices');
select public.set_bottle_value((select id from public.bottle_types where code = '19L'), app.own_company_id(), 1000, 1500, 0, app.today(), 'Deposit');
select public.set_bottle_value((select id from public.bottle_types where code = '19L'),
  (select id from public.bottle_companies where code = 'XYZ'), 0, 800, 200, app.today(), 'XYZ value');
reset role;
select tests.ok(app.unit_price((select id from public.products where sku = 'OLA-19L'), (select id from public.price_lists where code = 'RETAIL')) = 500,
                'prices are effective-dated per price list');
set role authenticated;
select tests.throws($$select public.set_prices((select id from public.price_lists where code = 'RETAIL'), '[]', app.today() - 1, 'x')$$,
  'back-dated', 'prices cannot be back-dated');

-- Vehicle, route, customers
select public.save_vehicle(null, '{"registration_no":"WP LB-4521","name":"Lorry 1","capacity_19l":200}', 'New lorry') as veh \gset
select public.save_route(null, jsonb_build_object('code','COL-03','name','Colombo 03 / 04','default_vehicle_id', :'veh'), 'New route') as route \gset
select public.save_customer(null, jsonb_build_object(
  'name','Nadeesha Perera','customer_type','household','phone','077 123 4567','route_id', :'route', 'route_sequence', 1,
  'address', jsonb_build_object('address_line','12/3 Galle Road','city','Colombo 03')), 'New customer') as cust_h \gset
select public.save_customer(null, jsonb_build_object(
  'name','Lanka Tech (Pvt) Ltd','customer_type','office','phone','011 250 1234','route_id', :'route', 'route_sequence', 2,
  'credit_limit', 50000, 'address', jsonb_build_object('address_line','45 Duplication Road','city','Colombo 04')), 'New customer') as cust_o \gset
select tests.ok((select bottle_model = 'deposit' and phone = '+94771234567' from public.customers where id = :'cust_h'),
                'household defaults to the deposit model and phone is normalised');
select tests.ok((select bottle_model = 'loan' and allowed_bottles = 10 and price_list_id = (select id from public.price_lists where code = 'CORPORATE')
                   from public.customers where id = :'cust_o'), 'office defaults to loan model, limit 10, corporate prices');
select tests.throws($$select public.save_customer(null, '{"name":"Dup","customer_type":"household","phone":"0771234567"}', 'x')$$,
  'already exists', 'duplicate phone numbers are rejected');
reset role;

-- A user without customers.credit cannot give credit
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);
set role authenticated;
select tests.throws($$select public.save_customer(null, '{"name":"X","customer_type":"shop","phone":"0712223334","credit_limit":1000}', 'x')$$,
  'permission denied', 'warehouse manager cannot create customers');
reset role;

-- ---------------------------------------------------------------------
-- Opening stock and bottles (go-live), labelled bottles
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.set_opening_bottles('location', (select id from public.locations where code = 'WH1'), app.own_company_id(),
  (select id from public.bottle_types where code = '19L'), 'empty', 30, 'Go-live count', gen_random_uuid());
select public.register_bottles(array['OLA-BTL-00000001','OLA-BTL-00000002','OLA-BTL-00000003'],
  (select id from public.bottle_types where code = '19L'), (select id from public.locations where code = 'WH1'), 'empty', 'Labelled', gen_random_uuid());
select tests.throws($$select public.register_bottles(array['OLA-BTL-00000001'], (select id from public.bottle_types where code = '19L'),
  (select id from public.locations where code = 'WH1'), 'empty', 'again', gen_random_uuid())$$, 'already on another bottle', 'a label cannot be applied twice');
reset role;
update public.products set cost_price = 120 where sku = 'OLA-19L';
update public.products set cost_price = 60 where sku = 'OLA-5L';
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);
set role authenticated;
select public.receive_stock((select id from public.locations where code = 'WH1'),
  jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 20)),
  'receipt', 'Filled today', gen_random_uuid());
select public.receive_stock((select id from public.locations where code = 'WH1'),
  jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-5L'), 'qty', 50)),
  'opening', 'Go-live stock', gen_random_uuid());
reset role;
select tests.ok((select qty = 20 from public.inventory_balances where product_id = (select id from public.products where sku = 'OLA-19L')
                   and location_id = (select id from public.locations where code = 'WH1')), 'stock receipt adds stock');
select tests.ok((select qty = 10 from public.bottle_balances where holder_type = 'location' and holder_id = (select id from public.locations where code = 'WH1')
                   and fill_state = 'empty'), 'filling 20 bottles uses 20 empties (30 - 20 = 10 left)');

-- Customer already holds 2 OLA bottles at go-live
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.set_opening_bottles('customer', :'cust_h', app.own_company_id(), (select id from public.bottle_types where code = '19L'),
  'full', 2, 'Bottles held before go-live', gen_random_uuid());
-- the labelled bottle 0001 is actually at this customer (moved before scanning existed)

-- ---------------------------------------------------------------------
-- Scenario 1: orders
-- ---------------------------------------------------------------------
select public.save_order(null, jsonb_build_object('customer_id', :'cust_h', 'expected_ola_returns', 2, 'items', jsonb_build_array(
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 2),
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-5L'), 'qty', 2))), true, gen_random_uuid()) as ord_h \gset
select tests.ok((:'ord_h'::jsonb ->> 'status') = 'confirmed' and (:'ord_h'::jsonb ->> 'total')::numeric = 1500, 'household order confirmed, total Rs. 1,500');
select public.save_order(null, jsonb_build_object('customer_id', :'cust_o', 'expected_ola_returns', 0, 'items', jsonb_build_array(
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 12))), true, gen_random_uuid()) as ord_big \gset
select tests.ok((:'ord_big'::jsonb ->> 'status') = 'on_hold' and (:'ord_big'::jsonb ->> 'hold_reason') like '%Bottle limit%',
                'order breaching the bottle limit goes on hold');
select public.save_order((:'ord_big'::jsonb ->> 'order_id')::uuid, jsonb_build_object('customer_id', :'cust_o', 'expected_ola_returns', 3,
  'items', jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 5))), true, null) as ord_o \gset
select tests.ok((:'ord_o'::jsonb ->> 'status') = 'confirmed' and (:'ord_o'::jsonb ->> 'total')::numeric = 2250, 'edited order confirmed at corporate price');
reset role;
-- Scenario 7: the edit is audited with before/after
select tests.ok(exists (select 1 from public.audit_logs where record_type = 'orders' and record_id = :'ord_o'::jsonb ->> 'order_id'
                    and action = 'edit' and 'total' = any(changed_fields) and (old_values ->> 'total')::numeric = 5400
                    and (new_values ->> 'total')::numeric = 2250),
                'order edit records total before (5,400) and after');

-- ---------------------------------------------------------------------
-- Dispatch, load-out, start
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.create_route_run(app.today(), :'route', :'veh', '00000000-0000-0000-0000-0000000000d1',
  array[(:'ord_h'::jsonb ->> 'order_id')::uuid, (:'ord_o'::jsonb ->> 'order_id')::uuid], null, null, gen_random_uuid()) as run \gset
select tests.ok((:'run'::jsonb ->> 'stops')::integer = 2, 'run created with two stops in route order');
select tests.throws(format($$select public.create_route_run(app.today(), null, %L, '00000000-0000-0000-0000-0000000000d2', array[]::uuid[], null, null, gen_random_uuid())$$, :'veh'),
  'already has an open run', 'a vehicle can only have one open run');
reset role;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);
set role authenticated;
select tests.throws(format($$select public.load_route_run(%L, jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 50)), 0, gen_random_uuid())$$,
  :'run'::jsonb ->> 'run_id'), 'not enough stock', 'cannot load more than the warehouse holds');
select public.load_route_run((:'run'::jsonb ->> 'run_id')::uuid, jsonb_build_array(
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 8),
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-5L'), 'qty', 2)), 1000, gen_random_uuid());
reset role;

-- The other driver cannot touch this run
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d2', false);
set role authenticated;
select tests.throws(format($$select public.driver_get_run(%L)$$, :'run'::jsonb ->> 'run_id'), 'another driver', 'drivers only see their own runs');
reset role;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', false);
set role authenticated;
select public.driver_start_run((:'run'::jsonb ->> 'run_id')::uuid);
select public.driver_get_run((:'run'::jsonb ->> 'run_id')::uuid) as runjson \gset
select tests.ok(jsonb_array_length(:'runjson'::jsonb -> 'stops') = 2
                and (:'runjson'::jsonb -> 'stops' -> 0 -> 'customer' ->> 'ola_bottles')::integer = 2, 'driver app receives stops with bottle balances');
select tests.ok(jsonb_array_length(public.driver_my_runs()) = 1, 'driver sees their run in the list');

-- ---------------------------------------------------------------------
-- Scenario 1 + 2 + 3: deliver to the household
--   2 x 19L + 2 x 5L, returns: 1 scanned OLA bottle + 1 counted, 1 XYZ bottle tagged now
-- ---------------------------------------------------------------------
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.generate_label_batch('EXT-XYZ', 5, 'qrcode', '40x30', null, gen_random_uuid()) as xyzlabels \gset
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', false);
set role authenticated;
select (select stop ->> 'delivery_id' from jsonb_array_elements(:'runjson'::jsonb -> 'stops') stop
         where stop -> 'customer' ->> 'id' = :'cust_h') as del_h \gset
select (select stop ->> 'delivery_id' from jsonb_array_elements(:'runjson'::jsonb -> 'stops') stop
         where stop -> 'customer' ->> 'id' = :'cust_o') as del_o \gset

select public.complete_delivery(:'del_h', jsonb_build_object(
  'lines', jsonb_build_array(
     jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 2),
     jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-5L'), 'qty', 2)),
  'ola_returned_codes', jsonb_build_array('ola-btl-00000001'),
  'ola_returned_counts', jsonb_build_array(jsonb_build_object('bottle_type_id', (select id from public.bottle_types where code = '19L'), 'qty', 1)),
  'external', jsonb_build_array(jsonb_build_object('company_id', (select id from public.bottle_companies where code = 'XYZ'),
                'bottle_type_id', (select id from public.bottle_types where code = '19L'), 'new_tag', :'xyzlabels'::jsonb ->> 'first')),
  'payment', jsonb_build_object('method', 'cash', 'amount', 2000, 'tendered', 2500),
  'confirmation', jsonb_build_object('method', 'signature', 'signature_data', 'data:image/png;base64,AAAA', 'recipient_name', 'Nadeesha'),
  'gps', jsonb_build_object('lat', 6.9022, 'lng', 79.8507)), '22222222-2222-2222-2222-222222222222') as rcpt \gset

reset role;
-- Expected: OLA bottles 2 (opening) + 2 issued - 2 returned - 1 replaced by XYZ = 1  -> deposit for 1 bottle
select tests.ok(app.customer_ola_bottles(:'cust_h') = 1, 'customer OLA bottle balance = 2 + 2 - 2 - 1 (XYZ one-for-one) = 1');
select tests.ok((:'rcpt'::jsonb ->> 'total')::numeric = 2500, 'invoice total = 1,000 (19L) + 500 (5L) + 1,000 deposit = Rs. 2,500');
select tests.ok((:'rcpt'::jsonb ->> 'change')::numeric = 500, 'change on Rs. 2,500 tendered = Rs. 500');
select tests.ok((:'rcpt'::jsonb ->> 'outstanding')::numeric = 500, 'Rs. 500 left outstanding');
select tests.ok((select tax_total = 228.81 and subtotal_net = 1271.19 from public.invoices where id = (:'rcpt'::jsonb ->> 'invoice_id')::uuid),
                'VAT 18% extracted from tax-inclusive prices (228.81)');
select tests.ok((select status = 'partially_paid' and amount_paid = 2000 from public.invoices where id = (:'rcpt'::jsonb ->> 'invoice_id')::uuid),
                'payment allocated to the invoice');
select tests.ok((select sum(qty) = 1 and sum(amount) = 1000 from public.deposit_transactions where customer_id = :'cust_h'), 'deposit recorded as a liability movement');
select tests.ok((select holder_type = 'location' and fill_state = 'empty' from public.bottles where code = 'OLA-BTL-00000001'),
                'scanned bottle is now on the vehicle, empty');
select tests.ok((select count(*) = 1 from public.operation_exceptions where exception_type = 'bottle_location' and severity = 'info'),
                'scan of a bottle recorded elsewhere is accepted and flagged');
select tests.ok((select company_id = (select id from public.bottle_companies where code = 'XYZ') and holder_type = 'location'
                   from public.bottles where code = :'xyzlabels'::jsonb ->> 'first'), 'XYZ bottle tagged and on the vehicle');
select tests.ok((select status = 'assigned' from public.identifiers where value = :'xyzlabels'::jsonb ->> 'first'), 'the external tag is now assigned');
select tests.ok((select count(*) = 0 from public.inventory_balances where location_id = (select location_id from public.vehicles where id = :'veh')
                   and product_id = (select id from public.products where sku = 'OLA-5L') and qty > 0), '5L stock left the vehicle');
select tests.ok((select status = 'delivered' from public.orders where id = (:'ord_h'::jsonb ->> 'order_id')::uuid), 'order marked delivered');

-- Scenario 8: the same transaction replayed (offline re-sync) is not duplicated
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', false);
set role authenticated;
select public.complete_delivery(:'del_h', '{}', '22222222-2222-2222-2222-222222222222') as rcpt2 \gset
select tests.ok((:'rcpt2'::jsonb ->> 'invoice_id') = (:'rcpt'::jsonb ->> 'invoice_id') and (:'rcpt2'::jsonb ->> 'duplicate')::boolean,
                're-sent delivery returns the original receipt');
reset role;
select tests.ok((select count(*) = 1 from public.invoices where customer_id = :'cust_h'), 'no duplicate invoice');
select tests.ok((select count(*) = 1 from public.payments where customer_id = :'cust_h'), 'no duplicate payment');

-- Office customer: 5 x 19L, 3 OLA empties back, 1 untagged XYZ bottle (count mode), on credit
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', false);
set role authenticated;
select tests.throws(format($$select public.complete_delivery(%L, jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('product_id',
  (select id from public.products where sku = 'OLA-19L'), 'qty', 50))), gen_random_uuid())$$, :'del_o'), 'not enough stock',
  'cannot deliver more than is on the vehicle');
select public.complete_delivery(:'del_o', jsonb_build_object(
  'lines', jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 5)),
  'ola_returned_counts', jsonb_build_array(jsonb_build_object('bottle_type_id', (select id from public.bottle_types where code = '19L'), 'qty', 3)),
  'external', jsonb_build_array(jsonb_build_object('company_id', (select id from public.bottle_companies where code = 'XYZ'),
                'bottle_type_id', (select id from public.bottle_types where code = '19L'), 'qty', 1))), gen_random_uuid()) as rcpt_o \gset
select tests.ok((:'rcpt_o'::jsonb ->> 'total')::numeric = 2250 and (:'rcpt_o'::jsonb ->> 'paid')::numeric = 0, 'credit delivery: Rs. 2,250 on account');
reset role;
select tests.ok(app.customer_ola_bottles(:'cust_o') = 1, 'office holds 5 - 3 - 1 = 1 OLA bottle');
select tests.ok((select due_date = invoice_date + 30 from public.invoices where customer_id = :'cust_o'), 'office invoice due in 30 days');

-- ---------------------------------------------------------------------
-- Scenario 9: check-in with a missing XYZ bottle and Rs. 500 short
-- Vehicle should hold: 19L full 1 (8 loaded - 7 delivered), OLA empty 5, XYZ empty 2
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);
set role authenticated;
select public.checkin_route_run((:'run'::jsonb ->> 'run_id')::uuid, jsonb_build_object(
  'products', jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 1)),
  'scanned_codes', jsonb_build_array(:'xyzlabels'::jsonb ->> 'first'),
  'bottles', jsonb_build_array(
     jsonb_build_object('company_id', app.own_company_id(), 'bottle_type_id', (select id from public.bottle_types where code = '19L'), 'qty', 5),
     jsonb_build_object('company_id', (select id from public.bottle_companies where code = 'XYZ'), 'bottle_type_id',
                        (select id from public.bottle_types where code = '19L'), 'qty', 1)),
  'cash_handed', 2500), gen_random_uuid()) as checkin \gset
reset role;
select tests.ok((:'checkin'::jsonb ->> 'exceptions')::integer = 2 and (:'checkin'::jsonb ->> 'cash_expected')::numeric = 3000,
                'check-in finds 2 differences; cash expected = 1,000 float + 2,000 collected');
select tests.ok((select status = 'checked_in' from public.route_runs where id = (:'run'::jsonb ->> 'run_id')::uuid), 'run waits for exceptions');
select tests.ok((select qty = 1 from public.bottle_balances where holder_type = 'location'
                   and holder_id = (select id from public.locations where code = 'EXT')
                   and company_id = (select id from public.bottle_companies where code = 'XYZ')), 'one XYZ bottle reached external holding');
select tests.ok((select holder_id = (select id from public.locations where code = 'EXT') from public.bottles where code = :'xyzlabels'::jsonb ->> 'first'),
                'the tagged XYZ bottle is in external holding');
select tests.ok((select qty = 15 from public.bottle_balances where holder_type = 'location' and holder_id = (select id from public.locations where code = 'WH1')
                   and company_id = app.own_company_id() and fill_state = 'empty'), 'warehouse empties: 10 + 5 returned = 15');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.resolve_exception((select id from public.operation_exceptions where exception_type = 'bottle_shortage'), 'write_off', 'Lost on route', gen_random_uuid());
select tests.ok((select status = 'checked_in' from public.route_runs where id = (:'run'::jsonb ->> 'run_id')::uuid), 'run stays open while cash is unresolved');
select public.resolve_exception((select id from public.operation_exceptions where exception_type = 'cash_shortage'), 'charge_driver', 'Deduct from salary', gen_random_uuid());
select tests.ok((select status = 'closed' from public.route_runs where id = (:'run'::jsonb ->> 'run_id')::uuid), 'run closes when all differences are resolved');
reset role;
select tests.ok((select count(*) >= 2 from public.audit_logs where action = 'resolve'), 'resolutions are audited');

-- ---------------------------------------------------------------------
-- Scenario 3 (cont.): hand external bottles back to XYZ, receive OLA bottles
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);
set role authenticated;
select tests.throws($$select public.record_external_handover((select id from public.bottle_companies where code = 'XYZ'), '{}', '[]', '{}', '[]', '', null, null, null, gen_random_uuid())$$,
  'representative', 'hand-over needs the receiver''s name');
select public.record_external_handover((select id from public.bottle_companies where code = 'XYZ'),
  array[:'xyzlabels'::jsonb ->> 'first'], '[]', '{}',
  jsonb_build_array(jsonb_build_object('bottle_type_id', (select id from public.bottle_types where code = '19L'), 'qty', 2)),
  'Kamal (XYZ driver)', '0771112223', 'Monthly swap', null, gen_random_uuid()) as eho \gset
reset role;
select tests.ok((:'eho'::jsonb ->> 'given')::integer = 1 and (:'eho'::jsonb ->> 'received')::integer = 2, 'hand-over: 1 given, 2 OLA received');
select tests.ok((select lifecycle = 'returned_to_owner' from public.bottles where code = :'xyzlabels'::jsonb ->> 'first'), 'XYZ bottle marked returned to owner');
select tests.ok((select count(*) = 3 from public.bottle_transactions bt join public.bottles b on b.id = bt.bottle_id
                  where b.code = :'xyzlabels'::jsonb ->> 'first'), 'full history: intake → check-in → holding → owner');

-- ---------------------------------------------------------------------
-- Payments and accounting
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
set role authenticated;
select public.record_payment(:'cust_h', 'bank_transfer', 500, 'BOC 88123', null, null, gen_random_uuid()) as pay \gset
select tests.ok((:'pay'::jsonb ->> 'outstanding')::numeric = 0, 'office payment clears the household balance');
select tests.throws(format($$select public.record_payment(%L, 'cheque', 100, '', null, null, gen_random_uuid())$$, :'cust_o'),
  'reference', 'cheques need a reference number');
reset role;
select tests.ok((select status = 'paid' from public.invoices where customer_id = :'cust_h'), 'invoice now paid');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select tests.ok((select sum(balance) = 0 from public.trial_balance(date '2026-01-01', date '2027-12-31')), 'ledger still balances after Phase 1A flows');
select tests.ok((select balance = -1000 from public.trial_balance(date '2026-01-01', date '2027-12-31') where account_code = '2200'),
                'bottle deposits held = Rs. 1,000 (liability)');
select tests.ok((select balance = 500 from public.trial_balance(date '2026-01-01', date '2027-12-31') where account_code = '1120'),
                'Rs. 500 cash shortage remains owed by the driver');
reset role;

-- ---------------------------------------------------------------------
-- Recurring orders
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.save_recurring_order(null, jsonb_build_object('customer_id', :'cust_o', 'frequency', 'daily', 'start_date', app.today() + 1,
  'items', jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 2))), 'Standing order') as rec \gset
select public.generate_recurring_orders(app.today() + 3) as gen1 \gset
select public.generate_recurring_orders(app.today() + 3) as gen2 \gset
select tests.ok((:'gen1'::jsonb ->> 'created')::integer = 3 and (:'gen2'::jsonb ->> 'created')::integer = 0,
                'recurring orders: 3 days generated once, re-running creates none');
select public.set_recurring_status(:'rec', 'paused', 'Office closed');
select tests.ok((select status = 'paused' from public.recurring_orders where id = :'rec'), 'recurring order paused');
reset role;

do $$ begin raise notice 'ALL PHASE 1A DATABASE TESTS PASSED'; end $$;

-- Read models used by the screens
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.dashboard_summary() as dash \gset
select tests.ok((:'dash'::jsonb -> 'bottles' ->> 'with_customers')::integer = 2 and (:'dash'::jsonb ->> 'invoices_today')::integer = 2,
                'dashboard: 2 OLA bottles with customers, 2 invoices today');
select tests.ok((select count(*) = 1 from public.external_bottle_accounts() where code = 'XYZ' and collected = 2 and returned = 1 and ola_received = 2),
                'XYZ account: collected 2, returned 1, OLA received 2');
select tests.ok((public.bottle_details('OLA-BTL-00000001') ->> 'found')::boolean, 'bottle lookup returns history');
select tests.ok((public.customer_summary(:'cust_o') ->> 'outstanding')::numeric = 2250, 'customer summary shows outstanding');
reset role;
do $$ begin raise notice 'READ MODEL TESTS PASSED'; end $$;

-- ---------------------------------------------------------------------
-- Field tolerance: labels scanned at the door that the office has not
-- registered yet must never block a delivery
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.save_order(null, jsonb_build_object('customer_id', :'cust_h', 'items', jsonb_build_array(
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 1))), true, gen_random_uuid()) as ord2 \gset
select public.create_route_run(app.today(), :'route', :'veh', '00000000-0000-0000-0000-0000000000d1',
  array[(:'ord2'::jsonb ->> 'order_id')::uuid], null, null, gen_random_uuid()) as run2 \gset
select public.load_route_run((:'run2'::jsonb ->> 'run_id')::uuid, jsonb_build_array(
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 1)), 0, gen_random_uuid());
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', false);
set role authenticated;
select public.driver_start_run((:'run2'::jsonb ->> 'run_id')::uuid);
select public.complete_delivery((select id from public.deliveries where run_id = (:'run2'::jsonb ->> 'run_id')::uuid), jsonb_build_object(
  'lines', jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 1)),
  'ola_returned_codes', jsonb_build_array('OLA-BTL-00000010', 'OLA-BTL-99999999', :'xyzlabels'::jsonb ->> 'last'),
  'payment', jsonb_build_object('method', 'cash', 'amount', 500)), gen_random_uuid()) as rcpt3 \gset
reset role;
select tests.ok((select holder_type = 'location' from public.bottles where code = 'OLA-BTL-00000010'), 'printed-but-unregistered OLA label is registered at the door');
select tests.ok((select count(*) = 1 from public.operation_exceptions where description like 'Unknown label OLA-BTL-99999999%'), 'unknown label is counted and flagged, not rejected');
select tests.ok((select company_id = (select id from public.bottle_companies where code = 'XYZ') from public.bottles where code = :'xyzlabels'::jsonb ->> 'last'),
                'an EXT tag scanned with OLA bottles is recorded as an XYZ bottle');
select tests.ok((select count(*) = 1 from jsonb_array_elements(:'rcpt3'::jsonb -> 'bottles' -> 'external')), 'receipt shows the external bottle');
do $$ begin raise notice 'FIELD TOLERANCE TESTS PASSED'; end $$;
