-- ============================================================================
-- 0167: the notifications page (side menu -> Notifications)
--
-- Every notification an account is sent is also kept here, so it can be
-- read again after the banner is gone, on any phone, after a reinstall.
-- send-push writes the rows (service role) for each recipient account,
-- including those whose phone was in the other mode; the page then shows
-- the ones for the mode the app is in plus the account's own business
-- (mode null). A ringing call, a ride offer and a chat message are not
-- kept: each has its own screen and is stale within minutes.
--
-- Clients read their own rows and change them only through the two
-- functions below. Rows older than 90 days are cleared daily.
-- ============================================================================

create table if not exists public.user_notifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  title text not null,
  body text not null,
  data jsonb not null default '{}'::jsonb,
  kind text,
  mode text check (mode is null or mode in ('rider', 'partner')),
  -- An outbox event (0144) is retried; it is kept once.
  event_id text,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  constraint user_notifications_event_key unique (profile_id, event_id)
);

create index if not exists user_notifications_profile_created_idx
  on public.user_notifications (profile_id, created_at desc);
create index if not exists user_notifications_created_idx on public.user_notifications (created_at);

alter table public.user_notifications enable row level security;
revoke all on public.user_notifications from public, anon, authenticated;
grant select on public.user_notifications to authenticated;
grant all on public.user_notifications to service_role;

drop policy if exists user_notifications_select_own on public.user_notifications;
create policy user_notifications_select_own on public.user_notifications
  for select to authenticated
  using (profile_id = (select auth.uid()));

-- Marks the caller's notifications read: [p_ids], or all of them when null.
create or replace function public.notifications_mark_read(p_ids uuid[] default null)
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
  update public.user_notifications
     set read_at = now()
   where profile_id = auth.uid()
     and read_at is null
     and (p_ids is null or id = any(p_ids));
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Removes the caller's notifications [p_ids].
create or replace function public.notifications_delete(p_ids uuid[])
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
  delete from public.user_notifications
   where profile_id = auth.uid()
     and id = any(coalesce(p_ids, '{}'));
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke execute on function public.notifications_mark_read(uuid[]) from public, anon;
revoke execute on function public.notifications_delete(uuid[]) from public, anon;
grant execute on function public.notifications_mark_read(uuid[]) to authenticated, service_role;
grant execute on function public.notifications_delete(uuid[]) to authenticated, service_role;

-- The badge and the page follow new rows live.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and tablename = 'user_notifications') then
    alter publication supabase_realtime add table public.user_notifications;
  end if;
end
$$;

-- Ninety days is plenty to read a notification again.
do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule(
      'user-notifications-sweep',
      '23 3 * * *',
      $sql$delete from public.user_notifications where created_at < now() - interval '90 days'$sql$
    );
  end if;
end
$$;
