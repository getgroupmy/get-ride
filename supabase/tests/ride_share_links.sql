-- ============================================================================
-- Regression test for migration 0108: a ride shared by link.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_share_links.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000008a1'),  -- rider
  ('00000000-0000-0000-0000-0000000008a2')   -- somebody else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000008%'
on conflict do nothing;

insert into public.ride_requests
  (id, rider_id, rider_name, rider_phone, status, otp, partner_name, partner_phone, partner_plate,
   booked_for_name, booked_for_phone, pickup_name, drop_name)
values
  ('00000000-0000-0000-0000-0000000008c1', '00000000-0000-0000-0000-0000000008a1', 'Ali Bakar', '+60111',
   'accepted', '4321', 'Siti', '+60222', 'WXY 1', null, null, 'KLCC', 'KL Sentral'),
  ('00000000-0000-0000-0000-0000000008c2', '00000000-0000-0000-0000-0000000008a1', 'Ali Bakar', '+60111',
   'arrived', '8765', 'Siti', '+60222', 'WXY 1', 'Mak Esah', '+60123456789', 'KLCC', 'Bangsar');

create temp table t_tokens (ride uuid, token uuid);
grant select, insert on t_tokens to authenticated, anon;

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
grant execute on function pg_temp.refused(text, text) to authenticated, anon;

-- 1. Only the rider makes a link, and asking twice gives the same one --------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000008a2');
select pg_temp.refused(
  $q$select public.ride_share_link('00000000-0000-0000-0000-0000000008c1')$q$,
  'sharing somebody else''s ride');

select pg_temp.as_user('00000000-0000-0000-0000-0000000008a1');
insert into t_tokens values
  ('00000000-0000-0000-0000-0000000008c1', public.ride_share_link('00000000-0000-0000-0000-0000000008c1')),
  ('00000000-0000-0000-0000-0000000008c2', public.ride_share_link('00000000-0000-0000-0000-0000000008c2'));
do $$
begin
  if public.ride_share_link('00000000-0000-0000-0000-0000000008c1')
       is distinct from (select token from t_tokens where ride = '00000000-0000-0000-0000-0000000008c1') then
    raise exception 'FAILED: a second share made a new link';
  end if;
end $$;

-- 2. Anyone with the link sees the ride, without a phone number --------------
reset role;
set local role anon;
do $$
declare
  v jsonb := public.ride_share_view((select token from t_tokens where ride = '00000000-0000-0000-0000-0000000008c1'));
begin
  if v is null or v->>'partner_plate' <> 'WXY 1' or v->>'drop_name' <> 'KL Sentral' or v->>'passenger' <> 'Ali' then
    raise exception 'FAILED: the shared view is wrong: %', v;
  end if;
  if v::text like '%+60%' then
    raise exception 'FAILED: a phone number is in the shared view: %', v;
  end if;
  if v ? 'otp' and v->>'otp' is not null then
    raise exception 'FAILED: the rider''s own trip code is in the shared view';
  end if;
end $$;

-- 3. A ride for someone else carries its trip code until pickup --------------
do $$
declare
  v jsonb := public.ride_share_view((select token from t_tokens where ride = '00000000-0000-0000-0000-0000000008c2'));
begin
  if v->>'otp' is distinct from '8765' or v->>'passenger' <> 'Mak' then
    raise exception 'FAILED: the passenger''s view is wrong: %', v;
  end if;
end $$;

-- 4. A wrong token, or a long-finished ride, shows nothing ------------------
do $$
begin
  if public.ride_share_view(gen_random_uuid()) is not null or public.ride_share_view(null) is not null then
    raise exception 'FAILED: an unknown link showed a ride';
  end if;
end $$;
reset role;
update public.ride_requests set status = 'completed', updated_at = now() - interval '2 days'
 where id = '00000000-0000-0000-0000-0000000008c1';
-- updated_at is stamped by a trigger; put it back in the past.
alter table public.ride_requests disable trigger user;
update public.ride_requests set updated_at = now() - interval '2 days'
 where id = '00000000-0000-0000-0000-0000000008c1';
alter table public.ride_requests enable trigger user;
set local role anon;
do $$
begin
  if public.ride_share_view((select token from t_tokens where ride = '00000000-0000-0000-0000-0000000008c1')) is not null then
    raise exception 'FAILED: a ride finished two days ago is still shared';
  end if;
end $$;

-- 5. Anon can read a shared ride but cannot make links -----------------------
do $$
begin
  if has_function_privilege('anon', 'public.ride_share_link(uuid)', 'execute') then
    raise exception 'FAILED: anon can make share links';
  end if;
end $$;

reset role;
select 'ride_share_links: all passed';
rollback;
