-- =====================================================================
-- OLA Water ERP — Phase 1A
-- 0015: private storage for delivery proof photos
-- Path convention: delivery-proofs/{run_id}/{delivery_id}-{client_txn_id}.jpg
-- (Skipped automatically where the Supabase storage schema is not present.)
-- =====================================================================
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('delivery-proofs', 'delivery-proofs', false, 2097152, array['image/jpeg','image/png','image/webp'])
    on conflict (id) do nothing;

    execute $p$
      create policy "Drivers upload proofs for their own runs" on storage.objects
        for insert to authenticated
        with check (
          bucket_id = 'delivery-proofs'
          and exists (select 1 from public.route_runs r
                       where r.id::text = (storage.foldername(name))[1]
                         and (r.driver_id = auth.uid() or app.has_permission('deliveries.manage')))
        )
    $p$;
    execute $p$
      create policy "Staff read delivery proofs" on storage.objects
        for select to authenticated
        using (
          bucket_id = 'delivery-proofs'
          and (app.has_permission('deliveries.view')
               or exists (select 1 from public.route_runs r where r.id::text = (storage.foldername(name))[1] and r.driver_id = auth.uid()))
        )
    $p$;
  end if;
exception when others then
  -- Never stop the rest of the update because of storage permissions.
  raise notice 'Storage bucket/policies not created (%). Delivery photos cannot be stored until this is fixed (signatures still work).', sqlerrm;
end $$;
