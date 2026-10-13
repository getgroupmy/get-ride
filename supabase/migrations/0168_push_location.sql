-- ============================================================================
-- 0168: push notifications by location (Admin -> Push Notification)
--
-- The admin can send a broadcast to the people in a country, state, city or
-- suburb, or within a radius of a point, and see how many it reaches first.
-- That needs to know where each phone is, so each phone now reports its
-- last known position and the region it is in (push_set_location): the
-- most specific admin region whose boundary or names match, as the bidding
-- and pricing rules pick it, else the geocoder's names. Throttled on the
-- phone, and never asked for: a phone without location permission simply
-- has no area and is left out of area broadcasts.
--
-- send-push does the matching (one rule, tested in _shared/push.ts), also
-- for the admin's "how many will this reach" preview (dryRun). The
-- broadcast history records the target.
-- ============================================================================

alter table public.push_tokens
  add column if not exists last_lat double precision,
  add column if not exists last_lng double precision,
  add column if not exists area_country text,
  add column if not exists area_state text,
  add column if not exists area_city text,
  add column if not exists area_suburb text,
  add column if not exists located_at timestamptz;

alter table public.push_notifications add column if not exists target jsonb;

-- The caller's phone (its tokens) is at p_lat/p_lng, in the region named.
-- Only the caller's own rows change; returns how many did.
create or replace function public.push_set_location(
  p_tokens text[],
  p_lat double precision,
  p_lng double precision,
  p_country text default null,
  p_state text default null,
  p_city text default null,
  p_suburb text default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  if auth.uid() is null then
    raise exception 'not_authorized';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'invalid_location';
  end if;
  update public.push_tokens
     set last_lat = p_lat,
         last_lng = p_lng,
         area_country = nullif(left(trim(coalesce(p_country, '')), 120), ''),
         area_state = nullif(left(trim(coalesce(p_state, '')), 120), ''),
         area_city = nullif(left(trim(coalesce(p_city, '')), 120), ''),
         area_suburb = nullif(left(trim(coalesce(p_suburb, '')), 120), ''),
         located_at = now()
   where profile_id = auth.uid()
     and token = any(coalesce(p_tokens, '{}'));
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke execute on function public.push_set_location(text[], double precision, double precision, text, text, text, text)
  from public, anon;
grant execute on function public.push_set_location(text[], double precision, double precision, text, text, text, text)
  to authenticated, service_role;
