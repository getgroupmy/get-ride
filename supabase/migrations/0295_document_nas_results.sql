-- ============================================================================
-- 0295: document reading, part 4 — what the office NAS read, for the review.
--
-- Admin > Documents shows, on a document, the plates, numbers and QR codes
-- the NAS read off each side of it (doc_read_jobs, 0293), how sure it was,
-- and whether it passed the reading on. Admins only; the newest finished
-- reading per document and side.
-- ============================================================================
create or replace function public.admin_doc_read_results(p_table text, p_ids uuid[])
returns table (
  doc_id uuid, side text, status text, result jsonb, confidence numeric, ms integer,
  reader_label text, done_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'Admins only.' using errcode = '42501';
  end if;
  if p_table not in ('provider_documents', 'vehicle_documents') then
    raise exception 'Unknown document table.' using errcode = '22023';
  end if;
  return query
  select distinct on (j.doc_id, j.side)
         j.doc_id, j.side, j.status, j.result, j.confidence, j.ms, r.label, j.done_at
    from public.doc_read_jobs j
    left join public.doc_readers r on r.id = j.reader_id
   where j.doc_table = p_table
     and j.doc_id = any(p_ids[1:500])
     and j.status in ('done', 'passed_on', 'failed')
   order by j.doc_id, j.side, j.done_at desc nulls last;
end;
$$;
revoke execute on function public.admin_doc_read_results(text, uuid[]) from public, anon;
grant execute on function public.admin_doc_read_results(text, uuid[]) to authenticated;

notify pgrst, 'reload schema';

insert into supabase_migrations.schema_migrations (version, name)
values ('20261025230000', '0295_document_nas_results')
on conflict (version) do nothing;
