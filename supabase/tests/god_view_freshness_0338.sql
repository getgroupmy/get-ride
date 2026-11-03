-- ============================================================================
-- Regression test for migration 0338: God View freshness.
--
-- god_view_people now takes a person's position and liveness from the newer of
-- their freshest push_tokens report and their latest user_location_history row
-- (an open app / trip / SOS writes the latter). So a phone that opened the app
-- but sent no background report no longer reads as a stale "Last known".
-- The push-token-only behaviour is unchanged from 0272 (that test still passes).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/god_view_freshness_0338.sql
--
-- One transaction, rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if p_ok is not true then raise exception 'FAILED: %', p_what; end if; end $$;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000338a1'),  -- token stale, fresh history (the Karpal Singh case)
  ('00000000-0000-0000-0000-0000000338a2'),  -- history only, no push token
  ('00000000-0000-0000-0000-0000000338a3')   -- stale token, stale history: stays last known
on conflict do nothing;
insert into public.profiles (id, name) values
  ('00000000-0000-0000-0000-0000000338a1', 'Fresh History'),
  ('00000000-0000-0000-0000-0000000338a2', 'History Only'),
  ('00000000-0000-0000-0000-0000000338a3', 'Stale Both')
on conflict (id) do update set name = excluded.name;

-- a1: a background token that last reported 18 hours ago (would be "last known").
insert into public.push_tokens (profile_id, token, platform, last_lat, last_lng, located_at, located_bg, location_always) values
  ('00000000-0000-0000-0000-0000000338a1', 'gvf338-a1', 'android', 3.10, 101.60, now() - interval '18 hours', true, true),
  ('00000000-0000-0000-0000-0000000338a3', 'gvf338-a3', 'android', 3.30, 101.80, now() - interval '18 hours', true, true);
-- a1: an open-app history row from a minute ago (fresh), at a different spot.
insert into public.user_location_history (user_id, latitude, longitude, captured_at) values
  ('00000000-0000-0000-0000-0000000338a1', 3.55, 101.95, now() - interval '1 minute'),
  -- a2: history only, fresh, no push token at all.
  ('00000000-0000-0000-0000-0000000338a2', 2.20, 100.10, now() - interval '2 minutes'),
  -- a3: history too old (2 days) to count in the live (30-minute) window.
  ('00000000-0000-0000-0000-0000000338a3', 3.33, 101.83, now() - interval '2 days');

-- 1. The fresh history row makes a1 live at the NEWER position, not "last known".
select pg_temp.check((select g.status <> 'last_known'
                        and round(g.lat::numeric, 2) = 3.55 and round(g.lng::numeric, 2) = 101.95
                        from public.god_view_people(null, false, null, '00000000-0000-0000-0000-0000000338a1', false, null, null) g),
  'a fresh history row makes the stale-token subject live at the history position');

-- 2. A person with only a history row (no push token) appears, and is live.
select pg_temp.check((select g.status <> 'last_known'
                        and round(g.lat::numeric, 2) = 2.20
                        from public.god_view_people(null, false, null, '00000000-0000-0000-0000-0000000338a2', false, null, null) g),
  'a history-only person appears live on the live view');

-- 3. A history row older than the live window does NOT make them live: a3 is
--    "last known", so the live view (p_offline = false) omits them entirely.
select pg_temp.check(not exists (
    select 1 from public.god_view_people(null, false, null, '00000000-0000-0000-0000-0000000338a3', false, null, null) g),
  'a stale history row does not resurrect a stale token on the live view');

-- 4. On the offline view (p_offline = true, 7-day window) a3 shows as "last known".
select pg_temp.check((select g.status = 'last_known'
                        from public.god_view_people(null, true, null, '00000000-0000-0000-0000-0000000338a3', false, null, null) g),
  'a3 is last known on the offline view');

do $$ begin raise notice 'ALL GOD VIEW FRESHNESS 0338 CHECKS PASSED'; end $$;

rollback;
