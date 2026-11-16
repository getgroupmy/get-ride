-- 0416 — Waze / Google Maps / Apple Maps balance: Apple Maps' automatic share
-- ---------------------------------------------------------------------------
-- Admin › Settings › Fare AI provider can send a share of fares to Apple Maps
-- first (fare_ai_provider.liveBalance.apple, _shared/live_balance.ts), taken
-- from Waze's part; the Google Maps share (0414) is unchanged. In "auto" mode
-- the waze-server-health edge function sets it every minute from the last 15
-- minutes of fare_ai_responses; it is kept next to the Google Maps share in
-- the one fare_live_balance row, which ai-route-proxy reads on every fare.
--
-- Same access as 0414: admins read, only the service role writes, through
-- fare_live_balance_set_apple.
-- ---------------------------------------------------------------------------

alter table public.fare_live_balance
  add column if not exists apple_first_pct smallint not null default 0,
  add column if not exists apple_reason text,
  add column if not exists apple_updated_at timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'fare_live_balance_apple_pct') then
    alter table public.fare_live_balance
      add constraint fare_live_balance_apple_pct check (apple_first_pct between 0 and 100);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'fare_live_balance_apple_reason') then
    alter table public.fare_live_balance
      add constraint fare_live_balance_apple_reason check (apple_reason is null or char_length(apple_reason) <= 300);
  end if;
end $$;

comment on column public.fare_live_balance.apple_first_pct is
  'The automatic Apple Maps share (0416): percent of fares asking Apple Maps first, taken from Waze''s part. Written by waze-server-health via fare_live_balance_set_apple.';

-- Set the automatic Apple Maps share (service role: waze-server-health).
create or replace function public.fare_live_balance_set_apple(p_pct integer, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_pct is null or p_pct < 0 or p_pct > 100 then
    raise exception 'FARE_LIVE_BALANCE_BAD_PCT';
  end if;
  insert into public.fare_live_balance (id, apple_first_pct, apple_reason, apple_updated_at)
       values (true, p_pct, left(p_reason, 300), now())
  on conflict (id) do update
     set apple_first_pct = excluded.apple_first_pct,
         apple_reason = excluded.apple_reason,
         apple_updated_at = excluded.apple_updated_at;
end;
$$;
revoke execute on function public.fare_live_balance_set_apple(integer, text) from public, anon, authenticated;
grant execute on function public.fare_live_balance_set_apple(integer, text) to service_role;
