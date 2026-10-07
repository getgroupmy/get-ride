-- 0105: support calls that carry audio, in both directions.
--
-- support_calls (0037) only ever rang: an admin inserted a row, the user's
-- app showed a call screen and both sides counted seconds, but no audio was
-- ever connected. Calls now carry voice over WebRTC, peer to peer, with this
-- database as the signalling channel:
--
--   * a call can be started by either side. caller_role 'user' is a user
--     ringing support from their ticket; any agent may answer, and the first
--     to do so is stamped answered_by (a conditional update, so two agents
--     can't both take it). caller_id is who started it.
--   * support_call_signals carries the WebRTC setup between the two people
--     on a call (offer, answer, ICE candidates, hang-up). Only they can read
--     or write a call's signals, and they are deleted when the call ends:
--     an SDP names the caller's network addresses.
--   * a guard keeps a non-admin client to its own side of a call: it can
--     only ring support as itself, and afterwards only move the status
--     (never answer its own call, re-target it, or claim it for an agent).
--
-- The turn-credentials edge function hands out the relay credentials a call
-- needs on networks that block a direct connection.

alter table public.support_calls
  add column if not exists caller_id uuid references public.profiles(id) on delete set null,
  add column if not exists answered_by uuid references public.profiles(id) on delete set null,
  add column if not exists answered_by_name text;

alter table public.support_calls drop constraint if exists support_calls_caller_role_check;
alter table public.support_calls
  add constraint support_calls_caller_role_check check (caller_role in ('admin', 'user'));

create index if not exists support_calls_ringing_idx
  on public.support_calls (created_at desc) where status = 'ringing';

-- Who is on a call: the user it is about, whoever rang, whoever answered.
create or replace function public.support_call_participant(p_call uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.support_calls c
     where c.id = p_call
       and auth.uid() is not null
       and auth.uid() in (c.profile_id, c.caller_id, c.answered_by)
  );
$$;
revoke all on function public.support_call_participant(uuid) from public;
grant execute on function public.support_call_participant(uuid) to authenticated;

create or replace function public.support_calls_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if public.caller_is_admin() then
    if tg_op = 'INSERT' and new.caller_id is null and new.caller_role = 'admin' then
      new.caller_id := auth.uid();
    end if;
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.caller_role <> 'user'
       or new.profile_id is distinct from auth.uid()
       or new.answered_by is not null
       or new.status <> 'ringing' then
      raise exception 'SUPPORT_CALL_NOT_ALLOWED' using errcode = '42501',
        hint = 'A user can only ring support as themselves.';
    end if;
    new.caller_id := auth.uid();
    new.started_at := null;
    new.ended_at := null;
    return new;
  end if;
  if (new.profile_id, new.caller_role, new.caller_id, new.answered_by, new.answered_by_name,
      new.ticket_id, new.media)
       is distinct from
     (old.profile_id, old.caller_role, old.caller_id, old.answered_by, old.answered_by_name,
      old.ticket_id, old.media) then
    raise exception 'SUPPORT_CALL_NOT_ALLOWED' using errcode = '42501',
      hint = 'Only the call status can be changed.';
  end if;
  if old.status in ('ended', 'declined', 'missed') and new.status is distinct from old.status then
    raise exception 'SUPPORT_CALL_NOT_ALLOWED' using errcode = '42501',
      hint = 'A finished call stays finished.';
  end if;
  if old.caller_role = 'user' and new.status = 'accepted' and old.status <> 'accepted' then
    raise exception 'SUPPORT_CALL_NOT_ALLOWED' using errcode = '42501',
      hint = 'A support agent answers a call the user made.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_support_calls_guard on public.support_calls;
create trigger trg_support_calls_guard
  before insert or update on public.support_calls
  for each row execute function public.support_calls_guard();

create table if not exists public.support_call_signals (
  id bigint generated always as identity primary key,
  call_id uuid not null references public.support_calls(id) on delete cascade,
  sender uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('offer', 'answer', 'ice', 'bye')),
  payload jsonb not null default '{}'::jsonb check (octet_length(payload::text) <= 65536),
  created_at timestamptz not null default now()
);
create index if not exists support_call_signals_call_idx on public.support_call_signals (call_id, id);

alter table public.support_call_signals enable row level security;
drop policy if exists "support_call_signals participant select" on public.support_call_signals;
create policy "support_call_signals participant select" on public.support_call_signals
  for select to authenticated using (public.support_call_participant(call_id));
drop policy if exists "support_call_signals participant insert" on public.support_call_signals;
create policy "support_call_signals participant insert" on public.support_call_signals
  for insert to authenticated
  with check (sender = auth.uid() and public.support_call_participant(call_id));

-- A finished call's signals go with it.
create or replace function public.support_calls_clear_signals()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status in ('ended', 'declined', 'missed') and old.status is distinct from new.status then
    delete from public.support_call_signals where call_id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_support_calls_clear_signals on public.support_calls;
create trigger trg_support_calls_clear_signals
  after update of status on public.support_calls
  for each row execute function public.support_calls_clear_signals();

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'support_call_signals'
  ) then
    alter publication supabase_realtime add table public.support_call_signals;
  end if;
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'support_calls'
  ) then
    alter publication supabase_realtime add table public.support_calls;
  end if;
end
$$;
