-- =====================================================================
-- Phase 4 database tests — GPS stop ordering for a run and a route,
-- demand forecast, material needs, customers due for a refill, analytics.
-- Runs after the Phase 0 – 3C tests in the same database.
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = notice;

-- the ordering on its own: points along a road, given out of order
select tests.ok(app.tour_order(array[7.00, 7.03, 7.01, 7.02]::float8[], array[80.0, 80.0, 80.0, 80.0]::float8[], false) = array[3, 4, 2],
                'stops are visited in road order from the start');
select tests.ok(app.path_length(array[7.00, 7.03, 7.01, 7.02]::float8[], array[80.0, 80.0, 80.0, 80.0]::float8[], array[3, 4, 2], false)
                < app.path_length(array[7.00, 7.03, 7.01, 7.02]::float8[], array[80.0, 80.0, 80.0, 80.0]::float8[], array[2, 3, 4], false),
                'the suggested order is shorter');

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select tests.throws(format('select public.set_location_gps(%L, 51.5, -0.12)', (select id from public.locations where code = 'WH1')), 'Sri Lanka',
                    'a warehouse location must be in Sri Lanka');
select public.set_location_gps((select id from public.locations where code = 'WH1'), 6.9000, 79.9000);
select public.save_route(null, '{"code":"GPS-T","name":"GPS test route"}', 'Test') as rt \gset
select public.save_customer(null, jsonb_build_object('name', 'Far Away', 'customer_type', 'household', 'phone', '0771110001', 'route_id', :'rt', 'route_sequence', 1,
  'address', jsonb_build_object('address_line', '1 Far St', 'gps_lat', 6.9300, 'gps_lng', 79.9000)), 'New') as c3 \gset
select public.save_customer(null, jsonb_build_object('name', 'Near By', 'customer_type', 'household', 'phone', '0771110002', 'route_id', :'rt', 'route_sequence', 2,
  'address', jsonb_build_object('address_line', '2 Near St', 'gps_lat', 6.9100, 'gps_lng', 79.9000)), 'New') as c1 \gset
select public.save_customer(null, jsonb_build_object('name', 'Middle', 'customer_type', 'household', 'phone', '0771110003', 'route_id', :'rt', 'route_sequence', 3,
  'address', jsonb_build_object('address_line', '3 Mid St', 'gps_lat', 6.9200, 'gps_lng', 79.9000)), 'New') as c2 \gset
select public.save_customer(null, jsonb_build_object('name', 'No Pin', 'customer_type', 'household', 'phone', '0771110004', 'route_id', :'rt', 'route_sequence', 4,
  'address', jsonb_build_object('address_line', '4 Unknown St')), 'New') as c4 \gset

-- route order
select public.suggest_route_sequence(:'rt') as rs \gset
select tests.ok((:'rs'::jsonb -> 'suggested' -> 0 ->> 'customer') = 'Near By' and (:'rs'::jsonb -> 'suggested' -> 2 ->> 'customer') = 'Far Away'
                and jsonb_array_length(:'rs'::jsonb -> 'no_gps') = 1, 'route customers are ordered nearest first; customers without GPS are listed');
select public.apply_route_sequence(:'rt', array[:'c1', :'c2', :'c3']::uuid[]);
select tests.ok((select string_agg(name, ',' order by route_sequence) from public.customers where route_id = :'rt') = 'Near By,Middle,Far Away,No Pin',
                'the route order is saved, customers without GPS last');

-- a run with the stops in a poor order
select public.save_vehicle(null, '{"registration_no":"WP GPS-0001","name":"GPS van","capacity_19l":50}', 'Test') as vh \gset
reset role;
update public.customers set route_sequence = case name when 'Far Away' then 1 when 'Near By' then 2 when 'Middle' then 3 else 4 end where route_id = :'rt';
set role authenticated;
select count(public.save_order(null, jsonb_build_object('customer_id', c, 'items', jsonb_build_array(
  jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-5L'), 'qty', 1))), true, gen_random_uuid()))
  from unnest(array[:'c1', :'c2', :'c3', :'c4']::uuid[]) c;
select array_agg(id) as orders from public.orders where customer_id = any (array[:'c1', :'c2', :'c3', :'c4']::uuid[]) and status = 'confirmed' \gset
select public.create_route_run(app.today(), :'rt', :'vh', '00000000-0000-0000-0000-0000000000d1', :'orders'::uuid[], null, null, gen_random_uuid()) as run \gset
select public.suggest_run_order((:'run'::jsonb ->> 'run_id')::uuid) as so \gset
select tests.ok((:'so'::jsonb ->> 'suggested_km')::numeric < (:'so'::jsonb ->> 'current_km')::numeric
                and (:'so'::jsonb -> 'suggested' -> 0 ->> 'customer') = 'Near By' and jsonb_array_length(:'so'::jsonb -> 'no_gps') = 1,
                'the run order saves kilometres, starting at the warehouse');
select tests.throws(format('select public.apply_run_order(%L, %L)', :'run'::jsonb ->> 'run_id', array[:'c1']::uuid[]), 'changed',
                    'the whole list of pending stops must be given');
select public.apply_run_order((:'run'::jsonb ->> 'run_id')::uuid,
  (select array_agg((x ->> 'delivery_id')::uuid order by o) from jsonb_array_elements(:'so'::jsonb -> 'suggested') with ordinality t(x, o))
  || (select array_agg((x ->> 'delivery_id')::uuid) from jsonb_array_elements(:'so'::jsonb -> 'no_gps') x));
reset role;
select tests.ok((select string_agg(c.name, ',' order by d.stop_sequence) from public.deliveries d join public.customers c on c.id = d.customer_id
                  where d.run_id = (:'run'::jsonb ->> 'run_id')::uuid) = 'Near By,Middle,Far Away,No Pin', 'the new stop order is applied');

-- refill prediction: a customer who orders every 7 days, last 7 days ago
insert into public.invoices (invoice_no, customer_id, invoice_date, due_date, subtotal_net, total)
select 'TEST-RF-' || g, :'c1', app.today() - 7 * g, app.today() - 7 * g, 1000, 1000 from generate_series(1, 4) g;
update public.orders set status = 'cancelled' where customer_id = :'c1' and status <> 'cancelled';
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select tests.ok(exists (select 1 from jsonb_array_elements(public.refill_due(2, null)) x
                         where x ->> 'customer' = 'Near By' and (x ->> 'usual_gap_days')::integer = 7),
                'a weekly customer with no order is due for a refill');
select public.demand_forecast(4) as fc \gset
select tests.ok(jsonb_array_length(:'fc'::jsonb -> 'products') >= 1 and jsonb_array_length(:'fc'::jsonb -> 'products' -> 0 -> 'history') = 12,
                'the forecast has 12 weeks of history per product');
select tests.ok(jsonb_typeof(public.material_needs(4)) = 'array', 'material needs');
select tests.ok(jsonb_array_length(public.analytics_overview(12) -> 'months') = 12, 'analytics has 12 months');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', false);
set role authenticated;
select tests.throws($$select public.analytics_overview(12)$$, 'permission', 'drivers cannot open analytics');
reset role;
update public.invoices set status = 'void' where invoice_no like 'TEST-RF-%';

do $$ begin raise notice 'ALL PHASE 4 DATABASE TESTS PASSED'; end $$;
