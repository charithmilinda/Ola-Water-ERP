-- =====================================================================
-- OLA Water ERP — Phase 0
-- 0004: identifier service (barcodes / QR / Data Matrix, future RFID/NFC)
--        and label batches
-- =====================================================================
-- Barcodes only identify a record; business data stays in the database.
-- Identifiers are generated in numbered series, printed as label batches,
-- and later bound to an entity (bottle, crate, bin...) by Phase 1 RPCs.
-- =====================================================================

create table public.identifier_series (
  code         text primary key check (code ~ '^[A-Z0-9]{2,8}(-[A-Z0-9]{2,8}){1,2}$'),
  name         text not null,
  entity_type  text not null check (entity_type in ('bottle','external_bottle','crate','location_bin','product')),
  padding      integer not null default 8 check (padding between 4 and 12),
  next_value   bigint not null default 1 check (next_value >= 1),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
comment on table public.identifier_series is 'e.g. OLA-BTL -> OLA-BTL-00000001, EXT-AQUA -> EXT-AQUA-00000001';

create table public.label_batches (
  id             uuid primary key default gen_random_uuid(),
  batch_no       text not null unique,
  series_code    text not null references public.identifier_series(code),
  first_value    bigint not null,
  last_value     bigint not null,
  quantity       integer not null check (quantity between 1 and 5000),
  symbology      text not null check (symbology in ('qrcode','datamatrix','code128')),
  label_size     text not null check (label_size in ('50x25','40x30','30x20')),
  status         text not null default 'generated' check (status in ('generated','printed','cancelled')),
  print_count    integer not null default 0 check (print_count >= 0),
  notes          text,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  last_printed_at timestamptz,
  last_printed_by uuid,
  cancelled_at   timestamptz,
  cancelled_by   uuid,
  updated_at     timestamptz not null default now(),
  check (last_value - first_value + 1 = quantity)
);
create index label_batches_created_idx on public.label_batches (created_at desc);

create table public.identifiers (
  id               uuid primary key default gen_random_uuid(),
  value            text not null unique,
  identifier_type  text not null check (identifier_type in ('barcode','qrcode','datamatrix','rfid','nfc')),
  series_code      text references public.identifier_series(code),
  label_batch_id   uuid references public.label_batches(id),
  entity_type      text not null check (entity_type in ('bottle','external_bottle','crate','location_bin','product')),
  entity_id        uuid,
  status           text not null default 'unassigned' check (status in ('unassigned','assigned','void')),
  assigned_at      timestamptz,
  assigned_by      uuid,
  voided_at        timestamptz,
  void_reason      text,
  created_at       timestamptz not null default now(),
  check ((status = 'assigned') = (entity_id is not null)),
  check (status <> 'void' or void_reason is not null)
);
create index identifiers_entity_idx on public.identifiers (entity_type, entity_id) where entity_id is not null;
create index identifiers_batch_idx  on public.identifiers (label_batch_id);

-- Triggers.  Identifier inserts are logged once per batch (not per label);
-- every later change to an identifier is audited row by row.
create trigger identifier_series_touch before update on public.identifier_series for each row execute function app.touch_updated_at();
create trigger label_batches_touch     before update on public.label_batches     for each row execute function app.touch_updated_at();

create trigger identifier_series_audit after insert or update or delete on public.identifier_series
  for each row execute function app.audit_row('labels', 'code');
create trigger label_batches_audit after insert or update or delete on public.label_batches
  for each row execute function app.audit_row('labels');
create trigger identifiers_audit after update or delete on public.identifiers
  for each row execute function app.audit_row('labels');

create trigger identifiers_no_delete before delete on public.identifiers
  for each row execute function app.forbid_change();
create trigger label_batches_no_delete before delete on public.label_batches
  for each row execute function app.forbid_change();

-- Look up an identifier by its scanned value (used by every scan field)
create or replace function public.lookup_identifier(p_value text)
returns table (
  id uuid, value text, identifier_type text, series_code text,
  entity_type text, entity_id uuid, status text, label_batch_id uuid
)
language sql stable
security definer
set search_path = ''
as $$
  select i.id, i.value, i.identifier_type, i.series_code, i.entity_type, i.entity_id, i.status, i.label_batch_id
    from public.identifiers i
   where app.current_user_id() is not null
     and i.value = upper(trim(p_value))
$$;

-- ---------------------------------------------------------------------
-- Generate a label batch
-- ---------------------------------------------------------------------
create or replace function public.generate_label_batch(
  p_series_code    text,
  p_quantity       integer,
  p_symbology      text,
  p_label_size     text,
  p_notes          text,
  p_client_txn_id  uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_done     jsonb;
  v_series   public.identifier_series;
  v_first    bigint;
  v_last     bigint;
  v_batch_id uuid;
  v_batch_no text;
  v_type     text;
  v_result   jsonb;
begin
  perform app.require_permission('labels.print');
  v_done := app.idempotency_begin(p_client_txn_id, 'generate_label_batch');
  if v_done is not null then return v_done; end if;

  if p_quantity is null or p_quantity < 1 or p_quantity > 5000 then
    raise exception 'Quantity must be between 1 and 5000' using errcode = '22023';
  end if;

  select * into v_series from public.identifier_series where code = p_series_code for update;
  if not found or not v_series.is_active then
    raise exception 'Identifier series % is not available', p_series_code using errcode = '22023';
  end if;

  v_first := v_series.next_value;
  v_last  := v_first + p_quantity - 1;
  if length(v_last::text) > v_series.padding then
    raise exception 'Series % would exceed % digits', p_series_code, v_series.padding using errcode = '22023';
  end if;

  perform app.set_context(null, p_client_txn_id, null);

  update public.identifier_series set next_value = v_last + 1 where code = p_series_code;

  v_batch_no := app.next_document_number('LBL');
  v_type := case p_symbology when 'code128' then 'barcode' else p_symbology end;

  insert into public.label_batches (
    batch_no, series_code, first_value, last_value, quantity, symbology, label_size, notes, created_by
  ) values (
    v_batch_no, p_series_code, v_first, v_last, p_quantity, p_symbology, p_label_size,
    nullif(trim(p_notes), ''), app.current_user_id()
  ) returning id into v_batch_id;

  insert into public.identifiers (value, identifier_type, series_code, label_batch_id, entity_type)
  select p_series_code || '-' || lpad(n::text, v_series.padding, '0'),
         v_type, p_series_code, v_batch_id, v_series.entity_type
    from generate_series(v_first, v_last) as n;

  v_result := jsonb_build_object(
    'batch_id', v_batch_id,
    'batch_no', v_batch_no,
    'first', p_series_code || '-' || lpad(v_first::text, v_series.padding, '0'),
    'last',  p_series_code || '-' || lpad(v_last::text,  v_series.padding, '0'),
    'quantity', p_quantity
  );
  perform app.idempotency_finish(p_client_txn_id, v_result);
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- Record that a batch was printed (reprints require a reason)
-- ---------------------------------------------------------------------
create or replace function public.record_label_print(
  p_batch_id uuid,
  p_reason   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch public.label_batches;
begin
  perform app.require_permission('labels.print');

  select * into v_batch from public.label_batches where id = p_batch_id for update;
  if not found then
    raise exception 'Label batch not found' using errcode = 'P0002';
  end if;
  if v_batch.status = 'cancelled' then
    raise exception 'Label batch % is cancelled', v_batch.batch_no using errcode = '22023';
  end if;
  if v_batch.print_count > 0 and nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required to reprint labels' using errcode = '22023';
  end if;

  perform app.set_context(
    nullif(trim(p_reason), ''), null,
    case when v_batch.print_count > 0 then 'reprint' else 'print' end
  );

  update public.label_batches
     set status = 'printed',
         print_count = print_count + 1,
         last_printed_at = now(),
         last_printed_by = app.current_user_id()
   where id = p_batch_id;

  return jsonb_build_object('batch_id', p_batch_id, 'print_count', v_batch.print_count + 1);
end;
$$;

-- ---------------------------------------------------------------------
-- Cancel a batch (only if none of its labels have been applied)
-- ---------------------------------------------------------------------
create or replace function public.cancel_label_batch(p_batch_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch public.label_batches;
begin
  perform app.require_permission('labels.print');
  if nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required' using errcode = '22023';
  end if;

  select * into v_batch from public.label_batches where id = p_batch_id for update;
  if not found then
    raise exception 'Label batch not found' using errcode = 'P0002';
  end if;
  if v_batch.status = 'cancelled' then
    raise exception 'Label batch % is already cancelled', v_batch.batch_no using errcode = '22023';
  end if;
  if exists (select 1 from public.identifiers where label_batch_id = p_batch_id and status = 'assigned') then
    raise exception 'Some labels in % are already applied and cannot be cancelled', v_batch.batch_no
      using errcode = '22023';
  end if;

  perform app.set_context(trim(p_reason), null, 'cancel');

  update public.identifiers
     set status = 'void', voided_at = now(), void_reason = trim(p_reason)
   where label_batch_id = p_batch_id and status = 'unassigned';

  update public.label_batches
     set status = 'cancelled', cancelled_at = now(), cancelled_by = app.current_user_id()
   where id = p_batch_id;

  return jsonb_build_object('batch_id', p_batch_id, 'status', 'cancelled');
end;
$$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.identifier_series enable row level security;
alter table public.label_batches     enable row level security;
alter table public.identifiers       enable row level security;

create policy identifier_series_read on public.identifier_series
  for select to authenticated using (true);
create policy label_batches_read on public.label_batches
  for select to authenticated using (app.has_permission('labels.print') or app.has_permission('labels.view'));
create policy identifiers_read on public.identifiers
  for select to authenticated using (app.has_permission('labels.print') or app.has_permission('labels.view'));
