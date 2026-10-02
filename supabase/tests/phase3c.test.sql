-- =====================================================================
-- Phase 3C database tests — every report runs, totals agree with the
-- source tables, permissions are enforced and downloads are audited.
-- Runs after the Phase 0 – 3B tests in the same database.
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = notice;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
do $$
declare r text; v jsonb; n integer := 0;
  co uuid := (select id from public.bottle_companies where not is_own order by name limit 1);
begin
  foreach r in array array['sales-daily','sales-monthly','sales-by-product','sales-by-customer','sales-by-customer-type','sales-by-channel',
    'sales-by-distributor','sales-by-rep','customers-inactive','customers-new','stock-current','stock-valuation','stock-movements','stock-damaged',
    'stock-low','stock-expiry','bottle-circulation','bottle-customers','bottle-holders','bottle-external','bottle-external-statement',
    'bottle-exposure','bottle-losses','bottle-discrepancies','bottle-ageing','bottle-retirement','delivery-daily','delivery-failures',
    'delivery-drivers','delivery-routes','delivery-vehicles','production-summary','production-batches','production-qc-failures',
    'production-recalls','finance-expenses','finance-shop-balances','finance-deposits','complaints-by-category'] loop
    v := public.run_report(r, jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co));
    if jsonb_typeof(v) <> 'array' then raise exception 'FAIL - report % did not return rows', r; end if;
    n := n + 1;
  end loop;
  raise notice 'ok - all % reports run', n;
end $$;

select tests.ok((select sum((x ->> 'net')::numeric) from jsonb_array_elements(public.run_report('sales-daily',
                   jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text))) x)
                = (select coalesce(sum(subtotal_net), 0) from public.invoices where status <> 'void' and invoice_date between app.today() - 400 and app.today() + 1),
                'daily sales add up to the invoices');
select tests.ok((select sum((x ->> 'net')::numeric) from jsonb_array_elements(public.run_report('sales-by-channel',
                   jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text))) x)
                = (select coalesce(sum(subtotal_net), 0) from public.invoices where status <> 'void' and invoice_date between app.today() - 400 and app.today() + 1),
                'sales by channel add up to the same total');
select tests.ok((select sum((x ->> 'value')::numeric) from jsonb_array_elements(public.run_report('stock-valuation', '{}')) x)
                = (select round(sum(round(b.qty * p.cost_price, 2)), 2) from (select product_id, sum(qty) qty from public.inventory_balances group by product_id) b
                     join public.products p on p.id = b.product_id where p.is_active),
                'stock valuation agrees with the balances');
select tests.ok((select sum((x ->> 'total')::numeric) from jsonb_array_elements(public.run_report('bottle-circulation', '{}')) x)
                = (select sum(qty) from public.bottle_balances where company_id = app.own_company_id()),
                'bottle circulation accounts for every OLA bottle');
select tests.ok(exists (select 1 from jsonb_array_elements(public.run_report('finance-deposits', '{}')) x where x ->> 'bottle_type' like 'Ledger%'),
                'deposit liability shows the ledger balance to compare');
select tests.throws($$select public.run_report('sales-daily', '{"from":"2026-09-10","to":"2026-09-01"}')$$, 'after the end', 'dates must be in order');
select tests.throws($$select public.run_report('nonsense', '{}')$$, 'permission', 'unknown reports are refused');
select public.run_report('stock-current', '{"export": true}');
select public.log_export('trial-balance', '{"from":"2026-09-01","to":"2026-09-30"}');
reset role;
select tests.ok((select count(*) = 2 from public.audit_logs where action = 'export' and module = 'reports'), 'downloads are recorded in the audit trail');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', false);
set role authenticated;
select tests.throws($$select public.run_report('sales-daily', '{}')$$, 'permission', 'drivers cannot open sales reports');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);
set role authenticated;
select tests.ok(jsonb_typeof(public.run_report('stock-current', '{}')) = 'array', 'the warehouse can open stock reports');
select tests.throws($$select public.run_report('finance-expenses', '{}')$$, 'permission', 'but not finance reports');
reset role;

-- generated: every report returns the columns the screen shows (checked when it has rows)
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
do $$ declare v jsonb; k text; co uuid := (select id from public.bottle_companies where not is_own order by name limit 1); begin
  v := public.run_report('sales-daily', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['date','invoices','net','vat','total','collected'] loop if not (v -> 0) ? k then raise exception 'FAIL - sales-daily has no column %', k; end if; end loop; end if;
  v := public.run_report('sales-monthly', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['month','invoices','customers','net','vat','total','collected'] loop if not (v -> 0) ? k then raise exception 'FAIL - sales-monthly has no column %', k; end if; end loop; end if;
  v := public.run_report('sales-by-product', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['product','sku','qty','avg_price','net','vat','total','share_pct'] loop if not (v -> 0) ? k then raise exception 'FAIL - sales-by-product has no column %', k; end if; end loop; end if;
  v := public.run_report('sales-by-customer', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['customer','customer_no','customer_type','invoices','net','total','last_invoice','outstanding'] loop if not (v -> 0) ? k then raise exception 'FAIL - sales-by-customer has no column %', k; end if; end loop; end if;
  v := public.run_report('sales-by-customer-type', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['customer_type','customers','invoices','net','total','share_pct'] loop if not (v -> 0) ? k then raise exception 'FAIL - sales-by-customer-type has no column %', k; end if; end loop; end if;
  v := public.run_report('sales-by-channel', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['channel','invoices','customers','net','vat','total','share_pct'] loop if not (v -> 0) ? k then raise exception 'FAIL - sales-by-channel has no column %', k; end if; end loop; end if;
  v := public.run_report('sales-by-distributor', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['distributor','code','territory','invoices','net','target','target_pct','outstanding'] loop if not (v -> 0) ? k then raise exception 'FAIL - sales-by-distributor has no column %', k; end if; end loop; end if;
  v := public.run_report('sales-by-rep', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['rep','code','territory','customers','net','target','target_pct','collections','visits'] loop if not (v -> 0) ? k then raise exception 'FAIL - sales-by-rep has no column %', k; end if; end loop; end if;
  v := public.run_report('customers-inactive', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['customer','customer_no','customer_type','phone','route','rep','last_invoice','days_since','outstanding'] loop if not (v -> 0) ? k then raise exception 'FAIL - customers-inactive has no column %', k; end if; end loop; end if;
  v := public.run_report('customers-new', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['customer','customer_no','customer_type','created','rep','first_sale','net_to_date'] loop if not (v -> 0) ? k then raise exception 'FAIL - customers-new has no column %', k; end if; end loop; end if;
  v := public.run_report('stock-current', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['location','product','sku','stock_status','qty','unit_cost','value'] loop if not (v -> 0) ? k then raise exception 'FAIL - stock-current has no column %', k; end if; end loop; end if;
  v := public.run_report('stock-valuation', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['product','sku','item_type','available','other','qty','unit_cost','value'] loop if not (v -> 0) ? k then raise exception 'FAIL - stock-valuation has no column %', k; end if; end loop; end if;
  v := public.run_report('stock-movements', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['at','txn_type','product','qty','from_location','to_location','reason','by'] loop if not (v -> 0) ? k then raise exception 'FAIL - stock-movements has no column %', k; end if; end loop; end if;
  v := public.run_report('stock-damaged', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['location','product','stock_status','qty','value'] loop if not (v -> 0) ? k then raise exception 'FAIL - stock-damaged has no column %', k; end if; end loop; end if;
  v := public.run_report('stock-low', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['product','sku','item_type','reorder_level','available','short_by'] loop if not (v -> 0) ? k then raise exception 'FAIL - stock-low has no column %', k; end if; end loop; end if;
  v := public.run_report('stock-expiry', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['location','product','batch_no','stock_status','qty','production_date','expiry_date','days_left'] loop if not (v -> 0) ? k then raise exception 'FAIL - stock-expiry has no column %', k; end if; end loop; end if;
  v := public.run_report('bottle-circulation', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['bottle_type','holder','full','empty','total'] loop if not (v -> 0) ? k then raise exception 'FAIL - bottle-circulation has no column %', k; end if; end loop; end if;
  v := public.run_report('bottle-customers', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['customer','customer_no','bottle_model','allowed_bottles','ola_held','deposits_qty','deposits_amount','uncovered','last_delivered'] loop if not (v -> 0) ? k then raise exception 'FAIL - bottle-customers has no column %', k; end if; end loop; end if;
  v := public.run_report('bottle-holders', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['holder','holder_kind','driver','company','bottle_type','full','empty','total'] loop if not (v -> 0) ? k then raise exception 'FAIL - bottle-holders has no column %', k; end if; end loop; end if;
  v := public.run_report('bottle-external', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['company','held_now','alert_level','received_from_customers','returned_to_company','ola_received_back','handovers','last_handover'] loop if not (v -> 0) ? k then raise exception 'FAIL - bottle-external has no column %', k; end if; end loop; end if;
  v := public.run_report('bottle-external-statement', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['date','txn_type','bottle_type','bottles_in','bottles_out','reference_type','reason'] loop if not (v -> 0) ? k then raise exception 'FAIL - bottle-external-statement has no column %', k; end if; end loop; end if;
  v := public.run_report('bottle-exposure', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['holder','bottle_type','qty','unit_value','value','deposits_held','uncovered'] loop if not (v -> 0) ? k then raise exception 'FAIL - bottle-exposure has no column %', k; end if; end loop; end if;
  v := public.run_report('bottle-losses', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['date','txn_type','company','bottle_type','qty','bottle_code','from_holder','value','reason'] loop if not (v -> 0) ? k then raise exception 'FAIL - bottle-losses has no column %', k; end if; end loop; end if;
  v := public.run_report('bottle-discrepancies', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['date','exception_type','description','expected','actual','difference','status','resolution','run_no','location'] loop if not (v -> 0) ? k then raise exception 'FAIL - bottle-discrepancies has no column %', k; end if; end loop; end if;
  v := public.run_report('bottle-ageing', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['holder','d0_30','d31_60','d61_90','d90_plus','total'] loop if not (v -> 0) ? k then raise exception 'FAIL - bottle-ageing has no column %', k; end if; end loop; end if;
  v := public.run_report('bottle-retirement', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['code','bottle_type','fill_count','max_fills','condition','holder','last_movement_at'] loop if not (v -> 0) ? k then raise exception 'FAIL - bottle-retirement has no column %', k; end if; end loop; end if;
  v := public.run_report('delivery-daily', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['date','runs','stops','delivered','partial','failed','success_pct'] loop if not (v -> 0) ? k then raise exception 'FAIL - delivery-daily has no column %', k; end if; end loop; end if;
  v := public.run_report('delivery-failures', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['reason','failures','share_pct','customers'] loop if not (v -> 0) ? k then raise exception 'FAIL - delivery-failures has no column %', k; end if; end loop; end if;
  v := public.run_report('delivery-drivers', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['driver','runs','stops','failed','success_pct','invoiced','cash_short','bottles_short'] loop if not (v -> 0) ? k then raise exception 'FAIL - delivery-drivers has no column %', k; end if; end loop; end if;
  v := public.run_report('delivery-routes', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['route','runs','stops','stops_per_run','success_pct','invoiced','invoiced_per_run'] loop if not (v -> 0) ? k then raise exception 'FAIL - delivery-routes has no column %', k; end if; end loop; end if;
  v := public.run_report('delivery-vehicles', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['vehicle','runs','sales','litres','fuel','repairs','other_costs','depreciation','contribution'] loop if not (v -> 0) ? k then raise exception 'FAIL - delivery-vehicles has no column %', k; end if; end loop; end if;
  v := public.run_report('production-summary', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['product','batches','planned','produced','rejected','wastage','yield_pct','rejection_pct','released','failed','avg_unit_cost'] loop if not (v -> 0) ? k then raise exception 'FAIL - production-summary has no column %', k; end if; end loop; end if;
  v := public.run_report('production-batches', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['batch_no','production_date','product','line','planned_qty','produced_qty','rejected_qty','wastage_qty','unit_cost','status','qc_pass','qc_fail','complaints'] loop if not (v -> 0) ? k then raise exception 'FAIL - production-batches has no column %', k; end if; end loop; end if;
  v := public.run_report('production-qc-failures', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['test_no','date','batch_no','product','test','failed_checks','batch_status','lab_name'] loop if not (v -> 0) ? k then raise exception 'FAIL - production-qc-failures has no column %', k; end if; end loop; end if;
  v := public.run_report('production-recalls', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['recall_no','date','batch_no','product','reason','status','customers','supplied','recovered','recovered_pct'] loop if not (v -> 0) ? k then raise exception 'FAIL - production-recalls has no column %', k; end if; end loop; end if;
  v := public.run_report('finance-expenses', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['category','expenses','net','vat','total','share_pct'] loop if not (v -> 0) ? k then raise exception 'FAIL - finance-expenses has no column %', k; end if; end loop; end if;
  v := public.run_report('finance-shop-balances', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['shop','operating_model','sales_net','settled_expected','settled_received','commission','settled_up_to','dealer_owes'] loop if not (v -> 0) ? k then raise exception 'FAIL - finance-shop-balances has no column %', k; end if; end loop; end if;
  v := public.run_report('finance-deposits', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['bottle_type','customers','bottles','amount','taken_in_period','released_in_period'] loop if not (v -> 0) ? k then raise exception 'FAIL - finance-deposits has no column %', k; end if; end loop; end if;
  v := public.run_report('complaints-by-category', jsonb_build_object('from', (app.today() - 400)::text, 'to', (app.today() + 1)::text, 'company_id', co, 'days', 1));
  if jsonb_array_length(v) > 0 then foreach k in array array['category','logged','resolved','open','within_sla_pct','avg_hours'] loop if not (v -> 0) ? k then raise exception 'FAIL - complaints-by-category has no column %', k; end if; end loop; end if;
  raise notice 'ok - report columns match the screens'; end $$;
reset role;

do $$ begin raise notice 'ALL PHASE 3C DATABASE TESTS PASSED'; end $$;
