-- ============================================================================
-- 0161: My QR — personal QR codes (GET.Referral, GET.me, GET.now)
--
-- An account keeps QR codes of three kinds, each a random, unguessable
-- token that stands for "this account, for this purpose":
--
--   referral  GET.Referral   any account. Scanning it opens sign-up with the
--                            owner's referral code (apply_referral, 0078/0094).
--   me        GET.me         partners only. Scanning it adds the driver as a
--                            My Ride favourite, exactly as entering their My
--                            Ride code does (add_favourite_driver, 0160).
--   now       GET.now        partners only. Scanning it books THAT driver:
--                            the request is offered to them alone, with no
--                            favourites window and no automatic fallback to
--                            anybody else.
--
-- At most one ACTIVE code per (owner, kind). The owner can expire it, make a
-- new one, or bring back one of their last 10 of that kind (the same token
-- works again — "reuse an expired code"), each time choosing an optional
-- auto-expiry: 1 hour, 24 hours, 7 days or never. Making or reviving a code
-- retires whatever code of that kind was live. A retired or lapsed token
-- resolves to "expired" and never to anything about its owner.
--
-- Payloads (the Dart side builds and parses them in lib/src/core/my_qr.dart;
-- the server accepts any of them, or the bare token, wherever it takes one):
--
--   https://getride.my/q/ref/<token>     what the QR encodes: a phone camera
--   https://getride.my/q/me/<token>      without the app lands on the web
--   https://getride.my/q/now/<token>     app (as /share/ and /install/ do)
--   getride://ref/<token>                accepted too (also getride://me/…,
--   getride://now/<token>                getride://now/…)
--
-- Tokens are 22 characters of base64url (A-Z a-z 0-9 - _), 122 random bits
-- (one gen_random_uuid()), case-sensitive.
--
-- What is here:
--
--   personal_qr_codes          id, owner_id, kind, token (unique), created_at,
--                              expires_at, revoked_at, last_activated_at.
--                              Partial unique index: one non-revoked row per
--                              (owner_id, kind). Active = revoked_at is null
--                              and (expires_at is null or expires_at > now()).
--                              An auto-expired row is still "non-revoked"
--                              until the next generate / reactivate retires it
--                              (they always retire first, so it never blocks
--                              them). The owner reads their own rows, admins
--                              all; no client writes (admins may).
--   my_qr_codes()              the caller's codes, active first then newest,
--                              at most 20 per kind, with status active /
--                              expired (lapsed) / revoked (expired by hand or
--                              replaced) and whether it can be revived.
--   generate_my_qr(kind, ttl)  {ok, qr} or {ok:false, error}; errors:
--                              invalid_kind, invalid_ttl, not_a_driver,
--                              driver_unavailable (blocked / rejected),
--                              no_profile, rate_limited (+ retry_after).
--   expire_my_qr(id)           {ok, qr} | {ok:false, error:'not_found'}.
--   reactivate_my_qr(id, ttl)  {ok, qr} | errors as generate, plus not_found
--                              and not_reactivatable (older than the last 10
--                              of its kind).
--   resolve_qr(token)          what a scanned code is (see below).
--   add_favourite_driver_by_qr(token)
--                              a GET.me code → add_favourite_driver with the
--                              driver's My Ride code, so every 0160 rule and
--                              limit applies unchanged. {ok, error?, driver?};
--                              extra errors: expired, wrong_kind.
--   TTL: null (never) / 3600 / 86400 / 604800 seconds; anything else is
--   refused (invalid_ttl). Generating / reviving is limited to 30 per hour
--   per account.
--
-- resolve_qr — anon may call it, because a GET.Referral code is scanned
-- BEFORE the person has an account (the web landing page then carries the
-- code into sign-up). What each caller gets:
--
--   anon,          referral, active   {status:'active', kind:'referral', referral_code}
--   anon,          me / now, active   {status:'sign_in_required', kind}   (nothing of the owner)
--   authenticated, referral, active   {status:'active', kind, referral_code, owner_name (masked), own}
--   authenticated, me, active         {status:'active', kind, driver (card, no phone), own, available,
--                                      already_favourite}
--   authenticated, now, active        {status:'active', kind, driver, own, available, online}
--   anyone,        retired / lapsed   {status:'expired'}
--   anyone,        no such token      {status:'unknown'}
--   anyone,        too many unknowns  {status:'rate_limited', retry_after}
--
--   "available" is false when the driver cannot take rides (blocked, not
--   approved) or has hidden the caller in My Ride — the two read alike, as
--   in 0160. A token that matches nobody counts towards 20 per account / 60
--   per network address per hour (auth_rate_hits), like My Ride codes.
--
-- GET.now booking (ride_requests):
--
--   New columns, all nullable (null = today's behaviour, so older builds book
--   exactly as before):
--     direct_qr_token   what the rider's app sends: the scanned GET.now
--                       payload or token. Write-only: the insert trigger
--                       reads it and stores null, so the token is never kept
--                       on (or readable from) the ride.
--     direct_driver_id  the driver booked directly (server-set).
--     direct_qr_id      the code it was booked through (server-set).
--
--   * BEFORE INSERT (trg_ride_requests_c_my_ride, replaced): with a
--     direct_qr_token the request must be an open request of a rider, the
--     token an ACTIVE `now` code, not the rider's own, of a bookable driver
--     who has not hidden the rider — else the insert is refused with
--     QR_EXPIRED, QR_SELF_BOOKING or QR_DRIVER_UNAVAILABLE (nothing is
--     written, nothing is pushed). Otherwise target_driver_ids = {driver},
--     targeted_until = now() + 10 minutes — longer than the 7 minutes after
--     which an open request expires (0139, AppConfig.requestExpiry) plus the
--     minute its cron can lag, so the request never opens to anybody else
--     before it expires — and any favourites the client sent are dropped.
--     No distance cap: the rider scanned the driver's code. The code is not
--     consumed: the driver can keep showing it until they expire it.
--   * The read policy and update guard of 0160 then keep the request to the
--     rider, that driver and admins, unchanged. The guard also keeps the
--     three new columns out of clients' hands.
--   * Push (notify_partners_on_ride_request, replaced): the driver alone,
--     "Passenger booked you directly" (data.direct = true).
--   * No automatic fallback: ride_requests_dispatch_tick() skips direct
--     bookings, and taking a driver off a rider's requests
--     (ride_requests_drop_target: un-favouriting / hiding) leaves direct
--     bookings alone, so neither opens one to everybody.
--     ride_request_add_targets refuses a direct booking (direct_booking).
--     The rider may still choose to: ride_request_offer_to_all works on a
--     direct booking as on any targeted one, ending the exclusive window
--     there and then (decided: no automatic fallback, but the rider keeps
--     the explicit "Offer to all nearby").
--
-- Rollback:
--   re-run 0160's ride_requests_my_ride_targets, ride_requests_my_ride_guard,
--   ride_request_push_message, notify_partners_on_ride_request,
--   ride_requests_dispatch_tick, ride_requests_drop_target and
--   ride_request_add_targets; drop the functions below, the table
--   personal_qr_codes and the three ride_requests columns.
-- ============================================================================

-- ---- Table ------------------------------------------------------------------------

create table if not exists public.personal_qr_codes (
  id                uuid primary key default gen_random_uuid(),
  owner_id          uuid not null references public.profiles(id) on delete cascade,
  kind              text not null check (kind in ('referral', 'me', 'now')),
  token             text not null unique check (token ~ '^[A-Za-z0-9_-]{20,64}$'),
  created_at        timestamptz not null default now(),
  expires_at        timestamptz,
  revoked_at        timestamptz,
  last_activated_at timestamptz not null default now()
);

create unique index if not exists personal_qr_codes_one_live
  on public.personal_qr_codes (owner_id, kind) where revoked_at is null;
create index if not exists personal_qr_codes_owner
  on public.personal_qr_codes (owner_id, kind, last_activated_at desc);

alter table public.personal_qr_codes enable row level security;

drop policy if exists "personal_qr_codes read" on public.personal_qr_codes;
create policy "personal_qr_codes read" on public.personal_qr_codes
  for select using (owner_id = auth.uid() or public.caller_is_admin());

drop policy if exists "personal_qr_codes admin write" on public.personal_qr_codes;
create policy "personal_qr_codes admin write" on public.personal_qr_codes
  for all using (public.caller_is_admin()) with check (public.caller_is_admin());

revoke all on public.personal_qr_codes from public, anon, authenticated;
grant select, insert, update, delete on public.personal_qr_codes to authenticated;

-- ---- Helpers ----------------------------------------------------------------------

-- 22 characters of base64url: one random uuid (122 random bits).
create or replace function public.personal_qr_new_token()
returns text
language sql
volatile
set search_path = ''
as $$
  select translate(rtrim(encode(uuid_send(gen_random_uuid()), 'base64'), '='), '+/', '-_');
$$;

revoke execute on function public.personal_qr_new_token() from public, anon, authenticated;

-- The token in a scanned payload (any accepted form) or a bare token; null
-- when it cannot be one.
create or replace function public.personal_qr_token_of(p_input text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when t ~ '^[A-Za-z0-9_-]{20,64}$' then t end
    from (
      select regexp_replace(
               split_part(split_part(rtrim(btrim(coalesce(p_input, '')), '/'), '?', 1), '#', 1),
               '^.*/', '') as t
    ) s;
$$;

revoke execute on function public.personal_qr_token_of(text) from public, anon;
grant execute on function public.personal_qr_token_of(text) to authenticated;

-- active / expired (lapsed on its own) / revoked (expired by hand or
-- replaced). A row that lapsed and was retired later still reads expired.
create or replace function public.personal_qr_status(p_expires_at timestamptz, p_revoked_at timestamptz)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_revoked_at is null and (p_expires_at is null or p_expires_at > now()) then 'active'
    when p_expires_at is not null and p_expires_at <= coalesce(p_revoked_at, now()) then 'expired'
    else 'revoked'
  end;
$$;

-- The account's referral code, as apply_referral resolves it: the explicit
-- profiles.referral_code, else the first 8 characters of the account id.
create or replace function public.personal_qr_referral_code(p_owner uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
           nullif(upper(regexp_replace(coalesce(pr.referral_code, ''), '[^a-zA-Z0-9]', '', 'g')), ''),
           upper(left(replace(pr.id::text, '-', ''), 8)))
    from public.profiles pr where pr.id = p_owner;
$$;

revoke execute on function public.personal_qr_referral_code(uuid) from public, anon, authenticated;

-- How far back a code can be revived, and how many are listed, per kind.
create or replace function public.personal_qr_recent_rank(p_row public.personal_qr_codes)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int + 1 from public.personal_qr_codes q
   where q.owner_id = p_row.owner_id and q.kind = p_row.kind
     and (q.last_activated_at, q.id) > (p_row.last_activated_at, p_row.id);
$$;

revoke execute on function public.personal_qr_recent_rank(public.personal_qr_codes) from public, anon, authenticated;

-- The JSON the RPCs answer with for one of the caller's codes.
create or replace function public.personal_qr_json(p_row public.personal_qr_codes)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', p_row.id,
    'kind', p_row.kind,
    'token', p_row.token,
    'status', public.personal_qr_status(p_row.expires_at, p_row.revoked_at),
    'created_at', p_row.created_at,
    'expires_at', p_row.expires_at,
    'revoked_at', p_row.revoked_at,
    'last_activated_at', p_row.last_activated_at,
    'reactivatable', public.personal_qr_status(p_row.expires_at, p_row.revoked_at) <> 'active'
                     and public.personal_qr_recent_rank(p_row) <= 10
  );
$$;

revoke execute on function public.personal_qr_json(public.personal_qr_codes) from public, anon, authenticated;

-- The interval a TTL in seconds stands for; null = never. Raises for any
-- other value.
create or replace function public.personal_qr_ttl(p_ttl_seconds integer)
returns interval
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_ttl_seconds is null then
    return null;
  end if;
  if p_ttl_seconds not in (3600, 86400, 604800) then
    raise exception 'invalid_ttl' using errcode = '22023';
  end if;
  return make_interval(secs => p_ttl_seconds);
end;
$$;

revoke execute on function public.personal_qr_ttl(integer) from public, anon, authenticated;

-- Why [p_owner] may not hold a code of [p_kind] (null when they may).
create or replace function public.personal_qr_refusal(p_owner uuid, p_kind text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  p public.partners;
begin
  if p_kind is null or p_kind not in ('referral', 'me', 'now') then
    return 'invalid_kind';
  end if;
  if not exists (select 1 from public.profiles where id = p_owner) then
    return 'no_profile';
  end if;
  if p_kind = 'referral' then
    return null;
  end if;
  p := public.my_ride_own_partner(p_owner);
  if p.id is null then
    return 'not_a_driver';
  end if;
  if p.status::text in ('blocked', 'rejected') then
    return 'driver_unavailable';
  end if;
  return null;
end;
$$;

revoke execute on function public.personal_qr_refusal(uuid, text) from public, anon, authenticated;

-- Retires the caller's live code of a kind (active or lapsed).
create or replace function public.personal_qr_retire_live(p_owner uuid, p_kind text, p_except uuid default null)
returns void
language sql
security definer
set search_path = public
as $$
  update public.personal_qr_codes
     set revoked_at = now()
   where owner_id = p_owner and kind = p_kind and revoked_at is null
     and id is distinct from p_except;
$$;

revoke execute on function public.personal_qr_retire_live(uuid, text, uuid) from public, anon, authenticated;

-- ---- The owner's RPCs ---------------------------------------------------------------

create or replace function public.my_qr_codes()
returns table (
  id                uuid,
  kind              text,
  token             text,
  status            text,
  created_at        timestamptz,
  expires_at        timestamptz,
  revoked_at        timestamptz,
  last_activated_at timestamptz,
  reactivatable     boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
  with ranked as (
    select q.*,
           public.personal_qr_status(q.expires_at, q.revoked_at) as st,
           row_number() over (partition by q.kind order by q.last_activated_at desc, q.id desc) as rk
      from public.personal_qr_codes q
     where q.owner_id = v_uid
  )
  select r.id, r.kind, r.token, r.st, r.created_at, r.expires_at, r.revoked_at, r.last_activated_at,
         r.st <> 'active' and r.rk <= 10
    from ranked r
   where r.rk <= 20
   order by (r.st = 'active') desc, r.last_activated_at desc, r.id desc;
end;
$$;

revoke execute on function public.my_qr_codes() from public, anon;
grant execute on function public.my_qr_codes() to authenticated;

create or replace function public.generate_my_qr(p_kind text, p_ttl_seconds integer default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_kind text := lower(btrim(coalesce(p_kind, '')));
  v_ttl  interval;
  v_why  text;
  v_wait int;
  r      public.personal_qr_codes;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  v_why := public.personal_qr_refusal(v_uid, v_kind);
  if v_why is not null then
    return jsonb_build_object('ok', false, 'error', v_why);
  end if;
  begin
    v_ttl := public.personal_qr_ttl(p_ttl_seconds);
  exception when invalid_parameter_value then
    return jsonb_build_object('ok', false, 'error', 'invalid_ttl');
  end;
  v_wait := public.auth_rate_take('my_qr_write', v_uid::text, 30, interval '1 hour');
  if v_wait > 0 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited', 'retry_after', v_wait);
  end if;

  perform pg_advisory_xact_lock(hashtextextended('my_qr|' || v_uid::text || '|' || v_kind, 161));
  perform public.personal_qr_retire_live(v_uid, v_kind);
  loop
    begin
      insert into public.personal_qr_codes (owner_id, kind, token, expires_at, last_activated_at)
      values (v_uid, v_kind, public.personal_qr_new_token(), now() + v_ttl, clock_timestamp())
      returning * into r;
      exit;
    exception when unique_violation then
      null;  -- a token collision (practically never): draw again
    end;
  end loop;
  return jsonb_build_object('ok', true, 'qr', public.personal_qr_json(r));
end;
$$;

revoke execute on function public.generate_my_qr(text, integer) from public, anon;
grant execute on function public.generate_my_qr(text, integer) to authenticated;

create or replace function public.expire_my_qr(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  r public.personal_qr_codes;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  update public.personal_qr_codes
     set revoked_at = coalesce(revoked_at, now())
   where id = p_id and owner_id = v_uid
  returning * into r;
  if r.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  return jsonb_build_object('ok', true, 'qr', public.personal_qr_json(r));
end;
$$;

revoke execute on function public.expire_my_qr(uuid) from public, anon;
grant execute on function public.expire_my_qr(uuid) to authenticated;

create or replace function public.reactivate_my_qr(p_id uuid, p_ttl_seconds integer default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_ttl  interval;
  v_why  text;
  v_wait int;
  r      public.personal_qr_codes;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.personal_qr_codes where id = p_id and owner_id = v_uid;
  if r.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  v_why := public.personal_qr_refusal(v_uid, r.kind);
  if v_why is not null then
    return jsonb_build_object('ok', false, 'error', v_why);
  end if;
  begin
    v_ttl := public.personal_qr_ttl(p_ttl_seconds);
  exception when invalid_parameter_value then
    return jsonb_build_object('ok', false, 'error', 'invalid_ttl');
  end;
  if public.personal_qr_recent_rank(r) > 10 then
    return jsonb_build_object('ok', false, 'error', 'not_reactivatable');
  end if;
  v_wait := public.auth_rate_take('my_qr_write', v_uid::text, 30, interval '1 hour');
  if v_wait > 0 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited', 'retry_after', v_wait);
  end if;

  perform pg_advisory_xact_lock(hashtextextended('my_qr|' || v_uid::text || '|' || r.kind, 161));
  perform public.personal_qr_retire_live(v_uid, r.kind, r.id);
  update public.personal_qr_codes
     set revoked_at = null,
         expires_at = now() + v_ttl,
         last_activated_at = clock_timestamp()
   where id = r.id
  returning * into r;
  return jsonb_build_object('ok', true, 'qr', public.personal_qr_json(r));
end;
$$;

revoke execute on function public.reactivate_my_qr(uuid, integer) from public, anon;
grant execute on function public.reactivate_my_qr(uuid, integer) to authenticated;

-- ---- Scanning -------------------------------------------------------------------------

-- Seconds until the caller may look up unknown tokens again (0 = now).
create or replace function public.personal_qr_miss_wait(p_uid uuid, p_ip text)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select greatest(
           coalesce((select case when count(*) >= 20
                             then ceil(extract(epoch from (min(at) + interval '1 hour' - now())))::int end
                       from public.auth_rate_hits
                      where p_uid is not null and bucket = 'my_qr_miss' and key = p_uid::text
                        and at > now() - interval '1 hour'), 0),
           coalesce((select case when count(*) >= 60
                             then ceil(extract(epoch from (min(at) + interval '1 hour' - now())))::int end
                       from public.auth_rate_hits
                      where p_ip is not null and bucket = 'my_qr_miss_ip' and key = p_ip
                        and at > now() - interval '1 hour'), 0));
$$;

revoke execute on function public.personal_qr_miss_wait(uuid, text) from public, anon, authenticated;

create or replace function public.personal_qr_record_miss(p_uid uuid, p_ip text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.auth_rate_take('my_qr_miss', p_uid::text, 20, interval '1 hour');
  perform public.auth_rate_take('my_qr_miss_ip', p_ip, 60, interval '1 hour');
end;
$$;

revoke execute on function public.personal_qr_record_miss(uuid, text) from public, anon, authenticated;

create or replace function public.resolve_qr(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_ip    text := public.request_client_ip();
  v_token text := public.personal_qr_token_of(p_token);
  v_wait  int;
  q       public.personal_qr_codes;
  p       public.partners;
  v_ok    boolean;
  v_hid   boolean;
  v_on    boolean;
  v_name  text;
begin
  if v_token is null then
    return jsonb_build_object('status', 'unknown');
  end if;
  v_wait := public.personal_qr_miss_wait(v_uid, v_ip);
  if v_wait > 0 then
    return jsonb_build_object('status', 'rate_limited', 'retry_after', v_wait);
  end if;

  select * into q from public.personal_qr_codes where token = v_token;
  if q.id is null then
    perform public.personal_qr_record_miss(v_uid, v_ip);
    return jsonb_build_object('status', 'unknown');
  end if;
  if public.personal_qr_status(q.expires_at, q.revoked_at) <> 'active' then
    return jsonb_build_object('status', 'expired');
  end if;

  if q.kind = 'referral' then
    if v_uid is null then
      return jsonb_build_object('status', 'active', 'kind', 'referral',
                                'referral_code', public.personal_qr_referral_code(q.owner_id));
    end if;
    select name into v_name from public.profiles where id = q.owner_id;
    return jsonb_build_object('status', 'active', 'kind', 'referral',
                              'referral_code', public.personal_qr_referral_code(q.owner_id),
                              'owner_name', public.wallet_mask_name(v_name),
                              'own', q.owner_id = v_uid);
  end if;

  -- GET.me / GET.now: a driver, for signed-in callers only.
  if v_uid is null then
    return jsonb_build_object('status', 'sign_in_required', 'kind', q.kind);
  end if;
  p := public.my_ride_partner_of(q.owner_id);
  if p.id is null then
    return jsonb_build_object('status', 'expired');
  end if;
  v_hid := exists (select 1 from public.favourite_drivers f
                    where f.rider_id = v_uid and f.driver_id = q.owner_id and f.hidden_by_driver);
  v_ok := public.partner_status_bookable(p.status::text) and not v_hid;
  v_on := v_ok and exists (select 1 from public.driver_presence d
                            where d.profile_id = q.owner_id and d.online
                              and d.updated_at > now() - interval '3 minutes');
  if q.kind = 'me' then
    return jsonb_build_object(
      'status', 'active', 'kind', 'me',
      'driver', public.my_ride_driver_card(p),
      'own', q.owner_id = v_uid,
      'available', v_ok,
      'already_favourite', exists (select 1 from public.favourite_drivers f
                                    where f.rider_id = v_uid and f.driver_id = q.owner_id));
  end if;
  return jsonb_build_object(
    'status', 'active', 'kind', 'now',
    'driver', public.my_ride_driver_card(p),
    'own', q.owner_id = v_uid,
    'available', v_ok,
    'online', v_on);
end;
$$;

revoke execute on function public.resolve_qr(text) from public;
grant execute on function public.resolve_qr(text) to anon, authenticated;

create or replace function public.add_favourite_driver_by_qr(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_ip    text := public.request_client_ip();
  v_token text := public.personal_qr_token_of(p_token);
  v_wait  int;
  q       public.personal_qr_codes;
  p       public.partners;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_token is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_code');
  end if;
  v_wait := public.personal_qr_miss_wait(v_uid, v_ip);
  if v_wait > 0 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited', 'retry_after', v_wait);
  end if;
  select * into q from public.personal_qr_codes where token = v_token;
  if q.id is null then
    perform public.personal_qr_record_miss(v_uid, v_ip);
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if public.personal_qr_status(q.expires_at, q.revoked_at) <> 'active' then
    return jsonb_build_object('ok', false, 'error', 'expired');
  end if;
  if q.kind <> 'me' then
    return jsonb_build_object('ok', false, 'error', 'wrong_kind');
  end if;
  if q.owner_id = v_uid then
    return jsonb_build_object('ok', false, 'error', 'own_code');
  end if;
  p := public.my_ride_partner_of(q.owner_id);
  if p.id is null or p.my_ride_code is null then
    return jsonb_build_object('ok', false, 'error', 'unavailable');
  end if;
  -- Everything else (blocked, the 50 limit, no profile) is My Ride's own.
  return public.add_favourite_driver(p.my_ride_code);
end;
$$;

revoke execute on function public.add_favourite_driver_by_qr(text) from public, anon;
grant execute on function public.add_favourite_driver_by_qr(text) to authenticated;

-- ---- GET.now: booking a driver directly ------------------------------------------------

alter table public.ride_requests
  add column if not exists direct_qr_token  text,
  add column if not exists direct_driver_id uuid,
  add column if not exists direct_qr_id     uuid references public.personal_qr_codes(id) on delete set null;

create index if not exists ride_requests_direct_driver
  on public.ride_requests (direct_driver_id) where direct_driver_id is not null;

-- As 0160, plus GET.now: a valid direct_qr_token makes the request the
-- driver's alone for longer than it can stay open.
create or replace function public.ride_requests_my_ride_targets()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.vehicle_service_dispatch_config(new.service);
  v_rider_max double precision := case when new.my_ride_max_km > 0 then new.my_ride_max_km end;
  v_max double precision;
  v_targets uuid[];
  v_direct text := nullif(btrim(coalesce(new.direct_qr_token, '')), '');
  q public.personal_qr_codes;
  p public.partners;
begin
  new.targeted_until := null;
  new.fallback_pushed_at := null;
  new.widened_pushed_at := null;
  -- Server-set; the token itself is never stored.
  new.direct_qr_token := null;
  new.direct_driver_id := null;
  new.direct_qr_id := null;

  -- GET.now.
  if v_direct is not null then
    select * into q from public.personal_qr_codes where token = public.personal_qr_token_of(v_direct);
    if q.id is null or q.kind <> 'now' or public.personal_qr_status(q.expires_at, q.revoked_at) <> 'active' then
      raise exception 'QR_EXPIRED' using errcode = 'P0001',
        hint = 'This GET.now code has expired. Ask the driver for their current code.';
    end if;
    if new.rider_id is null or new.status is distinct from 'open' then
      raise exception 'QR_EXPIRED' using errcode = 'P0001',
        hint = 'A GET.now code books a new, open request only.';
    end if;
    if q.owner_id = new.rider_id then
      raise exception 'QR_SELF_BOOKING' using errcode = 'P0001',
        hint = 'You can''t book yourself with your own GET.now code.';
    end if;
    p := public.my_ride_partner_of(q.owner_id);
    if p.id is null or not public.partner_status_bookable(p.status::text)
       or exists (select 1 from public.favourite_drivers f
                   where f.rider_id = new.rider_id and f.driver_id = q.owner_id and f.hidden_by_driver) then
      raise exception 'QR_DRIVER_UNAVAILABLE' using errcode = 'P0001',
        hint = 'This driver can''t take rides right now.';
    end if;
    new.direct_driver_id := q.owner_id;
    new.direct_qr_id := q.id;
    new.target_driver_ids := array[q.owner_id];
    -- Longer than an open request lives (7 minutes, 0139) plus its cron's lag.
    new.targeted_until := now() + interval '10 minutes';
    new.my_ride_max_km := null;
    return new;
  end if;

  -- The smaller of the rider's and the service's caps (least() skips nulls).
  v_max := least(v_rider_max, (cfg->>'my_ride_max_km')::double precision);
  new.my_ride_max_km := v_max;

  if coalesce(cardinality(new.target_driver_ids), 0) > 0 and new.status = 'open' and new.rider_id is not null then
    v_targets := public.my_ride_valid_targets(new.rider_id, new.target_driver_ids, new.pickup_lat, new.pickup_lng, v_max);
  end if;
  if coalesce(cardinality(v_targets), 0) > 0 then
    new.target_driver_ids := v_targets;
    new.targeted_until := now() + make_interval(secs => (cfg->>'my_ride_window_sec')::int);
  else
    new.target_driver_ids := null;
  end if;

  -- Open to everybody from the start: where nobody is within the min
  -- radius, the insert push goes straight to the max radius.
  if new.status = 'open' and new.targeted_until is null
     and not exists (select 1 from public.nearby_online_drivers(new.pickup_lat, new.pickup_lng,
                                                                (cfg->>'search_radius_min_km')::double precision) d
                      where d is distinct from new.rider_id) then
    new.widened_pushed_at := now();
  end if;
  return new;
end;
$$;

revoke execute on function public.ride_requests_my_ride_targets() from public, anon, authenticated;

-- As 0160, and the GET.now columns are the server's too.
create or replace function public.ride_requests_my_ride_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  -- The server's columns.
  new.target_driver_ids := old.target_driver_ids;
  new.targeted_until := old.targeted_until;
  new.my_ride_max_km := old.my_ride_max_km;
  new.fallback_pushed_at := old.fallback_pushed_at;
  new.widened_pushed_at := old.widened_pushed_at;
  new.direct_qr_token := old.direct_qr_token;
  new.direct_driver_id := old.direct_driver_id;
  new.direct_qr_id := old.direct_qr_id;
  -- Inside the window, only the rider and the targeted drivers.
  if old.status = 'open'
     and public.ride_request_targeting(old.target_driver_ids, old.targeted_until)
     and auth.uid() is distinct from old.rider_id
     and not coalesce(auth.uid() = any(old.target_driver_ids), false) then
    raise exception 'RIDE_TARGETED_TO_FAVOURITES' using errcode = '42501',
      hint = 'This request is offered to the rider''s favourite drivers first.';
  end if;
  return new;
end;
$$;

revoke execute on function public.ride_requests_my_ride_guard() from public, anon, authenticated;

-- As 0160, plus 'direct': "Passenger booked you directly".
create or replace function public.ride_request_push_message(
  p_request uuid, p_pickup_name text, p_pickup_address text, p_fare numeric, p_currency text,
  p_kind text
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'title', case p_kind
               when 'raised' then 'Fare increased'
               when 'my_ride' then 'Your regular rider needs a ride'
               when 'direct' then 'Passenger booked you directly'
               else 'New ride request' end,
    'body', case when p_kind = 'raised' then 'Higher fare — pickup at ' else 'Pickup at ' end
            || coalesce(nullif(p_pickup_name, ''), nullif(p_pickup_address, ''), 'a nearby location')
            || case when p_fare is not null
                    then ' • ' || public.currency_symbol(p_currency) || ' ' || p_fare::text
                    else '' end,
    'data', jsonb_build_object(
      'type', case when p_kind = 'raised' then 'ride_request_fare_raised' else 'ride_request' end,
      'ride_request_id', p_request,
      'my_ride', p_kind = 'my_ride',
      'direct', p_kind = 'direct'
    )
  );
$$;

revoke execute on function public.ride_request_push_message(uuid, text, text, numeric, text, text)
  from public, anon, authenticated;

-- As 0160; a direct booking's insert push says so.
create or replace function public.notify_partners_on_ride_request()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  cfg      jsonb;
  v_raised boolean := tg_op = 'UPDATE';
  v_msg    jsonb;
  v_radius double precision;
  v_driver uuid;
  v_told   int := 0;
begin
  -- Only ever notify about requests that are still open (biddable).
  if new.status is distinct from 'open' then
    return new;
  end if;

  -- On UPDATE, fire only when the passenger raised their fare on the open row.
  if tg_op = 'UPDATE'
     and not (new.fare is distinct from old.fare
              and coalesce(new.fare, 0) > coalesce(old.fare, 0)) then
    return new;
  end if;

  -- Inside the favourites / direct window: the targeted drivers, wherever they are.
  if public.ride_request_targeting(new.target_driver_ids, new.targeted_until) then
    v_msg := public.ride_request_push_message(new.id, new.pickup_name, new.pickup_address, new.fare, new.currency,
                                              case when v_raised then 'raised'
                                                   when new.direct_driver_id is not null then 'direct'
                                                   else 'my_ride' end);
    if v_raised then
      foreach v_driver in array new.target_driver_ids loop
        continue when v_driver = new.rider_id;
        perform public.send_push_webhook(v_msg || jsonb_build_object('profileId', v_driver));
      end loop;
    else
      perform public.ride_request_push_targets(new.id, new.target_driver_ids, v_msg);
    end if;
    return new;
  end if;

  -- Open to all: the drivers near the pickup — the service's min radius,
  -- or its max once widened.
  cfg := public.vehicle_service_dispatch_config(new.service);
  v_radius := case when new.widened_pushed_at is not null
                   then (cfg->>'search_radius_max_km')::double precision
                   else (cfg->>'search_radius_min_km')::double precision end;
  v_msg := public.ride_request_push_message(new.id, new.pickup_name, new.pickup_address, new.fare, new.currency,
                                            case when v_raised then 'raised' else 'new' end);
  v_told := public.ride_request_push_nearby(new.id, new.rider_id, new.pickup_lat, new.pickup_lng, v_radius, v_msg,
                                            case when v_raised then 'raised' else 'nearby' end, false);

  -- Nobody known nearby: every driver, as before.
  if v_told = 0 then
    perform public.ride_request_push_everyone(new.id, v_msg, case when v_raised then 'raised' else 'everyone' end);
  end if;

  return new;
exception when others then
  -- Never let a notification failure block the ride request write.
  return new;
end;
$$;

-- As 0160, but a direct booking never opens to all on its own.
create or replace function public.ride_requests_dispatch_tick()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  n int := 0;
begin
  for v_id in
    select id from public.ride_requests
     where status = 'open'
       and created_at > now() - interval '15 minutes'
       and targeted_until is not null and targeted_until <= now()
       and fallback_pushed_at is null
       and direct_driver_id is null
  loop
    if public.ride_request_open_to_all(v_id) >= 0 then
      n := n + 1;
    end if;
  end loop;

  for v_id in
    select id from public.ride_requests
     where status = 'open'
       and created_at > now() - interval '15 minutes'
       and widened_pushed_at is null
       and (targeted_until is null or fallback_pushed_at is not null)
  loop
    if public.ride_request_widen(v_id) >= 0 then
      n := n + 1;
    end if;
  end loop;

  delete from public.ride_request_pushes where at < now() - interval '1 day';
  return n;
end;
$$;

revoke execute on function public.ride_requests_dispatch_tick() from public, anon, authenticated;
grant execute on function public.ride_requests_dispatch_tick() to service_role;

-- As 0160, but a direct booking keeps its driver: un-favouriting or hiding
-- does not take them off it (nor open it to everybody).
create or replace function public.ride_requests_drop_target(p_rider uuid, p_driver uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  for v_id in
    update public.ride_requests
       set target_driver_ids = nullif(array_remove(target_driver_ids, p_driver), '{}')
     where rider_id = p_rider and status = 'open' and p_driver = any(target_driver_ids)
       and direct_driver_id is null
    returning id
  loop
    if exists (select 1 from public.ride_requests
                where id = v_id and target_driver_ids is null
                  and targeted_until is not null and fallback_pushed_at is null) then
      perform public.ride_request_open_to_all(v_id);
    end if;
  end loop;
end;
$$;

revoke execute on function public.ride_requests_drop_target(uuid, uuid) from public, anon, authenticated;

-- As 0160, but a direct booking is for its driver alone.
create or replace function public.ride_request_add_targets(p_request_id uuid, p_driver_ids uuid[])
returns uuid[]
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  r public.ride_requests;
  v_new uuid[];
  v_all uuid[];
  v_msg jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_request_id for update;
  if not found or r.rider_id is distinct from v_uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status <> 'open' then
    raise exception 'not_open' using errcode = '22023';
  end if;
  if r.direct_driver_id is not null and r.fallback_pushed_at is null then
    raise exception 'direct_booking' using errcode = '22023',
      hint = 'This request was booked with a driver''s GET.now code.';
  end if;
  v_new := public.my_ride_valid_targets(
    v_uid,
    array(select d from unnest(coalesce(p_driver_ids, '{}')) d
           where not (d = any(coalesce(r.target_driver_ids, '{}')))),
    r.pickup_lat, r.pickup_lng, r.my_ride_max_km);
  v_new := v_new[1:greatest(0, 20 - coalesce(cardinality(r.target_driver_ids), 0))];
  if coalesce(cardinality(v_new), 0) = 0 then
    return coalesce(r.target_driver_ids, '{}');
  end if;
  v_all := coalesce(r.target_driver_ids, '{}') || v_new;
  update public.ride_requests set target_driver_ids = v_all where id = p_request_id;
  begin
    v_msg := public.ride_request_push_message(r.id, r.pickup_name, r.pickup_address, r.fare, r.currency, 'my_ride');
    perform public.ride_request_push_targets(r.id, v_new, v_msg);
  exception when others then
    null;
  end;
  return v_all;
end;
$$;

revoke execute on function public.ride_request_add_targets(uuid, uuid[]) from public, anon;
grant execute on function public.ride_request_add_targets(uuid, uuid[]) to authenticated;

notify pgrst, 'reload schema';
