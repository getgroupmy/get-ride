-- ============================================================================
-- 0159: post-trip star ratings (passenger → driver)
--
-- The Expo app drew rating stars after a trip and never stored them. Now:
--
--   ride_ratings                       one row per ride per passenger: 1–5
--                                      stars and an optional short comment.
--   rate_ride(p_request_id, p_stars, p_comment)
--                                      the only way in. The caller must be
--                                      the ride's passenger, the ride
--                                      completed, and the driver is read off
--                                      the ride row (never sent by the
--                                      client). Rating again within 7 days
--                                      of drop-off changes the rating; after
--                                      that it is 'too_late'.
--
-- Each rating recomputes the driver's average onto partners.rating (the
-- column the app already reads, and copies onto a ride as partner_rating
-- when the driver accepts it). partners.rating is protected from clients by
-- partners_guard_protected_columns (0147); this definer function runs as its
-- owner, which the guard lets through.
--
-- Reads: the passenger sees their own ratings, the driver the ratings about
-- them, admins all of them.
--
-- Rollback: drop function public.rate_ride(uuid, int, text);
--           drop table public.ride_ratings;
-- ============================================================================

create table if not exists public.ride_ratings (
  id          uuid primary key default gen_random_uuid(),
  request_id  uuid not null references public.ride_requests(id) on delete cascade,
  rater_id    uuid not null references public.profiles(id) on delete cascade,
  -- The driver's account id, as ride_requests.partner_id holds it
  -- (partners.auth_user_id).
  partner_id  uuid not null,
  stars       smallint not null check (stars between 1 and 5),
  comment     text check (comment is null or char_length(comment) <= 500),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (request_id, rater_id)
);
create index if not exists ride_ratings_partner on public.ride_ratings (partner_id, created_at desc);
create index if not exists ride_ratings_rater on public.ride_ratings (rater_id, created_at desc);

alter table public.ride_ratings enable row level security;
drop policy if exists "ride_ratings parties read" on public.ride_ratings;
create policy "ride_ratings parties read" on public.ride_ratings
  for select using (rater_id = auth.uid() or partner_id = auth.uid() or public.caller_is_admin());
revoke all on public.ride_ratings from anon, authenticated;
grant select on public.ride_ratings to authenticated;

create or replace function public.rate_ride(p_request_id uuid, p_stars int, p_comment text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_uid uuid := auth.uid();
  v_comment text := nullif(btrim(coalesce(p_comment, '')), '');
  v_avg numeric;
  v_count int;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_request_id;
  if not found or r.rider_id is distinct from v_uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status <> 'completed' or r.partner_id is null then
    raise exception 'not_completed';
  end if;
  if coalesce(r.completed_at, r.updated_at) < now() - interval '7 days' then
    raise exception 'too_late';
  end if;
  if p_stars is null or p_stars < 1 or p_stars > 5 then
    raise exception 'bad_stars' using errcode = '22023';
  end if;

  insert into public.ride_ratings (request_id, rater_id, partner_id, stars, comment)
  values (p_request_id, v_uid, r.partner_id, p_stars, left(v_comment, 500))
  on conflict (request_id, rater_id) do update
     set stars = excluded.stars,
         comment = excluded.comment,
         partner_id = excluded.partner_id,
         updated_at = now();

  select round(avg(x.stars)::numeric, 2), count(*) into v_avg, v_count
    from public.ride_ratings x
   where x.partner_id = r.partner_id;
  update public.partners
     set rating = v_avg
   where auth_user_id = r.partner_id;

  return jsonb_build_object(
    'stars', p_stars,
    'comment', left(v_comment, 500),
    'partner_rating', v_avg,
    'ratings', v_count);
end;
$$;
revoke execute on function public.rate_ride(uuid, int, text) from public, anon;
grant execute on function public.rate_ride(uuid, int, text) to authenticated;

notify pgrst, 'reload schema';
