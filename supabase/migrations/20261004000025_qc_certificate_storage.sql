-- =====================================================================
-- OLA Water ERP — Phase 2A
-- 0025: private storage for QC certificates and lab reports
-- Path convention: qc-certificates/{batch_id}/{uuid}.{pdf|jpg|png}
-- (Skipped automatically where the Supabase storage schema is not present.)
-- =====================================================================
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('qc-certificates', 'qc-certificates', false, 10485760,
            array['application/pdf','image/jpeg','image/png','image/webp','image/heic'])
    on conflict (id) do nothing;

    execute $p$
      create policy "QC staff upload certificates for a batch" on storage.objects
        for insert to authenticated
        with check (
          bucket_id = 'qc-certificates'
          and app.has_permission('qc.manage')
          and exists (select 1 from public.production_batches b where b.id::text = (storage.foldername(name))[1])
        )
    $p$;
    execute $p$
      create policy "Staff read QC certificates" on storage.objects
        for select to authenticated
        using (bucket_id = 'qc-certificates' and (app.has_permission('qc.view') or app.has_permission('production.view')))
    $p$;
  end if;
exception when others then
  raise notice 'Storage bucket/policies not created (%). QC certificates cannot be uploaded until this is fixed.', sqlerrm;
end $$;
