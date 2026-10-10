-- ============================================================================
-- Regression test for migration 0140: photos and voice notes in the ride
-- chat. A file sits in the ride's own folder of the private ride-chat-media
-- bucket, which only that ride's two participants can read, and add to only
-- while the ride takes messages.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_chat_media.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================

do $$
begin
  if public.ride_message_push_body('audio', null) <> 'Sent a voice note'
     or public.ride_message_push_body('image', null) <> 'Sent a photo'
     or public.ride_message_push_body('image', ' Gate B ') <> 'Photo: Gate B'
     or public.ride_message_push_body('text', 'Hi') <> 'Hi' then
    raise exception 'FAILED: the push lines for photos and voice notes';
  end if;
  if (select public from storage.buckets where id = 'ride-chat-media') is distinct from false then
    raise exception 'FAILED: ride-chat-media must exist and be private';
  end if;
  if has_function_privilege('anon', 'public.ride_chat_media_allowed(text, boolean)', 'execute') then
    raise exception 'FAILED: anon must not call ride_chat_media_allowed';
  end if;
end
$$;

begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000140a1'),  -- rider
  ('00000000-0000-0000-0000-0000000140b1'),  -- driver
  ('00000000-0000-0000-0000-0000000140c1')   -- somebody else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000140%'
on conflict do nothing;

insert into public.ride_requests (id, rider_id, partner_id, status) values
  ('00000000-0000-0000-0000-0000000140d1', '00000000-0000-0000-0000-0000000140a1', '00000000-0000-0000-0000-0000000140b1', 'on_trip'),
  ('00000000-0000-0000-0000-0000000140d2', '00000000-0000-0000-0000-0000000140a1', '00000000-0000-0000-0000-0000000140b1', 'completed');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated;

set local role authenticated;

-- 1. Who may read and add files ----------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000140a1');
select pg_temp.check(public.ride_chat_media_allowed('00000000-0000-0000-0000-0000000140d1/a.jpg', true),
  'the rider adds to a running ride''s folder');
select pg_temp.check(not public.ride_chat_media_allowed('00000000-0000-0000-0000-0000000140d2/a.jpg', true),
  'nothing new goes into a finished ride''s folder');
select pg_temp.check(public.ride_chat_media_allowed('00000000-0000-0000-0000-0000000140d2/a.jpg', false),
  'a finished ride''s files stay readable to its rider');
select pg_temp.check(not public.ride_chat_media_allowed('a.jpg', false), 'a file outside any ride folder');

select pg_temp.as_user('00000000-0000-0000-0000-0000000140b1');
select pg_temp.check(public.ride_chat_media_allowed('00000000-0000-0000-0000-0000000140d1/v.m4a', true),
  'the driver adds to a running ride''s folder');

select pg_temp.as_user('00000000-0000-0000-0000-0000000140c1');
select pg_temp.check(not public.ride_chat_media_allowed('00000000-0000-0000-0000-0000000140d1/a.jpg', false),
  'an outsider reads nothing');

-- 2. Photo and voice-note messages ------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000140a1');
insert into public.ride_messages (id, request_id, sender_role, type, body, media_path) values
  ('00000000-0000-0000-0000-0000000140e1', '00000000-0000-0000-0000-0000000140d1', 'rider', 'image', '   ',
   '00000000-0000-0000-0000-0000000140d1/photo.jpg');
select pg_temp.check((select body is null from public.ride_messages where id = '00000000-0000-0000-0000-0000000140e1'),
  'an empty caption is stored as none');

select pg_temp.as_user('00000000-0000-0000-0000-0000000140b1');
insert into public.ride_messages (id, request_id, sender_role, type, media_path, media_duration) values
  ('00000000-0000-0000-0000-0000000140e2', '00000000-0000-0000-0000-0000000140d1', 'partner', 'audio',
   '00000000-0000-0000-0000-0000000140d1/note.m4a', 7.26);
select pg_temp.check((select media_duration = 7.3 from public.ride_messages where id = '00000000-0000-0000-0000-0000000140e2'),
  'a voice note''s length is kept to a tenth of a second');

select pg_temp.refused(
  $q$insert into public.ride_messages (request_id, sender_role, type, media_path)
     values ('00000000-0000-0000-0000-0000000140d1', 'partner', 'image', '00000000-0000-0000-0000-0000000140d2/x.jpg')$q$,
  'a photo from another ride''s folder');
select pg_temp.refused(
  $q$insert into public.ride_messages (request_id, sender_role, type)
     values ('00000000-0000-0000-0000-0000000140d1', 'partner', 'image')$q$,
  'a photo without a file');
select pg_temp.refused(
  $q$insert into public.ride_messages (request_id, sender_role, type, media_path, media_duration)
     values ('00000000-0000-0000-0000-0000000140d1', 'partner', 'audio', '00000000-0000-0000-0000-0000000140d1/n.m4a', 900)$q$,
  'a voice note over five minutes');
select pg_temp.refused(
  $q$insert into public.ride_messages (request_id, sender_role, type, body, media_path)
     values ('00000000-0000-0000-0000-0000000140d1', 'partner', 'text', 'hi', '00000000-0000-0000-0000-0000000140d1/n.m4a')$q$,
  'a text message carrying a file');

-- 3. The receiver ticks it; nobody swaps the file ---------------------------
update public.ride_messages set status = 'read' where id = '00000000-0000-0000-0000-0000000140e1';
select pg_temp.check((select status = 'read' from public.ride_messages where id = '00000000-0000-0000-0000-0000000140e1'),
  'the driver marks the rider''s photo read');
reset role;
select pg_temp.refused(
  $q$update public.ride_messages set media_path = '00000000-0000-0000-0000-0000000140d1/other.jpg'
      where id = '00000000-0000-0000-0000-0000000140e1'$q$,
  'swapping a sent photo');

select 'ride_chat_media: all passed';
rollback;
