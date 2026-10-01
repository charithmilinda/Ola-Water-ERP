-- =====================================================================
-- OLA Water ERP — Phase 2A
-- 0021: production batches, process stages, material consumption,
--       bottle traceability, quality control, release, recalls
-- =====================================================================
-- Flow: plan → start → stages → complete (materials consumed, stock enters
-- QC hold) → QC tests → release (sellable) or reject (quarantine) →
-- dispose. A released batch can be recalled: stock is pulled back into
-- quarantine and everyone who received it is listed for recovery.
-- =====================================================================

-- Process stages recorded against a batch
create table public.production_stage_logs (
  id           uuid primary key default gen_random_uuid(),
  batch_id     uuid not null references public.production_batches(id),
  stage        text not null check (stage in ('raw_water','filtration','ro','uv','ozone','storage','washing','filling',
                                              'capping','labelling','finished')),
  recorded_at  timestamptz not null default now(),
  recorded_by  uuid,
  reading      text,
  notes        text
);
create index production_stage_logs_batch_idx on public.production_stage_logs (batch_id, recorded_at);
create trigger production_stage_logs_audit after insert on public.production_stage_logs for each row execute function app.audit_row('production');

-- Materials actually used by a batch
create table public.production_batch_materials (
  batch_id     uuid not null references public.production_batches(id),
  material_id  uuid not null references public.products(id),
  qty          numeric(14,3) not null check (qty > 0),
  unit_cost    numeric(14,4) not null,
  primary key (batch_id, material_id)
);

-- Which labelled bottles were filled in which batch
create table public.production_batch_bottles (
  batch_id   uuid not null references public.production_batches(id),
  bottle_id  uuid not null references public.bottles(id),
  filled_at  timestamptz not null default now(),
  primary key (batch_id, bottle_id)
);
create index production_batch_bottles_bottle_idx on public.production_batch_bottles (bottle_id);
alter table public.bottles add column last_batch_id uuid references public.production_batches(id);

-- ---------------------------------------------------------------------
-- QC templates and tests
-- ---------------------------------------------------------------------
create table public.qc_templates (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique check (code ~ '^[A-Z0-9-]{2,20}$'),
  name         text not null,
  product_id   uuid references public.products(id),
  description  text,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
comment on column public.qc_templates.product_id is 'Empty = can be used for any product';
create trigger qc_templates_touch before update on public.qc_templates for each row execute function app.touch_updated_at();
create trigger qc_templates_audit after insert or update on public.qc_templates for each row execute function app.audit_row('qc');

create table public.qc_template_parameters (
  id           uuid primary key default gen_random_uuid(),
  template_id  uuid not null references public.qc_templates(id),
  sort_order   integer not null default 0,
  name         text not null,
  unit         text,
  value_type   text not null default 'number' check (value_type in ('number','pass_fail','text')),
  min_value    numeric,
  max_value    numeric,
  is_required  boolean not null default true,
  check (min_value is null or max_value is null or min_value <= max_value)
);
create index qc_template_parameters_template_idx on public.qc_template_parameters (template_id, sort_order);
create trigger qc_template_parameters_audit after insert or update or delete on public.qc_template_parameters
  for each row execute function app.audit_row('qc');

create table public.qc_tests (
  id                uuid primary key default gen_random_uuid(),
  test_no           text not null unique,
  batch_id          uuid not null references public.production_batches(id),
  template_id       uuid not null references public.qc_templates(id),
  tested_at         timestamptz not null default now(),
  tested_by         uuid,
  sample_ref        text,
  lab_name          text,
  result            text not null check (result in ('pass','fail')),
  notes             text,
  certificate_path  text,
  created_at        timestamptz not null default now(),
  client_txn_id     uuid unique
);
create index qc_tests_batch_idx on public.qc_tests (batch_id, tested_at desc);
create trigger qc_tests_audit after insert on public.qc_tests for each row execute function app.audit_row('qc');
create trigger qc_tests_append_only before update or delete on public.qc_tests for each row execute function app.forbid_change();

create table public.qc_test_results (
  id              bigint generated always as identity primary key,
  test_id         uuid not null references public.qc_tests(id),
  sort_order      integer not null default 0,
  parameter_name  text not null,
  unit            text,
  value_type      text not null,
  min_value       numeric,
  max_value       numeric,
  is_required     boolean not null,
  value_num       numeric,
  value_text      text,
  passed          boolean not null
);
comment on table public.qc_test_results is 'Each result keeps a copy of the limits used, so later template changes never alter past results';
create index qc_test_results_test_idx on public.qc_test_results (test_id, sort_order);
create trigger qc_test_results_append_only before update or delete on public.qc_test_results for each row execute function app.forbid_change();

-- ---------------------------------------------------------------------
-- Recalls
-- ---------------------------------------------------------------------
create table public.batch_recalls (
  id           uuid primary key default gen_random_uuid(),
  recall_no    text not null unique,
  batch_id     uuid not null references public.production_batches(id),
  reason       text not null,
  status       text not null default 'open' check (status in ('open','closed')),
  created_at   timestamptz not null default now(),
  created_by   uuid,
  closed_at    timestamptz,
  closed_by    uuid,
  close_note   text,
  updated_at   timestamptz not null default now(),
  client_txn_id uuid unique
);
create unique index batch_recalls_one_open on public.batch_recalls (batch_id) where status = 'open';
create trigger batch_recalls_touch before update on public.batch_recalls for each row execute function app.touch_updated_at();
create trigger batch_recalls_audit after insert or update on public.batch_recalls for each row execute function app.audit_row('qc');

-- Customers who received the batch (stock at locations is listed live)
create table public.batch_recall_customers (
  id             uuid primary key default gen_random_uuid(),
  recall_id      uuid not null references public.batch_recalls(id),
  customer_id    uuid not null references public.customers(id),
  qty_supplied   numeric(14,3) not null default 0,
  bottles_held   integer not null default 0,
  qty_recovered  numeric(14,3) not null default 0 check (qty_recovered >= 0),
  status         text not null default 'open' check (status in ('open','contacted','recovered','not_recoverable')),
  note           text,
  updated_at     timestamptz not null default now(),
  unique (recall_id, customer_id)
);
create trigger batch_recall_customers_touch before update on public.batch_recall_customers for each row execute function app.touch_updated_at();
create trigger batch_recall_customers_audit after insert or update on public.batch_recall_customers for each row execute function app.audit_row('qc');

-- ---------------------------------------------------------------------
-- Production lines
-- ---------------------------------------------------------------------
create or replace function public.save_production_line(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; v_loc uuid := app.juuid(p, 'location_id');
begin
  perform app.require_permission('production.manage');
  if not exists (select 1 from public.locations where id = v_loc and location_type = 'warehouse') then
    raise exception 'A production line must sit at a warehouse / plant location' using errcode = '22023';
  end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    insert into public.production_lines (code, name, location_id, notes)
    values (upper(trim(app.jtext(p, 'code'))), trim(app.jtext(p, 'name')), v_loc, app.jtext(p, 'notes')) returning id into v;
  else
    update public.production_lines set name = trim(app.jtext(p, 'name')), location_id = v_loc, notes = app.jtext(p, 'notes'),
           is_active = app.jbool(p, 'is_active', true)
     where id = p_id returning id into v;
    if v is null then raise exception 'Line not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Batches
-- ---------------------------------------------------------------------
create or replace function public.plan_production_batch(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; pr public.products; ln public.production_lines; v uuid := gen_random_uuid(); v_no text; v_res jsonb;
        v_date date := coalesce((app.jtext(p, 'production_date'))::date, app.today());
begin
  perform app.require_permission('production.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'plan_production_batch');
  if v_done is not null then return v_done; end if;
  select * into pr from public.products where id = app.juuid(p, 'product_id');
  if not found or pr.item_type <> 'finished_good' or not pr.is_active then raise exception 'Choose a product to produce' using errcode = '22023'; end if;
  select * into ln from public.production_lines where id = app.juuid(p, 'line_id') and is_active;
  if not found then raise exception 'Choose a production line' using errcode = '22023'; end if;
  if coalesce(app.jint(p, 'planned_qty'), 0) <= 0 then raise exception 'Enter the planned quantity' using errcode = '22023'; end if;
  perform app.set_context(null, p_client_txn_id, 'plan');
  v_no := app.next_document_number('BAT', ln.location_id, v_date);
  insert into public.production_batches (id, batch_no, product_id, line_id, location_id, production_date, shift, planned_qty,
    operator_name, notes, created_by, client_txn_id)
  values (v, v_no, pr.id, ln.id, ln.location_id, v_date, coalesce(app.jtext(p, 'shift'), 'day'), app.jint(p, 'planned_qty'),
    app.jtext(p, 'operator_name'), app.jtext(p, 'notes'), app.current_user_id(), p_client_txn_id);
  v_res := jsonb_build_object('batch_id', v, 'batch_no', v_no);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.start_production_batch(p_batch uuid, p_operator text)
returns void language plpgsql security definer set search_path = '' as $$
declare b public.production_batches;
begin
  perform app.require_permission('production.manage');
  select * into b from public.production_batches where id = p_batch for update;
  if not found then raise exception 'Batch not found' using errcode = 'P0002'; end if;
  if b.status <> 'planned' then raise exception 'This batch has already started' using errcode = '22023'; end if;
  perform app.set_context(null, null, 'start');
  update public.production_batches set status = 'in_production', started_at = now(),
         operator_name = coalesce(nullif(trim(p_operator), ''), operator_name) where id = p_batch;
end $$;

create or replace function public.cancel_production_batch(p_batch uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare b public.production_batches;
begin
  perform app.require_permission('production.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'Give a reason' using errcode = '22023'; end if;
  select * into b from public.production_batches where id = p_batch for update;
  if not found then raise exception 'Batch not found' using errcode = 'P0002'; end if;
  if b.status not in ('planned','in_production') then raise exception 'Only a batch that is not finished can be cancelled' using errcode = '22023'; end if;
  perform app.set_context(trim(p_reason), null, 'cancel');
  update public.production_batches set status = 'cancelled', decision_note = trim(p_reason) where id = p_batch;
end $$;

create or replace function public.record_production_stage(p_batch uuid, p_stage text, p_reading text, p_notes text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare b public.production_batches; v uuid;
begin
  perform app.require_permission('production.manage');
  select * into b from public.production_batches where id = p_batch;
  if not found then raise exception 'Batch not found' using errcode = 'P0002'; end if;
  if b.status not in ('planned','in_production') then raise exception 'Stages are recorded while the batch is in production' using errcode = '22023'; end if;
  insert into public.production_stage_logs (batch_id, stage, recorded_by, reading, notes)
  values (p_batch, p_stage, app.current_user_id(), nullif(trim(p_reading), ''), nullif(trim(p_notes), '')) returning id into v;
  if b.status = 'planned' then update public.production_batches set status = 'in_production', started_at = now() where id = p_batch; end if;
  return v;
end $$;

-- Finish production: consume materials, fill bottles, put the output on QC hold
--   p: {produced_qty, rejected_qty, wastage_qty, wastage_note, operator_name,
--       materials: [{material_id, qty}]  (empty = use the bill of materials),
--       bottle_codes: ['OLA-BTL-...']    (optional, returnable products)}
create or replace function public.complete_production_batch(p_batch uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; b public.production_batches; pr public.products; m public.products; bt public.bottles; l jsonb; v_code text;
  v_good integer := coalesce(app.jint(p, 'produced_qty'), -1); v_rej integer := coalesce(app.jint(p, 'rejected_qty'), 0);
  v_qty numeric; v_cost numeric := 0; v_unit numeric; v_scanned integer := 0; v_empties integer; v_res jsonb; v_mats jsonb;
  v_warn text[] := '{}';
begin
  perform app.require_permission('production.manage');
  if v_good < 0 or v_rej < 0 then raise exception 'Enter the good and rejected quantities' using errcode = '22023'; end if;
  if v_good + v_rej = 0 then raise exception 'Nothing was produced — cancel the batch instead' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'complete_production_batch');
  if v_done is not null then return v_done; end if;
  select * into b from public.production_batches where id = p_batch for update;
  if not found then raise exception 'Batch not found' using errcode = 'P0002'; end if;
  if b.status not in ('planned','in_production') then raise exception 'This batch is already finished' using errcode = '22023'; end if;
  select * into pr from public.products where id = b.product_id;
  perform app.set_context(null, p_client_txn_id, 'complete');

  -- materials: as entered, else the bill of materials for good + rejected units
  v_mats := coalesce(p -> 'materials', '[]'::jsonb);
  if jsonb_array_length(v_mats) = 0 then
    select coalesce(jsonb_agg(jsonb_build_object('material_id', material_id, 'qty', round(qty_per_unit * (v_good + v_rej), 3))), '[]')
      into v_mats from public.product_materials where product_id = pr.id;
  end if;
  for l in select * from jsonb_array_elements(v_mats) loop
    v_qty := app.jnum(l, 'qty');
    continue when coalesce(v_qty, 0) <= 0;
    select * into m from public.products where id = app.juuid(l, 'material_id');
    if not found or m.item_type = 'finished_good' then raise exception 'Unknown material' using errcode = '22023'; end if;
    perform app.stock_move('consume', m.id, v_qty, b.location_id, null, 'production_batch', b.id, 'Used in ' || b.batch_no);
    insert into public.production_batch_materials (batch_id, material_id, qty, unit_cost) values (b.id, m.id, v_qty, m.cost_price)
    on conflict (batch_id, material_id) do update set qty = public.production_batch_materials.qty + excluded.qty;
    v_cost := v_cost + v_qty * m.cost_price;
  end loop;
  v_cost := round(v_cost, 2);

  -- returnable bottles: scanned ones are traced to the batch, the rest are filled by count
  if pr.is_returnable and v_good > 0 then
    for v_code in select distinct upper(trim(x)) from jsonb_array_elements_text(coalesce(p -> 'bottle_codes', '[]')) x where trim(x) <> '' loop
      bt := app.bottle_by_code(v_code);
      if bt.id is null then raise exception 'Unknown bottle label %', v_code using errcode = 'P0002'; end if;
      if bt.company_id <> app.own_company_id() or bt.bottle_type_id <> pr.bottle_type_id then
        raise exception 'Bottle % is not an OLA % bottle', v_code, pr.name using errcode = '22023';
      end if;
      if bt.lifecycle <> 'active' or bt.condition = 'damaged' then
        raise exception 'Bottle % is % — it cannot be filled', v_code, case when bt.condition = 'damaged' then 'damaged' else bt.lifecycle end
          using errcode = '22023';
      end if;
      v_scanned := v_scanned + 1;
      if v_scanned > v_good then raise exception 'More bottles scanned than good units produced' using errcode = '22023'; end if;
      perform app.bottle_move('fill', bt.company_id, bt.bottle_type_id, 1, bt.holder_type, bt.holder_id, bt.fill_state,
        'location', b.location_id, 'full', 'production_batch', b.id, bt.id);
      update public.bottles set last_batch_no = b.batch_no, last_batch_id = b.id where id = bt.id;
      insert into public.production_batch_bottles (batch_id, bottle_id) values (b.id, bt.id);
    end loop;
    if v_good > v_scanned then
      select coalesce(qty, 0) into v_empties from public.bottle_balances
       where holder_type = 'location' and holder_id = b.location_id and company_id = app.own_company_id()
         and bottle_type_id = pr.bottle_type_id and fill_state = 'empty';
      if coalesce(v_empties, 0) < v_good - v_scanned then
        v_warn := v_warn || format('Only %s empty bottles were recorded here; the bottle count needs checking', coalesce(v_empties, 0));
      end if;
      perform app.bottle_move('fill', app.own_company_id(), pr.bottle_type_id, v_good - v_scanned,
        'location', b.location_id, 'empty', 'location', b.location_id, 'full', 'production_batch', b.id);
    end if;
  end if;

  -- output into stock, on QC hold, at the batch's cost
  if v_good > 0 then
    v_unit := case when v_cost > 0 then round(v_cost / v_good, 4) else pr.cost_price end;
    if v_cost > 0 then perform app.apply_receipt_cost(pr.id, v_good, v_unit); end if;
    perform app.stock_move('production', pr.id, v_good, null, b.location_id, 'production_batch', b.id, 'Produced ' || b.batch_no,
      'qc_hold', b.id, null, v_unit);
    if v_cost > 0 then
      perform app.post_event('production.complete', jsonb_build_object('value', v_cost), b.production_date,
        format('Production %s — %s × %s', b.batch_no, v_good, pr.name), 'production_batch', b.id, b.location_id);
    end if;
  elsif v_cost > 0 then
    perform app.post_event('production.loss', jsonb_build_object('value', v_cost), b.production_date,
      format('Production %s — all units rejected', b.batch_no), 'production_batch', b.id, b.location_id);
  end if;

  update public.production_batches set
    status = case when v_good > 0 then 'qc_hold' else 'failed' end,
    produced_qty = v_good, rejected_qty = v_rej, wastage_qty = app.jnum(p, 'wastage_qty'), wastage_note = app.jtext(p, 'wastage_note'),
    operator_name = coalesce(app.jtext(p, 'operator_name'), operator_name), started_at = coalesce(started_at, now()), ended_at = now(),
    expiry_date = case when pr.shelf_life_days is not null then production_date + pr.shelf_life_days end,
    material_cost = v_cost, unit_cost = v_unit, bottles_scanned = v_scanned,
    decision_note = case when v_good = 0 then 'All units rejected at production' else decision_note end
  where id = b.id;

  v_res := jsonb_build_object('batch_no', b.batch_no, 'produced', v_good, 'material_cost', v_cost, 'unit_cost', v_unit,
                              'bottles_scanned', v_scanned, 'warnings', to_jsonb(v_warn));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- QC
-- ---------------------------------------------------------------------
create or replace function public.save_qc_template(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; l jsonb; n integer := 0;
begin
  perform app.require_permission('qc.manage');
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    insert into public.qc_templates (code, name, product_id, description)
    values (upper(trim(app.jtext(p, 'code'))), trim(app.jtext(p, 'name')), app.juuid(p, 'product_id'), app.jtext(p, 'description'))
    returning id into v;
  else
    update public.qc_templates set name = trim(app.jtext(p, 'name')), product_id = app.juuid(p, 'product_id'),
           description = app.jtext(p, 'description'), is_active = app.jbool(p, 'is_active', true)
     where id = p_id returning id into v;
    if v is null then raise exception 'Template not found' using errcode = 'P0002'; end if;
    delete from public.qc_template_parameters where template_id = v;
  end if;
  for l in select * from jsonb_array_elements(coalesce(p -> 'parameters', '[]')) loop
    continue when nullif(trim(app.jtext(l, 'name')), '') is null;
    n := n + 1;
    insert into public.qc_template_parameters (template_id, sort_order, name, unit, value_type, min_value, max_value, is_required)
    values (v, n, trim(app.jtext(l, 'name')), nullif(trim(app.jtext(l, 'unit')), ''), coalesce(app.jtext(l, 'value_type'), 'number'),
            app.jnum(l, 'min_value'), app.jnum(l, 'max_value'), app.jbool(l, 'is_required', true));
  end loop;
  if n = 0 then raise exception 'Add at least one test parameter' using errcode = '22023'; end if;
  return v;
end $$;

--   p: {template_id, tested_at, sample_ref, lab_name, notes, certificate_path,
--       results: [{parameter_id, value}]}
create or replace function public.record_qc_test(p_batch uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; b public.production_batches; t public.qc_templates; prm public.qc_template_parameters; v uuid := gen_random_uuid();
  v_no text; v_val text; v_num numeric; v_ok boolean; v_res jsonb; v_failed text[] := '{}'; v_rows jsonb := '[]';
begin
  perform app.require_permission('qc.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'record_qc_test');
  if v_done is not null then return v_done; end if;
  select * into b from public.production_batches where id = p_batch for update;
  if not found then raise exception 'Batch not found' using errcode = 'P0002'; end if;
  if b.status not in ('qc_hold','failed','released','recalled') then raise exception 'Finish production before testing' using errcode = '22023'; end if;
  select * into t from public.qc_templates where id = app.juuid(p, 'template_id');
  if not found then raise exception 'Choose a test template' using errcode = '22023'; end if;
  if t.product_id is not null and t.product_id <> b.product_id then
    raise exception 'This template is for a different product' using errcode = '22023';
  end if;

  -- check every parameter; values outside the limits are flagged automatically
  for prm in select * from public.qc_template_parameters where template_id = t.id order by sort_order loop
    v_val := null;
    select nullif(trim(x ->> 'value'), '') into v_val
      from jsonb_array_elements(coalesce(p -> 'results', '[]')) x where x ->> 'parameter_id' = prm.id::text limit 1;
    v_num := null;
    if v_val is null then
      v_ok := not prm.is_required;
    elsif prm.value_type = 'number' then
      begin v_num := v_val::numeric; exception when others then raise exception '% must be a number', prm.name using errcode = '22023'; end;
      v_ok := (prm.min_value is null or v_num >= prm.min_value) and (prm.max_value is null or v_num <= prm.max_value);
    elsif prm.value_type = 'pass_fail' then
      v_ok := lower(v_val) in ('pass','passed','ok','yes','negative','absent','not detected');
    else
      v_ok := true;
    end if;
    if not v_ok then v_failed := v_failed || prm.name; end if;
    v_rows := v_rows || jsonb_build_object('sort_order', prm.sort_order, 'name', prm.name, 'unit', prm.unit, 'value_type', prm.value_type,
      'min', prm.min_value, 'max', prm.max_value, 'required', prm.is_required, 'num', v_num, 'text', v_val, 'ok', v_ok);
  end loop;

  perform app.set_context(null, p_client_txn_id, 'qc_test');
  v_no := app.next_document_number('QCT', b.location_id);
  insert into public.qc_tests (id, test_no, batch_id, template_id, tested_at, tested_by, sample_ref, lab_name, result, notes,
    certificate_path, client_txn_id)
  values (v, v_no, b.id, t.id, coalesce((app.jtext(p, 'tested_at'))::timestamptz, now()), app.current_user_id(),
    app.jtext(p, 'sample_ref'), app.jtext(p, 'lab_name'), case when cardinality(v_failed) = 0 then 'pass' else 'fail' end,
    app.jtext(p, 'notes'), app.jtext(p, 'certificate_path'), p_client_txn_id);
  insert into public.qc_test_results (test_id, sort_order, parameter_name, unit, value_type, min_value, max_value, is_required,
    value_num, value_text, passed)
  select v, (x ->> 'sort_order')::int, x ->> 'name', x ->> 'unit', x ->> 'value_type', (x ->> 'min')::numeric, (x ->> 'max')::numeric,
         (x ->> 'required')::boolean, (x ->> 'num')::numeric, x ->> 'text', (x ->> 'ok')::boolean
    from jsonb_array_elements(v_rows) x;

  v_res := jsonb_build_object('test_id', v, 'test_no', v_no, 'result', case when cardinality(v_failed) = 0 then 'pass' else 'fail' end,
                              'failed', to_jsonb(v_failed));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Move every lot of a batch from one status to another, wherever it is
create or replace function app.batch_status_move(p_batch uuid, p_txn text, p_from_status text[], p_to_status text,
  p_skip_vehicles boolean default false)
returns numeric language plpgsql security definer set search_path = '' as $$
declare lot record; v_total numeric := 0;
begin
  for lot in
    select l.location_id, l.product_id, l.stock_status, l.qty
      from public.inventory_lots l join public.locations loc on loc.id = l.location_id
     where l.batch_id = p_batch and l.qty > 0 and l.stock_status = any(p_from_status)
       and not (p_skip_vehicles and loc.location_type = 'vehicle')
     order by l.location_id
  loop
    perform app.stock_move(p_txn, lot.product_id, lot.qty, lot.location_id, lot.location_id, 'production_batch', p_batch, null,
      lot.stock_status, p_batch, p_to_status);
    v_total := v_total + lot.qty;
  end loop;
  return v_total;
end $$;

create or replace function public.release_production_batch(p_batch uuid, p_override boolean, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; b public.production_batches; v_last text; v_qty numeric; v_res jsonb;
begin
  v_done := app.idempotency_begin(p_client_txn_id, 'release_production_batch');
  if v_done is not null then return v_done; end if;
  select * into b from public.production_batches where id = p_batch for update;
  if not found then raise exception 'Batch not found' using errcode = 'P0002'; end if;
  if b.status not in ('qc_hold','failed') then raise exception 'Only a batch on QC hold or failed can be released' using errcode = '22023'; end if;
  select result into v_last from public.qc_tests where batch_id = b.id order by tested_at desc, created_at desc limit 1;

  if v_last = 'pass' and b.status = 'qc_hold' then
    if not (app.has_permission('qc.manage') or app.has_permission('qc.release')) then
      raise exception 'Permission denied: qc.manage is required' using errcode = '42501';
    end if;
  else
    if not coalesce(p_override, false) then
      raise exception '% — releasing it needs an authorised override with a reason',
        case when v_last is null then 'This batch has no QC test yet' when b.status = 'failed' then 'This batch failed QC'
             else 'The latest QC test failed' end using errcode = '22023';
    end if;
    perform app.require_permission('qc.release');
    if nullif(trim(p_reason), '') is null then raise exception 'An override needs a reason' using errcode = '22023'; end if;
  end if;
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'QC passed'), p_client_txn_id,
    case when coalesce(p_override, false) and not (v_last = 'pass' and b.status = 'qc_hold') then 'qc_override_release' else 'qc_release' end);

  v_qty := app.batch_status_move(b.id, 'qc_release', array['qc_hold','quarantine'], 'available');
  update public.production_batches set status = 'released', released_at = now(), released_by = app.current_user_id(),
         release_override = coalesce(p_override, false) and not (v_last = 'pass' and b.status = 'qc_hold'),
         decision_note = nullif(trim(p_reason), '')
   where id = b.id;
  v_res := jsonb_build_object('released_qty', v_qty, 'override', coalesce(p_override, false) and not (v_last = 'pass' and b.status = 'qc_hold'));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.reject_production_batch(p_batch uuid, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; b public.production_batches; v_qty numeric; v_res jsonb;
begin
  perform app.require_permission('qc.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'Give a reason' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'reject_production_batch');
  if v_done is not null then return v_done; end if;
  select * into b from public.production_batches where id = p_batch for update;
  if not found then raise exception 'Batch not found' using errcode = 'P0002'; end if;
  if b.status <> 'qc_hold' then raise exception 'Only a batch on QC hold can be failed' using errcode = '22023'; end if;
  perform app.set_context(trim(p_reason), p_client_txn_id, 'qc_reject');
  v_qty := app.batch_status_move(b.id, 'qc_reject', array['qc_hold'], 'quarantine');
  update public.production_batches set status = 'failed', decision_note = trim(p_reason) where id = b.id;
  v_res := jsonb_build_object('quarantined_qty', v_qty);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Destroy quarantined (failed / recalled) stock
create or replace function public.dispose_quarantined_stock(p_batch uuid, p_location uuid, p_qty numeric, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; b public.production_batches; pr public.products; v_res jsonb; v_value numeric;
begin
  if not (app.has_permission('qc.release') or app.has_permission('inventory.adjust')) then
    raise exception 'Permission denied: qc.release or inventory.adjust is required' using errcode = '42501';
  end if;
  if nullif(trim(p_reason), '') is null then raise exception 'Give a reason' using errcode = '22023'; end if;
  if coalesce(p_qty, 0) <= 0 then raise exception 'Enter the quantity destroyed' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'dispose_quarantined_stock');
  if v_done is not null then return v_done; end if;
  select * into b from public.production_batches where id = p_batch;
  if not found then raise exception 'Batch not found' using errcode = 'P0002'; end if;
  select * into pr from public.products where id = b.product_id;
  perform app.set_context(trim(p_reason), p_client_txn_id, 'dispose');
  v_value := round(p_qty * coalesce(b.unit_cost, pr.cost_price), 2);
  perform app.stock_move('dispose', pr.id, p_qty, p_location, null, 'production_batch', b.id, null, 'quarantine', b.id, null,
    coalesce(b.unit_cost, pr.cost_price));
  if pr.is_returnable then
    -- the water is poured away; the bottles go back to the empties
    perform app.bottle_move('adjust', app.own_company_id(), pr.bottle_type_id, p_qty::integer, 'location', p_location, 'full',
      'location', p_location, 'empty', 'production_batch', b.id);
  end if;
  if v_value > 0 then
    perform app.post_event('stock.qc_writeoff', jsonb_build_object('value', v_value), app.today(),
      format('Destroyed %s × %s from %s', p_qty, pr.name, b.batch_no), 'production_batch', b.id, p_location);
  end if;
  v_res := jsonb_build_object('disposed', p_qty, 'value', v_value);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- Recalls
-- ---------------------------------------------------------------------
-- Customers who received units of a batch (deliveries and till sales), net of recovery
create or replace function app.batch_customers(p_batch uuid)
returns table (customer_id uuid, qty numeric) language sql stable security definer set search_path = '' as $$
  select c.customer_id, sum(t.qty)
    from public.inventory_transactions t
    cross join lateral (
      select case t.reference_type
               when 'delivery' then (select d.customer_id from public.deliveries d where d.id = t.reference_id)
               when 'pos_sale' then (select s.customer_id from public.pos_sales s where s.id = t.reference_id)
             end as customer_id) c
   where t.batch_id = p_batch and t.txn_type = 'sale' and c.customer_id is not null
   group by c.customer_id
$$;

create or replace function public.secure_recalled_stock(p_recall uuid)
returns numeric language plpgsql security definer set search_path = '' as $$
declare r public.batch_recalls; v numeric;
begin
  if not (app.has_permission('qc.release') or app.has_permission('qc.manage')) then
    raise exception 'Permission denied: qc.manage is required' using errcode = '42501';
  end if;
  select * into r from public.batch_recalls where id = p_recall;
  if not found or r.status <> 'open' then raise exception 'Open recall not found' using errcode = 'P0002'; end if;
  perform app.set_context('Recall ' || r.recall_no, null, 'recall_hold');
  -- stock on a vehicle is brought back at check-in and caught by the next sweep
  v := app.batch_status_move(r.batch_id, 'recall_hold', array['available','qc_hold'], 'quarantine', true);
  return v;
end $$;

create or replace function public.recall_production_batch(p_batch uuid, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; b public.production_batches; v uuid := gen_random_uuid(); v_no text; v_res jsonb; v_secured numeric; v_cust integer;
begin
  perform app.require_permission('qc.release');
  if nullif(trim(p_reason), '') is null then raise exception 'Give the reason for the recall' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'recall_production_batch');
  if v_done is not null then return v_done; end if;
  select * into b from public.production_batches where id = p_batch for update;
  if not found then raise exception 'Batch not found' using errcode = 'P0002'; end if;
  if b.status not in ('released','qc_hold') then raise exception 'Only a released or held batch can be recalled' using errcode = '22023'; end if;
  perform app.set_context(trim(p_reason), p_client_txn_id, 'recall');
  v_no := app.next_document_number('RCL', b.location_id);
  insert into public.batch_recalls (id, recall_no, batch_id, reason, created_by, client_txn_id)
  values (v, v_no, b.id, trim(p_reason), app.current_user_id(), p_client_txn_id);
  update public.production_batches set status = 'recalled', decision_note = trim(p_reason) where id = b.id;

  insert into public.batch_recall_customers (recall_id, customer_id, qty_supplied, bottles_held)
  select v, x.customer_id, sum(x.qty), sum(x.bottles)
    from (select customer_id, qty, 0 as bottles from app.batch_customers(b.id)
          union all
          select bo.holder_id, 0, 1 from public.bottles bo
           where bo.last_batch_id = b.id and bo.holder_type = 'customer' and bo.lifecycle = 'active') x
   group by x.customer_id;
  get diagnostics v_cust = row_count;

  v_secured := app.batch_status_move(b.id, 'recall_hold', array['available','qc_hold'], 'quarantine', true);
  v_res := jsonb_build_object('recall_id', v, 'recall_no', v_no, 'secured_qty', v_secured, 'customers', v_cust);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- Units brought back from a customer go into quarantine at the batch's plant
create or replace function public.record_recall_recovery(p_item uuid, p_qty numeric, p_status text, p_note text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; it public.batch_recall_customers; r public.batch_recalls; b public.production_batches; v_res jsonb;
begin
  if not (app.has_permission('qc.manage') or app.has_permission('qc.release')) then
    raise exception 'Permission denied: qc.manage is required' using errcode = '42501';
  end if;
  if p_status not in ('open','contacted','recovered','not_recoverable') then raise exception 'Unknown status' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'record_recall_recovery');
  if v_done is not null then return v_done; end if;
  select * into it from public.batch_recall_customers where id = p_item for update;
  if not found then raise exception 'Recall line not found' using errcode = 'P0002'; end if;
  select * into r from public.batch_recalls where id = it.recall_id;
  if r.status <> 'open' then raise exception 'This recall is closed' using errcode = '22023'; end if;
  select * into b from public.production_batches where id = r.batch_id;
  perform app.set_context(coalesce(nullif(trim(p_note), ''), 'Recall follow-up'), p_client_txn_id, 'recall_recovery');
  if coalesce(p_qty, 0) > 0 then
    perform app.stock_move('recall_return', b.product_id, p_qty, null, b.location_id, 'batch_recall', r.id,
      'Recovered from customer', 'quarantine', b.id);
  end if;
  update public.batch_recall_customers set qty_recovered = qty_recovered + coalesce(p_qty, 0), status = p_status,
         note = coalesce(nullif(trim(p_note), ''), note)
   where id = p_item;
  v_res := jsonb_build_object('ok', true);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.close_batch_recall(p_recall uuid, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.batch_recalls;
begin
  perform app.require_permission('qc.release');
  if nullif(trim(p_note), '') is null then raise exception 'Summarise how the recall ended' using errcode = '22023'; end if;
  select * into r from public.batch_recalls where id = p_recall for update;
  if not found or r.status <> 'open' then raise exception 'Open recall not found' using errcode = 'P0002'; end if;
  perform app.set_context(trim(p_note), null, 'close_recall');
  update public.batch_recalls set status = 'closed', closed_at = now(), closed_by = app.current_user_id(), close_note = trim(p_note)
   where id = p_recall;
end $$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.production_stage_logs       enable row level security;
alter table public.production_batch_materials  enable row level security;
alter table public.production_batch_bottles    enable row level security;
alter table public.qc_templates                enable row level security;
alter table public.qc_template_parameters      enable row level security;
alter table public.qc_tests                    enable row level security;
alter table public.qc_test_results             enable row level security;
alter table public.batch_recalls               enable row level security;
alter table public.batch_recall_customers      enable row level security;

create policy production_stage_logs_read on public.production_stage_logs for select to authenticated
  using (app.has_permission('production.view') or app.has_permission('qc.view'));
create policy production_batch_materials_read on public.production_batch_materials for select to authenticated
  using (app.has_permission('production.view') or app.has_permission('qc.view'));
create policy production_batch_bottles_read on public.production_batch_bottles for select to authenticated
  using (app.has_permission('production.view') or app.has_permission('qc.view') or app.has_permission('bottles.view'));
create policy qc_templates_read on public.qc_templates for select to authenticated
  using (app.has_permission('qc.view') or app.has_permission('production.view'));
create policy qc_template_parameters_read on public.qc_template_parameters for select to authenticated
  using (app.has_permission('qc.view') or app.has_permission('production.view'));
create policy qc_tests_read on public.qc_tests for select to authenticated
  using (app.has_permission('qc.view') or app.has_permission('production.view'));
create policy qc_test_results_read on public.qc_test_results for select to authenticated
  using (app.has_permission('qc.view') or app.has_permission('production.view'));
create policy batch_recalls_read on public.batch_recalls for select to authenticated
  using (app.has_permission('qc.view') or app.has_permission('production.view'));
create policy batch_recall_customers_read on public.batch_recall_customers for select to authenticated
  using (app.has_permission('qc.view'));
revoke insert, update, delete, truncate on public.qc_tests, public.qc_test_results from anon, authenticated, service_role;
