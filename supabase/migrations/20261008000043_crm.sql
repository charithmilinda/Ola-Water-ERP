-- =====================================================================
-- OLA Water ERP — Phase 3B
-- 0043: CRM — leads and prospects, follow-ups / activities,
--       opportunities, customer segments, campaigns (with SMS to a
--       segment), promotions applied automatically to orders, and
--       conversion tracking (lead → customer → first sale)
-- =====================================================================

create table public.customer_segments (
  id           uuid primary key default gen_random_uuid(),
  name         text not null unique check (length(trim(name)) > 0),
  description  text,
  rules        jsonb not null default '{}',
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now()
);
comment on column public.customer_segments.rules is
  '{customer_types[], route_ids[], sales_rep_ids[], bottle_models[], cities[], min_days_since_order, max_days_since_order, has_overdue, created_after, min_monthly_sales}';
create trigger customer_segments_touch before update on public.customer_segments for each row execute function app.touch_updated_at();
create trigger customer_segments_audit after insert or update on public.customer_segments for each row execute function app.audit_row('crm');

create table public.promotions (
  id             uuid primary key default gen_random_uuid(),
  code           text not null unique check (code ~ '^[A-Z0-9_-]{2,16}$'),
  name           text not null,
  kind           text not null check (kind in ('percent','amount_per_unit','fixed_price','buy_x_get_y')),
  value          numeric(12,2) not null check (value > 0),     -- %, Rs. off per unit, special unit price, or free units
  buy_qty        integer check (buy_qty > 0),                  -- buy_x_get_y: buy this many
  product_id     uuid references public.products(id),          -- null = every product
  customer_types text[],                                       -- null = every type
  segment_id     uuid references public.customer_segments(id),
  price_list_id  uuid references public.price_lists(id),
  min_qty        numeric(12,3) not null default 0,
  start_date     date not null,
  end_date       date not null,
  status         text not null default 'draft' check (status in ('draft','active','ended')),
  approved_by    uuid,
  approved_at    timestamptz,
  notes          text,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  check (end_date >= start_date),
  check (kind <> 'percent' or value <= 100),
  check (kind <> 'buy_x_get_y' or buy_qty is not null)
);
create trigger promotions_touch before update on public.promotions for each row execute function app.touch_updated_at();
create trigger promotions_audit after insert or update on public.promotions for each row execute function app.audit_row('crm');

create table public.campaigns (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique check (code ~ '^[A-Z0-9_-]{2,16}$'),
  name          text not null,
  channel       text not null check (channel in ('sms','whatsapp','facebook','instagram','flyers','radio','event','field','referral','other')),
  objective     text,
  segment_id    uuid references public.customer_segments(id),
  promotion_id  uuid references public.promotions(id),
  start_date    date not null,
  end_date      date,
  budget        numeric(14,2) not null default 0 check (budget >= 0),
  spent         numeric(14,2) not null default 0 check (spent >= 0),
  status        text not null default 'planned' check (status in ('planned','active','completed','cancelled')),
  notes         text,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now()
);
create trigger campaigns_touch before update on public.campaigns for each row execute function app.touch_updated_at();
create trigger campaigns_audit after insert or update on public.campaigns for each row execute function app.audit_row('crm');

create table public.leads (
  id                   uuid primary key default gen_random_uuid(),
  lead_no              text not null unique,
  name                 text not null check (length(trim(name)) > 0),
  company_name         text,
  contact_person       text,
  phone                text check (phone ~ '^\+[1-9][0-9]{7,14}$'),
  email                text,
  address_line         text,
  city                 text,
  gps_lat              numeric(9,6),
  gps_lng              numeric(9,6),
  customer_type        text references public.customer_type_defaults(customer_type),
  source               text not null default 'phone' check (source in ('phone','walk_in','referral','website','facebook','instagram','whatsapp','campaign','field_visit','event','other')),
  campaign_id          uuid references public.campaigns(id),
  territory_id         uuid references public.territories(id),
  owner_id             uuid references public.profiles(id),
  status               text not null default 'new' check (status in ('new','contacted','qualified','proposal','won','lost')),
  est_monthly_bottles  integer check (est_monthly_bottles >= 0),
  est_monthly_value    numeric(14,2) check (est_monthly_value >= 0),
  next_follow_up       date,
  lost_reason          text,
  customer_id          uuid references public.customers(id),
  converted_at         timestamptz,
  notes                text,
  created_at           timestamptz not null default now(),
  created_by           uuid,
  updated_at           timestamptz not null default now(),
  check (phone is not null or email is not null or address_line is not null)
);
create index leads_status_idx on public.leads (status, next_follow_up);
create index leads_phone_idx on public.leads (phone);
create trigger leads_touch before update on public.leads for each row execute function app.touch_updated_at();
create trigger leads_audit after insert or update on public.leads for each row execute function app.audit_row('crm');

alter table public.rep_visits add constraint rep_visits_lead_fk foreign key (lead_id) references public.leads(id);
alter table public.customers add column lead_id uuid references public.leads(id);
alter table public.customers add column campaign_id uuid references public.campaigns(id);

create table public.opportunities (
  id              uuid primary key default gen_random_uuid(),
  opp_no          text not null unique,
  title           text not null check (length(trim(title)) > 0),
  lead_id         uuid references public.leads(id),
  customer_id     uuid references public.customers(id),
  owner_id        uuid references public.profiles(id),
  stage           text not null default 'prospecting' check (stage in ('prospecting','proposal','negotiation','won','lost')),
  monthly_value   numeric(14,2) not null default 0 check (monthly_value >= 0),
  probability     integer not null default 20 check (probability between 0 and 100),
  expected_close  date,
  lost_reason     text,
  closed_at       timestamptz,
  notes           text,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  check (lead_id is not null or customer_id is not null)
);
create trigger opportunities_touch before update on public.opportunities for each row execute function app.touch_updated_at();
create trigger opportunities_audit after insert or update on public.opportunities for each row execute function app.audit_row('crm');

create table public.crm_activities (
  id              uuid primary key default gen_random_uuid(),
  lead_id         uuid references public.leads(id),
  customer_id     uuid references public.customers(id),
  opportunity_id  uuid references public.opportunities(id),
  kind            text not null check (kind in ('call','visit','whatsapp','sms','email','meeting','note','task')),
  subject         text not null check (length(trim(subject)) > 0),
  notes           text,
  due_on          date,
  done_at         timestamptz,
  outcome         text,
  owner_id        uuid references public.profiles(id),
  created_at      timestamptz not null default now(),
  created_by      uuid,
  check (lead_id is not null or customer_id is not null or opportunity_id is not null)
);
create index crm_activities_due_idx on public.crm_activities (owner_id, due_on) where done_at is null;
create trigger crm_activities_audit after insert or update on public.crm_activities for each row execute function app.audit_row('crm');

alter table public.order_items add column promotion_id uuid references public.promotions(id);
alter table public.order_items add column promo_discount numeric(12,2) not null default 0 check (promo_discount >= 0);

-- ---------------------------------------------------------------------
-- Segments
-- ---------------------------------------------------------------------
create or replace function app.segment_customer_ids(p_rules jsonb)
returns setof uuid language sql stable security definer set search_path = '' as $$
  with last_order as (select customer_id, max(invoice_date) last_date from public.invoices where status <> 'void' group by customer_id),
       avg_sales as (select customer_id, sum(subtotal_net) / 3 avg_net from public.invoices
                      where status <> 'void' and invoice_date >= app.today() - 90 group by customer_id)
  select c.id from public.customers c
    left join last_order lo on lo.customer_id = c.id
    left join avg_sales s on s.customer_id = c.id
   where c.status = 'active' and not c.is_walk_in
     and (jsonb_array_length(coalesce(p_rules -> 'customer_types', '[]')) = 0 or c.customer_type in (select jsonb_array_elements_text(p_rules -> 'customer_types')))
     and (jsonb_array_length(coalesce(p_rules -> 'route_ids', '[]')) = 0 or c.route_id::text in (select jsonb_array_elements_text(p_rules -> 'route_ids')))
     and (jsonb_array_length(coalesce(p_rules -> 'sales_rep_ids', '[]')) = 0 or c.sales_rep_id::text in (select jsonb_array_elements_text(p_rules -> 'sales_rep_ids')))
     and (jsonb_array_length(coalesce(p_rules -> 'bottle_models', '[]')) = 0 or c.bottle_model in (select jsonb_array_elements_text(p_rules -> 'bottle_models')))
     and (jsonb_array_length(coalesce(p_rules -> 'cities', '[]')) = 0 or exists (
            select 1 from public.customer_addresses a where a.customer_id = c.id and a.is_active
               and lower(a.city) in (select lower(jsonb_array_elements_text(p_rules -> 'cities')))))
     and (app.jint(p_rules, 'min_days_since_order') is null or coalesce(lo.last_date, date '1900-01-01') <= app.today() - app.jint(p_rules, 'min_days_since_order'))
     and (app.jint(p_rules, 'max_days_since_order') is null or lo.last_date >= app.today() - app.jint(p_rules, 'max_days_since_order'))
     and (app.jbool(p_rules, 'has_overdue', null) is null or app.jbool(p_rules, 'has_overdue', null) = exists (
            select 1 from public.invoices i where i.customer_id = c.id and i.status in ('open','partially_paid') and i.balance > 0 and i.due_date < app.today()))
     and (app.jtext(p_rules, 'created_after') is null or c.created_at >= (app.jtext(p_rules, 'created_after'))::date)
     and (app.jnum(p_rules, 'min_monthly_sales') is null or coalesce(s.avg_net, 0) >= app.jnum(p_rules, 'min_monthly_sales'))
$$;

create or replace function app.segment_has(p_segment uuid, p_customer uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.customer_segments s, app.segment_customer_ids(s.rules) x(id)
                  where s.id = p_segment and s.is_active and x.id = p_customer)
$$;

create or replace function public.save_segment(p_id uuid, p_name text, p_description text, p_rules jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform app.require_permission('crm.manage');
  if nullif(trim(p_name), '') is null then raise exception 'Name the segment' using errcode = '22023'; end if;
  if p_id is null then
    insert into public.customer_segments (name, description, rules, created_by) values (trim(p_name), p_description, coalesce(p_rules, '{}'), app.current_user_id())
    returning id into v;
  else
    update public.customer_segments set name = trim(p_name), description = p_description, rules = coalesce(p_rules, '{}') where id = p_id returning id into v;
    if v is null then raise exception 'Segment not found' using errcode = 'P0002'; end if;
  end if;
  return jsonb_build_object('segment_id', v, 'customers', (select count(*) from app.segment_customer_ids(coalesce(p_rules, '{}'))));
end $$;

create or replace function public.segment_preview(p_rules jsonb, p_limit integer default 50)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not app.has_permission('crm.manage') then null else jsonb_build_object(
    'count', (select count(*) from app.segment_customer_ids(coalesce(p_rules, '{}'))),
    'with_phone', (select count(*) from app.segment_customer_ids(coalesce(p_rules, '{}')) x(id) join public.customers c on c.id = x.id
                    where not c.messages_opt_out),
    'sample', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'customer_no', c.customer_no, 'type', c.customer_type)), '[]')
                 from (select c.* from app.segment_customer_ids(coalesce(p_rules, '{}')) x(id) join public.customers c on c.id = x.id
                        order by c.name limit p_limit) c)) end
$$;

-- ---------------------------------------------------------------------
-- Promotions (applied automatically to order lines)
-- ---------------------------------------------------------------------
create or replace function app.promotion_discount(p_product uuid, p_customer uuid, p_qty numeric, p_price numeric, p_date date)
returns table (promotion_id uuid, amount numeric) language plpgsql stable security definer set search_path = '' as $$
declare c public.customers; pr record; v_best uuid; v_amt numeric := 0; a numeric;
begin
  select * into c from public.customers where id = p_customer;
  for pr in select * from public.promotions p
             where p.status = 'active' and p_date between p.start_date and p.end_date
               and (p.product_id is null or p.product_id = p_product)
               and (p.price_list_id is null or p.price_list_id = c.price_list_id)
               and (p.customer_types is null or cardinality(p.customer_types) = 0 or c.customer_type = any(p.customer_types))
               and p_qty >= p.min_qty loop
    continue when pr.segment_id is not null and not app.segment_has(pr.segment_id, p_customer);
    a := case pr.kind
           when 'percent' then round(p_qty * p_price * pr.value / 100, 2)
           when 'amount_per_unit' then round(least(pr.value, p_price) * p_qty, 2)
           when 'fixed_price' then round(greatest(p_price - pr.value, 0) * p_qty, 2)
           when 'buy_x_get_y' then round(floor(p_qty / (pr.buy_qty + pr.value)) * pr.value * p_price, 2) end;
    if a > v_amt then v_amt := a; v_best := pr.id; end if;
  end loop;
  return query select v_best, least(v_amt, round(p_qty * p_price, 2));
end $$;

-- p: code, name, kind, value, buy_qty, product_id, customer_types[], segment_id, price_list_id, min_qty, start_date, end_date, notes
create or replace function public.save_promotion(p_id uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; o public.promotions;
begin
  perform app.require_permission('crm.manage');
  if app.jtext(p, 'code') is null or app.jtext(p, 'name') is null then raise exception 'Enter a code and a name' using errcode = '22023'; end if;
  if p_id is not null then
    select * into o from public.promotions where id = p_id for update;
    if not found then raise exception 'Promotion not found' using errcode = 'P0002'; end if;
    if o.status <> 'draft' then raise exception 'An active promotion cannot be changed — end it and create a new one' using errcode = '22023'; end if;
  end if;
  if p_id is null then
    insert into public.promotions (code, name, kind, value, buy_qty, product_id, customer_types, segment_id, price_list_id, min_qty, start_date, end_date, notes, created_by)
    values (upper(app.jtext(p, 'code')), app.jtext(p, 'name'), app.jtext(p, 'kind'), app.jnum(p, 'value'), app.jint(p, 'buy_qty'),
      app.juuid(p, 'product_id'), nullif((select array_agg(x) from jsonb_array_elements_text(coalesce(p -> 'customer_types', '[]')) x), '{}'),
      app.juuid(p, 'segment_id'), app.juuid(p, 'price_list_id'), coalesce(app.jnum(p, 'min_qty'), 0),
      (app.jtext(p, 'start_date'))::date, (app.jtext(p, 'end_date'))::date, app.jtext(p, 'notes'), app.current_user_id())
    returning id into v;
  else
    update public.promotions set code = upper(app.jtext(p, 'code')), name = app.jtext(p, 'name'), kind = app.jtext(p, 'kind'), value = app.jnum(p, 'value'),
      buy_qty = app.jint(p, 'buy_qty'), product_id = app.juuid(p, 'product_id'),
      customer_types = nullif((select array_agg(x) from jsonb_array_elements_text(coalesce(p -> 'customer_types', '[]')) x), '{}'),
      segment_id = app.juuid(p, 'segment_id'), price_list_id = app.juuid(p, 'price_list_id'), min_qty = coalesce(app.jnum(p, 'min_qty'), 0),
      start_date = (app.jtext(p, 'start_date'))::date, end_date = (app.jtext(p, 'end_date'))::date, notes = app.jtext(p, 'notes')
     where id = p_id returning id into v;
  end if;
  return v;
end $$;

-- Switching a promotion on is a price change: it needs the price approver (see Approvals → Rules).
create or replace function public.activate_promotion(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.promotions;
begin
  perform app.require_permission('crm.manage');
  select * into o from public.promotions where id = p_id for update;
  if not found then raise exception 'Promotion not found' using errcode = 'P0002'; end if;
  if o.status <> 'draft' then raise exception 'Only a draft promotion can be switched on' using errcode = '22023'; end if;
  if o.end_date < app.today() then raise exception 'This promotion has already ended' using errcode = '22023'; end if;
  perform app.require_approval('promotion', 'Switching on a promotion needs approval');
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Promotion switched on'), null, 'activate');
  update public.promotions set status = 'active', approved_by = app.current_user_id(), approved_at = now() where id = p_id;
end $$;

create or replace function public.end_promotion(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_permission('crm.manage');
  perform app.set_context(coalesce(nullif(trim(p_reason), ''), 'Promotion ended'), null, null);
  update public.promotions set status = 'ended', end_date = least(end_date, app.today()) where id = p_id and status in ('draft','active');
  if not found then raise exception 'Promotion not found or already ended' using errcode = '22023'; end if;
end $$;

-- ---------------------------------------------------------------------
-- Campaigns
-- ---------------------------------------------------------------------
create or replace function public.save_campaign(p_id uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform app.require_permission('crm.manage');
  if app.jtext(p, 'code') is null or app.jtext(p, 'name') is null then raise exception 'Enter a code and a name' using errcode = '22023'; end if;
  if p_id is null then
    insert into public.campaigns (code, name, channel, objective, segment_id, promotion_id, start_date, end_date, budget, spent, notes, created_by)
    values (upper(app.jtext(p, 'code')), app.jtext(p, 'name'), coalesce(app.jtext(p, 'channel'), 'other'), app.jtext(p, 'objective'),
      app.juuid(p, 'segment_id'), app.juuid(p, 'promotion_id'), coalesce((app.jtext(p, 'start_date'))::date, app.today()),
      (app.jtext(p, 'end_date'))::date, coalesce(app.jnum(p, 'budget'), 0), coalesce(app.jnum(p, 'spent'), 0), app.jtext(p, 'notes'), app.current_user_id())
    returning id into v;
  else
    update public.campaigns set code = upper(app.jtext(p, 'code')), name = app.jtext(p, 'name'), channel = coalesce(app.jtext(p, 'channel'), channel),
      objective = app.jtext(p, 'objective'), segment_id = app.juuid(p, 'segment_id'), promotion_id = app.juuid(p, 'promotion_id'),
      start_date = coalesce((app.jtext(p, 'start_date'))::date, start_date), end_date = (app.jtext(p, 'end_date'))::date,
      budget = coalesce(app.jnum(p, 'budget'), 0), spent = coalesce(app.jnum(p, 'spent'), 0), status = coalesce(app.jtext(p, 'status'), status),
      notes = app.jtext(p, 'notes')
     where id = p_id returning id into v;
    if v is null then raise exception 'Campaign not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

-- Queue an SMS / WhatsApp to every customer in the campaign's segment (once per customer per campaign).
create or replace function public.send_campaign_message(p_campaign uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare cp public.campaigns; seg public.customer_segments; c record; n integer := 0; v_skipped integer := 0; v_max integer; v_vars jsonb; v_id uuid;
        v_channel text;
begin
  perform app.require_permission('crm.manage');
  select * into cp from public.campaigns where id = p_campaign;
  if not found then raise exception 'Campaign not found' using errcode = 'P0002'; end if;
  if cp.status in ('completed','cancelled') then raise exception 'This campaign is %', cp.status using errcode = '22023'; end if;
  if nullif(trim(p_body), '') is null then raise exception 'Write the message' using errcode = '22023'; end if;
  if length(p_body) > 480 then raise exception 'Keep the message under 480 characters (3 SMS)' using errcode = '22023'; end if;
  if not coalesce((app.get_setting('messaging.enabled') #>> '{}')::boolean, false) then
    raise exception 'Customer messages are switched off (Messages & Alerts)' using errcode = '22023';
  end if;
  select * into seg from public.customer_segments where id = cp.segment_id;
  if seg.id is null then raise exception 'Choose the customer segment for this campaign first' using errcode = '22023'; end if;
  v_max := coalesce((app.get_setting('crm.max_campaign_messages') #>> '{}')::integer, 2000);
  if (select count(*) from app.segment_customer_ids(seg.rules)) > v_max then
    raise exception 'The segment has more than % customers — narrow it, or raise the limit in System Settings', v_max using errcode = '22023';
  end if;
  v_channel := case when cp.channel = 'whatsapp' then 'whatsapp' else 'sms' end;
  perform app.set_context('Campaign message ' || cp.code, null, 'campaign_message');
  for c in select cu.* from app.segment_customer_ids(seg.rules) x(id) join public.customers cu on cu.id = x.id loop
    if c.messages_opt_out then v_skipped := v_skipped + 1; continue; end if;
    v_vars := jsonb_build_object('customer_name', c.name, 'customer_no', c.customer_no,
                'company_name', coalesce(app.get_setting('company.name') #>> '{}', 'OLA Water'),
                'company_phone', coalesce(app.get_setting('company.phone') #>> '{}', ''));
    v_id := null;
    insert into public.message_outbox (channel, to_address, to_name, body, customer_id, related_type, related_id, dedupe_key, created_by)
    values (v_channel, c.phone, c.name, app.render_template(p_body, v_vars), c.id, 'campaign', cp.id, 'campaign:' || cp.id || ':' || c.id, app.current_user_id())
    on conflict (dedupe_key) do nothing returning id into v_id;
    if v_id is null then v_skipped := v_skipped + 1; else n := n + 1; end if;
  end loop;
  update public.campaigns set status = case when status = 'planned' then 'active' else status end where id = cp.id;
  return jsonb_build_object('queued', n, 'skipped', v_skipped);
end $$;

-- ---------------------------------------------------------------------
-- Leads, activities, opportunities
-- p: name, company_name, contact_person, phone, email, address_line, city, gps_lat, gps_lng, customer_type, source, campaign_id,
--    territory_id, owner_id, status, est_monthly_bottles, est_monthly_value, next_follow_up, notes
-- ---------------------------------------------------------------------
create or replace function public.save_lead(p_id uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid; v_no text; v_phone text := app.normalize_phone(app.jtext(p, 'phone')); c public.customers; o public.leads; v_status text;
begin
  perform app.require_permission('crm.manage');
  if app.jtext(p, 'name') is null then raise exception 'Enter a name' using errcode = '22023'; end if;
  if app.jtext(p, 'phone') is not null and v_phone is null then raise exception 'The phone number is not valid' using errcode = '22023'; end if;
  if v_phone is not null then
    select * into c from public.customers where (phone = v_phone or phone2 = v_phone) and status <> 'inactive' limit 1;
    if found then raise exception '% is already a customer (%)', c.name, c.customer_no using errcode = '23505'; end if;
  end if;
  if p_id is not null then
    select * into o from public.leads where id = p_id for update;
    if not found then raise exception 'Lead not found' using errcode = 'P0002'; end if;
    if o.status = 'won' then raise exception 'This lead is already a customer' using errcode = '22023'; end if;
  end if;
  v_status := coalesce(app.jtext(p, 'status'), o.status, 'new');
  if v_status = 'won' then raise exception 'Use "Make customer" to win a lead' using errcode = '22023'; end if;
  if v_status = 'lost' and app.jtext(p, 'lost_reason') is null then raise exception 'Say why the lead was lost' using errcode = '22023'; end if;
  if p_id is null then
    v_no := app.next_document_number('LEAD');
    insert into public.leads (lead_no, name, company_name, contact_person, phone, email, address_line, city, gps_lat, gps_lng, customer_type, source,
      campaign_id, territory_id, owner_id, status, est_monthly_bottles, est_monthly_value, next_follow_up, notes, created_by)
    values (v_no, app.jtext(p, 'name'), app.jtext(p, 'company_name'), app.jtext(p, 'contact_person'), v_phone, lower(app.jtext(p, 'email')),
      app.jtext(p, 'address_line'), app.jtext(p, 'city'), app.jnum(p, 'gps_lat'), app.jnum(p, 'gps_lng'), app.jtext(p, 'customer_type'),
      coalesce(app.jtext(p, 'source'), 'phone'), app.juuid(p, 'campaign_id'), app.juuid(p, 'territory_id'),
      coalesce(app.juuid(p, 'owner_id'), app.current_user_id()), v_status, app.jint(p, 'est_monthly_bottles'), app.jnum(p, 'est_monthly_value'),
      (app.jtext(p, 'next_follow_up'))::date, app.jtext(p, 'notes'), app.current_user_id())
    returning id into v;
    if app.juuid(p, 'owner_id') is not null and app.juuid(p, 'owner_id') <> app.current_user_id() then
      perform app.notify('lead_assigned', 'New lead for you: ' || app.jtext(p, 'name'), app.jtext(p, 'notes'), '/crm/leads/' || v,
        'lead:' || v, app.juuid(p, 'owner_id'));
    end if;
  else
    update public.leads set name = app.jtext(p, 'name'), company_name = app.jtext(p, 'company_name'), contact_person = app.jtext(p, 'contact_person'),
      phone = v_phone, email = lower(app.jtext(p, 'email')), address_line = app.jtext(p, 'address_line'), city = app.jtext(p, 'city'),
      gps_lat = coalesce(app.jnum(p, 'gps_lat'), gps_lat), gps_lng = coalesce(app.jnum(p, 'gps_lng'), gps_lng),
      customer_type = app.jtext(p, 'customer_type'), source = coalesce(app.jtext(p, 'source'), source), campaign_id = app.juuid(p, 'campaign_id'),
      territory_id = app.juuid(p, 'territory_id'), owner_id = coalesce(app.juuid(p, 'owner_id'), owner_id), status = v_status,
      est_monthly_bottles = app.jint(p, 'est_monthly_bottles'), est_monthly_value = app.jnum(p, 'est_monthly_value'),
      next_follow_up = (app.jtext(p, 'next_follow_up'))::date, lost_reason = case when v_status = 'lost' then app.jtext(p, 'lost_reason') end,
      notes = app.jtext(p, 'notes')
     where id = p_id;
    v := p_id;
    if o.owner_id is distinct from app.juuid(p, 'owner_id') and app.juuid(p, 'owner_id') is not null and app.juuid(p, 'owner_id') <> app.current_user_id() then
      perform app.notify('lead_assigned', 'Lead passed to you: ' || app.jtext(p, 'name'), null, '/crm/leads/' || v,
        'lead:' || v || ':' || app.juuid(p, 'owner_id'), app.juuid(p, 'owner_id'));
    end if;
  end if;
  return jsonb_build_object('lead_id', v, 'lead_no', coalesce(v_no, o.lead_no));
end $$;

-- Win a lead: create the customer (credit terms go through approval as usual) and keep the link for conversion reports.
-- p: customer payload for save_customer (name, phone, customer_type … address)
create or replace function public.convert_lead(p_lead uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare l public.leads; v_cust uuid; v_payload jsonb;
begin
  perform app.require_permission('crm.manage');
  perform app.require_permission('customers.manage');
  select * into l from public.leads where id = p_lead for update;
  if not found then raise exception 'Lead not found' using errcode = 'P0002'; end if;
  if l.status = 'won' then raise exception 'Already a customer' using errcode = '22023'; end if;
  v_payload := jsonb_strip_nulls(jsonb_build_object('name', l.name, 'company_name', l.company_name, 'contact_person', l.contact_person,
                 'phone', l.phone, 'email', l.email, 'customer_type', l.customer_type, 'notes', l.notes,
                 'address', case when l.address_line is not null then jsonb_build_object('address_line', l.address_line, 'city', l.city,
                                  'gps_lat', l.gps_lat, 'gps_lng', l.gps_lng) end)) || coalesce(jsonb_strip_nulls(p), '{}');
  v_cust := public.save_customer(null, v_payload, 'Converted from lead ' || l.lead_no);
  update public.customers set lead_id = l.id, campaign_id = l.campaign_id,
         sales_rep_id = coalesce(sales_rep_id, (select profile_id from public.sales_reps where profile_id = l.owner_id)) where id = v_cust;
  update public.leads set status = 'won', customer_id = v_cust, converted_at = now(), next_follow_up = null where id = l.id;
  update public.opportunities set customer_id = v_cust where lead_id = l.id;
  update public.crm_activities set customer_id = v_cust where lead_id = l.id;
  return jsonb_build_object('customer_id', v_cust);
end $$;

-- p: lead_id | customer_id | opportunity_id, kind, subject, notes, due_on, done (boolean), outcome, owner_id
create or replace function public.log_crm_activity(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  if not (app.has_permission('crm.manage') or app.has_permission('customers.manage')) then raise exception 'Permission denied' using errcode = '42501'; end if;
  if app.jtext(p, 'subject') is null then raise exception 'Write what it is about' using errcode = '22023'; end if;
  insert into public.crm_activities (lead_id, customer_id, opportunity_id, kind, subject, notes, due_on, done_at, outcome, owner_id, created_by)
  values (app.juuid(p, 'lead_id'), app.juuid(p, 'customer_id'), app.juuid(p, 'opportunity_id'), coalesce(app.jtext(p, 'kind'), 'note'),
    app.jtext(p, 'subject'), app.jtext(p, 'notes'), (app.jtext(p, 'due_on'))::date,
    case when app.jbool(p, 'done', true) then now() end, app.jtext(p, 'outcome'),
    coalesce(app.juuid(p, 'owner_id'), app.current_user_id()), app.current_user_id())
  returning id into v;
  if app.juuid(p, 'lead_id') is not null then
    update public.leads set status = case when status = 'new' and app.jbool(p, 'done', true) then 'contacted' else status end,
           next_follow_up = case when not app.jbool(p, 'done', true) and app.jtext(p, 'due_on') is not null
                                 then least(coalesce(next_follow_up, (app.jtext(p, 'due_on'))::date), (app.jtext(p, 'due_on'))::date) else next_follow_up end
     where id = app.juuid(p, 'lead_id');
  end if;
  return v;
end $$;

create or replace function public.complete_crm_activity(p_id uuid, p_outcome text)
returns void language plpgsql security definer set search_path = '' as $$
declare a public.crm_activities;
begin
  if not (app.has_permission('crm.manage') or app.has_permission('customers.manage')) then raise exception 'Permission denied' using errcode = '42501'; end if;
  select * into a from public.crm_activities where id = p_id for update;
  if not found then raise exception 'Not found' using errcode = 'P0002'; end if;
  if a.done_at is not null then raise exception 'Already done' using errcode = '22023'; end if;
  update public.crm_activities set done_at = now(), outcome = nullif(trim(p_outcome), '') where id = p_id;
  if a.lead_id is not null then
    update public.leads set status = case when status = 'new' then 'contacted' else status end,
      next_follow_up = (select min(due_on) from public.crm_activities where lead_id = a.lead_id and done_at is null)
     where id = a.lead_id;
  end if;
end $$;

-- p: title, lead_id, customer_id, owner_id, stage, monthly_value, probability, expected_close, lost_reason, notes
create or replace function public.save_opportunity(p_id uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; o public.opportunities; v_stage text;
begin
  perform app.require_permission('crm.manage');
  if app.jtext(p, 'title') is null then raise exception 'Give the opportunity a title' using errcode = '22023'; end if;
  v_stage := coalesce(app.jtext(p, 'stage'), 'prospecting');
  if v_stage = 'lost' and app.jtext(p, 'lost_reason') is null then raise exception 'Say why it was lost' using errcode = '22023'; end if;
  if p_id is null then
    insert into public.opportunities (opp_no, title, lead_id, customer_id, owner_id, stage, monthly_value, probability, expected_close, lost_reason,
      closed_at, notes, created_by)
    values (app.next_document_number('OPP'), app.jtext(p, 'title'), app.juuid(p, 'lead_id'), app.juuid(p, 'customer_id'),
      coalesce(app.juuid(p, 'owner_id'), app.current_user_id()), v_stage, coalesce(app.jnum(p, 'monthly_value'), 0),
      coalesce(app.jint(p, 'probability'), case v_stage when 'won' then 100 when 'lost' then 0 when 'negotiation' then 60 when 'proposal' then 40 else 20 end),
      (app.jtext(p, 'expected_close'))::date, app.jtext(p, 'lost_reason'), case when v_stage in ('won','lost') then now() end, app.jtext(p, 'notes'),
      app.current_user_id())
    returning id into v;
  else
    select * into o from public.opportunities where id = p_id for update;
    if not found then raise exception 'Opportunity not found' using errcode = 'P0002'; end if;
    update public.opportunities set title = app.jtext(p, 'title'), owner_id = coalesce(app.juuid(p, 'owner_id'), owner_id), stage = v_stage,
      monthly_value = coalesce(app.jnum(p, 'monthly_value'), monthly_value),
      probability = coalesce(app.jint(p, 'probability'), case v_stage when 'won' then 100 when 'lost' then 0 else probability end),
      expected_close = (app.jtext(p, 'expected_close'))::date, lost_reason = case when v_stage = 'lost' then app.jtext(p, 'lost_reason') end,
      closed_at = case when v_stage in ('won','lost') then coalesce(closed_at, now()) end, notes = app.jtext(p, 'notes')
     where id = p_id returning id into v;
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.customer_segments enable row level security;
alter table public.promotions        enable row level security;
alter table public.campaigns         enable row level security;
alter table public.leads             enable row level security;
alter table public.opportunities     enable row level security;
alter table public.crm_activities    enable row level security;
create policy customer_segments_read on public.customer_segments for select to authenticated using (app.has_permission('crm.manage'));
create policy promotions_read on public.promotions for select to authenticated
  using (app.has_permission('crm.manage') or app.has_permission('orders.view') or app.has_permission('prices.approve') or app.has_permission('products.view'));
create policy campaigns_read on public.campaigns for select to authenticated using (app.has_permission('crm.manage') or app.has_permission('customers.view'));
create policy leads_read on public.leads for select to authenticated
  using (app.has_permission('crm.manage') or app.has_permission('sales_reps.manage') or owner_id = app.current_user_id());
create policy opportunities_read on public.opportunities for select to authenticated
  using (app.has_permission('crm.manage') or app.has_permission('sales_reps.manage') or owner_id = app.current_user_id());
create policy crm_activities_read on public.crm_activities for select to authenticated
  using (app.has_permission('crm.manage') or app.has_permission('sales_reps.manage') or owner_id = app.current_user_id()
         or (customer_id is not null and app.has_permission('customers.view')));

-- ---------------------------------------------------------------------
-- Orders: promotions applied automatically (replacement; [3B] marks the change)
-- ---------------------------------------------------------------------
create or replace function public.save_order(p_id uuid, p jsonb, p_confirm boolean, p_client_txn_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_done jsonb; v uuid; c public.customers; o public.orders; it jsonb; n integer := 0; v_price numeric;
  v_disc_limit numeric; v_line_gross numeric; v_res jsonb; v_addr uuid; v_include boolean;
  v_promo record; v_manual numeric;  -- [3B]
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
    -- [3B] the best active promotion is added on top of any manual discount (it needs no further approval)
    v_manual := least(coalesce(app.jnum(it, 'discount'), 0), v_line_gross);
    select * into v_promo from app.promotion_discount(app.juuid(it, 'product_id'), c.id, app.jnum(it, 'qty'), v_price,
                                                       coalesce((app.jtext(p, 'requested_date'))::date, app.today()));
    v_promo.amount := least(coalesce(v_promo.amount, 0), greatest(v_line_gross - v_manual, 0));
    insert into public.order_items (order_id, line_no, product_id, qty, unit_price, discount, line_net, line_tax, line_total, promotion_id, promo_discount)
    values (v, n, app.juuid(it, 'product_id'), app.jnum(it, 'qty'), v_price, v_manual + v_promo.amount, 0, 0, 0,
            case when v_promo.amount > 0 then v_promo.promotion_id end, v_promo.amount);
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
