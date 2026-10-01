-- =====================================================================
-- Phase 0 database tests. Run with scripts/db-test.sh
-- Every check prints "ok - ..." or aborts the run.
-- =====================================================================
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = notice;

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

create function tests.ok(p_cond boolean, p_name text) returns void language plpgsql as $$
begin
  if p_cond is distinct from true then
    raise exception 'FAIL - %', p_name;
  end if;
  raise notice 'ok - %', p_name;
end $$;

create function tests.throws(p_sql text, p_fragment text, p_name text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(lower(p_fragment) in lower(sqlerrm)) = 0 then
      raise exception 'FAIL - % (wrong error: %)', p_name, sqlerrm;
    end if;
    raise notice 'ok - %', p_name;
    return;
  end;
  raise exception 'FAIL - % (no error raised)', p_name;
end $$;
grant execute on all functions in schema tests to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- Users: admin, clerk (no permissions), accountant
-- ---------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@ola.test',  '{"full_name":"Nimal Perera"}'),
  ('00000000-0000-0000-0000-00000000000b', 'clerk@ola.test',  '{"full_name":"Kasun Silva"}'),
  ('00000000-0000-0000-0000-00000000000c', 'acct@ola.test',   '{"full_name":"Dilani Fernando"}');

select tests.ok((select count(*) = 3 from public.profiles), 'profiles are created for new auth users');
select tests.ok((select full_name = 'Nimal Perera' from public.profiles where email = 'admin@ola.test'), 'profile takes full_name from metadata');
select tests.ok((select count(*) >= 60 from public.permissions), 'permissions are seeded');
select tests.ok((select count(*) >= 16 from public.roles), 'default roles are seeded');

select public.bootstrap_super_admin('admin@ola.test');
select tests.ok(app.is_super_admin('00000000-0000-0000-0000-00000000000a'), 'bootstrap makes the first super admin');
select tests.throws($$select public.bootstrap_super_admin('clerk@ola.test')$$, 'already exists', 'bootstrap cannot run twice');

-- ---------------------------------------------------------------------
-- Function privileges
-- ---------------------------------------------------------------------
set role anon;
select tests.ok(not has_function_privilege('public.generate_label_batch(text,integer,text,text,text,uuid)', 'execute'), 'anon cannot execute RPCs');
reset role;
set role authenticated;
select tests.ok(not has_function_privilege('public.bootstrap_super_admin(text)', 'execute'), 'authenticated cannot bootstrap a super admin');
select tests.ok(not has_function_privilege('public.log_failed_login(text,text,text,text)', 'execute'), 'authenticated cannot write failed-login rows');
select tests.ok(not has_function_privilege('app.write_audit(text,text,text,text,jsonb,jsonb,text)', 'execute'), 'authenticated cannot call internal audit writer');
reset role;

-- ---------------------------------------------------------------------
-- Admin assigns the accountant role (as the admin, through the RPC)
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.admin_assign_role('00000000-0000-0000-0000-00000000000c',
  (select id from public.roles where code = 'accountant'), null, 'New hire');
select tests.ok((select (public.get_my_access() ->> 'is_super_admin')::boolean), 'get_my_access reports super admin');
select tests.ok((select jsonb_array_length(public.get_my_access() -> 'permissions') = (select count(*) from public.permissions)),
                'super admin receives every permission');
select tests.throws($$select public.admin_assign_role('00000000-0000-0000-0000-00000000000c',
  (select id from public.roles where code = 'accountant'), null, 'again')$$, 'already has', 'duplicate role assignment is rejected');
select tests.throws($$select public.admin_set_user_active('00000000-0000-0000-0000-00000000000a', false, 'test')$$,
  'own account', 'admin cannot deactivate themselves');
select tests.throws($$select public.admin_revoke_role((select id from public.user_roles where user_id = '00000000-0000-0000-0000-00000000000a'), 'test')$$,
  'last active super admin', 'last super admin cannot be removed');
select public.admin_update_profile('00000000-0000-0000-0000-00000000000b', 'Kasun Silva', '+94771234567', 'EMP-0002',
  (select id from public.locations where code = 'WH1'), 'Added phone');
reset role;

select tests.ok((select 'phone' = any(changed_fields) and reason = 'Added phone' and user_name = 'Nimal Perera'
                   from public.audit_logs where record_type = 'profiles' and action = 'edit'
                  order by id desc limit 1),
                'profile edit is audited with changed fields, reason and user');
select tests.ok((select action = 'assign_role' from public.audit_logs where record_type = 'user_roles' order by id desc limit 1),
                'role assignment is audited as assign_role');

-- ---------------------------------------------------------------------
-- Permissions: clerk has none
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
set role authenticated;
select tests.ok((select jsonb_array_length(public.get_my_access() -> 'permissions') = 0), 'clerk has no permissions');
select tests.throws($$select public.generate_label_batch('OLA-BTL', 10, 'qrcode', '50x25', null, gen_random_uuid())$$,
  'permission denied', 'label generation needs labels.print');
select tests.throws($$select public.admin_list_users()$$, 'permission denied', 'user list needs users.manage');
select tests.ok((select count(*) = 0 from public.audit_logs), 'clerk cannot read the audit trail (RLS)');
select tests.ok((select count(*) = 1 from public.profiles), 'clerk sees only their own profile (RLS)');
select tests.throws($$insert into public.audit_logs (action, module) values ('fake', 'x')$$, 'permission denied',
  'clerk cannot insert audit rows directly');
update public.profiles set full_name = 'X' where id = '00000000-0000-0000-0000-00000000000b';
reset role;
select tests.ok((select full_name = 'Kasun Silva' from public.profiles where email = 'clerk@ola.test'), 'direct profile update had no effect');

-- ---------------------------------------------------------------------
-- Labels, numbering and idempotency (as admin)
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.generate_label_batch('OLA-BTL', 25, 'qrcode', '50x25', 'First roll', '11111111-1111-1111-1111-111111111111') as r1 \gset
select tests.ok((:'r1'::jsonb ->> 'first') = 'OLA-BTL-00000001' and (:'r1'::jsonb ->> 'last') = 'OLA-BTL-00000025',
                'label batch generates OLA-BTL-00000001..00000025');
select tests.ok((:'r1'::jsonb ->> 'batch_no') = 'LBL-HQ-' || extract(year from (now() at time zone 'Asia/Colombo'))::int || '-000001',
                'batch number follows LBL-HQ-YYYY-000001');
select public.generate_label_batch('OLA-BTL', 25, 'qrcode', '50x25', 'First roll', '11111111-1111-1111-1111-111111111111') as r2 \gset
select tests.ok((:'r2'::jsonb ->> 'batch_id') = (:'r1'::jsonb ->> 'batch_id') and (:'r2'::jsonb ->> 'duplicate')::boolean,
                'repeating a client_txn_id returns the original result');
select tests.ok((select count(*) = 25 from public.identifiers), 'duplicate request created no extra labels');
select tests.throws($$select public.post_manual_journal(current_date, 'x', '[]', 'x', '11111111-1111-1111-1111-111111111111')$$,
  'already used', 'a client_txn_id cannot be reused for another operation');
select public.generate_label_batch('EXT-AQUA', 5, 'datamatrix', '40x30', null, gen_random_uuid()) as r3 \gset
select tests.ok((:'r3'::jsonb ->> 'first') = 'EXT-AQUA-00000001', 'external tag series is independent');
select tests.ok((select identifier_type = 'qrcode' and status = 'unassigned' from public.lookup_identifier(' ola-btl-00000007 ')),
                'scan lookup is case and whitespace tolerant');
select tests.throws($$select public.generate_label_batch('OLA-BTL', 6000, 'qrcode', '50x25', null, gen_random_uuid())$$,
  'between 1 and 5000', 'batch size is limited');

select public.record_label_print((:'r1'::jsonb ->> 'batch_id')::uuid, null);
select tests.throws(format($$select public.record_label_print(%L, null)$$, :'r1'::jsonb ->> 'batch_id'),
  'reason is required', 'reprint requires a reason');
select public.record_label_print((:'r1'::jsonb ->> 'batch_id')::uuid, 'Printer jam');
reset role;
select tests.ok((select print_count = 2 and status = 'printed' from public.label_batches where id = (:'r1'::jsonb ->> 'batch_id')::uuid),
                'print count is tracked');
select tests.ok((select reason = 'Printer jam' from public.audit_logs where action = 'reprint' order by id desc limit 1),
                'reprint is audited with reason');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.cancel_label_batch((:'r3'::jsonb ->> 'batch_id')::uuid, 'Wrong label size');
reset role;
select tests.ok((select bool_and(status = 'void') from public.identifiers where label_batch_id = (:'r3'::jsonb ->> 'batch_id')::uuid),
                'cancelling a batch voids its labels');
select tests.throws($$delete from public.identifiers where value = 'OLA-BTL-00000001'$$, 'append-only', 'identifiers cannot be deleted');

-- Gapless numbering: a rolled-back transaction does not consume a number
begin;
select app.next_document_number('ORD', (select id from public.locations where code = 'WH1')) as n1 \gset
rollback;
select app.next_document_number('ORD', (select id from public.locations where code = 'WH1')) as n2 \gset
select tests.ok(:'n1' = :'n2' and :'n2' like 'ORD-WH1-%-000001', 'document numbers are gapless across rollbacks');

-- ---------------------------------------------------------------------
-- Accounting
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select app.post_event('sale.cash', '{"gross": 1180, "net": 1000, "vat": 180, "levy": 0}', date '2026-10-01',
                      'Test cash sale', 'test', null, null, null, null, gen_random_uuid()) as je \gset
select tests.ok((select count(*) = 3 from public.journal_lines where entry_id = :'je'), 'posting rules skip zero amounts');
select tests.ok((select sum(debit) = 1180 and sum(credit) = 1180 from public.journal_lines where entry_id = :'je'),
                'sale.cash posts a balanced entry');
select tests.ok((select action = 'post' and new_values ? 'lines' from public.audit_logs where record_id = :'je'),
                'journal posting is audited with its lines');
select tests.throws($$select app.post_event('sale.cash', '{"gross": 1180, "net": 1000, "vat": 100, "levy": 0}', date '2026-10-01', 'bad')$$,
  'not balanced', 'unbalanced event amounts are rejected');
select tests.throws($$select app.post_event('sale.cash', '{"gross": 1180, "net": 1180}', date '2026-10-01', 'missing')$$,
  'requires amount', 'missing amounts are rejected');
select tests.throws($$select app.post_event('no.such_event', '{}', date '2026-10-01', 'x')$$,
  'no posting rules', 'unknown events are rejected');
select tests.throws(format($$update public.journal_lines set debit = 1 where entry_id = %L$$, :'je'), 'append-only',
  'journal lines cannot be edited');
select tests.throws(format($$delete from public.journal_entries where id = %L$$, :'je'), 'append-only',
  'journal entries cannot be deleted');

-- Deferred balance check catches a direct unbalanced insert
select tests.throws($$
  do $x$ declare v uuid; begin
    insert into public.journal_entries (entry_no, entry_date, period_id, event_type, description, total)
    values ('JE-TEST-1', date '2026-10-01', (select id from public.accounting_periods where name = '2026-10'), 'x', 'x', 50)
    returning id into v;
    insert into public.journal_lines (entry_id, line_no, account_id, debit) values (v, 1, (select id from public.accounts where code = '1100'), 50);
    insert into public.journal_lines (entry_id, line_no, account_id, credit) values (v, 2, (select id from public.accounts where code = '4100'), 40);
    set constraints all immediate;
  end $x$ $$, 'not balanced', 'database rejects an unbalanced journal even without the posting function');

-- The accountant posts and reverses a manual journal
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
set role authenticated;
select public.post_manual_journal(date '2026-10-01', 'Opening cash',
  '[{"account_key":"cash","debit":50000},{"account_key":"opening_equity","credit":50000}]',
  'Opening balance', gen_random_uuid()) as mj \gset
select tests.ok((:'mj'::jsonb ->> 'entry_no') like 'JE-HQ-2026-%', 'manual journal gets a JE number');
select tests.throws($$select public.post_manual_journal(date '2026-10-01', 'x',
  '[{"account_key":"cash","debit":10},{"account_key":"sales","credit":10}]', '', gen_random_uuid())$$,
  'reason is required', 'manual journal needs a reason');
select tests.throws($$select public.post_manual_journal(date '2026-10-01', 'x',
  ('[{"account_key":"cash","debit":10},{"account_id":"' || (select id from public.accounts where code = '1000') || '","credit":10}]')::jsonb, 'r', gen_random_uuid())$$,
  'cannot be posted to', 'header accounts cannot be posted to');
select tests.throws($$select public.reverse_journal_entry((select id from public.journal_entries where description = 'Opening cash'), 'Typo', date '2026-10-02', gen_random_uuid())$$,
  'permission denied', 'accountant role cannot reverse without accounting.reverse');
reset role;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.reverse_journal_entry((:'mj'::jsonb ->> 'entry_id')::uuid, 'Entered twice', date '2026-10-02', gen_random_uuid());
select tests.throws(format($$select public.reverse_journal_entry(%L, 'again', date '2026-10-02', gen_random_uuid())$$, :'mj'::jsonb ->> 'entry_id'),
  'already been reversed', 'an entry can only be reversed once');
select tests.ok((select sum(balance) = 0 from public.trial_balance(date '2026-01-01', date '2026-12-31')), 'trial balance nets to zero');
select tests.ok((select balance = 1180 from public.trial_balance(date '2026-01-01', date '2026-12-31') where account_code = '1100'),
                'cash balance reflects sale and reversed opening journal');
select public.close_accounting_period((select id from public.accounting_periods where name = '2026-09'), 'September closed');
select tests.throws($$select public.post_manual_journal(date '2026-09-15', 'late',
  '[{"account_key":"cash","debit":10},{"account_key":"sales","credit":10}]', 'late entry', gen_random_uuid())$$,
  'is closed', 'posting into a closed period is rejected');
reset role;

-- ---------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.set_setting('approvals.discount_percent', '15', app.today() + 30, 'New discount policy');
select tests.ok((select current_value = '10'::jsonb and scheduled_value = '15'::jsonb
                   from public.list_settings() where key = 'approvals.discount_percent'),
                'future-dated setting is scheduled, current value unchanged');
select tests.throws($$select public.set_setting('approvals.discount_percent', '150', app.today() + 1, 'x')$$,
  'between 0 and 100', 'percent settings are validated');
select tests.throws($$select public.set_setting('bottles.external_tracking_mode', '"magic"', app.today() + 1, 'x')$$,
  'must be one of', 'choice settings are validated');
select tests.throws($$select public.set_setting('approvals.discount_percent', '12', app.today() - 1, 'x')$$,
  'today or later', 'settings cannot be back-dated');
reset role;
select tests.ok(app.get_setting('approvals.discount_percent', app.today() + 31) = '15'::jsonb, 'get_setting returns the value for a date');
select tests.throws($$update public.system_settings set value = '1' where key = 'approvals.discount_percent'$$, 'append-only',
  'setting history cannot be edited');

-- ---------------------------------------------------------------------
-- Audit immutability (even for the table owner)
-- ---------------------------------------------------------------------
select tests.throws($$update public.audit_logs set action = 'x'$$, 'append-only', 'audit rows cannot be updated');
select tests.throws($$delete from public.audit_logs$$, 'append-only', 'audit rows cannot be deleted');
select tests.throws($$truncate public.audit_logs$$, 'append-only', 'audit log cannot be truncated');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select tests.ok((select count(*) > 10 from public.audit_logs), 'admin can read the audit trail');
reset role;

-- Login/logout events
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
set role authenticated;
select public.log_auth_event('login');
reset role;
select tests.ok((select action = 'login' from public.audit_logs where record_type = 'profiles' order by id desc limit 1),
                'login is audited');
select set_config('request.jwt.claim.sub', '', false);
select public.log_failed_login('Someone@Example.com', '203.0.113.5', 'Chrome on Android', 'Invalid login credentials');
select tests.ok((select ip_address = '203.0.113.5' and new_values ->> 'email' = 'someone@example.com'
                   from public.audit_logs where action = 'failed_login'),
                'failed login is audited with IP');

-- Admin-only audit events
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select public.admin_log_user_created('00000000-0000-0000-0000-00000000000b', 'New user account');
select public.admin_log_password_reset('00000000-0000-0000-0000-00000000000b', 'Forgot password');
reset role;
select tests.ok((select count(*) = 2 from public.audit_logs where action in ('create_user','reset_password')
                   and record_id = '00000000-0000-0000-0000-00000000000b' and user_name = 'Nimal Perera'),
                'user creation and password resets are attributed to the admin');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
set role authenticated;
select tests.throws($$select public.admin_log_password_reset('00000000-0000-0000-0000-00000000000a', 'x')$$,
  'permission denied', 'non-admins cannot log password resets');
reset role;

do $$ begin raise notice 'ALL PHASE 0 DATABASE TESTS PASSED'; end $$;
