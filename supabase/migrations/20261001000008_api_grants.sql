-- =====================================================================
-- OLA Water ERP — Phase 0
-- 0008: explicit read grants for the Supabase Data API
-- Some Supabase projects do not grant table access to API roles
-- automatically. Reads are still filtered by Row Level Security, and
-- all writes go through the permission-checked functions.
-- =====================================================================
grant usage on schema public to anon, authenticated, service_role;
grant select on all tables in schema public to authenticated, service_role;
revoke all on all tables in schema public from anon;
