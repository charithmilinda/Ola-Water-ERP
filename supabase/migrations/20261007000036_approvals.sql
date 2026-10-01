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
