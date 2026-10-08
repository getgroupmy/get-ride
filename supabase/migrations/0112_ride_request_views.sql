-- 0112: "3 drivers are viewing your request" (inDrive's bar above the search
-- sheet).
--
-- A driver's app reports that it has the request on screen, and keeps
-- reporting every few seconds while it stays there. The rider of that
-- request reads back how many drivers have looked at it, how many are
-- looking now, and a few of their photos. Nothing else: no ids, names or
-- positions reach the rider, and nobody but the request's own rider can
-- read its viewers. The table has no client policies at all; both sides go
-- through the two SECURITY DEFINER functions below.

create table if not exists public.ride_request_views (
  request_id    uuid not null references public.ride_requests(id) on delete cascade,
  viewer_id     uuid not null references auth.users(id) on delete cascade,
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  primary key (request_id, viewer_id)
);

alter table public.ride_request_views enable row level security;
revoke all on table public.ride_request_views from anon, authenticated;

-- The driver's app: "I have this request on screen". Only a partner, only
-- on an open request, and never on their own. Anything else is ignored.
create or replace function public.ride_request_viewed(p_request uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or p_request is null then
    return;
  end if;
  if not exists (select 1 from public.partners where auth_user_id = auth.uid()) then
    return;
  end if;
  if not exists (
    select 1 from public.ride_requests
     where id = p_request and status = 'open' and rider_id is distinct from auth.uid()
  ) then
    return;
  end if;
  insert into public.ride_request_views (request_id, viewer_id)
  values (p_request, auth.uid())
  on conflict (request_id, viewer_id) do update set last_seen_at = now();
end;
$$;

-- The rider's search sheet: how many drivers have seen the request, how many
-- have it on screen now (reported in the last 30 s), and up to four photos,
-- most recent first. Empty for anyone but the request's rider.
create or replace function public.ride_request_viewers(p_request uuid)
returns table (viewed integer, viewing integer, photos text[])
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or p_request is null then
    return;
  end if;
  if not exists (select 1 from public.ride_requests where id = p_request and rider_id = auth.uid()) then
    return;
  end if;
  return query
    select count(*)::integer,
           (count(*) filter (where v.last_seen_at > now() - interval '30 seconds'))::integer,
           coalesce(
             (array_agg(coalesce(nullif(p.avatar_url, ''), nullif(p.profile_image, ''))
                        order by v.last_seen_at desc)
               filter (where coalesce(nullif(p.avatar_url, ''), nullif(p.profile_image, '')) is not null))[1:4],
             '{}'::text[])
      from public.ride_request_views v
      left join public.profiles p on p.id = v.viewer_id
     where v.request_id = p_request;
end;
$$;

revoke all on function public.ride_request_viewed(uuid) from public;
revoke execute on function public.ride_request_viewed(uuid) from anon;
grant execute on function public.ride_request_viewed(uuid) to authenticated;
revoke all on function public.ride_request_viewers(uuid) from public;
revoke execute on function public.ride_request_viewers(uuid) from anon;
grant execute on function public.ride_request_viewers(uuid) to authenticated;
