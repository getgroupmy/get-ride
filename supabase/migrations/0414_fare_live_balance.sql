-- 0414 — Waze / Google Maps balance: the automatic share
-- ---------------------------------------------------------------------------
-- Admin › Settings › Fare AI provider can send a share of fares to Google Maps
-- first instead of Waze (fare_ai_provider.liveBalance, _shared/live_balance.ts).
-- In "fixed" mode the share is the admin's number. In "auto" mode it moves
-- inside the admin's range, set every minute by the waze-server-health edge
-- function from the last 15 minutes of fare_ai_responses; it is kept here,
-- one row, so ai-route-proxy reads it on every fare.
--
-- Read by admins (the Fare AI page shows the current share and why), written
-- only by the service role through fare_live_balance_set.
-- ---------------------------------------------------------------------------

create table if not exists public.fare_live_balance (
  id             boolean primary key default true check (id),
  gmap_first_pct smallint not null default 0 check (gmap_first_pct between 0 and 100),
  reason         text check (reason is null or char_length(reason) <= 300),
  updated_at     timestamptz not null default now()
);
comment on table public.fare_live_balance is
  'The automatic Waze / Google Maps share (0414): percent of fares asking Google Maps first. One row; written by waze-server-health via fare_live_balance_set.';

insert into public.fare_live_balance (id) values (true) on conflict (id) do nothing;

alter table public.fare_live_balance enable row level security;
revoke all on public.fare_live_balance from public, anon, authenticated;
grant select on public.fare_live_balance to authenticated;
grant all on public.fare_live_balance to service_role;

-- Guard the create rather than "drop ... if exists" first (a DROP asks for a
-- destructive-operation confirmation that hangs the apply).
do $$
begin
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'fare_live_balance'
       and policyname = 'fare_live_balance_read') then
    create policy fare_live_balance_read on public.fare_live_balance
      for select to authenticated using ((select public.caller_is_admin()));
  end if;
end $$;

-- Set the automatic share (service role: waze-server-health).
create or replace function public.fare_live_balance_set(p_pct integer, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_pct is null or p_pct < 0 or p_pct > 100 then
    raise exception 'FARE_LIVE_BALANCE_BAD_PCT';
  end if;
  insert into public.fare_live_balance (id, gmap_first_pct, reason, updated_at)
       values (true, p_pct, left(p_reason, 300), now())
  on conflict (id) do update
     set gmap_first_pct = excluded.gmap_first_pct, reason = excluded.reason, updated_at = excluded.updated_at;
end;
$$;
revoke execute on function public.fare_live_balance_set(integer, text) from public, anon, authenticated;
grant execute on function public.fare_live_balance_set(integer, text) to service_role;
