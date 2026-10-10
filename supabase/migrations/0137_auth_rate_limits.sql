-- ============================================================================
-- 0137: rate limits on the pre-login checks, and a way past a PIN lock
--
-- Two checks run before anyone is signed in, so anyone can call them:
--
--   * profile_phone_lookup says whether a number has an account. Unlimited,
--     it lists who uses the app one number at a time. It now answers at most
--     60 times in 10 minutes from one network address.
--   * verify_pin_for_login locks an account for 15 minutes after 5 wrong
--     PINs. That stops guessing, but it also lets a stranger lock someone out
--     of their own account at will. It now answers at most 30 times in 10
--     minutes from one network address, so one caller cannot lock many
--     accounts; and clear_my_pin_lock lets the owner lift their lock after
--     signing in with an SMS code (which proves the number is theirs).
--
-- Over a limit both raise 'RATE_LIMITED:<seconds until the next try>'.
--
-- The address is the caller's as the API gateway reports it
-- (request_client_ip). A request without one (SQL, the service role) is not
-- limited. Mobile carriers put many phones behind one address, which is why
-- the limits are well above what one person signing in needs.
--
-- The SMS sends themselves are made by Supabase Auth (signInWithOtp), so their
-- limits are Auth's own settings (Dashboard → Authentication → Rate Limits),
-- not this migration.
-- ============================================================================

create table if not exists public.auth_rate_hits (
  id bigserial primary key,
  bucket text not null,
  key text not null,
  at timestamptz not null default now()
);

create index if not exists auth_rate_hits_bucket_key_at on public.auth_rate_hits (bucket, key, at);

-- Nobody reads or writes it but the functions below.
alter table public.auth_rate_hits enable row level security;
revoke all on table public.auth_rate_hits from public, anon, authenticated;
revoke all on sequence public.auth_rate_hits_id_seq from public, anon, authenticated;

-- The caller's address as the gateway passed it on: Cloudflare's own header
-- first (a client cannot set it through Cloudflare), then the first
-- forwarded-for entry. Null outside an API request.
create or replace function public.request_client_ip()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  h json;
  v text;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    return null;
  end;
  if h is null then
    return null;
  end if;
  v := coalesce(
    nullif(btrim(h->>'cf-connecting-ip'), ''),
    nullif(btrim(h->>'x-real-ip'), ''),
    nullif(btrim(split_part(coalesce(h->>'x-forwarded-for', ''), ',', 1)), '')
  );
  return left(v, 64);
end;
$$;

revoke execute on function public.request_client_ip() from public, anon, authenticated;

-- Counts one try in [p_bucket] for [p_key]: 0 when it is within [p_limit] in
-- the last [p_window] (and is recorded), else the seconds until the oldest
-- try in the window leaves it (and nothing is recorded). A null key is never
-- limited.
create or replace function public.auth_rate_take(p_bucket text, p_key text, p_limit integer, p_window interval)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
  v_oldest timestamptz;
begin
  if p_key is null or p_key = '' then
    return 0;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_bucket || '|' || p_key, 137));
  delete from public.auth_rate_hits where bucket = p_bucket and key = p_key and at < now() - p_window;
  select count(*), min(at) into v_count, v_oldest
    from public.auth_rate_hits where bucket = p_bucket and key = p_key;
  if v_count >= p_limit then
    return greatest(1, ceil(extract(epoch from (v_oldest + p_window - now())))::integer);
  end if;
  insert into public.auth_rate_hits (bucket, key) values (p_bucket, p_key);
  -- Now and then, sweep what every other key left behind.
  if random() < 0.01 then
    delete from public.auth_rate_hits where at < now() - interval '1 day';
  end if;
  return 0;
end;
$$;

revoke execute on function public.auth_rate_take(text, text, integer, interval) from public, anon, authenticated;

-- ---- profile_phone_lookup: as in 0097, at most 60 per 10 minutes per address.
create or replace function public.profile_phone_lookup(p_phone text)
returns table (
  has_profile boolean,
  has_pin     boolean,
  is_deleted  boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_wait integer := public.auth_rate_take('phone_lookup', public.request_client_ip(), 60, interval '10 minutes');
begin
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait;
  end if;
  return query
  with digits as (
    select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') as d
  ),
  variants as (
    select array_remove(array['+' || d, d, '0' || d, ltrim(d, '0')], null) as v
    from digits
  ),
  match as (
    select p.pin, p.login_pin, p.pin_hash, p.profile_status
    from public.profiles p, variants
    where p.phone = any(variants.v)
    limit 1
  )
  select
    exists(select 1 from match),
    coalesce((select (m.pin is not null and m.pin <> '')
                  or (m.login_pin is not null and m.login_pin <> '')
                  or (m.pin_hash is not null and m.pin_hash <> '')
              from match m), false),
    coalesce((select lower(m.profile_status::text) = 'deleted' from match m), false);
end;
$$;

revoke all on function public.profile_phone_lookup(text) from public;
grant execute on function public.profile_phone_lookup(text) to anon, authenticated;

-- ---- verify_pin_for_login: as in 0097, at most 30 per 10 minutes per address.
create or replace function public.verify_pin_for_login(p_phone text, p_pin text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_digits   text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_row      record;
  v_matched  boolean := false;
  v_attempts integer;
  v_wait     integer := public.auth_rate_take('pin_check', public.request_client_ip(), 30, interval '10 minutes');
begin
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait;
  end if;

  select p.id, p.pin, p.login_pin, p.pin_hash,
         p.pin_failed_attempts, p.pin_locked_until
    into v_row
    from public.profiles p
   where p.phone = any (array_remove(array[
           '+' || v_digits,
           v_digits,
           '0' || v_digits,
           ltrim(v_digits, '0')
         ], null))
   limit 1;

  if v_row.id is null then
    return null;
  end if;

  if v_row.pin_locked_until is not null and v_row.pin_locked_until > now() then
    raise exception 'PIN_LOCKED:%',
      ceil(extract(epoch from (v_row.pin_locked_until - now())))::integer;
  end if;

  if v_row.pin_hash is not null and v_row.pin_hash <> '' then
    v_matched := v_row.pin_hash = crypt(p_pin, v_row.pin_hash);
  end if;
  -- Legacy plaintext columns (rows written before the 0052 backfill).
  if not v_matched then
    v_matched :=
         (v_row.login_pin is not null and v_row.login_pin <> '' and v_row.login_pin = p_pin)
      or (v_row.pin       is not null and v_row.pin       <> '' and v_row.pin       = p_pin);
  end if;

  if v_matched then
    update public.profiles
       set pin_failed_attempts = 0,
           pin_locked_until    = null,
           pin_hash = case when pin_hash is null or pin_hash = ''
                           then crypt(p_pin, gen_salt('bf', 10))
                           else pin_hash end,
           pin       = null,
           login_pin = null
     where id = v_row.id;
    return v_row.id;
  end if;

  v_attempts := coalesce(v_row.pin_failed_attempts, 0) + 1;
  if v_attempts >= 5 then
    update public.profiles
       set pin_failed_attempts = 0,
           pin_locked_until    = now() + interval '15 minutes'
     where id = v_row.id;
  else
    update public.profiles
       set pin_failed_attempts = v_attempts
     where id = v_row.id;
  end if;
  return null;
end;
$$;

revoke all on function public.verify_pin_for_login(text, text) from public;
grant execute on function public.verify_pin_for_login(text, text) to anon, authenticated;

-- ---- clear_my_pin_lock: the signed-in owner lifts their own PIN lock (after
-- an SMS sign-in, which is what proves the number is theirs).
create or replace function public.clear_my_pin_lock()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authorized';
  end if;
  update public.profiles
     set pin_failed_attempts = 0,
         pin_locked_until    = null
   where id = auth.uid();
  return found;
end;
$$;

revoke all on function public.clear_my_pin_lock() from public, anon;
grant execute on function public.clear_my_pin_lock() to authenticated;

notify pgrst, 'reload schema';
