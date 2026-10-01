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
