-- ============================================================================
-- Support: tickets, messages (live chat), calls + media bucket
-- ----------------------------------------------------------------------------
-- Adds a customer-support system tied to public.profiles:
--   * support_tickets  — one conversation per profile (a ticket / chat thread)
--   * support_messages — chat messages with attachments + read receipts
--   * support_calls    — admin → user call signaling (user only receives)
--   * storage bucket `support-media` for images / video / voice notes
-- Realtime is enabled so both sides see live updates (messages, ticks, calls).
-- Safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Tickets
-- ---------------------------------------------------------------------------
create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  subject text not null default 'Support',
  status text not null default 'open' check (status in ('open','pending','closed')),
  last_message text,
  last_message_at timestamptz,
  last_sender_role text check (last_sender_role in ('user','admin')),
  unread_admin integer not null default 0,
  unread_user integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists support_tickets_profile_idx on public.support_tickets(profile_id);
create index if not exists support_tickets_status_idx on public.support_tickets(status);
create index if not exists support_tickets_last_msg_idx on public.support_tickets(last_message_at desc);

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------
create table if not exists public.support_messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets(id) on delete cascade,
  sender_role text not null check (sender_role in ('user','admin')),
  sender_id uuid,
  type text not null default 'text'
    check (type in ('text','image','video','audio','location')),
  body text,
  media_url text,
  media_duration numeric,
  latitude double precision,
  longitude double precision,
  -- 'sent' (1 grey tick) → 'delivered' (2 grey ticks) → 'read' (2 blue ticks)
  status text not null default 'sent' check (status in ('sent','delivered','read')),
  created_at timestamptz not null default now()
);

create index if not exists support_messages_ticket_idx on public.support_messages(ticket_id, created_at);
create index if not exists support_messages_status_idx on public.support_messages(status);

-- ---------------------------------------------------------------------------
-- Calls (admin initiates, user receives)
-- ---------------------------------------------------------------------------
create table if not exists public.support_calls (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid references public.support_tickets(id) on delete set null,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  caller_role text not null default 'admin' check (caller_role in ('admin')),
  caller_name text,
  media text not null default 'voice' check (media in ('voice','video')),
  -- ringing → accepted → ended | declined | missed
  status text not null default 'ringing'
    check (status in ('ringing','accepted','declined','ended','missed')),
  started_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists support_calls_profile_idx on public.support_calls(profile_id, created_at desc);
create index if not exists support_calls_status_idx on public.support_calls(status);

-- ---------------------------------------------------------------------------
-- updated_at trigger
-- ---------------------------------------------------------------------------
do $$
begin
  drop trigger if exists trg_support_tickets_updated_at on public.support_tickets;
  create trigger trg_support_tickets_updated_at before update on public.support_tickets
    for each row execute function public.set_updated_at();
end$$;

-- ---------------------------------------------------------------------------
-- RLS — permissive (matches the rest of this project: admin uses a non-RLS
-- super session, users access their own tickets through the same client).
-- ---------------------------------------------------------------------------
alter table public.support_tickets enable row level security;
alter table public.support_messages enable row level security;
alter table public.support_calls enable row level security;

do $support_pol$
declare t text;
begin
  foreach t in array array['support_tickets','support_messages','support_calls'] loop
    execute format('drop policy if exists "%1$s read"   on public.%1$s;', t);
    execute format('drop policy if exists "%1$s insert" on public.%1$s;', t);
    execute format('drop policy if exists "%1$s update" on public.%1$s;', t);
    execute format('drop policy if exists "%1$s delete" on public.%1$s;', t);
    execute format('create policy "%1$s read"   on public.%1$s for select using (true);', t);
    execute format('create policy "%1$s insert" on public.%1$s for insert to public with check (true);', t);
    execute format('create policy "%1$s update" on public.%1$s for update to public using (true) with check (true);', t);
    execute format('create policy "%1$s delete" on public.%1$s for delete to public using (true);', t);
    execute format('grant select, insert, update, delete on public.%1$s to anon, authenticated;', t);
  end loop;
end;
$support_pol$;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.support_tickets;
exception when duplicate_object then null; end$$;
alter table public.support_tickets replica identity full;

do $$ begin
  alter publication supabase_realtime add table public.support_messages;
exception when duplicate_object then null; end$$;
alter table public.support_messages replica identity full;

do $$ begin
  alter publication supabase_realtime add table public.support_calls;
exception when duplicate_object then null; end$$;
alter table public.support_calls replica identity full;

-- ---------------------------------------------------------------------------
-- Storage bucket for support attachments (public read so media renders fast)
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('support-media', 'support-media', true)
on conflict (id) do nothing;

drop policy if exists "public read support-media" on storage.objects;
drop policy if exists "auth upload support-media" on storage.objects;
drop policy if exists "anon upload support-media" on storage.objects;
drop policy if exists "auth update support-media" on storage.objects;
drop policy if exists "auth delete support-media" on storage.objects;

create policy "public read support-media"
  on storage.objects for select
  using (bucket_id = 'support-media');

create policy "anon upload support-media"
  on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'support-media');

create policy "auth update support-media"
  on storage.objects for update to anon, authenticated
  using (bucket_id = 'support-media');

create policy "auth delete support-media"
  on storage.objects for delete to anon, authenticated
  using (bucket_id = 'support-media');
