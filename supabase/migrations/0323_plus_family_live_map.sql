-- ============================================================================
-- 0323 — GET.Plus family plan and God View's "GET.Plus only": joins three
-- features already built, GET.Plus (0316), Family (0317) and the rider live
-- map (0322).
--
-- Version 20261028160000 (0323_plus_family_live_map). Re-runnable: functions
-- "create or replace", the registry row updated in place. No table changes.
--
-- 1. A family host's GET.Plus covers their family members (the owner's
--    Family mockup: "Family plan: one membership covers every member").
--    plus_holder(rider, place) says whose live membership holds for a
--    rider: their own, else the live membership of the host of the family
--    they are an active member of, only where Family's module matrix has
--    the 'get_plus' row's "Family pays" box on for that place. Who is in a
--    family, the host's limits on what the member may use (services), the
--    region's Family switch and the matrix are all Family's own answer
--    (family_payer_for, 0317), never a copy. A member who leaves, or is
--    removed, is no longer covered from that moment: nothing is stored.
--    The matrix row starts OFF (no rule rows), so nothing changes until an
--    admin ticks it.
-- 2. plus_benefits(rider, place) keeps 0316's answer (null when nothing
--    holds or GET.Plus is off at the place) and adds family (true when the
--    host's membership is what holds) and hostName, for the app's "Covered
--    by <host>'s family plan". Every GET.Plus benefit reads it: the
--    discount and priority stamped on a request, the cancel terms and free
--    cancels, premium_plus_terms for the app.
-- 3. Free cancels are the family's, per month, not per member: a covered
--    member's free cancel is counted on the host's membership
--    (plus_memberships.free_cancels_used of the host's row, reset when the
--    host's month renews), the same counter the host's own cancels use. So
--    a plan with 2 free cancels gives the whole family 2 a month.
--    plus_cancel_waive locks the row that is counted (the host's for a
--    covered member) before it reads what is left, so two members
--    cancelling at once can't both take the last one.
-- 4. Redefined from 0316 for the family plan, behaviour otherwise kept:
--    ride_requests_plus_stamp (no longer skips a rider without a
--    membership row of their own: plus_benefits decides) and
--    plus_cancel_waive (counts on the holder's row).
-- 5. God View (0322): rider_live_map_is_plus(uid) was always false while
--    GET.Plus did not exist. It is now: a live membership of their own, or
--    their host's covering them (plus_holder at the family's place, as 0322
--    reads My people at the family's region), so Busy areas set to
--    "GET.Plus" shows to members and covered members only.
-- 6. The registry row 'get_plus' is a real module now (its description).
-- ============================================================================

-- ---- 6. The registry ----------------------------------------------------------------------------
select public.family_register_module('get_plus', 'GET.Plus', 'The host''s GET.Plus covers family members');
update public.booking_modules
   set name = 'GET.Plus', description = 'The host''s GET.Plus covers family members'
 where key = 'get_plus'
   and (name, description) is distinct from ('GET.Plus', 'The host''s GET.Plus covers family members');

-- ---- 1. Whose membership holds ------------------------------------------------------------------
-- The live GET.Plus membership that holds for [p_rider] at [p_place]
-- ({country, state, city, suburb}): {holder, family, hostName}, or null.
-- Their own first; else their family host's, where Family covers GET.Plus.
create or replace function public.plus_holder(p_rider uuid, p_place jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  m public.plus_memberships;
  fam jsonb;
begin
  if p_rider is null then
    return null;
  end if;
  select * into m from public.plus_memberships where rider_id = p_rider;
  if found and public.plus_membership_live(m) then
    return jsonb_build_object('holder', p_rider, 'family', false);
  end if;
  -- Family's own answer: an active member, Family on in the region, the
  -- host allows the service, and the matrix's "Family pays" on here.
  fam := public.family_payer_for('get_plus', p_rider, null, 0, coalesce(p_place, '{}'::jsonb), '{}'::jsonb);
  if not coalesce((fam->>'ok')::boolean, false) or fam->>'payer' is null then
    return null;
  end if;
  select * into m from public.plus_memberships where rider_id = (fam->>'payer')::uuid;
  if not found or not public.plus_membership_live(m) then
    return null;
  end if;
  return jsonb_build_object('holder', m.rider_id, 'family', true, 'hostName', fam->>'hostName');
end;
$$;
revoke execute on function public.plus_holder(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.plus_holder(uuid, jsonb) to service_role;

-- ---- 2. What it gives ---------------------------------------------------------------------------
-- As 0316, through plus_holder: the holder's membership, the rules at the
-- place; family and hostName when the host's plan covers the rider.
create or replace function public.plus_benefits(p_rider uuid, p_country text, p_state text, p_city text,
                                                p_suburb text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  h jsonb;
  m public.plus_memberships;
  v jsonb;
begin
  h := public.plus_holder(p_rider, jsonb_build_object('country', p_country, 'state', p_state, 'city', p_city,
                                                      'suburb', p_suburb));
  if h is null then
    return null;
  end if;
  select * into m from public.plus_memberships where rider_id = (h->>'holder')::uuid;
  if not found then
    return null;
  end if;
  v := public.premium_plus_rules_at(p_country, p_state, p_city, p_suburb);
  if not coalesce((v->>'plusOn')::boolean, false) then
    return null;
  end if;
  return jsonb_build_object(
    'pct', coalesce((v->>'plusDiscountPct')::numeric, 0),
    'maxDiscount', coalesce((v->>'plusMaxDiscount')::numeric, 0),
    'priority', coalesce((v->>'plusPriority')::boolean, false),
    'freeCancels', coalesce((v->>'plusFreeCancels')::numeric, 0)::int,
    'freeCancelsLeft', greatest(0, coalesce((v->>'plusFreeCancels')::numeric, 0)::int - m.free_cancels_used),
    'family', coalesce((h->>'family')::boolean, false))
    || case when coalesce((h->>'family')::boolean, false)
            then jsonb_build_object('hostName', coalesce(h->>'hostName', 'Your family host')) else '{}'::jsonb end;
end;
$$;
revoke execute on function public.plus_benefits(uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.plus_benefits(uuid, text, text, text, text) to service_role;

-- ---- 4. The request's stamp ---------------------------------------------------------------------
-- As 0316, without the shortcut for a rider with no membership row of their
-- own: a family member's request is stamped from their host's plan.
create or replace function public.ride_requests_plus_stamp()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  p record;
  b jsonb;
begin
  new.plus_pct := null;
  new.plus_max_discount := null;
  new.plus_priority := false;
  new.plus_discount := null;
  new.plus_settled_at := null;
  new.plus_waived_fee := null;
  if new.rider_id is null or new.stand_id is not null then
    return new;
  end if;
  begin
    select * into p from public.ride_option_place(new.pickup_lat, new.pickup_lng, new.country, new.state, new.city);
    b := public.plus_benefits(new.rider_id, p.country, p.state, p.city, p.suburb);
  exception when others then
    raise warning 'GET.Plus stamp for ride % failed: %', new.id, sqlerrm;
    b := null;
  end;
  if b is not null then
    new.plus_pct := case when (b->>'pct')::numeric > 0 then (b->>'pct')::numeric end;
    new.plus_max_discount := case when (b->>'maxDiscount')::numeric > 0 then (b->>'maxDiscount')::numeric end;
    new.plus_priority := coalesce((b->>'priority')::boolean, false);
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_plus_stamp() from public, anon, authenticated;

-- ---- 3. Free cancels, the family's --------------------------------------------------------------
-- As 0316: 0 while a free cancel is left (one used, the driver credited),
-- else [p_fee]. The cancel is counted on the holder's membership (the
-- host's for a covered member), locked before what is left is read.
create or replace function public.plus_cancel_waive(r public.ride_requests, p_fee numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  p record;
  h jsonb;
  b jsonb;
  v_holder uuid;
  v_rate numeric := case when r.commission_rate >= 0 and r.commission_rate < 1 then r.commission_rate else 0 end;
  v_fee numeric := round(coalesce(p_fee, 0), 2);
  v_share numeric;
begin
  if v_fee <= 0 or r.rider_id is null then
    return p_fee;
  end if;
  begin
    select * into p from public.ride_option_place(r.pickup_lat, r.pickup_lng, r.country, r.state, r.city);
    h := public.plus_holder(r.rider_id, jsonb_build_object('country', p.country, 'state', p.state, 'city', p.city,
                                                           'suburb', p.suburb));
    if h is null then
      return p_fee;
    end if;
    v_holder := (h->>'holder')::uuid;
    perform 1 from public.plus_memberships where rider_id = v_holder for update;
    if not found then
      return p_fee;
    end if;
    -- Read again now the row is ours: what is left, and that it is still
    -- this membership that holds.
    b := public.plus_benefits(r.rider_id, p.country, p.state, p.city, p.suburb);
    if b is null or (b->>'freeCancelsLeft')::int <= 0
       or (public.plus_holder(r.rider_id, jsonb_build_object('country', p.country, 'state', p.state, 'city', p.city,
                                                             'suburb', p.suburb))->>'holder')::uuid
          is distinct from v_holder then
      return p_fee;
    end if;
    update public.plus_memberships set free_cancels_used = free_cancels_used + 1, updated_at = now()
     where rider_id = v_holder;
    update public.ride_requests set plus_waived_fee = v_fee where id = r.id;
    v_share := round(v_fee * (1 - v_rate), 2);
    if r.partner_id is not null and v_share > 0 then
      insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
      values (r.partner_id, 'get_wallet', 'plus_cancel_credit', v_share, 'get_plus',
              'Cancellation fee, a GET.Plus free cancel paid by get.ride'
              || case when v_rate > 0 then ' (less ' || round(v_rate * 100, 1) || '% commission)' else '' end, r.id)
      on conflict (ride_id) where kind = 'plus_cancel_credit' do nothing;
    end if;
    return 0;
  exception when others then
    raise warning 'GET.Plus free cancel on ride % not applied: %', r.id, sqlerrm;
    return p_fee;
  end;
end;
$$;
revoke execute on function public.plus_cancel_waive(public.ride_requests, numeric) from public, anon, authenticated;

-- ---- 5. God View's "GET.Plus only" --------------------------------------------------------------
-- A GET.Plus member for the rider live map: their own live membership, or
-- their host's covering them at the family's place (0322's My people reads
-- the family's region the same way).
create or replace function public.rider_live_map_is_plus(p_uid uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  fam record;
begin
  if p_uid is null then
    return false;
  end if;
  select * into fam from public.rider_live_map_family(p_uid);
  return public.plus_holder(p_uid, coalesce(fam.place, '{}'::jsonb)) is not null;
end;
$$;
revoke execute on function public.rider_live_map_is_plus(uuid) from public, anon, authenticated;

notify pgrst, 'reload schema';
