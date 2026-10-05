-- ============================================================================
-- 0081 — Meter Digital settings & rate cards
-- ----------------------------------------------------------------------------
-- Admin → Settings → Meter Digital Setting (`app/admin-settings-meter-digital.tsx`).
--
-- Everything the in-app taxi meter (`app/meter-digital.tsx`) needs to be told
-- rather than to decide for itself, in one row:
--
--   * which sensors it may bill on — GPS only, OBD-II only, or both,
--   * whether the odometer is read, and whether a hire may open without one,
--   * which of the five console panels are shown, and which of those may be
--     tapped (a panel can be visible but locked — the driver sees the printer
--     status without being able to change it),
--   * the rate card itself: flag fare, the distance charge (per km, or per
--     started block such as RM0.35/200 m), the time charge (per minute, per
--     second, or per started block such as 36 s), how the two combine, the
--     night surcharge, and the per-unit luggage/passenger extras.
--
-- Scoping mirrors `commission_rates` (0058): one `master` row is the global
-- card, and country / state / city / suburb rows override it. The meter
-- resolves the first match, highest first:
--
--   suburb → city → state → country → master → built-in TEKSI tariff
--
-- Resolution is done client-side (`utils/meterSettings.ts`), because the meter
-- must keep pricing a hire with no signal at all — so there is deliberately no
-- server-side resolver RPC here. The table is the source of truth; the device
-- caches the last fetch.
--
-- RLS follows the 0069 lockdown for admin-managed config: public read (every
-- driver's meter needs the card), admin-only writes.
-- ============================================================================

create extension if not exists "pgcrypto";

create table if not exists public.meter_digital_settings (
  id uuid primary key default gen_random_uuid(),

  -- Scope of this card. 'master' is the single global row.
  level   text not null check (level in ('master','country','state','city','suburb')),
  country text,
  state   text,
  city    text,
  suburb  text,
  -- Optional admin-facing name, e.g. "KL city tariff".
  label   text,

  -- ---- Sensors -------------------------------------------------------------
  -- Which sources the meter may bill a hire on. 'gps' forces GPS even when a
  -- reader is linked; 'obd' refuses to bill on GPS at all.
  source_mode text not null default 'gps+obd'
    check (source_mode in ('gps','gps+obd','obd')),
  -- May a hire open before the vehicle has reported an odometer (PID A6)?
  -- False makes the odometer part of the start gate; true lets the hire begin
  -- and records the pickup odometer as unavailable.
  allow_start_without_odometer boolean not null default true,
  -- Read the vehicle's odometer at each end of a hire at all. On by default;
  -- turned off for fleets whose cars do not implement PID A6, so the meter
  -- stops asking for something it will never get.
  read_odometer boolean not null default true,

  -- ---- Console panels: shown, and tappable ---------------------------------
  show_meter    boolean not null default true,
  show_trips    boolean not null default true,
  show_printer  boolean not null default true,
  show_obd      boolean not null default true,
  show_settings boolean not null default true,
  tap_meter     boolean not null default true,
  tap_trips     boolean not null default true,
  tap_printer   boolean not null default true,
  tap_obd       boolean not null default true,
  tap_settings  boolean not null default true,

  -- ---- Rate card -----------------------------------------------------------
  currency text not null default 'MYR',

  -- Flag fall / minimum fare: what the meter shows the moment a hire opens.
  flag_fare       numeric(10,2) not null default 4.00 check (flag_fare >= 0),
  -- Distance the flag fare covers, in metres.
  flag_distance_m integer       not null default 1000 check (flag_distance_m >= 0),
  -- Floor under the whole fare, applied after everything else. 0 = no floor
  -- beyond the flag fare itself.
  minimum_fare    numeric(10,2) not null default 0 check (minimum_fare >= 0),

  -- Distance charge. 'block' bills a started block (TEKSI: RM0.35 per 200 m),
  -- 'per_km' bills continuously, 'off' bills nothing for distance.
  distance_mode         text          not null default 'block'
    check (distance_mode in ('block','per_km','off')),
  distance_block_m      integer       not null default 200 check (distance_block_m > 0),
  distance_block_charge numeric(10,2) not null default 0.35 check (distance_block_charge >= 0),
  per_km_charge         numeric(10,2) not null default 1.00 check (per_km_charge >= 0),

  -- Time charge. 'block' bills a started block (TEKSI: RM0.35 per 36 s),
  -- 'per_minute' and 'per_second' bill continuously, 'off' bills no time.
  time_mode         text          not null default 'block'
    check (time_mode in ('block','per_minute','per_second','off')),
  time_block_s      integer       not null default 36 check (time_block_s > 0),
  time_block_charge numeric(10,2) not null default 0.35 check (time_block_charge >= 0),
  per_minute_charge numeric(10,2) not null default 0.30 check (per_minute_charge >= 0),
  per_second_charge numeric(10,4) not null default 0 check (per_second_charge >= 0),

  -- How the two charges combine. 'max' is the TEKSI meter (distance OR time,
  -- whichever is greater — a meter never bills both for the same second);
  -- 'sum' adds them, which is the "new rates" structure.
  charge_mode text not null default 'max' check (charge_mode in ('max','sum')),
  -- Where the variable charge starts counting. 'flag' bills only past the
  -- flag-fare distance (and only the time accrued past it); 'start' bills the
  -- whole hire on top of the flag fare.
  charge_from text not null default 'flag' check (charge_from in ('flag','start')),

  -- ---- Night shift ---------------------------------------------------------
  night_multiplier numeric(6,3) not null default 1.5 check (night_multiplier >= 1),
  night_start_hour smallint     not null default 0 check (night_start_hour between 0 and 23),
  night_end_hour   smallint     not null default 6 check (night_end_hour between 0 and 24),

  -- ---- Extras the meter cannot measure -------------------------------------
  -- Per-unit charges the driver adds by hand at the end of a hire.
  extra_luggage_charge   numeric(10,2) not null default 0 check (extra_luggage_charge >= 0),
  free_luggage           smallint      not null default 0 check (free_luggage >= 0),
  extra_passenger_charge numeric(10,2) not null default 0 check (extra_passenger_charge >= 0),
  -- Passengers included in the fare before the surcharge starts.
  free_passengers        smallint      not null default 1 check (free_passengers >= 0),
  -- One press of the free-form EXTRA − / + keys, and the ceiling for extras.
  extra_step             numeric(10,2) not null default 0.50 check (extra_step > 0),
  max_extra              numeric(10,2) not null default 99.50 check (max_extra >= 0),

  active     boolean     not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One card per exact scope (case-insensitive on the place names).
create unique index if not exists meter_digital_settings_scope_uidx
  on public.meter_digital_settings (
    level,
    coalesce(lower(country), ''),
    coalesce(lower(state), ''),
    coalesce(lower(city), ''),
    coalesce(lower(suburb), '')
  );

create index if not exists meter_digital_settings_level_idx
  on public.meter_digital_settings(level);

do $$
begin
  drop trigger if exists trg_meter_digital_settings_updated_at on public.meter_digital_settings;
  create trigger trg_meter_digital_settings_updated_at
    before update on public.meter_digital_settings
    for each row execute function public.set_updated_at();
end$$;

-- ---------------------------------------------------------------------------
-- RLS: readable by everyone (each driver's meter resolves its own card),
-- writable only by admins — the 0069 posture for admin-managed config.
-- ---------------------------------------------------------------------------
alter table public.meter_digital_settings enable row level security;

drop policy if exists "meter_digital_settings read"         on public.meter_digital_settings;
drop policy if exists "meter_digital_settings admin insert" on public.meter_digital_settings;
drop policy if exists "meter_digital_settings admin update" on public.meter_digital_settings;
drop policy if exists "meter_digital_settings admin delete" on public.meter_digital_settings;

create policy "meter_digital_settings read" on public.meter_digital_settings
  for select using (true);

create policy "meter_digital_settings admin insert" on public.meter_digital_settings
  for insert to public with check (public.caller_is_admin());

create policy "meter_digital_settings admin update" on public.meter_digital_settings
  for update to public
  using (public.caller_is_admin())
  with check (public.caller_is_admin());

create policy "meter_digital_settings admin delete" on public.meter_digital_settings
  for delete to public using (public.caller_is_admin());

grant select on public.meter_digital_settings to anon, authenticated;
grant insert, update, delete on public.meter_digital_settings to authenticated;

-- ---------------------------------------------------------------------------
-- Seed the master card with the TEKSI "old rates" tariff the meter has been
-- billing on all along, so applying this migration changes no fare.
-- ---------------------------------------------------------------------------
insert into public.meter_digital_settings (level, label)
  select 'master', 'Global (TEKSI old rates)'
 where not exists (
   select 1 from public.meter_digital_settings where level = 'master'
 );
