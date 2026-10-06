-- 0079: Expose the inviter's name to a referred user.
--
-- The `referrals` row is readable by the referred user (policy from 0078),
-- but the inviter's `public.profiles` row is not — profiles are self-read
-- only. This SECURITY DEFINER RPC lets the signed-in user learn who invited
-- them (name + code) without widening the profiles RLS, so the profile
-- screen can render a "Referred" badge naming the inviter.

create or replace function public.get_my_referrer()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_name text;
  v_code text;
  v_created timestamptz;
begin
  if v_user is null then
    return null;
  end if;

  select p.name, r.code, r.created_at
    into v_name, v_code, v_created
    from public.referrals r
    join public.profiles p on p.id = r.referrer_user_id
   where r.referred_user_id = v_user
   limit 1;

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'name', nullif(trim(coalesce(v_name, '')), ''),
    'code', v_code,
    'created_at', v_created
  );
end;
$$;

grant execute on function public.get_my_referrer() to authenticated;

notify pgrst, 'reload schema';
