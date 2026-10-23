-- ============================================================================
-- 0279 — Admin → Push Notification: a picture, a full message shown in the
-- app, partners by type, and sends scheduled ahead (once, daily, weekly,
-- monthly).
--
-- Applied by hand as version 20261024090000 (0279_push_composer in
-- supabase_migrations.schema_migrations). Re-runnable: every object is
-- created with "if not exists" / "or replace", policies, the trigger and the
-- cron job are dropped first.
--
-- 1. caller_push_admin(edit): whether the caller is an admin with a grant on
--    the Push Notification page (READ, or EDIT when [edit]): '*', the
--    Settings hub ('admin-settings') or 'admin-settings-push-notification',
--    as the panel and send-push (admin_can_edit, PUSH_PAGES) decide.
-- 2. public.push_messages: the full message a push opens in the app (title,
--    body, picture, and the admin's blocks: a small JSON list of headings,
--    paragraphs, bullet lists, buttons and pictures, never HTML; the app
--    reads it through lib/src/core/push_message.dart, which drops what it
--    does not know). Push editors write it; the people a push carrying its
--    id reached read it, through their own user_notifications row
--    (data.message_id, written by send-push), and nobody else.
-- 3. public.push_schedules: a push to send later, and again every day, week
--    or month (Malaysia time; a monthly push on the 31st goes on the last
--    day of a shorter month). Push admins read, push editors write; nobody
--    deletes (Cancel sets status 'cancelled').
--      push_schedule_next(prev, anchor, repeat): the next time after prev.
--      push_schedule_kick(body) (internal): POSTs the push to
--        /functions/v1/send-push over pg_net with the push webhook secret
--        (`x-push-secret`, Vault `push_webhook_secret`, 0128) and nothing
--        else, as location_ping_kick (0276).
--      push_schedules_due() (pg_cron, every minute): claims the due rows
--        (for update skip locked), kicks send-push for each with its
--        scheduleId, then moves next_at on for a repeat or marks it done.
--        send-push writes how it went into last_result and logs the
--        schedule id in push_notifications.
-- 4. push_notifications gains schedule_id, message_id, image_url and
--    partner_types, so the history says what was sent and why.
-- ============================================================================

-- ---- 1. Who may see and write pushes -----------------------------------------------------------
create or replace function public.caller_push_admin(p_edit boolean default false)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
  v_uid uuid;
begin
  if v_claims is null or v_claims = '' then
    return true; -- direct database session (migrations, psql, cron)
  end if;
  if coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    return true;
  end if;
  v_uid := auth.uid();
  if v_uid is null then
    return false;
  end if;
  return exists (
    select 1 from public.admin_access a
     where a.profile_id = v_uid
       and (not p_edit or a.access_level = 'edit')
       and a.page in ('*', 'admin-settings', 'admin-settings-push-notification'));
end;
$$;
revoke execute on function public.caller_push_admin(boolean) from public;
grant execute on function public.caller_push_admin(boolean) to anon, authenticated, service_role;

-- ---- 2. The full message -----------------------------------------------------------------------
create table if not exists public.push_messages (
  id         uuid primary key default gen_random_uuid(),
  title      text not null,
  body       text not null default '',
  image_url  text,
  blocks     jsonb not null default '[]'::jsonb,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
comment on table public.push_messages is
  'The full message an admin push opens in the app (0279): blocks are a small JSON list (heading, paragraph, bullets, button, image), never HTML.';

alter table public.push_messages drop constraint if exists push_messages_size_check;
alter table public.push_messages add constraint push_messages_size_check
  check (length(title) between 1 and 200
     and length(body) <= 2000
     and jsonb_typeof(blocks) = 'array'
     and jsonb_array_length(blocks) <= 80
     and octet_length(blocks::text) <= 60000);
alter table public.push_messages drop constraint if exists push_messages_image_check;
alter table public.push_messages add constraint push_messages_image_check
  check (image_url is null or (image_url ~ '^https://[^\s]+$' and length(image_url) <= 1000));

alter table public.push_messages enable row level security;
revoke all on public.push_messages from public, anon, authenticated;
grant select, insert, update on public.push_messages to authenticated;
grant all on public.push_messages to service_role;

-- The page's look-up: the caller's notifications that carry a message id.
create index if not exists user_notifications_message_idx
  on public.user_notifications (profile_id, (data ->> 'message_id'))
  where data ? 'message_id';

drop policy if exists push_messages_read on public.push_messages;
create policy push_messages_read on public.push_messages
  for select to authenticated
  using (
    (select public.caller_push_admin(false))
    or exists (select 1 from public.user_notifications n
                where n.profile_id = (select auth.uid())
                  and n.data ? 'message_id'
                  and n.data ->> 'message_id' = push_messages.id::text));

drop policy if exists push_messages_insert on public.push_messages;
create policy push_messages_insert on public.push_messages
  for insert to authenticated
  with check ((select public.caller_push_admin(true)) and created_by is not distinct from (select auth.uid()));

drop policy if exists push_messages_update on public.push_messages;
create policy push_messages_update on public.push_messages
  for update to authenticated
  using ((select public.caller_push_admin(true)))
  with check ((select public.caller_push_admin(true)));

-- ---- 3. Pushes sent later ----------------------------------------------------------------------
create table if not exists public.push_schedules (
  id            uuid primary key default gen_random_uuid(),
  title         text not null,
  body          text not null,
  image_url     text,
  message_id    uuid references public.push_messages(id) on delete set null,
  audience      text not null default 'all',
  partner_types text[] not null default '{}',
  approved_only boolean not null default true,
  area          jsonb,
  send_at       timestamptz not null,
  repeat        text not null default 'once',
  next_at       timestamptz,
  last_sent_at  timestamptz,
  last_result   jsonb,
  status        text not null default 'active',
  created_by    uuid default auth.uid() references auth.users(id) on delete set null,
  created_at    timestamptz not null default now()
);
comment on table public.push_schedules is
  'Admin pushes sent later and on repeat (0279), sent by push_schedules_due() through send-push. Malaysia time.';

alter table public.push_schedules drop constraint if exists push_schedules_values_check;
alter table public.push_schedules add constraint push_schedules_values_check
  check (audience in ('all', 'users', 'partners')
     and repeat in ('once', 'daily', 'weekly', 'monthly')
     and status in ('active', 'done', 'cancelled')
     and length(title) between 1 and 200
     and length(body) between 1 and 2000
     and coalesce(cardinality(partner_types), 0) <= 30
     and (image_url is null or (image_url ~ '^https://[^\s]+$' and length(image_url) <= 1000))
     and (area is null or jsonb_typeof(area) = 'object'));

create index if not exists push_schedules_due_idx on public.push_schedules (next_at) where status = 'active';

-- next_at follows send_at: set when the row is made, and again when the
-- admin moves the time or the repeat.
create or replace function public.push_schedules_next_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.send_at is distinct from old.send_at or new.repeat is distinct from old.repeat then
    new.next_at := new.send_at;
  end if;
  return new;
end;
$$;
revoke execute on function public.push_schedules_next_at() from public, anon, authenticated;

drop trigger if exists trg_push_schedules_next_at on public.push_schedules;
create trigger trg_push_schedules_next_at
  before insert or update of send_at, repeat on public.push_schedules
  for each row
  execute function public.push_schedules_next_at();

alter table public.push_schedules enable row level security;
revoke all on public.push_schedules from public, anon, authenticated;
grant select, insert, update on public.push_schedules to authenticated;
grant all on public.push_schedules to service_role;

drop policy if exists push_schedules_read on public.push_schedules;
create policy push_schedules_read on public.push_schedules
  for select to authenticated
  using ((select public.caller_is_admin()) and (select public.caller_push_admin(false)));

drop policy if exists push_schedules_insert on public.push_schedules;
create policy push_schedules_insert on public.push_schedules
  for insert to authenticated
  with check ((select public.caller_admin_can_write('push_schedules'))
              and created_by is not distinct from (select auth.uid()));

drop policy if exists push_schedules_update on public.push_schedules;
create policy push_schedules_update on public.push_schedules
  for update to authenticated
  using ((select public.caller_admin_can_write('push_schedules')))
  with check ((select public.caller_admin_can_write('push_schedules')));

-- Push Notification edits the schedules (Edit on 'admin-settings' covers it too).
insert into public.admin_table_pages (target, page) values
  ('push_schedules', 'admin-settings-push-notification')
on conflict do nothing;

-- The next time after [p_prev] for [p_repeat], in Malaysia time: a day or a
-- week on, or the next month on [p_anchor]'s day (the last day of a shorter
-- month) at [p_anchor]'s time. Null for 'once'.
create or replace function public.push_schedule_next(p_prev timestamptz, p_anchor timestamptz, p_repeat text)
returns timestamptz
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_prev   timestamp := p_prev at time zone 'Asia/Kuala_Lumpur';
  v_anchor timestamp := p_anchor at time zone 'Asia/Kuala_Lumpur';
  v_month  date;
  v_last   int;
  v_day    int;
begin
  if p_prev is null then
    return null;
  end if;
  case p_repeat
    when 'daily' then
      return (v_prev + interval '1 day') at time zone 'Asia/Kuala_Lumpur';
    when 'weekly' then
      return (v_prev + interval '7 days') at time zone 'Asia/Kuala_Lumpur';
    when 'monthly' then
      v_month := (date_trunc('month', v_prev) + interval '1 month')::date;
      v_last := extract(day from (v_month + interval '1 month' - interval '1 day'))::int;
      v_day := least(extract(day from coalesce(v_anchor, v_prev))::int, v_last);
      return ((v_month + (v_day - 1)) + coalesce(v_anchor, v_prev)::time) at time zone 'Asia/Kuala_Lumpur';
    else
      return null;
  end case;
end;
$$;
revoke execute on function public.push_schedule_next(timestamptz, timestamptz, text) from public, anon;
grant execute on function public.push_schedule_next(timestamptz, timestamptz, text) to authenticated, service_role;

-- The call: the push to send-push, with the push webhook secret and nothing
-- else. False when it could not be queued.
create or replace function public.push_schedule_kick(p_body jsonb)
returns boolean
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_url    text;
  v_secret text;
begin
  if p_body is null then
    return false;
  end if;
  begin
    select decrypted_secret into v_url
      from vault.decrypted_secrets where name = 'project_url' limit 1;
    select decrypted_secret into v_secret
      from vault.decrypted_secrets where name = 'push_webhook_secret' limit 1;
  exception when others then
    return false;
  end;
  if v_url is null or v_secret is null then
    return false;
  end if;
  perform net.http_post(
    url     := v_url || '/functions/v1/send-push',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body    := p_body
  );
  return true;
exception when others then
  return false;
end;
$$;
revoke execute on function public.push_schedule_kick(jsonb) from public, anon, authenticated;

-- The scheduled run: every due push (at most 20 a minute, oldest first) sent
-- through send-push, then its next time set, or marked done. A row whose
-- call could not be queued (no project_url / secret) stays due. How many
-- were sent.
create or replace function public.push_schedules_due()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r      public.push_schedules;
  v_next timestamptz;
  n      integer := 0;
begin
  for r in
    select s.* from public.push_schedules s
     where s.status = 'active' and s.next_at is not null and s.next_at <= now()
     order by s.next_at asc
     limit 20
       for update skip locked
  loop
    if not public.push_schedule_kick(jsonb_strip_nulls(jsonb_build_object(
         'title', r.title,
         'body', r.body,
         'audience', r.audience,
         'approvedOnly', case when r.audience = 'partners' then r.approved_only end,
         'partnerTypes', case when coalesce(cardinality(r.partner_types), 0) > 0 then to_jsonb(r.partner_types) end,
         'area', r.area,
         'image', r.image_url,
         'messageId', r.message_id,
         'scheduleId', r.id))) then
      exit;
    end if;
    v_next := public.push_schedule_next(r.next_at, r.send_at, r.repeat);
    -- After a pause (the job off for a while) the next time is in the
    -- future, not a run of catch-up pushes.
    while v_next is not null and v_next <= now() loop
      v_next := public.push_schedule_next(v_next, r.send_at, r.repeat);
    end loop;
    update public.push_schedules
       set last_sent_at = now(),
           last_result = jsonb_build_object('queued', true, 'at', now()),
           next_at = coalesce(v_next, r.next_at),
           status = case when v_next is null then 'done' else 'active' end
     where id = r.id;
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function public.push_schedules_due() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'push-schedules-due';
    perform cron.schedule('push-schedules-due', '* * * * *', $job$select public.push_schedules_due()$job$);
  end if;
end $$;

-- ---- 4. What the history keeps -----------------------------------------------------------------
alter table public.push_notifications
  add column if not exists schedule_id uuid,
  add column if not exists message_id uuid,
  add column if not exists image_url text,
  add column if not exists partner_types text[];
comment on column public.push_notifications.schedule_id is
  'The push_schedules row this send came from (0279); null for one sent at once.';

notify pgrst, 'reload schema';
insert into supabase_migrations.schema_migrations (version, name) values ('20261024090000', '0279_push_composer') on conflict do nothing;
