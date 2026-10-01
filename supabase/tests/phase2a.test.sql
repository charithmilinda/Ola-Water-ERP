-- =====================================================================
-- Phase 2A database tests — acceptance scenario 5 (production → QC hold
-- → pass → sellable; fail → never sellable), purchasing with 3-way match,
-- batch tracing and recall, weighted average cost, ledger balance.
-- Runs after the Phase 0, 1A and 1B tests in the same database.
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = notice;

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'prod@ola.test',  '{"full_name":"Kamal Herath"}'),
  ('00000000-0000-0000-0000-0000000000a2', 'qc@ola.test',    '{"full_name":"Dilani Fernando"}'),
  ('00000000-0000-0000-0000-0000000000a3', 'buyer@ola.test', '{"full_name":"Asanka Peiris"}');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.admin_assign_role('00000000-0000-0000-0000-0000000000a1', (select id from public.roles where code = 'production_manager'), null, 'Production');
select public.admin_assign_role('00000000-0000-0000-0000-0000000000a2', (select id from public.roles where code = 'quality_officer'), null, 'QC');
select public.admin_assign_role('00000000-0000-0000-0000-0000000000a3', (select id from public.roles where code = 'procurement_officer'), null, 'Buyer');

-- ---------------------------------------------------------------------
-- Materials and bill of materials
-- ---------------------------------------------------------------------
select public.save_product(null, '{"sku":"CAP-19L","name":"19L cap","item_type":"packaging","unit":"piece","reorder_level":500}', 'New material') as cap \gset
select public.save_product(null, '{"sku":"LBL-19L","name":"19L label","item_type":"packaging","unit":"piece","reorder_level":500}', 'New material') as lbl \gset
select public.save_product(null, '{"sku":"CHEM-OZ","name":"Ozone generator salt","item_type":"chemical","unit":"kg"}', 'New material') as chem \gset
select tests.ok((select item_type = 'packaging' and not is_returnable and category = 'other' from public.products where id = :'cap'),
                'materials are stock items that are never returnable');
select public.set_bill_of_materials((select id from public.products where sku = 'OLA-19L'),
  jsonb_build_array(jsonb_build_object('material_id', :'cap', 'qty_per_unit', 1), jsonb_build_object('material_id', :'lbl', 'qty_per_unit', 1)), 'BOM');
select tests.throws(format($$select public.set_bill_of_materials(%L, '[]', 'x')$$, :'cap'), 'finished product', 'only products have a bill of materials');
reset role;
update public.products set shelf_life_days = 180 where sku = 'OLA-19L';

-- ---------------------------------------------------------------------
-- Purchasing: request → order → goods received → invoice (3-way) → payment
-- ---------------------------------------------------------------------
set role authenticated;
select public.save_supplier(null, '{"code":"PACKLK","name":"Lanka Packaging (Pvt) Ltd","phone":"0112345678","vat_no":"114567890-7000","payment_terms_days":30}', 'New supplier') as sup \gset
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a3', false);
select public.create_purchase_request(jsonb_build_object('location_id', (select id from public.locations where code = 'WH1'),
  'items', jsonb_build_array(jsonb_build_object('product_id', :'cap', 'qty', 1000), jsonb_build_object('product_id', :'lbl', 'qty', 1000))),
  gen_random_uuid()) as pr \gset
select tests.throws(format($$select public.decide_purchase_request(%L, true, 'ok')$$, :'pr'::jsonb ->> 'request_id'), 'permission denied',
                    'the buyer cannot approve their own request');
select tests.throws(format($$select public.create_purchase_order(jsonb_build_object('supplier_id', %L, 'location_id', %L, 'request_id', %L,
  'lines', jsonb_build_array(jsonb_build_object('product_id', %L, 'qty', 1, 'unit_price', 5))), gen_random_uuid())$$,
  :'sup', (select id from public.locations where code = 'WH1'), :'pr'::jsonb ->> 'request_id', :'cap'), 'approved first',
  'an order cannot be made from an unapproved request');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select public.decide_purchase_request((:'pr'::jsonb ->> 'request_id')::uuid, true, 'Needed for October');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a3', false);
select public.create_purchase_order(jsonb_build_object('supplier_id', :'sup', 'location_id', (select id from public.locations where code = 'WH1'),
  'request_id', :'pr'::jsonb ->> 'request_id', 'expected_date', app.today() + 3,
  'lines', jsonb_build_array(jsonb_build_object('product_id', :'cap', 'qty', 1000, 'unit_price', 5, 'tax_rate', 18),
                             jsonb_build_object('product_id', :'lbl', 'qty', 1000, 'unit_price', 2))), gen_random_uuid()) as po \gset
select tests.ok((:'po'::jsonb ->> 'status') = 'approved' and (:'po'::jsonb ->> 'total')::numeric = 7900,
                'order under the purchase limit is approved straight away (Rs. 5,900 caps incl. VAT + Rs. 2,000 labels)');
select public.create_purchase_order(jsonb_build_object('supplier_id', :'sup', 'location_id', (select id from public.locations where code = 'WH1'),
  'lines', jsonb_build_array(jsonb_build_object('product_id', :'cap', 'qty', 30000, 'unit_price', 5))), gen_random_uuid()) as po_big \gset
select tests.ok((:'po_big'::jsonb ->> 'status') = 'pending_approval', 'order over Rs. 100,000 waits for approval');
select tests.throws(format($$select public.receive_purchase_order(%L, '{"lines":[]}', gen_random_uuid())$$, :'po_big'::jsonb ->> 'po_id'),
                    'approved order', 'nothing can be received on an unapproved order');
reset role;
select tests.ok((select status = 'ordered' from public.purchase_requests where id = (:'pr'::jsonb ->> 'request_id')::uuid), 'request marked ordered');
select (select id from public.purchase_order_lines where po_id = (:'po'::jsonb ->> 'po_id')::uuid and product_id = :'cap') as cap_line \gset
select (select id from public.purchase_order_lines where po_id = (:'po'::jsonb ->> 'po_id')::uuid and product_id = :'lbl') as lbl_line \gset

-- Goods received: part of the caps (10 rejected at the door) and all labels
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);  -- warehouse manager
select tests.throws(format($$select public.receive_purchase_order(%L, jsonb_build_object('lines', jsonb_build_array(
  jsonb_build_object('po_line_id', %L, 'qty_received', 600, 'qty_rejected', 10))), gen_random_uuid())$$, :'po'::jsonb ->> 'po_id', :'cap_line'),
  'why', 'rejected goods need a reason');
select public.receive_purchase_order((:'po'::jsonb ->> 'po_id')::uuid, jsonb_build_object('delivery_note_no', 'DN-5531', 'lines', jsonb_build_array(
  jsonb_build_object('po_line_id', :'cap_line', 'qty_received', 600, 'qty_rejected', 10, 'reject_reason', 'Cracked'),
  jsonb_build_object('po_line_id', :'lbl_line', 'qty_received', 1000, 'supplier_lot', 'L-0925'))), gen_random_uuid()) as grn1 \gset
select tests.throws(format($$select public.receive_purchase_order(%L, jsonb_build_object('lines', jsonb_build_array(
  jsonb_build_object('po_line_id', %L, 'qty_received', 500))), gen_random_uuid())$$, :'po'::jsonb ->> 'po_id', :'cap_line'),
  'too many', 'cannot receive more than ordered');
reset role;
select tests.ok((:'grn1'::jsonb ->> 'value')::numeric = 5000 and not (:'grn1'::jsonb ->> 'complete')::boolean, 'first delivery: Rs. 5,000 received, order still open');
select tests.ok((select status = 'partially_received' from public.purchase_orders where id = (:'po'::jsonb ->> 'po_id')::uuid), 'order partly received');
select tests.ok((select qty = 600 from public.inventory_balances where product_id = :'cap' and stock_status = 'available'
                   and location_id = (select id from public.locations where code = 'WH1')), 'accepted caps are in stock; rejected ones are not');
select tests.ok((select cost_price = 5 from public.products where id = :'cap'), 'average cost set from the order price');
select tests.ok((select l.debit = 5000 from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
                  where e.event_type = 'purchase.receipt' and a.system_key = 'inv_raw'), 'goods received: Dr raw materials Rs. 5,000');
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);
select public.receive_purchase_order((:'po'::jsonb ->> 'po_id')::uuid, jsonb_build_object('lines', jsonb_build_array(
  jsonb_build_object('po_line_id', :'cap_line', 'qty_received', 400))), gen_random_uuid()) as grn2 \gset
reset role;
select tests.ok((select status = 'received' from public.purchase_orders where id = (:'po'::jsonb ->> 'po_id')::uuid), 'order fully received');

-- Supplier invoice: caps billed 4% above the order price → held for approval
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a3', false);
select public.record_supplier_invoice((:'po'::jsonb ->> 'po_id')::uuid, jsonb_build_object('supplier_invoice_no', 'LP/2026/0912',
  'lines', jsonb_build_array(jsonb_build_object('po_line_id', :'cap_line', 'qty', 1000, 'unit_price', 5.20),
                             jsonb_build_object('po_line_id', :'lbl_line', 'qty', 1000))), gen_random_uuid()) as sin1 \gset
select tests.ok((:'sin1'::jsonb ->> 'status') = 'on_hold' and jsonb_array_length(:'sin1'::jsonb -> 'mismatches') = 1,
                '3-way match: price above tolerance puts the invoice on hold');
select tests.throws(format($$select public.record_supplier_invoice(%L, '{"supplier_invoice_no":"lp/2026/0912","lines":[{"po_line_id":"%s","qty":1}]}', gen_random_uuid())$$,
  :'po'::jsonb ->> 'po_id', :'lbl_line'), 'already recorded', 'the same supplier invoice cannot be entered twice');
select public.record_supplier_invoice((:'po'::jsonb ->> 'po_id')::uuid, jsonb_build_object('supplier_invoice_no', 'LP/2026/0913',
  'lines', jsonb_build_array(jsonb_build_object('po_line_id', :'lbl_line', 'qty', 5))), gen_random_uuid()) as sin2 \gset
select tests.ok((:'sin2'::jsonb ->> 'status') = 'on_hold' and (:'sin2'::jsonb ->> 'mismatches') like '%received%',
                '3-way match: billing more than was received is held');
select tests.throws(format($$select public.decide_supplier_invoice(%L, true, 'ok')$$, :'sin1'::jsonb ->> 'invoice_id'), 'permission denied',
                    'the buyer cannot approve a mismatched invoice');
reset role;
select tests.ok((select count(*) = 0 from public.journal_entries where event_type = 'purchase.invoice'), 'held invoices are not posted');
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select public.decide_supplier_invoice((:'sin2'::jsonb ->> 'invoice_id')::uuid, false, 'Duplicate billing — returned to supplier');
select public.decide_supplier_invoice((:'sin1'::jsonb ->> 'invoice_id')::uuid, true, 'Price rise agreed by phone with Lanka Packaging');
reset role;
select tests.ok((select qty_invoiced = 1000 from public.purchase_order_lines where id = :'lbl_line'), 'voiding the second invoice releases its quantity');
select tests.ok((select sum(l.debit) filter (where a.system_key = 'grni') = 7000 and sum(l.debit) filter (where a.system_key = 'ppv') = 200
                    and sum(l.debit) filter (where a.system_key = 'vat_input') = 936 and sum(l.credit) filter (where a.system_key = 'ap') = 8136
                   from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
                  where e.event_type = 'purchase.invoice'),
                'invoice posts GRNI 7,000 + price variance 200 + VAT 936 = payable 8,136');
select tests.ok((select balance = 0 from public.trial_balance(date '2026-01-01', date '2027-12-31') where account_code = '2110'),
                'goods received not invoiced clears once everything is billed');

set role authenticated;
select tests.throws(format($$select public.record_supplier_payment(jsonb_build_object('supplier_id', %L, 'method', 'bank_transfer', 'amount', 5000), gen_random_uuid())$$, :'sup'),
                    'reference', 'bank payments need a reference');
select public.record_supplier_payment(jsonb_build_object('supplier_id', :'sup', 'method', 'bank_transfer', 'amount', 5000, 'reference', 'HNB TT 4412'),
  gen_random_uuid()) as spay \gset
reset role;
select tests.ok((:'spay'::jsonb ->> 'outstanding')::numeric = 3136
                and (select status = 'partially_paid' from public.supplier_invoices where id = (:'sin1'::jsonb ->> 'invoice_id')::uuid),
                'payment applied to the invoice: Rs. 3,136 still owed');
set role authenticated;
select tests.ok((select outstanding = 3136 and on_time_pct = 100 and rejected_pct = 0.5 from public.supplier_list() where id = :'sup'),
                'supplier list shows balance, on-time and rejection rate');
reset role;

-- ---------------------------------------------------------------------
-- Scenario 5: production → QC hold → pass → available
-- ---------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select public.generate_label_batch('OLA-BTL', 2, 'qrcode', '50x25', 'Production test', gen_random_uuid()) as lb \gset
select (select value from public.identifiers where label_batch_id = (:'lb'::jsonb ->> 'batch_id')::uuid order by value limit 1) as code1 \gset
select (select value from public.identifiers where label_batch_id = (:'lb'::jsonb ->> 'batch_id')::uuid order by value desc limit 1) as code2 \gset
select public.register_bottles(array[:'code1', :'code2'], (select id from public.bottle_types where code = '19L'),
  (select id from public.locations where code = 'WH1'), 'empty', 'New labelled bottles', gen_random_uuid());
select public.set_opening_bottles('location', (select id from public.locations where code = 'WH1'), app.own_company_id(),
  (select id from public.bottle_types where code = '19L'), 'empty', 200, 'Empties counted for production', gen_random_uuid());
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', false);
select public.save_production_line(null, jsonb_build_object('code', 'L1-19L', 'name', '19L filling line',
  'location_id', (select id from public.locations where code = 'WH1')), 'New line') as line \gset
select public.plan_production_batch(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'),
  'line_id', :'line', 'planned_qty', 100, 'shift', 'morning'), gen_random_uuid()) as b1 \gset
select public.record_production_stage((:'b1'::jsonb ->> 'batch_id')::uuid, 'ro', 'TDS 12 ppm', null);
select public.record_production_stage((:'b1'::jsonb ->> 'batch_id')::uuid, 'filling', null, null);
reset role;
select (select coalesce(sum(qty), 0) from public.inventory_balances where location_id = (select id from public.locations where code = 'WH1')
          and product_id = (select id from public.products where sku = 'OLA-19L') and stock_status = 'available') as avail_before \gset
select (select cost_price from public.products where sku = 'OLA-19L') as cost_before \gset
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', false);
select tests.throws(format($$select public.complete_production_batch(%L, jsonb_build_object('produced_qty', 98, 'rejected_qty', 2,
  'bottle_codes', jsonb_build_array('OLA-BTL-99999999')), gen_random_uuid())$$, :'b1'::jsonb ->> 'batch_id'), 'unknown bottle',
  'unknown bottle labels are refused at filling');
select public.complete_production_batch((:'b1'::jsonb ->> 'batch_id')::uuid, jsonb_build_object('produced_qty', 98, 'rejected_qty', 2,
  'wastage_qty', 12, 'wastage_note', 'Litres lost at changeover', 'bottle_codes', jsonb_build_array(:'code1', lower(:'code2'))),
  gen_random_uuid()) as c1 \gset
reset role;
select (:'b1'::jsonb ->> 'batch_id') as batch1 \gset
select tests.ok((:'c1'::jsonb ->> 'material_cost')::numeric = 700 and (:'c1'::jsonb ->> 'bottles_scanned')::integer = 2,
                'bill of materials used for 100 fills: 100 caps × 5 + 100 labels × 2 = Rs. 700; 2 bottles traced');
select tests.ok((select qty = 900 from public.inventory_balances where product_id = :'cap' and stock_status = 'available'
                   and location_id = (select id from public.locations where code = 'WH1')), 'materials consumed from stock');
select tests.ok((select status = 'qc_hold' and expiry_date = production_date + 180 from public.production_batches where id = :'batch1'),
                'new batch starts on QC hold with an expiry date');
select tests.ok((select qty = 98 from public.inventory_balances where product_id = (select id from public.products where sku = 'OLA-19L')
                   and stock_status = 'qc_hold' and location_id = (select id from public.locations where code = 'WH1')), '98 units on QC hold');
select tests.ok((select coalesce(sum(qty), 0) = :avail_before from public.inventory_balances where product_id = (select id from public.products where sku = 'OLA-19L')
                   and stock_status = 'available' and location_id = (select id from public.locations where code = 'WH1')), 'held stock is not available');
select tests.ok((select last_batch_id = :'batch1' and fill_state = 'full' and fill_count = 1 from public.bottles where code = :'code2'),
                'each scanned bottle remembers its batch');
select tests.ok((select cost_price <> :cost_before from public.products where sku = 'OLA-19L'), 'average cost updated by production');
select tests.throws(format($$select app.stock_move('sale', (select id from public.products where sku = 'OLA-19L'), %s, (select id from public.locations where code = 'WH1'), null)$$,
                    :avail_before + 1), 'not enough stock', 'held stock cannot be sold');
select tests.throws(format($$select app.stock_move('sale', %L, 1, (select id from public.locations where code = 'WH1'), null)$$, :'cap'),
                    'not a product for sale', 'materials can never be sold');

-- QC: template, a failing test, then a passing test
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', false);
select public.save_qc_template(null, jsonb_build_object('code', 'BW-STD', 'name', 'Bottled water — standard',
  'parameters', jsonb_build_array(
    jsonb_build_object('name', 'pH', 'value_type', 'number', 'min_value', 6.5, 'max_value', 8.5),
    jsonb_build_object('name', 'TDS', 'unit', 'ppm', 'value_type', 'number', 'min_value', 0, 'max_value', 500),
    jsonb_build_object('name', 'Turbidity', 'unit', 'NTU', 'value_type', 'number', 'max_value', 5),
    jsonb_build_object('name', 'E. coli', 'value_type', 'pass_fail'),
    jsonb_build_object('name', 'Appearance', 'value_type', 'text', 'is_required', false))), 'Standard tests') as tpl \gset
select (select id from public.qc_template_parameters where template_id = :'tpl' and name = 'pH') as p_ph \gset
select (select id from public.qc_template_parameters where template_id = :'tpl' and name = 'TDS') as p_tds \gset
select (select id from public.qc_template_parameters where template_id = :'tpl' and name = 'Turbidity') as p_tur \gset
select (select id from public.qc_template_parameters where template_id = :'tpl' and name = 'E. coli') as p_ec \gset
select public.record_qc_test(:'batch1', jsonb_build_object('template_id', :'tpl', 'sample_ref', 'S-1', 'results', jsonb_build_array(
  jsonb_build_object('parameter_id', :'p_ph', 'value', '9.1'), jsonb_build_object('parameter_id', :'p_tds', 'value', '45'),
  jsonb_build_object('parameter_id', :'p_tur', 'value', '0.4'), jsonb_build_object('parameter_id', :'p_ec', 'value', 'Absent'))),
  gen_random_uuid()) as t1 \gset
select tests.ok((:'t1'::jsonb ->> 'result') = 'fail' and (:'t1'::jsonb -> 'failed') = '["pH"]'::jsonb, 'value outside range is flagged automatically');
select tests.throws(format($$select public.release_production_batch(%L, false, null, gen_random_uuid())$$, :'batch1'), 'override',
                    'a batch whose latest test failed cannot be released normally');
select tests.throws(format($$select public.release_production_batch(%L, true, 'urgent', gen_random_uuid())$$, :'batch1'), 'permission denied',
                    'a QC officer cannot override');
select public.record_qc_test(:'batch1', jsonb_build_object('template_id', :'tpl', 'sample_ref', 'S-2', 'lab_name', 'ITI Lab', 'results', jsonb_build_array(
  jsonb_build_object('parameter_id', :'p_ph', 'value', '7.2'), jsonb_build_object('parameter_id', :'p_tds', 'value', '45'),
  jsonb_build_object('parameter_id', :'p_tur', 'value', '0.4'), jsonb_build_object('parameter_id', :'p_ec', 'value', 'Absent'))),
  gen_random_uuid()) as t2 \gset
select public.release_production_batch(:'batch1', false, null, gen_random_uuid()) as r1 \gset
reset role;
select tests.ok((:'t2'::jsonb ->> 'result') = 'pass' and (:'r1'::jsonb ->> 'released_qty')::numeric = 98, 'retest passes and the batch is released');
select tests.ok((select qty = :avail_before + 98 from public.inventory_balances where product_id = (select id from public.products where sku = 'OLA-19L')
                   and stock_status = 'available' and location_id = (select id from public.locations where code = 'WH1')), 'released stock is available for sale');
select tests.throws($$update public.qc_tests set result = 'pass'$$, 'append-only', 'QC results cannot be edited');

-- ---------------------------------------------------------------------
-- Scenario 5 (fail): a failed batch is never sellable
-- ---------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', false);
select public.plan_production_batch(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'),
  'line_id', :'line', 'planned_qty', 50), gen_random_uuid()) as b2 \gset
select public.complete_production_batch((:'b2'::jsonb ->> 'batch_id')::uuid, jsonb_build_object('produced_qty', 50, 'rejected_qty', 0,
  'materials', jsonb_build_array(jsonb_build_object('material_id', :'cap', 'qty', 50), jsonb_build_object('material_id', :'lbl', 'qty', 50),
                                 jsonb_build_object('material_id', :'chem', 'qty', 0))), gen_random_uuid());
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', false);
select public.record_qc_test((:'b2'::jsonb ->> 'batch_id')::uuid, jsonb_build_object('template_id', :'tpl', 'results', jsonb_build_array(
  jsonb_build_object('parameter_id', :'p_ph', 'value', '7.0'), jsonb_build_object('parameter_id', :'p_tds', 'value', '40'),
  jsonb_build_object('parameter_id', :'p_tur', 'value', '0.3'), jsonb_build_object('parameter_id', :'p_ec', 'value', 'Present'))),
  gen_random_uuid()) as t3 \gset
select public.reject_production_batch((:'b2'::jsonb ->> 'batch_id')::uuid, 'E. coli present', gen_random_uuid());
reset role;
select (:'b2'::jsonb ->> 'batch_id') as batch2 \gset
select tests.ok((:'t3'::jsonb ->> 'result') = 'fail' and (select status = 'failed' from public.production_batches where id = :'batch2'),
                'failed test → batch failed');
select tests.ok((select qty = 50 from public.inventory_lots where batch_id = :'batch2' and stock_status = 'quarantine'), 'failed stock is quarantined');
select tests.ok((select qty = :avail_before + 98 from public.inventory_balances where product_id = (select id from public.products where sku = 'OLA-19L')
                   and stock_status = 'available' and location_id = (select id from public.locations where code = 'WH1')), 'failed stock never becomes available');
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select public.dispose_quarantined_stock(:'batch2', (select id from public.locations where code = 'WH1'), 40, 'Poured away, bottles to washing',
  gen_random_uuid()) as d1 \gset
select tests.throws(format($$select public.release_production_batch(%L, true, '', gen_random_uuid())$$, :'batch2'), 'reason',
                    'an override needs a reason');
select public.release_production_batch(:'batch2', true, 'Re-tested by external lab: contamination was in the sample bottle', gen_random_uuid()) as r2 \gset
reset role;
select tests.ok((:'d1'::jsonb ->> 'value')::numeric = 280, 'destroyed stock written off at the batch cost (40 × Rs. 7)');
select tests.ok((select release_override and status = 'released' from public.production_batches where id = :'batch2')
                and (select count(*) = 1 from public.audit_logs where action = 'qc_override_release'),
                'authorised override release is recorded and audited');

-- ---------------------------------------------------------------------
-- Batch tracing: FIFO picks older stock first; a sale records its batch
-- ---------------------------------------------------------------------
select (select coalesce(sum(qty), 0) from public.inventory_lots where location_id = (select id from public.locations where code = 'WH1')
          and product_id = (select id from public.products where sku = 'OLA-19L') and stock_status = 'available' and batch_id is null) as unbatched \gset
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select public.transfer_stock((select id from public.locations where code = 'WH1'), (select id from public.locations where code = 'SHOP01'),
  jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', :unbatched)), 'Old stock to the shop',
  gen_random_uuid());
reset role;
select tests.ok((select coalesce(sum(qty), 0) = 0 from public.inventory_lots where location_id = (select id from public.locations where code = 'WH1')
                   and product_id = (select id from public.products where sku = 'OLA-19L') and stock_status = 'available' and batch_id is null),
                'oldest (pre-production) stock leaves first');
set role authenticated;
select public.pos_sale((select id from public.pos_sessions where location_id = (select id from public.locations where code = 'WH1') and status = 'open'),
  jsonb_build_object('seq', 2, 'customer_id', (select id from public.customers where phone = '+94112501234'),
  'lines', jsonb_build_array(jsonb_build_object('product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 3)),
  'payments', '[]'::jsonb), gen_random_uuid());
reset role;
select tests.ok((select sum(qty) = 3 from public.inventory_transactions where batch_id = :'batch1' and txn_type = 'sale'),
                'the counter sale is traced to batch 1');

-- ---------------------------------------------------------------------
-- Recall
-- ---------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', false);
select tests.throws(format($$select public.recall_production_batch(%L, 'x', gen_random_uuid())$$, :'batch1'), 'permission denied',
                    'a recall needs an authorised manager');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select public.recall_production_batch(:'batch1', 'Cap seal supplier reported a faulty lot', gen_random_uuid()) as rc \gset
reset role;
select tests.ok((:'rc'::jsonb ->> 'secured_qty')::numeric = 95 and (:'rc'::jsonb ->> 'customers')::integer = 1,
                'recall quarantines the 95 units still in stock and lists the customer who bought 3');
select tests.ok((select status = 'recalled' from public.production_batches where id = :'batch1')
                and (select coalesce(sum(qty), 0) = 0 from public.inventory_lots where batch_id = :'batch1' and stock_status = 'available'),
                'recalled stock can no longer be sold');
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a2', false);
select public.record_recall_recovery((select id from public.batch_recall_customers where recall_id = (:'rc'::jsonb ->> 'recall_id')::uuid),
  2, 'contacted', 'Collected 2 sealed bottles; 1 already used', gen_random_uuid());
select tests.ok((public.recall_details((:'rc'::jsonb ->> 'recall_id')::uuid) -> 'totals' ->> 'quarantined')::numeric = 97,
                'recovered units come back into quarantine (95 + 2)');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select public.close_batch_recall((:'rc'::jsonb ->> 'recall_id')::uuid, 'All reachable stock recovered');
reset role;

-- ---------------------------------------------------------------------
-- Manual water receipt is closed; stock count of materials posts to raw materials
-- ---------------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);
select tests.throws($$select public.receive_stock((select id from public.locations where code = 'WH1'), jsonb_build_array(jsonb_build_object(
  'product_id', (select id from public.products where sku = 'OLA-19L'), 'qty', 5)), 'receipt', 'x', gen_random_uuid())$$, 'production batch',
  'water can no longer be put into stock without a batch');
select public.adjust_stock((select id from public.locations where code = 'WH1'), :'cap', 845, 'Cycle count', gen_random_uuid());
reset role;
select tests.ok((select l.credit = 25 from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                   join public.accounts a on a.id = l.account_id where e.event_type = 'material.adjust_loss' and a.system_key = 'inv_raw'),
                'materials count loss (5 caps × Rs. 5) credits raw materials');

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select tests.ok((select count(*) >= 1 from public.stock_summary('materials') where low is false and sku = 'CAP-19L'), 'stock summary lists materials');
select tests.ok((public.operations_summary() -> 'purchasing' ->> 'orders_waiting')::integer = 1
                and (public.operations_summary() -> 'production' ->> 'open_recalls')::integer = 0, 'operations summary for the dashboard');
select tests.ok(jsonb_array_length(public.batch_details(:'batch1') -> 'tests') = 2
                and jsonb_array_length(public.batch_details(:'batch1') -> 'bottles') = 2, 'batch record shows tests and traced bottles');
select tests.ok((select sum(balance) = 0 from public.trial_balance(date '2026-01-01', date '2027-12-31')), 'ledger balances after all Phase 2A flows');
reset role;
select tests.ok((select bool_and(b.qty = coalesce(l.qty, 0)) from public.inventory_balances b
                  left join (select location_id, product_id, stock_status, sum(qty) qty from public.inventory_lots group by 1, 2, 3) l
                    using (location_id, product_id, stock_status)),
                'batch lots always add up to the stock balances');

do $$ begin raise notice 'ALL PHASE 2A DATABASE TESTS PASSED'; end $$;
