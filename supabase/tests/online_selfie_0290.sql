-- ============================================================================
-- Regression test for migration 0290: the partner selfie check when going
-- online.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/online_selfie_0290.sql
--
-- The rule (new phone, watch list, random with its cap), phones only, the
-- check kept due on "Not now" and going online refused on the server while
-- it is, the live selfie in the partner's own folder, always online after
-- it, the low-match alert and its recipients, the admin's settings and the
-- watch list (caller_admin_can_write, audited), the lists and who reads them.
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000290a1'),  -- full admin
  ('00000000-0000-0000-0000-0000000290a2'),  -- sub-admin, EDIT on Edit Partner
  ('00000000-0000-0000-0000-0000000290a3'),  -- sub-admin, READ on Edit Partner
  ('00000000-0000-0000-0000-0000000290a4'),  -- sub-admin, EDIT on IP access only
  ('00000000-0000-0000-0000-0000000290a5'),  -- sub-admin, EDIT on Dispatch › Partner selfie checks
  ('00000000-0000-0000-0000-0000000290a6'),  -- sub-admin, Support
  ('00000000-0000-0000-0000-0000000290a7'),  -- sub-admin, READ on Documents
  ('00000000-0000-0000-0000-0000000290b1'),  -- the partner
  ('00000000-0000-0000-0000-0000000290b2'),  -- another partner
  ('00000000-0000-0000-0000-0000000290c1')   -- a rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000290%'
on conflict do nothing;
update public.profiles set name = 'Test Partner', id_image = 'https://x.test/storage/v1/object/public/ID_Image/b1/id.jpg'
 where id = '00000000-0000-0000-0000-0000000290b1';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000290a1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000290a2', 'admin-partner-edit', 'edit'),
  ('00000000-0000-0000-0000-0000000290a3', 'admin-partner-edit', 'read'),
  ('00000000-0000-0000-0000-0000000290a4', 'admin-settings-ip-access', 'edit'),
  ('00000000-0000-0000-0000-0000000290a5', 'admin-dispatch-selfie-checks', 'edit'),
  ('00000000-0000-0000-0000-0000000290a6', 'admin-support', 'edit'),
  ('00000000-0000-0000-0000-0000000290a7', 'admin-documents', 'read')
on conflict do nothing;
insert into public.partners (id, auth_user_id, name, phone, status, avatar_url) values
  ('00000000-0000-0000-0000-000000029001', '00000000-0000-0000-0000-0000000290b1', 'Test Partner', '+60110000290',
   'approved', 'https://x.test/storage/v1/object/public/avatars/b1/me.jpg'),
  ('00000000-0000-0000-0000-000000029002', '00000000-0000-0000-0000-0000000290b2', 'Other Partner', '+60110000291',
   'approved', null);
delete from public.app_settings where key = 'online_selfie';

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.as_server() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
declare n integer;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    return;
  end;
  if n > 0 then
    raise exception 'FAILED: % was allowed', p_what;
  end if;
end $$;
create or replace function pg_temp.raises(p_sql text, p_code text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm not like '%' || p_code || '%' then
      raise exception 'FAILED: % raised "%" instead of %', p_what, sqlerrm, p_code;
    end if;
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.as_server(), pg_temp.check(boolean, text),
  pg_temp.refused(text, text), pg_temp.raises(text, text, text) to authenticated;

-- 0. The rule, alone ----------------------------------------------------------------------------------
-- (new phone, roll watch, roll random, random on, %, random today, cap, watch rule, %, watch today, cap,
--  hours, hours since)
select pg_temp.check(public.online_selfie_pick(true, 0.99, 0.99, false, 0, 0, 1, null, null, 0, null, null, null) = 'new_device',
  'a new phone is always checked');
select pg_temp.check(public.online_selfie_pick(true, 0.0, 0.0, true, 100, 0, 1, 'every', null, 0, null, null, null) = 'new_device',
  'a new phone says new phone, before the watch list and random');
select pg_temp.check(public.online_selfie_pick(false, 0.99, 0.99, false, 0, 0, 1, 'every', null, 5, null, null, null) = 'watch_list',
  'watch list: every go-online');
select pg_temp.check(public.online_selfie_pick(false, 0.49, 0.99, false, 0, 2, 3, 'percent', 50, 2, 3, null, null) = 'watch_list',
  'watch list: 50% rolled under, two of three today');
select pg_temp.check(public.online_selfie_pick(false, 0.49, 0.99, false, 0, 0, 1, 'percent', 50, 3, 3, null, null) is null,
  'watch list: the daily cap is reached');
select pg_temp.check(public.online_selfie_pick(false, 0.51, 0.99, false, 0, 0, 1, 'percent', 50, 0, 3, null, null) is null,
  'watch list: 50% rolled over');
select pg_temp.check(public.online_selfie_pick(false, 0.99, 0.99, false, 0, 0, 1, 'hours', null, 0, null, 8, 8.5) = 'watch_list',
  'watch list: 8 hours online since the last check');
select pg_temp.check(public.online_selfie_pick(false, 0.99, 0.99, false, 0, 0, 1, 'hours', null, 0, null, 8, 2) is null,
  'watch list: only 2 hours online since the last check');
select pg_temp.check(public.online_selfie_pick(false, 0.99, 0.99, false, 0, 0, 1, 'hours', null, 0, null, 8, null) = 'watch_list',
  'watch list: hours rule, never checked yet');
select pg_temp.check(public.online_selfie_pick(false, 0.99, 0.19, true, 20, 0, 1, null, null, 0, null, null, null) = 'random',
  'random: 20% rolled under');
select pg_temp.check(public.online_selfie_pick(false, 0.99, 0.21, true, 20, 0, 1, null, null, 0, null, null, null) is null,
  'random: 20% rolled over');
select pg_temp.check(public.online_selfie_pick(false, 0.99, 0.01, true, 20, 1, 1, null, null, 0, null, null, null) is null,
  'random: once a day already');
select pg_temp.check(public.online_selfie_pick(false, 0.99, 0.01, false, 20, 0, 1, null, null, 0, null, null, null) is null,
  'random: switched off');
select pg_temp.check(public.online_selfie_pick(false, 0.0, 0.0, true, 0, 0, 1, null, null, 0, null, null, null) is null,
  'random: 0% never');
select pg_temp.check(public.online_selfie_pick(false, 0.99, 0.01, true, 20, 0, 1, 'percent', 50, 0, 3, null, null) = 'random',
  'a watch-list miss still rolls the random check');
select pg_temp.check(public.online_selfie_alert_text('Test Partner', 41.4, 'new_device') = 'Low selfie match: Test Partner, 41%, new phone',
  'the alert text');
select pg_temp.check(public.online_selfie_alert_text(null, 12, 'watch_list') = 'Low selfie match: A partner, 12%, watch list',
  'the alert text without a name');

-- Random off for the deterministic part.
insert into public.app_settings (key, value) values ('online_selfie', '{"randomOn": false}');

set local role authenticated;

-- 1. Phones only; the first phone is known; a new phone is checked ------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000290c1');
select pg_temp.check(public.online_selfie_check_start('phone-rider-0001', 'android', 'Test Phone')->>'due' = 'false',
  'a rider is never checked');
select pg_temp.as_user('00000000-0000-0000-0000-0000000290b1');
select pg_temp.check(public.online_selfie_check_start(null, 'web', null)->>'due' = 'false', 'the web is never checked');
select pg_temp.check(public.online_selfie_check_start('phone-first-0001', 'android', 'Test Phone A')->>'due' = 'false',
  'the first phone seen is known');
select pg_temp.check(public.online_selfie_check_start('phone-first-0001', 'android', 'Test Phone A')->>'due' = 'false',
  'the same phone again is not checked');
select pg_temp.check(public.online_selfie_check_start('phone-second-02', 'ios', 'Test Phone B')->>'reason' = 'new_device',
  'a new phone is checked');
select pg_temp.check((select reason = 'new_device' and state = 'due' and device_model = 'Test Phone B' and platform = 'ios'
                        from public.partner_online_checks where user_id = auth.uid()),
  'the check is kept with the reason, the phone and its model');
select pg_temp.check(
  (public.online_selfie_check_start('phone-second-02', 'ios', null)->>'id')
    = (select id::text from public.partner_online_checks where user_id = auth.uid() and state = 'due'),
  'asking again gives the same check');
select pg_temp.check((public.online_selfie_check_start('phone-second-02', 'ios', null)->>'answer_seconds')::integer = 180,
  'three minutes to answer by default');
select pg_temp.check((public.online_selfie_check_start(null, 'desktop', null)->>'blocked')::boolean,
  'a desktop, while the phone''s check is due, is told to finish it on the phone');

-- 2. "Not now" keeps it due, and the server keeps them offline -------------------------------------------
select public.online_selfie_check_skip((select id from public.partner_online_checks where user_id = auth.uid()), 'not_now');
select pg_temp.check((select skips = 1 and last_skip = 'not_now' and state = 'due'
                        from public.partner_online_checks where user_id = auth.uid()), 'Not now is kept, still due');
select public.set_driver_presence(true, 3.1579, 101.7116);
select pg_temp.check((select not online from public.driver_presence where profile_id = auth.uid()),
  'going online is refused while a check is due');
select pg_temp.refused($q$update public.partner_online_checks set state = 'answered' where user_id = auth.uid()$q$,
  'the partner answering their own check by hand');

-- 3. The selfie: their own folder, live only; then online whatever the match ------------------------------
select pg_temp.raises($q$select public.online_selfie_check_submit(
  (select id from public.partner_online_checks where user_id = auth.uid() and state = 'due'),
  '{"file_url": "https://x.test/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-0000000290b2/s.jpg", "liveness": "passed"}')$q$,
  'IDENTITY_FILE', 'a selfie from someone else''s folder');
select pg_temp.raises($q$select public.online_selfie_check_submit(
  (select id from public.partner_online_checks where user_id = auth.uid() and state = 'due'),
  '{"file_url": "https://x.test/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-0000000290b1/s.jpg", "liveness": "not_checked"}')$q$,
  'ONLINE_SELFIE_LIVE', 'a selfie without the live check');
select pg_temp.as_user('00000000-0000-0000-0000-0000000290b2');
select pg_temp.raises($q$select public.online_selfie_check_submit(
  (select id from public.partner_online_checks where user_id = '00000000-0000-0000-0000-0000000290b1'),
  '{"file_url": "https://x.test/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-0000000290b2/s.jpg", "liveness": "passed"}')$q$,
  'ONLINE_SELFIE_NOT_FOUND', 'answering someone else''s check');
select pg_temp.as_user('00000000-0000-0000-0000-0000000290b1');
select pg_temp.check(public.online_selfie_check_submit(
  (select id from public.partner_online_checks where user_id = auth.uid() and state = 'due'),
  '{"file_url": "https://x.test/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-0000000290b1/s.jpg",
    "liveness": "passed", "liveness_detail": "blink", "model": "Test Phone B2"}')->>'state' = 'answered',
  'the live selfie answers the check');
select pg_temp.check((select state = 'answered' and liveness = 'passed' and liveness_detail = 'blink'
                             and device_model = 'Test Phone B2'
                             and face_state = 'not_checked' and face_reason = 'not_sent'
                        from public.partner_online_checks where user_id = auth.uid()),
  'answered; with no face server reachable it is kept as not checked');
select public.set_driver_presence(true, 3.1579, 101.7116);
select pg_temp.check((select online from public.driver_presence where profile_id = auth.uid()),
  'online once the selfie is in');
select pg_temp.check(public.online_selfie_check_start('phone-second-02', 'ios', null)->>'due' = 'false',
  'the phone the selfie was taken on is known now');
select pg_temp.check((select count(*) = 0 from public.partner_selfie_watch), 'the partner never reads the watch list');
select pg_temp.check((select count(*) = 1 from public.partner_online_checks), 'the partner reads their own checks only');
select pg_temp.refused($q$select public.online_selfie_checks_list('all')$q$, 'a partner listing the checks');

-- 4. Too late ------------------------------------------------------------------------------------------------
select pg_temp.check(public.online_selfie_check_start('phone-third-003', 'android', null)->>'reason' = 'new_device',
  'a third phone is checked');
reset role;
update public.partner_online_checks set answer_by = now() - interval '2 minutes'
 where user_id = '00000000-0000-0000-0000-0000000290b1' and state = 'due';
set local role authenticated;
select pg_temp.raises($q$select public.online_selfie_check_submit(
  (select id from public.partner_online_checks where user_id = auth.uid() and state = 'due'),
  '{"file_url": "https://x.test/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-0000000290b1/t.jpg", "liveness": "passed"}')$q$,
  'ONLINE_SELFIE_LATE', 'a selfie after the time ran out');
select pg_temp.check(public.online_selfie_check_start('phone-third-003', 'android', null)->>'due' = 'true',
  'going online again asks the same check, with fresh time');
select pg_temp.check((select answer_by > now() from public.partner_online_checks where user_id = auth.uid() and state = 'due'),
  'the time to answer starts again');
-- A day later it lapses and holds nobody.
reset role;
update public.partner_online_checks set created_at = now() - interval '2 days'
 where user_id = '00000000-0000-0000-0000-0000000290b1' and state = 'due';
update public.driver_presence set online = true where profile_id = '00000000-0000-0000-0000-0000000290b1';
select pg_temp.check((select online from public.driver_presence where profile_id = '00000000-0000-0000-0000-0000000290b1'),
  'a check older than a day holds nobody');
set local role authenticated;
select public.online_selfie_check_start(null, 'web', null);
select pg_temp.check((select state = 'lapsed' from public.partner_online_checks where device_key = 'phone-third-003'),
  'the old check lapses');

-- 5. The admin's settings -------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000290a3');
select pg_temp.refused($q$select public.online_selfie_set_config('{"randomPct": 50}')$q$, 'a read-only sub-admin');
select pg_temp.as_user('00000000-0000-0000-0000-0000000290a4');
select pg_temp.refused($q$select public.online_selfie_set_config('{"randomPct": 50}')$q$, 'an IP-access sub-admin');
select pg_temp.refused($q$select public.online_selfie_config()$q$, 'an IP-access sub-admin reading the settings');
select pg_temp.as_user('00000000-0000-0000-0000-0000000290a5');
select pg_temp.raises($q$select public.online_selfie_set_config('{"randomPct": 150}')$q$, 'ONLINE_SELFIE_PCT', 'a 150% chance');
select pg_temp.raises($q$select public.online_selfie_set_config('{"lowBelow": 0}')$q$, 'ONLINE_SELFIE_LOW', 'a 0% threshold');
select pg_temp.raises($q$select public.online_selfie_set_config('{"answerSeconds": 5}')$q$, 'ONLINE_SELFIE_TIME', '5 seconds to answer');
select pg_temp.raises($q$select public.online_selfie_set_config('{"alertTo": "selected", "alertAdmins": []}')$q$,
  'ONLINE_SELFIE_NO_ADMINS', 'selected admins with nobody picked');
select pg_temp.check(public.online_selfie_set_config(
  '{"randomOn": true, "randomPct": 100, "randomCap": 1, "lowBelow": 70, "answerSeconds": 120}')->>'lowBelow' = '70',
  'the selfie-checks sub-admin sets the settings');
select pg_temp.check((select (value->>'randomPct')::int = 100 and (value->>'randomOn')::boolean
                        from public.app_settings where key = 'online_selfie'), 'kept in app_settings');
select pg_temp.check(public.online_selfie_set_config(
  '{"alertTo": "selected", "alertAdmins": ["00000000-0000-0000-0000-0000000290a2", "00000000-0000-0000-0000-0000000290c1"]}')
  -> 'alertAdmins' = '["00000000-0000-0000-0000-0000000290a2"]'::jsonb,
  'only admins are kept as alert recipients');

-- 6. Random: the chance and the daily cap -------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000290b2');
select pg_temp.check(public.online_selfie_check_start('other-phone-001', 'android', null)->>'reason' = 'random',
  'random at 100%');
select pg_temp.check((public.online_selfie_check_start('other-phone-001', 'android', null)->>'answer_seconds')::int = 120,
  'the admin''s time to answer');
select public.online_selfie_check_submit(
  (select id from public.partner_online_checks where user_id = auth.uid() and state = 'due'),
  '{"file_url": "https://x.test/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-0000000290b2/r.jpg", "liveness": "passed"}');
select pg_temp.check(public.online_selfie_check_start('other-phone-001', 'android', null)->>'due' = 'false',
  'at most once a day');

-- 7. The face match is kept; a low one alerts the chosen admins ---------------------------------------------
reset role;
select pg_temp.as_server();
select pg_temp.check(public.online_selfie_face_source(
  (select id from public.partner_online_checks where user_id = '00000000-0000-0000-0000-0000000290b1' and state = 'answered'))
  = jsonb_build_object('user_id', '00000000-0000-0000-0000-0000000290b1',
      'selfie_url', 'https://x.test/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-0000000290b1/s.jpg',
      'photo_url', 'https://x.test/storage/v1/object/public/avatars/b1/me.jpg',
      'id_url', 'https://x.test/storage/v1/object/public/ID_Image/b1/id.jpg'),
  'compared with the partner''s profile photo and ID photo');
select pg_temp.check(
  (select count(*) = 1 from public.online_selfie_alert_recipients('00000000-0000-0000-0000-0000000290b1') r
    where r = '00000000-0000-0000-0000-0000000290a2'),
  'selected: the picked admin only');
update public.app_settings set value = value || '{"alertTo": "support"}' where key = 'online_selfie';
select pg_temp.check(
  (select array_agg(r) = array['00000000-0000-0000-0000-0000000290a6'::uuid]
     from public.online_selfie_alert_recipients('00000000-0000-0000-0000-0000000290b1') r),
  'support: everyone with the Support role');
update public.app_settings set value = value || '{"alertTo": "all"}' where key = 'online_selfie';
select pg_temp.check(
  (select array_agg(r order by r) = array['00000000-0000-0000-0000-0000000290a1'::uuid, '00000000-0000-0000-0000-0000000290a7'::uuid]
     from public.online_selfie_alert_recipients('00000000-0000-0000-0000-0000000290b1') r),
  'all: every admin who sees Documents');
select pg_temp.check(public.online_selfie_check_store(
  (select id from public.partner_online_checks where user_id = '00000000-0000-0000-0000-0000000290b1' and state = 'answered'),
  '{"state": "no_match", "score": 41, "provider": "aws", "photo": {"state": "no_match", "score": 41},
    "id": {"state": "no_match", "score": 30}}')->>'low_match' = 'true',
  '41% under 70% is a low match');
select pg_temp.check((select low_match and alerted_at is not null and alert_sent = 2 and photo_score = 41 and id_score = 30
                             and face_provider = 'aws'
                        from public.partner_online_checks
                       where user_id = '00000000-0000-0000-0000-0000000290b1' and state = 'answered'),
  'the alert went to the two Documents admins, once');
select pg_temp.check(public.online_selfie_check_store(
  (select id from public.partner_online_checks where user_id = '00000000-0000-0000-0000-0000000290b2' and state = 'answered'),
  '{"state": "match", "score": 92.5, "provider": "self_hosted"}')->>'low_match' = 'false',
  '92.5% is a good match');
select pg_temp.check((select alerted_at is null from public.partner_online_checks
                       where user_id = '00000000-0000-0000-0000-0000000290b2' and state = 'answered'),
  'no alert on a good match');
select pg_temp.as_user('00000000-0000-0000-0000-0000000290b1');
set local role authenticated;
select pg_temp.refused($q$select public.online_selfie_check_store(
  (select id from public.partner_online_checks where user_id = auth.uid() and state = 'answered'), '{"state": "match", "score": 99}')$q$,
  'the partner storing their own score');

-- 8. The lists: low matches first, "Needs a closer look" ------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000290c1');
select pg_temp.refused($q$select public.online_selfie_checks_list('all')$q$, 'a rider listing the checks');
select pg_temp.as_user('00000000-0000-0000-0000-0000000290a6');
select pg_temp.check((public.online_selfie_checks_list('all')->0->>'closer')::boolean
                     and public.online_selfie_checks_list('all')->0->>'name' = 'Test Partner',
  'the low match comes first, needing a closer look');
select pg_temp.check(jsonb_array_length(public.online_selfie_checks_list('closer')) = 1, 'one needs a closer look');
select pg_temp.check(public.online_selfie_closer_count() = 1, 'the count');
select pg_temp.check(public.online_selfie_checks_list('all')->0->>'device_key' is null, 'the device key stays on the server');
select pg_temp.check(public.online_selfie_check_get(
  (select id from public.partner_online_checks where user_id = '00000000-0000-0000-0000-0000000290b1' and state = 'answered'))
  ->>'photo_url' = 'https://x.test/storage/v1/object/public/avatars/b1/me.jpg', 'the alert''s page has the photos');
select pg_temp.as_user('00000000-0000-0000-0000-0000000290a3');
select pg_temp.refused($q$select public.online_selfie_check_review(
  (select id from public.partner_online_checks where low_match limit 1), 'fine')$q$, 'a read-only sub-admin looking at it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000290a6');
select pg_temp.check((public.online_selfie_check_review(
  (select id from public.partner_online_checks where low_match limit 1), 'Called them, it is them')->>'closer')::boolean = false,
  'Support marks it looked at');
select pg_temp.check(public.online_selfie_closer_count() = 0, 'nothing left to look at');

-- 9. The watch list ----------------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000290a3');
select pg_temp.refused($q$select public.online_selfie_watch_set('00000000-0000-0000-0000-0000000290b1', 'every',
  p_reason => 'Reported by a rider')$q$, 'a read-only sub-admin adding to the watch list');
select pg_temp.as_user('00000000-0000-0000-0000-0000000290a4');
select pg_temp.refused($q$select public.online_selfie_watch_set('00000000-0000-0000-0000-0000000290b1', 'every',
  p_reason => 'Reported by a rider')$q$, 'an IP-access sub-admin adding to the watch list');
select pg_temp.as_user('00000000-0000-0000-0000-0000000290a2');
select pg_temp.raises($q$select public.online_selfie_watch_set('00000000-0000-0000-0000-0000000290b1', 'every')$q$,
  'ONLINE_SELFIE_REASON', 'no reason');
select pg_temp.raises($q$select public.online_selfie_watch_set('00000000-0000-0000-0000-0000000290c1', 'every',
  p_reason => 'x')$q$, 'ONLINE_SELFIE_NOT_PARTNER', 'a rider on the watch list');
select pg_temp.raises($q$select public.online_selfie_watch_set('00000000-0000-0000-0000-0000000290b1', 'percent', 150, 3,
  p_reason => 'x')$q$, 'ONLINE_SELFIE_PCT', '150%');
select pg_temp.raises($q$select public.online_selfie_watch_set('00000000-0000-0000-0000-0000000290b1', 'every',
  p_until => current_date - 1, p_reason => 'x')$q$, 'ONLINE_SELFIE_UNTIL', 'an end date in the past');
select pg_temp.check(public.online_selfie_watch_set('00000000-0000-0000-0000-0000000290b1', 'every',
  p_until => current_date + 30, p_reason => 'Reported by a rider: different driver at pickup',
  p_check => (select id from public.partner_online_checks where low_match limit 1))->>'rule' = 'every',
  'Edit Partner puts them on the watch list');
select pg_temp.check(public.online_selfie_watch_set('00000000-0000-0000-0000-0000000290b1', 'percent', 50, 3,
  p_reason => 'Two low matches this week')->>'pct' = '50', 'and changes the rule');
select pg_temp.check((select from_check is not null and rule = 'percent' and until is null and hours is null
                        from public.partner_selfie_watch where profile_id = '00000000-0000-0000-0000-0000000290b1'),
  'the change keeps where it was set from');
select pg_temp.check(jsonb_array_length(public.online_selfie_watch_list()) = 1, 'the watch list');
select pg_temp.check(public.online_selfie_person('00000000-0000-0000-0000-0000000290b1')->'watch'->>'reason'
  = 'Two low matches this week', 'Edit Partner reads the entry');
select pg_temp.check(jsonb_array_length(public.online_selfie_person('00000000-0000-0000-0000-0000000290b1')->'checks') = 2,
  'Edit Partner reads their recent checks');
select pg_temp.check(public.online_selfie_watch_set('00000000-0000-0000-0000-0000000290b1', 'every',
  p_reason => 'Reported by a rider')->>'rule' = 'every', 'back to every go-online');
-- Watched: checked every time, told it is a random check.
select pg_temp.as_user('00000000-0000-0000-0000-0000000290b1');
select pg_temp.check(public.online_selfie_check_start('phone-second-02', 'ios', null)->>'reason' = 'random',
  'a watched partner is checked, and told it is random');
select pg_temp.check((select reason = 'watch_list' from public.partner_online_checks where user_id = auth.uid() and state = 'due'),
  'kept as a watch-list check');
select pg_temp.as_user('00000000-0000-0000-0000-0000000290a2');
select pg_temp.check(public.online_selfie_watch_remove('00000000-0000-0000-0000-0000000290b1'), 'removed');
select pg_temp.check(not public.online_selfie_watch_remove('00000000-0000-0000-0000-0000000290b1'), 'nothing left to remove');
reset role;
select pg_temp.check((select array_agg(action order by created_at, action) @> array['online_selfie.watch_add',
                        'online_selfie.watch_change', 'online_selfie.watch_remove']
                        from public.admin_audit_log
                       where target_profile_id = '00000000-0000-0000-0000-0000000290b1'),
  'every watch-list change is in the audit log');
select pg_temp.check((select count(*) >= 1 from public.admin_audit_log where action = 'online_selfie.config'),
  'the settings change is in the audit log');
select pg_temp.check((select count(*) = 1 from public.admin_audit_log where action = 'online_selfie.review'),
  'looking at a check is in the audit log');

-- 10. Grants ---------------------------------------------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('authenticated', 'public.online_selfie_check_store(uuid, jsonb)', 'execute'),
  'only the server stores a score');
select pg_temp.check(not has_function_privilege('authenticated', 'public.online_selfie_face_source(uuid)', 'execute'),
  'only the server reads the photos to compare');
select pg_temp.check(not has_function_privilege('anon', 'public.online_selfie_check_start(text, text, text)', 'execute'),
  'anon never starts a check');
select pg_temp.check(not has_function_privilege('authenticated', 'public.online_selfie_alert(uuid)', 'execute'),
  'nobody sends the alert by hand');

select 'online_selfie_0290: all passed';
rollback;
