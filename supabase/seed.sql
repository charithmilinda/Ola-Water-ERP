-- =====================================================================
-- DEMO DATA — for a local or separate TEST project only.
-- Do NOT run this on the live OLA database: it creates fictional
-- customers, prices and stock. (scripts/db-test.sh loads it locally.)
-- =====================================================================

-- Prices, VAT and deposits (demo values — set real ones in the ERP)
insert into public.tax_rates (tax_code, rate_percent, effective_from) values ('VAT', 18, date '2026-01-01') on conflict do nothing;
insert into public.price_list_items (price_list_id, product_id, unit_price, effective_from)
select pl.id, p.id, v.price, date '2026-01-01'
  from (values ('RETAIL','OLA-19L',500),('RETAIL','OLA-5L',250),('RETAIL','OLA-1.5L',120),('RETAIL','OLA-500ML',70),
               ('RETAIL','OLA-1.5L-12',1350),('RETAIL','OLA-500ML-24',1550),
               ('CORPORATE','OLA-19L',450),('CORPORATE','OLA-5L',230),('CORPORATE','OLA-1.5L-12',1250),('CORPORATE','OLA-500ML-24',1450),
               ('DEALER','OLA-19L',420),('DEALER','OLA-5L',210),('DEALER','OLA-1.5L-12',1150),('DEALER','OLA-500ML-24',1350),
               ('DISTRIBUTOR','OLA-19L',380),('DISTRIBUTOR','OLA-1.5L-12',1050),('DISTRIBUTOR','OLA-500ML-24',1250),
               ('SHOP_TRANSFER','OLA-19L',360),('SHOP_TRANSFER','OLA-5L',190)) as v(pl, sku, price)
  join public.price_lists pl on pl.code = v.pl join public.products p on p.sku = v.sku
on conflict do nothing;
update public.products set cost_price = case sku when 'OLA-19L' then 140 when 'OLA-5L' then 90 when 'OLA-1.5L' then 45 when 'OLA-500ML' then 25
  when 'OLA-1.5L-12' then 540 when 'OLA-500ML-24' then 600 else cost_price end;
insert into public.bottle_values (bottle_type_id, company_id, deposit_amount, replacement_value, external_charge, effective_from)
select (select id from public.bottle_types where code = '19L'), c.id, case when c.is_own then 1000 else 0 end,
       case when c.is_own then 1600 else 900 end, case when c.is_own then 0 else 150 end, date '2026-01-01'
  from public.bottle_companies c on conflict do nothing;

-- Vehicles (each is a stock location)
insert into public.locations (code, name, location_type) values ('WPLB4521', 'Vehicle WP LB-4521', 'vehicle'), ('WPPH2290', 'Vehicle WP PH-2290', 'vehicle');
insert into public.vehicles (registration_no, name, vehicle_type, capacity_19l, location_id)
select 'WP LB-4521', 'Lorry 1', 'lorry', 180, id from public.locations where code = 'WPLB4521';
insert into public.vehicles (registration_no, name, vehicle_type, capacity_19l, location_id)
select 'WP PH-2290', 'Van 1', 'van', 60, id from public.locations where code = 'WPPH2290';

-- Routes
insert into public.routes (code, name, area, default_vehicle_id) values
  ('COL-03', 'Colombo 03 / 04', 'Kollupitiya, Bambalapitiya', (select id from public.vehicles where registration_no = 'WP LB-4521')),
  ('DEH-01', 'Dehiwala / Mount Lavinia', 'Dehiwala, Mount Lavinia, Ratmalana', (select id from public.vehicles where registration_no = 'WP PH-2290')),
  ('NUG-01', 'Nugegoda / Maharagama', 'Nugegoda, Nawala, Maharagama', null);

-- Customers (fictional)
with c(name, company, type, phone, route, seq, addr, city, credit) as (values
  ('Nadeesha Perera', null, 'household', '+94771234501', 'COL-03', 1, '12/3 Galle Road', 'Colombo 03', 0),
  ('Ruwan Senanayake', null, 'household', '+94771234502', 'COL-03', 2, '45 Flower Road', 'Colombo 07', 0),
  ('Lanka Tech Solutions', 'Lanka Tech Solutions (Pvt) Ltd', 'office', '+94112501234', 'COL-03', 3, '45 Duplication Road', 'Colombo 04', 75000),
  ('Hotel Seaview', 'Seaview Hotels (Pvt) Ltd', 'hotel', '+94112789900', 'COL-03', 4, '120 Marine Drive', 'Colombo 03', 150000),
  ('Spice Garden Restaurant', null, 'restaurant', '+94772345678', 'COL-03', 5, '8 Duplication Road', 'Colombo 04', 25000),
  ('Dilani Fernando', null, 'household', '+94712223301', 'DEH-01', 1, '23 Hill Street', 'Dehiwala', 0),
  ('Mount Lavinia Pharmacy', null, 'shop', '+94112733445', 'DEH-01', 2, '301 Galle Road', 'Mount Lavinia', 20000),
  ('St. Mary''s Montessori', null, 'institution', '+94112716677', 'DEH-01', 3, '14 Vihara Road', 'Mount Lavinia', 30000),
  ('Ratmalana Super', 'Ratmalana Super (Pvt) Ltd', 'supermarket', '+94112635566', 'DEH-01', 4, '402 Galle Road', 'Ratmalana', 120000),
  ('Kasun Jayawardena', null, 'household', '+94761112233', 'NUG-01', 1, '7 Stanley Tilakaratne Mawatha', 'Nugegoda', 0),
  ('Nawala Medical Centre', null, 'corporate', '+94112809090', 'NUG-01', 2, '88 Nawala Road', 'Nawala', 100000),
  ('Maharagama Water Point', null, 'water_shop', '+94718889900', 'NUG-01', 3, '156 High Level Road', 'Maharagama', 200000))
, ins as (
  insert into public.customers (name, company_name, customer_type, phone, route_id, route_sequence, price_list_id, credit_limit,
                                payment_terms_days, bottle_model, allowed_bottles)
  select c.name, c.company, c.type, c.phone, r.id, c.seq, d.price_list_id, c.credit, d.payment_terms_days, d.bottle_model, d.allowed_bottles
    from c join public.routes r on r.code = c.route join public.customer_type_defaults d on d.customer_type = c.type
  returning id, phone)
insert into public.customer_addresses (customer_id, label, address_line, city, is_default)
select ins.id, 'Main', c.addr, c.city, true from ins join c on c.phone = ins.phone;

-- Opening stock and bottles at the main warehouse
insert into public.inventory_balances (location_id, product_id, qty)
select (select id from public.locations where code = 'WH1'), p.id, v.q
  from (values ('OLA-19L', 300), ('OLA-5L', 120), ('OLA-1.5L-12', 80), ('OLA-500ML-24', 60)) v(sku, q) join public.products p on p.sku = v.sku;
insert into public.bottle_balances (holder_type, holder_id, company_id, bottle_type_id, fill_state, qty)
select 'location', (select id from public.locations where code = 'WH1'), app.own_company_id(), (select id from public.bottle_types where code = '19L'), f, q
  from (values ('full', 300), ('empty', 150)) v(f, q);
