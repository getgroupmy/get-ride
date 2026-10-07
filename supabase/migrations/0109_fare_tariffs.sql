-- 0109: booking tariffs by country, state, city and suburb.
--
-- Booking quotes were priced on the built-in ringgit TEKSI tariff
-- everywhere. A tariff card sets the price and currency for a place, scoped
-- exactly like commission_rates: one 'master' card for everywhere, then
-- country / state / city / suburb overrides, the narrowest one that matches
-- the pickup winning. With no card at all the app keeps the built-in
-- tariff.
--
--   fare = max(minimum_fare, (base_fare + per_km * km + per_minute * min) * service multiplier)
--          + booking_fee
--
-- Meter Digital keeps its own rate cards (meter_digital_settings): a street
-- hail is billed on the meter, a booking on its quote.
--
-- Anyone may read the cards (the quote is shown before a booking); only
-- admins write them.

create table if not exists public.fare_tariffs (
  id uuid primary key default gen_random_uuid(),
  level text not null check (level in ('master', 'country', 'state', 'city', 'suburb')),
  country text,
  state   text,
  city    text,
  suburb  text,
  label   text check (label is null or char_length(label) <= 80),
  currency text not null default 'MYR' check (currency ~ '^[A-Z]{3}$'),
  base_fare    numeric(10,2) not null default 0 check (base_fare >= 0),
  per_km       numeric(10,4) not null default 0 check (per_km >= 0),
  per_minute   numeric(10,4) not null default 0 check (per_minute >= 0),
  minimum_fare numeric(10,2) not null default 0 check (minimum_fare >= 0),
  booking_fee  numeric(10,2) not null default 0 check (booking_fee >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- A card names every level above its own.
  check (
    (level = 'master' and country is null and state is null and city is null and suburb is null)
    or (level = 'country' and country is not null and state is null and city is null and suburb is null)
    or (level = 'state' and country is not null and state is not null and city is null and suburb is null)
    or (level = 'city' and country is not null and state is not null and city is not null and suburb is null)
    or (level = 'suburb' and country is not null and state is not null and city is not null and suburb is not null)
  )
);

create unique index if not exists fare_tariffs_scope_uidx
  on public.fare_tariffs (
    level,
    coalesce(lower(country), ''),
    coalesce(lower(state), ''),
    coalesce(lower(city), ''),
    coalesce(lower(suburb), '')
  );

drop trigger if exists trg_fare_tariffs_updated_at on public.fare_tariffs;
create trigger trg_fare_tariffs_updated_at
  before update on public.fare_tariffs
  for each row execute function public.set_updated_at();

alter table public.fare_tariffs enable row level security;

drop policy if exists "fare_tariffs read" on public.fare_tariffs;
drop policy if exists "fare_tariffs admin insert" on public.fare_tariffs;
drop policy if exists "fare_tariffs admin update" on public.fare_tariffs;
drop policy if exists "fare_tariffs admin delete" on public.fare_tariffs;
create policy "fare_tariffs read" on public.fare_tariffs for select using (true);
create policy "fare_tariffs admin insert" on public.fare_tariffs for insert to public
  with check (public.caller_is_admin());
create policy "fare_tariffs admin update" on public.fare_tariffs for update to public
  using (public.caller_is_admin()) with check (public.caller_is_admin());
create policy "fare_tariffs admin delete" on public.fare_tariffs for delete to public
  using (public.caller_is_admin());

grant select on public.fare_tariffs to anon, authenticated;
grant insert, update, delete on public.fare_tariffs to authenticated;
