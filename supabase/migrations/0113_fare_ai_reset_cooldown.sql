-- 0113: Admin → Fare AI → "Reset cooldown".
--
-- A fare-AI key that fails is paused until fare_ai_key_states.disabled_until
-- (ai-route-proxy skips it while that is in the future). The table is
-- read-only to clients, so this is how an admin puts a key — or every key,
-- when p_key_id is null — straight back into rotation. Only the pause is
-- cleared; the usage / pass / fail counters and the last error stay as they
-- were, so the log still explains why the key was paused.

create or replace function public.fare_ai_reset_cooldown(p_key_id text default null)
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  n integer;
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  update public.fare_ai_key_states
     set disabled_until = null,
         updated_at = now()
   where disabled_until is not null
     and (p_key_id is null or key_id = p_key_id);
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke all on function public.fare_ai_reset_cooldown(text) from public;
revoke execute on function public.fare_ai_reset_cooldown(text) from anon;
grant execute on function public.fare_ai_reset_cooldown(text) to authenticated;
