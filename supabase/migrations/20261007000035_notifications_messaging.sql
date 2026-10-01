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
