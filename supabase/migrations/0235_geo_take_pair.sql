-- ============================================================================
-- 0235: the geo function's two rate limits in one call (PERF-73).
--
-- A keyed lookup (search, reverse, route …) is held to the signed-in user's
-- limit and to the caller address's, each a geo_take (0200). Asked one after
-- the other they cost two round trips to the database per lookup; geo_take2
-- takes both in one, in the same order and with the same counting as the
-- two calls: the user's bucket first, the address's only when the user is
-- under their limit, and a refused call still counts in the bucket that
-- refused it. Both are taken in one transaction.
--
-- Returns 'user' or 'ip' for the bucket that refused, or null when both
-- allow it. The function falls back to two geo_take calls while this
-- migration is not run, so it can be deployed first.
-- ============================================================================

create or replace function public.geo_take2(
  p_user_bucket text,
  p_user_limit integer,
  p_ip_bucket text,
  p_ip_limit integer
)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.geo_take(p_user_bucket, p_user_limit) then
    return 'user';
  end if;
  if not public.geo_take(p_ip_bucket, p_ip_limit) then
    return 'ip';
  end if;
  return null;
end;
$$;
revoke execute on function public.geo_take2(text, integer, text, integer) from public, anon, authenticated;
grant execute on function public.geo_take2(text, integer, text, integer) to service_role;
