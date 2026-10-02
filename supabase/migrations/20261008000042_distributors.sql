-- =====================================================================
-- OLA Water ERP — Phase 3B
-- 0042: distributors / dealers — profile on top of their customer
--       account (price list, credit, orders, invoices, payments and
--       bottles stay on the customer), territory, agreement, monthly
--       targets, and stock they report holding
-- =====================================================================

create table public.distributors (
  id               uuid primary key default gen_random_uuid(),
  customer_id      uuid not null unique references public.customers(id),
  code             text not null unique check (code ~ '^[A-Z0-9_-]{2,12}$'),
  kind             text not null default 'distributor' check (kind in ('distributor','dealer','wholesaler')),
  territory_id     uuid references public.territories(id),
  manager_id       uuid references public.profiles(id),        -- staff member who looks after them
  agreement_start  date,
  agreement_end    date,
  monthly_target   numeric(14,2) not null default 0 check (monthly_target >= 0),
  min_stock_19l    integer,                                    -- agreed minimum 19L stock to hold
  exclusive        boolean not null default false,
  status           text not null default 'active' check (status in ('active','suspended','ended')),
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (agreement_end is null or agreement_start is null or agreement_end >= agreement_start)
);
create trigger distributors_touch before update on public.distributors for each row execute function app.touch_updated_at();
create trigger distributors_audit after insert or update on public.distributors for each row execute function app.audit_row('distributors');

create table public.distributor_stock_reports (
  id              uuid primary key default gen_random_uuid(),
  distributor_id  uuid not null references public.distributors(id),
  report_date     date not null,
  lines           jsonb not null,        -- [{product_id, qty}]
  empty_bottles   integer,
  notes           text,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  unique (distributor_id, report_date)
);
create trigger distributor_stock_reports_append_only before update or delete on public.distributor_stock_reports for each row execute function app.forbid_change();
create trigger distributor_stock_reports_audit after insert on public.distributor_stock_reports for each row execute function app.audit_row('distributors');

-- p: customer_id, code, kind, territory_id, manager_id, agreement_start, agreement_end, monthly_target, min_stock_19l, exclusive, status, notes
create or replace function public.save_distributor(p_id uuid, p jsonb, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; c public.customers;
begin
  perform app.require_permission('distributors.manage');
  if app.jtext(p, 'code') is null then raise exception 'Enter a distributor code' using errcode = '22023'; end if;
  perform app.set_context(nullif(trim(p_reason), ''), null, null);
  if p_id is null then
    select * into c from public.customers where id = app.juuid(p, 'customer_id');
    if not found then raise exception 'Choose the customer account the distributor buys on (create it under Customers first)' using errcode = '22023'; end if;
    insert into public.distributors (customer_id, code, kind, territory_id, manager_id, agreement_start, agreement_end, monthly_target,
      min_stock_19l, exclusive, notes)
    values (c.id, upper(app.jtext(p, 'code')), coalesce(app.jtext(p, 'kind'), 'distributor'), app.juuid(p, 'territory_id'), app.juuid(p, 'manager_id'),
      (app.jtext(p, 'agreement_start'))::date, (app.jtext(p, 'agreement_end'))::date, coalesce(app.jnum(p, 'monthly_target'), 0),
      app.jint(p, 'min_stock_19l'), app.jbool(p, 'exclusive', false), app.jtext(p, 'notes'))
    returning id into v;
  else
    update public.distributors set code = upper(app.jtext(p, 'code')), kind = coalesce(app.jtext(p, 'kind'), kind),
      territory_id = app.juuid(p, 'territory_id'), manager_id = app.juuid(p, 'manager_id'),
      agreement_start = (app.jtext(p, 'agreement_start'))::date, agreement_end = (app.jtext(p, 'agreement_end'))::date,
      monthly_target = coalesce(app.jnum(p, 'monthly_target'), 0), min_stock_19l = app.jint(p, 'min_stock_19l'),
      exclusive = app.jbool(p, 'exclusive', false), status = coalesce(app.jtext(p, 'status'), status), notes = app.jtext(p, 'notes')
     where id = p_id returning id into v;
    if v is null then raise exception 'Distributor not found' using errcode = 'P0002'; end if;
  end if;
  return v;
end $$;

create or replace function public.record_distributor_stock(p_distributor uuid, p_date date, p_lines jsonb, p_empty integer, p_notes text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; x jsonb; v_clean jsonb := '[]';
begin
  perform app.require_permission('distributors.manage');
  if coalesce(p_date, app.today()) > app.today() then raise exception 'The count cannot be in the future' using errcode = '22023'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    continue when app.juuid(x, 'product_id') is null or app.jnum(x, 'qty') is null;
    if app.jnum(x, 'qty') < 0 then raise exception 'Quantities cannot be negative' using errcode = '22023'; end if;
    v_clean := v_clean || jsonb_build_object('product_id', app.juuid(x, 'product_id'), 'qty', app.jnum(x, 'qty'));
  end loop;
  if jsonb_array_length(v_clean) = 0 and p_empty is null then raise exception 'Enter at least one count' using errcode = '22023'; end if;
  insert into public.distributor_stock_reports (distributor_id, report_date, lines, empty_bottles, notes, created_by)
  values (p_distributor, coalesce(p_date, app.today()), v_clean, p_empty, nullif(trim(p_notes), ''), app.current_user_id())
  returning id into v;
  return v;
end $$;

alter table public.distributors              enable row level security;
alter table public.distributor_stock_reports enable row level security;
create policy distributors_read on public.distributors for select to authenticated
  using (app.has_permission('distributors.manage') or app.has_permission('customers.view'));
create policy distributor_stock_reports_read on public.distributor_stock_reports for select to authenticated
  using (app.has_permission('distributors.manage'));
