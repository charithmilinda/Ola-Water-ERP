-- =====================================================================
-- OLA Water ERP — Phase 2B
-- 0029: document numbers, settings, roles, financial reports, grants
-- =====================================================================

insert into public.document_types (code, name, padding) values
  ('MJ',  'Manual journal', 6),
  ('FT',  'Funds transfer', 6),
  ('VAT', 'VAT return', 4),
  ('EXP', 'Expense', 6)
on conflict (code) do nothing;

insert into public.setting_definitions (key, module, label, description, value_type, choices, min_value, max_value, sort_order) values
  ('accounting.fiscal_year_start_month', 'Accounting', 'Financial year starts in month',
   '4 = April (Sri Lankan tax year). Used by the balance sheet for "profit this year".', 'integer', null, 1, 12, 80);
insert into public.system_settings (key, value, effective_from) values ('accounting.fiscal_year_start_month', '4', date '2026-01-01');

select public.ensure_accounting_year(2028);

insert into public.role_permissions (role_id, permission_code)
select r.id, x.code
  from public.roles r
  join (values
    ('accountant',          array['reports.export','expenses.view','procurement.view']),
    ('operations_manager',  array['expenses.view','expenses.manage']),
    ('director',            array['reports.view'])
  ) as m(role_code, perms) on m.role_code = r.code
  cross join lateral unnest(m.perms) as x(code)
 where not exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_code = x.code);

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create or replace function app.require_accounting_view()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.has_permission('accounting.view') then
    raise exception 'Permission denied: accounting.view is required' using errcode = '42501';
  end if;
end $$;

create or replace function app.party_name(p_type text, p_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case p_type
    when 'customer' then (select name from public.customers where id = p_id)
    when 'supplier' then (select name from public.suppliers where id = p_id)
    when 'water_shop' then (select name from public.water_shops where id = p_id)
    when 'driver' then (select full_name from public.profiles where id = p_id)
    when 'employee' then (select full_name from public.profiles where id = p_id)
    when 'external_company' then (select name from public.bottle_companies where id = p_id)
  end
$$;

create or replace function app.fiscal_year_start(p_date date)
returns date language sql stable security definer set search_path = '' as $$
  select case when extract(month from p_date)::int >= m then make_date(extract(year from p_date)::int, m, 1)
              else make_date(extract(year from p_date)::int - 1, m, 1) end
    from (select coalesce((app.get_setting('accounting.fiscal_year_start_month') #>> '{}')::int, 4) as m) s
$$;

-- Accounts that count as cash for the cash-flow report
create or replace function app.is_cash_account(p_account uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.money_accounts where account_id = p_account)
      or exists (select 1 from public.accounts where id = p_account and system_key in ('driver_cash','shop_cash','cheques_in_hand'))
$$;

-- ---------------------------------------------------------------------
-- Trial balance with opening and closing balances
-- ---------------------------------------------------------------------
create or replace function public.report_trial_balance(p_from date, p_to date)
returns table (account_id uuid, code text, name text, account_type text, opening numeric, debit numeric, credit numeric, closing numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_accounting_view();
  return query
  select a.id, a.code, a.name, a.account_type,
         coalesce(sum(l.debit - l.credit) filter (where e.entry_date < p_from), 0),
         coalesce(sum(l.debit) filter (where e.entry_date between p_from and p_to), 0),
         coalesce(sum(l.credit) filter (where e.entry_date between p_from and p_to), 0),
         coalesce(sum(l.debit - l.credit) filter (where e.entry_date <= p_to), 0)
    from public.accounts a
    join public.journal_lines l on l.account_id = a.id
    join public.journal_entries e on e.id = l.entry_id
   where e.entry_date <= p_to
   group by a.id
   order by a.code;
end $$;

-- ---------------------------------------------------------------------
-- Profit and loss (with the previous period of the same length)
-- ---------------------------------------------------------------------
create or replace function public.report_profit_loss(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_len integer := p_to - p_from + 1; v_pfrom date := p_from - (p_to - p_from + 1); v_pto date := p_from - 1; v jsonb;
begin
  perform app.require_accounting_view();
  with amounts as (
    select a.id, a.code, a.name, a.account_type,
           case when a.account_type = 'income' then 'income' when a.code like '5%' then 'cost_of_sales' else 'expenses' end as section,
           coalesce(sum(case when a.account_type = 'income' then l.credit - l.debit else l.debit - l.credit end)
                    filter (where e.entry_date between p_from and p_to), 0) as amount,
           coalesce(sum(case when a.account_type = 'income' then l.credit - l.debit else l.debit - l.credit end)
                    filter (where e.entry_date between v_pfrom and v_pto), 0) as previous
      from public.accounts a
      join public.journal_lines l on l.account_id = a.id
      join public.journal_entries e on e.id = l.entry_id
     where a.account_type in ('income','expense') and e.entry_date between v_pfrom and p_to
     group by a.id
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'previous_from', v_pfrom, 'previous_to', v_pto, 'days', v_len,
    'sections', jsonb_build_object(
      'income', (select coalesce(jsonb_agg(jsonb_build_object('account_id', id, 'code', code, 'name', name, 'amount', amount, 'previous', previous) order by code), '[]')
                   from amounts where section = 'income' and (amount <> 0 or previous <> 0)),
      'cost_of_sales', (select coalesce(jsonb_agg(jsonb_build_object('account_id', id, 'code', code, 'name', name, 'amount', amount, 'previous', previous) order by code), '[]')
                   from amounts where section = 'cost_of_sales' and (amount <> 0 or previous <> 0)),
      'expenses', (select coalesce(jsonb_agg(jsonb_build_object('account_id', id, 'code', code, 'name', name, 'amount', amount, 'previous', previous) order by code), '[]')
                   from amounts where section = 'expenses' and (amount <> 0 or previous <> 0))),
    'totals', jsonb_build_object(
      'income', (select coalesce(sum(amount), 0) from amounts where section = 'income'),
      'cost_of_sales', (select coalesce(sum(amount), 0) from amounts where section = 'cost_of_sales'),
      'expenses', (select coalesce(sum(amount), 0) from amounts where section = 'expenses'),
      'gross_profit', (select coalesce(sum(case when section = 'income' then amount when section = 'cost_of_sales' then -amount else 0 end), 0) from amounts),
      'net_profit', (select coalesce(sum(case when section = 'income' then amount else -amount end), 0) from amounts),
      'previous_income', (select coalesce(sum(previous), 0) from amounts where section = 'income'),
      'previous_cost_of_sales', (select coalesce(sum(previous), 0) from amounts where section = 'cost_of_sales'),
      'previous_expenses', (select coalesce(sum(previous), 0) from amounts where section = 'expenses'),
      'previous_net_profit', (select coalesce(sum(case when section = 'income' then previous else -previous end), 0) from amounts))
  ) into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Balance sheet
-- ---------------------------------------------------------------------
create or replace function public.report_balance_sheet(p_as_at date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; v_fy date := app.fiscal_year_start(p_as_at);
begin
  perform app.require_accounting_view();
  with bal as (
    select a.id, a.code, a.name, a.account_type,
           coalesce(sum(l.debit - l.credit), 0) as dr_balance,
           coalesce(sum(l.debit - l.credit) filter (where e.entry_date >= v_fy), 0) as dr_this_year
      from public.accounts a
      join public.journal_lines l on l.account_id = a.id
      join public.journal_entries e on e.id = l.entry_id
     where e.entry_date <= p_as_at
     group by a.id
  ), pl as (
    select coalesce(sum(-(dr_balance - dr_this_year)), 0) as prior_years, coalesce(sum(-dr_this_year), 0) as this_year
      from bal where account_type in ('income','expense')
  )
  select jsonb_build_object(
    'as_at', p_as_at, 'year_start', v_fy,
    'assets', (select coalesce(jsonb_agg(jsonb_build_object('account_id', id, 'code', code, 'name', name, 'amount', dr_balance) order by code), '[]')
                 from bal where account_type = 'asset' and dr_balance <> 0),
    'liabilities', (select coalesce(jsonb_agg(jsonb_build_object('account_id', id, 'code', code, 'name', name, 'amount', -dr_balance) order by code), '[]')
                 from bal where account_type = 'liability' and dr_balance <> 0),
    'equity', (select coalesce(jsonb_agg(jsonb_build_object('account_id', id, 'code', code, 'name', name, 'amount', -dr_balance) order by code), '[]')
                 from bal where account_type = 'equity' and dr_balance <> 0),
    'profit_prior_years', (select prior_years from pl),
    'profit_this_year', (select this_year from pl),
    'totals', jsonb_build_object(
      'assets', (select coalesce(sum(dr_balance), 0) from bal where account_type = 'asset'),
      'liabilities', (select coalesce(sum(-dr_balance), 0) from bal where account_type = 'liability'),
      'equity', (select coalesce(sum(-dr_balance), 0) from bal where account_type = 'equity') + (select prior_years + this_year from pl))
  ) into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Cash flow (direct method): every entry that moves cash, grouped by
-- what the money was for
-- ---------------------------------------------------------------------
create or replace function public.report_cash_flow(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  perform app.require_accounting_view();
  with cashacc as (
    select id from public.accounts a where app.is_cash_account(a.id)
  ), moves as (
    select e.id, e.entry_date, e.event_type,
           sum(l.debit - l.credit) filter (where l.account_id in (select id from cashacc)) as delta
      from public.journal_entries e join public.journal_lines l on l.entry_id = e.id
     where e.entry_date between p_from and p_to
     group by e.id
    having coalesce(sum(l.debit - l.credit) filter (where l.account_id in (select id from cashacc)), 0) <> 0
  ), counter as (
    select distinct on (m.id) m.id, m.delta, m.event_type, a.system_key, a.account_type, a.code
      from moves m join public.journal_lines l on l.entry_id = m.id join public.accounts a on a.id = l.account_id
     where l.account_id not in (select id from cashacc)
     order by m.id, abs(l.debit - l.credit) desc
  ), classified as (
    select c.delta,
      case
        when c.system_key in ('ar','ar_shops','ar_distributors','customer_advances','bottle_deposits','sales','sales_shops','delivery_income')
          or c.event_type like 'payment.%' or c.event_type like 'refund.%' or c.event_type like 'cheque.%' then 'Customers (receipts less refunds)'
        when c.system_key in ('ap','grni') or c.event_type like 'supplier.%' then 'Suppliers'
        when c.system_key in ('salaries_payable','epf_payable','etf_payable','paye_payable') then 'Salaries and statutory payments'
        when c.system_key in ('vat_output','vat_input','sscl_payable') then 'Taxes'
        when c.system_key like 'fa_%' or c.system_key = 'accum_depreciation' then 'Fixed assets (investing)'
        when c.account_type = 'equity' then 'Owners and financing'
        when c.system_key = 'expenses_payable' or c.account_type = 'expense' then 'Expenses'
        when c.account_type = 'income' then 'Other income'
        else 'Other' end as category
      from counter c
  ), all_moves as (
    select category, delta from classified
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'opening', coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                          where e.entry_date < p_from and l.account_id in (select id from cashacc)), 0),
    'closing', coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                          where e.entry_date <= p_to and l.account_id in (select id from cashacc)), 0),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('category', category, 'cash_in', cash_in, 'cash_out', cash_out, 'net', cash_in - cash_out)
                order by cash_in - cash_out desc), '[]')
                from (select category, coalesce(sum(delta) filter (where delta > 0), 0) cash_in, coalesce(-sum(delta) filter (where delta < 0), 0) cash_out
                        from all_moves group by category) g),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name,
                   'opening', coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                                         where l.account_id = a.id and e.entry_date < p_from), 0),
                   'closing', coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                                         where l.account_id = a.id and e.entry_date <= p_to), 0)) order by a.code), '[]')
                 from public.accounts a where a.id in (select id from cashacc))
  ) into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- General ledger for one account
-- ---------------------------------------------------------------------
create or replace function public.report_general_ledger(p_account uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.accounts; v jsonb; v_open numeric;
begin
  perform app.require_accounting_view();
  select * into a from public.accounts where id = p_account;
  if not found then raise exception 'Account not found' using errcode = 'P0002'; end if;
  select coalesce(sum(l.debit - l.credit), 0) into v_open from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
   where l.account_id = a.id and e.entry_date < p_from;
  select jsonb_build_object(
    'account', jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'account_type', a.account_type),
    'from', p_from, 'to', p_to, 'opening', v_open,
    'lines', (select coalesce(jsonb_agg(x order by (x ->> 'n')::bigint), '[]') from (
        select jsonb_build_object('n', row_number() over w, 'entry_id', e.id, 'entry_no', e.entry_no, 'date', e.entry_date, 'description', e.description,
                 'memo', l.memo, 'party', app.party_name(l.party_type, l.party_id), 'event_type', e.event_type,
                 'source_type', e.source_type, 'source_id', e.source_id, 'debit', l.debit, 'credit', l.credit,
                 'balance', v_open + sum(l.debit - l.credit) over w) as x
          from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
         where l.account_id = a.id and e.entry_date between p_from and p_to
        window w as (order by e.entry_date, e.created_at, l.id rows between unbounded preceding and current row)
        limit 3000) q),
    'debit', coalesce((select sum(l.debit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                        where l.account_id = a.id and e.entry_date between p_from and p_to), 0),
    'credit', coalesce((select sum(l.credit) from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
                        where l.account_id = a.id and e.entry_date between p_from and p_to), 0)
  ) into v;
  return v || jsonb_build_object('closing', v_open + (v ->> 'debit')::numeric - (v ->> 'credit')::numeric);
end $$;

create or replace function public.journal_entry_details(p_entry uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare e public.journal_entries; v jsonb;
begin
  perform app.require_accounting_view();
  select * into e from public.journal_entries where id = p_entry;
  if not found then raise exception 'Entry not found' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'entry', to_jsonb(e) || jsonb_build_object('created_by_name', (select full_name from public.profiles where id = e.created_by),
               'period', (select name || case when status = 'closed' then ' (closed)' else '' end from public.accounting_periods where id = e.period_id),
               'location', (select name from public.locations where id = e.location_id)),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('line_no', l.line_no, 'account_id', a.id, 'code', a.code, 'name', a.name,
                'debit', l.debit, 'credit', l.credit, 'memo', l.memo, 'party', app.party_name(l.party_type, l.party_id)) order by l.line_no), '[]')
                from public.journal_lines l join public.accounts a on a.id = l.account_id where l.entry_id = e.id),
    'reverses', (select jsonb_build_object('id', id, 'entry_no', entry_no) from public.journal_entries where id = e.reverses_entry_id),
    'reversed_by', (select jsonb_build_object('id', id, 'entry_no', entry_no, 'entry_date', entry_date) from public.journal_entries where reverses_entry_id = e.id),
    'reason', (select reason from public.audit_logs where record_type = 'journal_entries' and record_id = e.id::text order by occurred_at limit 1)
  ) into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Ageing
-- ---------------------------------------------------------------------
create or replace function public.report_ar_ageing(p_as_at date default null)
returns table (customer_id uuid, customer_no text, name text, phone text, customer_type text, not_due numeric, d1_30 numeric, d31_60 numeric,
               d61_90 numeric, d90_plus numeric, total_due numeric, unapplied numeric, net numeric, credit_limit numeric)
language plpgsql stable security definer set search_path = '' as $$
declare d date := coalesce(p_as_at, app.today());
begin
  if not (app.has_permission('accounting.view') or app.has_permission('payments.view')) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  return query
  with inv as (
    select i.customer_id, i.balance, d - i.due_date as late from public.invoices i
     where i.status in ('open','partially_paid') and i.balance > 0 and i.invoice_date <= d
  ), un as (
    select p.customer_id, sum(p.unallocated) amt from public.payments p where p.status = 'received' and p.direction = 'in' and p.unallocated > 0 group by 1
    union all
    select cn.customer_id, sum(cn.unallocated) from public.credit_notes cn where cn.unallocated > 0 group by 1
  )
  select c.id, c.customer_no, c.name, c.phone, c.customer_type,
         coalesce(sum(inv.balance) filter (where inv.late <= 0), 0),
         coalesce(sum(inv.balance) filter (where inv.late between 1 and 30), 0),
         coalesce(sum(inv.balance) filter (where inv.late between 31 and 60), 0),
         coalesce(sum(inv.balance) filter (where inv.late between 61 and 90), 0),
         coalesce(sum(inv.balance) filter (where inv.late > 90), 0),
         coalesce(sum(inv.balance), 0),
         coalesce((select sum(amt) from un where un.customer_id = c.id), 0),
         coalesce(sum(inv.balance), 0) - coalesce((select sum(amt) from un where un.customer_id = c.id), 0),
         c.credit_limit
    from public.customers c
    left join inv on inv.customer_id = c.id
   group by c.id
  having coalesce(sum(inv.balance), 0) <> 0 or coalesce((select sum(amt) from un where un.customer_id = c.id), 0) <> 0
   order by coalesce(sum(inv.balance) filter (where inv.late > 90), 0) desc, coalesce(sum(inv.balance), 0) desc;
end $$;

create or replace function public.report_ap_ageing(p_as_at date default null)
returns table (party text, supplier_id uuid, not_due numeric, d1_30 numeric, d31_60 numeric, d61_90 numeric, d90_plus numeric, total_due numeric,
               advances numeric)
language plpgsql stable security definer set search_path = '' as $$
declare d date := coalesce(p_as_at, app.today());
begin
  if not (app.has_permission('accounting.view') or app.has_permission('payments.view')) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  return query
  with bills as (
    select s.name as party, s.id as supplier_id, i.total - i.amount_paid as bal, d - i.due_date as late
      from public.supplier_invoices i join public.suppliers s on s.id = i.supplier_id
     where i.status in ('approved','partially_paid') and i.invoice_date <= d
    union all
    select coalesce(s.name, x.payee, 'Other bills'), s.id, x.total, d - x.expense_date
      from public.expenses x left join public.suppliers s on s.id = x.supplier_id
     where x.status = 'approved' and x.pay_method = 'on_credit' and x.expense_date <= d
  )
  select b.party, b.supplier_id,
         coalesce(sum(bal) filter (where late <= 0), 0), coalesce(sum(bal) filter (where late between 1 and 30), 0),
         coalesce(sum(bal) filter (where late between 31 and 60), 0), coalesce(sum(bal) filter (where late between 61 and 90), 0),
         coalesce(sum(bal) filter (where late > 90), 0), coalesce(sum(bal), 0),
         coalesce((select sum(unallocated) from public.supplier_payments sp where sp.supplier_id = b.supplier_id), 0)
    from bills b
   group by b.party, b.supplier_id
   order by coalesce(sum(bal), 0) desc;
end $$;

-- ---------------------------------------------------------------------
-- VAT report for a period
-- ---------------------------------------------------------------------
create or replace function public.report_vat(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare t record; v jsonb;
begin
  perform app.require_accounting_view();
  select * into t from app.vat_totals(p_from, p_to);
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'output_vat', t.output_vat, 'input_vat', t.input_vat, 'net', t.output_vat - t.input_vat,
    'vat_no', app.get_setting('company.vat_registration_no') #>> '{}',
    'sales_by_rate', (select coalesce(jsonb_agg(jsonb_build_object('rate', rate, 'net', net, 'vat', vat) order by rate desc), '[]') from (
        select il.tax_rate rate, sum(il.net) net, sum(il.tax) vat from public.invoice_lines il join public.invoices i on i.id = il.invoice_id
         where i.status <> 'void' and i.invoice_date between p_from and p_to and il.line_type in ('product','delivery_charge','bottle_charge')
           and exists (select 1 from public.journal_entries je where je.id = i.journal_entry_id)
         group by il.tax_rate) s),
    'credit_notes', jsonb_build_object('net', coalesce((select sum(net) from public.credit_notes where credit_date between p_from and p_to), 0),
                                       'vat', coalesce((select sum(tax) from public.credit_notes where credit_date between p_from and p_to), 0)),
    'purchases', jsonb_build_object('net', coalesce((select sum(subtotal) from public.supplier_invoices where status not in ('on_hold','void')
                                                       and invoice_date between p_from and p_to), 0),
                                    'vat', coalesce((select sum(tax_total) from public.supplier_invoices where status not in ('on_hold','void')
                                                       and invoice_date between p_from and p_to), 0)),
    'expenses', jsonb_build_object('net', coalesce((select sum(net_amount) from public.expenses where status in ('approved','paid')
                                                      and expense_date between p_from and p_to), 0),
                                   'vat', coalesce((select sum(vat_amount) from public.expenses where status in ('approved','paid')
                                                      and expense_date between p_from and p_to), 0)),
    'balances', jsonb_build_object(
        'vat_output', coalesce((select sum(l.credit - l.debit) from public.journal_lines l join public.accounts a on a.id = l.account_id
                                 join public.journal_entries e on e.id = l.entry_id where a.system_key = 'vat_output' and e.entry_date <= p_to), 0),
        'vat_input', coalesce((select sum(l.debit - l.credit) from public.journal_lines l join public.accounts a on a.id = l.account_id
                                join public.journal_entries e on e.id = l.entry_id where a.system_key = 'vat_input' and e.entry_date <= p_to), 0)),
    'returns', (select coalesce(jsonb_agg(jsonb_build_object('return_no', return_no, 'period_from', period_from, 'period_to', period_to,
                  'output_vat', output_vat, 'input_vat', input_vat, 'net_payable', net_payable, 'reference', reference, 'created_at', created_at)
                  order by period_from desc), '[]') from public.vat_returns),
    'last_return_to', (select max(period_to) from public.vat_returns)
  ) into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Accounting overview
-- ---------------------------------------------------------------------
create or replace function public.accounting_overview()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; v_today date := app.today(); v_month date := date_trunc('month', app.today())::date;
begin
  if not (app.has_permission('accounting.view') or app.has_permission('payments.manage')) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'money', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'kind', m.kind, 'bank_name', m.bank_name, 'account_no', m.account_no,
                'is_default', m.is_default, 'is_active', m.is_active, 'code', a.code,
                'balance', coalesce((select sum(debit - credit) from public.journal_lines where account_id = m.account_id), 0),
                'last_reconciled', (select max(statement_date) from public.bank_reconciliations r where r.money_account_id = m.id))
                order by m.kind, m.name), '[]')
                from public.money_accounts m join public.accounts a on a.id = m.account_id),
    'other_cash', (select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name,
                     'balance', coalesce((select sum(debit - credit) from public.journal_lines where account_id = a.id), 0)) order by a.code), '[]')
                     from public.accounts a where a.system_key in ('driver_cash','shop_cash','cheques_in_hand')),
    'receivable', coalesce((select sum(balance) from public.invoices where status in ('open','partially_paid')), 0),
    'receivable_overdue', coalesce((select sum(balance) from public.invoices where status in ('open','partially_paid') and due_date < v_today), 0),
    'payable', coalesce((select sum(total - amount_paid) from public.supplier_invoices where status in ('approved','partially_paid')), 0)
             + coalesce((select sum(total) from public.expenses where status = 'approved' and pay_method = 'on_credit'), 0),
    'vat_balance', coalesce((select sum(l.credit - l.debit) from public.journal_lines l join public.accounts a on a.id = l.account_id
                              where a.system_key in ('vat_output','vat_input')), 0),
    'deposits_held', coalesce((select sum(l.credit - l.debit) from public.journal_lines l join public.accounts a on a.id = l.account_id
                                where a.system_key = 'bottle_deposits'), 0),
    'cheques_in_hand', jsonb_build_object('count', (select count(*) from public.payments where cheque_status = 'in_hand' and status = 'received'),
                                          'amount', coalesce((select sum(amount) from public.payments where cheque_status = 'in_hand' and status = 'received'), 0)),
    'cheques_deposited', (select count(*) from public.payments where cheque_status = 'deposited'),
    'journals_waiting', (select count(*) from public.journal_drafts where status = 'pending'),
    'expenses_waiting', (select count(*) from public.expenses where status = 'pending_approval'),
    'bills_to_pay', (select count(*) from public.expenses where status = 'approved' and pay_method = 'on_credit'),
    'month', (select jsonb_build_object(
        'income', coalesce(sum(case when a.account_type = 'income' then l.credit - l.debit end), 0),
        'expense', coalesce(sum(case when a.account_type = 'expense' then l.debit - l.credit end), 0))
        from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.id = l.account_id
       where e.entry_date between v_month and v_today and a.account_type in ('income','expense')),
    'periods', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'starts_on', starts_on, 'ends_on', ends_on, 'status', status,
                  'closed_at', closed_at) order by starts_on), '[]')
                  from public.accounting_periods where starts_on <= v_today + 62 and ends_on >= v_today - 400)
  ) into v;
  return v;
end $$;

-- Cheques received, for the cheque register
create or replace function public.cheque_register(p_status text default null)
returns table (id uuid, payment_no text, customer_id uuid, customer text, amount numeric, reference text, cheque_bank text, cheque_date date,
               received_at timestamptz, cheque_status text, deposited_at timestamptz, deposited_to text, cleared_at timestamptz,
               returned_at timestamptz, reversal_reason text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.payment_no, p.customer_id, c.name, p.amount, p.reference, p.cheque_bank, p.cheque_date, p.received_at, p.cheque_status,
         p.deposited_at, m.name, p.cleared_at, p.returned_at, p.reversal_reason
    from public.payments p join public.customers c on c.id = p.customer_id left join public.money_accounts m on m.id = p.deposited_to
   where p.method = 'cheque' and (app.has_permission('payments.view') or app.has_permission('accounting.view'))
     and (p_status is null or p.cheque_status = p_status)
   order by case p.cheque_status when 'in_hand' then 0 when 'deposited' then 1 when 'returned' then 2 else 3 end, p.received_at desc
   limit 300
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

grant select on all tables in schema public to authenticated, service_role;
revoke all on all tables in schema public from anon;
