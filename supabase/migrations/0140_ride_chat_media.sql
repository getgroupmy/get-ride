-- ============================================================================
-- 0140: photos and voice notes in the rider ↔ driver chat
--
-- ride_messages (0129) took text, quick replies and locations. Two more kinds:
--
--   * 'image' — a photo from the gallery or the camera, with an optional
--     caption in `body`;
--   * 'audio' — a voice note, `media_duration` seconds long.
--
-- The file itself lives in the private `ride-chat-media` bucket under the
-- ride's folder (`<request_id>/<file>`), and the message carries its path in
-- `media_path`. Only the ride's rider and driver can read that folder, and
-- they can add to it only while the ride takes messages — the same rule the
-- messages themselves follow. The apps show a file through a short-lived
-- signed link, so a photo of someone's pickup is never at a public address.
-- ============================================================================

alter table public.ride_messages add column if not exists media_path text;
alter table public.ride_messages add column if not exists media_duration numeric;

alter table public.ride_messages drop constraint if exists ride_messages_type_check;
alter table public.ride_messages add constraint ride_messages_type_check
  check (type in ('text', 'quick', 'location', 'image', 'audio'));

-- A file must be in this ride's own folder; a voice note is at most 5 minutes.
alter table public.ride_messages drop constraint if exists ride_messages_content;
alter table public.ride_messages add constraint ride_messages_content check (coalesce(
  case type
    when 'location' then latitude between -90 and 90 and longitude between -180 and 180
                         and media_path is null
    when 'image' then starts_with(media_path, request_id::text || '/')
                      and char_length(media_path) <= 300
                      and (body is null or char_length(body) between 1 and 1000)
    when 'audio' then starts_with(media_path, request_id::text || '/')
                      and char_length(media_path) <= 300
                      and media_duration between 0 and 300
                      and body is null
    else char_length(btrim(body)) between 1 and 1000 and media_path is null
  end, false));

-- ---- Insert: as 0129, and an empty caption is no caption ----------------------
create or replace function public.ride_messages_before_insert()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.status := 'sent';
  new.created_at := now();
  if new.type in ('text', 'quick') then
    new.body := btrim(new.body);
  elsif new.type = 'image' then
    new.body := nullif(btrim(coalesce(new.body, '')), '');
  end if;
  if new.type = 'audio' and new.media_duration is not null then
    new.media_duration := round(new.media_duration, 1);
  end if;
  return new;
end;
$$;

revoke execute on function public.ride_messages_before_insert() from public, anon, authenticated;

-- ---- Update: as 0129, with the file fixed too ---------------------------------
create or replace function public.ride_messages_guard_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rider uuid;
  v_partner uuid;
  v_receiver uuid;
begin
  if (new.id, new.request_id, new.sender_id, new.sender_role, new.type, new.body,
      new.latitude, new.longitude, new.media_path, new.media_duration, new.created_at)
     is distinct from
     (old.id, old.request_id, old.sender_id, old.sender_role, old.type, old.body,
      old.latitude, old.longitude, old.media_path, old.media_duration, old.created_at) then
    raise exception 'only a message''s status can change' using errcode = '42501';
  end if;
  if array_position(array['sent', 'delivered', 'read'], new.status)
     < array_position(array['sent', 'delivered', 'read'], old.status) then
    raise exception 'a message''s status only moves forward' using errcode = '42501';
  end if;
  if new.status is not distinct from old.status or public.caller_is_admin() then
    return new;
  end if;
  select rider_id, partner_id into v_rider, v_partner from public.ride_requests where id = old.request_id;
  v_receiver := case old.sender_role when 'rider' then v_partner else v_rider end;
  if auth.uid() is null or auth.uid() is distinct from v_receiver then
    raise exception 'only the receiver can mark a message delivered or read' using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke execute on function public.ride_messages_guard_update() from public, anon, authenticated;

-- ---- What the notification says -----------------------------------------------
create or replace function public.ride_message_push_body(p_type text, p_body text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_type = 'location' then 'Shared a location'
    when p_type = 'audio' then 'Sent a voice note'
    when p_type = 'image' and btrim(coalesce(p_body, '')) = '' then 'Sent a photo'
    when p_type = 'image' and char_length(btrim(p_body)) > 150 then 'Photo: ' || left(btrim(p_body), 149) || '…'
    when p_type = 'image' then 'Photo: ' || btrim(p_body)
    when char_length(btrim(coalesce(p_body, ''))) > 160 then left(btrim(p_body), 159) || '…'
    else btrim(coalesce(p_body, ''))
  end;
$$;

-- ---- The files ------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ride-chat-media', 'ride-chat-media', false, 15728640, array['image/*', 'audio/*'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Whether the caller is the rider or the driver of the ride whose folder
-- [p_name] is in, and (with [p_open]) whether that ride takes messages now.
create or replace function public.ride_chat_media_allowed(p_name text, p_open boolean)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1 from public.ride_requests r
     where r.id::text = split_part(coalesce(p_name, ''), '/', 1)
       and (r.rider_id = auth.uid() or r.partner_id = auth.uid())
       and (not p_open or r.status in ('accepted', 'arrived', 'on_trip'))
  );
$$;

revoke execute on function public.ride_chat_media_allowed(text, boolean) from public, anon;
grant execute on function public.ride_chat_media_allowed(text, boolean) to authenticated;

drop policy if exists "ride chat media participant read" on storage.objects;
drop policy if exists "ride chat media participant upload" on storage.objects;
drop policy if exists "ride chat media admin delete" on storage.objects;

create policy "ride chat media participant read"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'ride-chat-media'
    and (public.ride_chat_media_allowed(name, false) or public.caller_is_admin())
  );

-- New files only (no update policy): a sent photo can't be swapped afterwards.
create policy "ride chat media participant upload"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'ride-chat-media'
    and public.ride_chat_media_allowed(name, true)
  );

create policy "ride chat media admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'ride-chat-media' and public.caller_is_admin());

notify pgrst, 'reload schema';
