-- ============================================================================
-- 0241 — Test traffic: the tester accounts, and the figures that leave them out
--
-- The Claude test sessions sign in with a few tester accounts. Their calls
-- land in the same speed and usage figures as real riders and drivers, so the
-- admin can't tell what real people get. The admin now lists those accounts
-- (Admin → Display Settings → Demo / Mockup Data → Tester accounts) and the
-- figures below label their traffic as test traffic.
--
-- The label is derived on the server from the caller's verified user id
-- (the edge function reads it from the JWT through auth.getUser) — never from
-- anything the client sends. It only labels: rate limits, payments, security
-- checks and every real side effect treat a tester exactly like anyone else.
--
-- 1. public.test_accounts — one row per tester profile. Admins read it; an
--    admin with EDIT on Display Settings (or a full admin) adds and removes
--    rows. Removing the profile removes the row.
-- 2. public.is_test_account(uuid) — true when the id is listed. Stable,
--    SECURITY DEFINER, fixed search_path; callable by the edge functions
--    (service_role) only, so nobody can probe who is a tester.
-- 3. Fare AI response log (Admin → Fare AI → Response log: the record count,
--    passed / failed and each call's latency): fare_ai_responses.is_test,
--    written by ai-route-proxy. Clients can't insert into this table (0147),
--    so nobody can set it but the function.
-- 4. Map usage (Admin → Maps → Usage: calls, cached, failed per provider):
--    geo_usage_daily counts test calls in their own rows (is_test is part
--    of the key). geo_count(..., p_test) counts one; the four-argument
--    geo_count still counts real traffic, so a geo function deployed before
--    this one keeps working. map_usage(p_days, p_include_test) leaves test
--    calls out unless asked, and says how many there were (test_calls).
-- ============================================================================

-- 1. The list ------------------------------------------------------------------
create table if not exists public.test_accounts (
  profile_id uuid primary key references public.profiles (id) on delete cascade,
  note       text check (note is null or length(note) <= 120),
  added_by   uuid default auth.uid(),
  created_at timestamptz not null default now()
);
comment on table public.test_accounts is
  'Tester accounts (the Claude test sessions). Their traffic is labelled test traffic in the speed and usage figures; nothing else treats them differently.';

-- Who writes it: EDIT on Display Settings (0223), or a full admin.
insert into public.admin_table_pages (target, page) values
  ('test_accounts', 'admin-settings-display')
on conflict do nothing;

alter table public.test_accounts enable row level security;
revoke all on public.test_accounts from anon;
revoke update, truncate on public.test_accounts from authenticated;
grant select, insert, delete on public.test_accounts to authenticated;
grant all on public.test_accounts to service_role;

drop policy if exists "test_accounts admin read"   on public.test_accounts;
drop policy if exists "test_accounts admin insert" on public.test_accounts;
drop policy if exists "test_accounts admin delete" on public.test_accounts;
create policy "test_accounts admin read"
  on public.test_accounts for select to authenticated
  using ((select public.caller_is_admin()));
create policy "test_accounts admin insert"
  on public.test_accounts for insert to authenticated
  with check ((select public.caller_admin_can_write('test_accounts')));
create policy "test_accounts admin delete"
  on public.test_accounts for delete to authenticated
  using ((select public.caller_admin_can_write('test_accounts')));

-- 2. The check -----------------------------------------------------------------
create or replace function public.is_test_account(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p_uid is not null
     and exists (select 1 from public.test_accounts t where t.profile_id = p_uid);
$$;
revoke execute on function public.is_test_account(uuid) from public, anon, authenticated;
grant execute on function public.is_test_account(uuid) to service_role;

-- 3. Fare AI response log --------------------------------------------------------
alter table public.fare_ai_responses add column if not exists is_test boolean not null default false;
create index if not exists fare_ai_responses_real_created_at_idx
  on public.fare_ai_responses (created_at desc) where not is_test;

-- 4. Map usage -------------------------------------------------------------------
alter table public.geo_usage_daily add column if not exists is_test boolean not null default false;

do $$
begin
  -- The key gains is_test (once: a replay finds it there already).
  if not exists (
    select 1
      from pg_constraint c
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
     where c.conrelid = 'public.geo_usage_daily'::regclass
       and c.contype = 'p'
       and a.attname = 'is_test')
  then
    alter table public.geo_usage_daily drop constraint if exists geo_usage_daily_pkey;
    alter table public.geo_usage_daily
      add constraint geo_usage_daily_pkey primary key (day, provider, kind, is_test);
  end if;
end $$;

-- One call, real or test. Only the geo function (service_role) counts.
create or replace function public.geo_count(
  p_provider text, p_kind text, p_ok boolean, p_cached boolean, p_test boolean)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.geo_usage_daily as u (provider, kind, calls, cached, failures, is_test)
  values (p_provider, p_kind, 1, case when p_cached then 1 else 0 end, case when p_ok then 0 else 1 end,
          coalesce(p_test, false))
  on conflict (day, provider, kind, is_test) do update
    set calls = u.calls + 1,
        cached = u.cached + excluded.cached,
        failures = u.failures + excluded.failures;
$$;
revoke execute on function public.geo_count(text, text, boolean, boolean, boolean) from public, anon, authenticated;
grant execute on function public.geo_count(text, text, boolean, boolean, boolean) to service_role;

-- The four-argument form (geo functions deployed before 0241): real traffic.
-- Redefined because its old conflict target is no longer a key.
create or replace function public.geo_count(p_provider text, p_kind text, p_ok boolean, p_cached boolean)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  select public.geo_count(p_provider, p_kind, p_ok, p_cached, false);
$$;
revoke execute on function public.geo_count(text, text, boolean, boolean) from public, anon, authenticated;
grant execute on function public.geo_count(text, text, boolean, boolean) to service_role;

-- Admin: calls per provider and kind over the last [p_days] days; test calls
-- only when [p_include_test]. test_calls says how many test calls the period
-- had either way.
drop function if exists public.map_usage(integer);
create or replace function public.map_usage(p_days integer default 30, p_include_test boolean default false)
returns table (provider text, kind text, calls bigint, cached bigint, failures bigint, test_calls bigint)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
    select u.provider, u.kind,
           sum(u.calls) filter (where coalesce(p_include_test, false) or not u.is_test)::bigint,
           sum(u.cached) filter (where coalesce(p_include_test, false) or not u.is_test)::bigint,
           sum(u.failures) filter (where coalesce(p_include_test, false) or not u.is_test)::bigint,
           coalesce(sum(u.calls) filter (where u.is_test), 0)::bigint
      from public.geo_usage_daily u
     where u.day > current_date - greatest(1, least(coalesce(p_days, 30), 365))
     group by u.provider, u.kind
    having coalesce(p_include_test, false) or bool_or(not u.is_test)
     order by 3 desc nulls last;
end;
$$;
revoke execute on function public.map_usage(integer, boolean) from public, anon;
grant execute on function public.map_usage(integer, boolean) to authenticated;
