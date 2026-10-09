-- 0116: Saved places (inDrive's "Saved" tab on Enter your route).
--
-- A rider keeps Home, Work and any number of other places: a name, the
-- address, the point and the entrance to wait at. One Home and one Work per
-- account; "other" places as many as they like. Rows belong to the account
-- that saved them and nobody else can see or change them.

create table if not exists public.saved_places (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind text not null default 'other' check (kind in ('home', 'work', 'other')),
  name text not null check (length(btrim(name)) between 1 and 80),
  address text not null default '' check (length(address) <= 300),
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  entrance text not null default '' check (length(entrance) <= 80),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists saved_places_user_idx on public.saved_places (user_id, created_at);

-- One Home and one Work each.
create unique index if not exists saved_places_one_home_work
  on public.saved_places (user_id, kind) where kind in ('home', 'work');

drop trigger if exists saved_places_updated_at on public.saved_places;
create trigger saved_places_updated_at before update on public.saved_places
  for each row execute function public.set_updated_at();

alter table public.saved_places enable row level security;

drop policy if exists "saved_places own read" on public.saved_places;
create policy "saved_places own read" on public.saved_places
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "saved_places own insert" on public.saved_places;
create policy "saved_places own insert" on public.saved_places
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists "saved_places own update" on public.saved_places;
create policy "saved_places own update" on public.saved_places
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "saved_places own delete" on public.saved_places;
create policy "saved_places own delete" on public.saved_places
  for delete to authenticated using (user_id = auth.uid());

grant select, insert, update, delete on public.saved_places to authenticated;
