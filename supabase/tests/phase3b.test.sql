-- =====================================================================
-- Phase 3B database tests — sales reps (targets, GPS visits, collections,
-- cash hand-in, commission → payroll), distributors (profile, stock
-- reports, performance), CRM (leads, follow-ups, opportunities,
-- conversion, segments, promotions with approval, campaigns).
-- Runs after the Phase 0 – 3A tests in the same database.
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = notice;

select (select id from public.products where sku = 'OLA-19L') as p19 \gset
select (select id from public.money_accounts where kind = 'cash' and is_default) as cash \gset
select (select id from public.customers where name = 'Kandy Lake Hotel') as hotel \gset
select (select id from public.employees where emp_no = 'E001') as emp1 \gset

-- ---------------------------------------------------------------------
-- Sales team set-up
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f8', false);
set role authenticated;
select public.save_territory(null, '{"code":"CENTRAL","name":"Central Province","districts":["Kandy","Matale"]}') as terr \gset
select public.save_sales_rep(null, jsonb_build_object('profile_id', '00000000-0000-0000-0000-0000000000f7', 'employee_id', :'emp1', 'code', 'SR01',
  'territory_id', :'terr', 'commission_plan_id', (select id from public.commission_plans where code = 'STD'), 'phone', '0771112233')) as rep \gset
select tests.throws(format($$select public.save_sales_rep(null, jsonb_build_object('profile_id', %L, 'code', 'SR02'))$$, '00000000-0000-0000-0000-0000000000f7'),
                    'already exists', 'one rep record per login');
select public.assign_customers_to_rep(array[:'hotel'::uuid, (select id from public.customers where name = 'Galle Face Residency')], :'rep', 'Territory split');
select public.set_sales_targets(extract(year from app.today())::int, extract(month from app.today())::int,
  jsonb_build_array(jsonb_build_object('rep_id', :'rep', 'sales_target', 1000, 'collection_target', 1000, 'new_customers', 2, 'visits', 20)));
reset role;

-- ---------------------------------------------------------------------
-- A rep's day: GPS check-in, collection, check-out
-- ---------------------------------------------------------------------
update public.customer_addresses set gps_lat = 7.293100, gps_lng = 80.635000 where customer_id = :'hotel';
insert into public.customer_addresses (customer_id, label, address_line, city, gps_lat, gps_lng, is_default)
select :'hotel', 'Main', '1 Lake Road', 'Kandy', 7.293100, 80.635000, true
 where not exists (select 1 from public.customer_addresses where customer_id = :'hotel');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f7', false);
set role authenticated;
select public.rep_check_in(jsonb_build_object('customer_id', :'hotel', 'purpose', 'collection', 'lat', 7.2950, 'lng', 80.6350, 'accuracy', 12), gen_random_uuid()) as vis \gset
select tests.ok((:'vis'::jsonb ->> 'distance_m')::integer between 180 and 230 and (:'vis'::jsonb ->> 'warning') is null,
                'check-in records the distance from the customer (about 210 m, inside the 300 m limit)');
select tests.throws(format($$select public.rep_check_in(jsonb_build_object('customer_id', %L), gen_random_uuid())$$, :'hotel'), 'check out', 'one open visit at a time');
select public.rep_collect_payment(:'hotel', 'cash', 1000, null, 'Part payment', (:'vis'::jsonb ->> 'visit_id')::uuid, gen_random_uuid()) as col \gset
select tests.throws(format($$select public.rep_collect_payment(%L, 'cheque', 500, null, null, null, gen_random_uuid())$$, :'hotel'), 'cheque number',
                    'cheques need their number');
select public.rep_check_out((:'vis'::jsonb ->> 'visit_id')::uuid, '{"outcome":"payment","notes":"Paid in cash","next_action_on":"2026-12-01"}');
select tests.ok((public.my_sales_day() ->> 'cash_with_me')::numeric = 1000 and jsonb_array_length(public.my_sales_day() -> 'today') = 1,
                'the rep sees the cash held and today''s visit');
select public.rep_check_in(jsonb_build_object('customer_id', :'hotel', 'lat', 6.9271, 'lng', 79.8612), gen_random_uuid()) as vis2 \gset
select tests.ok((:'vis2'::jsonb ->> 'warning') like '%m from the customer%', 'checking in far away is flagged');
select public.rep_check_out((:'vis2'::jsonb ->> 'visit_id')::uuid, '{"outcome":"no_one_there"}');
reset role;
select tests.ok((select p.rep_id = :'rep' and v.payment_id is not null from public.payments p join public.rep_visits v on v.payment_id = p.id
                   where v.id = (:'vis'::jsonb ->> 'visit_id')::uuid), 'the payment is linked to the rep and the visit');
select tests.ok((select sum(l.debit - l.credit) = 1000 from public.journal_lines l join public.accounts a on a.id = l.account_id
                  where a.system_key = 'rep_cash' and l.party_id = :'rep'), 'collected cash sits in Cash with Sales Reps for that rep');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
set role authenticated;
select tests.throws(format($$select public.rep_cash_handover(%L, 1500, %L, null, null, gen_random_uuid())$$, :'rep', :'cash'), 'holds only',
                    'cannot hand in more than the rep holds');
select public.rep_cash_handover(:'rep', 600, :'cash', null, 'Evening hand-in', gen_random_uuid()) as ho \gset
select tests.ok((:'ho'::jsonb ->> 'still_held')::numeric = 400, 'part hand-in leaves the rest with the rep');
reset role;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f8', false);
set role authenticated;
select tests.ok((select collections >= 1000 and visits = 2 and sales_target = 1000 and cash_with_rep = 400
                   from public.sales_team_overview(extract(year from app.today())::int, extract(month from app.today())::int) where id = :'rep'),
                'team overview: collections, visits, target, cash held');
select tests.ok(jsonb_array_length(public.rep_details(:'rep') -> 'history') = 6 and jsonb_array_length(public.rep_details(:'rep') -> 'visits') = 2,
                'rep details with six months of history');
reset role;

-- ---------------------------------------------------------------------
-- Commission → approved → paid through payroll
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f8', false);
set role authenticated;
select tests.throws('select public.prepare_commissions(2027, 1)', 'not started', 'no commission for a future month');
select public.prepare_commissions(2026, 9);
select (select id from public.commission_statements where rep_id = :'rep' and period_year = 2026 and period_month = 9) as cs \gset
select tests.throws(format('select public.adjust_commission(%L, 5000, null)', :'cs'), 'explain', 'adjustments need a reason');
select public.adjust_commission(:'cs', 5000, 'Launch bonus for the Kandy territory');
reset role;
select tests.ok((select total = 5000 and status = 'draft' from public.commission_statements where id = :'cs'), 'statement total includes the adjustment');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f7', false);
set role authenticated;
select tests.throws(format('select public.approve_commission(%L, null)', :'cs'), 'permission denied', 'a rep cannot approve commission');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
set role authenticated;
select public.approve_commission(:'cs', 'OK') as ca \gset
reset role;
select tests.ok((:'ca'::jsonb ->> 'via_payroll')::boolean and (select status = 'approved' and journal_entry_id is not null from public.commission_statements where id = :'cs'),
                'approval books the commission expense; the rep is on the payroll');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false);
set role authenticated;
select public.create_payroll_run(extract(year from app.today())::int, extract(month from app.today())::int, 'October', gen_random_uuid()) as prl \gset
reset role;
select tests.ok((select l.amount = 5000 and l.source = 'commission' from public.payslip_lines l join public.payslips s on s.id = l.payslip_id
                  where s.run_id = (:'prl'::jsonb ->> 'run_id')::uuid and s.employee_id = :'emp1' and l.source = 'commission'), 'the commission appears on the rep''s payslip');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
set role authenticated;
select public.approve_payroll_run((:'prl'::jsonb ->> 'run_id')::uuid, 'October payroll');
reset role;
select tests.ok((select status = 'paid' and paid_via = 'payroll' and payslip_id is not null from public.commission_statements where id = :'cs'),
                'payroll approval marks the commission paid');
select tests.ok((select coalesce(sum(l.credit - l.debit), 0) = 0 from public.journal_lines l join public.accounts a on a.id = l.account_id
                  where a.system_key = 'commission_payable'), 'commission payable is cleared by the payroll (no double expense)');

-- ---------------------------------------------------------------------
-- Distributors
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.save_customer(null, jsonb_build_object('name', 'Matale Water Distributors', 'customer_type', 'distributor', 'phone', '0662223344',
  'credit_limit', 500000, 'payment_terms_days', 30), 'New distributor') as dcust \gset
select public.save_distributor(null, jsonb_build_object('customer_id', :'dcust', 'code', 'D-MTL', 'territory_id', :'terr', 'monthly_target', 250000,
  'agreement_start', '2026-01-01', 'agreement_end', (app.today() + 20)::text, 'min_stock_19l', 200), 'Signed agreement') as dist \gset
select public.record_distributor_stock(:'dist', app.today() - 1, jsonb_build_array(jsonb_build_object('product_id', :'p19', 'qty', 150)), 80, 'Monthly count');
select public.set_prices((select id from public.price_lists where code = 'DISTRIBUTOR'),
  jsonb_build_array(jsonb_build_object('product_id', :'p19', 'unit_price', 380)), app.today(), 'Distributor price');
select public.save_order(null, jsonb_build_object('customer_id', :'dcust', 'items', jsonb_build_array(jsonb_build_object('product_id', :'p19', 'qty', 100))),
  true, gen_random_uuid()) as dord \gset
select tests.throws(format($$select public.record_distributor_stock(%L, app.today() + 1, '[]', 5, null)$$, :'dist'), 'future', 'no future stock counts');
select tests.ok((select monthly_target = 250000 and credit_limit = 500000 and territory = 'Central Province' from public.distributor_overview() where id = :'dist'),
                'distributor overview with target, credit and territory');
select tests.ok((public.distributor_details(:'dist') -> 'stock' ->> 'report_date')::date = app.today() - 1
                and jsonb_array_length(public.distributor_details(:'dist') -> 'history') = 12, 'stock report and 12-month history');
update public.notification_scan_state set last_run_at = '-infinity';
select public.refresh_notifications(true);
reset role;
select tests.ok(exists (select 1 from public.notifications where type_code = 'distributor_agreement'), 'agreements ending soon are flagged');

-- ---------------------------------------------------------------------
-- CRM: leads, follow-ups, opportunity, conversion
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f7', false);
set role authenticated;
select tests.throws($$select public.save_lead(null, '{"name":"Dup","phone":"0812234455"}')$$, 'already a customer', 'existing customers are not added as leads');
select public.save_lead(null, jsonb_build_object('name', 'Peradeniya Campus Canteen', 'phone', '0812388990', 'customer_type', 'institution',
  'source', 'field_visit', 'city', 'Peradeniya', 'est_monthly_bottles', 120, 'est_monthly_value', 60000, 'territory_id', :'terr')) as lead \gset
select (:'lead'::jsonb ->> 'lead_id') as lead_id \gset
select public.log_crm_activity(jsonb_build_object('lead_id', :'lead_id', 'kind', 'call', 'subject', 'Introduced 19L service', 'outcome', 'Interested'));
select public.log_crm_activity(jsonb_build_object('lead_id', :'lead_id', 'kind', 'visit', 'subject', 'Tasting and price offer', 'done', false, 'due_on', app.today()::text)) as act \gset
select tests.ok((select status = 'contacted' and next_follow_up = app.today() from public.leads where id = :'lead_id'), 'a call moves the lead to contacted and the visit sets the follow-up');
select public.save_opportunity(null, jsonb_build_object('title', 'Canteen supply', 'lead_id', :'lead_id', 'stage', 'proposal', 'monthly_value', 60000,
  'expected_close', (app.today() + 14)::text)) as opp \gset
select tests.ok((select probability = 40 from public.opportunities where id = :'opp'), 'stage gives a default probability');
select public.complete_crm_activity(:'act', 'Agreed to start next week');
select tests.ok((select next_follow_up is null from public.leads where id = :'lead_id'), 'completing the follow-up clears the date');
select tests.throws(format($$select public.save_lead(%L, '{"name":"x","status":"lost"}')$$, :'lead_id'), 'why', 'a lost lead needs a reason');
select public.convert_lead(:'lead_id', jsonb_build_object('address', jsonb_build_object('address_line', 'University Park', 'city', 'Peradeniya'))) as conv \gset
reset role;
select tests.ok((select l.status = 'won' and c.lead_id = l.id and c.sales_rep_id = '00000000-0000-0000-0000-0000000000f7' and c.customer_type = 'institution'
                   from public.leads l join public.customers c on c.id = l.customer_id where l.id = :'lead_id'),
                'converting a lead creates the customer, linked to the lead and owned by the rep');
select tests.ok((select customer_id is not null from public.opportunities where id = :'opp'), 'the opportunity follows the new customer');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f7', false);
set role authenticated;
select tests.ok((public.crm_overview() -> 'pipeline' -> 'won' ->> 'count')::integer >= 1 and public.lead_details(:'lead_id') is not null, 'CRM overview and lead details');
reset role;

-- ---------------------------------------------------------------------
-- Segments, promotions (approval) and campaigns
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f7', false);
set role authenticated;
select public.save_segment(null, 'Hotels', 'All hotel customers', '{"customer_types":["hotel"]}') as seg \gset
select tests.ok((:'seg'::jsonb ->> 'customers')::integer >= 2 and (public.segment_preview('{"customer_types":["hotel"]}') ->> 'count')::integer >= 2,
                'segment counts its customers');
select public.save_promotion(null, jsonb_build_object('code', 'HOTEL10', 'name', 'Hotels 10% off 19L', 'kind', 'percent', 'value', 10, 'product_id', :'p19',
  'segment_id', :'seg'::jsonb ->> 'segment_id', 'min_qty', 5, 'start_date', app.today()::text, 'end_date', (app.today() + 30)::text)) as promo \gset
select tests.throws(format('select public.activate_promotion(%L, null)', :'promo'), 'needs approval', 'switching on a promotion needs the price approver');
select public.submit_approval('promotion', 'activate_promotion', jsonb_build_object('p_id', :'promo', 'p_reason', 'Hotel season'), 'Hotel season') as preq \gset
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f8', false);
set role authenticated;
select public.decide_approval((:'preq'::jsonb ->> 'request_id')::uuid, true, null);
reset role;
select tests.ok((select status = 'active' from public.promotions where id = :'promo'), 'approved promotion is active');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f7', false);
set role authenticated;
select public.save_order(null, jsonb_build_object('customer_id', :'hotel', 'notes', 'promo test',
  'items', jsonb_build_array(jsonb_build_object('product_id', :'p19', 'qty', 10))), true, gen_random_uuid()) as pord \gset
select public.save_order(null, jsonb_build_object('customer_id', :'hotel', 'notes', 'small',
  'items', jsonb_build_array(jsonb_build_object('product_id', :'p19', 'qty', 2))), true, gen_random_uuid()) as pord2 \gset
reset role;
select tests.ok((select promotion_id = :'promo' and promo_discount = round(qty * unit_price * 0.10, 2) and discount = promo_discount
                   from public.order_items where order_id = (:'pord'::jsonb ->> 'order_id')::uuid),
                'the promotion is applied automatically to a qualifying order line (no approval needed)');
select tests.ok((select promotion_id is null and promo_discount = 0 from public.order_items where order_id = (:'pord2'::jsonb ->> 'order_id')::uuid),
                'below the minimum quantity there is no promotion');
select tests.ok((select (:'pord'::jsonb ->> 'status') = 'confirmed'), 'the promotional order is confirmed straight away');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f7', false);
set role authenticated;
select public.save_campaign(null, jsonb_build_object('code', 'HOTELS-OCT', 'name', 'Hotel season offer', 'channel', 'sms',
  'segment_id', :'seg'::jsonb ->> 'segment_id', 'promotion_id', :'promo', 'budget', 10000, 'spent', 2500)) as camp \gset
select public.send_campaign_message(:'camp', 'Dear {{customer_name}}, hotels get 10% off 19L bottles this month. Call {{company_phone}}.') as sent1 \gset
select public.send_campaign_message(:'camp', 'Reminder') as sent2 \gset
select tests.ok((:'sent1'::jsonb ->> 'queued')::integer >= 2 and (:'sent2'::jsonb ->> 'queued')::integer = 0,
                'a campaign message goes once to each customer in the segment');
select tests.ok(exists (select 1 from public.message_outbox where related_type = 'campaign' and body like 'Dear Kandy Lake Hotel, hotels get 10%'),
                'the message is personalised');
select tests.ok((select promo_discount > 0 and status = 'active' from public.campaign_performance() where id = :'camp'), 'campaign performance shows the promotion use');
select tests.ok((select orders = 1 and discount_given > 0 from public.promotion_performance() where id = :'promo'), 'promotion performance');
select tests.ok(exists (select 1 from public.active_promotions_for(:'hotel') where id = :'promo'), 'the order screen can show the customer''s promotions');
reset role;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', false);
set role authenticated;
select tests.ok((select count(*) = 0 from public.leads) and public.my_sales_day() is null, 'drivers see no leads and are not reps');
reset role;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select tests.ok((select sum(balance) = 0 from public.trial_balance(date '2026-01-01', date '2027-12-31')), 'ledger balances after all Phase 3B flows');

do $$ begin raise notice 'ALL PHASE 3B DATABASE TESTS PASSED'; end $$;
