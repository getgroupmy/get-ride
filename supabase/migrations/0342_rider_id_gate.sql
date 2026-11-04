-- Rider ID-verification gate (admin country rule).
-- ============================================================================
-- An admin can require a rider to verify a photo ID (and a selfie face-match)
-- before their Nth booking, per country. When the rule applies and the rider
-- is not verified, the booking is refused server-side on every booking module,
-- so an old or hacked client cannot skip it — the app runs the existing
-- identity flow (live selfie + ID read + face match, migrations 0281/0283/0320)
-- and only then can book.
--
-- The rider's country is profiles.nationality (as elsewhere, see
-- core/date_order.dart). Verified = profiles.id_verified = 'Verified'. Prior
-- bookings = profiles.total_rides. The rule is stored in app_settings
-- 'rider_id_gate' as { "master": rule, "<Country>": rule } with
-- rule = { require, idType, nthBooking, selfie, allowPhoto }.
-- ============================================================================

-- ---- 0. Admin rule: read + write -----------------------------------------------------------------
-- One rule object, cleaned and defaulted.
create or replace function public.rider_id_gate_rule(p in jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'require', coalesce((p->>'require')::boolean, false),
    'idType', case when p->>'idType' in ('national', 'passport', 'either') then p->>'idType' else 'either' end,
    'nthBooking', least(50, greatest(1, coalesce(
      case when jsonb_typeof(p->'nthBooking') = 'number' then (p->>'nthBooking')::numeric end, 1)))::int,
    'selfie', coalesce((p->>'selfie')::boolean, true),
    'allowPhoto', coalesce((p->>'allowPhoto')::boolean, true));
$$;

-- The whole map { master, <Country>... }, each rule cleaned.
create or replace function public.rider_id_gate_config()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select jsonb_object_agg(e.key, public.rider_id_gate_rule(e.value))
       from jsonb_each((select s.value from public.app_settings s where s.key = 'rider_id_gate')) e
      where jsonb_typeof(e.value) = 'object'),
    '{}'::jsonb);
$$;
revoke execute on function public.rider_id_gate_config() from public, anon;
grant execute on function public.rider_id_gate_config() to authenticated;

-- Admin upserts one country's rule (p_country = 'master' for the default).
create or replace function public.set_rider_id_gate(p_country text, p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_all jsonb;
  v_key text := nullif(btrim(p_country), '');
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:set_rider_id_gate') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_key is null or jsonb_typeof(p_config) is distinct from 'object' then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  v_all := coalesce((select s.value from public.app_settings s where s.key = 'rider_id_gate'), '{}'::jsonb)
           || jsonb_build_object(v_key, public.rider_id_gate_rule(p_config));
  insert into public.app_settings (key, value, updated_at) values ('rider_id_gate', v_all, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return public.rider_id_gate_config();
end;
$$;
revoke execute on function public.set_rider_id_gate(text, jsonb) from public, anon;
grant execute on function public.set_rider_id_gate(text, jsonb) to authenticated;

insert into public.admin_table_pages (target, page) values ('rpc:set_rider_id_gate', 'admin-settings-site')
on conflict do nothing;

-- ---- 1. The gate check ---------------------------------------------------------------------------
-- Whether [p_rider] must verify their ID before they may book now: the rule
-- for their country (else master) requires it, they are not already verified,
-- and they have reached the booking number it applies from.
create or replace function public.rider_id_gate_block(p_rider uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_prof public.profiles;
  v_cfg jsonb := public.rider_id_gate_config();
  v_rule jsonb;
  v_nth int;
begin
  if p_rider is null then
    return false;
  end if;
  select * into v_prof from public.profiles where id = p_rider;
  if not found then
    return false;
  end if;
  v_rule := coalesce(v_cfg->v_prof.nationality, v_cfg->'master');
  if v_rule is null or not (v_rule->>'require')::boolean then
    return false;
  end if;
  if v_prof.id_verified = 'Verified' then
    return false;
  end if;
  v_nth := coalesce((v_rule->>'nthBooking')::int, 1);
  -- They may take nth-1 bookings first, then must verify before booking #nth.
  return coalesce(v_prof.total_rides, 0) >= (v_nth - 1);
end;
$$;
revoke execute on function public.rider_id_gate_block(uuid) from public, anon;
grant execute on function public.rider_id_gate_block(uuid) to authenticated;

-- ---- 2. The booking guard (every booking module) -------------------------------------------------
-- Raised on a rider booking for themselves when the gate blocks them. Family
-- and dispatch bookings (a booker who is not the rider) are not gated here;
-- the rider verifies when they book for themselves.
create or replace function public.rider_id_gate_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.rider_id is not null and new.rider_id = auth.uid() and public.rider_id_gate_block(new.rider_id) then
    raise exception 'RIDER_ID_REQUIRED' using errcode = '42501',
      hint = 'Verify your ID before booking.';
  end if;
  return new;
end;
$$;
revoke execute on function public.rider_id_gate_guard() from public, anon, authenticated;

-- Attach to every booking table that exists (each has rider_id).
do $$
declare
  t text;
begin
  foreach t in array array['ride_requests', 'scheduled_rides', 'hire_bookings', 'mygig_bookings', 'c2c_bookings', 'freight', 'courier']
  loop
    if to_regclass('public.' || t) is not null
       and exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = t and column_name = 'rider_id') then
      execute format('drop trigger if exists %I on public.%I', 'rider_id_gate_' || t, t);
      execute format(
        'create trigger %I before insert on public.%I for each row execute function public.rider_id_gate_guard()',
        'rider_id_gate_' || t, t);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
