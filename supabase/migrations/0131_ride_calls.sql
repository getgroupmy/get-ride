-- ============================================================================
-- 0131: in-app voice calls between a rider and their driver
--
-- The trip screens' Call button opened the phone's dialer, which needs a
-- phone number on both sides and shows each side the other's number. Calls
-- now go over the same WebRTC engine as support calls (0105), with this
-- database as the signalling channel, but in tables of their own: a ride
-- call has two fixed participants taken from the ride, not a ticket and a
-- queue of agents, so support_calls and its guard are left alone.
--
--   * ride_calls is one call on one ride_requests row. Either participant
--     rings the other while the ride is accepted / arrived / on_trip; who is
--     calling whom, and the names shown, are filled in from the ride (never
--     a phone number). One live call per ride at a time.
--   * status only moves forward:
--       ringing → answered | declined | missed | cancelled,  answered → ended.
--     Only the callee answers or declines, only the caller cancels, either
--     ends (trg_ride_calls_guard). A call that has rung for 45 seconds is
--     missed: answering or declining it then records 'missed' instead, and
--     ringing again on the ride clears it, so no cron is needed.
--   * the ride leaving accepted / arrived / on_trip, or changing driver,
--     ends its live call (trg_ride_requests_end_calls).
--   * ride_call_signals carries the WebRTC setup (offer, answer, ICE, bye)
--     between the two, exactly as support_call_signals does, and is deleted
--     when the call is over: an SDP names the caller's network addresses.
--   * a new call pushes the callee (data.type 'ride_call', with the call id
--     and the callee's role so the tap opens the right screen).
-- ============================================================================

create table if not exists public.ride_calls (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.ride_requests(id) on delete cascade,
  caller_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  callee_id uuid not null references public.profiles(id) on delete cascade,
  caller_role text not null check (caller_role in ('rider', 'partner')),
  caller_name text,
  callee_name text,
  status text not null default 'ringing'
    check (status in ('ringing', 'answered', 'declined', 'missed', 'cancelled', 'ended')),
  created_at timestamptz not null default now(),
  answered_at timestamptz,
  ended_at timestamptz
);

create index if not exists ride_calls_request_idx on public.ride_calls (request_id, created_at desc);
create index if not exists ride_calls_callee_ringing_idx on public.ride_calls (callee_id) where status = 'ringing';
-- One live call per ride (both ringing each other at once: the second fails).
create unique index if not exists ride_calls_one_live_idx
  on public.ride_calls (request_id) where status in ('ringing', 'answered');

-- How long a call rings before it is missed. On its own so it is tested on
-- its own, and so the app's 45 s (callRingTimeout) has one place to match.
create or replace function public.ride_call_rang_out(p_status text, p_created timestamptz, p_at timestamptz)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_status = 'ringing' and p_created is not null and p_at - p_created >= interval '45 seconds';
$$;

-- ---- RLS --------------------------------------------------------------------
alter table public.ride_calls enable row level security;

drop policy if exists "ride_calls participant read" on public.ride_calls;
drop policy if exists "ride_calls participant insert" on public.ride_calls;
drop policy if exists "ride_calls participant update" on public.ride_calls;

create policy "ride_calls participant read"
  on public.ride_calls for select to authenticated
  using (auth.uid() in (caller_id, callee_id));

-- The insert trigger fills in caller, callee and role from the ride; this
-- keeps the row it produced to the ride's own participants, while it runs.
create policy "ride_calls participant insert"
  on public.ride_calls for insert to authenticated
  with check (
    caller_id = auth.uid()
    and exists (
      select 1 from public.ride_requests r
       where r.id = ride_calls.request_id
         and r.status in ('accepted', 'arrived', 'on_trip')
         and auth.uid() in (r.rider_id, r.partner_id)
         and ride_calls.callee_id in (r.rider_id, r.partner_id)
    )
  );

-- Which participant may move the status where is the guard's job.
create policy "ride_calls participant update"
  on public.ride_calls for update to authenticated
  using (auth.uid() in (caller_id, callee_id))
  with check (auth.uid() in (caller_id, callee_id));

-- A client names the ride and moves the status; the rest is the triggers'.
revoke all on public.ride_calls from anon, authenticated;
grant select on public.ride_calls to authenticated;
grant insert (request_id) on public.ride_calls to authenticated;
grant update (status) on public.ride_calls to authenticated;

-- ---- Insert: who is calling whom, from the ride --------------------------------
create or replace function public.ride_calls_before_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_uid uuid := coalesce(auth.uid(), new.caller_id);
begin
  select rider_id, partner_id, rider_name, partner_name, status into r
    from public.ride_requests where id = new.request_id;
  if not found or r.status not in ('accepted', 'arrived', 'on_trip')
     or r.rider_id is null or r.partner_id is null or r.rider_id = r.partner_id then
    raise exception 'RIDE_CALL_NOT_ALLOWED' using errcode = '42501',
      hint = 'Calls are only between the rider and driver of a ride in progress.';
  end if;
  if v_uid = r.rider_id then
    new.caller_role := 'rider';
    new.callee_id := r.partner_id;
  elsif v_uid = r.partner_id then
    new.caller_role := 'partner';
    new.callee_id := r.rider_id;
  else
    raise exception 'RIDE_CALL_NOT_ALLOWED' using errcode = '42501',
      hint = 'Calls are only between the rider and driver of a ride in progress.';
  end if;
  new.caller_id := v_uid;
  new.caller_name := case new.caller_role
    when 'rider' then coalesce(nullif(btrim(coalesce(r.rider_name, '')), ''), 'Your passenger')
    else coalesce(nullif(btrim(coalesce(r.partner_name, '')), ''), 'Your driver') end;
  new.callee_name := case new.caller_role
    when 'rider' then coalesce(nullif(btrim(coalesce(r.partner_name, '')), ''), 'Your driver')
    else coalesce(nullif(btrim(coalesce(r.rider_name, '')), ''), 'Your passenger') end;
  new.status := 'ringing';
  new.created_at := now();
  new.answered_at := null;
  new.ended_at := null;
  -- A call on this ride that rang out without anyone recording it is missed,
  -- so it no longer holds the ride's one live call.
  update public.ride_calls
     set status = 'missed'
   where request_id = new.request_id
     and public.ride_call_rang_out(status, created_at, now());
  return new;
end;
$$;

revoke execute on function public.ride_calls_before_insert() from public, anon, authenticated;

drop trigger if exists trg_ride_calls_before_insert on public.ride_calls;
create trigger trg_ride_calls_before_insert before insert on public.ride_calls
  for each row execute function public.ride_calls_before_insert();

-- ---- Update: only the status, only forward, only by the right side ------------
create or replace function public.ride_calls_guard()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_client boolean := current_user in ('anon', 'authenticated') and not public.caller_is_admin();
  v_expired boolean := public.ride_call_rang_out(old.status, old.created_at, now());
  v_ride_status text;
begin
  if (new.id, new.request_id, new.caller_id, new.callee_id, new.caller_role, new.caller_name,
      new.callee_name, new.created_at)
     is distinct from
     (old.id, old.request_id, old.caller_id, old.callee_id, old.caller_role, old.caller_name,
      old.callee_name, old.created_at) then
    raise exception 'RIDE_CALL_NOT_ALLOWED' using errcode = '42501', hint = 'Only a call''s status can change.';
  end if;
  if new.status is not distinct from old.status then
    new.answered_at := old.answered_at;
    new.ended_at := old.ended_at;
    return new;
  end if;
  if old.status in ('declined', 'missed', 'cancelled', 'ended') then
    raise exception 'RIDE_CALL_NOT_ALLOWED' using errcode = '42501', hint = 'A finished call stays finished.';
  end if;
  -- Too late to pick up or turn down: it rang out.
  if v_expired and new.status in ('answered', 'declined') then
    new.status := 'missed';
  end if;
  if not ((old.status = 'ringing' and new.status in ('answered', 'declined', 'missed', 'cancelled'))
          or (old.status = 'answered' and new.status = 'ended')) then
    raise exception 'RIDE_CALL_NOT_ALLOWED' using errcode = '42501',
      hint = format('A call cannot go from %s to %s.', old.status, new.status);
  end if;
  if v_client then
    if new.status in ('answered', 'declined') and auth.uid() is distinct from old.callee_id then
      raise exception 'RIDE_CALL_NOT_ALLOWED' using errcode = '42501', hint = 'Only the person called answers.';
    end if;
    if new.status = 'cancelled' and auth.uid() is distinct from old.caller_id then
      raise exception 'RIDE_CALL_NOT_ALLOWED' using errcode = '42501', hint = 'Only the caller cancels a call.';
    end if;
    if new.status = 'missed' and not v_expired and auth.uid() is distinct from old.caller_id then
      raise exception 'RIDE_CALL_NOT_ALLOWED' using errcode = '42501', hint = 'The call is still ringing.';
    end if;
    if new.status = 'answered' then
      select status into v_ride_status from public.ride_requests where id = old.request_id;
      if v_ride_status is null or v_ride_status not in ('accepted', 'arrived', 'on_trip') then
        raise exception 'RIDE_CALL_NOT_ALLOWED' using errcode = '42501', hint = 'The ride is over.';
      end if;
    end if;
  end if;
  if new.status = 'answered' then
    new.answered_at := now();
    new.ended_at := null;
  else
    new.answered_at := old.answered_at;
    new.ended_at := now();
  end if;
  return new;
end;
$$;

revoke execute on function public.ride_calls_guard() from public, anon, authenticated;

drop trigger if exists trg_ride_calls_guard on public.ride_calls;
create trigger trg_ride_calls_guard before update on public.ride_calls
  for each row execute function public.ride_calls_guard();

-- ---- The ride ending ends its call ----------------------------------------------
create or replace function public.ride_requests_end_calls()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status not in ('accepted', 'arrived', 'on_trip') or new.partner_id is distinct from old.partner_id then
    update public.ride_calls
       set status = case status when 'ringing' then 'cancelled' else 'ended' end
     where request_id = new.id and status in ('ringing', 'answered');
  end if;
  return new;
end;
$$;

revoke execute on function public.ride_requests_end_calls() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_end_calls on public.ride_requests;
create trigger trg_ride_requests_end_calls after update of status, partner_id on public.ride_requests
  for each row
  when (old.status is distinct from new.status or old.partner_id is distinct from new.partner_id)
  execute function public.ride_requests_end_calls();

-- ---- Signals ----------------------------------------------------------------
create table if not exists public.ride_call_signals (
  id bigint generated always as identity primary key,
  call_id uuid not null references public.ride_calls(id) on delete cascade,
  sender uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('offer', 'answer', 'ice', 'bye')),
  payload jsonb not null default '{}'::jsonb check (octet_length(payload::text) <= 65536),
  created_at timestamptz not null default now()
);
create index if not exists ride_call_signals_call_idx on public.ride_call_signals (call_id, id);

-- The ride_calls subqueries run under the caller's own RLS there, which
-- already keeps them to their own calls.
alter table public.ride_call_signals enable row level security;
drop policy if exists "ride_call_signals participant select" on public.ride_call_signals;
create policy "ride_call_signals participant select" on public.ride_call_signals
  for select to authenticated
  using (exists (
    select 1 from public.ride_calls c
     where c.id = ride_call_signals.call_id and auth.uid() in (c.caller_id, c.callee_id)
  ));
drop policy if exists "ride_call_signals participant insert" on public.ride_call_signals;
create policy "ride_call_signals participant insert" on public.ride_call_signals
  for insert to authenticated
  with check (
    sender = auth.uid()
    and exists (
      select 1 from public.ride_calls c
       where c.id = ride_call_signals.call_id
         and auth.uid() in (c.caller_id, c.callee_id)
         and c.status in ('ringing', 'answered')
    )
  );

revoke all on public.ride_call_signals from anon, authenticated;
grant select on public.ride_call_signals to authenticated;
grant insert (call_id, kind, payload) on public.ride_call_signals to authenticated;

-- A finished call's signals go with it.
create or replace function public.ride_calls_clear_signals()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status in ('declined', 'missed', 'cancelled', 'ended') and old.status is distinct from new.status then
    delete from public.ride_call_signals where call_id = new.id;
  end if;
  return new;
end;
$$;

revoke execute on function public.ride_calls_clear_signals() from public, anon, authenticated;

drop trigger if exists trg_ride_calls_clear_signals on public.ride_calls;
create trigger trg_ride_calls_clear_signals after update of status on public.ride_calls
  for each row execute function public.ride_calls_clear_signals();

-- ---- Push the callee ----------------------------------------------------------
create or replace function public.notify_ride_call_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.send_push_webhook(jsonb_build_object(
    'title', coalesce(new.caller_name, 'GET.ride') || ' is calling',
    'body', 'Voice call about your ride. Tap to answer.',
    'profileId', new.callee_id,
    'data', jsonb_build_object(
      'type', 'ride_call',
      'request_id', new.request_id,
      'call_id', new.id,
      'role', case new.caller_role when 'rider' then 'partner' else 'rider' end
    )
  ));
  return new;
exception when others then
  return new;
end;
$$;

revoke execute on function public.notify_ride_call_push() from public, anon, authenticated;

drop trigger if exists trg_ride_calls_push on public.ride_calls;
create trigger trg_ride_calls_push after insert on public.ride_calls
  for each row execute function public.notify_ride_call_push();

-- ---- Realtime -----------------------------------------------------------------
-- Both ends follow the call row and its signals; RLS decides who receives what.
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    return;
  end if;
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'ride_calls'
  ) then
    alter publication supabase_realtime add table public.ride_calls;
  end if;
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'ride_call_signals'
  ) then
    alter publication supabase_realtime add table public.ride_call_signals;
  end if;
end $$;
