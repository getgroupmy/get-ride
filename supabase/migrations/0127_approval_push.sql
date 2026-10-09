-- ============================================================================
-- 0127: tell a partner when the admin decides
--
-- An approval, a rejection or a block of a partner account, a vehicle or one
-- of their documents now sends a push to that partner's devices, so they
-- don't have to keep reopening the app to find out. Neither app did this
-- (Expo or Flutter): the decision was only seen on the next visit.
--
-- What each decision says is one pure function, approval_push_message, so it
-- is tested on its own (supabase/tests/approval_push.sql); the triggers only
-- find the recipient and hand it to send_push_webhook, which never fails the
-- write it rides on.
-- ============================================================================

-- {title, body} for a decision, or null when it isn't one worth a push.
--   p_kind:   'partner' | 'vehicle' | 'document'
--   p_status: the new status (partner_status for partner/vehicle; the
--             document's 'Approved' / 'Rejected' / …)
--   p_name:   the vehicle's plate or the document's name (unused for partner)
--   p_note:   the admin's reason (status_note / reviewer_notes), if any
create or replace function public.approval_push_message(p_kind text, p_status text, p_name text, p_note text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  with n as (
    select nullif(btrim(coalesce(p_note, '')), '') as note,
           coalesce(nullif(btrim(coalesce(p_name, '')), ''), case p_kind when 'vehicle' then 'Your vehicle' else 'A document' end) as name,
           lower(btrim(coalesce(p_status, ''))) as status
  )
  select case
    when p_kind = 'partner' then case n.status
      when 'approved' then jsonb_build_object('title', 'You''re approved',
        'body', 'Your GET.ride partner account is approved. You can go online now.')
      when 'permit-verified' then jsonb_build_object('title', 'Permit verified',
        'body', 'Your permit is verified. You can go online now.')
      when 'rejected' then jsonb_build_object('title', 'Application not approved',
        'body', coalesce(n.note, 'Open GET.ride to see what to change and send it again.'))
      when 'blocked' then jsonb_build_object('title', 'Account blocked',
        'body', coalesce(n.note, 'Contact support to find out more.'))
      when 'unapproved-docs' then jsonb_build_object('title', 'Documents needed',
        'body', 'Some of your documents need attention. Open GET.ride to update them.')
      end
    when p_kind = 'vehicle' then case n.status
      when 'approved' then jsonb_build_object('title', 'Vehicle approved',
        'body', n.name || ' is approved. You can drive it now.')
      when 'permit-verified' then jsonb_build_object('title', 'Vehicle permit verified',
        'body', n.name || ' is verified. You can drive it now.')
      when 'rejected' then jsonb_build_object('title', 'Vehicle not approved',
        'body', n.name || ': ' || coalesce(n.note, 'open GET.ride to see what to change.'))
      when 'blocked' then jsonb_build_object('title', 'Vehicle blocked',
        'body', n.name || ': ' || coalesce(n.note, 'contact support to find out more.'))
      end
    when p_kind = 'document' then case n.status
      when 'approved' then jsonb_build_object('title', 'Document approved',
        'body', n.name || ' is approved.')
      when 'rejected' then jsonb_build_object('title', 'Document rejected',
        'body', n.name || ': ' || coalesce(n.note, 'please upload it again.'))
      end
  end
  from n;
$$;

-- Sends [p_msg] to [p_user]'s devices (no-op when either is missing).
create or replace function public.approval_push_send(p_user uuid, p_msg jsonb, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user is null or p_msg is null then
    return;
  end if;
  perform public.send_push_webhook(jsonb_build_object(
    'title', p_msg->>'title',
    'body', p_msg->>'body',
    'profileId', p_user,
    'data', p_data
  ));
exception when others then
  null;
end;
$$;

create or replace function public.notify_partner_status_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is distinct from old.status then
    perform public.approval_push_send(
      new.auth_user_id,
      public.approval_push_message('partner', new.status::text, null, new.status_note),
      jsonb_build_object('type', 'partner_status', 'status', new.status::text)
    );
  end if;
  return new;
exception when others then
  return new;
end;
$$;

create or replace function public.notify_vehicle_status_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := new.auth_user_id;
begin
  if new.status is distinct from old.status then
    if v_user is null and new.owner_partner_id is not null then
      select auth_user_id into v_user from public.partners where id = new.owner_partner_id;
    end if;
    perform public.approval_push_send(
      v_user,
      public.approval_push_message('vehicle', new.status::text, new.plate, null),
      jsonb_build_object('type', 'vehicle_status', 'vehicle_id', new.id, 'status', new.status::text)
    );
  end if;
  return new;
exception when others then
  return new;
end;
$$;

-- Both document tables have partner_id, auth_user_id, doc_name, status and
-- reviewer_notes.
create or replace function public.notify_document_status_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := new.auth_user_id;
begin
  if new.status is distinct from old.status then
    if v_user is null and new.partner_id is not null then
      select auth_user_id into v_user from public.partners where id = new.partner_id;
    end if;
    perform public.approval_push_send(
      v_user,
      public.approval_push_message('document', new.status, new.doc_name, new.reviewer_notes),
      jsonb_build_object('type', 'document_status', 'table', tg_table_name, 'document_id', new.id, 'status', new.status)
    );
  end if;
  return new;
exception when others then
  return new;
end;
$$;

revoke execute on function public.approval_push_send(uuid, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.notify_partner_status_push() from public, anon, authenticated;
revoke execute on function public.notify_vehicle_status_push() from public, anon, authenticated;
revoke execute on function public.notify_document_status_push() from public, anon, authenticated;

drop trigger if exists trg_partners_status_push on public.partners;
create trigger trg_partners_status_push after update of status on public.partners
  for each row execute function public.notify_partner_status_push();

drop trigger if exists trg_vehicle_status_push on public.vehicle;
create trigger trg_vehicle_status_push after update of status on public.vehicle
  for each row execute function public.notify_vehicle_status_push();

drop trigger if exists trg_provider_documents_status_push on public.provider_documents;
create trigger trg_provider_documents_status_push after update of status on public.provider_documents
  for each row execute function public.notify_document_status_push();

drop trigger if exists trg_vehicle_documents_status_push on public.vehicle_documents;
create trigger trg_vehicle_documents_status_push after update of status on public.vehicle_documents
  for each row execute function public.notify_document_status_push();
