-- ============================================================================
-- 0020 — More dedicated tables for admin-settings screens
-- ----------------------------------------------------------------------------
-- Splits these categories out of `settings_entries` into their own typed
-- tables so they can be queried, indexed and seeded independently:
--
--   multi-gate-places       \
--   multi-gate-place-gates  /->  public.multi_gate (kind = 'place' | 'gate')
--   insurance-providers          ->  public.insurance_providers
--   insurance-types              ->  public.insurance_types
--   insurance-durations          ->  public.insurance_durations
--   insurance-premium            ->  public.insurance_premium
--   ev-delivery-advisors         ->  public.ev_delivery_advisors
--   ev-finance-options           ->  public.ev_finance_options
--   ev-order-fee                 ->  public.ev_order_fee
--   ev-vehicle-details           ->  public.ev_vehicle_details
--   ev-vehicle-inventory         ->  public.ev_vehicle_inventory
--
-- Every table mirrors the settings_entries shape (id / values / position /
-- active / timestamps) so the existing admin screens keep using SettingEntry
-- without changes.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- multi_gate (shared by multi-gate-places and multi-gate-place-gates)
-- ---------------------------------------------------------------------------
create table if not exists public.multi_gate (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('place','gate')),
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists multi_gate_kind_idx     on public.multi_gate(kind);
create index if not exists multi_gate_position_idx on public.multi_gate(position);

-- ---------------------------------------------------------------------------
-- Simple per-category tables
-- ---------------------------------------------------------------------------
do $mk$
declare t text;
begin
  foreach t in array array[
    'insurance_providers','insurance_types','insurance_durations','insurance_premium',
    'ev_delivery_advisors','ev_finance_options','ev_order_fee',
    'ev_vehicle_details','ev_vehicle_inventory'
  ] loop
    execute format($f$
      create table if not exists public.%1$s (
        id          uuid primary key default gen_random_uuid(),
        values      jsonb not null default '{}'::jsonb,
        position    integer not null default 0,
        active      boolean not null default true,
        created_at  timestamptz not null default now(),
        updated_at  timestamptz not null default now()
      );
      create index if not exists %1$s_position_idx on public.%1$s(position);
    $f$, t);
  end loop;
end;
$mk$;

-- ---------------------------------------------------------------------------
-- updated_at triggers (relies on public.set_updated_at from schema.sql)
-- ---------------------------------------------------------------------------
do $trg$
declare t text;
begin
  foreach t in array array[
    'multi_gate',
    'insurance_providers','insurance_types','insurance_durations','insurance_premium',
    'ev_delivery_advisors','ev_finance_options','ev_order_fee',
    'ev_vehicle_details','ev_vehicle_inventory'
  ] loop
    execute format(
      'drop trigger if exists trg_%1$s_updated_at on public.%1$s;
       create trigger trg_%1$s_updated_at before update on public.%1$s
       for each row execute function public.set_updated_at();', t);
  end loop;
end;
$trg$;

-- ---------------------------------------------------------------------------
-- Row-Level Security: open read/write (matches the other dedicated tables)
-- ---------------------------------------------------------------------------
do $pol$
declare t text;
begin
  foreach t in array array[
    'multi_gate',
    'insurance_providers','insurance_types','insurance_durations','insurance_premium',
    'ev_delivery_advisors','ev_finance_options','ev_order_fee',
    'ev_vehicle_details','ev_vehicle_inventory'
  ] loop
    execute format('alter table public.%1$s enable row level security;', t);
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
-- Backfill from settings_entries, then delete migrated rows
-- ---------------------------------------------------------------------------
do $bf$
declare
  pair record;
  cat  text;
  tbl  text;
begin
  for pair in
    select * from (values
      ('insurance-providers',   'insurance_providers'),
      ('insurance-types',       'insurance_types'),
      ('insurance-durations',   'insurance_durations'),
      ('insurance-premium',     'insurance_premium'),
      ('ev-delivery-advisors',  'ev_delivery_advisors'),
      ('ev-finance-options',    'ev_finance_options'),
      ('ev-order-fee',          'ev_order_fee'),
      ('ev-vehicle-details',    'ev_vehicle_details'),
      ('ev-vehicle-inventory',  'ev_vehicle_inventory')
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

  -- multi_gate: backfill from the two storage keys, tagging kind appropriately.
  insert into public.multi_gate (id, kind, values, position, created_at, updated_at)
    select id, 'place', coalesce(values, '{}'::jsonb), coalesce(position, 0), created_at, updated_at
      from public.settings_entries
     where category = 'multi-gate-places'
  on conflict (id) do nothing;
  delete from public.settings_entries where category = 'multi-gate-places';

  insert into public.multi_gate (id, kind, values, position, created_at, updated_at)
    select id, 'gate', coalesce(values, '{}'::jsonb), coalesce(position, 0), created_at, updated_at
      from public.settings_entries
     where category = 'multi-gate-place-gates'
  on conflict (id) do nothing;
  delete from public.settings_entries where category = 'multi-gate-place-gates';
end;
$bf$;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------
do $rt$
declare t text;
begin
  foreach t in array array[
    'multi_gate',
    'insurance_providers','insurance_types','insurance_durations','insurance_premium',
    'ev_delivery_advisors','ev_finance_options','ev_order_fee',
    'ev_vehicle_details','ev_vehicle_inventory'
  ] loop
    begin
      execute format('alter publication supabase_realtime add table public.%1$s;', t);
    exception when duplicate_object then null;
             when others then null;
    end;
  end loop;
end;
$rt$;
