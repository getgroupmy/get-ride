-- ============================================================================
-- 0019 — Dedicated tables for several admin-settings screens
-- ----------------------------------------------------------------------------
-- Splits the following categories out of `settings_entries` into their own
-- typed tables so they can be queried, indexed and seeded independently:
--   * airport-areas      -> public.airport_areas
--   * required-documents -> public.required_document
--   * document-type      -> public.document_type
--   * driver-incentive   -> public.driver_incentive
--
-- All four share the same shape (id / values / position / timestamps) so the
-- existing admin screens keep using SettingEntry without changes.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table if not exists public.airport_areas (
  id          uuid primary key default gen_random_uuid(),
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists airport_areas_position_idx on public.airport_areas(position);

create table if not exists public.required_document (
  id          uuid primary key default gen_random_uuid(),
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists required_document_position_idx on public.required_document(position);

create table if not exists public.document_type (
  id          uuid primary key default gen_random_uuid(),
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists document_type_position_idx on public.document_type(position);

create table if not exists public.driver_incentive (
  id          uuid primary key default gen_random_uuid(),
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists driver_incentive_position_idx on public.driver_incentive(position);

-- ---------------------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------------------
do $trg$
declare t text;
begin
  foreach t in array array[
    'airport_areas','required_document','document_type','driver_incentive'
  ] loop
    execute format(
      'drop trigger if exists trg_%1$s_updated_at on public.%1$s;
       create trigger trg_%1$s_updated_at before update on public.%1$s
       for each row execute function public.set_updated_at();', t);
  end loop;
end;
$trg$;

-- ---------------------------------------------------------------------------
-- Row-Level Security: open read/write for now (matches regions tables)
-- ---------------------------------------------------------------------------
alter table public.airport_areas    enable row level security;
alter table public.required_document enable row level security;
alter table public.document_type    enable row level security;
alter table public.driver_incentive enable row level security;

do $pol$
declare t text;
begin
  foreach t in array array[
    'airport_areas','required_document','document_type','driver_incentive'
  ] loop
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
$pol$;

-- ---------------------------------------------------------------------------
-- Backfill from settings_entries, then delete the migrated rows
-- ---------------------------------------------------------------------------
do $bf$
declare
  pair record;
  cat  text;
  tbl  text;
begin
  for pair in
    select * from (values
      ('airport-areas',      'airport_areas'),
      ('required-documents', 'required_document'),
      ('document-type',      'document_type'),
      ('driver-incentive',   'driver_incentive')
    ) as v(cat, tbl)
  loop
    cat := pair.cat;
    tbl := pair.tbl;
    execute format(
      'insert into public.%1$s (id, values, position, created_at, updated_at)
         select id, coalesce(values, ''{}''::jsonb), coalesce(position, 0), created_at, updated_at
           from public.settings_entries
          where category = %2$L
       on conflict (id) do nothing;',
      tbl, cat
    );
    execute format(
      'delete from public.settings_entries where category = %1$L;',
      cat
    );
  end loop;
end;
$bf$;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------
do $rt$
declare t text;
begin
  foreach t in array array[
    'airport_areas','required_document','document_type','driver_incentive'
  ] loop
    begin
      execute format('alter publication supabase_realtime add table public.%1$s;', t);
    exception when duplicate_object then null;
             when others then null;
    end;
  end loop;
end;
$rt$;
