-- =====================================================================
-- OLA Water ERP — Phase 1A
-- 0008b: fix — the balanced-journal check must see every journal line,
-- whatever the poster's own read permissions (warehouse, drivers).
-- =====================================================================
create or replace function app.check_entry_balanced()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry_id uuid;
  v_total    numeric;
  v_debit    numeric;
  v_credit   numeric;
  v_lines    integer;
begin
  if tg_table_name = 'journal_entries' then
    v_entry_id := new.id;
  else
    v_entry_id := new.entry_id;
  end if;

  select total into v_total from public.journal_entries where id = v_entry_id;
  select coalesce(sum(debit), 0), coalesce(sum(credit), 0), count(*)
    into v_debit, v_credit, v_lines
    from public.journal_lines where entry_id = v_entry_id;

  if v_lines < 2 then
    raise exception 'Journal entry % must have at least two lines', v_entry_id using errcode = 'P0001';
  end if;
  if v_debit <> v_credit then
    raise exception 'Journal entry % is not balanced (debit %, credit %)', v_entry_id, v_debit, v_credit
      using errcode = 'P0001';
  end if;
  if v_debit <> v_total then
    raise exception 'Journal entry % total % does not match lines %', v_entry_id, v_total, v_debit
      using errcode = 'P0001';
  end if;
  return null;
end;
$$;
revoke execute on function app.check_entry_balanced() from public, anon, authenticated;
