-- ============================================================================
-- Regression test for migration 0323: the GET.Plus family plan and God
-- View's "GET.Plus only".
--   0. plus_holder is the server's own; the registry row is a real module,
--      its matrix row OFF;
--   1. a host's membership covers a member only where Family's matrix has
--      the 'get_plus' "Family pays" box on for that place (the app's terms
--      say so, the request is stamped);
--   2. free cancels are the family's: counted on the host's membership,
--      shared, not multiplied per member;
--   3. a member who leaves loses the cover at once;
--   4. Busy areas set to "GET.Plus": shown to a member and a covered member,
--      not to others.
-- All names, numbers and places are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/plus_family_live_map_0323.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if to_regclass('public.permit_country_settings') is not null then
    execute 'update public.permit_country_settings set enforce = false';
  end if;
end
$$;
insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000323a1'),  -- family host, GET.Plus member
  ('00000000-0000-0000-0000-0000000323a2'),  -- family member, no membership of their own
  ('00000000-0000-0000-0000-0000000323a3'),  -- GET.Plus member, no family
  ('00000000-0000-0000-0000-0000000323a4')   -- nobody: no family, no membership
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000323a1', 'Hana Contoh', '+60100323001'),
  ('00000000-0000-0000-0000-0000000323a2', 'Amir Contoh', '+60100323002'),
  ('00000000-0000-0000-0000-0000000323a3', 'Plus Sample', '+60100323003'),
  ('00000000-0000-0000-0000-0000000323a4', 'Other Sample', '+60100323004')
on conflict (id) do update set name = excluded.name, phone = excluded.phone;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
-- What the rider live map's config says about Busy areas for [p] here.
create or replace function pg_temp.busy_on(p uuid) returns boolean language plpgsql as $$
declare
  v boolean;
begin
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p);
  v := (public.rider_live_map_config('{"country": "Testland 323"}')->'busy'->>'on')::boolean;
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
  return v;
end $$;
-- [p]'s GET.Plus terms in Testland 323, as the app reads them.
create or replace function pg_temp.terms(p uuid) returns jsonb language plpgsql as $$
declare
  v jsonb;
begin
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p);
  v := public.premium_plus_terms(null, null, 'Testland 323', null, null);
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
  return v;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text) to authenticated;
create temporary table t_ids (k text primary key, id uuid);
grant all on t_ids to authenticated;

-- ---- 0. Grants and the registry -----------------------------------------------------------------
select pg_temp.check(not has_function_privilege('authenticated', 'public.plus_holder(uuid, jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.plus_holder(uuid, jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.plus_benefits(uuid, text, text, text, text)', 'execute'),
  'whose membership holds is the server''s own');
select pg_temp.check((select name = 'GET.Plus' and description like '%covers family members%'
                        from public.booking_modules where key = 'get_plus'), 'GET.Plus is a real module');
select pg_temp.check(not (public.family_module_rule_at('get_plus', '{"country": "Testland 323"}')->>'familyPays')::boolean,
  'the matrix row starts off');

-- ---- Setup: GET.Plus on in two places, memberships, a family ------------------------------------
insert into public.premium_plus_places (level, country, rules) values
  ('country', 'Testland 323', '{"plusOn": true, "plusDiscountPct": 10, "plusFreeCancels": 2, "plusPriority": true}'),
  ('country', 'Otherland 323', '{"plusOn": true, "plusDiscountPct": 10, "plusFreeCancels": 2}');
insert into public.plus_memberships (rider_id, status, auto_renew, period_start, period_end, country, month_price)
values ('00000000-0000-0000-0000-0000000323a1', 'active', true, now(), now() + interval '30 days', 'Testland 323', 9.9),
       ('00000000-0000-0000-0000-0000000323a3', 'active', true, now(), now() + interval '30 days', 'Testland 323', 9.9);

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000323a1');
insert into t_ids select 'm', (public.family_invite('{"country": "Testland 323"}', '+60100323002', 'Amir')->>'id')::uuid;
select pg_temp.as_user('00000000-0000-0000-0000-0000000323a2');
select pg_temp.check((public.family_my_invites()->0->'modules') is not null
  and not ((public.family_my_invites()->0->'modules') ? 'GET.Plus'),
  'the invite doesn''t list GET.Plus while the matrix box is off');
reset role;

-- ---- 1. Covered only where the matrix box is on -------------------------------------------------
select pg_temp.check(public.plus_benefits('00000000-0000-0000-0000-0000000323a2', 'Testland 323', null, null, null) is null
  and public.plus_holder('00000000-0000-0000-0000-0000000323a2', '{"country": "Testland 323"}') is null,
  'an invited member is not covered');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000323a2');
select public.family_respond((select id from t_ids where k = 'm'), true, '{"shown": ["payments"]}');
reset role;
select pg_temp.check(public.plus_benefits('00000000-0000-0000-0000-0000000323a2', 'Testland 323', null, null, null) is null,
  'a member is not covered while the box is off');
insert into public.family_module_rules (level, country, module_key, family_pays)
values ('country', 'Testland 323', 'get_plus', true);
select pg_temp.check((public.plus_benefits('00000000-0000-0000-0000-0000000323a2', 'Testland 323', null, null, null)->>'family')::boolean
  and public.plus_benefits('00000000-0000-0000-0000-0000000323a2', 'Testland 323', null, null, null)->>'hostName' = 'Hana Contoh'
  and (public.plus_benefits('00000000-0000-0000-0000-0000000323a2', 'Testland 323', null, null, null)->>'pct')::numeric = 10,
  'with the box on, the host''s membership covers the member');
select pg_temp.check(public.plus_benefits('00000000-0000-0000-0000-0000000323a2', 'Otherland 323', null, null, null) is null
  and public.plus_benefits('00000000-0000-0000-0000-0000000323a1', 'Otherland 323', null, null, null) is not null,
  'only where the box is on: elsewhere the host is a member and the member is not covered');
select pg_temp.check(not (public.plus_benefits('00000000-0000-0000-0000-0000000323a1', 'Testland 323', null, null, null)->>'family')::boolean
  and not (public.plus_benefits('00000000-0000-0000-0000-0000000323a1', 'Testland 323', null, null, null) ? 'hostName'),
  'the host''s own benefits are their own');
select pg_temp.check((pg_temp.terms('00000000-0000-0000-0000-0000000323a2')->'benefits'->>'family')::boolean
  and pg_temp.terms('00000000-0000-0000-0000-0000000323a2')->'membership' = 'null'::jsonb,
  'the app reads "covered by the family plan", with no membership of their own');
insert into public.ride_requests (id, rider_id, status, fare, ride_fare, payment_mode, country) values
  ('00000000-0000-0000-0000-0000000323f1', '00000000-0000-0000-0000-0000000323a2', 'open', 20, 20, 'Cash', 'Testland 323'),
  ('00000000-0000-0000-0000-0000000323f2', '00000000-0000-0000-0000-0000000323a2', 'open', 20, 20, 'Cash', 'Testland 323'),
  ('00000000-0000-0000-0000-0000000323f3', '00000000-0000-0000-0000-0000000323a1', 'open', 20, 20, 'Cash', 'Testland 323'),
  ('00000000-0000-0000-0000-0000000323f4', '00000000-0000-0000-0000-0000000323a4', 'open', 20, 20, 'Cash', 'Testland 323');
select pg_temp.check((select plus_pct = 10 and plus_priority from public.ride_requests
                       where id = '00000000-0000-0000-0000-0000000323f1'),
  'a covered member''s request is stamped with the discount and priority');
select pg_temp.check((select plus_pct is null and not plus_priority from public.ride_requests
                       where id = '00000000-0000-0000-0000-0000000323f4'), 'a stranger''s is not');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000323a1');
insert into t_ids select 'm2', (public.family_invite('{"country": "Testland 323"}', '+60100323004', 'Other')->>'id')::uuid;
select pg_temp.as_user('00000000-0000-0000-0000-0000000323a4');
select pg_temp.check((public.family_my_invites()->0->'modules') ? 'GET.Plus',
  'once the box is on, the invite lists GET.Plus among what the family covers');
reset role;

-- ---- 2. Free cancels are the family's -----------------------------------------------------------
select pg_temp.check((select public.plus_cancel_waive(r, 5) = 0 from public.ride_requests r
                       where r.id = '00000000-0000-0000-0000-0000000323f1'), 'the member''s first cancel is free');
select pg_temp.check((select free_cancels_used = 1 from public.plus_memberships
                       where rider_id = '00000000-0000-0000-0000-0000000323a1')
  and not exists (select 1 from public.plus_memberships where rider_id = '00000000-0000-0000-0000-0000000323a2'),
  'counted on the host''s membership');
select pg_temp.check((public.plus_benefits('00000000-0000-0000-0000-0000000323a1', 'Testland 323', null, null, null)->>'freeCancelsLeft')::int = 1
  and (public.plus_benefits('00000000-0000-0000-0000-0000000323a2', 'Testland 323', null, null, null)->>'freeCancelsLeft')::int = 1,
  'host and member see the same one left');
select pg_temp.check((select public.plus_cancel_waive(r, 5) = 0 from public.ride_requests r
                       where r.id = '00000000-0000-0000-0000-0000000323f3'), 'the host''s own cancel takes the last');
select pg_temp.check((select public.plus_cancel_waive(r, 5) = 5 from public.ride_requests r
                       where r.id = '00000000-0000-0000-0000-0000000323f2')
  and (select plus_waived_fee is null from public.ride_requests where id = '00000000-0000-0000-0000-0000000323f2'),
  'none left for the family: the member pays the fee');
select pg_temp.check((select free_cancels_used = 2 from public.plus_memberships
                       where rider_id = '00000000-0000-0000-0000-0000000323a1'),
  'two a month for the whole family, not two each');
select pg_temp.check((select (t->>'plusFreeCancelsLeft') is null
                        from (select public.plus_cancel_terms(r, '{"lateFee": 5}') t from public.ride_requests r
                               where r.id = '00000000-0000-0000-0000-0000000323f2') x),
  'the cancel terms show the fee again for the member');

-- ---- 4. God View's "GET.Plus only" --------------------------------------------------------------
insert into public.rider_live_map_rules (country, busy_on, busy_who) values ('Testland 323', true, 'plus');
select pg_temp.check(pg_temp.busy_on('00000000-0000-0000-0000-0000000323a3'), 'a member sees Busy areas');
select pg_temp.check(pg_temp.busy_on('00000000-0000-0000-0000-0000000323a1'), 'the host, a member, sees it');
select pg_temp.check(pg_temp.busy_on('00000000-0000-0000-0000-0000000323a2'), 'a covered member sees it');
select pg_temp.check(not pg_temp.busy_on('00000000-0000-0000-0000-0000000323a4'), 'somebody else doesn''t');
update public.family_module_rules set family_pays = false where module_key = 'get_plus' and country = 'Testland 323';
select pg_temp.check(not pg_temp.busy_on('00000000-0000-0000-0000-0000000323a2'),
  'with the matrix box off the member isn''t covered on the map either');
update public.family_module_rules set family_pays = true where module_key = 'get_plus' and country = 'Testland 323';
update public.plus_memberships set status = 'ended', ended_at = now(), period_end = now() - interval '1 day'
 where rider_id = '00000000-0000-0000-0000-0000000323a1';
select pg_temp.check(not pg_temp.busy_on('00000000-0000-0000-0000-0000000323a2')
  and public.plus_benefits('00000000-0000-0000-0000-0000000323a2', 'Testland 323', null, null, null) is null,
  'the host''s membership ended: nobody in the family is covered');
update public.plus_memberships set status = 'active', ended_at = null, period_end = now() + interval '30 days'
 where rider_id = '00000000-0000-0000-0000-0000000323a1';

-- ---- 3. Leaving ends the cover at once ----------------------------------------------------------
select pg_temp.check(public.plus_holder('00000000-0000-0000-0000-0000000323a2', '{"country": "Testland 323"}') is not null,
  'covered before leaving');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000323a2');
select public.family_leave();
reset role;
select pg_temp.check(public.plus_holder('00000000-0000-0000-0000-0000000323a2', '{"country": "Testland 323"}') is null
  and public.plus_benefits('00000000-0000-0000-0000-0000000323a2', 'Testland 323', null, null, null) is null,
  'a member who left is not covered');
select pg_temp.check(not pg_temp.busy_on('00000000-0000-0000-0000-0000000323a2'), 'nor sees the GET.Plus overlay');
insert into public.ride_requests (id, rider_id, status, fare, ride_fare, payment_mode, country) values
  ('00000000-0000-0000-0000-0000000323f5', '00000000-0000-0000-0000-0000000323a2', 'open', 20, 20, 'Cash', 'Testland 323');
select pg_temp.check((select plus_pct is null from public.ride_requests where id = '00000000-0000-0000-0000-0000000323f5'),
  'their next request has no member discount');
select pg_temp.check(pg_temp.busy_on('00000000-0000-0000-0000-0000000323a1'), 'the host keeps their own');

rollback;
