-- ============================================================================
-- 0286 — Admin › Partners › Edit Partner › Change status: support asks a
-- partner's phone to go online, go offline, link or unlink a vehicle, and
-- the phone confirms.
--
-- Applied by hand as version 20261024160000 (0286_partner_remote_actions in
-- supabase_migrations.schema_migrations). Re-runnable: every object is
-- created with "if not exists" / "or replace".
--
-- Why: support on the phone with a driver ("I can't go online") had no way
-- to do it for them, and setting driver_presence from the admin would skip
-- every rule the driver's own switch applies (documents, approved vehicle,
-- credit, vehicle in use, region rules, permits). So the admin only asks;
-- the phone does it through the driver's own code and says how it went.
--
-- 1. partner_remote_actions: one request a row (profile_id = the partner's
--    login; action go_online / go_offline / link_vehicle / unlink_vehicle;
--    vehicle_id for a link). status:
--      queued   asked, the push not out yet;
--      sent     the push went out (or the phone has it and waits for the
--               driver to tap: waiting_driver);
--      done     the phone did it;
--      refused  the phone's own rules said no (reason: what the driver's
--               own flow says);
--      expired  no answer in 2 minutes.
--    One open (queued / sent) a partner. Nobody writes it directly: the
--    functions below. The partner reads their own rows; admins read through
--    partner_remote_action_status.
-- 2. partner_remote_action_request(profile, action, vehicle) (authenticated):
--    only an admin with EDIT on the Partners pages
--    (caller_admin_can_write('rpc:partner_remote_action_request')). Checks
--    what the server can up front (a partner, a vehicle that exists and is
--    not held by another driver who is online or on a job), expires stale
--    ones, logs 'partner.remote_action' in admin_audit_log and kicks the
--    push: location-ping (0276) with { actionId, reason: 'remote_action' },
--    over pg_net with the existing push webhook secret (x-push-secret) and
--    nothing else. The function sends a silent push `{ type:
--    partner_remote_action, id, title, body }` (an iPhone a background
--    push, Android data-only high priority).
-- 3. partner_remote_action_targets(id) / partner_remote_action_sent(id, n)
--    (service role only): the phones to send to, and "the push is out".
-- 4. The phone: partner_remote_action_mine(id) reads the open request (its
--    own only); partner_remote_action_seen(id, waiting_driver) says it has
--    it; partner_remote_action_report(id, result, reason, local_time) says
--    done / refused, only by the partner themself, only while open. Done
--    leaves a line in the driver's notifications ("Support set you offline
--    at 3:12 PM"). The result is logged ('partner.remote_action_result').
-- 5. partner_remote_action_status(profile) (authenticated): the latest
--    request for Edit Partner's card, to admins who may read the Partners
--    pages; expires it first when its 2 minutes are up (logged).
-- ============================================================================

-- ---- 1. The requests ----------------------------------------------------------------------------
create table if not exists public.partner_remote_actions (
  id             uuid primary key default gen_random_uuid(),
  profile_id     uuid not null references public.profiles (id) on delete cascade,
  partner_id     uuid references public.partners (id) on delete set null,
  action         text not null check (action in ('go_online', 'go_offline', 'link_vehicle', 'unlink_vehicle')),
  vehicle_id     uuid references public.vehicle (id) on delete set null,
  status         text not null default 'queued' check (status in ('queued', 'sent', 'done', 'refused', 'expired')),
  reason         text check (reason is null or char_length(reason) <= 500),
  waiting_driver boolean not null default false,
  requested_by   uuid references public.profiles (id) on delete set null,
  created_at     timestamptz not null default now(),
  sent_at        timestamptz,
  seen_at        timestamptz,
  answered_at    timestamptz,
  expires_at     timestamptz not null default now() + interval '2 minutes'
);
comment on table public.partner_remote_actions is
  'Admin › Edit Partner › Change status (0286): support asks the partner''s phone to go online / offline or link / unlink a vehicle; the phone runs it through the driver''s own code and reports done / refused. Who asked and the result are in admin_audit_log.';

-- One open request a partner.
create unique index if not exists partner_remote_actions_open_idx
  on public.partner_remote_actions (profile_id) where status in ('queued', 'sent');
create index if not exists partner_remote_actions_profile_created_idx
  on public.partner_remote_actions (profile_id, created_at desc);

alter table public.partner_remote_actions enable row level security;
revoke all on public.partner_remote_actions from public, anon, authenticated;
grant select on public.partner_remote_actions to authenticated;
grant all on public.partner_remote_actions to service_role;

drop policy if exists partner_remote_actions_select_own on public.partner_remote_actions;
create policy partner_remote_actions_select_own on public.partner_remote_actions
  for select to authenticated using (profile_id = (select auth.uid()));

insert into public.admin_table_pages (target, page) values
  ('rpc:partner_remote_action_request', 'admin-partners'),
  ('rpc:partner_remote_action_request', 'admin-partner-edit')
on conflict do nothing;

-- The request as the card and the phone read it.
create or replace function public.partner_remote_action_json(r public.partner_remote_actions)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', r.id, 'profile_id', r.profile_id, 'action', r.action, 'vehicle_id', r.vehicle_id,
    'vehicle_plate', (select v.plate from public.vehicle v where v.id = r.vehicle_id),
    'status', r.status, 'reason', r.reason, 'waiting_driver', r.waiting_driver,
    'created_at', r.created_at, 'sent_at', r.sent_at, 'seen_at', r.seen_at,
    'answered_at', r.answered_at, 'expires_at', r.expires_at, 'now', now());
$$;
revoke execute on function public.partner_remote_action_json(public.partner_remote_actions) from public, anon, authenticated;

-- Open requests whose 2 minutes are up become 'expired' (one partner's, or
-- everyone's), each logged. How many.
create or replace function public.partner_remote_actions_expire(p_profile_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  n integer := 0;
  r record;
begin
  for r in
    update public.partner_remote_actions a
       set status = 'expired', answered_at = now()
     where a.status in ('queued', 'sent')
       and a.expires_at <= now()
       and (p_profile_id is null or a.profile_id = p_profile_id)
    returning a.id, a.profile_id, a.action, a.requested_by
  loop
    insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
    values (r.requested_by, 'partner.remote_action_result', r.profile_id,
            jsonb_build_object('id', r.id, 'action', r.action, 'result', 'expired'));
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function public.partner_remote_actions_expire(uuid) from public, anon, authenticated;

-- What the phone's notification says until the driver taps it.
create or replace function public.partner_remote_action_prompt(p_action text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_action
           when 'go_online' then 'Support asked you to go online'
           when 'go_offline' then 'Support asked you to go offline'
           when 'link_vehicle' then 'Support asked you to use a vehicle'
           when 'unlink_vehicle' then 'Support asked you to hand back your vehicle'
           else 'Support sent you a request'
         end;
$$;
revoke execute on function public.partner_remote_action_prompt(text) from public, anon;
grant execute on function public.partner_remote_action_prompt(text) to authenticated, service_role;

-- ---- 2. The admin asks ----------------------------------------------------------------------------
-- The push: { actionId, reason } to location-ping, with the push webhook
-- secret and nothing else (as location_ping_kick, 0276). False when it
-- could not be queued.
create or replace function public.partner_remote_action_kick(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_url    text;
  v_secret text;
begin
  if p_id is null then
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
    url     := v_url || '/functions/v1/location-ping',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body    := jsonb_build_object('actionId', p_id, 'reason', 'remote_action')
  );
  return true;
exception when others then
  return false;
end;
$$;
revoke execute on function public.partner_remote_action_kick(uuid) from public, anon, authenticated;

-- Whether [p_profile_id] is online (a fresh report) or on a job.
create or replace function public.partner_remote_driver_busy(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.driver_presence d
                  where d.profile_id = p_profile_id and d.online
                    and d.updated_at > now() - interval '3 minutes')
      or exists (select 1 from public.ride_requests r
                  where r.partner_id = p_profile_id and r.status in ('accepted', 'arrived', 'on_trip'));
$$;
revoke execute on function public.partner_remote_driver_busy(uuid) from public, anon, authenticated;

create or replace function public.partner_remote_action_request(
  p_profile_id uuid,
  p_action text,
  p_vehicle_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_partner uuid;
  v_plate text;
  v_holder uuid;
  v_row public.partner_remote_actions;
  v_posted boolean;
begin
  if not public.caller_admin_can_write('rpc:partner_remote_action_request') then
    raise exception 'Only admins who can edit partners can change a partner''s status.' using errcode = '42501';
  end if;
  if p_action is null or p_action not in ('go_online', 'go_offline', 'link_vehicle', 'unlink_vehicle') then
    raise exception 'That is not something the phone can be asked to do.' using errcode = '22023';
  end if;
  select p.id into v_partner
    from public.partners p
    join public.profiles pr on pr.id = p.auth_user_id and pr.deleted_at is null
   where p.auth_user_id = p_profile_id
   order by p.created_at
   limit 1;
  if v_partner is null then
    raise exception 'This partner has no account on the app to ask.' using errcode = 'P0002';
  end if;
  if p_action = 'link_vehicle' then
    select v.plate into v_plate from public.vehicle v where v.id = p_vehicle_id;
    if p_vehicle_id is null or not found then
      raise exception 'That vehicle does not exist.' using errcode = 'P0002';
    end if;
    -- Another driver driving it (a session) or linked to it (the plate), while
    -- online or on a job, keeps it: the phone would be refused anyway.
    select h.uid into v_holder
      from (select s.user_id as uid from public.vehicle_active_session s where s.vehicle_id = p_vehicle_id
            union
            select p.auth_user_id from public.partners p
             where v_plate is not null and btrim(v_plate) <> ''
               and upper(btrim(p.plate)) = upper(btrim(v_plate))) h
     where h.uid is not null and h.uid <> p_profile_id
       and public.partner_remote_driver_busy(h.uid)
     limit 1;
    if v_holder is not null then
      raise exception 'Another driver is online or on a job with this vehicle. Ask them to go offline first.'
        using errcode = 'P0001';
    end if;
  elsif p_vehicle_id is not null then
    raise exception 'Only linking takes a vehicle.' using errcode = '22023';
  end if;

  perform public.partner_remote_actions_expire(p_profile_id);
  if exists (select 1 from public.partner_remote_actions a
              where a.profile_id = p_profile_id and a.status in ('queued', 'sent')) then
    raise exception 'A request is already waiting for this driver''s phone.' using errcode = 'P0001';
  end if;

  insert into public.partner_remote_actions (profile_id, partner_id, action, vehicle_id, requested_by)
  values (p_profile_id, v_partner, p_action, p_vehicle_id, v_uid)
  returning * into v_row;
  v_posted := public.partner_remote_action_kick(v_row.id);
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'partner.remote_action', p_profile_id,
          jsonb_build_object('id', v_row.id, 'action', p_action, 'vehicle_id', p_vehicle_id, 'posted', v_posted));
  return public.partner_remote_action_json(v_row) || jsonb_build_object('posted', v_posted);
end;
$$;
revoke execute on function public.partner_remote_action_request(uuid, text, uuid) from public, anon;
grant execute on function public.partner_remote_action_request(uuid, text, uuid) to authenticated;

-- ---- 3. The push (location-ping, service role) ----------------------------------------------------
-- The phones to send an open request to, with what the notification says.
-- Never the phone number.
create or replace function public.partner_remote_action_targets(p_id uuid)
returns table (id uuid, token text, platform text, title text, body text)
language sql
stable
security definer
set search_path = ''
as $$
  select t.id, t.token, t.platform, public.partner_remote_action_prompt(a.action), 'Tap to confirm'
    from public.partner_remote_actions a
    join public.push_tokens t on t.profile_id = a.profile_id
    join public.profiles p on p.id = a.profile_id and p.deleted_at is null
   where a.id = p_id
     and a.status in ('queued', 'sent')
     and a.expires_at > now()
     and t.platform in ('ios', 'android')
     and t.token not like 'ExponentPushToken[%'
     and t.token not like 'ExpoPushToken[%'
   order by t.id
   limit 20;
$$;
revoke execute on function public.partner_remote_action_targets(uuid) from public, anon, authenticated;
grant execute on function public.partner_remote_action_targets(uuid) to service_role;

-- The push is out to [p_sent] phones: queued becomes sent.
create or replace function public.partner_remote_action_sent(p_id uuid, p_sent integer)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.partner_remote_actions
     set status = 'sent', sent_at = coalesce(sent_at, now())
   where id = p_id and status = 'queued' and coalesce(p_sent, 0) > 0 and expires_at > now();
$$;
revoke execute on function public.partner_remote_action_sent(uuid, integer) from public, anon, authenticated;
grant execute on function public.partner_remote_action_sent(uuid, integer) to service_role;

-- ---- 4. The phone ---------------------------------------------------------------------------------
-- The caller's open request: [p_id], or the newest open one. Null when none.
create or replace function public.partner_remote_action_mine(p_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.partner_remote_actions;
begin
  if v_uid is null then
    return null;
  end if;
  perform public.partner_remote_actions_expire(v_uid);
  select * into v_row
    from public.partner_remote_actions a
   where a.profile_id = v_uid
     and a.status in ('queued', 'sent')
     and (p_id is null or a.id = p_id)
   order by a.created_at desc
   limit 1;
  if not found then
    return null;
  end if;
  return public.partner_remote_action_json(v_row);
end;
$$;
revoke execute on function public.partner_remote_action_mine(uuid) from public, anon;
grant execute on function public.partner_remote_action_mine(uuid) to authenticated;

-- The phone has it; [p_waiting_driver] when it waits for the driver's tap.
create or replace function public.partner_remote_action_seen(p_id uuid, p_waiting_driver boolean)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.partner_remote_actions
     set status = 'sent', sent_at = coalesce(sent_at, now()), seen_at = coalesce(seen_at, now()),
         waiting_driver = coalesce(p_waiting_driver, false)
   where id = p_id and profile_id = (select auth.uid())
     and status in ('queued', 'sent') and expires_at > now();
$$;
revoke execute on function public.partner_remote_action_seen(uuid, boolean) from public, anon;
grant execute on function public.partner_remote_action_seen(uuid, boolean) to authenticated;

-- What the phone did: 'done', or 'refused' with the reason the driver's own
-- flow gave. Only the partner themself, only while open. [p_local_time] is
-- the phone's clock ("3:12 PM"), for the line in their notifications.
-- Returns the request as it stands (expired when it came too late).
create or replace function public.partner_remote_action_report(
  p_id uuid,
  p_result text,
  p_reason text default null,
  p_local_time text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.partner_remote_actions;
  v_time text := btrim(coalesce(p_local_time, ''));
  v_what text;
begin
  if p_result is null or p_result not in ('done', 'refused') then
    raise exception 'The result is done or refused.' using errcode = '22023';
  end if;
  select * into v_row from public.partner_remote_actions a where a.id = p_id for update;
  if not found or v_uid is null or v_row.profile_id <> v_uid then
    raise exception 'Only the partner it was sent to can answer it.' using errcode = '42501';
  end if;
  perform public.partner_remote_actions_expire(v_uid);
  select * into v_row from public.partner_remote_actions a where a.id = p_id;
  if v_row.status not in ('queued', 'sent') then
    return public.partner_remote_action_json(v_row);
  end if;
  update public.partner_remote_actions a
     set status = p_result,
         reason = case when p_result = 'refused'
                       then left(coalesce(nullif(btrim(p_reason), ''), 'The phone said no.'), 500) end,
         answered_at = now(), seen_at = coalesce(a.seen_at, now()), sent_at = coalesce(a.sent_at, now())
   where a.id = p_id
  returning * into v_row;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_row.requested_by, 'partner.remote_action_result', v_row.profile_id,
          jsonb_build_object('id', v_row.id, 'action', v_row.action, 'result', p_result, 'reason', v_row.reason));
  if p_result = 'done' then
    if v_time !~ '^[0-9]{1,2}[:.][0-9]{2}( ?([AaPp][Mm]))?$' then
      v_time := '';
    end if;
    v_what := case v_row.action
                when 'go_online' then 'Support set you online'
                when 'go_offline' then 'Support set you offline'
                when 'link_vehicle' then 'Support linked your vehicle'
                else 'Support unlinked your vehicle'
              end;
    insert into public.user_notifications (profile_id, title, body, data, kind, mode, event_id)
    values (v_row.profile_id, v_what,
            v_what || case when v_time = '' then '.' else ' at ' || v_time || '.' end,
            jsonb_build_object('type', 'partner_remote_action', 'action_id', v_row.id, 'action', v_row.action),
            'partner_remote_action', 'partner', 'remote:' || v_row.id)
    on conflict (profile_id, event_id) do nothing;
  end if;
  return public.partner_remote_action_json(v_row);
end;
$$;
revoke execute on function public.partner_remote_action_report(uuid, text, text, text) from public, anon;
grant execute on function public.partner_remote_action_report(uuid, text, text, text) to authenticated;

-- ---- 5. The card ----------------------------------------------------------------------------------
-- The partner's latest request (expired first when its time is up), for
-- admins who may read or edit the Partners pages. Null when there is none.
create or replace function public.partner_remote_action_status(p_profile_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.partner_remote_actions;
begin
  if not (public.caller_admin_can_write('rpc:partner_remote_action_request')
          or (v_uid is not null and (public.admin_can_read(v_uid, 'admin-partners')
                                     or public.admin_can_read(v_uid, 'admin-partner-edit')))) then
    raise exception 'Only admins who can see partners can read this.' using errcode = '42501';
  end if;
  perform public.partner_remote_actions_expire(p_profile_id);
  select * into v_row
    from public.partner_remote_actions a
   where a.profile_id = p_profile_id
   order by a.created_at desc
   limit 1;
  if not found then
    return null;
  end if;
  return public.partner_remote_action_json(v_row);
end;
$$;
revoke execute on function public.partner_remote_action_status(uuid) from public, anon;
grant execute on function public.partner_remote_action_status(uuid) to authenticated;

notify pgrst, 'reload schema';
insert into supabase_migrations.schema_migrations (version, name) values ('20261024160000', '0286_partner_remote_actions') on conflict do nothing;
