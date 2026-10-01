-- OLA Water ERP — Phase 2A database update (production, quality control, materials, purchasing)
-- Run ONCE in Supabase → SQL Editor → New query, on the database that already has Phase 1B.
-- It runs as one transaction: if anything fails, nothing is changed.
begin;

-- >>> 20261004000020_items_lots_costing.sql
-- =====================================================================
-- OLA Water ERP — Phase 2A
-- 0020: materials as stock items, QC stock statuses, production batches,
--       batch (lot) tracking on every stock movement, weighted average cost
-- =====================================================================
-- * Raw materials, packaging, chemicals, spare parts and consumables live in
--   the same `products` table (item_type <> 'finished_good') so they use the
--   same stock ledger, counts and transfers. Only finished goods can be sold.
-- * Stock statuses: available (sellable), damaged, qc_hold (new production
--   waiting for QC), quarantine (failed or recalled). Every sale, pick,
--   transfer and load-out takes only 'available' stock, so held or failed
--   stock can never be sold.
-- * inventory_lots splits every balance by production batch. Movements take
--   the oldest batch first (FIFO) unless a batch is named, and every ledger
--   row records its batch — this is what powers recalls.
-- * products.cost_price becomes a weighted average cost, updated by goods
--   received and by production.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------
alter table public.products
  add column item_type text not null default 'finished_good'
    check (item_type in ('finished_good','raw_material','packaging','chemical','consumable','spare_part')),
  add column reorder_level numeric(14,3) not null default 0 check (reorder_level >= 0),
  add column shelf_life_days integer check (shelf_life_days is null or shelf_life_days > 0);
alter table public.products alter column cost_price type numeric(14,4);
alter table public.products drop constraint if exists products_unit_check;
alter table public.products add constraint products_unit_check
  check (unit in ('bottle','case','pack','unit','piece','kg','g','litre','ml','roll','box','metre','set'));
alter table public.products add constraint products_material_not_returnable
  check (item_type = 'finished_good' or not is_returnable);
comment on column public.products.item_type is 'finished_good = sold to customers; everything else is a material used by production or the business';
comment on column public.products.cost_price is 'Weighted average cost per unit (updated by goods received and production)';
comment on column public.products.reorder_level is 'Alert when total available stock falls to or below this';

-- Bill of materials: what one unit of a finished good uses
create table public.product_materials (
  product_id    uuid not null references public.products(id),
  material_id   uuid not null references public.products(id),
  qty_per_unit  numeric(14,4) not null check (qty_per_unit > 0),
  primary key (product_id, material_id),
  check (product_id <> material_id)
);
create trigger product_materials_audit after insert or update or delete on public.product_materials
  for each row execute function app.audit_row('production');

-- ---------------------------------------------------------------------
-- Stock statuses and ledger columns
-- ---------------------------------------------------------------------
alter table public.inventory_balances drop constraint if exists inventory_balances_stock_status_check;
alter table public.inventory_balances add constraint inventory_balances_stock_status_check
  check (stock_status in ('available','damaged','qc_hold','quarantine'));

alter table public.inventory_transactions drop constraint if exists inventory_transactions_txn_type_check;
alter table public.inventory_transactions add constraint inventory_transactions_txn_type_check
  check (txn_type in ('opening','receipt','transfer','load_out','check_in','sale','adjust_gain','adjust_loss','damaged','return',
                      'production','consume','qc_release','qc_reject','recall_hold','recall_return','dispose',
                      'purchase_receipt'));
alter table public.inventory_transactions
  add column to_status text,
  add column batch_id uuid;
comment on column public.inventory_transactions.stock_status is 'Status the stock left (or entered, for receipts)';
comment on column public.inventory_transactions.to_status is 'Status the stock entered when it changed status (QC release, quarantine)';

-- ---------------------------------------------------------------------
-- Production lines and batches (QC and recall logic in 0021)
-- ---------------------------------------------------------------------
create table public.production_lines (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique check (code ~ '^[A-Z0-9-]{2,12}$'),
  name         text not null check (length(trim(name)) > 0),
  location_id  uuid not null references public.locations(id),
  notes        text,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create trigger production_lines_touch before update on public.production_lines for each row execute function app.touch_updated_at();
create trigger production_lines_audit after insert or update on public.production_lines for each row execute function app.audit_row('production');

create table public.production_batches (
  id               uuid primary key default gen_random_uuid(),
  batch_no         text not null unique,
  product_id       uuid not null references public.products(id),
  line_id          uuid not null references public.production_lines(id),
  location_id      uuid not null references public.locations(id),
  production_date  date not null,
  shift            text not null default 'day' check (shift in ('morning','day','evening','night')),
  status           text not null default 'planned' check (status in
                     ('planned','in_production','qc_hold','released','failed','recalled','cancelled')),
  planned_qty      integer not null check (planned_qty > 0),
  produced_qty     integer check (produced_qty >= 0),
  rejected_qty     integer check (rejected_qty >= 0),
  wastage_qty      numeric(14,3) check (wastage_qty >= 0),
  wastage_note     text,
  operator_name    text,
  started_at       timestamptz,
  ended_at         timestamptz,
  expiry_date      date,
  material_cost    numeric(16,2),
  unit_cost        numeric(14,4),
  bottles_scanned  integer not null default 0,
  released_at      timestamptz,
  released_by      uuid,
  release_override boolean not null default false,
  decision_note    text,
  notes            text,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  client_txn_id    uuid unique
);
create index production_batches_status_idx on public.production_batches (status, production_date desc);
create index production_batches_product_idx on public.production_batches (product_id, production_date desc);
create trigger production_batches_touch before update on public.production_batches for each row execute function app.touch_updated_at();
create trigger production_batches_audit after insert or update on public.production_batches for each row execute function app.audit_row('production');

alter table public.inventory_transactions
  add constraint inventory_transactions_batch_fk foreign key (batch_id) references public.production_batches(id);
create index inventory_transactions_batch_idx on public.inventory_transactions (batch_id) where batch_id is not null;

-- ---------------------------------------------------------------------
-- Lots: balance per location / item / status / batch
-- ---------------------------------------------------------------------
create table public.inventory_lots (
  id            uuid primary key default gen_random_uuid(),
  location_id   uuid not null references public.locations(id),
  product_id    uuid not null references public.products(id),
  stock_status  text not null,
  batch_id      uuid references public.production_batches(id),
  qty           numeric(14,3) not null default 0 check (qty >= 0),
  received_at   timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint inventory_lots_key unique nulls not distinct (location_id, product_id, stock_status, batch_id)
);
create index inventory_lots_batch_idx on public.inventory_lots (batch_id) where batch_id is not null;
comment on table public.inventory_lots is 'Splits inventory_balances by production batch. Stock that existed before batches (or bought in) has no batch.';

insert into public.inventory_lots (location_id, product_id, stock_status, batch_id, qty, received_at)
select location_id, product_id, stock_status, null, qty, updated_at from public.inventory_balances where qty > 0;

-- ---------------------------------------------------------------------
-- The stock ledger: one place where stock moves
-- ---------------------------------------------------------------------
drop function if exists app.stock_move(text, uuid, numeric, uuid, uuid, text, uuid, text, text);

create or replace function app.stock_move(
  p_txn_type text, p_product uuid, p_qty numeric, p_from uuid, p_to uuid,
  p_ref_type text default null, p_ref_id uuid default null, p_reason text default null,
  p_status text default 'available', p_batch uuid default null, p_to_status text default null,
  p_unit_cost numeric default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_have numeric; v_loc text; pr public.products; v_to_status text := coalesce(p_to_status, p_status);
  v_left numeric := p_qty; v_take numeric; lot record; v_portions jsonb := '[]'; v_p jsonb; v_cost numeric; v_bno text;
begin
  if p_qty is null or p_qty = 0 then return; end if;
  if p_qty < 0 then raise exception 'Quantity cannot be negative' using errcode = '22023'; end if;
  select * into pr from public.products where id = p_product;
  if not found then raise exception 'Item not found' using errcode = 'P0002'; end if;
  if p_txn_type = 'sale' and pr.item_type <> 'finished_good' then
    raise exception '% is a material, not a product for sale', pr.name using errcode = '22023';
  end if;
  v_cost := coalesce(p_unit_cost, pr.cost_price);

  if p_from is not null then
    select qty into v_have from public.inventory_balances
     where location_id = p_from and product_id = p_product and stock_status = p_status for update;
    if coalesce(v_have, 0) < p_qty then
      select name into v_loc from public.locations where id = p_from;
      raise exception 'Not enough %stock: % at % has %, needs %',
        case p_status when 'available' then '' else replace(p_status, '_', ' ') || ' ' end,
        pr.name, v_loc, coalesce(v_have, 0)::numeric(14,0), p_qty::numeric(14,0)
        using errcode = 'P0001';
    end if;
    update public.inventory_balances set qty = qty - p_qty, updated_at = now()
     where location_id = p_from and product_id = p_product and stock_status = p_status;

    -- take the oldest batch first, or the named batch
    for lot in
      select l.id, l.batch_id, l.qty
        from public.inventory_lots l
        left join public.production_batches b on b.id = l.batch_id
       where l.location_id = p_from and l.product_id = p_product and l.stock_status = p_status and l.qty > 0
         and (p_batch is null or l.batch_id = p_batch)
       order by (l.batch_id is not null), b.production_date nulls first, l.received_at, l.id
       for update of l
    loop
      exit when v_left <= 0;
      v_take := least(lot.qty, v_left);
      update public.inventory_lots set qty = qty - v_take, updated_at = now() where id = lot.id;
      v_portions := v_portions || jsonb_build_object('batch', lot.batch_id, 'qty', v_take);
      v_left := v_left - v_take;
    end loop;
    if v_left > 0 then
      if p_batch is not null then
        select batch_no into v_bno from public.production_batches where id = p_batch;
        select name into v_loc from public.locations where id = p_from;
        raise exception 'Batch % has only % of % at %', v_bno, (p_qty - v_left)::numeric(14,0), pr.name, v_loc using errcode = 'P0001';
      end if;
      v_portions := v_portions || jsonb_build_object('batch', null, 'qty', v_left);  -- lots out of step: keep the ledger whole
    end if;
  else
    v_portions := jsonb_build_array(jsonb_build_object('batch', p_batch, 'qty', p_qty));
  end if;

  if p_to is not null then
    insert into public.inventory_balances (location_id, product_id, stock_status, qty)
    values (p_to, p_product, v_to_status, p_qty)
    on conflict (location_id, product_id, stock_status) do update set qty = public.inventory_balances.qty + excluded.qty, updated_at = now();
  end if;

  for v_p in select * from jsonb_array_elements(v_portions) loop
    if p_to is not null then
      insert into public.inventory_lots (location_id, product_id, stock_status, batch_id, qty)
      values (p_to, p_product, v_to_status, (v_p ->> 'batch')::uuid, (v_p ->> 'qty')::numeric)
      on conflict on constraint inventory_lots_key
      do update set qty = public.inventory_lots.qty + excluded.qty, updated_at = now();
    end if;
    insert into public.inventory_transactions (txn_type, product_id, qty, from_location, to_location, stock_status, to_status,
      unit_cost, reference_type, reference_id, reason, batch_id, created_by, client_txn_id)
    values (p_txn_type, p_product, (v_p ->> 'qty')::numeric, p_from, p_to,
      case when p_from is null then v_to_status else p_status end,
      case when p_from is not null and p_to is not null and v_to_status <> p_status then v_to_status end,
      v_cost, p_ref_type, p_ref_id,
      coalesce(p_reason, nullif(current_setting('app.reason', true), '')), (v_p ->> 'batch')::uuid, app.current_user_id(),
      nullif(current_setting('app.client_txn_id', true), '')::uuid);
  end loop;
end $$;

-- Weighted average cost: call BEFORE the receipt is moved into stock
create or replace function app.apply_receipt_cost(p_product uuid, p_qty numeric, p_unit_cost numeric)
returns numeric language plpgsql security definer set search_path = '' as $$
declare v_on numeric; v_old numeric; v_new numeric;
begin
  if coalesce(p_qty, 0) <= 0 or p_unit_cost is null then return null; end if;
  select coalesce(sum(qty), 0) into v_on from public.inventory_balances where product_id = p_product;
  select cost_price into v_old from public.products where id = p_product for update;
  v_new := case when v_on <= 0 then p_unit_cost
                else round((v_on * v_old + p_qty * p_unit_cost) / (v_on + p_qty), 4) end;
  update public.products set cost_price = v_new, updated_at = now() where id = p_product;
  return v_new;
end $$;

-- Which inventory account an item sits in
create or replace function app.is_material(p_product uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select item_type <> 'finished_good' from public.products where id = p_product
$$;

-- ---------------------------------------------------------------------
-- Items: save (adds item type, reorder level, shelf life)
-- ---------------------------------------------------------------------
create or replace function public.save_product(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; v_type text := coalesce(app.jtext(p, 'item_type'), 'finished_good');
begin
  perform app.require_permission('products.manage');
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    insert into public.products (sku, name, category, size_label, unit, units_per_pack, barcode, is_returnable,
                                 bottle_type_id, tax_code, cost_price, sort_order, item_type, reorder_level, shelf_life_days)
    values (upper(app.jtext(p, 'sku')), app.jtext(p, 'name'),
            case when v_type = 'finished_good' then coalesce(app.jtext(p, 'category'), 'water') else 'other' end,
            app.jtext(p, 'size_label'), coalesce(app.jtext(p, 'unit'), case when v_type = 'finished_good' then 'bottle' else 'piece' end),
            coalesce(app.jint(p, 'units_per_pack'), 1),
            app.jtext(p, 'barcode'), v_type = 'finished_good' and app.jbool(p, 'is_returnable', false), app.juuid(p, 'bottle_type_id'),
            app.jtext(p, 'tax_code'), coalesce(app.jnum(p, 'cost_price'), 0), coalesce(app.jint(p, 'sort_order'), 0),
            v_type, coalesce(app.jnum(p, 'reorder_level'), 0), app.jint(p, 'shelf_life_days'))
    returning id into v;
  else
    update public.products set
      name = app.jtext(p, 'name'),
      category = case when v_type = 'finished_good' then coalesce(app.jtext(p, 'category'), 'water') else 'other' end,
      size_label = app.jtext(p, 'size_label'), unit = coalesce(app.jtext(p, 'unit'), unit),
      units_per_pack = coalesce(app.jint(p, 'units_per_pack'), 1), barcode = app.jtext(p, 'barcode'),
      is_returnable = v_type = 'finished_good' and app.jbool(p, 'is_returnable', false), bottle_type_id = app.juuid(p, 'bottle_type_id'),
      tax_code = app.jtext(p, 'tax_code'),
      -- the average cost only changes by hand while nothing is in stock
      cost_price = case when coalesce((select sum(qty) from public.inventory_balances b where b.product_id = p_id), 0) = 0
                        then coalesce(app.jnum(p, 'cost_price'), cost_price) else cost_price end,
      sort_order = coalesce(app.jint(p, 'sort_order'), 0), is_active = app.jbool(p, 'is_active', true),
      item_type = v_type, reorder_level = coalesce(app.jnum(p, 'reorder_level'), 0), shelf_life_days = app.jint(p, 'shelf_life_days')
    where id = p_id returning id into v;
    if v is null then raise exception 'Item not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

create or replace function public.set_bill_of_materials(p_product uuid, p_lines jsonb, p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
declare pr public.products; l jsonb; n integer := 0; m public.products;
begin
  if not (app.has_permission('products.manage') or app.has_permission('production.manage')) then
    raise exception 'Permission denied: products.manage or production.manage is required' using errcode = '42501';
  end if;
  select * into pr from public.products where id = p_product;
  if not found or pr.item_type <> 'finished_good' then raise exception 'Choose a finished product' using errcode = '22023'; end if;
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Bill of materials'), null, 'bom');
  delete from public.product_materials where product_id = p_product;
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    continue when coalesce(app.jnum(l, 'qty_per_unit'), 0) <= 0;
    select * into m from public.products where id = app.juuid(l, 'material_id');
    if not found or m.item_type = 'finished_good' then raise exception 'Only materials can go into a bill of materials' using errcode = '22023'; end if;
    insert into public.product_materials (product_id, material_id, qty_per_unit) values (p_product, m.id, app.jnum(l, 'qty_per_unit'));
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Receive stock: opening balances (any item) and, only when switched on in
-- settings or done by someone who may release QC batches, water received
-- without a production batch. Materials are bought through
-- purchase orders (goods received) from Phase 2A.
-- ---------------------------------------------------------------------
create or replace function public.receive_stock(
  p_location uuid, p_lines jsonb, p_source text, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v_line jsonb; pr public.products; v_qty numeric; v_fg numeric := 0; v_mat numeric := 0; v_res jsonb; v_cost numeric;
begin
  perform app.require_permission('inventory.manage');
  if p_source not in ('opening','receipt') then raise exception 'Unknown source' using errcode = '22023'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'receive_stock');
  if v_done is not null then return v_done; end if;
  perform app.set_context(trim(p_reason), p_client_txn_id, null);

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_qty := app.jnum(v_line, 'qty');
    continue when coalesce(v_qty, 0) = 0;
    select * into pr from public.products where id = app.juuid(v_line, 'product_id');
    if not found then raise exception 'Item not found' using errcode = 'P0002'; end if;
    if v_qty < 0 or (pr.item_type = 'finished_good' and v_qty <> trunc(v_qty)) then
      raise exception 'Quantities must be positive (whole numbers for products)' using errcode = '22023';
    end if;
    if p_source = 'receipt' then
      if pr.item_type <> 'finished_good' then
        raise exception '% is a material — receive it against a purchase order (Purchasing → Goods received)', pr.name using errcode = '22023';
      end if;
      if not coalesce((app.get_setting('production.allow_manual_receipt') #>> '{}')::boolean, false)
         and not app.has_permission('qc.release') then
        raise exception 'Water now comes into stock through a production batch and QC (Production → New batch)' using errcode = '22023';
      end if;
    end if;
    v_cost := coalesce(app.jnum(v_line, 'unit_cost'), pr.cost_price);
    if p_source = 'opening' and app.jnum(v_line, 'unit_cost') is not null then
      perform app.apply_receipt_cost(pr.id, v_qty, v_cost);
    end if;

    perform app.stock_move(p_source, pr.id, v_qty, null, p_location, 'stock_receipt', p_client_txn_id, null, 'available', null, null, v_cost);
    if pr.is_returnable then
      if p_source = 'opening' then
        perform app.bottle_move('opening', app.own_company_id(), pr.bottle_type_id, v_qty::integer,
          'outside', app.outside_id(), 'full', 'location', p_location, 'full', 'stock_receipt', p_client_txn_id);
      else
        perform app.bottle_move('fill', app.own_company_id(), pr.bottle_type_id, v_qty::integer,
          'location', p_location, 'empty', 'location', p_location, 'full', 'stock_receipt', p_client_txn_id);
      end if;
    end if;
    if pr.item_type = 'finished_good' then v_fg := v_fg + v_qty * v_cost; else v_mat := v_mat + v_qty * v_cost; end if;
  end loop;

  if p_source = 'opening' and v_fg > 0 then
    perform app.post_event('stock.opening', jsonb_build_object('value', round(v_fg, 2)), app.today(),
      'Opening stock: ' || trim(p_reason), 'stock_receipt', p_client_txn_id, p_location);
  end if;
  if p_source = 'opening' and v_mat > 0 then
    perform app.post_event('material.opening', jsonb_build_object('value', round(v_mat, 2)), app.today(),
      'Opening materials: ' || trim(p_reason), 'stock_receipt', p_client_txn_id, p_location);
  end if;

  v_res := jsonb_build_object('ok', true, 'value', round(v_fg + v_mat, 2));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- Stock counts: materials post to the raw-materials account
-- ---------------------------------------------------------------------
create or replace function public.adjust_stock(
  p_location uuid, p_product uuid, p_counted numeric, p_reason text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v_have numeric; v_diff numeric; pr public.products; v_limit numeric; v_res jsonb; v_ev text;
begin
  perform app.require_permission('inventory.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required for a stock adjustment' using errcode = '22023'; end if;
  if p_counted is null or p_counted < 0 then raise exception 'Enter the counted quantity' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'adjust_stock');
  if v_done is not null then return v_done; end if;

  select * into pr from public.products where id = p_product;
  if not found then raise exception 'Item not found' using errcode = 'P0002'; end if;
  select coalesce(qty, 0) into v_have from public.inventory_balances
   where location_id = p_location and product_id = p_product and stock_status = 'available';
  v_have := coalesce(v_have, 0);
  v_diff := p_counted - v_have;
  v_limit := coalesce((app.get_setting('approvals.stock_adjustment_qty') #>> '{}')::numeric, 0);
  if abs(v_diff) > v_limit and not app.has_permission('inventory.adjust') then
    raise exception 'Adjustments over % units need a Warehouse Manager (inventory.adjust)', v_limit using errcode = '42501';
  end if;
  perform app.set_context(trim(p_reason), p_client_txn_id, 'stock_adjustment');
  v_ev := case when pr.item_type = 'finished_good' then 'stock' else 'material' end;

  if v_diff > 0 then
    perform app.stock_move('adjust_gain', p_product, v_diff, null, p_location, 'stock_adjustment', p_client_txn_id);
    if pr.cost_price > 0 then
      perform app.post_event(v_ev || '.adjust_gain', jsonb_build_object('value', round(v_diff * pr.cost_price, 2)), app.today(),
        'Stock count gain: ' || pr.name, 'stock_adjustment', p_client_txn_id, p_location);
    end if;
  elsif v_diff < 0 then
    perform app.stock_move('adjust_loss', p_product, -v_diff, p_location, null, 'stock_adjustment', p_client_txn_id);
    if pr.cost_price > 0 then
      perform app.post_event(v_ev || '.adjust_loss', jsonb_build_object('value', round(-v_diff * pr.cost_price, 2)), app.today(),
        'Stock count loss: ' || pr.name, 'stock_adjustment', p_client_txn_id, p_location);
    end if;
  end if;
  v_res := jsonb_build_object('previous', v_have, 'counted', p_counted, 'difference', v_diff);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.product_materials   enable row level security;
alter table public.production_lines    enable row level security;
alter table public.production_batches  enable row level security;
alter table public.inventory_lots      enable row level security;

create policy product_materials_read on public.product_materials for select to authenticated
  using (app.has_permission('products.view') or app.has_permission('production.view'));
create policy production_lines_read on public.production_lines for select to authenticated
  using (app.has_permission('production.view') or app.has_permission('qc.view') or app.has_permission('inventory.view'));
create policy production_batches_read on public.production_batches for select to authenticated
  using (app.has_permission('production.view') or app.has_permission('qc.view') or app.has_permission('inventory.view'));
create policy inventory_lots_read on public.inventory_lots for select to authenticated
  using (app.has_permission('inventory.view') or app.has_permission('production.view') or app.has_permission('qc.view'));
revoke insert, update, delete, truncate on public.inventory_lots from anon, authenticated, service_role;

-- >>> 20261004000021_production_qc_recalls.sql
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

-- >>> 20261004000022_procurement.sql
-- =====================================================================
-- OLA Water ERP — Phase 2A
-- 0022: suppliers and purchasing
-- =====================================================================
-- Purchase request → approval → purchase order (approval above the
-- purchase limit) → goods received (partial allowed, rejects at the door)
-- → supplier invoice with 3-way match (order × received × invoiced)
-- → supplier payment.
-- Accounting: goods received Dr Inventory / Cr Goods Received Not Invoiced;
-- invoice Dr GRNI (+/- price variance) + VAT input / Cr Accounts Payable;
-- payment Dr Accounts Payable / Cr Bank or Cash.
-- =====================================================================

create table public.suppliers (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique check (code ~ '^[A-Z0-9-]{2,12}$'),
  name                text not null check (length(trim(name)) > 0),
  contact_person      text,
  phone               text,
  email               text,
  address             text,
  city                text,
  vat_no              text,
  payment_terms_days  integer not null default 30 check (payment_terms_days >= 0),
  notes               text,
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create trigger suppliers_touch before update on public.suppliers for each row execute function app.touch_updated_at();
create trigger suppliers_audit after insert or update on public.suppliers for each row execute function app.audit_row('procurement');

create table public.supplier_items (
  supplier_id     uuid not null references public.suppliers(id),
  product_id      uuid not null references public.products(id),
  supplier_sku    text,
  unit_price      numeric(14,4) not null check (unit_price >= 0),
  lead_time_days  integer check (lead_time_days >= 0),
  is_preferred    boolean not null default false,
  updated_at      timestamptz not null default now(),
  primary key (supplier_id, product_id)
);
create trigger supplier_items_audit after insert or update or delete on public.supplier_items for each row execute function app.audit_row('procurement');

-- ---------------------------------------------------------------------
-- Purchase requests
-- ---------------------------------------------------------------------
create table public.purchase_requests (
  id             uuid primary key default gen_random_uuid(),
  request_no     text not null unique,
  location_id    uuid not null references public.locations(id),
  status         text not null default 'submitted' check (status in ('submitted','approved','rejected','ordered','cancelled')),
  needed_by      date,
  notes          text,
  requested_at   timestamptz not null default now(),
  requested_by   uuid,
  decided_at     timestamptz,
  decided_by     uuid,
  decision_note  text,
  updated_at     timestamptz not null default now(),
  client_txn_id  uuid unique
);
create trigger purchase_requests_touch before update on public.purchase_requests for each row execute function app.touch_updated_at();
create trigger purchase_requests_audit after insert or update on public.purchase_requests for each row execute function app.audit_row('procurement');

create table public.purchase_request_items (
  id               uuid primary key default gen_random_uuid(),
  request_id       uuid not null references public.purchase_requests(id),
  product_id       uuid not null references public.products(id),
  qty              numeric(14,3) not null check (qty > 0),
  est_unit_price   numeric(14,4),
  notes            text,
  unique (request_id, product_id)
);

-- ---------------------------------------------------------------------
-- Purchase orders
-- ---------------------------------------------------------------------
create table public.purchase_orders (
  id              uuid primary key default gen_random_uuid(),
  po_no           text not null unique,
  supplier_id     uuid not null references public.suppliers(id),
  location_id     uuid not null references public.locations(id),
  request_id      uuid references public.purchase_requests(id),
  order_date      date not null,
  expected_date   date,
  status          text not null default 'pending_approval' check (status in
                    ('pending_approval','approved','partially_received','received','closed','cancelled')),
  subtotal        numeric(16,2) not null default 0,
  tax_total       numeric(16,2) not null default 0,
  total           numeric(16,2) not null default 0,
  notes           text,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  approved_at     timestamptz,
  approved_by     uuid,
  decision_note   text,
  updated_at      timestamptz not null default now(),
  client_txn_id   uuid unique
);
create index purchase_orders_supplier_idx on public.purchase_orders (supplier_id, order_date desc);
create index purchase_orders_status_idx on public.purchase_orders (status, order_date desc);
create trigger purchase_orders_touch before update on public.purchase_orders for each row execute function app.touch_updated_at();
create trigger purchase_orders_audit after insert or update on public.purchase_orders for each row execute function app.audit_row('procurement');

create table public.purchase_order_lines (
  id             uuid primary key default gen_random_uuid(),
  po_id          uuid not null references public.purchase_orders(id),
  line_no        integer not null,
  product_id     uuid not null references public.products(id),
  qty_ordered    numeric(14,3) not null check (qty_ordered > 0),
  unit_price     numeric(14,4) not null check (unit_price >= 0),
  tax_rate       numeric(5,2) not null default 0 check (tax_rate between 0 and 100),
  net            numeric(16,2) not null,
  tax            numeric(16,2) not null,
  total          numeric(16,2) not null,
  qty_received   numeric(14,3) not null default 0 check (qty_received >= 0),
  qty_rejected   numeric(14,3) not null default 0 check (qty_rejected >= 0),
  qty_invoiced   numeric(14,3) not null default 0 check (qty_invoiced >= 0),
  unique (po_id, line_no),
  unique (po_id, product_id)
);
comment on column public.purchase_order_lines.unit_price is 'Agreed price per unit before VAT';
create trigger purchase_order_lines_audit after insert or update on public.purchase_order_lines for each row execute function app.audit_row('procurement');

-- ---------------------------------------------------------------------
-- Goods received
-- ---------------------------------------------------------------------
create table public.goods_receipts (
  id                uuid primary key default gen_random_uuid(),
  grn_no            text not null unique,
  po_id             uuid not null references public.purchase_orders(id),
  supplier_id       uuid not null references public.suppliers(id),
  location_id       uuid not null references public.locations(id),
  received_at       timestamptz not null default now(),
  delivery_note_no  text,
  notes             text,
  on_time           boolean,
  received_by       uuid,
  client_txn_id     uuid unique
);
create index goods_receipts_po_idx on public.goods_receipts (po_id);
create index goods_receipts_supplier_idx on public.goods_receipts (supplier_id, received_at desc);
create trigger goods_receipts_audit after insert on public.goods_receipts for each row execute function app.audit_row('procurement');
create trigger goods_receipts_append_only before update or delete on public.goods_receipts for each row execute function app.forbid_change();

create table public.goods_receipt_lines (
  id             uuid primary key default gen_random_uuid(),
  grn_id         uuid not null references public.goods_receipts(id),
  po_line_id     uuid not null references public.purchase_order_lines(id),
  product_id     uuid not null references public.products(id),
  qty_received   numeric(14,3) not null default 0 check (qty_received >= 0),
  qty_rejected   numeric(14,3) not null default 0 check (qty_rejected >= 0),
  reject_reason  text,
  supplier_lot   text,
  expiry_date    date,
  unit_price     numeric(14,4) not null
);
create trigger goods_receipt_lines_append_only before update or delete on public.goods_receipt_lines for each row execute function app.forbid_change();

-- ---------------------------------------------------------------------
-- Supplier invoices and payments
-- ---------------------------------------------------------------------
create table public.supplier_invoices (
  id                   uuid primary key default gen_random_uuid(),
  ref_no               text not null unique,
  supplier_id          uuid not null references public.suppliers(id),
  supplier_invoice_no  text not null,
  po_id                uuid not null references public.purchase_orders(id),
  invoice_date         date not null,
  due_date             date not null,
  subtotal             numeric(16,2) not null,
  tax_total            numeric(16,2) not null,
  total                numeric(16,2) not null check (total >= 0),
  amount_paid          numeric(16,2) not null default 0,
  status               text not null check (status in ('on_hold','approved','partially_paid','paid','void')),
  match_status         text not null check (match_status in ('matched','mismatch','override')),
  match_notes          text[] not null default '{}',
  journal_entry_id     uuid references public.journal_entries(id),
  created_at           timestamptz not null default now(),
  created_by           uuid,
  approved_at          timestamptz,
  approved_by          uuid,
  decision_note        text,
  updated_at           timestamptz not null default now(),
  client_txn_id        uuid unique
);
create unique index supplier_invoices_number_uq on public.supplier_invoices (supplier_id, lower(supplier_invoice_no)) where status <> 'void';
create index supplier_invoices_supplier_idx on public.supplier_invoices (supplier_id, invoice_date desc);
create trigger supplier_invoices_touch before update on public.supplier_invoices for each row execute function app.touch_updated_at();
create trigger supplier_invoices_audit after insert or update on public.supplier_invoices for each row execute function app.audit_row('procurement');

create table public.supplier_invoice_lines (
  id           uuid primary key default gen_random_uuid(),
  invoice_id   uuid not null references public.supplier_invoices(id),
  po_line_id   uuid not null references public.purchase_order_lines(id),
  product_id   uuid not null references public.products(id),
  qty          numeric(14,3) not null check (qty > 0),
  unit_price   numeric(14,4) not null check (unit_price >= 0),
  po_price     numeric(14,4) not null,
  tax_rate     numeric(5,2) not null,
  net          numeric(16,2) not null,
  tax          numeric(16,2) not null,
  total        numeric(16,2) not null,
  match_ok     boolean not null,
  match_note   text
);

create table public.supplier_payments (
  id               uuid primary key default gen_random_uuid(),
  payment_no       text not null unique,
  supplier_id      uuid not null references public.suppliers(id),
  paid_at          timestamptz not null default now(),
  method           text not null check (method in ('cash','bank_transfer','cheque')),
  amount           numeric(16,2) not null check (amount > 0),
  unallocated      numeric(16,2) not null default 0 check (unallocated >= 0),
  reference        text,
  notes            text,
  journal_entry_id uuid references public.journal_entries(id),
  created_by       uuid,
  client_txn_id    uuid unique
);
create index supplier_payments_supplier_idx on public.supplier_payments (supplier_id, paid_at desc);
create trigger supplier_payments_audit after insert or update on public.supplier_payments for each row execute function app.audit_row('procurement');

create table public.supplier_payment_allocations (
  payment_id  uuid not null references public.supplier_payments(id),
  invoice_id  uuid not null references public.supplier_invoices(id),
  amount      numeric(16,2) not null check (amount > 0),
  created_at  timestamptz not null default now(),
  primary key (payment_id, invoice_id)
);

-- ---------------------------------------------------------------------
-- Suppliers
-- ---------------------------------------------------------------------
create or replace function public.save_supplier(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; v_phone text := app.jtext(p, 'phone');
begin
  perform app.require_permission('suppliers.manage');
  if nullif(trim(app.jtext(p, 'name')), '') is null then raise exception 'Enter the supplier name' using errcode = '22023'; end if;
  if v_phone is not null then v_phone := coalesce(app.normalize_phone(v_phone), v_phone); end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    insert into public.suppliers (code, name, contact_person, phone, email, address, city, vat_no, payment_terms_days, notes)
    values (upper(trim(app.jtext(p, 'code'))), trim(app.jtext(p, 'name')), app.jtext(p, 'contact_person'), v_phone,
            lower(app.jtext(p, 'email')), app.jtext(p, 'address'), app.jtext(p, 'city'), nullif(trim(app.jtext(p, 'vat_no')), ''),
            coalesce(app.jint(p, 'payment_terms_days'), 30), app.jtext(p, 'notes'))
    returning id into v;
  else
    update public.suppliers set name = trim(app.jtext(p, 'name')), contact_person = app.jtext(p, 'contact_person'), phone = v_phone,
           email = lower(app.jtext(p, 'email')), address = app.jtext(p, 'address'), city = app.jtext(p, 'city'),
           vat_no = nullif(trim(app.jtext(p, 'vat_no')), ''), payment_terms_days = coalesce(app.jint(p, 'payment_terms_days'), 30),
           notes = app.jtext(p, 'notes'), is_active = app.jbool(p, 'is_active', true)
     where id = p_id returning id into v;
    if v is null then raise exception 'Supplier not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

create or replace function public.set_supplier_items(p_supplier uuid, p_lines jsonb, p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
declare l jsonb; n integer := 0;
begin
  perform app.require_permission('suppliers.manage');
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Supplier prices'), null, null);
  delete from public.supplier_items where supplier_id = p_supplier;
  for l in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    continue when app.jnum(l, 'unit_price') is null;
    insert into public.supplier_items (supplier_id, product_id, supplier_sku, unit_price, lead_time_days, is_preferred)
    values (p_supplier, app.juuid(l, 'product_id'), app.jtext(l, 'supplier_sku'), app.jnum(l, 'unit_price'),
            app.jint(l, 'lead_time_days'), app.jbool(l, 'is_preferred', false));
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function app.supplier_outstanding(p_supplier uuid)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce((select sum(total - amount_paid) from public.supplier_invoices
                    where supplier_id = p_supplier and status in ('approved','partially_paid')), 0)
       - coalesce((select sum(unallocated) from public.supplier_payments where supplier_id = p_supplier), 0)
$$;

-- ---------------------------------------------------------------------
-- Purchase requests
-- ---------------------------------------------------------------------
create or replace function public.create_purchase_request(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; v uuid := gen_random_uuid(); v_no text; l jsonb; n integer := 0; v_res jsonb; v_loc uuid := app.juuid(p, 'location_id');
begin
  perform app.require_permission('procurement.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'create_purchase_request');
  if v_done is not null then return v_done; end if;
  if not exists (select 1 from public.locations where id = v_loc) then raise exception 'Choose where the goods are needed' using errcode = '22023'; end if;
  perform app.set_context(null, p_client_txn_id, 'request');
  v_no := app.next_document_number('PR', v_loc);
  insert into public.purchase_requests (id, request_no, location_id, needed_by, notes, requested_by, client_txn_id)
  values (v, v_no, v_loc, (app.jtext(p, 'needed_by'))::date, app.jtext(p, 'notes'), app.current_user_id(), p_client_txn_id);
  for l in select * from jsonb_array_elements(coalesce(p -> 'items', '[]')) loop
    continue when coalesce(app.jnum(l, 'qty'), 0) <= 0;
    insert into public.purchase_request_items (request_id, product_id, qty, est_unit_price, notes)
    values (v, app.juuid(l, 'product_id'), app.jnum(l, 'qty'), app.jnum(l, 'est_unit_price'), app.jtext(l, 'notes'));
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Add at least one item' using errcode = '22023'; end if;
  v_res := jsonb_build_object('request_id', v, 'request_no', v_no);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.decide_purchase_request(p_id uuid, p_approve boolean, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.purchase_requests;
begin
  select * into r from public.purchase_requests where id = p_id for update;
  if not found then raise exception 'Request not found' using errcode = 'P0002'; end if;
  if r.status <> 'submitted' then raise exception 'This request has already been decided' using errcode = '22023'; end if;
  if p_approve is null then
    -- withdraw (by the requester or a manager)
    if r.requested_by is distinct from app.current_user_id() and not app.has_permission('procurement.approve') then
      raise exception 'Only the requester or an approver can withdraw a request' using errcode = '42501';
    end if;
  else
    perform app.require_permission('procurement.approve');
    if not p_approve and nullif(trim(p_note), '') is null then raise exception 'Give a reason for rejecting' using errcode = '22023'; end if;
  end if;
  perform app.set_context(nullif(trim(p_note), ''), null, case when p_approve then 'approve' when not p_approve then 'reject' else 'withdraw' end);
  update public.purchase_requests set status = case when p_approve then 'approved' when not p_approve then 'rejected' else 'cancelled' end,
         decided_at = now(), decided_by = app.current_user_id(), decision_note = nullif(trim(p_note), '')
   where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- Purchase orders
-- ---------------------------------------------------------------------
--   p: {supplier_id, location_id, expected_date, request_id, notes,
--       lines: [{product_id, qty, unit_price, tax_rate?}]}
create or replace function public.create_purchase_order(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; s public.suppliers; v uuid := gen_random_uuid(); v_no text; l jsonb; pr public.products; n integer := 0;
  v_rate numeric; calc record; v_net numeric := 0; v_tax numeric := 0; v_total numeric := 0; v_limit numeric; v_res jsonb;
  v_loc uuid := app.juuid(p, 'location_id'); v_req uuid := app.juuid(p, 'request_id'); v_status text;
begin
  perform app.require_permission('procurement.manage');
  v_done := app.idempotency_begin(p_client_txn_id, 'create_purchase_order');
  if v_done is not null then return v_done; end if;
  select * into s from public.suppliers where id = app.juuid(p, 'supplier_id') and is_active;
  if not found then raise exception 'Choose a supplier' using errcode = '22023'; end if;
  if not exists (select 1 from public.locations where id = v_loc and location_type in ('warehouse','head_office')) then
    raise exception 'Choose the warehouse to deliver to' using errcode = '22023';
  end if;
  if v_req is not null and not exists (select 1 from public.purchase_requests where id = v_req and status = 'approved') then
    raise exception 'The purchase request must be approved first' using errcode = '22023';
  end if;
  perform app.set_context(null, p_client_txn_id, 'order');
  v_no := app.next_document_number('PO', v_loc);
  insert into public.purchase_orders (id, po_no, supplier_id, location_id, request_id, order_date, expected_date, notes, created_by, client_txn_id)
  values (v, v_no, s.id, v_loc, v_req, app.today(), (app.jtext(p, 'expected_date'))::date, app.jtext(p, 'notes'), app.current_user_id(), p_client_txn_id);

  for l in select * from jsonb_array_elements(coalesce(p -> 'lines', '[]')) loop
    continue when coalesce(app.jnum(l, 'qty'), 0) <= 0;
    select * into pr from public.products where id = app.juuid(l, 'product_id') and is_active;
    if not found then raise exception 'Unknown item' using errcode = 'P0002'; end if;
    if app.jnum(l, 'unit_price') is null or app.jnum(l, 'unit_price') < 0 then
      raise exception 'Enter the price for %', pr.name using errcode = '22023';
    end if;
    v_rate := coalesce(app.jnum(l, 'tax_rate'),
                       case when s.vat_no is not null and pr.tax_code is not null then app.tax_rate(pr.tax_code) else 0 end);
    select * into calc from app.calc_line(app.jnum(l, 'qty'), app.jnum(l, 'unit_price'), 0, v_rate, false);
    n := n + 1;
    insert into public.purchase_order_lines (po_id, line_no, product_id, qty_ordered, unit_price, tax_rate, net, tax, total)
    values (v, n, pr.id, app.jnum(l, 'qty'), app.jnum(l, 'unit_price'), v_rate, calc.net, calc.tax, calc.total);
    v_net := v_net + calc.net; v_tax := v_tax + calc.tax; v_total := v_total + calc.total;
  end loop;
  if n = 0 then raise exception 'Add at least one item' using errcode = '22023'; end if;

  v_limit := coalesce((app.get_setting('approvals.purchase_amount') #>> '{}')::numeric, 0);
  v_status := case when v_total < v_limit or app.has_permission('procurement.approve') then 'approved' else 'pending_approval' end;
  update public.purchase_orders set subtotal = v_net, tax_total = v_tax, total = v_total, status = v_status,
         approved_at = case when v_status = 'approved' then now() end,
         approved_by = case when v_status = 'approved' then app.current_user_id() end
   where id = v;
  if v_req is not null then update public.purchase_requests set status = 'ordered' where id = v_req; end if;

  v_res := jsonb_build_object('po_id', v, 'po_no', v_no, 'total', v_total, 'status', v_status);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.decide_purchase_order(p_po uuid, p_approve boolean, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare po public.purchase_orders;
begin
  select * into po from public.purchase_orders where id = p_po for update;
  if not found then raise exception 'Purchase order not found' using errcode = 'P0002'; end if;
  if p_approve then
    perform app.require_permission('procurement.approve');
    if po.status <> 'pending_approval' then raise exception 'This order is not waiting for approval' using errcode = '22023'; end if;
    perform app.set_context(nullif(trim(p_note), ''), null, 'approve');
    update public.purchase_orders set status = 'approved', approved_at = now(), approved_by = app.current_user_id(),
           decision_note = nullif(trim(p_note), '') where id = p_po;
  else
    if not (app.has_permission('procurement.approve') or (po.status = 'pending_approval' and app.has_permission('procurement.manage'))) then
      raise exception 'Permission denied: procurement.approve is required' using errcode = '42501';
    end if;
    if nullif(trim(p_note), '') is null then raise exception 'Give a reason' using errcode = '22023'; end if;
    if po.status not in ('pending_approval','approved') or exists (select 1 from public.goods_receipts where po_id = p_po) then
      raise exception 'Goods have already been received on this order — close it instead' using errcode = '22023';
    end if;
    perform app.set_context(trim(p_note), null, 'cancel');
    update public.purchase_orders set status = 'cancelled', decision_note = trim(p_note) where id = p_po;
  end if;
end $$;

create or replace function public.close_purchase_order(p_po uuid, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare po public.purchase_orders;
begin
  perform app.require_permission('procurement.manage');
  if nullif(trim(p_note), '') is null then raise exception 'Give a reason' using errcode = '22023'; end if;
  select * into po from public.purchase_orders where id = p_po for update;
  if not found then raise exception 'Purchase order not found' using errcode = 'P0002'; end if;
  if po.status not in ('partially_received','received') then raise exception 'Only a received order can be closed' using errcode = '22023'; end if;
  perform app.set_context(trim(p_note), null, 'close');
  update public.purchase_orders set status = 'closed', decision_note = trim(p_note) where id = p_po;
end $$;

-- ---------------------------------------------------------------------
-- Goods received
--   p: {delivery_note_no, notes, lines: [{po_line_id, qty_received, qty_rejected, reject_reason, supplier_lot, expiry_date}]}
-- ---------------------------------------------------------------------
create or replace function public.receive_purchase_order(p_po uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; po public.purchase_orders; pl public.purchase_order_lines; pr public.products; l jsonb; v uuid := gen_random_uuid();
  v_no text; v_ok numeric; v_rej numeric; v_raw numeric := 0; v_fg numeric := 0; n integer := 0; v_res jsonb; v_open integer;
begin
  if not (app.has_permission('inventory.manage') or app.has_permission('procurement.manage')) then
    raise exception 'Permission denied: inventory.manage is required' using errcode = '42501';
  end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'receive_purchase_order');
  if v_done is not null then return v_done; end if;
  select * into po from public.purchase_orders where id = p_po for update;
  if not found then raise exception 'Purchase order not found' using errcode = 'P0002'; end if;
  if po.status not in ('approved','partially_received') then
    raise exception 'Goods can only be received on an approved order' using errcode = '22023';
  end if;
  perform app.set_context(null, p_client_txn_id, 'receive');
  v_no := app.next_document_number('GRN', po.location_id);
  insert into public.goods_receipts (id, grn_no, po_id, supplier_id, location_id, delivery_note_no, notes, on_time, received_by, client_txn_id)
  values (v, v_no, po.id, po.supplier_id, po.location_id, app.jtext(p, 'delivery_note_no'), app.jtext(p, 'notes'),
          po.expected_date is null or app.today() <= po.expected_date, app.current_user_id(), p_client_txn_id);

  for l in select * from jsonb_array_elements(coalesce(p -> 'lines', '[]')) loop
    v_ok := coalesce(app.jnum(l, 'qty_received'), 0); v_rej := coalesce(app.jnum(l, 'qty_rejected'), 0);
    continue when v_ok <= 0 and v_rej <= 0;
    if v_ok < 0 or v_rej < 0 then raise exception 'Quantities cannot be negative' using errcode = '22023'; end if;
    select * into pl from public.purchase_order_lines where id = app.juuid(l, 'po_line_id') and po_id = po.id for update;
    if not found then raise exception 'Line is not on this order' using errcode = 'P0002'; end if;
    select * into pr from public.products where id = pl.product_id;
    if pl.qty_received + v_ok > pl.qty_ordered then
      raise exception '% — % ordered, % already received; % more is too many', pr.name, pl.qty_ordered::numeric(14,0),
        pl.qty_received::numeric(14,0), v_ok::numeric(14,0) using errcode = '22023';
    end if;
    if v_rej > 0 and nullif(trim(app.jtext(l, 'reject_reason')), '') is null then
      raise exception 'Say why % was rejected', pr.name using errcode = '22023';
    end if;
    insert into public.goods_receipt_lines (grn_id, po_line_id, product_id, qty_received, qty_rejected, reject_reason, supplier_lot,
      expiry_date, unit_price)
    values (v, pl.id, pr.id, v_ok, v_rej, nullif(trim(app.jtext(l, 'reject_reason')), ''), app.jtext(l, 'supplier_lot'),
      (app.jtext(l, 'expiry_date'))::date, pl.unit_price);
    if v_ok > 0 then
      perform app.apply_receipt_cost(pr.id, v_ok, pl.unit_price);
      perform app.stock_move('purchase_receipt', pr.id, v_ok, null, po.location_id, 'goods_receipt', v, v_no, 'available', null, null,
        pl.unit_price);
      if pr.item_type = 'finished_good' then v_fg := v_fg + round(v_ok * pl.unit_price, 2);
      else v_raw := v_raw + round(v_ok * pl.unit_price, 2); end if;
    end if;
    update public.purchase_order_lines set qty_received = qty_received + v_ok, qty_rejected = qty_rejected + v_rej where id = pl.id;
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Enter what arrived' using errcode = '22023'; end if;

  if v_raw + v_fg > 0 then
    perform app.post_event('purchase.receipt', jsonb_build_object('raw', v_raw, 'finished', v_fg, 'total', v_raw + v_fg), app.today(),
      format('Goods received %s on %s', v_no, po.po_no), 'goods_receipt', v, po.location_id, 'supplier', po.supplier_id);
  end if;
  select count(*) into v_open from public.purchase_order_lines where po_id = po.id and qty_received < qty_ordered;
  update public.purchase_orders set status = case when v_open = 0 then 'received' else 'partially_received' end where id = po.id;

  v_res := jsonb_build_object('grn_id', v, 'grn_no', v_no, 'value', v_raw + v_fg, 'complete', v_open = 0);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- Supplier invoices with 3-way match
--   p: {supplier_invoice_no, invoice_date, due_date, lines: [{po_line_id, qty, unit_price, tax_rate?}]}
-- ---------------------------------------------------------------------
create or replace function app.post_supplier_invoice(p_inv uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare i public.supplier_invoices; v_grni numeric; v_var numeric; v_je uuid;
begin
  select * into i from public.supplier_invoices where id = p_inv;
  select coalesce(sum(round(qty * po_price, 2)), 0) into v_grni from public.supplier_invoice_lines where invoice_id = p_inv;
  v_var := i.subtotal - v_grni;
  v_je := app.post_event('purchase.invoice', jsonb_build_object('grni', v_grni, 'ppv_dr', greatest(v_var, 0), 'ppv_cr', greatest(-v_var, 0),
            'vat', i.tax_total, 'total', i.total), i.invoice_date,
          format('Supplier invoice %s (%s)', i.supplier_invoice_no, i.ref_no), 'supplier_invoice', i.id, null, 'supplier', i.supplier_id);
  update public.supplier_invoices set journal_entry_id = v_je where id = p_inv;
  return v_je;
end $$;

create or replace function public.record_supplier_invoice(p_po uuid, p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; po public.purchase_orders; s public.suppliers; pl public.purchase_order_lines; pr public.products; l jsonb;
  v uuid := gen_random_uuid(); v_no text; v_qty numeric; v_price numeric; v_rate numeric; calc record; v_ok boolean; v_note text;
  v_notes text[] := '{}'; v_tol numeric; v_net numeric := 0; v_tax numeric := 0; v_total numeric := 0; n integer := 0;
  v_date date := coalesce((app.jtext(p, 'invoice_date'))::date, app.today()); v_res jsonb; v_status text;
begin
  if not (app.has_permission('procurement.manage') or app.has_permission('payments.manage')) then
    raise exception 'Permission denied: procurement.manage or payments.manage is required' using errcode = '42501';
  end if;
  if nullif(trim(app.jtext(p, 'supplier_invoice_no')), '') is null then raise exception 'Enter the supplier''s invoice number' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'record_supplier_invoice');
  if v_done is not null then return v_done; end if;
  select * into po from public.purchase_orders where id = p_po for update;
  if not found then raise exception 'Purchase order not found' using errcode = 'P0002'; end if;
  if po.status in ('pending_approval','cancelled') then raise exception 'This order is not approved' using errcode = '22023'; end if;
  select * into s from public.suppliers where id = po.supplier_id;
  if exists (select 1 from public.supplier_invoices where supplier_id = s.id and lower(supplier_invoice_no) = lower(trim(app.jtext(p, 'supplier_invoice_no')))
               and status <> 'void') then
    raise exception 'Invoice % from % is already recorded', trim(app.jtext(p, 'supplier_invoice_no')), s.name using errcode = '23505';
  end if;
  v_tol := coalesce((app.get_setting('procurement.price_tolerance_percent') #>> '{}')::numeric, 0);
  perform app.set_context(null, p_client_txn_id, 'supplier_invoice');
  v_no := app.next_document_number('SIN');
  insert into public.supplier_invoices (id, ref_no, supplier_id, supplier_invoice_no, po_id, invoice_date, due_date, subtotal, tax_total,
    total, status, match_status, created_by, client_txn_id)
  values (v, v_no, s.id, trim(app.jtext(p, 'supplier_invoice_no')), po.id, v_date,
    coalesce((app.jtext(p, 'due_date'))::date, v_date + s.payment_terms_days), 0, 0, 0, 'on_hold', 'mismatch',
    app.current_user_id(), p_client_txn_id);

  for l in select * from jsonb_array_elements(coalesce(p -> 'lines', '[]')) loop
    v_qty := coalesce(app.jnum(l, 'qty'), 0);
    continue when v_qty <= 0;
    select * into pl from public.purchase_order_lines where id = app.juuid(l, 'po_line_id') and po_id = po.id for update;
    if not found then raise exception 'Line is not on this order' using errcode = 'P0002'; end if;
    select * into pr from public.products where id = pl.product_id;
    v_price := coalesce(app.jnum(l, 'unit_price'), pl.unit_price);
    v_rate := coalesce(app.jnum(l, 'tax_rate'), pl.tax_rate);
    select * into calc from app.calc_line(v_qty, v_price, 0, v_rate, false);
    v_ok := true; v_note := null;
    if pl.qty_invoiced + v_qty > pl.qty_received then
      v_ok := false;
      v_note := format('%s: billed %s but only %s received and not yet billed', pr.name, v_qty::numeric(14,0),
                       (pl.qty_received - pl.qty_invoiced)::numeric(14,0));
    elsif abs(v_price - pl.unit_price) > pl.unit_price * v_tol / 100 then
      v_ok := false;
      v_note := format('%s: price %s differs from the order price %s', pr.name, round(v_price, 2), round(pl.unit_price, 2));
    elsif v_rate <> pl.tax_rate then
      v_ok := false;
      v_note := format('%s: VAT %s%% differs from the order (%s%%)', pr.name, v_rate, pl.tax_rate);
    end if;
    if v_note is not null then v_notes := v_notes || v_note; end if;
    insert into public.supplier_invoice_lines (invoice_id, po_line_id, product_id, qty, unit_price, po_price, tax_rate, net, tax, total,
      match_ok, match_note)
    values (v, pl.id, pr.id, v_qty, v_price, pl.unit_price, v_rate, calc.net, calc.tax, calc.total, v_ok, v_note);
    update public.purchase_order_lines set qty_invoiced = qty_invoiced + v_qty where id = pl.id;
    v_net := v_net + calc.net; v_tax := v_tax + calc.tax; v_total := v_total + calc.total; n := n + 1;
  end loop;
  if n = 0 then raise exception 'Add the invoiced lines' using errcode = '22023'; end if;

  v_status := case when cardinality(v_notes) = 0 then 'approved' else 'on_hold' end;
  update public.supplier_invoices set subtotal = v_net, tax_total = v_tax, total = v_total, status = v_status,
         match_status = case when cardinality(v_notes) = 0 then 'matched' else 'mismatch' end, match_notes = v_notes,
         approved_at = case when v_status = 'approved' then now() end
   where id = v;
  if v_status = 'approved' then perform app.post_supplier_invoice(v); end if;

  v_res := jsonb_build_object('invoice_id', v, 'ref_no', v_no, 'total', v_total, 'status', v_status, 'mismatches', to_jsonb(v_notes));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.decide_supplier_invoice(p_inv uuid, p_approve boolean, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare i public.supplier_invoices;
begin
  perform app.require_permission('procurement.approve');
  if nullif(trim(p_note), '') is null then raise exception 'Give a reason' using errcode = '22023'; end if;
  select * into i from public.supplier_invoices where id = p_inv for update;
  if not found then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if i.status <> 'on_hold' then raise exception 'Only an invoice on hold can be decided here' using errcode = '22023'; end if;
  if p_approve then
    perform app.set_context(trim(p_note), null, 'approve_mismatch');
    update public.supplier_invoices set status = 'approved', match_status = 'override', approved_at = now(),
           approved_by = app.current_user_id(), decision_note = trim(p_note) where id = p_inv;
    perform app.post_supplier_invoice(p_inv);
  else
    perform app.set_context(trim(p_note), null, 'void');
    update public.purchase_order_lines pl set qty_invoiced = pl.qty_invoiced - x.qty
      from (select po_line_id, sum(qty) qty from public.supplier_invoice_lines where invoice_id = p_inv group by po_line_id) x
     where pl.id = x.po_line_id;
    update public.supplier_invoices set status = 'void', decision_note = trim(p_note) where id = p_inv;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Supplier payments
--   p: {supplier_id, method, amount, reference, notes, allocations: [{invoice_id, amount}]}
--   No allocations given → oldest approved invoices first.
-- ---------------------------------------------------------------------
create or replace function public.record_supplier_payment(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; s public.suppliers; v uuid := gen_random_uuid(); v_no text; v_amt numeric := app.jnum(p, 'amount');
  v_left numeric; i public.supplier_invoices; a jsonb; v_take numeric; v_method text := app.jtext(p, 'method'); v_je uuid; v_res jsonb;
begin
  perform app.require_permission('payments.manage');
  if coalesce(v_amt, 0) <= 0 then raise exception 'Enter the amount paid' using errcode = '22023'; end if;
  if v_method not in ('cash','bank_transfer','cheque') then raise exception 'Choose how it was paid' using errcode = '22023'; end if;
  if v_method <> 'cash' and nullif(trim(app.jtext(p, 'reference')), '') is null then
    raise exception 'Enter the bank reference or cheque number' using errcode = '22023';
  end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'record_supplier_payment');
  if v_done is not null then return v_done; end if;
  select * into s from public.suppliers where id = app.juuid(p, 'supplier_id');
  if not found then raise exception 'Choose a supplier' using errcode = '22023'; end if;
  perform app.set_context(app.jtext(p, 'notes'), p_client_txn_id, 'supplier_payment');
  v_no := app.next_document_number('SPY');
  insert into public.supplier_payments (id, payment_no, supplier_id, method, amount, unallocated, reference, notes, created_by, client_txn_id)
  values (v, v_no, s.id, v_method, v_amt, v_amt, nullif(trim(app.jtext(p, 'reference')), ''), app.jtext(p, 'notes'),
          app.current_user_id(), p_client_txn_id);
  v_left := v_amt;

  if jsonb_array_length(coalesce(p -> 'allocations', '[]')) > 0 then
    for a in select * from jsonb_array_elements(p -> 'allocations') loop
      continue when coalesce(app.jnum(a, 'amount'), 0) <= 0;
      select * into i from public.supplier_invoices where id = app.juuid(a, 'invoice_id') and supplier_id = s.id for update;
      if not found or i.status not in ('approved','partially_paid') then raise exception 'Invoice is not open for payment' using errcode = '22023'; end if;
      if app.jnum(a, 'amount') > i.total - i.amount_paid then
        raise exception 'Payment to % is more than its balance', i.supplier_invoice_no using errcode = '22023';
      end if;
      if app.jnum(a, 'amount') > v_left then
        raise exception 'The amounts given to invoices add up to more than the payment' using errcode = '22023';
      end if;
      v_take := app.jnum(a, 'amount');
      if v_take > 0 then
        insert into public.supplier_payment_allocations (payment_id, invoice_id, amount) values (v, i.id, v_take);
        update public.supplier_invoices set amount_paid = amount_paid + v_take,
               status = case when amount_paid + v_take >= total then 'paid' else 'partially_paid' end where id = i.id;
        v_left := v_left - v_take;
      end if;
    end loop;
    -- anything not allocated is kept as an advance to the supplier
  else
    for i in select * from public.supplier_invoices where supplier_id = s.id and status in ('approved','partially_paid')
              order by due_date, invoice_date, ref_no for update loop
      exit when v_left <= 0;
      v_take := least(i.total - i.amount_paid, v_left);
      insert into public.supplier_payment_allocations (payment_id, invoice_id, amount) values (v, i.id, v_take);
      update public.supplier_invoices set amount_paid = amount_paid + v_take,
             status = case when amount_paid + v_take >= total then 'paid' else 'partially_paid' end where id = i.id;
      v_left := v_left - v_take;
    end loop;
  end if;

  v_je := app.post_event('supplier.payment', jsonb_build_object('amount', v_amt,
            'bank', case when v_method = 'cash' then 0 else v_amt end, 'cash', case when v_method = 'cash' then v_amt else 0 end),
          app.today(), format('Payment %s to %s', v_no, s.name), 'supplier_payment', v, null, 'supplier', s.id);
  update public.supplier_payments set unallocated = v_left, journal_entry_id = v_je where id = v;

  v_res := jsonb_build_object('payment_id', v, 'payment_no', v_no, 'unallocated', v_left, 'outstanding', app.supplier_outstanding(s.id));
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.suppliers                    enable row level security;
alter table public.supplier_items               enable row level security;
alter table public.purchase_requests            enable row level security;
alter table public.purchase_request_items       enable row level security;
alter table public.purchase_orders              enable row level security;
alter table public.purchase_order_lines         enable row level security;
alter table public.goods_receipts               enable row level security;
alter table public.goods_receipt_lines          enable row level security;
alter table public.supplier_invoices            enable row level security;
alter table public.supplier_invoice_lines       enable row level security;
alter table public.supplier_payments            enable row level security;
alter table public.supplier_payment_allocations enable row level security;

create policy suppliers_read on public.suppliers for select to authenticated
  using (app.has_permission('procurement.view') or app.has_permission('suppliers.manage') or app.has_permission('payments.view'));
create policy supplier_items_read on public.supplier_items for select to authenticated
  using (app.has_permission('procurement.view') or app.has_permission('suppliers.manage'));
create policy purchase_requests_read on public.purchase_requests for select to authenticated
  using (app.has_permission('procurement.view') or requested_by = app.current_user_id());
create policy purchase_request_items_read on public.purchase_request_items for select to authenticated
  using (exists (select 1 from public.purchase_requests r where r.id = request_id));
create policy purchase_orders_read on public.purchase_orders for select to authenticated
  using (app.has_permission('procurement.view') or app.has_permission('inventory.manage') or app.has_permission('payments.view'));
create policy purchase_order_lines_read on public.purchase_order_lines for select to authenticated
  using (exists (select 1 from public.purchase_orders o where o.id = po_id));
create policy goods_receipts_read on public.goods_receipts for select to authenticated
  using (app.has_permission('procurement.view') or app.has_permission('inventory.view') or app.has_permission('payments.view'));
create policy goods_receipt_lines_read on public.goods_receipt_lines for select to authenticated
  using (exists (select 1 from public.goods_receipts g where g.id = grn_id));
create policy supplier_invoices_read on public.supplier_invoices for select to authenticated
  using (app.has_permission('procurement.view') or app.has_permission('payments.view'));
create policy supplier_invoice_lines_read on public.supplier_invoice_lines for select to authenticated
  using (exists (select 1 from public.supplier_invoices i where i.id = invoice_id));
create policy supplier_payments_read on public.supplier_payments for select to authenticated
  using (app.has_permission('payments.view') or app.has_permission('procurement.view'));
create policy supplier_payment_allocations_read on public.supplier_payment_allocations for select to authenticated
  using (exists (select 1 from public.supplier_payments x where x.id = payment_id));
revoke insert, update, delete, truncate on public.goods_receipts, public.goods_receipt_lines from anon, authenticated, service_role;

-- >>> 20261004000023_phase2a_reference_data.sql
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

-- >>> 20261004000024_phase2a_read_models.sql
-- =====================================================================
-- OLA Water ERP — Phase 2A
-- 0024: read models for production, QC, recalls, stock and purchasing
-- =====================================================================

-- Stock per item: sellable, on hold, quarantined, value and reorder warning
create or replace function public.stock_summary(p_item_type text default null)
returns table (product_id uuid, sku text, name text, item_type text, unit text, available numeric, qc_hold numeric,
               quarantine numeric, damaged numeric, cost_price numeric, value numeric, reorder_level numeric, low boolean,
               by_location jsonb)
language sql stable security definer set search_path = '' as $$
  select p.id, p.sku, p.name, p.item_type, p.unit,
    coalesce(sum(b.qty) filter (where b.stock_status = 'available'), 0),
    coalesce(sum(b.qty) filter (where b.stock_status = 'qc_hold'), 0),
    coalesce(sum(b.qty) filter (where b.stock_status = 'quarantine'), 0),
    coalesce(sum(b.qty) filter (where b.stock_status = 'damaged'), 0),
    p.cost_price,
    round(coalesce(sum(b.qty), 0) * p.cost_price, 2),
    p.reorder_level,
    p.reorder_level > 0 and coalesce(sum(b.qty) filter (where b.stock_status = 'available'), 0) <= p.reorder_level,
    coalesce(jsonb_agg(jsonb_build_object('location', l.name, 'location_id', l.id, 'status', b.stock_status, 'qty', b.qty)
               order by l.name) filter (where b.qty <> 0), '[]')
  from public.products p
  left join public.inventory_balances b on b.product_id = p.id and b.qty <> 0
  left join public.locations l on l.id = b.location_id
  where app.has_permission('inventory.view') and p.is_active
    and (p_item_type is null or (p_item_type = 'materials' and p.item_type <> 'finished_good') or p.item_type = p_item_type)
  group by p.id
  order by p.item_type, p.sort_order, p.name
$$;

-- Batch stock that expires soon (or already has)
create or replace function public.expiring_stock(p_days integer default null)
returns table (batch_id uuid, batch_no text, product text, location text, stock_status text, qty numeric, expiry_date date, days_left integer)
language sql stable security definer set search_path = '' as $$
  select b.id, b.batch_no, p.name, l.name, lt.stock_status, lt.qty, b.expiry_date, (b.expiry_date - app.today())::integer
    from public.inventory_lots lt
    join public.production_batches b on b.id = lt.batch_id
    join public.products p on p.id = lt.product_id
    join public.locations l on l.id = lt.location_id
   where (app.has_permission('inventory.view') or app.has_permission('production.view'))
     and lt.qty > 0 and lt.stock_status in ('available','qc_hold') and b.expiry_date is not null
     and b.expiry_date <= app.today() + coalesce(p_days, (app.get_setting('production.expiry_alert_days') #>> '{}')::integer, 30)
   order by b.expiry_date, b.batch_no
$$;

create or replace function public.batch_details(p_batch uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare b public.production_batches; v jsonb;
begin
  if not (app.has_permission('production.view') or app.has_permission('qc.view') or app.has_permission('inventory.view')) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  select * into b from public.production_batches where id = p_batch;
  if not found then raise exception 'Batch not found' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'batch', to_jsonb(b),
    'product', (select jsonb_build_object('id', p.id, 'name', p.name, 'sku', p.sku, 'is_returnable', p.is_returnable,
                  'shelf_life_days', p.shelf_life_days, 'bottle_type_id', p.bottle_type_id) from public.products p where p.id = b.product_id),
    'line', (select jsonb_build_object('id', ln.id, 'code', ln.code, 'name', ln.name) from public.production_lines ln where ln.id = b.line_id),
    'location', (select name from public.locations where id = b.location_id),
    'created_by', (select full_name from public.profiles where id = b.created_by),
    'released_by', (select full_name from public.profiles where id = b.released_by),
    'stages', (select coalesce(jsonb_agg(jsonb_build_object('stage', s.stage, 'recorded_at', s.recorded_at, 'reading', s.reading,
                 'notes', s.notes, 'by', (select full_name from public.profiles where id = s.recorded_by)) order by s.recorded_at), '[]')
                 from public.production_stage_logs s where s.batch_id = b.id),
    'materials', (select coalesce(jsonb_agg(jsonb_build_object('material_id', m.material_id, 'name', p.name, 'unit', p.unit, 'qty', m.qty,
                    'unit_cost', m.unit_cost, 'value', round(m.qty * m.unit_cost, 2)) order by p.name), '[]')
                    from public.production_batch_materials m join public.products p on p.id = m.material_id where m.batch_id = b.id),
    'bom', (select coalesce(jsonb_agg(jsonb_build_object('material_id', m.material_id, 'name', p.name, 'unit', p.unit,
              'qty_per_unit', m.qty_per_unit,
              'available', coalesce((select qty from public.inventory_balances ib where ib.location_id = b.location_id
                                      and ib.product_id = m.material_id and ib.stock_status = 'available'), 0)) order by p.name), '[]')
              from public.product_materials m join public.products p on p.id = m.material_id where m.product_id = b.product_id),
    'tests', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'test_no', t.test_no, 'tested_at', t.tested_at, 'result', t.result,
                'template', (select name from public.qc_templates where id = t.template_id), 'lab_name', t.lab_name,
                'sample_ref', t.sample_ref, 'notes', t.notes, 'certificate_path', t.certificate_path,
                'by', (select full_name from public.profiles where id = t.tested_by),
                'results', (select coalesce(jsonb_agg(jsonb_build_object('name', r.parameter_name, 'unit', r.unit, 'min', r.min_value,
                              'max', r.max_value, 'value', coalesce(r.value_num::text, r.value_text), 'passed', r.passed,
                              'required', r.is_required) order by r.sort_order), '[]')
                              from public.qc_test_results r where r.test_id = t.id)) order by t.tested_at desc), '[]')
                from public.qc_tests t where t.batch_id = b.id),
    'stock', (select coalesce(jsonb_agg(jsonb_build_object('location_id', lt.location_id, 'location', l.name, 'location_type', l.location_type,
                'status', lt.stock_status, 'qty', lt.qty) order by l.name, lt.stock_status), '[]')
                from public.inventory_lots lt join public.locations l on l.id = lt.location_id
               where lt.batch_id = b.id and lt.qty > 0),
    'sold', coalesce((select sum(qty) from public.inventory_transactions where batch_id = b.id and txn_type = 'sale'), 0),
    'disposed', coalesce((select sum(qty) from public.inventory_transactions where batch_id = b.id and txn_type = 'dispose'), 0),
    'bottles', (select coalesce(jsonb_agg(jsonb_build_object('code', bo.code, 'holder', app.holder_label(bo.holder_type, bo.holder_id),
                  'still_from_batch', bo.last_batch_id = b.id) order by bo.code), '[]')
                  from public.production_batch_bottles bb join public.bottles bo on bo.id = bb.bottle_id where bb.batch_id = b.id),
    'recalls', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'recall_no', r.recall_no, 'status', r.status, 'created_at', r.created_at)
                  order by r.created_at desc), '[]') from public.batch_recalls r where r.batch_id = b.id),
    'journals', (select coalesce(jsonb_agg(jsonb_build_object('entry_no', j.entry_no, 'entry_date', j.entry_date, 'event_type', j.event_type,
                   'total', j.total) order by j.created_at), '[]')
                   from public.journal_entries j where j.source_type = 'production_batch' and j.source_id = b.id)
  ) into v;
  return v;
end $$;

create or replace function public.recall_details(p_recall uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.batch_recalls; b public.production_batches; v jsonb;
begin
  if not app.has_permission('qc.view') then raise exception 'Permission denied' using errcode = '42501'; end if;
  select * into r from public.batch_recalls where id = p_recall;
  if not found then raise exception 'Recall not found' using errcode = 'P0002'; end if;
  select * into b from public.production_batches where id = r.batch_id;
  select jsonb_build_object(
    'recall', to_jsonb(r) || jsonb_build_object('created_by_name', (select full_name from public.profiles where id = r.created_by),
                                                'closed_by_name', (select full_name from public.profiles where id = r.closed_by)),
    'batch', jsonb_build_object('id', b.id, 'batch_no', b.batch_no, 'production_date', b.production_date, 'produced_qty', b.produced_qty,
                                'expiry_date', b.expiry_date, 'product', (select name from public.products where id = b.product_id)),
    'locations', (select coalesce(jsonb_agg(jsonb_build_object('location_id', l.id, 'location', l.name, 'type', l.location_type,
                    'status', lt.stock_status, 'qty', lt.qty) order by l.location_type, l.name), '[]')
                    from public.inventory_lots lt join public.locations l on l.id = lt.location_id
                   where lt.batch_id = b.id and lt.qty > 0),
    'customers', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'customer_id', c.id, 'name', c.name, 'customer_no', c.customer_no,
                    'phone', c.phone, 'is_walk_in', c.is_walk_in,
                    'address', (select a.address_line || coalesce(', ' || a.city, '') from public.customer_addresses a
                                 where a.customer_id = c.id order by a.is_default desc limit 1),
                    'qty_supplied', i.qty_supplied, 'bottles_held', i.bottles_held, 'qty_recovered', i.qty_recovered,
                    'status', i.status, 'note', i.note) order by i.status, c.name), '[]')
                    from public.batch_recall_customers i join public.customers c on c.id = i.customer_id where i.recall_id = r.id),
    'totals', jsonb_build_object(
        'produced', b.produced_qty,
        'sold', coalesce((select sum(qty) from public.inventory_transactions where batch_id = b.id and txn_type = 'sale'), 0),
        'in_circulation', coalesce((select sum(lt.qty) from public.inventory_lots lt where lt.batch_id = b.id and lt.stock_status = 'available'), 0),
        'quarantined', coalesce((select sum(lt.qty) from public.inventory_lots lt where lt.batch_id = b.id and lt.stock_status = 'quarantine'), 0),
        'recovered', coalesce((select sum(qty_recovered) from public.batch_recall_customers where recall_id = r.id), 0),
        'disposed', coalesce((select sum(qty) from public.inventory_transactions where batch_id = b.id and txn_type = 'dispose'), 0))
  ) into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Suppliers
-- ---------------------------------------------------------------------
create or replace function public.supplier_list()
returns table (id uuid, code text, name text, phone text, city text, vat_no text, payment_terms_days integer, is_active boolean,
               outstanding numeric, overdue numeric, open_orders bigint, receipts bigint, on_time_pct numeric, rejected_pct numeric)
language sql stable security definer set search_path = '' as $$
  select s.id, s.code, s.name, s.phone, s.city, s.vat_no, s.payment_terms_days, s.is_active,
    app.supplier_outstanding(s.id),
    coalesce((select sum(total - amount_paid) from public.supplier_invoices i where i.supplier_id = s.id
               and i.status in ('approved','partially_paid') and i.due_date < app.today()), 0),
    (select count(*) from public.purchase_orders o where o.supplier_id = s.id and o.status in ('pending_approval','approved','partially_received')),
    (select count(*) from public.goods_receipts g where g.supplier_id = s.id),
    (select round(100.0 * count(*) filter (where g.on_time) / nullif(count(*), 0), 0) from public.goods_receipts g where g.supplier_id = s.id),
    (select round(100.0 * sum(gl.qty_rejected) / nullif(sum(gl.qty_received + gl.qty_rejected), 0), 1)
       from public.goods_receipt_lines gl join public.goods_receipts g on g.id = gl.grn_id where g.supplier_id = s.id)
  from public.suppliers s
  where app.has_permission('procurement.view') or app.has_permission('suppliers.manage') or app.has_permission('payments.view')
  order by s.is_active desc, s.name
$$;

create or replace function public.supplier_details(p_supplier uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare s public.suppliers; v jsonb;
begin
  if not (app.has_permission('procurement.view') or app.has_permission('suppliers.manage') or app.has_permission('payments.view')) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  select * into s from public.suppliers where id = p_supplier;
  if not found then raise exception 'Supplier not found' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'supplier', to_jsonb(s),
    'outstanding', app.supplier_outstanding(s.id),
    'advance', coalesce((select sum(unallocated) from public.supplier_payments where supplier_id = s.id), 0),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('product_id', p.id, 'name', p.name, 'unit', p.unit, 'supplier_sku', si.supplier_sku,
                'unit_price', si.unit_price, 'lead_time_days', si.lead_time_days, 'is_preferred', si.is_preferred) order by p.name), '[]')
                from public.supplier_items si join public.products p on p.id = si.product_id where si.supplier_id = s.id),
    'orders', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'po_no', o.po_no, 'order_date', o.order_date,
                 'expected_date', o.expected_date, 'status', o.status, 'total', o.total) order by o.order_date desc, o.po_no desc), '[]')
                 from (select * from public.purchase_orders where supplier_id = s.id order by order_date desc limit 30) o),
    'invoices', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'ref_no', i.ref_no, 'supplier_invoice_no', i.supplier_invoice_no,
                   'invoice_date', i.invoice_date, 'due_date', i.due_date, 'total', i.total, 'amount_paid', i.amount_paid,
                   'balance', i.total - i.amount_paid, 'status', i.status, 'match_status', i.match_status,
                   'po_no', (select po_no from public.purchase_orders where id = i.po_id)) order by i.invoice_date desc), '[]')
                   from (select * from public.supplier_invoices where supplier_id = s.id order by invoice_date desc limit 50) i),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'payment_no', x.payment_no, 'paid_at', x.paid_at, 'method', x.method,
                   'amount', x.amount, 'unallocated', x.unallocated, 'reference', x.reference) order by x.paid_at desc), '[]')
                   from (select * from public.supplier_payments where supplier_id = s.id order by paid_at desc limit 30) x),
    'performance', jsonb_build_object(
        'receipts', (select count(*) from public.goods_receipts g where g.supplier_id = s.id),
        'on_time', (select count(*) from public.goods_receipts g where g.supplier_id = s.id and g.on_time),
        'qty_received', coalesce((select sum(gl.qty_received) from public.goods_receipt_lines gl join public.goods_receipts g on g.id = gl.grn_id
                                   where g.supplier_id = s.id), 0),
        'qty_rejected', coalesce((select sum(gl.qty_rejected) from public.goods_receipt_lines gl join public.goods_receipts g on g.id = gl.grn_id
                                   where g.supplier_id = s.id), 0),
        'mismatched_invoices', (select count(*) from public.supplier_invoices i where i.supplier_id = s.id and i.match_status <> 'matched'
                                  and i.status <> 'void'))
  ) into v;
  return v;
end $$;

create or replace function public.purchase_order_details(p_po uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o public.purchase_orders; v jsonb;
begin
  select * into o from public.purchase_orders where id = p_po;
  if not found then raise exception 'Purchase order not found' using errcode = 'P0002'; end if;
  if not (app.has_permission('procurement.view') or app.has_permission('inventory.manage') or app.has_permission('payments.view')) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'order', to_jsonb(o) || jsonb_build_object(
        'created_by_name', (select full_name from public.profiles where id = o.created_by),
        'approved_by_name', (select full_name from public.profiles where id = o.approved_by),
        'request_no', (select request_no from public.purchase_requests where id = o.request_id),
        'location', (select name from public.locations where id = o.location_id),
        'purchase_limit', coalesce((app.get_setting('approvals.purchase_amount') #>> '{}')::numeric, 0)),
    'supplier', (select jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name, 'phone', s.phone, 'email', s.email,
                   'address', s.address, 'city', s.city, 'vat_no', s.vat_no, 'payment_terms_days', s.payment_terms_days)
                   from public.suppliers s where s.id = o.supplier_id),
    'company', jsonb_build_object('name', app.get_setting('company.name') #>> '{}',
                                  'vat_no', app.get_setting('company.vat_registration_no') #>> '{}'),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'line_no', l.line_no, 'product_id', p.id, 'name', p.name, 'sku', p.sku,
                'unit', p.unit, 'qty_ordered', l.qty_ordered, 'unit_price', l.unit_price, 'tax_rate', l.tax_rate, 'net', l.net, 'tax', l.tax,
                'total', l.total, 'qty_received', l.qty_received, 'qty_rejected', l.qty_rejected, 'qty_invoiced', l.qty_invoiced)
                order by l.line_no), '[]')
                from public.purchase_order_lines l join public.products p on p.id = l.product_id where l.po_id = o.id),
    'receipts', (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'grn_no', g.grn_no, 'received_at', g.received_at,
                   'delivery_note_no', g.delivery_note_no, 'on_time', g.on_time,
                   'received_by', (select full_name from public.profiles where id = g.received_by),
                   'value', (select coalesce(sum(round(gl.qty_received * gl.unit_price, 2)), 0) from public.goods_receipt_lines gl where gl.grn_id = g.id),
                   'lines', (select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'qty_received', gl.qty_received,
                              'qty_rejected', gl.qty_rejected, 'reject_reason', gl.reject_reason, 'supplier_lot', gl.supplier_lot,
                              'expiry_date', gl.expiry_date)), '[]')
                              from public.goods_receipt_lines gl join public.products p on p.id = gl.product_id where gl.grn_id = g.id))
                   order by g.received_at), '[]')
                   from public.goods_receipts g where g.po_id = o.id),
    'invoices', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'ref_no', i.ref_no, 'supplier_invoice_no', i.supplier_invoice_no,
                   'invoice_date', i.invoice_date, 'due_date', i.due_date, 'total', i.total, 'amount_paid', i.amount_paid, 'status', i.status,
                   'match_status', i.match_status, 'match_notes', i.match_notes, 'decision_note', i.decision_note) order by i.created_at), '[]')
                   from public.supplier_invoices i where i.po_id = o.id)
  ) into v;
  return v;
end $$;

-- Figures for the dashboard and the operations pages
create or replace function public.operations_summary()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'production', case when app.has_permission('production.view') or app.has_permission('qc.view') then jsonb_build_object(
        'today_produced', coalesce((select sum(produced_qty) from public.production_batches where production_date = app.today()
                                     and status not in ('cancelled','planned','in_production')), 0),
        'in_production', (select count(*) from public.production_batches where status in ('planned','in_production')),
        'qc_hold', (select count(*) from public.production_batches where status = 'qc_hold'),
        'qc_hold_qty', coalesce((select sum(qty) from public.inventory_lots where stock_status = 'qc_hold'), 0),
        'quarantine_qty', coalesce((select sum(qty) from public.inventory_lots where stock_status = 'quarantine'), 0),
        'open_recalls', (select count(*) from public.batch_recalls where status = 'open'),
        'month_rejected', coalesce((select sum(rejected_qty) from public.production_batches
                                     where production_date >= date_trunc('month', app.today())::date), 0),
        'month_produced', coalesce((select sum(produced_qty) from public.production_batches
                                     where production_date >= date_trunc('month', app.today())::date), 0)) end,
    'stock', case when app.has_permission('inventory.view') then jsonb_build_object(
        'low_items', (select count(*) from (select p.id from public.products p
                         left join public.inventory_balances b on b.product_id = p.id and b.stock_status = 'available'
                        where p.is_active and p.reorder_level > 0 group by p.id, p.reorder_level
                       having coalesce(sum(b.qty), 0) <= p.reorder_level) x),
        'expiring', (select count(*) from public.expiring_stock(null)),
        'materials_value', coalesce((select round(sum(b.qty * p.cost_price), 2) from public.inventory_balances b
                                      join public.products p on p.id = b.product_id where p.item_type <> 'finished_good'), 0),
        'finished_value', coalesce((select round(sum(b.qty * p.cost_price), 2) from public.inventory_balances b
                                     join public.products p on p.id = b.product_id where p.item_type = 'finished_good'), 0)) end,
    'purchasing', case when app.has_permission('procurement.view') or app.has_permission('payments.view') then jsonb_build_object(
        'requests_waiting', (select count(*) from public.purchase_requests where status = 'submitted'),
        'orders_waiting', (select count(*) from public.purchase_orders where status = 'pending_approval'),
        'orders_open', (select count(*) from public.purchase_orders where status in ('approved','partially_received')),
        'orders_late', (select count(*) from public.purchase_orders where status in ('approved','partially_received')
                          and expected_date < app.today()),
        'invoices_on_hold', (select count(*) from public.supplier_invoices where status = 'on_hold'),
        'payable', coalesce((select sum(total - amount_paid) from public.supplier_invoices where status in ('approved','partially_paid')), 0),
        'payable_overdue', coalesce((select sum(total - amount_paid) from public.supplier_invoices
                                      where status in ('approved','partially_paid') and due_date < app.today()), 0),
        'due_7_days', coalesce((select sum(total - amount_paid) from public.supplier_invoices
                                 where status in ('approved','partially_paid') and due_date between app.today() and app.today() + 7), 0)) end
  )
$$;

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

-- >>> 20261004000025_qc_certificate_storage.sql
-- =====================================================================
-- OLA Water ERP — Phase 2A
-- 0025: private storage for QC certificates and lab reports
-- Path convention: qc-certificates/{batch_id}/{uuid}.{pdf|jpg|png}
-- (Skipped automatically where the Supabase storage schema is not present.)
-- =====================================================================
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('qc-certificates', 'qc-certificates', false, 10485760,
            array['application/pdf','image/jpeg','image/png','image/webp','image/heic'])
    on conflict (id) do nothing;

    execute $p$
      create policy "QC staff upload certificates for a batch" on storage.objects
        for insert to authenticated
        with check (
          bucket_id = 'qc-certificates'
          and app.has_permission('qc.manage')
          and exists (select 1 from public.production_batches b where b.id::text = (storage.foldername(name))[1])
        )
    $p$;
    execute $p$
      create policy "Staff read QC certificates" on storage.objects
        for select to authenticated
        using (bucket_id = 'qc-certificates' and (app.has_permission('qc.view') or app.has_permission('production.view')))
    $p$;
  end if;
exception when others then
  raise notice 'Storage bucket/policies not created (%). QC certificates cannot be uploaded until this is fixed.', sqlerrm;
end $$;

commit;
