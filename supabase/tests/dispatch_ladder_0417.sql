-- ============================================================================
-- Regression test for migration 0417: the staged dispatch ladder.
--   * dispatch_ladder_expand  -- stored rings -> runtime {after_sec, radius_km}
--   * dispatch_ladder_reached_km -- the radius a ladder has reached by t
--   * dispatch_ladder_steps_ok + the table CHECK  -- bad steps are rejected
--   * dispatch_ladder_at  -- narrowest-first, service-specific beats all-service,
--                            legacy fallback when nothing matches
--   * RLS  -- an edit admin writes; a view-only admin and a rider cannot; a
--            partner may read.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/dispatch_ladder_0417.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000417c1'),  -- admin (edit)
  ('00000000-0000-0000-0000-0000000417c2'),  -- admin (view only)
  ('00000000-0000-0000-0000-0000000417d1')   -- ordinary partner/rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000417%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000417c1', 'admin-settings-dispatch-ladder', 'edit'),
  ('00000000-0000-0000-0000-0000000417c2', 'admin-settings-dispatch-ladder', 'read')
on conflict do nothing;

-- Only this test's rows count.
delete from public.dispatch_ladder_rules;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated, anon;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated, anon;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
declare n int;
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
grant execute on function pg_temp.refused(text, text) to authenticated, anon;

create or replace function pg_temp.raised(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was accepted', p_what;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Expand: cumulative after_sec from the hold of each ring, plus a trailing
--    null-radius "everybody" ring when offer_everyone.
-- ---------------------------------------------------------------------------
select pg_temp.check(
  public.dispatch_ladder_expand(
    '[{"radius_km":2,"hold_sec":5},{"radius_km":5,"hold_sec":5},{"radius_km":10,"hold_sec":0}]'::jsonb, true)
  = '[{"after_sec":0,"radius_km":2},{"after_sec":5,"radius_km":5},{"after_sec":10,"radius_km":10},{"after_sec":10,"radius_km":null}]'::jsonb,
  'expand: cumulative times + everybody ring');

select pg_temp.check(
  public.dispatch_ladder_expand('[{"radius_km":3,"hold_sec":30}]'::jsonb, false)
  = '[{"after_sec":0,"radius_km":3}]'::jsonb,
  'expand: no everybody ring when offer_everyone is false');

-- ---------------------------------------------------------------------------
-- 2. Reached radius by elapsed time: the widest due ring, -1 once the
--    everybody ring is due, NULL before the first ring.
-- ---------------------------------------------------------------------------
do $$
declare l jsonb := public.dispatch_ladder_expand(
  '[{"radius_km":2,"hold_sec":5},{"radius_km":5,"hold_sec":5},{"radius_km":10,"hold_sec":0}]'::jsonb, true);
begin
  perform pg_temp.check(public.dispatch_ladder_reached_km(l, 0) = 2,   'reached: t=0 -> 2 km');
  perform pg_temp.check(public.dispatch_ladder_reached_km(l, 7) = 5,   'reached: t=7 -> 5 km');
  perform pg_temp.check(public.dispatch_ladder_reached_km(l, 10) = -1, 'reached: t=10 -> everybody (-1)');
  perform pg_temp.check(
    public.dispatch_ladder_reached_km('[{"after_sec":5,"radius_km":2}]'::jsonb, 0) is null,
    'reached: nothing due yet -> NULL');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Bad steps are rejected by the CHECK (radius <= 0, fractional hold, empty,
--    not an array); a well-formed ladder is accepted.
-- ---------------------------------------------------------------------------
select pg_temp.check(public.dispatch_ladder_steps_ok('[{"radius_km":2,"hold_sec":5}]'::jsonb), 'steps_ok: good');
select pg_temp.check(not public.dispatch_ladder_steps_ok('[{"radius_km":0,"hold_sec":5}]'::jsonb), 'steps_ok: radius 0');
select pg_temp.check(not public.dispatch_ladder_steps_ok('[{"radius_km":2,"hold_sec":5.5}]'::jsonb), 'steps_ok: fractional hold');
select pg_temp.check(not public.dispatch_ladder_steps_ok('[]'::jsonb), 'steps_ok: empty array');
select pg_temp.check(not public.dispatch_ladder_steps_ok('{}'::jsonb), 'steps_ok: not an array');

select pg_temp.raised(
  $q$insert into public.dispatch_ladder_rules (level, steps) values ('master', '[{"radius_km":0,"hold_sec":5}]')$q$,
  'CHECK rejects a non-positive radius');

-- ---------------------------------------------------------------------------
-- 4. Resolver: legacy fallback, a master rule, service-specific beats
--    all-service, a country level beats master, inactive ignored.
-- ---------------------------------------------------------------------------
-- 4a. No matching rule: NULL, so the caller keeps the legacy per-service
--     min/max/widen dispatch (the ladder is purely additive).
select pg_temp.check(
  public.dispatch_ladder_at('zzz_unconfigured_service', 'Nowhere', null, null, null) is null,
  'resolver: no rule -> NULL (legacy dispatch unchanged)');

-- 4b. A master all-service ladder wins everywhere.
insert into public.dispatch_ladder_rules (level, service, steps, offer_everyone)
  values ('master', null, '[{"radius_km":2,"hold_sec":5},{"radius_km":8,"hold_sec":5}]', false);
select pg_temp.check(
  public.dispatch_ladder_at('ride', 'Malaysia', 'Selangor', null, null)
  = '[{"after_sec":0,"radius_km":2},{"after_sec":5,"radius_km":8}]'::jsonb,
  'resolver: master all-service ladder');

-- 4c. A service-specific master row beats the all-service master, for teksi only.
insert into public.dispatch_ladder_rules (level, service, steps, offer_everyone)
  values ('master', 'teksi', '[{"radius_km":1,"hold_sec":3}]', true);
select pg_temp.check(
  (public.dispatch_ladder_at('TEKSI', null, null, null, null) -> 0 ->> 'radius_km') = '1',
  'resolver: service-specific beats all-service (case-insensitive)');
select pg_temp.check(
  (public.dispatch_ladder_at('ride', null, null, null, null) -> 0 ->> 'radius_km') = '2',
  'resolver: ride still on the all-service master');

-- 4d. A country row beats master for that country; master still elsewhere.
insert into public.dispatch_ladder_rules (level, country, service, steps, offer_everyone)
  values ('country', 'Malaysia', null, '[{"radius_km":4,"hold_sec":9}]', false);
select pg_temp.check(
  (public.dispatch_ladder_at('ride', 'Malaysia', 'Selangor', null, null) -> 0 ->> 'radius_km') = '4',
  'resolver: country (Malaysia) beats master');
select pg_temp.check(
  (public.dispatch_ladder_at('ride', 'Thailand', null, null, null) -> 0 ->> 'radius_km') = '2',
  'resolver: country row does not apply in Thailand -> master');

-- 4e. An inactive row is ignored.
update public.dispatch_ladder_rules set active = false where level = 'country';
select pg_temp.check(
  (public.dispatch_ladder_at('ride', 'Malaysia', null, null, null) -> 0 ->> 'radius_km') = '2',
  'resolver: inactive country row ignored -> master');

-- ---------------------------------------------------------------------------
-- 5. RLS: an edit admin writes; a view-only admin and an ordinary user cannot.
--    Switch to the authenticated role so RLS is actually enforced.
-- ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000417c1');
insert into public.dispatch_ladder_rules (level, service, steps)
  values ('master', 'courier', '[{"radius_km":3,"hold_sec":5}]');
select pg_temp.check(
  (select count(*) from public.dispatch_ladder_rules where service = 'courier') = 1,
  'edit admin may insert');

select pg_temp.as_user('00000000-0000-0000-0000-0000000417c2');
select pg_temp.refused(
  $q$insert into public.dispatch_ladder_rules (level, service, steps) values ('master', 'freight', '[{"radius_km":3,"hold_sec":5}]')$q$,
  'view-only admin insert');

select pg_temp.as_user('00000000-0000-0000-0000-0000000417d1');
select pg_temp.refused(
  $q$insert into public.dispatch_ladder_rules (level, service, steps) values ('master', 'freight', '[{"radius_km":3,"hold_sec":5}]')$q$,
  'ordinary user insert');
-- but a partner may read (the on-screen gate reads the stamped ladder; the
-- editor reads the rules).
select pg_temp.check((select count(*) from public.dispatch_ladder_rules) >= 1, 'signed-in user may read rows');

rollback;
