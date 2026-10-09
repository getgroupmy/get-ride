-- ============================================================================
-- 0129: rider ↔ driver chat for an active ride
--
-- Until now the rider's Message button opened the phone's own SMS app and the
-- driver had no way to write to the passenger at all. ride_messages is the
-- thread for one ride_requests row, seen and written only by that ride's
-- rider and partner:
--
--   * either side sends while the ride is accepted / arrived / on_trip; once
--     it has ended the thread stays readable but takes no new messages;
--   * a message is text, a quick reply (a canned line, still text in `body`)
--     or a shared location;
--   * `status` is the tick: 'sent' → 'delivered' → 'read'. Only the RECEIVER
--     moves it, only forward, and nothing else about a message can change
--     (trg_ride_messages_guard_update);
--   * each new message pushes the other participant (data.type
--     'ride_message', with the recipient's role so the tap opens the right
--     screen).
-- ============================================================================

create table if not exists public.ride_messages (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.ride_requests(id) on delete cascade,
  sender_id uuid not null default auth.uid(),
  sender_role text not null check (sender_role in ('rider', 'partner')),
  type text not null default 'text' check (type in ('text', 'quick', 'location')),
  body text check (body is null or char_length(body) <= 1000),
  latitude double precision,
  longitude double precision,
  status text not null default 'sent' check (status in ('sent', 'delivered', 'read')),
  created_at timestamptz not null default now(),
  -- A null inside a check passes it, hence the coalesce.
  constraint ride_messages_content check (coalesce(
    case type
      when 'location' then latitude between -90 and 90 and longitude between -180 and 180
      else char_length(btrim(body)) between 1 and 1000
    end, false))
);

create index if not exists ride_messages_request_idx on public.ride_messages(request_id, created_at);

-- ---- RLS --------------------------------------------------------------------
-- The ride_requests subqueries run under the caller's own RLS there, which
-- already lets a participant read their ride.
alter table public.ride_messages enable row level security;

drop policy if exists "ride_messages participant read" on public.ride_messages;
drop policy if exists "ride_messages participant insert" on public.ride_messages;
drop policy if exists "ride_messages participant update" on public.ride_messages;
drop policy if exists "ride_messages admin delete" on public.ride_messages;

create policy "ride_messages participant read"
  on public.ride_messages for select
  using (
    exists (
      select 1 from public.ride_requests r
       where r.id = ride_messages.request_id
         and (r.rider_id = auth.uid() or r.partner_id = auth.uid())
    )
    or public.caller_is_admin()
  );

create policy "ride_messages participant insert"
  on public.ride_messages for insert
  with check (
    auth.uid() is not null
    and sender_id = auth.uid()
    and exists (
      select 1 from public.ride_requests r
       where r.id = ride_messages.request_id
         and r.status in ('accepted', 'arrived', 'on_trip')
         and (
           (ride_messages.sender_role = 'rider' and r.rider_id = auth.uid())
           or (ride_messages.sender_role = 'partner' and r.partner_id = auth.uid())
         )
    )
  );

-- Which participant may change what is the trigger's job; the policy only
-- keeps outsiders off the rows.
create policy "ride_messages participant update"
  on public.ride_messages for update
  using (
    exists (
      select 1 from public.ride_requests r
       where r.id = ride_messages.request_id
         and (r.rider_id = auth.uid() or r.partner_id = auth.uid())
    )
    or public.caller_is_admin()
  )
  with check (
    exists (
      select 1 from public.ride_requests r
       where r.id = ride_messages.request_id
         and (r.rider_id = auth.uid() or r.partner_id = auth.uid())
    )
    or public.caller_is_admin()
  );

create policy "ride_messages admin delete"
  on public.ride_messages for delete
  using (public.caller_is_admin());

-- The default privileges grant every client role everything; a signed-in
-- client may only ever write the tick.
revoke all on public.ride_messages from anon, authenticated;
grant select, insert, delete on public.ride_messages to authenticated;
grant update (status) on public.ride_messages to authenticated;

-- ---- Insert: a message always starts as sent, stamped now --------------------
create or replace function public.ride_messages_before_insert()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.status := 'sent';
  new.created_at := now();
  if new.type in ('text', 'quick') then
    new.body := btrim(new.body);
  end if;
  return new;
end;
$$;

revoke execute on function public.ride_messages_before_insert() from public, anon, authenticated;

drop trigger if exists trg_ride_messages_before_insert on public.ride_messages;
create trigger trg_ride_messages_before_insert before insert on public.ride_messages
  for each row execute function public.ride_messages_before_insert();

-- ---- Update: only the receiver, only the tick, only forward ------------------
create or replace function public.ride_messages_guard_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rider uuid;
  v_partner uuid;
  v_receiver uuid;
begin
  if (new.id, new.request_id, new.sender_id, new.sender_role, new.type, new.body,
      new.latitude, new.longitude, new.created_at)
     is distinct from
     (old.id, old.request_id, old.sender_id, old.sender_role, old.type, old.body,
      old.latitude, old.longitude, old.created_at) then
    raise exception 'only a message''s status can change' using errcode = '42501';
  end if;
  if array_position(array['sent', 'delivered', 'read'], new.status)
     < array_position(array['sent', 'delivered', 'read'], old.status) then
    raise exception 'a message''s status only moves forward' using errcode = '42501';
  end if;
  if new.status is not distinct from old.status or public.caller_is_admin() then
    return new;
  end if;
  select rider_id, partner_id into v_rider, v_partner from public.ride_requests where id = old.request_id;
  v_receiver := case old.sender_role when 'rider' then v_partner else v_rider end;
  if auth.uid() is null or auth.uid() is distinct from v_receiver then
    raise exception 'only the receiver can mark a message delivered or read' using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke execute on function public.ride_messages_guard_update() from public, anon, authenticated;

drop trigger if exists trg_ride_messages_guard_update on public.ride_messages;
create trigger trg_ride_messages_guard_update before update on public.ride_messages
  for each row execute function public.ride_messages_guard_update();

-- ---- Push the other participant ----------------------------------------------
-- What the notification says, on its own so it is tested on its own.
create or replace function public.ride_message_push_body(p_type text, p_body text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_type = 'location' then 'Shared a location'
    when char_length(btrim(coalesce(p_body, ''))) > 160 then left(btrim(p_body), 159) || '…'
    else btrim(coalesce(p_body, ''))
  end;
$$;

create or replace function public.notify_ride_message_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_to uuid;
  v_to_role text;
  v_title text;
begin
  select rider_id, partner_id, rider_name, partner_name into r
    from public.ride_requests where id = new.request_id;
  if new.sender_role = 'rider' then
    v_to := r.partner_id;
    v_to_role := 'partner';
    v_title := coalesce(nullif(btrim(coalesce(r.rider_name, '')), ''), 'Your passenger');
  else
    v_to := r.rider_id;
    v_to_role := 'rider';
    v_title := coalesce(nullif(btrim(coalesce(r.partner_name, '')), ''), 'Your driver');
  end if;
  if v_to is null or v_to = new.sender_id then
    return new;
  end if;
  perform public.send_push_webhook(jsonb_build_object(
    'title', v_title,
    'body', public.ride_message_push_body(new.type, new.body),
    'profileId', v_to,
    'data', jsonb_build_object('type', 'ride_message', 'request_id', new.request_id, 'role', v_to_role)
  ));
  return new;
exception when others then
  return new;
end;
$$;

revoke execute on function public.notify_ride_message_push() from public, anon, authenticated;

drop trigger if exists trg_ride_messages_push on public.ride_messages;
create trigger trg_ride_messages_push after insert on public.ride_messages
  for each row execute function public.notify_ride_message_push();

-- ---- Realtime -----------------------------------------------------------------
-- Both sides follow the thread live (new messages and ticks); RLS still
-- decides what each subscriber receives.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'ride_messages'
     ) then
    alter publication supabase_realtime add table public.ride_messages;
  end if;
end $$;
