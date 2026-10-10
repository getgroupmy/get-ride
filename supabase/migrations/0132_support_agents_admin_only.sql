-- ============================================================================
-- 0132 — support_agents(): admins only
--
-- The roster lists every row of admin_access with a display name and avatar,
-- and when an admin has no name it falls back to their phone number. It was
-- executable by `anon`, so anyone, signed in or not, could list the admins
-- and read some of their phone numbers.
--
-- Its only callers are admin screens (Expo `admin-support-pool.tsx`, Flutter
-- `admin/screens/support_*`), so the function now returns nothing unless the
-- caller is an admin, and `public`/`anon` lose EXECUTE. Same columns and
-- order, so neither app changes.
-- ============================================================================
create or replace function public.support_agents()
returns table (profile_id uuid, name text, avatar_url text, priority integer)
language sql
stable
security definer
set search_path = public
as $$
  select aa.profile_id,
         coalesce(nullif(p.name, ''), nullif(p.phone, ''), 'Agent') as name,
         coalesce(nullif(p.avatar_url, ''), nullif(p.profile_image, '')) as avatar_url,
         min(aa.support) as priority
    from public.admin_access aa
    join public.profiles p on p.id = aa.profile_id
   where public.caller_is_admin()
   group by aa.profile_id, p.name, p.phone, p.avatar_url, p.profile_image;
$$;

revoke execute on function public.support_agents() from public, anon;
grant execute on function public.support_agents() to authenticated;
