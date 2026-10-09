-- ============================================================================
-- Regression test for migration 0127: what a partner is told when the admin
-- decides on their account, vehicle or document, and that the senders can't
-- be called by clients.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approval_push.sql
--
-- Read-only. A failed assertion raises.
-- ============================================================================
do $$
declare
  m jsonb;
begin
  m := public.approval_push_message('partner', 'approved', null, null);
  if m->>'title' <> 'You''re approved' then raise exception 'partner approved: %', m; end if;

  m := public.approval_push_message('partner', 'rejected', null, '  Blurry IC photo ');
  if m->>'body' <> 'Blurry IC photo' then raise exception 'partner rejection reason: %', m; end if;
  m := public.approval_push_message('partner', 'rejected', null, '');
  if m->>'body' not like 'Open GET.ride%' then raise exception 'partner rejection fallback: %', m; end if;

  if public.approval_push_message('partner', 'unapproved', null, null) is not null then
    raise exception 'reopening a partner is not a decision to push';
  end if;
  if public.approval_push_message('partner', 'permit-pending', null, null) is not null then
    raise exception 'permit-pending is not a decision to push';
  end if;

  m := public.approval_push_message('vehicle', 'approved', 'WXY 1234', null);
  if m->>'body' <> 'WXY 1234 is approved. You can drive it now.' then raise exception 'vehicle approved: %', m; end if;
  m := public.approval_push_message('vehicle', 'blocked', null, null);
  if m->>'body' not like 'Your vehicle:%' then raise exception 'vehicle without plate: %', m; end if;

  m := public.approval_push_message('document', 'Rejected', 'Road tax', 'Expired');
  if m->>'title' <> 'Document rejected' or m->>'body' <> 'Road tax: Expired' then
    raise exception 'document rejected: %', m;
  end if;
  m := public.approval_push_message('document', 'Approved', 'Road tax', null);
  if m->>'body' <> 'Road tax is approved.' then raise exception 'document approved: %', m; end if;
  if public.approval_push_message('document', 'Pending Review', 'Road tax', null) is not null then
    raise exception 'a re-upload going back to review is not a decision to push';
  end if;

  if has_function_privilege('authenticated', 'public.approval_push_send(uuid, jsonb, jsonb)', 'execute')
     or has_function_privilege('anon', 'public.approval_push_send(uuid, jsonb, jsonb)', 'execute') then
    raise exception 'approval_push_send must not be callable by clients';
  end if;

  if not exists (select 1 from pg_trigger where tgname = 'trg_partners_status_push')
     or not exists (select 1 from pg_trigger where tgname = 'trg_vehicle_status_push')
     or not exists (select 1 from pg_trigger where tgname = 'trg_provider_documents_status_push')
     or not exists (select 1 from pg_trigger where tgname = 'trg_vehicle_documents_status_push') then
    raise exception 'a status push trigger is missing';
  end if;
end
$$;

-- A status change still goes through with the push in its path (no Vault
-- secret in CI, so the send is a no-op).
begin;
do $$
declare
  p uuid := gen_random_uuid();
begin
  insert into public.partners (id, name, phone, status) values (p, 'Push Test', '+60000000127', 'unapproved');
  update public.partners set status = 'approved' where id = p;
  if (select status::text from public.partners where id = p) <> 'approved' then
    raise exception 'the approval did not stick';
  end if;
end
$$;
rollback;

select 'approval_push: all passed';
