-- ============================================================================
-- 0297 — Tags on the rider's rating of the driver, totals for the driver,
-- and a flag for the admin.
--
-- Version 20261027090000 (0297_driver_rating_tags). Re-runnable: tables and
-- columns "if not exists", functions "create or replace", policies dropped
-- first, seed rows "on conflict do nothing".
--
-- 1. driver_rating_tags: the tags a rider picks after rating a driver, kept
--    by the admin. A 1–3 star list ("What went wrong?") and a 4–5 star list
--    ("What went well?"). A removed tag is kept inactive, so its past totals
--    still read under its own list.
-- 2. ride_ratings.tags: the tags picked with the rating. rate_ride takes them
--    (p_tags): only active tags of the stars' own list, each once. Without
--    p_tags (an app from before 0297) the tags already given stay, those of
--    the stars' list.
-- 3. my_driver_rating_tags(days): the driver's own totals per tag. Totals
--    only: never who gave them or on which trip, and never the admin's flag.
--    The driver no longer reads ride_ratings rows about them (0159 allowed
--    it; the app never did).
-- 4. The flag: a driver is flagged for a 1–3 star tag picked at least
--    `times` times within `days` days (driver_rating_flag_rule, set by the
--    admin). Flags are for admins only: admin_driver_rating_tags(partner)
--    for the partner page, admin_rating_flags() for the Partners list.
--    "Mark reviewed" (admin_rating_flag_review) counts that tag afresh from
--    then on.
-- ============================================================================

-- ---- 1. The tags ---------------------------------------------------------------------------------
create table if not exists public.driver_rating_tags (
  tag        text primary key check (char_length(tag) between 1 and 40 and tag = btrim(tag)),
  low        boolean not null,
  position   integer not null default 0,
  active     boolean not null default true,
  updated_at timestamptz not null default now()
);
comment on table public.driver_rating_tags is
  'Tags a rider picks when rating a driver (0297): low = the 1-3 star list. Set by the admin through driver_rating_tags_set; a removed tag is kept inactive.';

alter table public.driver_rating_tags enable row level security;
revoke all on public.driver_rating_tags from public, anon, authenticated;
grant select on public.driver_rating_tags to authenticated;
grant all on public.driver_rating_tags to service_role;
drop policy if exists driver_rating_tags_read on public.driver_rating_tags;
create policy driver_rating_tags_read on public.driver_rating_tags for select to authenticated using (true);

insert into public.driver_rating_tags (tag, low, position) values
  ('Safe driving', false, 0), ('Clean car', false, 1), ('Friendly', false, 2), ('Knew the way', false, 3),
  ('On time', false, 4),
  ('Late to pickup', true, 0), ('Unsafe driving', true, 1), ('Dirty car', true, 2), ('Wrong route', true, 3),
  ('Rude', true, 4)
on conflict (tag) do nothing;

-- ---- The flag rule and reviews --------------------------------------------------------------------
create table if not exists public.driver_rating_flag_rule (
  id         boolean primary key default true check (id),
  times      integer not null default 3 check (times between 1 and 20),
  days       integer not null default 30 check (days between 1 and 90),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id) on delete set null
);
insert into public.driver_rating_flag_rule (id) values (true) on conflict (id) do nothing;

create table if not exists public.driver_rating_flag_reviews (
  partner_id  uuid not null,
  tag         text not null,
  reviewed_at timestamptz not null default now(),
  reviewed_by uuid references public.profiles (id) on delete set null,
  primary key (partner_id, tag)
);

alter table public.driver_rating_flag_rule enable row level security;
alter table public.driver_rating_flag_reviews enable row level security;
revoke all on public.driver_rating_flag_rule, public.driver_rating_flag_reviews from public, anon, authenticated;
grant select on public.driver_rating_flag_rule, public.driver_rating_flag_reviews to authenticated;
grant all on public.driver_rating_flag_rule, public.driver_rating_flag_reviews to service_role;
drop policy if exists driver_rating_flag_rule_read on public.driver_rating_flag_rule;
create policy driver_rating_flag_rule_read on public.driver_rating_flag_rule
  for select to authenticated using ((select public.caller_is_admin()));
drop policy if exists driver_rating_flag_reviews_read on public.driver_rating_flag_reviews;
create policy driver_rating_flag_reviews_read on public.driver_rating_flag_reviews
  for select to authenticated using ((select public.caller_is_admin()));

insert into public.admin_table_pages (target, page) values
  ('rpc:driver_rating_tags_set', 'admin-partners'),
  ('rpc:driver_rating_flag_rule_set', 'admin-partners'),
  ('rpc:admin_rating_flag_review', 'admin-partners')
on conflict do nothing;

-- ---- 2. Tags on the rating ------------------------------------------------------------------------
alter table public.ride_ratings add column if not exists tags text[] not null default '{}';

-- The driver sees totals (my_driver_rating_tags), not each rating: who gave
-- which stars, tags and comment stays with the rider and the admins. The
-- app never read a driver's ratings row by row (0159 allowed it).
drop policy if exists "ride_ratings parties read" on public.ride_ratings;
create policy "ride_ratings parties read" on public.ride_ratings
  for select using (rater_id = auth.uid() or public.caller_is_admin());
create index if not exists ride_ratings_partner_tags on public.ride_ratings (partner_id, updated_at desc)
  where tags <> '{}';

-- [p_tags] kept to the active tags of the stars' own list, each once, in
-- the admin's order.
create or replace function public.driver_rating_tags_for(p_stars int, p_tags text[])
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(t.tag order by t.position, t.tag), '{}')
    from public.driver_rating_tags t
   where t.active and t.low = (p_stars <= 3) and t.tag = any (coalesce(p_tags, '{}'));
$$;
revoke execute on function public.driver_rating_tags_for(int, text[]) from public, anon, authenticated;

drop function if exists public.rate_ride(uuid, int, text);
create or replace function public.rate_ride(p_request_id uuid, p_stars int, p_comment text default null,
                                            p_tags text[] default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_uid uuid := auth.uid();
  v_comment text := nullif(btrim(coalesce(p_comment, '')), '');
  v_tags text[];
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

  -- Without p_tags (an app from before 0297) the tags already given stay.
  if p_tags is null then
    select x.tags into v_tags from public.ride_ratings x where x.request_id = p_request_id and x.rater_id = v_uid;
  end if;
  v_tags := public.driver_rating_tags_for(p_stars, coalesce(p_tags, v_tags));

  insert into public.ride_ratings (request_id, rater_id, partner_id, stars, comment, tags)
  values (p_request_id, v_uid, r.partner_id, p_stars, left(v_comment, 500), v_tags)
  on conflict (request_id, rater_id) do update
     set stars = excluded.stars,
         comment = excluded.comment,
         tags = excluded.tags,
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
    'tags', to_jsonb(v_tags),
    'partner_rating', v_avg,
    'ratings', v_count);
end;
$$;
revoke execute on function public.rate_ride(uuid, int, text, text[]) from public, anon;
grant execute on function public.rate_ride(uuid, int, text, text[]) to authenticated;

-- ---- Totals ---------------------------------------------------------------------------------------
-- How often each tag was picked for [p_partner] (an account id) within
-- [p_days] days, and from [p_since] on when given.
create or replace function public.driver_rating_tag_counts(p_partner uuid, p_days int, p_since timestamptz default null)
returns table (tag text, low boolean, n integer)
language sql
stable
security definer
set search_path = ''
as $$
  select x.tag, coalesce(t.low, false), count(*)::int
    from public.ride_ratings rr
   cross join lateral unnest(rr.tags) as x(tag)
    left join public.driver_rating_tags t on t.tag = x.tag
   where rr.partner_id = p_partner
     and rr.updated_at > now() - make_interval(days => greatest(1, least(p_days, 365)))
     and (p_since is null or rr.updated_at > p_since)
   group by x.tag, t.low;
$$;
revoke execute on function public.driver_rating_tag_counts(uuid, int, timestamptz) from public, anon, authenticated;

-- ---- 3. The driver's own totals --------------------------------------------------------------------
create or replace function public.my_driver_rating_tags(p_days int default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_days int := greatest(1, least(coalesce(p_days, 30), 365));
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'days', v_days,
    'rating', (select p.rating from public.partners p where p.auth_user_id = v_uid limit 1),
    'rated', (select count(*) from public.ride_ratings rr
               where rr.partner_id = v_uid and rr.updated_at > now() - make_interval(days => v_days)),
    'tags', coalesce((select jsonb_agg(jsonb_build_object('tag', c.tag, 'low', c.low, 'n', c.n)
                                       order by c.low, c.n desc, c.tag)
                        from public.driver_rating_tag_counts(v_uid, v_days) c), '[]'::jsonb));
end;
$$;
revoke execute on function public.my_driver_rating_tags(int) from public, anon;
grant execute on function public.my_driver_rating_tags(int) to authenticated;

-- ---- 4. Admin: tags, rule, totals, flags ----------------------------------------------------------
create or replace function public.driver_rating_tags_set(p_high text[], p_low text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_high text[] := array(select btrim(x) from unnest(coalesce(p_high, '{}')) x where btrim(x) <> '');
  v_low text[] := array(select btrim(x) from unnest(coalesce(p_low, '{}')) x where btrim(x) <> '');
  v_all text[] := v_high || v_low;
  i int;
begin
  if not public.caller_admin_can_write('rpc:driver_rating_tags_set') then
    raise exception 'Only admins who can edit partners can change the rating tags.' using errcode = '42501';
  end if;
  if cardinality(v_high) > 12 or cardinality(v_low) > 12 then
    raise exception 'RATING_TAGS_TOO_MANY' using errcode = '22023', hint = 'Up to 12 tags in each list.';
  end if;
  if exists (select 1 from unnest(v_all) x where char_length(x) > 40) then
    raise exception 'RATING_TAG_TOO_LONG' using errcode = '22023', hint = 'A tag is up to 40 characters.';
  end if;
  if (select count(distinct lower(x)) from unnest(v_all) x) <> cardinality(v_all) then
    raise exception 'RATING_TAG_TWICE' using errcode = '22023', hint = 'Each tag can be in one list, once.';
  end if;
  update public.driver_rating_tags set active = false, updated_at = now() where active;
  for i in 1 .. coalesce(cardinality(v_high), 0) loop
    insert into public.driver_rating_tags (tag, low, position, active) values (v_high[i], false, i - 1, true)
    on conflict (tag) do update set low = false, position = i - 1, active = true, updated_at = now();
  end loop;
  for i in 1 .. coalesce(cardinality(v_low), 0) loop
    insert into public.driver_rating_tags (tag, low, position, active) values (v_low[i], true, i - 1, true)
    on conflict (tag) do update set low = true, position = i - 1, active = true, updated_at = now();
  end loop;
end;
$$;
revoke execute on function public.driver_rating_tags_set(text[], text[]) from public, anon;
grant execute on function public.driver_rating_tags_set(text[], text[]) to authenticated;

create or replace function public.driver_rating_flag_rule_set(p_times int, p_days int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.caller_admin_can_write('rpc:driver_rating_flag_rule_set') then
    raise exception 'Only admins who can edit partners can change the flag rule.' using errcode = '42501';
  end if;
  if p_times is null or p_times not between 1 and 20 or p_days is null or p_days not between 1 and 90 then
    raise exception 'RATING_FLAG_RULE_BAD' using errcode = '22023',
      hint = 'From 1 to 20 times, within 1 to 90 days.';
  end if;
  insert into public.driver_rating_flag_rule (id, times, days, updated_at, updated_by)
  values (true, p_times, p_days, now(), auth.uid())
  on conflict (id) do update
     set times = excluded.times, days = excluded.days, updated_at = now(), updated_by = auth.uid();
end;
$$;
revoke execute on function public.driver_rating_flag_rule_set(int, int) from public, anon;
grant execute on function public.driver_rating_flag_rule_set(int, int) to authenticated;

-- The low tags that reach the rule for [p_partner], counted since the
-- window opened or the tag was last marked reviewed.
create or replace function public.driver_rating_flags_for(p_partner uuid)
returns table (tag text, n integer)
language sql
stable
security definer
set search_path = ''
as $$
  with rule as (select times, days from public.driver_rating_flag_rule where id limit 1)
  select x.tag, count(*)::int
    from public.ride_ratings rr
   cross join lateral unnest(rr.tags) as x(tag)
    join public.driver_rating_tags t on t.tag = x.tag and t.low
   cross join rule
    left join public.driver_rating_flag_reviews v on v.partner_id = rr.partner_id and v.tag = x.tag
   where rr.partner_id = p_partner
     and rr.updated_at > now() - make_interval(days => rule.days)
     and (v.reviewed_at is null or rr.updated_at > v.reviewed_at)
   group by x.tag, rule.times
  having count(*) >= rule.times;
$$;
revoke execute on function public.driver_rating_flags_for(uuid) from public, anon, authenticated;

-- The partner page: [p_partner] is the driver's account id (auth_user_id).
create or replace function public.admin_driver_rating_tags(p_partner uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_times int;
  v_days int;
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select times, days into v_times, v_days from public.driver_rating_flag_rule where id limit 1;
  v_times := coalesce(v_times, 3);
  v_days := coalesce(v_days, 30);
  return jsonb_build_object(
    'times', v_times,
    'days', v_days,
    'rated', (select count(*) from public.ride_ratings rr
               where rr.partner_id = p_partner and rr.updated_at > now() - make_interval(days => v_days)),
    'tags', coalesce((select jsonb_agg(jsonb_build_object('tag', c.tag, 'low', c.low, 'n', c.n)
                                       order by c.low, c.n desc, c.tag)
                        from public.driver_rating_tag_counts(p_partner, v_days) c), '[]'::jsonb),
    'flags', coalesce((select jsonb_agg(jsonb_build_object('tag', f.tag, 'n', f.n) order by f.n desc, f.tag)
                         from public.driver_rating_flags_for(p_partner) f), '[]'::jsonb));
end;
$$;
revoke execute on function public.admin_driver_rating_tags(uuid) from public, anon;
grant execute on function public.admin_driver_rating_tags(uuid) to authenticated;

-- The Partners list: every flagged driver (account id) and tag.
create or replace function public.admin_rating_flags()
returns table (partner_id uuid, tag text, n integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
    select p.pid, f.tag, f.n
      from (select distinct rr.partner_id as pid
              from public.ride_ratings rr
             where rr.tags <> '{}'
               and rr.updated_at > now() - make_interval(days => coalesce(
                     (select days from public.driver_rating_flag_rule where id limit 1), 30))) p
     cross join lateral public.driver_rating_flags_for(p.pid) f;
end;
$$;
revoke execute on function public.admin_rating_flags() from public, anon;
grant execute on function public.admin_rating_flags() to authenticated;

create or replace function public.admin_rating_flag_review(p_partner uuid, p_tag text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.caller_admin_can_write('rpc:admin_rating_flag_review') then
    raise exception 'Only admins who can edit partners can mark a flag reviewed.' using errcode = '42501';
  end if;
  if p_partner is null or coalesce(btrim(p_tag), '') = '' then
    raise exception 'RATING_FLAG_BAD' using errcode = '22023';
  end if;
  insert into public.driver_rating_flag_reviews (partner_id, tag, reviewed_at, reviewed_by)
  values (p_partner, btrim(p_tag), now(), auth.uid())
  on conflict (partner_id, tag) do update set reviewed_at = now(), reviewed_by = auth.uid();
end;
$$;
revoke execute on function public.admin_rating_flag_review(uuid, text) from public, anon;
grant execute on function public.admin_rating_flag_review(uuid, text) to authenticated;

notify pgrst, 'reload schema';
