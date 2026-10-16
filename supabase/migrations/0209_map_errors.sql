-- ============================================================================
-- 0209 · Admin → Settings → Maps → Usage: what went wrong.
--
-- Each failed call through the geo function (a refused Google map session,
-- a provider that said no or nothing, a search that found nothing) is kept
-- for 30 days with its reason, provider, kind and the rider's or partner's
-- device. Tapping a Usage row lists that row's latest 30, and more on asking.
--
--   geo_log_error(provider, kind, role, device, detail)   the geo function only
--   map_errors(provider, kind, before_id, limit)            admins: newest first
--
-- The reasons never carry a key (the function reports a host and Google's
-- reason codes only). Pruned with the cache, hourly.
-- ============================================================================

create table if not exists public.geo_errors (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  provider text not null,
  kind text not null,
  role text,
  device text,
  detail text not null
);
create index if not exists geo_errors_provider_kind_id on public.geo_errors (provider, kind, id desc);
create index if not exists geo_errors_at on public.geo_errors (at);

alter table public.geo_errors enable row level security;
revoke all on public.geo_errors from public, anon, authenticated;

create or replace function public.geo_log_error(
  p_provider text, p_kind text, p_role text, p_device text, p_detail text
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.geo_errors (provider, kind, role, device, detail)
  values (left(p_provider, 40), left(p_kind, 20), left(p_role, 20), left(p_device, 20),
          left(coalesce(nullif(trim(p_detail), ''), 'Failed'), 500));
$$;
revoke execute on function public.geo_log_error(text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.geo_log_error(text, text, text, text, text) to service_role;

-- Admin: [p_provider]'s [p_kind] errors, newest first, [p_limit] (30, at most
-- 100) older than [p_before] (an id; null for the newest).
create or replace function public.map_errors(
  p_provider text, p_kind text, p_before bigint default null, p_limit integer default 30
)
returns table (id bigint, at timestamptz, role text, device text, detail text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
    select e.id, e.at, e.role, e.device, e.detail
      from public.geo_errors e
     where e.provider = p_provider and e.kind = p_kind
       and (p_before is null or e.id < p_before)
     order by e.id desc
     limit greatest(1, least(coalesce(p_limit, 30), 100));
end;
$$;
revoke execute on function public.map_errors(text, text, bigint, integer) from public, anon;
grant execute on function public.map_errors(text, text, bigint, integer) to authenticated;

create or replace function public.geo_cache_prune()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.geo_cache where expires_at < now();
  delete from public.geo_rate where window_start < now() - interval '10 minutes';
  delete from public.geo_usage_daily where day < current_date - 400;
  delete from public.geo_errors where at < now() - interval '30 days';
$$;
revoke execute on function public.geo_cache_prune() from public, anon, authenticated;

notify pgrst, 'reload schema';
