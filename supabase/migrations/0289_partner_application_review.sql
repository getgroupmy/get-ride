-- ============================================================================
-- 0289 — Partner registration, part 3: the admin reviews an application line
-- by line, and the driver sees "Changes needed".
--
-- Version 20261024190000 (0289_partner_application_review). Re-runnable:
-- the enum value and the table "if not exists", functions "create or
-- replace", triggers and policies dropped first, seed rows "on conflict do
-- nothing".
--
-- 1. partner_status gets 'changes-needed': the admin sent the application
--    back with items to fix. Not approved, so Drive stays locked.
-- 2. partner_review_items: one row a reviewed line (item_key, e.g.
--    details.name, id.front, doc:provider:<required document id>), its group
--    and label as the driver reads it, the decision (approved / rejected /
--    edited), the admin's reason or note, the value before and after an
--    admin's edit, who decided and when, when it went to the driver
--    (sent_at), when the driver changed it (fixed_at, the server's) and
--    whether they kept the admin's edit (kept_at). Nobody writes it
--    directly: the functions below. Admins read every row; the driver reads
--    their own once sent.
-- 3. partner_review_set (admin with EDIT on the Partners pages,
--    caller_admin_can_write('rpc:partner_review_set')): approve, reject (a
--    reason is required), edit (a note and the new value, written to the
--    real column: the profile, the partner row or the registration vehicle)
--    or clear a line. Not while the application is with the driver, and
--    never on an approved or blocked partner.
-- 4. partner_review_send_back: at least one rejected line. The documents on
--    the lines are approved / rejected (with the reason) without a push
--    each; a rejected vehicle line opens the vehicle again for the driver;
--    the partner goes to 'changes-needed', and the status push (0127) says
--    "Changes needed".
-- 5. partner_review_approve: no rejected line and none changed since it was
--    decided. The documents on the lines are approved, the registration
--    vehicle is approved with the partner (as the status picker does it,
--    with its push), the partner is approved.
-- 6. The driver: what changes after sending back marks the line fixed
--    (triggers on profiles, partners, vehicle and both document tables);
--    partner_review_keep(item_key) keeps an admin's edit;
--    partner_review_resubmit() sends it again once every rejected line is
--    fixed: fixed lines go back to the admin unreviewed, the vehicle is
--    submitted again, the partner is 'unapproved' (resubmitted_at), and the
--    admins with a Partners page get a push.
-- Every admin action and the resubmission are in admin_audit_log.
-- ============================================================================

-- ---- 1. The status ------------------------------------------------------------------------------
-- Never used as an enum literal below (only as text), so this runs in the
-- same transaction as the rest.
alter type public.partner_status add value if not exists 'changes-needed';

-- ---- 2. The lines -------------------------------------------------------------------------------
create table if not exists public.partner_review_items (
  id          uuid primary key default gen_random_uuid(),
  partner_id  uuid not null references public.partners (id) on delete cascade,
  item_key    text not null check (char_length(item_key) between 1 and 120 and item_key ~ '^[a-z_]+([.:][A-Za-z0-9_.:-]+)?$'),
  item_group  text not null check (item_group in (
                'details', 'national_id', 'company', 'driver_permit', 'services',
                'vehicle', 'vehicle_documents', 'service_documents', 'vehicle_permits')),
  label       text not null check (char_length(btrim(label)) between 1 and 160),
  state       text not null check (state in ('approved', 'rejected', 'edited')),
  note        text check (note is null or char_length(note) <= 500),
  old_value   jsonb,
  new_value   jsonb,
  -- The line's value when it was decided (and again when sent): a change
  -- after sending marks it fixed.
  seen_value  jsonb,
  reviewer_id uuid references public.profiles (id) on delete set null,
  decided_at  timestamptz not null default now(),
  sent_at     timestamptz,
  fixed_at    timestamptz,
  kept_at     timestamptz,
  constraint partner_review_items_reason_check
    check (state = 'approved' or char_length(btrim(coalesce(note, ''))) > 0),
  unique (partner_id, item_key)
);
comment on table public.partner_review_items is
  'Partner application review (0289): the admin''s decision on each line (approved / rejected with a reason / edited with a note and the value before and after). The driver sees them once sent back (partners.status changes-needed); fixed_at is the server''s. Written only through partner_review_* functions.';
create index if not exists partner_review_items_partner_idx on public.partner_review_items (partner_id);

alter table public.partner_review_items enable row level security;
revoke all on public.partner_review_items from public, anon, authenticated;
grant select on public.partner_review_items to authenticated;
grant all on public.partner_review_items to service_role;

drop policy if exists partner_review_items_read on public.partner_review_items;
create policy partner_review_items_read on public.partner_review_items
  for select to authenticated using (
    (select public.caller_is_admin())
    or (sent_at is not null and exists (
          select 1 from public.partners p
           where p.id = partner_review_items.partner_id and p.auth_user_id = (select auth.uid())))
  );

insert into public.admin_table_pages (target, page) values
  ('rpc:partner_review_set', 'admin-partners'),
  ('rpc:partner_review_set', 'admin-partner-edit'),
  ('rpc:partner_review_send_back', 'admin-partners'),
  ('rpc:partner_review_send_back', 'admin-partner-edit'),
  ('rpc:partner_review_approve', 'admin-partners'),
  ('rpc:partner_review_approve', 'admin-partner-edit')
on conflict do nothing;

-- ---- The value behind a line --------------------------------------------------------------------
-- What [p_key] reads today for [p_partner] (null when the line has none).
create or replace function public.partner_review_value(p_partner uuid, p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  p  public.partners%rowtype;
  pr public.profiles%rowtype;
  v  public.vehicle%rowtype;
  r  jsonb;
begin
  select * into p from public.partners where id = p_partner;
  if not found then
    return null;
  end if;
  select * into pr from public.profiles where id = p.auth_user_id;
  if p.registration_vehicle_id is not null then
    select * into v from public.vehicle where id = p.registration_vehicle_id;
  end if;

  if p_key like 'doc:provider:%' then
    select jsonb_build_object('file_url', d.file_url, 'file_url_back', d.file_url_back,
                              'document_number', d.document_number, 'expiry_date', d.expiry_date)
      into r
      from public.provider_documents d
     where d.partner_id = p.id and d.doc_id = substr(p_key, 14)
     order by d.uploaded_at desc
     limit 1;
    return r;
  elsif p_key like 'doc:vehicle:%' then
    if v.id is null then
      return null;
    end if;
    select jsonb_build_object('file_url', d.file_url, 'file_url_back', d.file_url_back,
                              'document_number', d.document_number, 'expiry_date', d.expiry_date)
      into r
      from public.vehicle_documents d
     where d.vehicle_id = v.id and d.doc_id = substr(p_key, 13)
     order by d.uploaded_at desc
     limit 1;
    return r;
  elsif p_key like 'vpermit:%' then
    if v.id is null then
      return null;
    end if;
    select jsonb_build_object('file_url', d.file_url, 'document_number', d.document_number,
                              'expiry_date', d.expiry_date, 'status', d.status)
      into r
      from public.vehicle_documents d
     where d.vehicle_id = v.id and d.permit_type_id::text = substr(p_key, 9)
     order by d.uploaded_at desc
     limit 1;
    return r;
  end if;

  return case p_key
    when 'details.photo'        then to_jsonb(pr.avatar_url)
    when 'details.name'         then to_jsonb(pr.name)
    when 'details.birth_date'   then to_jsonb(pr.birth_date)
    when 'details.address'      then to_jsonb(pr.address)
    when 'details.nationality'  then to_jsonb(pr.nationality)
    when 'details.id_number'    then to_jsonb(pr.ic)
    when 'id.front'             then to_jsonb(pr.id_image)
    when 'id.back'              then to_jsonb(pr.id_image_back)
    when 'company.document'     then to_jsonb(p.company_document_url)
    when 'company.name'         then to_jsonb(p.company_name)
    when 'company.reg_no'       then to_jsonb(p.company_reg_no)
    when 'company.type'         then to_jsonb(p.company_type)
    when 'company.reg_date'     then to_jsonb(p.company_reg_date)
    when 'company.address'      then to_jsonb(p.company_address)
    when 'permit.photos'        then jsonb_build_array(p.driver_permit_front_url, p.driver_permit_back_url)
    when 'permit.card_no'       then to_jsonb(p.driver_permit_card_no)
    when 'permit.valid_until'   then to_jsonb(p.driver_permit_valid_until)
    when 'services'             then to_jsonb(p.partner_types)
    when 'vehicle.grant'        then case when v.id is null then null
                                          else jsonb_build_array(v.grant_front_url, v.grant_back_url) end
    when 'vehicle.photos'       then case when v.id is null then null
                                          else jsonb_build_array(v.image_front, v.image_left, v.image_right, v.image_back) end
    when 'vehicle.authorisation' then to_jsonb(v.authorisation_letter_url)
    when 'vehicle.agreement'    then to_jsonb(v.hire_agreement_url)
    when 'vehicle.plate'        then to_jsonb(v.plate)
    when 'vehicle.make'         then to_jsonb(v.make)
    when 'vehicle.model'        then to_jsonb(v.model)
    when 'vehicle.year'         then to_jsonb(v.year)
    when 'vehicle.color'        then to_jsonb(v.color)
    when 'vehicle.engine_number' then to_jsonb(v.engine_number)
    when 'vehicle.vin'          then to_jsonb(v.vin)
    when 'vehicle.registration_date' then to_jsonb(v.registration_date)
    when 'vehicle.engine_cc'    then to_jsonb(v.engine_cc)
    when 'vehicle.owner'        then to_jsonb(v.grant_owner_name)
    else null
  end;
end;
$$;
revoke execute on function public.partner_review_value(uuid, text) from public, anon, authenticated;

-- What an admin may edit, and how it is typed: 'text', 'date', 'int',
-- 'services'; null: not editable (photos, files, documents).
create or replace function public.partner_review_edit_type(p_key text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_key in ('details.name', 'details.address', 'details.nationality', 'details.id_number',
                   'company.name', 'company.reg_no', 'company.type', 'company.address', 'permit.card_no',
                   'vehicle.plate', 'vehicle.make', 'vehicle.model', 'vehicle.year', 'vehicle.color',
                   'vehicle.engine_number', 'vehicle.vin', 'vehicle.owner') then 'text'
    when p_key in ('details.birth_date', 'company.reg_date', 'permit.valid_until', 'vehicle.registration_date') then 'date'
    when p_key = 'vehicle.engine_cc' then 'int'
    when p_key = 'services' then 'services'
    when p_key like 'vpermit:%' then 'note'
  end;
$$;
revoke execute on function public.partner_review_edit_type(text) from public, anon;
grant execute on function public.partner_review_edit_type(text) to authenticated;

-- Writes an admin's new value into the real column (security definer: the
-- row guards let the server through).
create or replace function public.partner_review_apply(p_partner uuid, p_key text, p_value jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  p      public.partners%rowtype;
  v_type text := public.partner_review_edit_type(p_key);
  v_txt  text;
  v_date date;
  v_int  integer;
  v_list text[];
begin
  select * into p from public.partners where id = p_partner;
  if v_type is null or v_type = 'note' then
    return;
  end if;
  if v_type = 'services' then
    if jsonb_typeof(p_value) is distinct from 'array' then
      raise exception 'REVIEW_BAD_VALUE' using errcode = '22023', hint = 'Pick at least one Partner Service type.';
    end if;
    select array_agg(distinct btrim(x)) into v_list
      from jsonb_array_elements_text(p_value) x where btrim(x) <> '';
    if coalesce(cardinality(v_list), 0) = 0 then
      raise exception 'REVIEW_BAD_VALUE' using errcode = '22023', hint = 'Pick at least one Partner Service type.';
    end if;
    update public.partners
       set partner_types = v_list, partner_type = array_to_string(v_list, ','), updated_at = now()
     where id = p_partner;
    return;
  end if;

  v_txt := nullif(btrim(coalesce(p_value #>> '{}', '')), '');
  if v_txt is null or char_length(v_txt) > 500 then
    raise exception 'REVIEW_BAD_VALUE' using errcode = '22023', hint = 'Type the new value (up to 500 characters).';
  end if;
  if v_type = 'date' then
    begin
      v_date := v_txt::date;
    exception when others then
      raise exception 'REVIEW_BAD_VALUE' using errcode = '22023', hint = 'Enter a real date.';
    end;
  elsif v_type = 'int' then
    begin
      v_int := v_txt::integer;
    exception when others then
      raise exception 'REVIEW_BAD_VALUE' using errcode = '22023', hint = 'Enter a whole number.';
    end;
  end if;

  if p_key like 'vehicle.%' and p.registration_vehicle_id is null then
    raise exception 'REVIEW_NO_VEHICLE' using errcode = 'P0002', hint = 'This application has no vehicle.';
  end if;
  if p_key like 'details.%' and p.auth_user_id is null then
    raise exception 'REVIEW_NO_PROFILE' using errcode = 'P0002', hint = 'This partner has no account on the app.';
  end if;

  case p_key
    -- The profile is the master copy of name, IC and address (0277): the
    -- partner row follows.
    when 'details.name'        then update public.profiles set name = v_txt where id = p.auth_user_id;
    when 'details.address'     then update public.profiles set address = v_txt where id = p.auth_user_id;
    when 'details.nationality' then update public.profiles set nationality = v_txt where id = p.auth_user_id;
    when 'details.id_number'   then update public.profiles set ic = v_txt where id = p.auth_user_id;
    when 'details.birth_date'  then update public.profiles set birth_date = v_date where id = p.auth_user_id;
    when 'company.name'        then update public.partners set company_name = v_txt where id = p_partner;
    when 'company.reg_no'      then update public.partners set company_reg_no = v_txt where id = p_partner;
    when 'company.type'        then update public.partners set company_type = v_txt where id = p_partner;
    when 'company.address'     then update public.partners set company_address = v_txt where id = p_partner;
    when 'company.reg_date'    then update public.partners set company_reg_date = v_date where id = p_partner;
    when 'permit.card_no'      then update public.partners set driver_permit_card_no = v_txt where id = p_partner;
    when 'permit.valid_until'  then update public.partners set driver_permit_valid_until = v_date where id = p_partner;
    when 'vehicle.plate'       then update public.vehicle set plate = upper(v_txt) where id = p.registration_vehicle_id;
    when 'vehicle.make'        then update public.vehicle set make = v_txt where id = p.registration_vehicle_id;
    when 'vehicle.model'       then update public.vehicle set model = v_txt where id = p.registration_vehicle_id;
    when 'vehicle.year'        then update public.vehicle set year = v_txt where id = p.registration_vehicle_id;
    when 'vehicle.color'       then update public.vehicle set color = v_txt where id = p.registration_vehicle_id;
    when 'vehicle.engine_number' then update public.vehicle set engine_number = v_txt where id = p.registration_vehicle_id;
    when 'vehicle.vin'         then update public.vehicle set vin = v_txt where id = p.registration_vehicle_id;
    when 'vehicle.owner'       then update public.vehicle set grant_owner_name = v_txt where id = p.registration_vehicle_id;
    when 'vehicle.registration_date' then update public.vehicle set registration_date = v_date where id = p.registration_vehicle_id;
    when 'vehicle.engine_cc'   then update public.vehicle set engine_cc = v_int where id = p.registration_vehicle_id;
  end case;
  -- The partner row shows the vehicle by its plate.
  if p_key = 'vehicle.plate' then
    update public.partners set plate = upper(v_txt) where id = p_partner and plate is distinct from upper(v_txt);
  end if;
end;
$$;
revoke execute on function public.partner_review_apply(uuid, text, jsonb) from public, anon, authenticated;

-- ---- 3. One line --------------------------------------------------------------------------------
create or replace function public.partner_review_set(
  p_partner uuid, p_key text, p_group text, p_label text, p_state text,
  p_note text default null, p_value jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  p        public.partners%rowtype;
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
  v_prev   public.partner_review_items%rowtype;
  v_old    jsonb;
  v_new    jsonb;
  v_row    public.partner_review_items%rowtype;
begin
  if not public.caller_admin_can_write('rpc:partner_review_set') then
    raise exception 'Only admins who can edit partners can review an application.' using errcode = '42501';
  end if;
  select * into p from public.partners where id = p_partner for update;
  if not found then
    raise exception 'PARTNER_NOT_FOUND' using errcode = 'P0002', hint = 'This partner no longer exists.';
  end if;
  if p.status::text = 'changes-needed' then
    raise exception 'REVIEW_WITH_DRIVER' using errcode = '22023',
      hint = 'The application is with the driver. You can review it again once they send it back.';
  end if;
  if p.status::text in ('approved', 'blocked') or p.status::text like 'permit-%' then
    raise exception 'REVIEW_CLOSED' using errcode = '22023',
      hint = 'This partner is already approved or blocked. Change their status first.';
  end if;
  if p_key is null or p_key !~ '^[a-z_]+([.:][A-Za-z0-9_.:-]+)?$' or char_length(p_key) > 120 then
    raise exception 'REVIEW_BAD_ITEM' using errcode = '22023', hint = 'That is not a line of this application.';
  end if;

  select * into v_prev from public.partner_review_items where partner_id = p_partner and item_key = p_key;

  if p_state = 'clear' then
    delete from public.partner_review_items where partner_id = p_partner and item_key = p_key;
    -- An admin's edit stays where it was written; clearing only forgets the line.
    insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
    values (v_uid, 'partner.review_item', p.auth_user_id,
            jsonb_build_object('partner_id', p_partner, 'item_key', p_key, 'state', 'clear'));
    return null;
  end if;

  if p_state is null or p_state not in ('approved', 'rejected', 'edited') then
    raise exception 'REVIEW_BAD_STATE' using errcode = '22023', hint = 'Approve, reject or edit.';
  end if;
  if p_group is null or p_group not in ('details', 'national_id', 'company', 'driver_permit', 'services',
                                        'vehicle', 'vehicle_documents', 'service_documents', 'vehicle_permits') then
    raise exception 'REVIEW_BAD_ITEM' using errcode = '22023', hint = 'That is not a group of this application.';
  end if;
  if char_length(btrim(coalesce(p_label, ''))) not between 1 and 160 then
    raise exception 'REVIEW_BAD_ITEM' using errcode = '22023', hint = 'The line needs a name.';
  end if;
  if p_state = 'rejected' and v_note is null then
    raise exception 'REVIEW_REASON_NEEDED' using errcode = '22023', hint = 'Say why it is rejected: the driver reads it.';
  end if;
  if p_state = 'edited' and v_note is null then
    raise exception 'REVIEW_NOTE_NEEDED' using errcode = '22023', hint = 'Add a note for the driver about the change.';
  end if;
  if char_length(coalesce(v_note, '')) > 500 then
    raise exception 'REVIEW_NOTE_TOO_LONG' using errcode = '22023', hint = 'Keep the note to 500 characters.';
  end if;
  -- A vehicle permit is GET.ride's upload: the driver can't fix it.
  if p_state = 'rejected' and p_key like 'vpermit:%' then
    raise exception 'REVIEW_NOT_DRIVERS' using errcode = '22023',
      hint = 'Vehicle permits are uploaded by GET.ride, not the driver. Upload the right one on Vehicle permits.';
  end if;

  if p_state = 'edited' then
    if public.partner_review_edit_type(p_key) is null then
      raise exception 'REVIEW_NOT_EDITABLE' using errcode = '22023',
        hint = 'Photos and documents can''t be edited here. Reject the line so the driver uploads it again.';
    end if;
    if public.partner_review_edit_type(p_key) = 'note' then
      v_old := null;
      v_new := case when p_value is null or btrim(coalesce(p_value #>> '{}', '')) = '' then null else p_value end;
    else
      v_old := public.partner_review_value(p_partner, p_key);
      perform public.partner_review_apply(p_partner, p_key, p_value);
      v_new := public.partner_review_value(p_partner, p_key);
      -- Edited twice: "You entered" stays what the driver entered.
      if v_prev.state = 'edited' and v_prev.old_value is not null then
        v_old := v_prev.old_value;
      end if;
    end if;
  end if;

  insert into public.partner_review_items as i
    (partner_id, item_key, item_group, label, state, note, old_value, new_value, seen_value,
     reviewer_id, decided_at, sent_at, fixed_at, kept_at)
  values
    (p_partner, p_key, p_group, btrim(p_label), p_state, v_note, v_old, v_new,
     public.partner_review_value(p_partner, p_key), v_uid, now(), null, null, null)
  on conflict (partner_id, item_key) do update
    set item_group = excluded.item_group, label = excluded.label, state = excluded.state,
        note = excluded.note, old_value = excluded.old_value, new_value = excluded.new_value,
        seen_value = excluded.seen_value, reviewer_id = excluded.reviewer_id,
        decided_at = now(), sent_at = null, fixed_at = null, kept_at = null
  returning * into v_row;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'partner.review_item', p.auth_user_id,
          jsonb_build_object('partner_id', p_partner, 'item_key', p_key, 'state', p_state, 'note', v_note,
                             'old_value', v_old, 'new_value', v_new));
  return to_jsonb(v_row);
end;
$$;
revoke execute on function public.partner_review_set(uuid, text, text, text, text, text, jsonb) from public, anon;
grant execute on function public.partner_review_set(uuid, text, text, text, text, text, jsonb) to authenticated;

-- ---- Documents decided with the application ----------------------------------------------------
-- Approves or rejects the documents on the lines (the newest upload of each)
-- without a push each: the application's own push says it.
create or replace function public.partner_review_decide_documents(p_partner uuid, p_only_approved boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  p public.partners%rowtype;
  i record;
begin
  select * into p from public.partners where id = p_partner;
  perform set_config('app.partner_review_batch', 'on', true);
  for i in
    select it.item_key, it.state, it.note from public.partner_review_items it
     where it.partner_id = p_partner and (it.item_key like 'doc:provider:%' or it.item_key like 'doc:vehicle:%')
  loop
    continue when p_only_approved and i.state = 'rejected';
    if i.item_key like 'doc:provider:%' then
      update public.provider_documents d
         set status = case when i.state = 'rejected' then 'Rejected' else 'Approved' end,
             reviewer_notes = case when i.state = 'rejected' then i.note else d.reviewer_notes end,
             reviewed_at = now()
       where d.id = (select x.id from public.provider_documents x
                      where x.partner_id = p_partner and x.doc_id = substr(i.item_key, 14)
                      order by x.uploaded_at desc limit 1);
    elsif p.registration_vehicle_id is not null then
      update public.vehicle_documents d
         set status = case when i.state = 'rejected' then 'Rejected' else 'Approved' end,
             reviewer_notes = case when i.state = 'rejected' then i.note else d.reviewer_notes end,
             reviewed_at = now()
       where d.id = (select x.id from public.vehicle_documents x
                      where x.vehicle_id = p.registration_vehicle_id and x.doc_id = substr(i.item_key, 13)
                      order by x.uploaded_at desc limit 1);
    end if;
  end loop;
  perform set_config('app.partner_review_batch', '', true);
end;
$$;
revoke execute on function public.partner_review_decide_documents(uuid, boolean) from public, anon, authenticated;

-- The document push (0127) stays quiet while the application is decided.
create or replace function public.notify_document_status_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := new.auth_user_id;
begin
  if coalesce(current_setting('app.partner_review_batch', true), '') = 'on' then
    return new;
  end if;
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
revoke execute on function public.notify_document_status_push() from public, anon, authenticated;

-- The status push (0127) with "Changes needed".
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
      when 'changes-needed' then jsonb_build_object('title', 'Changes needed',
        'body', coalesce(n.note, 'An admin checked your application. Open GET.ride to see what to fix.'))
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

-- ---- 4. Send back to the driver ----------------------------------------------------------------
create or replace function public.partner_review_send_back(p_partner uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  p          public.partners%rowtype;
  v_rejected integer;
  v_edited   integer;
  v_approved integer;
  v_vehicle  boolean;
begin
  if not public.caller_admin_can_write('rpc:partner_review_send_back') then
    raise exception 'Only admins who can edit partners can send an application back.' using errcode = '42501';
  end if;
  select * into p from public.partners where id = p_partner for update;
  if not found then
    raise exception 'PARTNER_NOT_FOUND' using errcode = 'P0002', hint = 'This partner no longer exists.';
  end if;
  if p.status::text not in ('unapproved', 'unapproved-docs', 'rejected') then
    raise exception 'REVIEW_CLOSED' using errcode = '22023',
      hint = 'Only an application waiting for review can be sent back.';
  end if;
  select count(*) filter (where state = 'rejected'), count(*) filter (where state = 'edited'),
         count(*) filter (where state = 'approved'),
         coalesce(bool_or(state = 'rejected' and item_group in ('vehicle', 'vehicle_documents')), false)
    into v_rejected, v_edited, v_approved, v_vehicle
    from public.partner_review_items where partner_id = p_partner;
  if v_rejected = 0 then
    raise exception 'REVIEW_NOTHING_TO_FIX' using errcode = '22023',
      hint = 'Reject at least one line with a reason, or approve the application.';
  end if;

  perform public.partner_review_decide_documents(p_partner, false);
  update public.partner_review_items
     set sent_at = now(), fixed_at = null, kept_at = null,
         seen_value = public.partner_review_value(p_partner, item_key)
   where partner_id = p_partner;

  -- The vehicle is the driver's to change again (0288's draft rules).
  if v_vehicle and p.registration_vehicle_id is not null then
    update public.vehicle set documents_ok = false
     where id = p.registration_vehicle_id and status::text in ('unapproved', 'unapproved-docs') and documents_ok;
  end if;

  -- The status push (trg_partners_status_push) tells the driver.
  update public.partners
     set status = 'changes-needed', status_note = null, documents_ok = true, updated_at = now()
   where id = p_partner;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'partner.review_send_back', p.auth_user_id,
          jsonb_build_object('partner_id', p_partner, 'rejected', v_rejected, 'edited', v_edited, 'approved', v_approved));
  return jsonb_build_object('rejected', v_rejected, 'edited', v_edited, 'approved', v_approved);
end;
$$;
revoke execute on function public.partner_review_send_back(uuid) from public, anon;
grant execute on function public.partner_review_send_back(uuid) to authenticated;

-- ---- 5. Approve the application ----------------------------------------------------------------
create or replace function public.partner_review_approve(p_partner uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  p         public.partners%rowtype;
  v_vehicle boolean := false;
begin
  if not public.caller_admin_can_write('rpc:partner_review_approve') then
    raise exception 'Only admins who can edit partners can approve an application.' using errcode = '42501';
  end if;
  select * into p from public.partners where id = p_partner for update;
  if not found then
    raise exception 'PARTNER_NOT_FOUND' using errcode = 'P0002', hint = 'This partner no longer exists.';
  end if;
  if p.status::text = 'blocked' then
    raise exception 'REVIEW_CLOSED' using errcode = '22023', hint = 'This partner is blocked. Unblock them first.';
  end if;
  if p.status::text = 'changes-needed' then
    raise exception 'REVIEW_WITH_DRIVER' using errcode = '22023',
      hint = 'The application is with the driver. You can review it again once they send it back.';
  end if;
  if exists (select 1 from public.partner_review_items where partner_id = p_partner and state = 'rejected') then
    raise exception 'REVIEW_REJECTED_LINES' using errcode = '22023',
      hint = 'Some lines are rejected. Send the application back to the driver, or approve those lines first.';
  end if;

  perform public.partner_review_decide_documents(p_partner, true);

  -- Partner and vehicle are approved together.
  if p.registration_vehicle_id is not null then
    update public.vehicle
       set status = 'approved', documents_ok = true
     where id = p.registration_vehicle_id
       and status::text in ('unapproved', 'unapproved-docs', 'rejected');
    v_vehicle := found;
  end if;
  if not (p.status::text = 'approved' or p.status::text like 'permit-%') then
    update public.partners
       set status = 'approved', status_note = null, documents_ok = true, updated_at = now()
     where id = p_partner;
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'partner.review_approve', p.auth_user_id,
          jsonb_build_object('partner_id', p_partner, 'vehicle_id', p.registration_vehicle_id,
                             'vehicle_approved', v_vehicle));
  return jsonb_build_object('approved', true, 'vehicle_approved', v_vehicle);
end;
$$;
revoke execute on function public.partner_review_approve(uuid) from public, anon;
grant execute on function public.partner_review_approve(uuid) to authenticated;

-- ---- 6. The driver ------------------------------------------------------------------------------
-- A line whose value changed since it was sent back is fixed (a value
-- emptied isn't a fix).
create or replace function public.partner_review_touch(p_partner uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_partner is null or not exists (
    select 1 from public.partners p where p.id = p_partner and p.status::text = 'changes-needed'
  ) then
    return;
  end if;
  update public.partner_review_items i
     set fixed_at = now()
   from (select it.id, public.partner_review_value(p_partner, it.item_key) as v
           from public.partner_review_items it
          where it.partner_id = p_partner and it.sent_at is not null and it.fixed_at is null) cur
   where i.id = cur.id
     and cur.v is distinct from i.seen_value
     and cur.v is not null
     and cur.v not in ('null'::jsonb, '""'::jsonb, '[]'::jsonb);
end;
$$;
revoke execute on function public.partner_review_touch(uuid) from public, anon, authenticated;

create or replace function public.partner_review_touch_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_table_name = 'partners' then
    perform public.partner_review_touch(new.id);
  elsif tg_table_name = 'profiles' then
    perform public.partner_review_touch(p.id) from public.partners p
     where p.auth_user_id = new.id and p.status::text = 'changes-needed';
  elsif tg_table_name = 'vehicle' then
    perform public.partner_review_touch(p.id) from public.partners p
     where p.registration_vehicle_id = new.id and p.status::text = 'changes-needed';
  elsif tg_table_name = 'provider_documents' then
    perform public.partner_review_touch(new.partner_id);
  elsif tg_table_name = 'vehicle_documents' then
    perform public.partner_review_touch(p.id) from public.partners p
     where p.registration_vehicle_id = new.vehicle_id and p.status::text = 'changes-needed';
  end if;
  return null;
exception when others then
  return null;
end;
$$;
revoke execute on function public.partner_review_touch_trigger() from public, anon, authenticated;

drop trigger if exists trg_partners_review_touch on public.partners;
create trigger trg_partners_review_touch
  after update of partner_types, company_document_url, company_name, company_reg_no, company_type, company_reg_date,
    company_address, driver_permit_front_url, driver_permit_back_url, driver_permit_card_no, driver_permit_valid_until
  on public.partners
  for each row when (new.status::text = 'changes-needed' and old.status::text = 'changes-needed')
  execute function public.partner_review_touch_trigger();
drop trigger if exists trg_profiles_review_touch on public.profiles;
create trigger trg_profiles_review_touch
  after update of avatar_url, name, birth_date, address, nationality, ic, id_image, id_image_back on public.profiles
  for each row execute function public.partner_review_touch_trigger();
drop trigger if exists trg_vehicle_review_touch on public.vehicle;
create trigger trg_vehicle_review_touch
  after update of plate, make, model, year, color, engine_number, vin, registration_date, engine_cc, grant_owner_name,
    grant_front_url, grant_back_url, image_front, image_left, image_right, image_back, authorisation_letter_url,
    hire_agreement_url on public.vehicle
  for each row execute function public.partner_review_touch_trigger();
drop trigger if exists trg_provider_documents_review_touch on public.provider_documents;
create trigger trg_provider_documents_review_touch
  after insert or update of file_url, file_url_back, document_number, expiry_date on public.provider_documents
  for each row execute function public.partner_review_touch_trigger();
drop trigger if exists trg_vehicle_documents_review_touch on public.vehicle_documents;
create trigger trg_vehicle_documents_review_touch
  after insert or update of file_url, file_url_back, document_number, expiry_date on public.vehicle_documents
  for each row execute function public.partner_review_touch_trigger();

-- "Keep and close": the driver keeps an admin's edit as it is.
create or replace function public.partner_review_keep(p_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '42501';
  end if;
  update public.partner_review_items i
     set kept_at = now()
    from public.partners p
   where p.id = i.partner_id and p.auth_user_id = auth.uid() and p.status::text = 'changes-needed'
     and i.item_key = p_key and i.state = 'edited' and i.sent_at is not null and i.kept_at is null;
end;
$$;
revoke execute on function public.partner_review_keep(text) from public, anon;
grant execute on function public.partner_review_keep(text) to authenticated;

-- "Send for review again".
create or replace function public.partner_review_resubmit()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  p       public.partners%rowtype;
  v_left  integer;
  v_fixed integer;
  v_who   text;
  r       record;
begin
  if v_uid is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '42501';
  end if;
  select * into p from public.partners where auth_user_id = v_uid and status::text = 'changes-needed'
   order by created_at limit 1 for update;
  if not found then
    raise exception 'PARTNER_NOT_CHANGES_NEEDED' using errcode = '22023',
      hint = 'There is nothing to send: your application is not waiting for changes.';
  end if;
  perform public.partner_review_touch(p.id);
  select count(*) into v_left from public.partner_review_items
   where partner_id = p.id and state = 'rejected' and fixed_at is null;
  if v_left > 0 then
    raise exception 'REVIEW_ITEMS_LEFT' using errcode = '22023',
      hint = format('Fix the %s rejected item(s) first.', v_left);
  end if;

  -- What changed goes back to the admin unreviewed.
  with gone as (delete from public.partner_review_items where partner_id = p.id and fixed_at is not null returning 1)
  select count(*) into v_fixed from gone;

  if p.registration_vehicle_id is not null then
    update public.vehicle set documents_ok = true
     where id = p.registration_vehicle_id and status::text in ('unapproved', 'unapproved-docs') and not documents_ok;
  end if;
  update public.partners
     set status = 'unapproved', resubmitted_at = now(), status_note = null, documents_ok = true, updated_at = now()
   where id = p.id;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'partner.review_resubmit', v_uid, jsonb_build_object('partner_id', p.id, 'fixed', v_fixed));

  -- The admins who review partners hear about it.
  v_who := coalesce(nullif(btrim(p.name), ''), p.phone, 'A driver');
  for r in
    select distinct a.profile_id from public.admin_access a
     where (a.page in ('*', 'admin-partners', 'admin-partner-edit') or a.page like 'admin-partners-%')
       and a.profile_id <> v_uid
  loop
    perform public.approval_push_send(r.profile_id,
      jsonb_build_object('title', 'Application sent again',
                         'body', v_who || ' made the changes you asked for. Open the review to check them.'),
      jsonb_build_object('type', 'partner_review', 'partner_id', p.id, 'for', 'admin'));
  end loop;
  return jsonb_build_object('fixed', v_fixed);
end;
$$;
revoke execute on function public.partner_review_resubmit() from public, anon;
grant execute on function public.partner_review_resubmit() to authenticated;

notify pgrst, 'reload schema';
insert into supabase_migrations.schema_migrations (version, name) values ('20261024190000', '0289_partner_application_review') on conflict do nothing;
