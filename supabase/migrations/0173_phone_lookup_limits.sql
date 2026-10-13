-- ============================================================================
-- 0173: the phone lookup is limited harder
--
-- profile_phone_lookup tells a signed-out caller whether a number has an
-- account (and a PIN) -- the sign-in screen needs that to choose between
-- "enter your PIN" and "we'll text you a code". It was limited to 60 calls
-- per address per 10 minutes (0137), which still let one address check 8,640
-- numbers a day.
--
-- Real use is a handful: over a day of live traffic no address made more than
-- 3 lookups. So, per address:
--   * 20 per 10 minutes (was 60) -- still ~6x the busiest real address, with
--     room for a carrier's shared address (CGNAT) serving many phones;
--   * 100 per day (new) -- what actually stops a number list being walked.
-- No address (SQL, the service role) is not limited, as before.
-- ============================================================================

create or replace function public.profile_phone_lookup(p_phone text)
returns table (
  has_profile boolean,
  has_pin     boolean,
  is_deleted  boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ip   text := public.request_client_ip();
  v_wait integer := public.auth_rate_take('phone_lookup', v_ip, 20, interval '10 minutes');
begin
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait;
  end if;
  v_wait := public.auth_rate_take('phone_lookup_day', v_ip, 100, interval '1 day');
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait;
  end if;
  return query
  with digits as (
    select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') as d
  ),
  variants as (
    select array_remove(array['+' || d, d, '0' || d, ltrim(d, '0')], null) as v
    from digits
  ),
  match as (
    select p.pin_hash, p.profile_status
    from public.profiles p, variants
    where p.phone = any(variants.v)
    limit 1
  )
  select
    exists(select 1 from match),
    coalesce((select m.pin_hash is not null and m.pin_hash <> '' from match m), false),
    coalesce((select lower(m.profile_status::text) = 'deleted' from match m), false);
end;
$$;

revoke all on function public.profile_phone_lookup(text) from public;
grant execute on function public.profile_phone_lookup(text) to anon, authenticated;
