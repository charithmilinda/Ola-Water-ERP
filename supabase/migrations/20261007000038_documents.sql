-- =====================================================================
-- OLA Water ERP — Phase 3A
-- 0038: document library — contracts, licences, insurance, employee
--       documents, lab reports, invoices … in a private bucket, access
--       by category permission, linked to a customer / supplier /
--       employee / vehicle / asset / batch, expiry dates with alerts
--       Path convention: documents/{category}/{uuid}.{ext}
-- =====================================================================

create table public.document_categories (
  code               text primary key check (code ~ '^[a-z][a-z0-9_]{2,30}$'),
  name               text not null,
  view_permission    text not null references public.permissions(code),
  manage_permission  text not null references public.permissions(code),
  has_expiry         boolean not null default false,
  is_active          boolean not null default true,
  sort_order         integer not null default 0
);
create trigger document_categories_audit after insert or update on public.document_categories
  for each row execute function app.audit_row('documents');

create table public.documents (
  id            uuid primary key default gen_random_uuid(),
  doc_no        text not null unique,
  category_code text not null references public.document_categories(code),
  title         text not null check (length(trim(title)) > 0),
  reference_no  text,                         -- policy / licence / contract number
  entity_type   text check (entity_type in ('customer','supplier','employee','vehicle','asset','batch','shop','company')),
  entity_id     uuid,
  file_path     text not null,
  file_name     text not null,
  mime_type     text,
  size_bytes    bigint,
  issued_on     date,
  expires_on    date,
  alert_days    integer not null default 30 check (alert_days between 0 and 365),
  notes         text,
  status        text not null default 'active' check (status in ('active','replaced','archived')),
  replaces_id   uuid references public.documents(id),
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  check (expires_on is null or issued_on is null or expires_on >= issued_on),
  check ((entity_type is null) = (entity_id is null) or entity_type = 'company')
);
create index documents_entity_idx on public.documents (entity_type, entity_id) where status = 'active';
create index documents_expiry_idx on public.documents (expires_on) where status = 'active' and expires_on is not null;
create trigger documents_touch before update on public.documents for each row execute function app.touch_updated_at();
create trigger documents_audit after insert or update on public.documents for each row execute function app.audit_row('documents');

create or replace function app.document_can(p_category text, p_manage boolean)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.document_categories c
                  where c.code = p_category
                    and app.has_permission(case when p_manage then c.manage_permission else c.view_permission end))
$$;

create or replace function app.entity_exists(p_type text, p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select case p_type
    when 'customer' then exists (select 1 from public.customers where id = p_id)
    when 'supplier' then exists (select 1 from public.suppliers where id = p_id)
    when 'employee' then exists (select 1 from public.employees where id = p_id)
    when 'vehicle'  then exists (select 1 from public.vehicles where id = p_id)
    when 'asset'    then exists (select 1 from public.fixed_assets where id = p_id)
    when 'batch'    then exists (select 1 from public.production_batches where id = p_id)
    when 'shop'     then exists (select 1 from public.water_shops where id = p_id)
    when 'company'  then true
    else false end
$$;

-- Register a file that the app has just uploaded.
-- p: category_code, title, reference_no, entity_type, entity_id, file_path, file_name, mime_type, size_bytes,
--    issued_on, expires_on, alert_days, notes, replaces_id
create or replace function public.register_document(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare cat public.document_categories; v uuid; v_no text; old public.documents; v_type text := app.jtext(p, 'entity_type');
begin
  select * into cat from public.document_categories where code = app.jtext(p, 'category_code') and is_active;
  if not found then raise exception 'Choose a document type' using errcode = '22023'; end if;
  if not app.has_permission(cat.manage_permission) then
    raise exception 'Permission denied: % is required for % documents', cat.manage_permission, lower(cat.name) using errcode = '42501';
  end if;
  if app.jtext(p, 'title') is null then raise exception 'Give the document a title' using errcode = '22023'; end if;
  if app.jtext(p, 'file_path') is null or split_part(app.jtext(p, 'file_path'), '/', 1) <> cat.code then
    raise exception 'The file was not uploaded' using errcode = '22023';
  end if;
  if v_type is not null and v_type <> 'company' and not app.entity_exists(v_type, app.juuid(p, 'entity_id')) then
    raise exception 'The linked record was not found' using errcode = '22023';
  end if;
  if cat.has_expiry and app.jtext(p, 'expires_on') is null then
    raise exception 'Enter the expiry date for this type of document' using errcode = '22023';
  end if;
  if app.juuid(p, 'replaces_id') is not null then
    select * into old from public.documents where id = app.juuid(p, 'replaces_id') for update;
    if not found or old.status <> 'active' then raise exception 'The document being replaced was not found' using errcode = '22023'; end if;
  end if;
  perform app.set_context(case when old.id is not null then 'New version of ' || old.doc_no end, null, null);
  v_no := app.next_document_number('DOC');
  insert into public.documents (doc_no, category_code, title, reference_no, entity_type, entity_id, file_path, file_name, mime_type,
    size_bytes, issued_on, expires_on, alert_days, notes, replaces_id, created_by)
  values (v_no, cat.code, app.jtext(p, 'title'), app.jtext(p, 'reference_no'),
    coalesce(v_type, old.entity_type), coalesce(app.juuid(p, 'entity_id'), old.entity_id),
    app.jtext(p, 'file_path'), coalesce(app.jtext(p, 'file_name'), 'file'), app.jtext(p, 'mime_type'), app.jint(p, 'size_bytes'),
    (app.jtext(p, 'issued_on'))::date, (app.jtext(p, 'expires_on'))::date,
    coalesce(app.jint(p, 'alert_days'), coalesce((app.get_setting('documents.alert_days') #>> '{}')::integer, 30)),
    app.jtext(p, 'notes'), old.id, app.current_user_id())
  returning id into v;
  if old.id is not null then
    update public.documents set status = 'replaced' where id = old.id;
  end if;
  return jsonb_build_object('document_id', v, 'doc_no', v_no);
end $$;

create or replace function public.update_document(p_id uuid, p jsonb, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare d public.documents;
begin
  select * into d from public.documents where id = p_id for update;
  if not found then raise exception 'Document not found' using errcode = 'P0002'; end if;
  if not app.document_can(d.category_code, true) then raise exception 'Permission denied' using errcode = '42501'; end if;
  if d.status <> 'active' then raise exception 'Only the current version can be edited' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  update public.documents set
    title = coalesce(app.jtext(p, 'title'), title),
    reference_no = case when p ? 'reference_no' then app.jtext(p, 'reference_no') else reference_no end,
    issued_on = case when p ? 'issued_on' then (app.jtext(p, 'issued_on'))::date else issued_on end,
    expires_on = case when p ? 'expires_on' then (app.jtext(p, 'expires_on'))::date else expires_on end,
    alert_days = coalesce(app.jint(p, 'alert_days'), alert_days),
    notes = case when p ? 'notes' then app.jtext(p, 'notes') else notes end
   where id = p_id;
end $$;

create or replace function public.archive_document(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare d public.documents;
begin
  select * into d from public.documents where id = p_id for update;
  if not found then raise exception 'Document not found' using errcode = 'P0002'; end if;
  if not app.document_can(d.category_code, true) then raise exception 'Permission denied' using errcode = '42501'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  perform app.set_context(trim(p_reason), null, 'archive');
  update public.documents set status = 'archived' where id = p_id and status = 'active';
end $$;

do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('documents', 'documents', false, 10485760,
            array['application/pdf','image/jpeg','image/png','image/webp','image/heic',
                  'application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
                  'application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
    on conflict (id) do nothing;
    execute $p$
      create policy "Staff upload documents they manage" on storage.objects for insert to authenticated
        with check (bucket_id = 'documents' and app.document_can((storage.foldername(name))[1], true))
    $p$;
    execute $p$
      create policy "Staff read documents they may view" on storage.objects for select to authenticated
        using (bucket_id = 'documents' and app.document_can((storage.foldername(name))[1], false))
    $p$;
  end if;
exception when others then
  raise notice 'Storage bucket/policies not created (%). Documents cannot be uploaded until this is fixed.', sqlerrm;
end $$;

alter table public.document_categories enable row level security;
alter table public.documents           enable row level security;
create policy document_categories_read on public.document_categories for select to authenticated using (true);
create policy documents_read on public.documents for select to authenticated using (app.document_can(category_code, false));
