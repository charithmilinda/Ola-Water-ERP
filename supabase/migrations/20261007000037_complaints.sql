-- =====================================================================
-- OLA Water ERP — Phase 3A
-- 0037: complaints — New → Assigned → In Progress → Resolved → Closed,
--       priority with SLA due times, timeline, photos, links to order /
--       delivery / batch / bottle / shop, QC review for quality issues
-- =====================================================================

create table public.complaint_categories (
  code              text primary key check (code ~ '^[a-z][a-z0-9_]{2,30}$'),
  name              text not null,
  default_priority  text not null default 'normal' check (default_priority in ('low','normal','high','urgent')),
  needs_qc_review   boolean not null default false,
  is_active         boolean not null default true,
  sort_order        integer not null default 0
);
create trigger complaint_categories_audit after insert or update on public.complaint_categories
  for each row execute function app.audit_row('complaints');

create table public.complaints (
  id                 uuid primary key default gen_random_uuid(),
  complaint_no       text not null unique,
  category_code      text not null references public.complaint_categories(code),
  priority           text not null check (priority in ('low','normal','high','urgent')),
  status             text not null default 'new' check (status in ('new','assigned','in_progress','resolved','closed')),
  channel            text not null default 'phone' check (channel in ('phone','whatsapp','email','walk_in','driver','shop','sales_rep','other')),
  subject            text not null check (length(trim(subject)) > 0),
  description        text,
  customer_id        uuid references public.customers(id),
  contact_name       text,
  contact_phone      text,
  location_id        uuid references public.locations(id),         -- shop or warehouse concerned
  order_id           uuid references public.orders(id),
  delivery_id        uuid references public.deliveries(id),
  invoice_id         uuid references public.invoices(id),
  batch_id           uuid references public.production_batches(id),
  bottle_id          uuid references public.bottles(id),
  product_id         uuid references public.products(id),
  driver_id          uuid references public.profiles(id),
  assigned_to        uuid references public.profiles(id),
  due_at             timestamptz not null,
  first_response_at  timestamptz,
  resolved_at        timestamptz,
  resolution         text,
  root_cause         text,
  closed_at          timestamptz,
  qc_review_status   text check (qc_review_status in ('requested','done')),
  qc_finding         text,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  client_txn_id      uuid unique
);
create index complaints_open_idx on public.complaints (status, due_at) where status not in ('resolved','closed');
create index complaints_customer_idx on public.complaints (customer_id, created_at desc);
create index complaints_batch_idx on public.complaints (batch_id) where batch_id is not null;
create trigger complaints_touch before update on public.complaints for each row execute function app.touch_updated_at();
create trigger complaints_audit after insert or update on public.complaints for each row execute function app.audit_row('complaints');

create table public.complaint_events (
  id            uuid primary key default gen_random_uuid(),
  complaint_id  uuid not null references public.complaints(id),
  event         text not null check (event in ('created','assigned','status','note','photo','resolved','closed','reopened','qc_review')),
  from_status   text,
  to_status     text,
  note          text,
  photo_path    text,
  created_at    timestamptz not null default now(),
  created_by    uuid
);
create index complaint_events_idx on public.complaint_events (complaint_id, created_at);
create trigger complaint_events_append_only before update or delete on public.complaint_events for each row execute function app.forbid_change();

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create or replace function app.complaint_sla_hours(p_priority text)
returns integer language sql stable security definer set search_path = '' as $$
  select coalesce((app.get_setting('complaints.sla_hours_' || p_priority) #>> '{}')::integer,
                  case p_priority when 'urgent' then 4 when 'high' then 24 when 'normal' then 48 else 72 end)
$$;

create or replace function app.complaint_event(p_complaint uuid, p_event text, p_from text, p_to text, p_note text, p_photo text default null)
returns void language sql security definer set search_path = '' as $$
  insert into public.complaint_events (complaint_id, event, from_status, to_status, note, photo_path, created_by)
  values (p_complaint, p_event, p_from, p_to, nullif(trim(p_note), ''), p_photo, app.current_user_id())
$$;

create or replace function app.complaint_for_update(p_id uuid)
returns public.complaints language plpgsql security definer set search_path = '' as $$
declare c public.complaints;
begin
  perform app.require_permission('complaints.manage');
  select * into c from public.complaints where id = p_id for update;
  if not found then raise exception 'Complaint not found' using errcode = 'P0002'; end if;
  return c;
end $$;

-- ---------------------------------------------------------------------
-- Log a complaint
-- p: category_code, priority, channel, subject, description, customer_id, contact_name, contact_phone,
--    location_id, order_id, delivery_id, invoice_id, batch_id | batch_no, bottle_code, product_id,
--    assigned_to, photo_paths[]
-- ---------------------------------------------------------------------
create or replace function public.log_complaint(p jsonb, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_done jsonb; cat public.complaint_categories; v uuid := gen_random_uuid(); v_no text; v_prio text; v_batch uuid; v_bottle uuid;
        v_order public.orders; v_delivery public.deliveries; v_driver uuid; v_res jsonb; x text; v_cust uuid; v_assignee uuid;
begin
  if not (app.has_permission('complaints.manage') or app.has_permission('complaints.view')) then
    raise exception 'Permission denied: complaints.manage is required' using errcode = '42501';
  end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'log_complaint');
  if v_done is not null then return v_done; end if;
  select * into cat from public.complaint_categories where code = app.jtext(p, 'category_code') and is_active;
  if not found then raise exception 'Choose what the complaint is about' using errcode = '22023'; end if;
  if app.jtext(p, 'subject') is null then raise exception 'Describe the complaint in a few words' using errcode = '22023'; end if;
  v_prio := coalesce(app.jtext(p, 'priority'), cat.default_priority);
  if v_prio not in ('low','normal','high','urgent') then raise exception 'Unknown priority' using errcode = '22023'; end if;
  v_cust := app.juuid(p, 'customer_id');
  if v_cust is null and app.jtext(p, 'contact_phone') is null then
    raise exception 'Choose the customer, or enter a contact phone number' using errcode = '22023';
  end if;

  v_batch := app.juuid(p, 'batch_id');
  if v_batch is null and app.jtext(p, 'batch_no') is not null then
    select id into v_batch from public.production_batches where batch_no = upper(app.jtext(p, 'batch_no'));
    if v_batch is null then raise exception 'Batch % not found', app.jtext(p, 'batch_no') using errcode = '22023'; end if;
  end if;
  if app.jtext(p, 'bottle_code') is not null then
    v_bottle := (app.bottle_by_code(app.jtext(p, 'bottle_code'))).id;
    if v_bottle is null then raise exception 'Bottle % not found', app.jtext(p, 'bottle_code') using errcode = '22023'; end if;
  end if;
  if app.juuid(p, 'delivery_id') is not null then
    select * into v_delivery from public.deliveries where id = app.juuid(p, 'delivery_id');
    select driver_id into v_driver from public.route_runs where id = v_delivery.run_id;
  end if;
  if app.juuid(p, 'order_id') is not null then select * into v_order from public.orders where id = app.juuid(p, 'order_id'); end if;
  v_assignee := app.juuid(p, 'assigned_to');
  if v_assignee is not null and not exists (select 1 from public.profiles where id = v_assignee and is_active) then
    raise exception 'Choose an active user to handle it' using errcode = '22023';
  end if;

  perform app.set_context(null, p_client_txn_id, null);
  v_no := app.next_document_number('CMP');
  insert into public.complaints (id, complaint_no, category_code, priority, status, channel, subject, description, customer_id,
    contact_name, contact_phone, location_id, order_id, delivery_id, invoice_id, batch_id, bottle_id, product_id, driver_id,
    assigned_to, due_at, first_response_at, qc_review_status, created_by, client_txn_id)
  values (v, v_no, cat.code, v_prio, case when v_assignee is not null then 'assigned' else 'new' end,
    coalesce(app.jtext(p, 'channel'), 'phone'), app.jtext(p, 'subject'), app.jtext(p, 'description'),
    coalesce(v_cust, v_order.customer_id, v_delivery.customer_id), app.jtext(p, 'contact_name'), app.normalize_phone(app.jtext(p, 'contact_phone')),
    app.juuid(p, 'location_id'), coalesce(v_order.id, v_delivery.order_id), v_delivery.id, coalesce(app.juuid(p, 'invoice_id'), v_delivery.invoice_id),
    v_batch, v_bottle, app.juuid(p, 'product_id'), coalesce(app.juuid(p, 'driver_id'), v_driver), v_assignee,
    now() + make_interval(hours => app.complaint_sla_hours(v_prio)),
    case when v_assignee is not null then now() end,
    case when cat.needs_qc_review and v_batch is not null then 'requested' end,
    app.current_user_id(), p_client_txn_id);
  perform app.complaint_event(v, 'created', null, case when v_assignee is not null then 'assigned' else 'new' end, app.jtext(p, 'description'));
  for x in select jsonb_array_elements_text(coalesce(p -> 'photo_paths', '[]')) loop
    perform app.complaint_event(v, 'photo', null, null, null, x);
  end loop;

  if v_assignee is not null then
    perform app.notify('complaint_assigned', 'Complaint ' || v_no || ' assigned to you', app.jtext(p, 'subject'), '/complaints/' || v,
      'complaint-assigned:' || v || ':' || v_assignee, v_assignee, case when v_prio in ('high','urgent') then 'warning' end);
  else
    perform app.notify('complaint_new', 'New ' || v_prio || ' complaint ' || v_no, app.jtext(p, 'subject'), '/complaints/' || v,
      'complaint-new:' || v, null, case when v_prio = 'urgent' then 'critical' when v_prio = 'high' then 'warning' end);
  end if;
  if cat.needs_qc_review and v_batch is not null then
    perform app.notify('qc_review', 'Quality complaint on batch ' || (select batch_no from public.production_batches where id = v_batch),
      app.jtext(p, 'subject'), '/complaints/' || v, 'qc-review:' || v, null, 'warning');
  end if;
  perform app.queue_customer_message('COMPLAINT_RECEIVED', coalesce(v_cust, v_order.customer_id, v_delivery.customer_id),
    jsonb_build_object('complaint_no', v_no, 'subject', app.jtext(p, 'subject')), 'complaint', v, 'complaint-received:' || v);

  v_res := jsonb_build_object('complaint_id', v, 'complaint_no', v_no);
  perform app.idempotency_finish(p_client_txn_id, v_res);
  return v_res;
end $$;

create or replace function public.assign_complaint(p_id uuid, p_user uuid, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.complaints; v_name text;
begin
  c := app.complaint_for_update(p_id);
  if c.status in ('resolved','closed') then raise exception 'Reopen the complaint first' using errcode = '22023'; end if;
  select full_name into v_name from public.profiles where id = p_user and is_active;
  if v_name is null then raise exception 'Choose an active user' using errcode = '22023'; end if;
  perform app.set_context(coalesce(nullif(trim(p_note), ''), 'Assigned to ' || v_name), null, 'assign');
  update public.complaints set assigned_to = p_user, status = case when status = 'new' then 'assigned' else status end,
         first_response_at = coalesce(first_response_at, now()) where id = p_id;
  perform app.complaint_event(p_id, 'assigned', c.status, case when c.status = 'new' then 'assigned' else c.status end,
    'Assigned to ' || v_name || coalesce(' — ' || nullif(trim(p_note), ''), ''));
  if p_user <> app.current_user_id() then
    perform app.notify('complaint_assigned', 'Complaint ' || c.complaint_no || ' assigned to you', c.subject, '/complaints/' || p_id,
      'complaint-assigned:' || p_id || ':' || p_user || ':' || extract(epoch from now())::bigint, p_user,
      case when c.priority in ('high','urgent') then 'warning' end);
  end if;
end $$;

create or replace function public.update_complaint(p_id uuid, p jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.complaints; v_status text; v_prio text;
begin
  c := app.complaint_for_update(p_id);
  v_status := coalesce(app.jtext(p, 'status'), c.status);
  v_prio := coalesce(app.jtext(p, 'priority'), c.priority);
  if v_status not in ('new','assigned','in_progress') and v_status <> c.status then
    raise exception 'Use Resolve or Close for that' using errcode = '22023';
  end if;
  if c.status in ('resolved','closed') and (v_status <> c.status or v_prio <> c.priority) then
    raise exception 'Reopen the complaint first' using errcode = '22023';
  end if;
  if v_prio not in ('low','normal','high','urgent') then raise exception 'Unknown priority' using errcode = '22023'; end if;
  perform app.set_context(app.jtext(p, 'note'), null, null);
  update public.complaints set
    status = v_status,
    priority = v_prio,
    due_at = case when v_prio <> c.priority then created_at + make_interval(hours => app.complaint_sla_hours(v_prio)) else due_at end,
    first_response_at = case when v_status in ('assigned','in_progress') then coalesce(first_response_at, now()) else first_response_at end,
    category_code = coalesce(app.jtext(p, 'category_code'), category_code)
   where id = p_id;
  if v_status <> c.status then
    perform app.complaint_event(p_id, 'status', c.status, v_status, app.jtext(p, 'note'));
  end if;
  if v_prio <> c.priority then
    perform app.complaint_event(p_id, 'note', null, null, 'Priority ' || c.priority || ' → ' || v_prio || coalesce('. ' || app.jtext(p, 'note'), ''));
  elsif v_status = c.status and app.jtext(p, 'note') is not null then
    perform app.complaint_event(p_id, 'note', null, null, app.jtext(p, 'note'));
  end if;
end $$;

create or replace function public.add_complaint_note(p_id uuid, p_note text, p_photo_paths text[] default '{}')
returns void language plpgsql security definer set search_path = '' as $$
declare c public.complaints; x text;
begin
  c := app.complaint_for_update(p_id);
  if nullif(trim(p_note), '') is null and cardinality(coalesce(p_photo_paths, '{}')) = 0 then
    raise exception 'Write a note or add a photo' using errcode = '22023';
  end if;
  if nullif(trim(p_note), '') is not null then perform app.complaint_event(p_id, 'note', null, null, p_note); end if;
  foreach x in array coalesce(p_photo_paths, '{}') loop
    perform app.complaint_event(p_id, 'photo', null, null, null, x);
  end loop;
  update public.complaints set first_response_at = coalesce(first_response_at, now()) where id = p_id;
end $$;

create or replace function public.resolve_complaint(p_id uuid, p_resolution text, p_root_cause text)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.complaints;
begin
  c := app.complaint_for_update(p_id);
  if c.status in ('resolved','closed') then raise exception 'Already %', c.status using errcode = '22023'; end if;
  if nullif(trim(p_resolution), '') is null then raise exception 'Say what was done to resolve it' using errcode = '22023'; end if;
  if c.qc_review_status = 'requested' then raise exception 'Quality control must finish its review of the batch first' using errcode = '22023'; end if;
  perform app.set_context(trim(p_resolution), null, 'resolve');
  update public.complaints set status = 'resolved', resolution = trim(p_resolution), root_cause = nullif(trim(p_root_cause), ''),
         resolved_at = now(), first_response_at = coalesce(first_response_at, now()) where id = p_id;
  perform app.complaint_event(p_id, 'resolved', c.status, 'resolved', trim(p_resolution));
  if c.customer_id is not null then
    perform app.queue_customer_message('COMPLAINT_RESOLVED', c.customer_id,
      jsonb_build_object('complaint_no', c.complaint_no, 'subject', c.subject, 'resolution', trim(p_resolution)),
      'complaint', c.id, 'complaint-resolved:' || c.id || ':' || extract(epoch from now())::bigint);
  end if;
  if c.created_by is not null and c.created_by <> app.current_user_id() then
    perform app.notify('complaint_assigned', 'Complaint ' || c.complaint_no || ' resolved', trim(p_resolution), '/complaints/' || p_id,
      'complaint-resolved:' || p_id || ':' || extract(epoch from now())::bigint, c.created_by);
  end if;
end $$;

create or replace function public.close_complaint(p_id uuid, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.complaints;
begin
  c := app.complaint_for_update(p_id);
  if c.status <> 'resolved' then raise exception 'Resolve the complaint before closing it' using errcode = '22023'; end if;
  perform app.set_context(coalesce(nullif(trim(p_note), ''), 'Closed'), null, 'close');
  update public.complaints set status = 'closed', closed_at = now() where id = p_id;
  perform app.complaint_event(p_id, 'closed', 'resolved', 'closed', p_note);
end $$;

create or replace function public.reopen_complaint(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.complaints;
begin
  c := app.complaint_for_update(p_id);
  if c.status not in ('resolved','closed') then raise exception 'The complaint is still open' using errcode = '22023'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'Give a reason for reopening' using errcode = '22023'; end if;
  perform app.set_context(trim(p_reason), null, 'reopen');
  update public.complaints set status = case when assigned_to is not null then 'in_progress' else 'new' end,
         resolved_at = null, closed_at = null where id = p_id;
  perform app.complaint_event(p_id, 'reopened', c.status, case when c.assigned_to is not null then 'in_progress' else 'new' end, trim(p_reason));
end $$;

-- Quality control records its finding on a quality complaint (re-test, hold or recall are done in Quality Control).
create or replace function public.complete_complaint_qc_review(p_id uuid, p_finding text)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.complaints;
begin
  perform app.require_permission('qc.manage');
  select * into c from public.complaints where id = p_id for update;
  if not found then raise exception 'Complaint not found' using errcode = 'P0002'; end if;
  if c.batch_id is null then raise exception 'No batch is linked to this complaint' using errcode = '22023'; end if;
  if nullif(trim(p_finding), '') is null then raise exception 'Write what quality control found' using errcode = '22023'; end if;
  perform app.set_context(trim(p_finding), null, 'qc_review');
  update public.complaints set qc_review_status = 'done', qc_finding = trim(p_finding) where id = p_id;
  perform app.complaint_event(p_id, 'qc_review', null, null, 'QC review: ' || trim(p_finding));
  if c.assigned_to is not null then
    perform app.notify('complaint_assigned', 'QC review done for ' || c.complaint_no, trim(p_finding), '/complaints/' || p_id,
      'qc-done:' || p_id, c.assigned_to);
  end if;
end $$;

-- Quality can also ask for a review on any complaint that names a batch.
create or replace function public.request_complaint_qc_review(p_id uuid, p_batch_no text, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.complaints; v_batch uuid;
begin
  c := app.complaint_for_update(p_id);
  v_batch := coalesce((select id from public.production_batches where batch_no = upper(trim(p_batch_no))), c.batch_id);
  if v_batch is null then raise exception 'Enter the batch number from the bottle label' using errcode = '22023'; end if;
  perform app.set_context(coalesce(nullif(trim(p_note), ''), 'QC review requested'), null, null);
  update public.complaints set batch_id = v_batch, qc_review_status = 'requested', qc_finding = null where id = p_id;
  perform app.complaint_event(p_id, 'qc_review', null, null, 'QC review requested' || coalesce(': ' || nullif(trim(p_note), ''), ''));
  perform app.notify('qc_review', 'Quality complaint on batch ' || (select batch_no from public.production_batches where id = v_batch),
    c.subject, '/complaints/' || p_id, 'qc-review:' || p_id || ':' || extract(epoch from now())::bigint, null, 'warning');
end $$;

-- ---------------------------------------------------------------------
-- Photos: private bucket complaint-photos/{complaint or 'new'}/{uuid}.jpg
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('complaint-photos', 'complaint-photos', false, 5242880, array['image/jpeg','image/png','image/webp','image/heic'])
    on conflict (id) do nothing;
    execute $p$
      create policy "Complaint staff upload photos" on storage.objects for insert to authenticated
        with check (bucket_id = 'complaint-photos' and (app.has_permission('complaints.manage') or app.has_permission('complaints.view')))
    $p$;
    execute $p$
      create policy "Complaint staff read photos" on storage.objects for select to authenticated
        using (bucket_id = 'complaint-photos' and (app.has_permission('complaints.view') or app.has_permission('complaints.manage')
                                                   or app.has_permission('qc.view')))
    $p$;
  end if;
exception when others then
  raise notice 'Storage bucket/policies not created (%). Complaint photos cannot be stored until this is fixed.', sqlerrm;
end $$;

alter table public.complaint_categories enable row level security;
alter table public.complaints           enable row level security;
alter table public.complaint_events     enable row level security;
create policy complaint_categories_read on public.complaint_categories for select to authenticated using (true);
create policy complaints_read on public.complaints for select to authenticated
  using (app.has_permission('complaints.view') or app.has_permission('complaints.manage')
         or (batch_id is not null and app.has_permission('qc.view')) or assigned_to = app.current_user_id());
create policy complaint_events_read on public.complaint_events for select to authenticated
  using (exists (select 1 from public.complaints c where c.id = complaint_id));
