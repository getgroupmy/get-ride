-- ============================================================================
-- 0058: Configurable commission rates with hierarchical overrides
-- ----------------------------------------------------------------------------
-- Admin -> Settings -> Commission Rates. One master (platform default) rate
-- plus overrides at country / state / city / suburb level and per-user
-- (partner) level. Resolution priority when charging a ride commission:
--   user > suburb > city > state > country > master (default 15%).
-- ============================================================================

create table if not exists public.commission_rates (
  id uuid primary key default gen_random_uuid(),
  -- Scope of this rule. 'master' is the single platform-wide default row.
  level text not null check (level in ('master','country','state','city','suburb','user')),
  country text,
  state   text,
  city    text,
  suburb  text,
  -- Per-user (partner account) override.
  user_id    uuid,
  user_label text,
  -- Fraction of the fare, e.g. 0.15 = 15%.
  rate numeric(6,4) not null check (rate >= 0 and rate < 1),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One rule per exact scope (case-insensitive on names).
create unique index if not exists commission_rates_scope_uidx
  on public.commission_rates (
    level,
    coalesce(lower(country), ''),
    coalesce(lower(state), ''),
    coalesce(lower(city), ''),
    coalesce(lower(suburb), ''),
    coalesce(user_id::text, '')
  );

create index if not exists commission_rates_level_idx on public.commission_rates(level);
create index if not exists commission_rates_user_idx  on public.commission_rates(user_id);

do $$
begin
  drop trigger if exists trg_commission_rates_updated_at on public.commission_rates;
  create trigger trg_commission_rates_updated_at before update on public.commission_rates
    for each row execute function public.set_updated_at();
end$$;

alter table public.commission_rates enable row level security;

drop policy if exists "commission_rates read"   on public.commission_rates;
drop policy if exists "commission_rates insert" on public.commission_rates;
drop policy if exists "commission_rates update" on public.commission_rates;
drop policy if exists "commission_rates delete" on public.commission_rates;

create policy "commission_rates read"   on public.commission_rates for select using (true);
create policy "commission_rates insert" on public.commission_rates for insert to public with check (true);
create policy "commission_rates update" on public.commission_rates for update to public using (true) with check (true);
create policy "commission_rates delete" on public.commission_rates for delete to public using (true);

grant select, insert, update, delete on public.commission_rates to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Server-side rate resolution mirroring the client priority chain.
-- Returns the fraction (0..1) to charge for a given partner + ride geography.
-- ----------------------------------------------------------------------------
create or replace function public.commission_resolve_rate(
  p_user uuid default null,
  p_country text default null,
  p_state text default null,
  p_city text default null,
  p_suburb text default null
)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_rate numeric;
begin
  -- 1) Per-user override
  if p_user is not null then
    select rate into v_rate from public.commission_rates
     where active and level = 'user' and user_id = p_user
     limit 1;
    if found then return v_rate; end if;
  end if;

  -- 2) Suburb
  if p_suburb is not null then
    select rate into v_rate from public.commission_rates
     where active and level = 'suburb'
       and lower(suburb) = lower(p_suburb)
       and (city    is null or p_city    is null or lower(city)    = lower(p_city))
       and (state   is null or p_state   is null or lower(state)   = lower(p_state))
       and (country is null or p_country is null or lower(country) = lower(p_country))
     limit 1;
    if found then return v_rate; end if;
  end if;

  -- 3) City
  if p_city is not null then
    select rate into v_rate from public.commission_rates
     where active and level = 'city'
       and lower(city) = lower(p_city)
       and (state   is null or p_state   is null or lower(state)   = lower(p_state))
       and (country is null or p_country is null or lower(country) = lower(p_country))
     limit 1;
    if found then return v_rate; end if;
  end if;

  -- 4) State
  if p_state is not null then
    select rate into v_rate from public.commission_rates
     where active and level = 'state'
       and lower(state) = lower(p_state)
       and (country is null or p_country is null or lower(country) = lower(p_country))
     limit 1;
    if found then return v_rate; end if;
  end if;

  -- 5) Country
  if p_country is not null then
    select rate into v_rate from public.commission_rates
     where active and level = 'country'
       and lower(country) = lower(p_country)
     limit 1;
    if found then return v_rate; end if;
  end if;

  -- 6) Master (admin default)
  select rate into v_rate from public.commission_rates
   where active and level = 'master'
   limit 1;
  if found then return v_rate; end if;

  return 0.15;
end;
$$;

grant execute on function public.commission_resolve_rate(uuid, text, text, text, text)
  to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Let the charge RPC resolve the rate itself when p_rate is null, using the
-- ride's stored geography + the partner's user override.
-- ----------------------------------------------------------------------------
create or replace function public.wallet_charge_ride_commission(
  p_ride uuid,
  p_partner uuid,
  p_fare numeric,
  p_rate numeric default null
)
returns public.wallets
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  w public.wallets;
  v_rate numeric;
  v_amount numeric(12,2);
begin
  if p_partner is null then
    raise exception 'invalid_partner';
  end if;
  if p_fare is null or p_fare <= 0 then
    raise exception 'invalid_fare';
  end if;

  select * into r from public.ride_requests where id = p_ride for update;
  if not found then
    raise exception 'ride_not_found';
  end if;

  -- Already charged: idempotent no-op.
  if r.commission_charged_at is not null then
    select * into w from public.wallets
     where user_id = p_partner and wallet_type = 'get_credit';
    return w;
  end if;

  v_rate := p_rate;
  if v_rate is null then
    v_rate := public.commission_resolve_rate(p_partner, r.country, r.state, r.city, r.suburb);
  end if;
  if v_rate is null or v_rate <= 0 or v_rate >= 1 then
    raise exception 'invalid_rate';
  end if;

  v_amount := round(p_fare * v_rate, 2);

  insert into public.wallets (user_id, wallet_type, balance)
  values (p_partner, 'get_credit', 0)
  on conflict (user_id, wallet_type) do nothing;

  update public.wallets
     set balance = balance - v_amount, updated_at = now()
   where user_id = p_partner and wallet_type = 'get_credit'
  returning * into w;

  insert into public.wallet_transactions
    (user_id, wallet_type, kind, amount, balance_after, note)
  values
    (p_partner, 'get_credit', 'commission', -v_amount, w.balance,
     'Ride commission ' || round(v_rate * 100, 1) || '% of ' ||
     coalesce(r.currency, 'RM') || ' ' || round(p_fare, 2));

  update public.ride_requests
     set commission_rate = v_rate,
         commission_amount = v_amount,
         commission_charged_at = now()
   where id = p_ride;

  return w;
end;
$$;

grant execute on function public.wallet_charge_ride_commission(uuid, uuid, numeric, numeric)
  to anon, authenticated;
