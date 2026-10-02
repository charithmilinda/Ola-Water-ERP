-- =====================================================================
-- Phase 3A database tests — approvals (discount, credit terms, prices,
-- stock adjustment with two levels, bottle write-off, reject, validation),
-- approvals inbox, notifications, customer messages and the outbox,
-- complaints with SLA and QC review, document library and expiry.
-- Runs after the Phase 0 – 2C tests in the same database.
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = notice;

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000f7', 'rep@ola.test',      '{"full_name":"Tharindu Jayasinghe"}'),
  ('00000000-0000-0000-0000-0000000000f8', 'director@ola.test', '{"full_name":"Anura Bandara"}'),
  ('00000000-0000-0000-0000-0000000000f9', 'delivery@ola.test', '{"full_name":"Ruwan Dissanayake"}');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.admin_assign_role('00000000-0000-0000-0000-0000000000f7', (select id from public.roles where code = 'sales_representative'), null, 'Sales');
select public.admin_assign_role('00000000-0000-0000-0000-0000000000f8', (select id from public.roles where code = 'director'), null, 'Director');
select public.admin_assign_role('00000000-0000-0000-0000-0000000000f9', (select id from public.roles where code = 'delivery_manager'), null, 'Delivery');
reset role;

select (select id from public.customers where status = 'active' and not is_walk_in and customer_type = 'household' order by created_at limit 1) as cust \gset
select (select id from public.products where sku = 'OLA-19L') as p19 \gset
select (select id from public.locations where code = 'WH1') as wh \gset

-- ---------------------------------------------------------------------
-- Discount above the limit → approval → order created for the rep
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f7', false);
set role authenticated;
select jsonb_build_object('p_id', null, 'p', jsonb_build_object('customer_id', :'cust', 'notes', 'Big discount',
         'items', jsonb_build_array(jsonb_build_object('product_id', :'p19', 'qty', 10, 'discount', 2500))),
       'p_confirm', true, 'p_client_txn_id', gen_random_uuid()) as disc_args \gset
select tests.throws(format('select public.save_order(null, %L::jsonb, true, gen_random_uuid())', (:'disc_args'::jsonb -> 'p')::text),
                    'need approval', 'a large discount is not refused outright: it needs approval');
select public.submit_approval('order_discount', 'save_order', :'disc_args', 'Bulk buyer, one-off') as req1 \gset
select tests.ok((:'req1'::jsonb ->> 'status') = 'pending' and (:'req1'::jsonb ->> 'request_no') like 'APR-%', 'the request is stored with a number');
select tests.throws($$select public.submit_approval('order_discount', 'save_order', '$$ || :'disc_args' || $$', 'again')$$,
                    'already waiting', 'the same request cannot be sent twice');
select tests.throws(format('select public.decide_approval(%L, true, null)', :'req1'::jsonb ->> 'request_id'),
                    'own request', 'nobody approves their own request');
select tests.throws($$select public.submit_approval('order_discount', 'set_prices', '{}', 'x')$$,
                    'cannot be sent', 'only the actions listed on the rule can be requested');
select tests.ok((select count(*) = 0 from public.orders where notes = 'Big discount'), 'no order exists before approval');
reset role;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
set role authenticated;
select tests.throws(format('select public.decide_approval(%L, true, null)', :'req1'::jsonb ->> 'request_id'),
                    'pos.discount', 'only holders of the approver permission can decide');
reset role;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f8', false);
set role authenticated;
select tests.ok(exists (select 1 from jsonb_array_elements(public.approval_inbox() -> 'items') x
                         where x ->> 'id' = :'req1'::jsonb ->> 'request_id'), 'the director sees it in the approvals inbox');
select tests.ok(exists (select 1 from public.notifications where user_id = app.current_user_id() and type_code = 'approval_request'),
                'approvers are notified');
select public.decide_approval((:'req1'::jsonb ->> 'request_id')::uuid, true, 'OK for this customer') as dec1 \gset
reset role;
select tests.ok((:'dec1'::jsonb ->> 'status') = 'approved'
                and (select created_by = '00000000-0000-0000-0000-0000000000f7' and discount_total = 2500 and status = 'confirmed'
                       from public.orders where notes = 'Big discount'),
                'on approval the order is created for the sales rep, confirmed, with the discount');
select tests.ok((select count(*) = 1 from public.notifications where user_id = '00000000-0000-0000-0000-0000000000f7' and type_code = 'approval_decision'),
                'the requester is told');
select tests.ok(exists (select 1 from public.audit_logs where reason like '%approved by Anura Bandara (APR-%'), 'the approval is in the audit trail');

-- ---------------------------------------------------------------------
-- New credit customer: saved as cash, credit terms wait for Finance
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f7', false);
set role authenticated;
select public.save_customer(null, jsonb_build_object('name', 'Kandy Lake Hotel', 'customer_type', 'hotel', 'phone', '0812234455',
  'credit_limit', 150000, 'payment_terms_days', 30), 'New hotel') as hotel \gset
reset role;
select tests.ok((select credit_limit = 0 from public.customers where id = :'hotel')
                and (select status = 'pending' and kind = 'credit_change' from public.approval_requests where entity_id = :'hotel'),
                'a new credit customer starts on cash terms with a credit request waiting');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
set role authenticated;
select public.decide_approval((select id from public.approval_requests where entity_id = :'hotel'), true, 'Checked references');
reset role;
select tests.ok((select credit_limit = 150000 and payment_terms_days = 30 from public.customers where id = :'hotel'),
                'finance approval sets the credit limit and terms');

-- ---------------------------------------------------------------------
-- Price change: Finance proposes, the Director approves
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
set role authenticated;
select jsonb_build_object('p_price_list', (select id from public.price_lists where code = 'RETAIL'),
  'p_prices', jsonb_build_array(jsonb_build_object('product_id', :'p19', 'unit_price', 555)),
  'p_effective_from', (app.today() + 1)::text, 'p_reason', 'Cost increase') as price_args \gset
select tests.throws(format('select public.set_prices(%L, %L, %L, %L)', :'price_args'::jsonb ->> 'p_price_list', (:'price_args'::jsonb -> 'p_prices')::text,
                    app.today() + 1, 'x'), 'need approval', 'price changes need the director');
select public.submit_approval('price_change', 'set_prices', :'price_args', 'Cost increase') as req3 \gset
reset role;
select tests.ok((select details like '%555.00%' from public.approval_requests where id = (:'req3'::jsonb ->> 'request_id')::uuid),
                'the approver sees old and new prices');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f8', false);
set role authenticated;
select public.decide_approval((:'req3'::jsonb ->> 'request_id')::uuid, true, null);
reset role;
select tests.ok(app.unit_price(:'p19', (select id from public.price_lists where code = 'RETAIL'), app.today() + 1) = 555, 'new price takes effect after approval');

-- ---------------------------------------------------------------------
-- Stock adjustment with two approval levels
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select tests.throws($$select public.save_approval_rule('stock_adjustment', '{"levels": 2}', '')$$, 'reason', 'rule changes need a reason');
select public.save_approval_rule('stock_adjustment', '{"levels": 2}', 'Two people for big count changes');
reset role;
select coalesce((select sum(qty) from public.inventory_balances where location_id = :'wh' and product_id = :'p19' and stock_status = 'available'), 0) as have19 \gset
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);
set role authenticated;
select tests.throws(format('select public.adjust_stock(%L, %L, %s, %L, gen_random_uuid())', :'wh', :'p19', :'have19'::numeric + 100, 'Count'),
                    'need approval', 'with two levels even a warehouse manager needs approval');
select public.submit_approval('stock_adjustment', 'adjust_stock', jsonb_build_object('p_location', :'wh', 'p_product', :'p19',
  'p_counted', :'have19'::numeric + 100, 'p_reason', 'Year-end count', 'p_client_txn_id', gen_random_uuid()), 'Year-end count') as req4 \gset
select tests.throws(format($$select public.submit_approval('stock_adjustment', 'adjust_stock', %L, 'x')$$,
                      jsonb_build_object('p_location', :'wh', 'p_product', :'p19', 'p_counted', -5, 'p_reason', 'x', 'p_client_txn_id', gen_random_uuid())),
                    'counted quantity', 'an invalid request is refused straight away (test-run)');
select tests.throws(format($$select public.submit_approval('stock_adjustment', 'adjust_stock', %L, 'x')$$,
                      jsonb_build_object('p_location', :'wh', 'p_product', :'p19', 'p_counted', :'have19'::numeric + 1, 'p_reason', 'x', 'p_client_txn_id', gen_random_uuid())),
                    'no longer needs approval', 'a small change does not need approval');
reset role;
select tests.ok((select sum(qty) = :'have19'::numeric from public.inventory_balances where location_id = :'wh' and product_id = :'p19' and stock_status = 'available'),
                'the test-run left stock unchanged');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.decide_approval((:'req4'::jsonb ->> 'request_id')::uuid, true, 'Level 1') as dec4a \gset
select tests.throws(format('select public.decide_approval(%L, true, null)', :'req4'::jsonb ->> 'request_id'),
                    'already approved', 'the same person cannot give both approvals');
reset role;
select tests.ok((:'dec4a'::jsonb ->> 'status') = 'pending'
                and (select sum(qty) = :'have19'::numeric from public.inventory_balances where location_id = :'wh' and product_id = :'p19' and stock_status = 'available'),
                'after the first level nothing changes yet');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f8', false);
set role authenticated;
select public.decide_approval((:'req4'::jsonb ->> 'request_id')::uuid, true, 'Level 2');
reset role;
select tests.ok((select sum(qty) = :'have19'::numeric + 100 from public.inventory_balances where location_id = :'wh' and product_id = :'p19' and stock_status = 'available'),
                'after the second approval the count is applied');

-- ---------------------------------------------------------------------
-- Bottle write-off: rejected, then approved
-- ---------------------------------------------------------------------
select (select code from public.bottles where holder_type <> 'outside' order by code limit 1) as btl \gset
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f9', false);
set role authenticated;
select tests.throws(format($$select public.mark_bottle(%L, 'retire', 'Cracked')$$, :'btl'), 'needs approval', 'writing off a bottle needs approval');
select public.submit_approval('bottle_write_off', 'mark_bottle', jsonb_build_object('p_code', :'btl', 'p_action', 'retire', 'p_reason', 'Cracked'), 'Cracked') as req5 \gset
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
set role authenticated;
select tests.throws(format('select public.decide_approval(%L, false, %L)', :'req5'::jsonb ->> 'request_id', ''), 'reason', 'a rejection needs a reason');
select public.decide_approval((:'req5'::jsonb ->> 'request_id')::uuid, false, 'Send it for repair first');
reset role;
select tests.ok((select status = 'rejected' from public.approval_requests where id = (:'req5'::jsonb ->> 'request_id')::uuid)
                and (select holder_type <> 'outside' from public.bottles where code = :'btl'), 'a rejected write-off changes nothing');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f9', false);
set role authenticated;
select public.submit_approval('bottle_write_off', 'mark_bottle', jsonb_build_object('p_code', :'btl', 'p_action', 'retire', 'p_reason', 'Cracked beyond repair'), 'Cracked') as req6 \gset
select tests.ok((select count(*) >= 2 from jsonb_array_elements(public.approval_inbox() -> 'mine')), 'requesters see their own requests');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
set role authenticated;
select public.decide_approval((:'req6'::jsonb ->> 'request_id')::uuid, true, null);
reset role;
select tests.ok((select holder_type = 'outside' from public.bottles where code = :'btl'), 'the approved write-off retires the bottle');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select tests.ok(jsonb_typeof(public.approval_inbox() -> 'items') = 'array', 'the inbox gathers every module for a super admin');
select tests.ok((select count(*) >= 3 from public.staff_directory()), 'staff names for assigning complaints');
select tests.ok(jsonb_array_length(public.approval_rules_overview() -> 'rules') >= 5, 'rules overview lists the approval rules');
select tests.ok((select count(*) >= 5 from public.approval_history(app.today() - 1, app.today())), 'approval history');
select public.save_approval_rule('stock_adjustment', '{"levels": 1}', 'Back to one approver');
reset role;

-- ---------------------------------------------------------------------
-- Customer messages and the outbox
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.set_setting('messaging.enabled', 'true', app.today(), 'Go live with SMS');
select public.set_setting('company.phone', '"0112345678"', app.today(), 'Hotline');
select public.save_order(null, jsonb_build_object('customer_id', :'hotel', 'notes', 'msg test',
  'items', jsonb_build_array(jsonb_build_object('product_id', :'p19', 'qty', 2))), true, gen_random_uuid()) as ord \gset
reset role;
select tests.ok((select count(*) = 1 and bool_and(body like '%' || (:'ord'::jsonb ->> 'order_no') || '%' and to_address = '+94812234455' and status = 'queued')
                   from public.message_outbox where template_code = 'ORDER_CONFIRMED' and customer_id = :'hotel'),
                'confirming an order queues an SMS with the order number');
update public.customers set messages_opt_out = true where id = :'hotel';
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.save_order(null, jsonb_build_object('customer_id', :'hotel', 'items', jsonb_build_array(jsonb_build_object('product_id', :'p19', 'qty', 1))),
  true, gen_random_uuid());
reset role;
select tests.ok((select count(*) = 1 from public.message_outbox where template_code = 'ORDER_CONFIRMED' and customer_id = :'hotel'),
                'no messages to customers who opted out');
update public.customers set messages_opt_out = false where id = :'hotel';

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
set role authenticated;
select public.send_customer_message(:'cust', 'PAYMENT_REMINDER', '{"overdue":"1,000.00","due_date":"1 Sep 2026"}');
reset role;

-- the sender: only the service key (or an administrator) may claim messages
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f7', false);
set role authenticated;
select tests.throws('select * from public.claim_messages(10)', 'permission denied', 'staff cannot read the outbox queue');
reset role;
select set_config('request.jwt.claim.sub', '', false);
select set_config('request.jwt.claims', '{"role":"service_role"}', false);
select (select count(*) from public.claim_messages(10)) as claimed \gset
select tests.ok(:'claimed'::integer >= 2 and (select count(*) = 0 from public.message_outbox where status = 'queued'), 'the sender claims queued messages');
select public.report_message_result(id, true, 'notify_lk', 'abc', null) from public.message_outbox where template_code = 'ORDER_CONFIRMED';
select public.report_message_result(id, false, 'notify_lk', null, 'timeout') from public.message_outbox where status = 'sending';
select tests.ok((select status = 'sent' and sent_at is not null from public.message_outbox where template_code = 'ORDER_CONFIRMED'),
                'a sent message is marked sent');
select tests.ok((select bool_and(status = 'queued' and next_attempt_at > now()) from public.message_outbox where last_error = 'timeout'),
                'a failed send is retried later');
select tests.ok((public.refresh_notifications(true) ->> 'ran')::boolean, 'the alert scan runs for the sender');
select set_config('request.jwt.claims', '', false);

-- ---------------------------------------------------------------------
-- Alert scan
-- ---------------------------------------------------------------------
update public.products set reorder_level = 100000 where sku = 'OLA-5L';
update public.notification_scan_state set last_run_at = '-infinity';
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);
set role authenticated;
select public.refresh_notifications(false) as scan1 \gset
select tests.ok((:'scan1'::jsonb ->> 'ran')::boolean and not (public.refresh_notifications(false) ->> 'ran')::boolean,
                'the scan runs, then waits for the next interval');
select tests.ok(exists (select 1 from public.notifications where user_id = app.current_user_id() and type_code = 'low_stock' and title like '%5L%'),
                'low stock is reported to the warehouse');
select tests.ok((public.my_notifications(10) ->> 'unread')::integer > 0, 'unread count');
select public.mark_notifications_read(null);
select tests.ok((public.my_notifications(10) ->> 'unread')::integer = 0, 'mark all read');
reset role;
update public.products set reorder_level = 0 where sku = 'OLA-5L';

-- ---------------------------------------------------------------------
-- Complaints
-- ---------------------------------------------------------------------
select (select batch_no from public.production_batches order by created_at limit 1) as bno \gset
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f7', false);
set role authenticated;
select tests.throws($$select public.log_complaint('{"category_code":"quality","subject":"Bad smell"}', gen_random_uuid())$$,
                    'customer', 'a complaint needs a customer or contact number');
select public.log_complaint(jsonb_build_object('category_code', 'quality', 'subject', 'Bad smell in water', 'customer_id', :'hotel',
  'description', 'Guests complained', 'batch_no', :'bno', 'photo_paths', jsonb_build_array('new/x.jpg')), gen_random_uuid()) as cmp \gset
select (:'cmp'::jsonb ->> 'complaint_id') as cmp_id \gset
reset role;
select tests.ok((select priority = 'urgent' and status = 'new' and qc_review_status = 'requested'
                        and due_at between created_at + interval '3 hours 59 minutes' and created_at + interval '4 hours 1 minute'
                   from public.complaints where id = :'cmp_id'),
                'quality complaints default to urgent with a 4-hour SLA and ask QC to review the batch');
select tests.ok(exists (select 1 from public.notifications where user_id = '00000000-0000-0000-0000-0000000000a2' and type_code = 'qc_review'),
                'quality control is notified');
select tests.ok(exists (select 1 from public.message_outbox where template_code = 'COMPLAINT_RECEIVED' and customer_id = :'hotel'),
                'the customer gets an acknowledgement');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f7', false);
set role authenticated;
select public.assign_complaint(:'cmp_id', '00000000-0000-0000-0000-0000000000f9', 'Please visit the hotel');
select public.update_complaint(:'cmp_id', '{"status":"in_progress","note":"Visited, took a sample"}');
select public.add_complaint_note(:'cmp_id', 'Sample sent to the lab', array['x/y.jpg']);
select tests.throws(format('select public.resolve_complaint(%L, %L, null)', :'cmp_id', 'Replaced'), 'quality control', 'QC must review first');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', false);
set role authenticated;
select public.complete_complaint_qc_review(:'cmp_id', 'Retained sample passes; cap seal faulty on this delivery');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f7', false);
set role authenticated;
select tests.throws(format('select public.close_complaint(%L, null)', :'cmp_id'), 'resolve', 'close only after resolving');
select public.resolve_complaint(:'cmp_id', 'Replaced 10 bottles free of charge', 'Faulty cap seals from one supplier lot');
select public.close_complaint(:'cmp_id', 'Customer happy');
select public.reopen_complaint(:'cmp_id', 'Customer called again');
select tests.ok((select status = 'in_progress' and resolved_at is null from public.complaints where id = :'cmp_id'), 'reopen goes back to in progress');
select public.resolve_complaint(:'cmp_id', 'Second replacement', null);
select tests.ok(jsonb_array_length(public.complaint_details(:'cmp_id') -> 'events') >= 9, 'the timeline keeps every step');
select tests.ok((public.complaints_summary(app.today() - 30, app.today()) ->> 'logged')::integer >= 1, 'complaints summary');
reset role;
select tests.ok((select assigned_to = '00000000-0000-0000-0000-0000000000f9' and first_response_at is not null from public.complaints where id = :'cmp_id')
                and exists (select 1 from public.notifications where user_id = '00000000-0000-0000-0000-0000000000f9' and type_code = 'complaint_assigned'),
                'the assignee is notified and first response time recorded');
select tests.throws($$update public.complaint_events set note = 'x'$$, 'append-only', 'the complaint timeline cannot be changed');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', false);
set role authenticated;
select tests.ok((select count(*) = 0 from public.complaints), 'drivers cannot read complaints');
reset role;

-- ---------------------------------------------------------------------
-- Documents
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false);
set role authenticated;
select public.register_document(jsonb_build_object('category_code', 'employee', 'title', 'Appointment letter', 'entity_type', 'employee',
  'entity_id', (select id from public.employees order by created_at limit 1), 'file_path', 'employee/a.pdf', 'file_name', 'a.pdf')) as d1 \gset
select tests.throws($$select public.register_document('{"category_code":"lab_report","title":"x","file_path":"lab_report/x.pdf"}')$$,
                    'qc.manage', 'HR cannot file lab reports');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f8', false);
set role authenticated;
select tests.throws($$select public.register_document('{"category_code":"licence","title":"SLSI","file_path":"licence/x.pdf"}')$$,
                    'expiry', 'licences need an expiry date');
select tests.throws($$select public.register_document('{"category_code":"licence","title":"SLSI","file_path":"other/x.pdf","expires_on":"2030-01-01"}')$$,
                    'not uploaded', 'the file must be in the category folder');
select public.register_document(jsonb_build_object('category_code', 'licence', 'title', 'SLSI product certificate', 'reference_no', 'SLS 894',
  'entity_type', 'company', 'file_path', 'licence/slsi.pdf', 'file_name', 'slsi.pdf', 'expires_on', (app.today() + 10)::text)) as d2 \gset
select tests.ok(exists (select 1 from public.expiring_documents(30) where id = (:'d2'::jsonb ->> 'document_id')::uuid and days_left = 10),
                'documents expiring soon are listed');
select public.register_document(jsonb_build_object('category_code', 'licence', 'title', 'SLSI product certificate (renewed)',
  'file_path', 'licence/slsi2.pdf', 'file_name', 'slsi2.pdf', 'expires_on', (app.today() + 400)::text,
  'replaces_id', :'d2'::jsonb ->> 'document_id')) as d3 \gset
select tests.ok((select status = 'replaced' from public.documents where id = (:'d2'::jsonb ->> 'document_id')::uuid)
                and (select entity_type = 'company' from public.documents where id = (:'d3'::jsonb ->> 'document_id')::uuid),
                'a new version replaces the old one and keeps its link');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f7', false);
set role authenticated;
select tests.ok((select count(*) = 0 from public.documents where category_code in ('employee','licence')), 'a sales rep cannot see HR or company documents');
reset role;
update public.notification_scan_state set last_run_at = '-infinity';
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f8', false);
select public.update_document((:'d3'::jsonb ->> 'document_id')::uuid, jsonb_build_object('expires_on', (app.today() + 5)::text), 'Typo');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f8', false);
set role authenticated;
select public.refresh_notifications(false);
select tests.ok(exists (select 1 from public.notifications where user_id = app.current_user_id() and type_code = 'document_expiry'),
                'document managers are warned before expiry');
select tests.ok((public.control_summary() ->> 'documents_expiring')::integer >= 1, 'dashboard control summary');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false);
set role authenticated;
select tests.ok((select count(*) = 1 from public.entity_documents('employee', (select id from public.employees order by created_at limit 1))),
                'documents show on the employee');
reset role;

do $$ begin raise notice 'ALL PHASE 3A DATABASE TESTS PASSED'; end $$;
