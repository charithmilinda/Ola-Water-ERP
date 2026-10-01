-- OLA Water ERP — Phase 3A database update (approvals, notifications & messages, complaints, documents)
-- Run ONCE in Supabase → SQL Editor → New query, on the database that already has Phase 2C.
-- It runs as one transaction: if anything fails, nothing is changed.
begin;

-- >>> 20261007000035_notifications_messaging.sql
-- =====================================================================
-- OLA Water ERP — Phase 3A
-- 0035: in-app notifications, message templates and the outbox for
--       email / SMS / WhatsApp (sent by the app server through the
--       provider configured in Vercel), customer message triggers
-- =====================================================================

-- ---------------------------------------------------------------------
-- Notification types: who receives each kind of alert, and how
-- ---------------------------------------------------------------------
create table public.notification_types (
  code         text primary key check (code ~ '^[a-z][a-z0-9_]{2,40}$'),
  name         text not null,
  description  text,
  permission   text references public.permissions(code),      -- staff holding this permission receive it
  severity     text not null default 'info' check (severity in ('info','warning','critical')),
  in_app       boolean not null default true,
  email        boolean not null default false,                 -- also email staff who have an email address
  is_active    boolean not null default true,
  sort_order   integer not null default 0
);
create trigger notification_types_audit after insert or update on public.notification_types
  for each row execute function app.audit_row('notifications');

create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id),
  type_code   text not null references public.notification_types(code),
  title       text not null,
  body        text,
  href        text,
  severity    text not null default 'info' check (severity in ('info','warning','critical')),
  dedupe_key  text,
  created_at  timestamptz not null default now(),
  read_at     timestamptz
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_unread_idx on public.notifications (user_id) where read_at is null;
create unique index notifications_dedupe_idx on public.notifications (user_id, dedupe_key) where dedupe_key is not null;

-- ---------------------------------------------------------------------
-- Message templates (English) and the outbox
-- ---------------------------------------------------------------------
create table public.message_templates (
  code              text primary key check (code ~ '^[A-Z][A-Z0-9_]{2,40}$'),
  name              text not null,
  audience          text not null check (audience in ('customer','staff')),
  channel           text not null check (channel in ('sms','whatsapp','email')),
  subject           text,
  body              text not null check (length(trim(body)) > 0),
  whatsapp_template text,          -- approved WhatsApp template name (business-initiated messages)
  variables         text[] not null default '{}',   -- placeholders in the order WhatsApp expects them
  is_active         boolean not null default false,
  updated_at        timestamptz not null default now()
);
create trigger message_templates_touch before update on public.message_templates for each row execute function app.touch_updated_at();
create trigger message_templates_audit after insert or update on public.message_templates
  for each row execute function app.audit_row('notifications');

create table public.message_outbox (
  id              uuid primary key default gen_random_uuid(),
  channel         text not null check (channel in ('sms','whatsapp','email')),
  to_address      text not null,
  to_name         text,
  subject         text,
  body            text not null,
  template_code   text references public.message_templates(code),
  wa_template     text,
  wa_params       jsonb not null default '[]',
  customer_id     uuid references public.customers(id),
  user_id         uuid references public.profiles(id),
  related_type    text,
  related_id      uuid,
  dedupe_key      text unique,
  status          text not null default 'queued' check (status in ('queued','sending','sent','failed','cancelled')),
  attempts        integer not null default 0,
  last_error      text,
  provider        text,
  provider_ref    text,
  next_attempt_at timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  created_by      uuid,
  sent_at         timestamptz
);
create index message_outbox_queue_idx on public.message_outbox (next_attempt_at) where status = 'queued';
create index message_outbox_customer_idx on public.message_outbox (customer_id, created_at desc);
create trigger message_outbox_audit after insert or update on public.message_outbox
  for each row execute function app.audit_row('notifications');

alter table public.customers add column messages_opt_out boolean not null default false;
comment on column public.customers.messages_opt_out is 'Customer asked not to receive SMS / WhatsApp messages (reminders and updates).';

-- Throttle for the background scan
create table public.notification_scan_state (
  id          integer primary key default 1 check (id = 1),
  last_run_at timestamptz not null default '-infinity',
  last_dispatch_at timestamptz not null default '-infinity'
);
insert into public.notification_scan_state default values;

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
-- Fill {{placeholders}} from a jsonb object.
create or replace function app.render_template(p_text text, p_vars jsonb)
returns text language plpgsql immutable set search_path = '' as $$
declare k text; v text; r text := p_text;
begin
  if r is null then return null; end if;
  for k, v in select key, value from jsonb_each_text(coalesce(p_vars, '{}')) loop
    r := replace(r, '{{' || k || '}}', coalesce(v, ''));
  end loop;
  return regexp_replace(r, '\{\{[a-z_]+\}\}', '', 'g');
end $$;

-- Send an in-app notification to one user, or to every active user holding the type's permission
-- (or p_permission when given, e.g. the approver permission of an approval rule).
-- Returns the number of notifications created (duplicates by dedupe key are skipped).
create or replace function app.notify(
  p_type text, p_title text, p_body text default null, p_href text default null,
  p_dedupe text default null, p_user uuid default null, p_severity text default null, p_permission text default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare t public.notification_types; n integer := 0; u record; v_new uuid; v_perm text;
begin
  select * into t from public.notification_types where code = p_type;
  if not found or not t.is_active then return 0; end if;
  v_perm := coalesce(p_permission, t.permission);
  for u in
    select p.id, p.email, p.full_name from public.profiles p
     where p.is_active
       and (case when p_user is not null then p.id = p_user
                 else v_perm is not null and (
                        app.is_super_admin(p.id)
                        or exists (select 1 from public.user_roles ur
                                     join public.roles r on r.id = ur.role_id and r.archived_at is null
                                     join public.role_permissions rp on rp.role_id = r.id
                                    where ur.user_id = p.id and rp.permission_code = v_perm)) end)
  loop
    v_new := null;
    if t.in_app then
      insert into public.notifications (user_id, type_code, title, body, href, severity, dedupe_key)
      values (u.id, t.code, p_title, p_body, p_href, coalesce(p_severity, t.severity), p_dedupe)
      on conflict (user_id, dedupe_key) where dedupe_key is not null do nothing
      returning id into v_new;
      if v_new is not null then n := n + 1; end if;
    end if;
    if t.email and u.email is not null and (v_new is not null or not t.in_app) then
      insert into public.message_outbox (channel, to_address, to_name, subject, body, user_id, related_type, dedupe_key)
      values ('email', u.email, u.full_name, 'OLA ERP: ' || p_title, coalesce(p_body, p_title) ||
              case when p_href is not null then E'\n\nOpen: ' || p_href else '' end, u.id, 'notification',
              case when p_dedupe is not null then 'staff:' || u.id || ':' || p_dedupe end)
      on conflict (dedupe_key) do nothing;
    end if;
  end loop;
  return n;
end $$;

-- Queue a customer message from a template. Silently does nothing when messaging is off, the
-- template is inactive, the customer opted out, or there is no phone/email for the channel.
create or replace function app.queue_customer_message(
  p_template text, p_customer uuid, p_vars jsonb, p_related_type text default null, p_related_id uuid default null,
  p_dedupe text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare t public.message_templates; c public.customers; v uuid; v_to text; v_vars jsonb; v_params jsonb;
begin
  if not coalesce((app.get_setting('messaging.enabled') #>> '{}')::boolean, false) then return null; end if;
  select * into t from public.message_templates where code = p_template and is_active and audience = 'customer';
  if not found then return null; end if;
  select * into c from public.customers where id = p_customer;
  if not found or c.messages_opt_out or c.is_walk_in or c.status = 'inactive' then return null; end if;
  v_to := case when t.channel = 'email' then c.email else c.phone end;
  if v_to is null then return null; end if;
  v_vars := jsonb_build_object('customer_name', c.name, 'customer_no', c.customer_no,
              'company_name', coalesce(app.get_setting('company.name') #>> '{}', 'OLA Water'),
              'company_phone', coalesce(app.get_setting('company.phone') #>> '{}', '')) || coalesce(p_vars, '{}');
  select coalesce(jsonb_agg(coalesce(v_vars ->> x, '') order by i), '[]') into v_params
    from unnest(t.variables) with ordinality as u(x, i);
  insert into public.message_outbox (channel, to_address, to_name, subject, body, template_code, wa_template, wa_params,
    customer_id, related_type, related_id, dedupe_key, created_by)
  values (t.channel, v_to, c.name, app.render_template(t.subject, v_vars), app.render_template(t.body, v_vars), t.code,
          t.whatsapp_template, v_params, c.id, p_related_type, p_related_id, p_dedupe, app.current_user_id())
  on conflict (dedupe_key) do nothing
  returning id into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Customer messages fired by business events
-- ---------------------------------------------------------------------
create or replace function app.order_message_trigger()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'confirmed' and (tg_op = 'INSERT' or old.status is distinct from 'confirmed') and new.source <> 'walk_in' then
    perform app.queue_customer_message('ORDER_CONFIRMED', new.customer_id,
      jsonb_build_object('order_no', new.order_no, 'delivery_date', to_char(new.requested_date, 'DD Mon YYYY'),
                         'total', to_char(new.total, 'FM999,999,990.00')),
      'order', new.id, 'order-confirmed:' || new.id);
  end if;
  return new;
end $$;
create trigger orders_customer_message after insert or update of status on public.orders
  for each row execute function app.order_message_trigger();

create or replace function app.delivery_message_trigger()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status in ('delivered','partially_delivered') and old.status = 'pending' then
    perform app.queue_customer_message('DELIVERED', new.customer_id,
      jsonb_build_object('delivery_no', new.delivery_no,
                         'invoice_total', to_char(coalesce((new.summary ->> 'total')::numeric, 0), 'FM999,999,990.00'),
                         'paid', to_char(coalesce((new.summary ->> 'paid')::numeric, 0), 'FM999,999,990.00'),
                         'balance', to_char(app.customer_outstanding(new.customer_id), 'FM999,999,990.00')),
      'delivery', new.id, 'delivered:' || new.id);
  elsif new.status = 'failed' and old.status = 'pending' then
    perform app.queue_customer_message('DELIVERY_MISSED', new.customer_id,
      jsonb_build_object('delivery_no', new.delivery_no, 'reason', coalesce(new.failure_reason, '')),
      'delivery', new.id, 'delivery-failed:' || new.id);
  end if;
  return new;
end $$;
create trigger deliveries_customer_message after update of status on public.deliveries
  for each row execute function app.delivery_message_trigger();

create or replace function app.payment_message_trigger()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- payments taken at a delivery are already in the "delivered" message
  if new.status = 'received' and coalesce(new.direction, 'in') = 'in' and new.delivery_id is null then
    perform app.queue_customer_message('PAYMENT_RECEIVED', new.customer_id,
      jsonb_build_object('payment_no', new.payment_no, 'amount', to_char(new.amount, 'FM999,999,990.00'),
                         'balance', to_char(app.customer_outstanding(new.customer_id), 'FM999,999,990.00')),
      'payment', new.id, 'payment:' || new.id);
  end if;
  return new;
end $$;
create trigger payments_customer_message after insert on public.payments
  for each row execute function app.payment_message_trigger();

-- ---------------------------------------------------------------------
-- Staff RPCs: my notifications
-- ---------------------------------------------------------------------
create or replace function public.my_notifications(p_limit integer default 30)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'unread', (select count(*) from public.notifications where user_id = app.current_user_id() and read_at is null),
    'items', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
        select id, type_code, title, body, href, severity, created_at, read_at
          from public.notifications where user_id = app.current_user_id()
         order by created_at desc limit least(greatest(coalesce(p_limit, 30), 1), 200)) x), '[]'))
$$;

create or replace function public.mark_notifications_read(p_ids uuid[] default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if app.current_user_id() is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  update public.notifications set read_at = now()
   where user_id = app.current_user_id() and read_at is null and (p_ids is null or id = any(p_ids));
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Settings RPCs for notification types and templates
-- ---------------------------------------------------------------------
create or replace function public.save_notification_type(p_code text, p jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_permission('settings.manage');
  if app.jtext(p, 'permission') is not null and not exists (select 1 from public.permissions where code = app.jtext(p, 'permission')) then
    raise exception 'Unknown permission' using errcode = '22023';
  end if;
  perform app.set_context('Notification settings changed', null, null);
  update public.notification_types set
    permission = coalesce(app.jtext(p, 'permission'), permission),
    in_app = coalesce(app.jbool(p, 'in_app', null), in_app),
    email = coalesce(app.jbool(p, 'email', null), email),
    is_active = coalesce(app.jbool(p, 'is_active', null), is_active)
   where code = p_code;
  if not found then raise exception 'Notification type not found' using errcode = 'P0002'; end if;
end $$;

create or replace function public.save_message_template(p_code text, p jsonb, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare t public.message_templates;
begin
  perform app.require_permission('settings.manage');
  select * into t from public.message_templates where code = p_code for update;
  if not found then raise exception 'Template not found' using errcode = 'P0002'; end if;
  if coalesce(app.jtext(p, 'channel'), t.channel) not in ('sms','whatsapp','email') then raise exception 'Choose SMS, WhatsApp or email' using errcode = '22023'; end if;
  if nullif(trim(coalesce(app.jtext(p, 'body'), t.body)), '') is null then raise exception 'The message cannot be empty' using errcode = '22023'; end if;
  if coalesce(app.jtext(p, 'channel'), t.channel) = 'sms' and length(coalesce(app.jtext(p, 'body'), t.body)) > 480 then
    raise exception 'Keep SMS messages under 480 characters (3 SMS)' using errcode = '22023';
  end if;
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Message template changed'), null, null);
  update public.message_templates set
    channel = coalesce(app.jtext(p, 'channel'), channel),
    subject = coalesce(app.jtext(p, 'subject'), subject),
    body = coalesce(app.jtext(p, 'body'), body),
    whatsapp_template = case when p ? 'whatsapp_template' then nullif(trim(app.jtext(p, 'whatsapp_template')), '') else whatsapp_template end,
    is_active = coalesce(app.jbool(p, 'is_active', null), is_active)
   where code = p_code;
end $$;

-- Queue a one-off message to a customer (e.g. a manual payment reminder).
create or replace function public.send_customer_message(p_customer uuid, p_template text, p_vars jsonb default '{}')
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  if not (app.has_permission('customers.manage') or app.has_permission('payments.manage') or app.has_permission('complaints.manage')) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  v := app.queue_customer_message(p_template, p_customer, p_vars, 'manual', null, null);
  if v is null then
    raise exception 'Not queued: messaging is switched off, the template is inactive, or the customer has opted out / has no number' using errcode = '22023';
  end if;
  return v;
end $$;

create or replace function public.retry_message(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_permission('settings.manage');
  update public.message_outbox set status = 'queued', next_attempt_at = now(), last_error = null
   where id = p_id and status in ('failed','cancelled');
  if not found then raise exception 'Only failed or cancelled messages can be sent again' using errcode = '22023'; end if;
end $$;

create or replace function public.cancel_message(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_permission('settings.manage');
  update public.message_outbox set status = 'cancelled' where id = p_id and status = 'queued';
  if not found then raise exception 'Only queued messages can be cancelled' using errcode = '22023'; end if;
end $$;

-- ---------------------------------------------------------------------
-- Sender API (called by the app server with the service key, or by a
-- signed-in administrator pressing "Send now")
-- ---------------------------------------------------------------------
create or replace function app.can_dispatch() returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(current_setting('request.jwt.claim.role', true), '') = 'service_role'
      or coalesce((nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'), '') = 'service_role'
      or session_user = 'service_role' or current_user = 'service_role'
      or app.has_permission('settings.manage')
$$;

-- Claim up to p_limit queued messages; they move to 'sending' so a parallel run cannot send them twice.
create or replace function public.claim_messages(p_limit integer default 20)
returns setof public.message_outbox language plpgsql security definer set search_path = '' as $$
begin
  if not app.can_dispatch() then raise exception 'Permission denied' using errcode = '42501'; end if;
  -- messages stuck in 'sending' for 15 minutes (a crashed run) go back to the queue
  update public.message_outbox set status = 'queued' where status = 'sending' and next_attempt_at < now() - interval '15 minutes';
  update public.notification_scan_state set last_dispatch_at = now() where id = 1;
  return query
  update public.message_outbox m set status = 'sending', attempts = m.attempts + 1, next_attempt_at = now()
   where m.id in (select id from public.message_outbox
                   where status = 'queued' and next_attempt_at <= now()
                   order by created_at limit least(greatest(coalesce(p_limit, 20), 1), 100)
                   for update skip locked)
  returning m.*;
end $$;

create or replace function public.report_message_result(p_id uuid, p_ok boolean, p_provider text, p_ref text, p_error text)
returns void language plpgsql security definer set search_path = '' as $$
declare m public.message_outbox;
begin
  if not app.can_dispatch() then raise exception 'Permission denied' using errcode = '42501'; end if;
  select * into m from public.message_outbox where id = p_id for update;
  if not found then return; end if;
  if p_ok then
    update public.message_outbox set status = 'sent', sent_at = now(), provider = p_provider, provider_ref = p_ref, last_error = null where id = p_id;
  elsif m.attempts >= 3 or p_error ilike 'not configured%' then
    update public.message_outbox set status = 'failed', provider = p_provider, last_error = left(p_error, 500) where id = p_id;
  else
    update public.message_outbox set status = 'queued', provider = p_provider, last_error = left(p_error, 500),
           next_attempt_at = now() + (m.attempts * interval '10 minutes') where id = p_id;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.notification_types       enable row level security;
alter table public.notifications            enable row level security;
alter table public.message_templates        enable row level security;
alter table public.message_outbox           enable row level security;
alter table public.notification_scan_state  enable row level security;

create policy notification_types_read on public.notification_types for select to authenticated using (true);
create policy notifications_own on public.notifications for select to authenticated using (user_id = app.current_user_id());
create policy message_templates_read on public.message_templates for select to authenticated
  using (app.has_permission('settings.manage') or app.has_permission('customers.manage') or app.has_permission('payments.manage'));
create policy message_outbox_read on public.message_outbox for select to authenticated
  using (app.has_permission('settings.manage')
         or (customer_id is not null and (app.has_permission('customers.view') or app.has_permission('payments.view'))));
create policy notification_scan_state_read on public.notification_scan_state for select to authenticated using (true);

-- >>> 20261007000036_approvals.sql
-- =====================================================================
-- OLA Water ERP — Phase 3A
-- 0036: configurable approval rules, approval requests with levels,
--       and the actions that now go to an approver instead of being
--       refused: large stock adjustments, discounts above the limit,
--       credit limit / payment term changes, price changes, bottle
--       write-offs.
--
-- How it works
--   * A guarded action calls app.require_approval(kind). If the user may
--     not do it alone, it fails with SQLSTATE OL001 (hint = kind).
--   * The app then calls submit_approval(kind, function, arguments): the
--     action is test-run (and rolled back) to prove it is valid and that
--     approval is really what is missing, then stored as a request.
--   * Approvers decide from the inbox. On the last approval level the
--     stored action is carried out for the requester, with the approval
--     recorded in the audit trail.
-- =====================================================================

create table public.approval_rules (
  kind                 text primary key check (kind ~ '^[a-z][a-z0-9_]{2,40}$'),
  name                 text not null,
  description          text,
  approver_permission  text not null references public.permissions(code),
  levels               integer not null default 1 check (levels between 1 and 3),
  threshold_setting    text references public.setting_definitions(key),
  functions            text[] not null default '{}',     -- database functions an approved request may carry out
  is_active            boolean not null default true,
  sort_order           integer not null default 0,
  updated_at           timestamptz not null default now()
);
create trigger approval_rules_touch before update on public.approval_rules for each row execute function app.touch_updated_at();
create trigger approval_rules_audit after insert or update on public.approval_rules for each row execute function app.audit_row('approvals');

create table public.approval_requests (
  id               uuid primary key default gen_random_uuid(),
  request_no       text not null unique,
  kind             text not null references public.approval_rules(kind),
  title            text not null,
  details          text,
  amount           numeric(16,2),
  fn               text not null,
  args             jsonb not null,
  reason           text,
  entity_type      text,
  entity_id        uuid,
  href             text,
  levels_required  integer not null check (levels_required between 1 and 3),
  levels_done      integer not null default 0,
  status           text not null default 'pending' check (status in ('pending','executing','approved','rejected','cancelled')),
  requested_by     uuid not null references public.profiles(id),
  requested_at     timestamptz not null default now(),
  decided_by       uuid references public.profiles(id),
  decided_at       timestamptz,
  decision_note    text,
  result           text,
  updated_at       timestamptz not null default now()
);
create index approval_requests_pending_idx on public.approval_requests (kind) where status = 'pending';
create index approval_requests_entity_idx on public.approval_requests (entity_type, entity_id);
create trigger approval_requests_touch before update on public.approval_requests for each row execute function app.touch_updated_at();
create trigger approval_requests_audit after insert or update on public.approval_requests for each row execute function app.audit_row('approvals');

create table public.approval_steps (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid not null references public.approval_requests(id),
  level        integer not null,
  approver_id  uuid not null references public.profiles(id),
  decision     text not null check (decision in ('approve','reject')),
  note         text,
  created_at   timestamptz not null default now(),
  unique (request_id, approver_id)
);
create trigger approval_steps_append_only before update or delete on public.approval_steps for each row execute function app.forbid_change();
create trigger approval_steps_audit after insert on public.approval_steps for each row execute function app.audit_row('approvals');

-- ---------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------
-- True only while an approved request of this kind is being carried out.
create or replace function app.approval_granted(p_kind text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.approval_requests
                  where id = nullif(current_setting('app.approval_request', true), '')::uuid
                    and status = 'executing' and kind = p_kind)
$$;

-- Does the current user need an approver for this kind of action?
create or replace function app.approval_needed(p_kind text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare r public.approval_rules;
begin
  if app.approval_granted(p_kind) then return false; end if;
  select * into r from public.approval_rules where kind = p_kind;
  if not found or not r.is_active then return false; end if;
  return not (r.levels = 1 and app.has_permission(r.approver_permission));
end $$;

create or replace function app.require_approval(p_kind text, p_message text default null)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if app.approval_needed(p_kind) then
    raise exception '%', coalesce(p_message, (select name from public.approval_rules where kind = p_kind) || ' needs approval')
      using errcode = 'OL001', hint = p_kind;
  end if;
end $$;

-- Call public.<fn>(...) with named arguments taken from a jsonb object; returns the result as text.
create or replace function app.call_rpc(p_fn text, p_args jsonb)
returns text language plpgsql security definer set search_path = '' as $$
declare v_oid oid; v_list text; v_res text;
begin
  select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = p_fn;
  if v_oid is null then raise exception 'Unknown action %', p_fn using errcode = '22023'; end if;
  select string_agg(format('%I => %s', a.name,
           case when a.type = 'jsonb'::regtype then format('(%L::jsonb -> %L)', p_args::text, a.name)
                else format('(%L::jsonb ->> %L)::%s', p_args::text, a.name, format_type(a.type, null)) end), ', ' order by a.ord)
    into v_list
    from pg_proc p
    cross join lateral unnest(p.proargnames, p.proargtypes::oid[]) with ordinality as a(name, type, ord)
   where p.oid = v_oid and p_args ? a.name;
  execute format('select (public.%I(%s))::text', p_fn, coalesce(v_list, '')) into v_res;
  return v_res;
end $$;

-- What the approver sees: title, details, amount and a link, built from the stored action.
create or replace function app.approval_describe(p_kind text, p_fn text, p_args jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := '{}'; pr public.products; l public.locations; c public.customers; have numeric; pl public.price_lists;
        e public.operation_exceptions; x jsonb; v_lines text[] := '{}'; v_old numeric; v_amt numeric := 0; v_gross numeric;
        v_pl uuid;
begin
  if p_kind = 'stock_adjustment' then
    select * into pr from public.products where id = app.juuid(p_args, 'p_product');
    select * into l from public.locations where id = app.juuid(p_args, 'p_location');
    select coalesce(sum(qty), 0) into have from public.inventory_balances
     where location_id = l.id and product_id = pr.id and stock_status = 'available';
    v := jsonb_build_object('title', 'Stock count — ' || pr.name || ' at ' || l.name,
      'details', format('Counted %s, system has %s (difference %s). Reason: %s', app.jnum(p_args, 'p_counted'),
                        have, app.jnum(p_args, 'p_counted') - have, app.jtext(p_args, 'p_reason')),
      'amount', round(abs(app.jnum(p_args, 'p_counted') - have) * coalesce(pr.cost_price, 0), 2),
      'entity_type', 'product', 'entity_id', pr.id, 'href', '/inventory');
  elsif p_kind = 'order_discount' then
    select * into c from public.customers where id = app.juuid(p_args -> 'p', 'customer_id');
    for x in select * from jsonb_array_elements(coalesce(p_args -> 'p' -> 'items', '[]')) loop
      continue when coalesce(app.jnum(x, 'discount'), 0) <= 0;
      select * into pr from public.products where id = app.juuid(x, 'product_id');
      v_gross := app.jnum(x, 'qty') * app.unit_price(pr.id, c.price_list_id, app.today());
      v_amt := v_amt + app.jnum(x, 'discount');
      v_lines := v_lines || format('%s × %s: discount Rs. %s (%s%%)', app.jnum(x, 'qty'), pr.name, app.jnum(x, 'discount'),
                                   case when v_gross > 0 then round(app.jnum(x, 'discount') / v_gross * 100, 1) end);
    end loop;
    v := jsonb_build_object('title', 'Order discount — ' || c.name, 'details', array_to_string(v_lines, '; '),
      'amount', v_amt, 'entity_type', 'customer', 'entity_id', c.id, 'href', '/customers/' || c.id);
  elsif p_kind = 'credit_change' then
    select * into c from public.customers where id = app.juuid(p_args, 'p_customer');
    v := jsonb_build_object('title', 'Credit terms — ' || c.name,
      'details', format('Credit limit Rs. %s → Rs. %s; payment terms %s → %s days', to_char(c.credit_limit, 'FM999,999,990.00'),
                        to_char(app.jnum(p_args, 'p_credit_limit'), 'FM999,999,990.00'), c.payment_terms_days, app.jint(p_args, 'p_payment_terms_days'))
                 || coalesce('. Outstanding now Rs. ' || to_char(app.customer_outstanding(c.id), 'FM999,999,990.00'), ''),
      'amount', app.jnum(p_args, 'p_credit_limit'), 'entity_type', 'customer', 'entity_id', c.id, 'href', '/customers/' || c.id);
  elsif p_kind = 'price_change' then
    v_pl := app.juuid(p_args, 'p_price_list');
    select * into pl from public.price_lists where id = v_pl;
    for x in select * from jsonb_array_elements(coalesce(p_args -> 'p_prices', '[]')) loop
      continue when app.jnum(x, 'unit_price') is null;
      select * into pr from public.products where id = app.juuid(x, 'product_id');
      v_old := app.unit_price(pr.id, v_pl, app.today());
      continue when v_old = app.jnum(x, 'unit_price');
      v_lines := v_lines || format('%s: Rs. %s → Rs. %s', pr.name, coalesce(to_char(v_old, 'FM999,990.00'), '—'), to_char(app.jnum(x, 'unit_price'), 'FM999,990.00'));
    end loop;
    v := jsonb_build_object('title', 'Price change — ' || pl.name || ' from ' || to_char(app.jtext(p_args, 'p_effective_from')::date, 'DD Mon YYYY'),
      'details', array_to_string(v_lines, '; ') || coalesce('. Reason: ' || app.jtext(p_args, 'p_reason'), ''),
      'entity_type', 'price_list', 'entity_id', pl.id, 'href', '/products');
  elsif p_kind = 'bottle_write_off' and p_fn = 'resolve_exception' then
    select * into e from public.operation_exceptions where id = app.juuid(p_args, 'p_id');
    v := jsonb_build_object('title', 'Write off — ' || replace(e.exception_type, '_', ' '),
      'details', e.description || coalesce('. Note: ' || app.jtext(p_args, 'p_note'), ''),
      'amount', case when e.bottle_type_id is not null
                     then (e.expected - e.actual) * coalesce((app.bottle_value(e.bottle_type_id, e.company_id)).replacement_value, 0) end,
      'entity_type', 'exception', 'entity_id', e.id, 'href', '/exceptions');
  elsif p_kind = 'bottle_write_off' then
    v := jsonb_build_object('title', 'Write off bottle ' || app.jtext(p_args, 'p_code'),
      'details', app.jtext(p_args, 'p_reason'), 'href', '/bottles');
  else
    v := jsonb_build_object('title', (select name from public.approval_rules where kind = p_kind), 'details', null);
  end if;
  return v;
end $$;

-- Store a request (no test-run) and tell the approvers.
create or replace function app.create_approval(p_kind text, p_fn text, p_args jsonb, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.approval_rules; d jsonb; v uuid; v_no text;
begin
  select * into r from public.approval_rules where kind = p_kind;
  if not found then raise exception 'Unknown approval type' using errcode = '22023'; end if;
  if not (p_fn = any(r.functions)) then raise exception 'This action cannot be sent for approval' using errcode = '22023'; end if;
  d := app.approval_describe(p_kind, p_fn, p_args);
  v_no := app.next_document_number('APR');
  insert into public.approval_requests (request_no, kind, title, details, amount, fn, args, reason, entity_type, entity_id, href,
    levels_required, requested_by)
  values (v_no, p_kind, coalesce(d ->> 'title', r.name), d ->> 'details', (d ->> 'amount')::numeric, p_fn, p_args,
          nullif(trim(p_reason), ''), d ->> 'entity_type', (d ->> 'entity_id')::uuid, d ->> 'href', r.levels, app.current_user_id())
  returning id into v;
  perform app.notify('approval_request', 'Approval needed: ' || coalesce(d ->> 'title', r.name),
    (select full_name from public.profiles where id = app.current_user_id()) || ' asks: ' || coalesce(d ->> 'details', ''),
    '/approvals', 'approval:' || v, null, null, r.approver_permission);
  return jsonb_build_object('request_id', v, 'request_no', v_no, 'status', 'pending');
end $$;

-- Called by the app after an action failed with "needs approval".
create or replace function public.submit_approval(p_kind text, p_fn text, p_args jsonb, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.approval_rules; v_state text; v_hint text;
begin
  if app.current_user_id() is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  select * into r from public.approval_rules where kind = p_kind;
  if not found then raise exception 'Unknown approval type' using errcode = '22023'; end if;
  if not (p_fn = any(r.functions)) then raise exception 'This action cannot be sent for approval' using errcode = '22023'; end if;
  if exists (select 1 from public.approval_requests where status = 'pending' and fn = p_fn and args = p_args and requested_by = app.current_user_id()) then
    raise exception 'This request is already waiting for approval' using errcode = '22023';
  end if;
  -- test-run the action: it must fail only because approval is missing
  begin
    perform app.call_rpc(p_fn, p_args);
    raise exception 'test-run' using errcode = 'OL999';
  exception
    when sqlstate 'OL001' then
      get stacked diagnostics v_hint = pg_exception_hint;
      v_state := 'needs';
    when sqlstate 'OL999' then
      v_state := 'free';
  end;
  if v_state = 'free' then raise exception 'This no longer needs approval — save it again' using errcode = '22023'; end if;
  if v_hint is distinct from p_kind then raise exception 'This action needs a different approval (%)', v_hint using errcode = '22023'; end if;
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Sent for approval'), null, 'request_approval');
  return app.create_approval(p_kind, p_fn, p_args, p_reason);
end $$;

create or replace function public.decide_approval(p_id uuid, p_approve boolean, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare q public.approval_requests; r public.approval_rules; v_me uuid := app.current_user_id(); v_level integer; v_res text;
        v_args jsonb; v_name text;
begin
  select * into q from public.approval_requests where id = p_id for update;
  if not found then raise exception 'Request not found' using errcode = 'P0002'; end if;
  if q.status <> 'pending' then raise exception 'This request is already %', q.status using errcode = '22023'; end if;
  select * into r from public.approval_rules where kind = q.kind;
  if q.requested_by = v_me then raise exception 'You cannot approve your own request' using errcode = '42501'; end if;
  if not app.has_permission(r.approver_permission) then
    raise exception 'Permission denied: % is required to decide this request', r.approver_permission using errcode = '42501';
  end if;
  if exists (select 1 from public.approval_steps where request_id = q.id and approver_id = v_me) then
    raise exception 'You have already approved this request — another approver is needed' using errcode = '42501';
  end if;
  if not p_approve and nullif(trim(p_note), '') is null then raise exception 'Give a reason for rejecting' using errcode = '22023'; end if;
  select full_name into v_name from public.profiles where id = v_me;
  v_level := q.levels_done + 1;
  perform app.set_context(coalesce(nullif(trim(p_note), ''), case when p_approve then 'Approved' else 'Rejected' end), null,
                          case when p_approve then 'approve' else 'reject' end);
  insert into public.approval_steps (request_id, level, approver_id, decision, note)
  values (q.id, v_level, v_me, case when p_approve then 'approve' else 'reject' end, nullif(trim(p_note), ''));

  if not p_approve then
    update public.approval_requests set status = 'rejected', decided_by = v_me, decided_at = now(), decision_note = trim(p_note) where id = q.id;
    perform app.notify('approval_decision', 'Rejected: ' || q.title, v_name || ': ' || trim(p_note), coalesce(q.href, '/approvals'),
      'approval-done:' || q.id, q.requested_by, 'warning');
    return jsonb_build_object('status', 'rejected', 'request_no', q.request_no);
  end if;

  if v_level < q.levels_required then
    update public.approval_requests set levels_done = v_level where id = q.id;
    perform app.notify('approval_request', 'Second approval needed: ' || q.title, 'Approved by ' || v_name || ' (level ' || v_level || ' of ' || q.levels_required || ')',
      '/approvals', 'approval:' || q.id || ':' || (v_level + 1), null, null, r.approver_permission);
    return jsonb_build_object('status', 'pending', 'request_no', q.request_no, 'levels_done', v_level);
  end if;

  -- last level: carry out the action for the requester
  v_args := q.args;
  if v_args ? 'p_effective_from' and (v_args ->> 'p_effective_from')::date < app.today() then
    v_args := jsonb_set(v_args, '{p_effective_from}', to_jsonb(app.today()::text));
  end if;
  update public.approval_requests set status = 'executing', levels_done = v_level where id = q.id;
  perform set_config('app.approval_request', q.id::text, true);
  perform set_config('request.jwt.claim.sub', q.requested_by::text, true);
  begin
    perform app.set_context(format('%s — approved by %s (%s)%s', coalesce(q.reason, q.title), v_name, q.request_no,
                                   coalesce(': ' || nullif(trim(p_note), ''), '')), null, null);
    v_res := app.call_rpc(q.fn, v_args);
  exception when others then
    perform set_config('request.jwt.claim.sub', v_me::text, true);
    perform set_config('app.approval_request', '', true);
    raise exception 'Approved, but the action could not be carried out: %', sqlerrm using errcode = '22023';
  end;
  perform set_config('request.jwt.claim.sub', v_me::text, true);
  perform set_config('app.approval_request', '', true);
  update public.approval_requests set status = 'approved', decided_by = v_me, decided_at = now(),
         decision_note = nullif(trim(p_note), ''), result = left(v_res, 2000) where id = q.id;
  perform app.notify('approval_decision', 'Approved: ' || q.title, 'Approved by ' || v_name || ' and carried out.',
    coalesce(q.href, '/approvals'), 'approval-done:' || q.id, q.requested_by);
  return jsonb_build_object('status', 'approved', 'request_no', q.request_no, 'result', v_res);
end $$;

create or replace function public.cancel_approval(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare q public.approval_requests;
begin
  select * into q from public.approval_requests where id = p_id for update;
  if not found then raise exception 'Request not found' using errcode = 'P0002'; end if;
  if q.requested_by <> app.current_user_id() and not app.is_super_admin() then
    raise exception 'Only the person who asked can withdraw the request' using errcode = '42501';
  end if;
  if q.status <> 'pending' then raise exception 'This request is already %', q.status using errcode = '22023'; end if;
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Withdrawn'), null, 'cancel');
  update public.approval_requests set status = 'cancelled', decided_by = app.current_user_id(), decided_at = now(),
         decision_note = nullif(trim(p_reason), '') where id = p_id;
end $$;

create or replace function public.save_approval_rule(p_kind text, p jsonb, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_permission('settings.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required to change an approval rule' using errcode = '22023'; end if;
  if app.jtext(p, 'approver_permission') is not null
     and not exists (select 1 from public.permissions where code = app.jtext(p, 'approver_permission')) then
    raise exception 'Unknown permission' using errcode = '22023';
  end if;
  if coalesce(app.jint(p, 'levels'), 1) not between 1 and 3 then raise exception 'Choose 1, 2 or 3 approval levels' using errcode = '22023'; end if;
  perform app.set_context(trim(p_reason), null, null);
  update public.approval_rules set
    approver_permission = coalesce(app.jtext(p, 'approver_permission'), approver_permission),
    levels = coalesce(app.jint(p, 'levels'), levels),
    is_active = coalesce(app.jbool(p, 'is_active', null), is_active)
   where kind = p_kind;
  if not found then raise exception 'Rule not found' using errcode = 'P0002'; end if;
end $$;

-- ---------------------------------------------------------------------
-- Customer credit terms: their own action so an approval changes only
-- these two fields (never other details edited since).
-- ---------------------------------------------------------------------
create or replace function public.set_customer_credit(p_customer uuid, p_credit_limit numeric, p_payment_terms_days integer, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.customers;
begin
  perform app.require_permission('customers.manage');
  if p_credit_limit is null or p_credit_limit < 0 then raise exception 'Enter a credit limit (0 for cash only)' using errcode = '22023'; end if;
  if p_payment_terms_days is null or p_payment_terms_days < 0 then raise exception 'Enter the payment terms in days' using errcode = '22023'; end if;
  select * into c from public.customers where id = p_customer for update;
  if not found then raise exception 'Customer not found' using errcode = 'P0002'; end if;
  if c.credit_limit = p_credit_limit and c.payment_terms_days = p_payment_terms_days then return; end if;
  perform app.require_approval('credit_change', 'Changing a credit limit or payment terms needs approval');
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Credit terms changed'), null, null);
  update public.customers set credit_limit = p_credit_limit, payment_terms_days = p_payment_terms_days where id = p_customer;
end $$;

-- =====================================================================
-- Guarded actions (replacements of earlier functions; only the
-- permission check changed — see the marked lines)
-- =====================================================================
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
  if abs(v_diff) > v_limit then  -- [3A] was: refused without inventory.adjust
    perform app.require_approval('stock_adjustment', format('Adjustments over %s units need approval', v_limit));
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

create or replace function public.save_order(p_id uuid, p jsonb, p_confirm boolean, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; v uuid; c public.customers; o public.orders; it jsonb; n integer := 0; v_price numeric;
  v_disc_limit numeric; v_line_gross numeric; v_res jsonb; v_addr uuid; v_include boolean;
begin
  perform app.require_permission('orders.manage');
  if p_id is null then
    v_done := app.idempotency_begin(p_client_txn_id, 'save_order');
    if v_done is not null then return v_done; end if;
  end if;
  perform app.set_context(null, p_client_txn_id, null);

  select * into c from public.customers where id = app.juuid(p, 'customer_id');
  if not found then raise exception 'Choose a customer' using errcode = '22023'; end if;
  if c.status = 'inactive' then raise exception 'Customer % is inactive', c.name using errcode = '22023'; end if;
  if jsonb_array_length(coalesce(p -> 'items', '[]')) = 0 then raise exception 'Add at least one product' using errcode = '22023'; end if;

  v_addr := coalesce(app.juuid(p, 'address_id'),
                     (select id from public.customer_addresses where customer_id = c.id and is_default and is_active));
  select prices_include_tax into v_include from public.price_lists where id = c.price_list_id;

  if p_id is null then
    insert into public.orders (order_no, customer_id, address_id, source, requested_date, time_window, route_id, price_list_id,
      prices_include_tax, delivery_charge, expected_ola_returns, notes, created_by, client_txn_id)
    values (app.next_document_number('ORD'), c.id, v_addr, coalesce(app.jtext(p, 'source'), 'phone'),
      coalesce((app.jtext(p, 'requested_date'))::date, app.today()), app.jtext(p, 'time_window'), c.route_id, c.price_list_id,
      v_include, coalesce(app.jnum(p, 'delivery_charge'), 0), coalesce(app.jint(p, 'expected_ola_returns'), 0),
      app.jtext(p, 'notes'), app.current_user_id(), p_client_txn_id)
    returning id into v;
  else
    select * into o from public.orders where id = p_id for update;
    if not found then raise exception 'Order not found' using errcode = 'P0002'; end if;
    if o.status not in ('draft','on_hold','confirmed') then
      raise exception 'Order % is already % and cannot be edited', o.order_no, replace(o.status, '_', ' ') using errcode = '22023';
    end if;
    update public.orders set address_id = v_addr, requested_date = coalesce((app.jtext(p, 'requested_date'))::date, requested_date),
           time_window = app.jtext(p, 'time_window'), delivery_charge = coalesce(app.jnum(p, 'delivery_charge'), 0),
           expected_ola_returns = coalesce(app.jint(p, 'expected_ola_returns'), 0), notes = app.jtext(p, 'notes'),
           status = 'draft', hold_reason = null
     where id = p_id;
    perform set_config('app.audit_action', 'remove_line', true);
    delete from public.order_items where order_id = p_id;
    perform set_config('app.audit_action', '', true);
    v := p_id;
  end if;

  v_disc_limit := coalesce((app.get_setting('approvals.discount_percent') #>> '{}')::numeric, 0);
  for it in select * from jsonb_array_elements(p -> 'items') loop
    continue when coalesce(app.jnum(it, 'qty'), 0) <= 0;
    n := n + 1;
    v_price := app.unit_price(app.juuid(it, 'product_id'), c.price_list_id, coalesce((app.jtext(p, 'requested_date'))::date, app.today()));
    v_line_gross := app.jnum(it, 'qty') * v_price;
    if coalesce(app.jnum(it, 'discount'), 0) > 0 and v_line_gross > 0
       and app.jnum(it, 'discount') / v_line_gross * 100 > v_disc_limit then  -- [3A] was: refused without pos.discount
      perform app.require_approval('order_discount', format('Discounts above %s%% need approval', v_disc_limit));
    end if;
    insert into public.order_items (order_id, line_no, product_id, qty, unit_price, discount, line_net, line_tax, line_total)
    values (v, n, app.juuid(it, 'product_id'), app.jnum(it, 'qty'), v_price, coalesce(app.jnum(it, 'discount'), 0), 0, 0, 0);
  end loop;
  if n = 0 then raise exception 'Add at least one product with a quantity' using errcode = '22023'; end if;
  perform app.recalc_order(v);

  if coalesce(p_confirm, false) then
    perform public.confirm_order(v);
  end if;

  select jsonb_build_object('order_id', id, 'order_no', order_no, 'status', status, 'hold_reason', hold_reason, 'total', total)
    into v_res from public.orders where id = v;
  if p_id is null then perform app.idempotency_finish(p_client_txn_id, v_res); end if;
  return v_res;
end $$;

create or replace function public.save_customer(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v uuid;
  d public.customer_type_defaults;
  v_old public.customers;
  v_phone text := app.normalize_phone(app.jtext(p, 'phone'));
  v_credit numeric := coalesce(app.jnum(p, 'credit_limit'), 0);
  v_addr jsonb := p -> 'address';
  v_credit_req jsonb;
begin
  perform app.require_permission('customers.manage');
  if app.jtext(p, 'name') is null then raise exception 'Customer name is required' using errcode = '22023'; end if;
  if v_phone is null then raise exception 'A phone number is required' using errcode = '22023'; end if;

  select * into d from public.customer_type_defaults where customer_type = coalesce(app.jtext(p, 'customer_type'), '');
  if not found then raise exception 'Choose a customer type' using errcode = '22023'; end if;

  if p_id is not null then
    select * into v_old from public.customers where id = p_id for update;
    if not found then raise exception 'Customer not found' using errcode = 'P0002'; end if;
  end if;

  -- Credit limits and payment terms need finance permission to change
  if v_credit <> coalesce(v_old.credit_limit, 0)
     or coalesce(app.jint(p, 'payment_terms_days'), d.payment_terms_days) <> coalesce(v_old.payment_terms_days, d.payment_terms_days) then
    -- [3A] was: refused without customers.credit. Now the customer is saved with the old (or cash)
    -- terms and the new terms go to an approver.
    if app.approval_needed('credit_change') then
      v_credit_req := jsonb_build_object('p_credit_limit', v_credit,
                        'p_payment_terms_days', coalesce(app.jint(p, 'payment_terms_days'), d.payment_terms_days),
                        'p_reason', coalesce(nullif(trim(p_reason), ''), case when p_id is null then 'New credit customer' else 'Credit terms change' end));
      v_credit := coalesce(v_old.credit_limit, 0);
      p := (p - 'payment_terms_days') || case when v_old.id is not null then jsonb_build_object('payment_terms_days', v_old.payment_terms_days)
                                              else jsonb_build_object('payment_terms_days', 0) end;
    end if;
  end if;

  perform app.set_context(nullif(trim(p_reason), ''), null, null);

  if p_id is null then
    if exists (select 1 from public.customers where phone = v_phone and status <> 'inactive') then
      raise exception 'A customer with phone % already exists', v_phone using errcode = '23505';
    end if;
    insert into public.customers (
      name, company_name, customer_type, contact_person, phone, phone2, email, vat_no, route_id, route_sequence,
      sales_rep_id, price_list_id, credit_limit, payment_terms_days, bottle_model, allowed_bottles, external_policy,
      notes, created_by)
    values (
      app.jtext(p, 'name'), app.jtext(p, 'company_name'), d.customer_type, app.jtext(p, 'contact_person'), v_phone,
      app.normalize_phone(app.jtext(p, 'phone2')), lower(app.jtext(p, 'email')), app.jtext(p, 'vat_no'),
      app.juuid(p, 'route_id'), app.jint(p, 'route_sequence'), app.juuid(p, 'sales_rep_id'),
      coalesce(app.juuid(p, 'price_list_id'), d.price_list_id,
               (select id from public.price_lists where code = 'RETAIL')),
      v_credit, coalesce(app.jint(p, 'payment_terms_days'), d.payment_terms_days),
      coalesce(app.jtext(p, 'bottle_model'), d.bottle_model), coalesce(app.jint(p, 'allowed_bottles'), d.allowed_bottles),
      app.jtext(p, 'external_policy'), app.jtext(p, 'notes'), app.current_user_id())
    returning id into v;

    if v_addr is not null and app.jtext(v_addr, 'address_line') is not null then
      insert into public.customer_addresses (customer_id, label, address_line, city, district, gps_lat, gps_lng,
                                             delivery_instructions, is_default)
      values (v, coalesce(app.jtext(v_addr, 'label'), 'Main'), app.jtext(v_addr, 'address_line'), app.jtext(v_addr, 'city'),
              app.jtext(v_addr, 'district'), app.jnum(v_addr, 'gps_lat'), app.jnum(v_addr, 'gps_lng'),
              app.jtext(v_addr, 'delivery_instructions'), true);
    end if;
  else
    update public.customers set
      name = app.jtext(p, 'name'), company_name = app.jtext(p, 'company_name'), customer_type = d.customer_type,
      contact_person = app.jtext(p, 'contact_person'), phone = v_phone, phone2 = app.normalize_phone(app.jtext(p, 'phone2')),
      email = lower(app.jtext(p, 'email')), vat_no = app.jtext(p, 'vat_no'), route_id = app.juuid(p, 'route_id'),
      route_sequence = app.jint(p, 'route_sequence'), sales_rep_id = app.juuid(p, 'sales_rep_id'),
      price_list_id = coalesce(app.juuid(p, 'price_list_id'), v_old.price_list_id),
      credit_limit = v_credit, payment_terms_days = coalesce(app.jint(p, 'payment_terms_days'), v_old.payment_terms_days),
      bottle_model = coalesce(app.jtext(p, 'bottle_model'), v_old.bottle_model),
      allowed_bottles = coalesce(app.jint(p, 'allowed_bottles'), v_old.allowed_bottles),
      external_policy = app.jtext(p, 'external_policy'),
      status = coalesce(app.jtext(p, 'status'), v_old.status), notes = app.jtext(p, 'notes')
    where id = p_id;
    v := p_id;
  end if;
  if v_credit_req is not null then
    perform app.create_approval('credit_change', 'set_customer_credit', v_credit_req || jsonb_build_object('p_customer', v), v_credit_req ->> 'p_reason');
  end if;
  return v;
end $$;

create or replace function public.set_prices(p_price_list uuid, p_prices jsonb, p_effective_from date, p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_row jsonb; n integer := 0; v_current numeric;
begin
  perform app.require_permission('prices.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required to change prices' using errcode = '22023'; end if;
  if p_effective_from < app.today() then raise exception 'Prices cannot be back-dated' using errcode = '22023'; end if;
  perform app.require_approval('price_change', 'Price changes need approval');  -- [3A]
  perform app.set_context(trim(p_reason), null, 'change_price');
  for v_row in select * from jsonb_array_elements(p_prices) loop
    continue when app.jnum(v_row, 'unit_price') is null;
    select unit_price into v_current from public.price_list_items
     where price_list_id = p_price_list and product_id = app.juuid(v_row, 'product_id') and effective_from <= p_effective_from
     order by effective_from desc limit 1;
    continue when v_current = app.jnum(v_row, 'unit_price');
    insert into public.price_list_items (price_list_id, product_id, unit_price, effective_from, created_by)
    values (p_price_list, app.juuid(v_row, 'product_id'), app.jnum(v_row, 'unit_price'), p_effective_from, app.current_user_id())
    on conflict (price_list_id, product_id, effective_from) do nothing;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.mark_bottle(p_code text, p_action text, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare b public.bottles;
begin
  perform app.require_permission('bottles.manage');
  if nullif(trim(p_reason), '') is null then raise exception 'A reason is required' using errcode = '22023'; end if;
  b := app.bottle_by_code(p_code);
  if b.id is null then raise exception 'Bottle not found' using errcode = 'P0002'; end if;
  perform app.set_context(trim(p_reason), null, p_action);
  if p_action = 'damaged' then
    update public.bottles set condition = 'damaged' where id = b.id;
  elsif p_action = 'repaired' then
    update public.bottles set condition = 'good' where id = b.id;
  elsif p_action = 'retire' then
    perform app.require_approval('bottle_write_off', 'Writing off a bottle needs approval');  -- [3A]
    perform app.bottle_move('retire', null, null, 1, b.holder_type, b.holder_id, b.fill_state, 'outside', app.outside_id(), 'empty',
      'bottle', b.id, b.id, trim(p_reason));
  else
    raise exception 'Unknown action' using errcode = '22023';
  end if;
end $$;

create or replace function public.resolve_exception(p_id uuid, p_resolution text, p_note text, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; e public.operation_exceptions; r public.route_runs; v_qty integer; v_amount numeric; v_own uuid := app.own_company_id();
  v_dest uuid; bv public.bottle_values; pr public.products; v_veh uuid; v_ola boolean; v_shop public.water_shops;
begin
  if nullif(trim(p_note), '') is null then raise exception 'Explain the resolution' using errcode = '22023'; end if;
  v_done := app.idempotency_begin(p_client_txn_id, 'resolve_exception');
  if v_done is not null then return v_done; end if;
  select * into e from public.operation_exceptions where id = p_id for update;
  if not found then raise exception 'Exception not found' using errcode = 'P0002'; end if;
  if e.status = 'resolved' then raise exception 'Already resolved' using errcode = '22023'; end if;
  if e.run_id is not null then
    perform app.require_permission('deliveries.reconcile');
  elsif not (app.has_permission('deliveries.reconcile') or app.has_permission('shops.settle') or app.has_permission('inventory.adjust')) then
    raise exception 'Permission denied: deliveries.reconcile, shops.settle or inventory.adjust is required' using errcode = '42501';
  end if;
  perform app.set_context(trim(p_note), p_client_txn_id, 'resolve');

  if e.run_id is not null then
    select * into r from public.route_runs where id = e.run_id; v_veh := app.vehicle_location(e.run_id);

    if e.exception_type = 'bottle_shortage' then
      v_qty := (e.expected - e.actual)::integer;
      v_dest := case when e.company_id = v_own then r.load_location_id
                     else (select id from public.locations where location_type = 'external_holding' order by created_at limit 1) end;
      bv := app.bottle_value(e.bottle_type_id, e.company_id);
      if p_resolution = 'found' then
        perform app.bottle_move(case when e.company_id = v_own then 'check_in' else 'to_external_holding' end, e.company_id, e.bottle_type_id,
          v_qty, 'location', v_veh, 'empty', 'location', v_dest, 'empty', 'exception', e.id);
      elsif p_resolution in ('write_off','charge_driver') then
        if p_resolution = 'write_off' then perform app.require_approval('bottle_write_off', 'Writing off bottles needs approval'); end if;  -- [3A]
        perform app.bottle_move('write_off', e.company_id, e.bottle_type_id, v_qty, 'location', v_veh, 'empty', 'outside', app.outside_id(), 'empty',
          'exception', e.id);
        v_amount := v_qty * coalesce(bv.replacement_value, 0);
        if p_resolution = 'write_off' and e.company_id = v_own and v_amount > 0 then
          perform app.post_event('bottle.writeoff', jsonb_build_object('value', v_amount), app.today(),
            'Bottles written off: ' || e.description, 'exception', e.id);
        elsif p_resolution = 'charge_driver' and v_amount > 0 then
          perform app.post_event('driver.bottle_charge', jsonb_build_object('amount', v_amount), app.today(),
            'Bottles charged to driver: ' || e.description, 'exception', e.id, null, 'driver', r.driver_id);
        end if;
      elsif p_resolution <> 'accepted' then
        raise exception 'Unsupported resolution' using errcode = '22023';
      end if;

    elsif e.exception_type = 'stock_shortage' then
      v_qty := (e.expected - e.actual)::integer;
      select * into pr from public.products where id = e.product_id;
      if p_resolution = 'found' then
        perform app.stock_move('check_in', pr.id, v_qty, v_veh, r.load_location_id, 'exception', e.id);
        if pr.is_returnable then
          perform app.bottle_move('check_in', v_own, pr.bottle_type_id, v_qty, 'location', v_veh, 'full', 'location', r.load_location_id, 'full',
            'exception', e.id);
        end if;
      elsif p_resolution in ('write_off','charge_driver') then
        perform app.require_permission('inventory.adjust');
        perform app.stock_move('adjust_loss', pr.id, v_qty, v_veh, null, 'exception', e.id);
        if pr.is_returnable then
          perform app.bottle_move('write_off', v_own, pr.bottle_type_id, v_qty, 'location', v_veh, 'full', 'outside', app.outside_id(), 'empty',
            'exception', e.id);
        end if;
        if pr.cost_price > 0 then
          perform app.post_event(case when p_resolution = 'write_off' then 'stock.adjust_loss' else 'driver.stock_charge' end,
            jsonb_build_object('value', v_qty * pr.cost_price, 'amount', v_qty * pr.cost_price), app.today(),
            'Stock shortage: ' || e.description, 'exception', e.id, null,
            case when p_resolution = 'charge_driver' then 'driver' end, case when p_resolution = 'charge_driver' then r.driver_id end);
        end if;
      elsif p_resolution <> 'accepted' then
        raise exception 'Unsupported resolution' using errcode = '22023';
      end if;

    elsif e.exception_type = 'cash_shortage' then
      v_amount := e.expected - e.actual;
      if p_resolution = 'found' then
        perform app.post_event('driver.cash_handover', jsonb_build_object('amount', v_amount), app.today(),
          'Shortage handed in: ' || r.run_no, 'exception', e.id, null, 'driver', r.driver_id);
      elsif p_resolution = 'write_off' then
        perform app.require_permission('accounting.manual_journal');
        perform app.post_event('driver.cash_shortage', jsonb_build_object('amount', v_amount), app.today(),
          'Cash shortage written off: ' || r.run_no, 'exception', e.id, null, 'driver', r.driver_id);
      elsif p_resolution not in ('charge_driver','accepted') then
        raise exception 'Unsupported resolution' using errcode = '22023';
      end if;

    elsif p_resolution <> 'accepted' then
      raise exception 'This exception can only be acknowledged' using errcode = '22023';
    end if;

  else
    -- shops, transfers in transit, tills and counters
    v_ola := app.location_is_ola(e.location_id);
    v_shop := app.shop_by_location(coalesce(e.target_location_id, e.location_id));

    if e.exception_type = 'stock_shortage' then
      v_qty := (e.expected - e.actual)::integer;
      select * into pr from public.products where id = e.product_id;
      if p_resolution = 'found' then
        if e.target_location_id is not null then
          -- goods turned up at the shop after all
          perform app.stock_move('transfer', pr.id, v_qty, e.location_id, e.target_location_id, 'exception', e.id);
          if pr.is_returnable then
            perform app.bottle_move('transfer', v_own, pr.bottle_type_id, v_qty, 'location', e.location_id, 'full',
              'location', e.target_location_id, 'full', 'exception', e.id);
          end if;
          if v_shop.operating_model = 'dealer' then
            perform app.invoice_dealer_transfer(v_shop.id, jsonb_build_array(jsonb_build_object('product_id', pr.id, 'qty', v_qty)), 'exception', e.id);
          end if;
        end if;  -- otherwise: recount found the stock, nothing moves
      elsif p_resolution = 'write_off' then
        perform app.require_permission('inventory.adjust');
        perform app.stock_move('adjust_loss', pr.id, v_qty, e.location_id, null, 'exception', e.id);
        if pr.is_returnable then
          perform app.bottle_move('write_off', v_own, pr.bottle_type_id, v_qty, 'location', e.location_id, 'full', 'outside', app.outside_id(), 'empty',
            'exception', e.id);
        end if;
        if v_ola and pr.cost_price > 0 then
          perform app.post_event('stock.adjust_loss', jsonb_build_object('value', v_qty * pr.cost_price), app.today(),
            'Stock shortage: ' || e.description, 'exception', e.id, e.location_id);
        end if;
      elsif p_resolution <> 'accepted' then
        raise exception 'Unsupported resolution' using errcode = '22023';
      end if;

    elsif e.exception_type in ('stock_surplus','negative_balance') then
      if p_resolution = 'found' and e.exception_type = 'stock_surplus' and e.target_location_id is null then
        v_qty := (e.actual - e.expected)::integer;
        select * into pr from public.products where id = e.product_id;
        perform app.require_permission('inventory.adjust');
        perform app.stock_move('adjust_gain', pr.id, v_qty, null, e.location_id, 'exception', e.id);
        if v_ola and pr.cost_price > 0 then
          perform app.post_event('stock.adjust_gain', jsonb_build_object('value', v_qty * pr.cost_price), app.today(),
            'Stock surplus: ' || e.description, 'exception', e.id, e.location_id);
        end if;
      elsif p_resolution <> 'accepted' then
        raise exception 'This difference can only be acknowledged or (for a counted surplus) brought into stock' using errcode = '22023';
      end if;

    elsif e.exception_type = 'bottle_shortage' then
      v_qty := (e.expected - e.actual)::integer;
      if p_resolution = 'write_off' then
        perform app.require_approval('bottle_write_off', 'Writing off bottles needs approval');  -- [3A]
        perform app.bottle_move('write_off', e.company_id, e.bottle_type_id, v_qty, 'location', e.location_id, coalesce(e.fill_state, 'empty'),
          'outside', app.outside_id(), 'empty', 'exception', e.id);
        bv := app.bottle_value(e.bottle_type_id, e.company_id);
        if e.company_id = v_own and coalesce(bv.replacement_value, 0) * v_qty > 0 then
          perform app.post_event('bottle.writeoff', jsonb_build_object('value', v_qty * bv.replacement_value), app.today(),
            'Bottles written off: ' || e.description, 'exception', e.id, e.location_id);
        end if;
      elsif p_resolution not in ('found','accepted') then
        raise exception 'Unsupported resolution' using errcode = '22023';
      end if;

    elsif e.exception_type = 'bottle_surplus' then
      if p_resolution = 'found' and e.source_type = 'pos_session' then
        perform app.bottle_move('found', e.company_id, e.bottle_type_id, (e.actual - e.expected)::integer, 'outside', app.outside_id(),
          coalesce(e.fill_state, 'empty'), 'location', e.location_id, coalesce(e.fill_state, 'empty'), 'exception', e.id);
      elsif p_resolution not in ('found','accepted') then
        raise exception 'Unsupported resolution' using errcode = '22023';
      end if;

    elsif e.exception_type = 'cash_shortage' then
      v_amount := e.expected - e.actual;
      if p_resolution = 'write_off' then
        perform app.require_permission('accounting.manual_journal');
        if v_ola and v_shop.id is not null then
          perform app.post_event('shop.cash_shortage', jsonb_build_object('amount', v_amount), app.today(),
            'Till shortage written off: ' || e.description, 'exception', e.id, e.location_id);
        elsif v_shop.id is null then
          perform app.post_event('counter.cash_shortage', jsonb_build_object('amount', v_amount), app.today(),
            'Counter shortage written off: ' || e.description, 'exception', e.id, e.location_id);
        end if;
      elsif p_resolution not in ('found','charge_driver','accepted') then
        raise exception 'Unsupported resolution' using errcode = '22023';
      end if;

    elsif p_resolution <> 'accepted' then
      raise exception 'This exception can only be acknowledged' using errcode = '22023';
    end if;
  end if;

  update public.operation_exceptions set status = 'resolved', resolution = p_resolution, resolution_note = trim(p_note),
         resolved_at = now(), resolved_by = app.current_user_id()
   where id = p_id;

  if e.run_id is not null and not exists (select 1 from public.operation_exceptions where run_id = e.run_id and status = 'open'
       and exception_type in ('bottle_shortage','bottle_surplus','stock_shortage','stock_surplus','cash_shortage','cash_surplus')) then
    update public.route_runs set status = 'closed', closed_at = now() where id = e.run_id and status = 'checked_in';
  end if;
  if e.source_type = 'stock_request' and not exists (select 1 from public.operation_exceptions where source_id = e.source_id and status = 'open') then
    update public.shop_stock_requests set status = 'received' where id = e.source_id and status = 'received_with_differences';
  end if;

  perform app.idempotency_finish(p_client_txn_id, jsonb_build_object('ok', true));
  return jsonb_build_object('ok', true);
end $$;

-- >>> 20261007000037_complaints.sql
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

-- >>> 20261007000038_documents.sql
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

-- >>> 20261007000039_phase3a_reference_data.sql
-- =====================================================================
-- OLA Water ERP — Phase 3A
-- 0039: numbering, permissions, approval rules, notification types,
--       message templates, complaint and document categories, settings
-- =====================================================================
insert into public.document_types (code, name, padding) values
  ('APR', 'Approval request', 6), ('CMP', 'Complaint', 6), ('DOC', 'Document', 6)
on conflict (code) do nothing;

insert into public.permissions (code, module, action, description, sort_order) values
  ('prices.approve', 'Products', 'prices_approve', 'Approve price list changes', 33)
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, x.code
  from public.roles r
  join (values
    ('director',            array['prices.approve','documents.manage','complaints.manage']),
    ('delivery_manager',    array['complaints.manage','approvals.act']),
    ('shop_manager',        array['complaints.view']),
    ('quality_officer',     array['complaints.manage']),
    ('finance_manager',     array['documents.manage','complaints.view']),
    ('operations_manager',  array['documents.manage']),
    ('procurement_officer', array['documents.manage']),
    ('hr_manager',          array['approvals.act'])
  ) as m(role_code, perms) on m.role_code = r.code
  cross join lateral unnest(m.perms) as x(code)
 where exists (select 1 from public.permissions p where p.code = x.code)
   and not exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_code = x.code);

-- ---------------------------------------------------------------------
-- Approval rules (approver permission and number of approvers editable in Approvals → Rules)
-- ---------------------------------------------------------------------
insert into public.approval_rules (kind, name, description, approver_permission, levels, threshold_setting, functions, sort_order) values
  ('stock_adjustment', 'Large stock adjustment', 'A stock count that changes stock by more than the limit',
     'inventory.adjust', 1, 'approvals.stock_adjustment_qty', array['adjust_stock'], 10),
  ('order_discount', 'Discount above the limit', 'An order line discounted by more than the limit (the order is created when approved)',
     'pos.discount', 1, 'approvals.discount_percent', array['save_order'], 20),
  ('credit_change', 'Credit limit / payment terms', 'A new credit customer or a change to a credit limit or payment terms (the customer stays on the old terms until approved)',
     'customers.credit', 1, null, array['set_customer_credit'], 30),
  ('price_change', 'Price list change', 'New prices on a price list (they take effect from the chosen date, or the approval date if later)',
     'prices.approve', 1, null, array['set_prices'], 40),
  ('bottle_write_off', 'Bottle write-off', 'Writing off lost or damaged bottles (from an exception, or a single bottle)',
     'bottles.writeoff', 1, null, array['resolve_exception','mark_bottle'], 50);

-- ---------------------------------------------------------------------
-- Notification types
-- ---------------------------------------------------------------------
insert into public.notification_types (code, name, description, permission, severity, sort_order) values
  ('approval_request',  'Approval needed',              'A request waits for your approval', null, 'warning', 10),
  ('approval_decision', 'Your request was decided',     'Approved or rejected', null, 'info', 11),
  ('pending_approvals', 'Items waiting for approval',   'Daily reminder of expenses, purchases, journals, payroll, leave … waiting', null, 'info', 12),
  ('complaint_new',     'New complaint',                'A complaint nobody is handling yet', 'complaints.manage', 'info', 20),
  ('complaint_assigned','Complaint for you',            'Assigned to you, or an update on one you logged', null, 'info', 21),
  ('complaint_overdue', 'Complaint past its due time',  'Not resolved within the SLA', 'complaints.manage', 'warning', 22),
  ('qc_review',         'Quality complaint to review',  'A customer complaint about a batch', 'qc.manage', 'warning', 30),
  ('qc_hold',           'Batch waiting for QC release', 'Production batch on QC hold', 'qc.release', 'info', 31),
  ('low_stock',         'Low stock',                    'Items at or below the reorder level', 'inventory.manage', 'warning', 40),
  ('overdue_invoices',  'Overdue customer balances',    'Daily summary of overdue invoices', 'payments.manage', 'info', 50),
  ('failed_delivery',   'Failed deliveries',            'Deliveries marked not delivered today', 'deliveries.manage', 'warning', 60),
  ('vehicle_alert',     'Vehicle needs attention',      'Service due or vehicle document expiring', 'fleet.manage', 'warning', 70),
  ('document_expiry',   'Document expiring',            'Licence, insurance, contract … about to expire', 'documents.manage', 'warning', 71),
  ('external_bottles',  'External bottles to hand over','Bottles held for another company above the alert level', 'bottles.external', 'info', 80),
  ('messages_failed',   'Messages not sent',            'SMS / WhatsApp / email that failed', 'settings.manage', 'warning', 90);

-- ---------------------------------------------------------------------
-- Customer message templates (English). Nothing is sent until
-- "Customer messages" is switched on in System Settings and a provider
-- is set up in Vercel.
-- ---------------------------------------------------------------------
insert into public.message_templates (code, name, audience, channel, subject, body, variables, is_active) values
  ('ORDER_CONFIRMED', 'Order confirmed', 'customer', 'sms', 'Your order {{order_no}}',
   'Dear {{customer_name}}, your {{company_name}} order {{order_no}} is confirmed for {{delivery_date}}. Total Rs. {{total}}. Thank you!',
   array['customer_name','order_no','delivery_date','total'], true),
  ('DELIVERED', 'Delivered', 'customer', 'sms', 'Delivery {{delivery_no}}',
   '{{company_name}}: delivered ({{delivery_no}}). Bill Rs. {{invoice_total}}, paid Rs. {{paid}}. Your balance is Rs. {{balance}}. Thank you!',
   array['delivery_no','invoice_total','paid','balance'], true),
  ('DELIVERY_MISSED', 'Delivery missed', 'customer', 'sms', 'We missed you',
   'Sorry, {{company_name}} could not deliver today ({{delivery_no}}). We will contact you to deliver again. {{company_phone}}',
   array['delivery_no','company_phone'], true),
  ('PAYMENT_RECEIVED', 'Payment received', 'customer', 'sms', 'Payment received',
   'Thank you! {{company_name}} received Rs. {{amount}} ({{payment_no}}). Your balance is Rs. {{balance}}.',
   array['amount','payment_no','balance'], true),
  ('PAYMENT_REMINDER', 'Payment reminder', 'customer', 'sms', 'Payment reminder',
   'Dear {{customer_name}}, Rs. {{overdue}} is overdue on your {{company_name}} account (since {{due_date}}). Please pay at your next delivery or call {{company_phone}}.',
   array['customer_name','overdue','due_date','company_phone'], true),
  ('COMPLAINT_RECEIVED', 'Complaint received', 'customer', 'sms', 'Complaint {{complaint_no}}',
   '{{company_name}}: we received your complaint {{complaint_no}} ({{subject}}). We will contact you shortly.',
   array['complaint_no','subject'], true),
  ('COMPLAINT_RESOLVED', 'Complaint resolved', 'customer', 'sms', 'Complaint {{complaint_no}} resolved',
   '{{company_name}}: your complaint {{complaint_no}} is resolved — {{resolution}}. Thank you for your patience.',
   array['complaint_no','resolution'], true);

insert into public.complaint_categories (code, name, default_priority, needs_qc_review, sort_order) values
  ('delivery', 'Delivery (late, missed, wrong address)', 'normal', false, 10),
  ('product',  'Product (taste, smell, colour)',          'high',   true,  20),
  ('quality',  'Quality (particles, contamination)',      'urgent', true,  30),
  ('bottle',   'Bottle (leaking, dirty, damaged)',        'normal', false, 40),
  ('driver',   'Driver behaviour',                        'normal', false, 50),
  ('payment',  'Payment / billing',                       'normal', false, 60),
  ('quantity', 'Quantity (short, wrong items)',           'normal', false, 70),
  ('shop',     'Water shop',                              'normal', false, 80);

insert into public.document_categories (code, name, view_permission, manage_permission, has_expiry, sort_order) values
  ('contract',       'Contracts & agreements',          'documents.view',   'documents.manage',  false, 10),
  ('licence',        'Business licences & permits',     'documents.view',   'documents.manage',  true,  20),
  ('insurance',      'Insurance policies',              'documents.view',   'documents.manage',  true,  30),
  ('vehicle',        'Vehicle documents',               'fleet.manage',     'fleet.manage',      false, 40),
  ('employee',       'Employee documents',              'hr.view',          'hr.manage',         false, 50),
  ('qc_certificate', 'QC certificates',                 'qc.view',          'qc.manage',         false, 60),
  ('lab_report',     'Lab reports (water tests)',       'qc.view',          'qc.manage',         false, 70),
  ('purchase',       'Purchase & supplier documents',   'procurement.view', 'procurement.manage',false, 80),
  ('finance',        'Invoices & finance documents',    'payments.view',    'payments.manage',   false, 90),
  ('other',          'Other',                           'documents.view',   'documents.manage',  false, 100);

insert into public.setting_definitions (key, module, label, description, value_type, choices, min_value, max_value, sort_order) values
  ('company.phone', 'Company', 'Customer hotline', 'Phone number shown in customer messages', 'text', null, null, null, 7),
  ('messaging.enabled', 'Messages', 'Send customer messages (SMS / WhatsApp)', 'Master switch. Set up the provider in Vercel first.', 'boolean', null, null, null, 60),
  ('messaging.reminder_after_days', 'Messages', 'Payment reminder: days overdue', 'First reminder when the oldest unpaid invoice is this many days past due', 'integer', null, 1, 90, 61),
  ('messaging.reminder_repeat_days', 'Messages', 'Payment reminder: repeat every (days)', null, 'integer', null, 1, 60, 62),
  ('complaints.sla_hours_urgent', 'Complaints', 'Resolve urgent complaints within (hours)', null, 'integer', null, 1, 720, 70),
  ('complaints.sla_hours_high', 'Complaints', 'Resolve high-priority complaints within (hours)', null, 'integer', null, 1, 720, 71),
  ('complaints.sla_hours_normal', 'Complaints', 'Resolve normal complaints within (hours)', null, 'integer', null, 1, 720, 72),
  ('complaints.sla_hours_low', 'Complaints', 'Resolve low-priority complaints within (hours)', null, 'integer', null, 1, 720, 73),
  ('documents.alert_days', 'Documents', 'Warn before a document expires (days)', 'Default for new documents', 'integer', null, 1, 365, 80),
  ('notifications.scan_minutes', 'Notifications', 'Check for new alerts every (minutes)', null, 'integer', null, 5, 240, 85);

insert into public.system_settings (key, value, effective_from) values
  ('company.phone', '""', date '2026-01-01'),
  ('messaging.enabled', 'false', date '2026-01-01'),
  ('messaging.reminder_after_days', '7', date '2026-01-01'),
  ('messaging.reminder_repeat_days', '7', date '2026-01-01'),
  ('complaints.sla_hours_urgent', '4', date '2026-01-01'),
  ('complaints.sla_hours_high', '24', date '2026-01-01'),
  ('complaints.sla_hours_normal', '48', date '2026-01-01'),
  ('complaints.sla_hours_low', '72', date '2026-01-01'),
  ('documents.alert_days', '30', date '2026-01-01'),
  ('notifications.scan_minutes', '10', date '2026-01-01');

-- >>> 20261007000040_phase3a_read_models.sql
-- =====================================================================
-- OLA Water ERP — Phase 3A
-- 0040: approvals inbox, rules overview, alert scan, complaint and
--       document read models, control summary for the dashboard
-- =====================================================================

-- ---------------------------------------------------------------------
-- Approvals inbox: everything the current user can decide, from every module
-- ---------------------------------------------------------------------
create or replace function public.approval_inbox()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_me uuid := app.current_user_id(); v_items jsonb := '[]';
begin
  if v_me is null then raise exception 'Not signed in' using errcode = '42501'; end if;

  -- requests from approval rules
  v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
      'source', 'request', 'id', q.id, 'ref', q.request_no, 'title', q.title, 'detail', q.details, 'amount', q.amount,
      'kind', q.kind, 'kind_name', r.name, 'reason', q.reason, 'requested_by', p.full_name, 'requested_at', q.requested_at,
      'href', q.href, 'level', q.levels_done + 1, 'levels', q.levels_required,
      'approved_by', (select string_agg(pp.full_name, ', ') from public.approval_steps s join public.profiles pp on pp.id = s.approver_id
                       where s.request_id = q.id and s.decision = 'approve')) order by q.requested_at)
    from public.approval_requests q join public.approval_rules r on r.kind = q.kind
    left join public.profiles p on p.id = q.requested_by
   where q.status = 'pending' and q.requested_by <> v_me and app.has_permission(r.approver_permission)
     and not exists (select 1 from public.approval_steps s where s.request_id = q.id and s.approver_id = v_me)), '[]');

  if app.has_permission('expenses.approve') then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'expense', 'id', x.id, 'ref', x.expense_no, 'title', 'Expense — ' || coalesce(c.name, ''), 'detail', x.description,
        'amount', x.total, 'kind_name', 'Expense', 'requested_by', p.full_name, 'requested_at', x.created_at,
        'href', '/expenses?show=pending_approval') order by x.created_at)
      from public.expenses x left join public.expense_categories c on c.id = x.category_id left join public.profiles p on p.id = x.created_by
     where x.status = 'pending_approval' and x.created_by is distinct from v_me), '[]');
  end if;

  if app.has_permission('accounting.manual_journal') then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'journal', 'id', j.id, 'ref', j.draft_no, 'title', 'Manual journal', 'detail', j.description, 'amount', j.total,
        'kind_name', 'Manual journal', 'requested_by', p.full_name, 'requested_at', j.created_at, 'href', '/accounting/journals') order by j.created_at)
      from public.journal_drafts j left join public.profiles p on p.id = j.created_by
     where j.status = 'pending' and (j.created_by is distinct from v_me or app.is_super_admin())), '[]');
  end if;

  if app.has_permission('procurement.approve') then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'purchase_request', 'id', r.id, 'ref', r.request_no, 'title', 'Purchase request — ' || l.name, 'detail', r.notes,
        'kind_name', 'Purchase request', 'requested_by', p.full_name, 'requested_at', r.requested_at, 'href', '/purchasing') order by r.requested_at)
      from public.purchase_requests r join public.locations l on l.id = r.location_id left join public.profiles p on p.id = r.requested_by
     where r.status = 'submitted'), '[]');
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'purchase_order', 'id', o.id, 'ref', o.po_no, 'title', 'Purchase order — ' || s.name, 'amount', o.total,
        'kind_name', 'Purchase order', 'requested_by', p.full_name, 'requested_at', o.created_at, 'href', '/purchasing/' || o.id) order by o.created_at)
      from public.purchase_orders o join public.suppliers s on s.id = o.supplier_id left join public.profiles p on p.id = o.created_by
     where o.status = 'pending_approval' and (o.created_by is distinct from v_me or app.is_super_admin())), '[]');
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'supplier_invoice', 'id', i.id, 'ref', i.ref_no, 'title', 'Supplier invoice on hold — ' || s.name,
        'detail', 'Invoice ' || i.supplier_invoice_no || ' does not match the order / goods received', 'amount', i.total,
        'kind_name', 'Supplier invoice', 'requested_by', p.full_name, 'requested_at', i.created_at, 'href', '/purchasing') order by i.created_at)
      from public.supplier_invoices i join public.suppliers s on s.id = i.supplier_id left join public.profiles p on p.id = i.created_by
     where i.status = 'on_hold'), '[]');
  end if;

  if app.has_permission('payroll.approve') then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'payroll', 'id', r.id, 'ref', r.run_no, 'title', 'Payroll ' || to_char(make_date(r.pay_year, r.pay_month, 1), 'Mon YYYY'),
        'detail', r.employees || ' employee(s)', 'amount', r.net, 'kind_name', 'Payroll', 'requested_by', p.full_name,
        'requested_at', r.prepared_at, 'href', '/payroll/' || r.id) order by r.prepared_at)
      from public.payroll_runs r left join public.profiles p on p.id = r.prepared_by
     where r.status = 'draft' and (r.prepared_by is distinct from v_me or app.is_super_admin())), '[]');
  end if;

  if app.has_permission('hr.manage') then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'leave', 'id', l.id, 'ref', l.request_no, 'title', 'Leave — ' || e.full_name,
        'detail', t.name || ', ' || l.days || ' day(s) from ' || to_char(l.from_date, 'DD Mon'), 'kind_name', 'Leave',
        'requested_by', p.full_name, 'requested_at', l.requested_at, 'href', '/hr/attendance') order by l.from_date)
      from public.leave_requests l join public.employees e on e.id = l.employee_id join public.leave_types t on t.id = l.leave_type_id
      left join public.profiles p on p.id = l.requested_by
     where l.status = 'pending'), '[]');
  end if;

  if app.has_permission('customers.credit') then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'order_hold', 'id', o.id, 'ref', o.order_no, 'title', 'Order on hold — ' || c.name, 'detail', o.hold_reason,
        'amount', o.total, 'kind_name', 'Order on hold', 'requested_by', p.full_name, 'requested_at', o.created_at,
        'href', '/orders/' || o.id) order by o.created_at)
      from public.orders o join public.customers c on c.id = o.customer_id left join public.profiles p on p.id = o.created_by
     where o.status = 'on_hold'), '[]');
  end if;

  if app.has_permission('shops.stock_approve') then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'shop_request', 'id', r.id, 'ref', r.request_no, 'title', 'Shop stock request — ' || s.name,
        'kind_name', 'Shop stock request', 'requested_by', p.full_name, 'requested_at', r.requested_at, 'href', '/shops/requests') order by r.requested_at)
      from public.shop_stock_requests r join public.water_shops s on s.id = r.shop_id left join public.profiles p on p.id = r.requested_by
     where r.status = 'submitted'), '[]');
  end if;

  if app.has_permission('qc.release') then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object(
        'source', 'qc_hold', 'id', b.id, 'ref', b.batch_no, 'title', 'Batch on QC hold — ' || pr.name,
        'detail', b.planned_qty || ' planned', 'kind_name', 'QC release', 'requested_at', b.created_at,
        'href', '/production/' || b.id) order by b.created_at)
      from public.production_batches b join public.products pr on pr.id = b.product_id
     where b.status = 'qc_hold'), '[]');
  end if;

  return jsonb_build_object(
    'items', v_items,
    'mine', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'ref', q.request_no, 'title', q.title, 'detail', q.details,
               'amount', q.amount, 'status', q.status, 'requested_at', q.requested_at, 'decided_at', q.decided_at,
               'decided_by', p.full_name, 'decision_note', q.decision_note, 'levels', q.levels_required, 'levels_done', q.levels_done,
               'href', q.href) order by q.requested_at desc)
       from (select * from public.approval_requests where requested_by = v_me order by requested_at desc limit 50) q
       left join public.profiles p on p.id = q.decided_by), '[]'));
end $$;

create or replace function public.approval_history(p_from date, p_to date)
returns table (id uuid, request_no text, kind_name text, title text, details text, amount numeric, status text,
               requested_by text, requested_at timestamptz, decided_by text, decided_at timestamptz, decision_note text, steps jsonb)
language sql stable security definer set search_path = '' as $$
  select q.id, q.request_no, r.name, q.title, q.details, q.amount, q.status, rp.full_name, q.requested_at, dp.full_name, q.decided_at,
         q.decision_note,
         (select coalesce(jsonb_agg(jsonb_build_object('level', s.level, 'by', sp.full_name, 'decision', s.decision, 'note', s.note,
                   'at', s.created_at) order by s.created_at), '[]')
            from public.approval_steps s join public.profiles sp on sp.id = s.approver_id where s.request_id = q.id)
    from public.approval_requests q join public.approval_rules r on r.kind = q.kind
    left join public.profiles rp on rp.id = q.requested_by left join public.profiles dp on dp.id = q.decided_by
   where (app.has_permission('approvals.act') or app.has_permission('audit.view') or app.has_permission(r.approver_permission))
     and q.requested_at >= p_from and q.requested_at < p_to + 1
   order by q.requested_at desc
   limit 500
$$;

-- Rules with their limits and who can approve, plus the approvals built into modules.
create or replace function public.approval_rules_overview()
returns jsonb language sql stable security definer set search_path = '' as $$
  with holders as (
    select rp.permission_code, string_agg(distinct r.name, ', ' order by r.name) roles
      from public.role_permissions rp join public.roles r on r.id = rp.role_id and r.archived_at is null
     group by rp.permission_code)
  select jsonb_build_object(
    'rules', (select coalesce(jsonb_agg(jsonb_build_object('kind', a.kind, 'name', a.name, 'description', a.description,
                'approver_permission', a.approver_permission, 'approver_roles', coalesce(h.roles, 'Super Admin only'),
                'levels', a.levels, 'is_active', a.is_active, 'threshold_setting', a.threshold_setting,
                'threshold_label', d.label, 'threshold', app.get_setting(a.threshold_setting),
                'pending', (select count(*) from public.approval_requests q where q.kind = a.kind and q.status = 'pending'))
              order by a.sort_order), '[]')
       from public.approval_rules a left join holders h on h.permission_code = a.approver_permission
       left join public.setting_definitions d on d.key = a.threshold_setting),
    'built_in', (select coalesce(jsonb_agg(jsonb_build_object('name', b.name, 'rule', b.rule, 'permission', b.perm,
                   'approver_roles', coalesce(h.roles, 'Super Admin only'), 'threshold_setting', b.setting,
                   'threshold', case when b.setting is not null then app.get_setting(b.setting) end, 'href', b.href) order by b.ord), '[]')
       from (values
         (1, 'Expenses', 'Above the limit, approved by someone other than the person who entered it', 'expenses.approve', 'approvals.expense_amount', '/expenses'),
         (2, 'Purchases', 'Purchase requests, and purchase orders above the limit', 'procurement.approve', 'approvals.purchase_amount', '/purchasing'),
         (3, 'Supplier invoices that do not match', '3-way match failed — released by an approver', 'procurement.approve', null, '/purchasing'),
         (4, 'Manual journals', 'Prepared by one person, posted by another', 'accounting.manual_journal', null, '/accounting/journals'),
         (5, 'Payroll', 'Prepared by one person, approved by another', 'payroll.approve', null, '/payroll'),
         (6, 'Leave', 'Leave requests', 'hr.manage', null, '/hr/attendance'),
         (7, 'Orders on credit hold', 'Customer over the credit limit or overdue', 'customers.credit', null, '/orders?status=on_hold'),
         (8, 'Shop stock requests', 'Stock asked for by a water shop', 'shops.stock_approve', null, '/shops/requests'),
         (9, 'QC release', 'Batches on QC hold, and releasing a failed batch (override)', 'qc.release', null, '/quality')
       ) as b(ord, name, rule, perm, setting, href)
       left join holders h on h.permission_code = b.perm),
    'permissions', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'label', module || ' — ' || description) order by sort_order), '[]')
                      from public.permissions))
$$;

-- ---------------------------------------------------------------------
-- Alert scan. Cheap to call often: it only runs every
-- notifications.scan_minutes (unless forced by an administrator).
-- ---------------------------------------------------------------------
create or replace function public.refresh_notifications(p_force boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare st public.notification_scan_state; n integer := 0; v_day text := to_char(app.today(), 'YYYY-MM-DD'); x record;
        v_minutes integer := coalesce((app.get_setting('notifications.scan_minutes') #>> '{}')::integer, 10);
        v_after integer := coalesce((app.get_setting('messaging.reminder_after_days') #>> '{}')::integer, 7);
        v_repeat integer := coalesce((app.get_setting('messaging.reminder_repeat_days') #>> '{}')::integer, 7);
        v_reminders integer := 0;
begin
  if app.current_user_id() is null and not app.can_dispatch() then raise exception 'Not signed in' using errcode = '42501'; end if;
  if p_force and not (app.has_permission('settings.manage') or app.can_dispatch()) then p_force := false; end if;
  select * into st from public.notification_scan_state where id = 1 for update skip locked;
  if not found then return jsonb_build_object('ran', false); end if;
  if not p_force and st.last_run_at > now() - make_interval(mins => v_minutes) then
    return jsonb_build_object('ran', false, 'last_run_at', st.last_run_at);
  end if;
  update public.notification_scan_state set last_run_at = now() where id = 1;

  -- low stock (one alert per item per day)
  for x in select p.id, p.name, p.reorder_level, coalesce(sum(b.qty), 0) qty
             from public.products p left join public.inventory_balances b on b.product_id = p.id and b.stock_status = 'available'
            where p.is_active and p.reorder_level > 0 group by p.id having coalesce(sum(b.qty), 0) <= p.reorder_level loop
    n := n + app.notify('low_stock', 'Low stock: ' || x.name, format('%s left (reorder level %s)', x.qty, x.reorder_level), '/inventory',
                        'low-stock:' || x.id || ':' || v_day);
  end loop;

  -- vehicles
  for x in select f.id, f.registration_no, f.alerts from public.fleet_overview() f where f.is_active and cardinality(f.alerts) > 0 loop
    n := n + app.notify('vehicle_alert', x.registration_no || ': ' || array_to_string(x.alerts, ', '), null, '/fleet/' || x.id,
                        'vehicle:' || x.id || ':' || md5(array_to_string(x.alerts, ',')) || ':' || v_day);
  end loop;

  -- documents expiring (the people who manage that kind of document are told)
  for x in select d.id, d.doc_no, d.title, d.expires_on, c.manage_permission
             from public.documents d join public.document_categories c on c.code = d.category_code
            where d.status = 'active' and d.expires_on is not null and d.expires_on <= app.today() + d.alert_days loop
    n := n + app.notify('document_expiry',
      case when x.expires_on < app.today() then 'Expired: ' else 'Expiring ' || to_char(x.expires_on, 'DD Mon') || ': ' end || x.title,
      x.doc_no, '/documents?show=expiring', 'doc-expiry:' || x.id || ':' || (x.expires_on < app.today()), null,
      case when x.expires_on < app.today() then 'critical' end, x.manage_permission);
  end loop;

  -- external bottles above the alert level (once a day)
  for x in select c.name, h.qty, h.alert from (
             select b.company_id, sum(b.qty) qty,
                    coalesce(bc.holding_alert_qty, (app.get_setting('bottles.external_holding_alert_qty') #>> '{}')::integer) alert
               from public.bottle_balances b join public.locations l on l.id = b.holder_id
               join public.bottle_companies bc on bc.id = b.company_id
              where b.holder_type = 'location' and l.location_type = 'external_holding' and not bc.is_own
              group by b.company_id, bc.holding_alert_qty) h join public.bottle_companies c on c.id = h.company_id
            where h.qty > h.alert loop
    n := n + app.notify('external_bottles', x.name || ': ' || x.qty || ' bottles held', 'Alert level ' || x.alert || ' — arrange a hand-over',
                        '/bottles/external', 'ext:' || x.name || ':' || v_day);
  end loop;

  -- failed deliveries today
  select count(*) cnt into x from public.deliveries d join public.route_runs r on r.id = d.run_id
   where d.status = 'failed' and r.run_date = app.today();
  if x.cnt > 0 then
    n := n + app.notify('failed_delivery', x.cnt || ' failed delivery(ies) today', null, '/dispatch', 'failed:' || v_day || ':' || x.cnt);
  end if;

  -- complaints past their due time
  for x in select id, complaint_no, subject, assigned_to from public.complaints
            where status not in ('resolved','closed') and due_at < now() loop
    n := n + app.notify('complaint_overdue', 'Overdue complaint ' || x.complaint_no, x.subject, '/complaints/' || x.id, 'cmp-overdue:' || x.id);
    if x.assigned_to is not null then
      n := n + app.notify('complaint_overdue', 'Overdue complaint ' || x.complaint_no, x.subject, '/complaints/' || x.id,
                          'cmp-overdue-me:' || x.id, x.assigned_to);
    end if;
  end loop;

  -- QC holds
  for x in select b.id, b.batch_no, p.name from public.production_batches b join public.products p on p.id = b.product_id
            where b.status = 'qc_hold' loop
    n := n + app.notify('qc_hold', 'Batch ' || x.batch_no || ' waiting for QC release', x.name, '/production/' || x.id, 'qc-hold:' || x.id);
  end loop;

  -- items waiting for approval in modules (one reminder a day per kind)
  for x in select * from (values
      ('expenses.approve', (select count(*) from public.expenses where status = 'pending_approval'), 'expense(s)', '/expenses?show=pending_approval'),
      ('procurement.approve', (select count(*) from public.purchase_orders where status = 'pending_approval')
                              + (select count(*) from public.purchase_requests where status = 'submitted'), 'purchase(s)', '/purchasing'),
      ('accounting.manual_journal', (select count(*) from public.journal_drafts where status = 'pending'), 'manual journal(s)', '/accounting/journals'),
      ('payroll.approve', (select count(*) from public.payroll_runs where status = 'draft'), 'payroll run(s)', '/payroll'),
      ('hr.manage', (select count(*) from public.leave_requests where status = 'pending'), 'leave request(s)', '/hr/attendance'),
      ('shops.stock_approve', (select count(*) from public.shop_stock_requests where status = 'submitted'), 'shop stock request(s)', '/shops/requests'),
      ('customers.credit', (select count(*) from public.orders where status = 'on_hold'), 'order(s) on credit hold', '/orders?status=on_hold')
    ) as t(perm, cnt, what, href) where t.cnt > 0 loop
    n := n + app.notify('pending_approvals', x.cnt || ' ' || x.what || ' waiting for approval', null, x.href,
                        'pending:' || x.perm || ':' || v_day, null, null, x.perm);
  end loop;

  -- overdue customer balances: staff summary once a day, customer reminders
  select count(distinct customer_id) cnt, coalesce(sum(balance), 0) amt into x from public.invoices
   where status in ('open','partially_paid') and due_date < app.today() and balance > 0;
  if x.cnt > 0 then
    n := n + app.notify('overdue_invoices', x.cnt || ' customer(s) overdue', 'Rs. ' || to_char(x.amt, 'FM999,999,999,990.00') || ' past due',
                        '/accounting/reports/ar-ageing', 'overdue:' || v_day);
  end if;
  for x in select i.customer_id, sum(i.balance) overdue, min(i.due_date) oldest
             from public.invoices i join public.customers c on c.id = i.customer_id
            where i.status in ('open','partially_paid') and i.balance > 0 and i.due_date <= app.today() - v_after
              and not c.messages_opt_out and not c.is_walk_in
            group by i.customer_id loop
    if not exists (select 1 from public.message_outbox m where m.customer_id = x.customer_id and m.template_code = 'PAYMENT_REMINDER'
                     and m.status <> 'cancelled' and m.created_at > now() - make_interval(days => v_repeat)) then
      if app.queue_customer_message('PAYMENT_REMINDER', x.customer_id,
           jsonb_build_object('overdue', to_char(x.overdue, 'FM999,999,990.00'), 'due_date', to_char(x.oldest, 'DD Mon YYYY')),
           'reminder', null, 'reminder:' || x.customer_id || ':' || v_day) is not null then
        v_reminders := v_reminders + 1;
      end if;
    end if;
  end loop;

  -- messages that failed today
  select count(*) cnt into x from public.message_outbox where status = 'failed' and created_at > now() - interval '1 day';
  if x.cnt > 0 then
    n := n + app.notify('messages_failed', x.cnt || ' message(s) could not be sent', 'Check Messages for the reason', '/messages?show=failed',
                        'msg-failed:' || v_day || ':' || x.cnt);
  end if;

  return jsonb_build_object('ran', true, 'created', n, 'reminders', v_reminders);
end $$;

-- ---------------------------------------------------------------------
-- Complaints
-- ---------------------------------------------------------------------
create or replace function public.complaint_details(p_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not (app.has_permission('complaints.view') or app.has_permission('complaints.manage')
                        or (c.batch_id is not null and app.has_permission('qc.view')) or c.assigned_to = app.current_user_id()) then null
  else jsonb_build_object(
    'complaint', to_jsonb(c) || jsonb_build_object(
        'category', cat.name, 'assigned_name', a.full_name, 'created_by_name', cb.full_name,
        'overdue', c.status not in ('resolved','closed') and c.due_at < now()),
    'customer', (select jsonb_build_object('id', cu.id, 'name', cu.name, 'customer_no', cu.customer_no, 'phone', cu.phone,
                   'outstanding', app.customer_outstanding(cu.id), 'complaints', (select count(*) from public.complaints z where z.customer_id = cu.id))
                   from public.customers cu where cu.id = c.customer_id),
    'links', jsonb_build_object(
        'order', (select jsonb_build_object('id', o.id, 'no', o.order_no) from public.orders o where o.id = c.order_id),
        'delivery', (select jsonb_build_object('id', d.id, 'no', d.delivery_no, 'run_id', d.run_id) from public.deliveries d where d.id = c.delivery_id),
        'invoice', (select jsonb_build_object('id', i.id, 'no', i.invoice_no) from public.invoices i where i.id = c.invoice_id),
        'batch', (select jsonb_build_object('id', b.id, 'no', b.batch_no, 'status', b.status, 'product', p.name)
                    from public.production_batches b join public.products p on p.id = b.product_id where b.id = c.batch_id),
        'bottle', (select jsonb_build_object('id', bt.id, 'code', bt.code) from public.bottles bt where bt.id = c.bottle_id),
        'product', (select jsonb_build_object('id', p.id, 'name', p.name) from public.products p where p.id = c.product_id),
        'driver', (select jsonb_build_object('id', p.id, 'name', p.full_name) from public.profiles p where p.id = c.driver_id),
        'location', (select jsonb_build_object('id', l.id, 'name', l.name) from public.locations l where l.id = c.location_id)),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'event', e.event, 'from_status', e.from_status,
                 'to_status', e.to_status, 'note', e.note, 'photo_path', e.photo_path, 'created_at', e.created_at, 'by', p.full_name)
                 order by e.created_at), '[]')
                 from public.complaint_events e left join public.profiles p on p.id = e.created_by where e.complaint_id = c.id))
  end
  from public.complaints c join public.complaint_categories cat on cat.code = c.category_code
  left join public.profiles a on a.id = c.assigned_to left join public.profiles cb on cb.id = c.created_by
  where c.id = p_id
$$;

create or replace function public.complaints_summary(p_from date, p_to date)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not (app.has_permission('complaints.view') or app.has_permission('complaints.manage')) then null else jsonb_build_object(
    'open', (select count(*) from public.complaints where status not in ('resolved','closed')),
    'overdue', (select count(*) from public.complaints where status not in ('resolved','closed') and due_at < now()),
    'unassigned', (select count(*) from public.complaints where status = 'new'),
    'qc_review', (select count(*) from public.complaints where qc_review_status = 'requested'),
    'logged', (select count(*) from public.complaints where created_at >= p_from and created_at < p_to + 1),
    'resolved', (select count(*) from public.complaints where resolved_at >= p_from and resolved_at < p_to + 1),
    'within_sla_pct', (select round(100.0 * count(*) filter (where resolved_at <= due_at) / nullif(count(*), 0), 0)
                         from public.complaints where resolved_at >= p_from and resolved_at < p_to + 1),
    'avg_hours_to_resolve', (select round(avg(extract(epoch from resolved_at - created_at) / 3600)::numeric, 1)
                               from public.complaints where resolved_at >= p_from and resolved_at < p_to + 1),
    'by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', cat.name, 'count', x.cnt) order by x.cnt desc), '[]')
                      from (select category_code, count(*) cnt from public.complaints
                             where created_at >= p_from and created_at < p_to + 1 group by category_code) x
                      join public.complaint_categories cat on cat.code = x.category_code))
  end
$$;

-- ---------------------------------------------------------------------
-- Documents: what expires soon (library + vehicle documents)
-- ---------------------------------------------------------------------
create or replace function public.expiring_documents(p_days integer default 60)
returns table (source text, id uuid, title text, category text, reference_no text, expires_on date, days_left integer, href text)
language sql stable security definer set search_path = '' as $$
  select 'document', d.id, d.title, c.name, d.reference_no, d.expires_on, (d.expires_on - app.today())::integer,
         '/documents/' || d.id
    from public.documents d join public.document_categories c on c.code = d.category_code
   where d.status = 'active' and d.expires_on is not null and d.expires_on <= app.today() + greatest(coalesce(p_days, 60), d.alert_days)
     and app.has_permission(c.view_permission)
  union all
  select 'vehicle', v.id, v.registration_no || ' — ' || replace(x.doc_type, '_', ' '), 'Vehicle documents', x.doc_no, x.expires_on,
         (x.expires_on - app.today())::integer, '/fleet/' || v.id
    from (select distinct on (vehicle_id, doc_type) * from public.vehicle_documents order by vehicle_id, doc_type, expires_on desc) x
    join public.vehicles v on v.id = x.vehicle_id
   where v.is_active and x.expires_on <= app.today() + coalesce(p_days, 60) and app.has_permission('fleet.manage')
  order by 6
$$;

create or replace function public.entity_documents(p_type text, p_id uuid)
returns table (id uuid, doc_no text, category text, title text, reference_no text, file_path text, file_name text, mime_type text,
               issued_on date, expires_on date, created_at timestamptz, uploaded_by text, can_manage boolean)
language sql stable security definer set search_path = '' as $$
  select d.id, d.doc_no, c.name, d.title, d.reference_no, d.file_path, d.file_name, d.mime_type, d.issued_on, d.expires_on, d.created_at,
         p.full_name, app.has_permission(c.manage_permission)
    from public.documents d join public.document_categories c on c.code = d.category_code
    left join public.profiles p on p.id = d.created_by
   where d.entity_type = p_type and d.entity_id = p_id and d.status = 'active' and app.has_permission(c.view_permission)
   order by d.created_at desc
$$;

-- Names of active staff (to assign complaints); no contact details.
create or replace function public.staff_directory()
returns table (id uuid, full_name text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.full_name from public.profiles p
   where p.is_active and app.current_user_id() is not null
     and (app.has_permission('complaints.manage') or app.has_permission('complaints.view') or app.has_permission('users.manage'))
   order by p.full_name
$$;

-- ---------------------------------------------------------------------
-- Dashboard: approvals, complaints, documents, messages
-- ---------------------------------------------------------------------
create or replace function public.control_summary()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'approvals_waiting', jsonb_array_length(public.approval_inbox() -> 'items'),
    'complaints', case when app.has_permission('complaints.view') or app.has_permission('complaints.manage') then jsonb_build_object(
        'open', (select count(*) from public.complaints where status not in ('resolved','closed')),
        'overdue', (select count(*) from public.complaints where status not in ('resolved','closed') and due_at < now()),
        'unassigned', (select count(*) from public.complaints where status = 'new'),
        'mine', (select count(*) from public.complaints where status not in ('resolved','closed') and assigned_to = app.current_user_id())) end,
    'qc_reviews', case when app.has_permission('qc.manage') then (select count(*) from public.complaints where qc_review_status = 'requested') end,
    'documents_expiring', (select count(*) from public.expiring_documents(30) where days_left <= 30),
    'documents_expired', (select count(*) from public.expiring_documents(30) where days_left < 0),
    'messages', case when app.has_permission('settings.manage') then jsonb_build_object(
        'queued', (select count(*) from public.message_outbox where status in ('queued','sending')),
        'failed', (select count(*) from public.message_outbox where status = 'failed' and created_at > now() - interval '7 days'),
        'sent_today', (select count(*) from public.message_outbox where status = 'sent' and sent_at >= app.today()),
        'enabled', coalesce((app.get_setting('messaging.enabled') #>> '{}')::boolean, false)) end)
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
grant execute on function app.document_can(text, boolean)      to authenticated, service_role;
revoke execute on function public.log_failed_login(text, text, text, text) from authenticated;
revoke execute on function public.bootstrap_super_admin(text)              from authenticated;

grant select on all tables in schema public to authenticated, service_role;
revoke all on all tables in schema public from anon;

commit;
