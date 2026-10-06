-- ============================================================================
-- 0031_vehicle_user_assignments.sql
--
-- Tracks which users are permitted to use which vehicles, and which user is
-- currently using which vehicle.
--
-- 1) `public.vehicle_user_assignment` — many-to-many link table.
--      * A user can be assigned to many vehicles.
--      * A vehicle can be assigned to many users.
--      * Admins or users themselves can create rows here.
--      * (vehicle_id, user_id) is unique.
--
-- 2) `public.vehicle_active_session` — tracks the *currently in-use* pairing.
--      * Unique on vehicle_id  => only ONE user can use a vehicle at a time.
--      * Unique on user_id     => a user can drive only ONE vehicle at a time.
--      * A row exists only while the vehicle is online/in-use. Going offline
--        deletes the row (or sets ended_at via the helper RPC), freeing both
--        the vehicle and the user for a new session.
--
-- Safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. vehicle_user_assignment — permission link (many-to-many)
-- ---------------------------------------------------------------------------
create table if not exists public.vehicle_user_assignment (
  id            uuid primary key default gen_random_uuid(),
  vehicle_id    uuid not null references public.vehicle(id) on delete cascade,
  user_id       uuid not null,                       -- auth.users.id (driver)
  partner_id    uuid references public.partners(id) on delete set null,
  role          text not null default 'driver'
                  check (role in ('owner', 'driver', 'co-driver')),
  assigned_by   uuid,                                -- admin auth id, optional
  assigned_at   timestamptz not null default now(),
  is_active     boolean not null default true,       -- soft-disable a pairing
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint vehicle_user_assignment_unique unique (vehicle_id, user_id)
);

create index if not exists vehicle_user_assignment_vehicle_idx
  on public.vehicle_user_assignment(vehicle_id);
create index if not exists vehicle_user_assignment_user_idx
  on public.vehicle_user_assignment(user_id);
create index if not exists vehicle_user_assignment_partner_idx
  on public.vehicle_user_assignment(partner_id);
create index if not exists vehicle_user_assignment_active_idx
  on public.vehicle_user_assignment(is_active);

drop trigger if exists trg_vehicle_user_assignment_updated_at
  on public.vehicle_user_assignment;
create trigger trg_vehicle_user_assignment_updated_at
  before update on public.vehicle_user_assignment
  for each row execute function public.set_updated_at();

alter table public.vehicle_user_assignment enable row level security;

drop policy if exists "vehicle_user_assignment read"   on public.vehicle_user_assignment;
drop policy if exists "vehicle_user_assignment insert" on public.vehicle_user_assignment;
drop policy if exists "vehicle_user_assignment update" on public.vehicle_user_assignment;
drop policy if exists "vehicle_user_assignment delete" on public.vehicle_user_assignment;

create policy "vehicle_user_assignment read"
  on public.vehicle_user_assignment for select using (true);
create policy "vehicle_user_assignment insert"
  on public.vehicle_user_assignment for insert to public with check (true);
create policy "vehicle_user_assignment update"
  on public.vehicle_user_assignment for update to public using (true) with check (true);
create policy "vehicle_user_assignment delete"
  on public.vehicle_user_assignment for delete to public using (true);

grant select, insert, update, delete on public.vehicle_user_assignment to anon, authenticated;

do $$
begin
  alter publication supabase_realtime add table public.vehicle_user_assignment;
exception when duplicate_object then null;
end$$;
alter table public.vehicle_user_assignment replica identity full;


-- ---------------------------------------------------------------------------
-- 2. vehicle_active_session — exclusive "vehicle is online & in use" pairing
-- ---------------------------------------------------------------------------
create table if not exists public.vehicle_active_session (
  id           uuid primary key default gen_random_uuid(),
  vehicle_id   uuid not null references public.vehicle(id) on delete cascade,
  user_id      uuid not null,                        -- auth.users.id
  partner_id   uuid references public.partners(id) on delete set null,
  started_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  status       text not null default 'online'
                  check (status in ('online', 'busy', 'offline')),
  metadata     jsonb,
  -- Exclusivity:
  constraint vehicle_active_session_vehicle_unique unique (vehicle_id),
  constraint vehicle_active_session_user_unique    unique (user_id)
);

create index if not exists vehicle_active_session_status_idx
  on public.vehicle_active_session(status);
create index if not exists vehicle_active_session_partner_idx
  on public.vehicle_active_session(partner_id);

alter table public.vehicle_active_session enable row level security;

drop policy if exists "vehicle_active_session read"   on public.vehicle_active_session;
drop policy if exists "vehicle_active_session insert" on public.vehicle_active_session;
drop policy if exists "vehicle_active_session update" on public.vehicle_active_session;
drop policy if exists "vehicle_active_session delete" on public.vehicle_active_session;

create policy "vehicle_active_session read"
  on public.vehicle_active_session for select using (true);
create policy "vehicle_active_session insert"
  on public.vehicle_active_session for insert to public with check (true);
create policy "vehicle_active_session update"
  on public.vehicle_active_session for update to public using (true) with check (true);
create policy "vehicle_active_session delete"
  on public.vehicle_active_session for delete to public using (true);

grant select, insert, update, delete on public.vehicle_active_session to anon, authenticated;

do $$
begin
  alter publication supabase_realtime add table public.vehicle_active_session;
exception when duplicate_object then null;
end$$;
alter table public.vehicle_active_session replica identity full;


-- ---------------------------------------------------------------------------
-- 3. Helper RPCs — atomic claim / release.
--    Using these from the client avoids the classic race-window where two
--    devices both see "vehicle is free" and both try to insert.
-- ---------------------------------------------------------------------------

-- Claim a vehicle for a user. Returns the active session row on success.
-- Raises if the user isn't an active assignee, the vehicle is already taken,
-- or the user is already driving another vehicle.
create or replace function public.claim_vehicle(
  p_vehicle_id uuid,
  p_user_id    uuid
) returns public.vehicle_active_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_assignment public.vehicle_user_assignment%rowtype;
  v_session    public.vehicle_active_session%rowtype;
  v_partner_id uuid;
begin
  -- Must have an active assignment
  select * into v_assignment
    from public.vehicle_user_assignment
   where vehicle_id = p_vehicle_id
     and user_id    = p_user_id
     and is_active  = true
   limit 1;

  if not found then
    raise exception 'not_assigned'
      using hint = 'User is not an active assignee of this vehicle.';
  end if;

  -- Vehicle already in use?
  select * into v_session
    from public.vehicle_active_session
   where vehicle_id = p_vehicle_id
   limit 1;

  if found then
    if v_session.user_id = p_user_id then
      -- Already owned by this user => refresh heartbeat and return.
      update public.vehicle_active_session
         set last_seen_at = now(),
             status       = 'online'
       where id = v_session.id
      returning * into v_session;
      return v_session;
    end if;
    raise exception 'vehicle_in_use'
      using hint = 'Vehicle is currently used by another user.';
  end if;

  -- User already driving something else?
  if exists (
    select 1 from public.vehicle_active_session where user_id = p_user_id
  ) then
    raise exception 'user_busy'
      using hint = 'User is already in an active session on another vehicle.';
  end if;

  v_partner_id := v_assignment.partner_id;

  insert into public.vehicle_active_session (vehicle_id, user_id, partner_id)
       values (p_vehicle_id, p_user_id, v_partner_id)
    returning * into v_session;

  return v_session;
end;
$$;

grant execute on function public.claim_vehicle(uuid, uuid) to anon, authenticated;

-- Release whatever vehicle the user is currently driving (sets vehicle offline).
create or replace function public.release_vehicle(
  p_user_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.vehicle_active_session where user_id = p_user_id;
end;
$$;

grant execute on function public.release_vehicle(uuid) to anon, authenticated;

-- Heartbeat — call periodically while online to keep the session fresh.
create or replace function public.touch_vehicle_session(
  p_user_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.vehicle_active_session
     set last_seen_at = now()
   where user_id = p_user_id;
end;
$$;

grant execute on function public.touch_vehicle_session(uuid) to anon, authenticated;

notify pgrst, 'reload schema';
