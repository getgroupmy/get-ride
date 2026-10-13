-- ============================================================================
-- 0166: notifications follow the mode the phone is in
--
-- An account can be a passenger and a driver. Each phone now says which mode
-- it is in (push_tokens.mode: 'rider' or 'partner', set by push_set_mode as
-- the app moves between passenger and driver screens), and send-push skips
-- a phone in the other mode for the notifications that belong to one:
--
--   * partner: new ride requests, raised fares, direct and My Ride
--     requests, and admin broadcasts to partners;
--   * rider: admin broadcasts to users.
--
-- Everything about the account's own business still reaches it in either
-- mode: its rides (status, chat, calls, payment, safety), GET.coin
-- transfers, approval decisions, lost items. A phone that has never said
-- (null: an older build) gets everything, as before.
-- ============================================================================

alter table public.push_tokens add column if not exists mode text;
alter table public.push_tokens drop constraint if exists push_tokens_mode_check;
alter table public.push_tokens add constraint push_tokens_mode_check check (mode is null or mode in ('rider', 'partner'));

-- The caller's phone (its tokens: the ordinary one and the VoIP one) is in
-- p_mode now. Only the caller's own rows change; returns how many did.
create or replace function public.push_set_mode(p_tokens text[], p_mode text)
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
  if p_mode is null or p_mode not in ('rider', 'partner') then
    raise exception 'invalid_mode';
  end if;
  update public.push_tokens
     set mode = p_mode
   where profile_id = auth.uid()
     and token = any(coalesce(p_tokens, '{}'))
     and mode is distinct from p_mode;
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke execute on function public.push_set_mode(text[], text) from public, anon;
grant execute on function public.push_set_mode(text[], text) to authenticated, service_role;
