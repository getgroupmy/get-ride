-- ============================================================================
-- 0151: PINs are only ever checked against their hash
--
-- Sign-in (verify_pin_for_login, 0137) still fell back to the legacy plain-
-- text columns profiles.pin / profiles.login_pin, from before the 0052 hash
-- backfill, and the phone lookup still counted them as "has a PIN". Every
-- live row has been hashed (none holds a plain-text PIN), so:
--
--   * verify_pin_for_login matches pin_hash only (rate limit and lockout as
--     in 0137, pgcrypto reached through 0138's search path);
--   * profile_phone_lookup reports has_pin from pin_hash only;
--   * the profiles trigger (hash_profile_pin, 0097) no longer turns a plain-
--     text PIN written straight onto a profile into a PIN: that let a signed-
--     in client set its PIN without set_login_pin's checks (six digits, the
--     duplicate-account device guard). A client now can't write any PIN
--     column (plain text, hash, failed attempts, lockout); only the PIN
--     functions, which run as the database owner, can;
--   * a check constraint keeps a plain-text PIN from ever being stored again
--     (set_login_pin already writes the hash and blanks both columns).
--
-- The columns stay, empty, so nothing that still names them breaks.
-- ============================================================================

-- ---- verify_pin_for_login: hash only --------------------------------------------
create or replace function public.verify_pin_for_login(p_phone text, p_pin text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
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

  select p.id, p.pin_hash, p.pin_failed_attempts, p.pin_locked_until
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

  if v_matched then
    update public.profiles
       set pin_failed_attempts = 0,
           pin_locked_until    = null
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

-- ---- profile_phone_lookup: a PIN is a hash ---------------------------------------
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
    select p.pin_hash, p.profile_status
    from public.profiles p, variants
    where p.phone = any(variants.v)
    limit 1
  )
  select
    exists(select 1 from match),
    coalesce((select m.pin_hash is not null and m.pin_hash <> '' from match m), false),
    coalesce((select lower(m.profile_status::text) = 'deleted' from match m), false);
end;
$$;

revoke all on function public.profile_phone_lookup(text) from public;
grant execute on function public.profile_phone_lookup(text) to anon, authenticated;

-- ---- Only the PIN functions write PIN columns ------------------------------------------
create or replace function public.hash_profile_pin()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- A client (the app's anon or signed-in role) sets a PIN through
  -- set_login_pin, never by writing the columns. The PIN functions run as
  -- the database owner and pass.
  if current_user in ('anon', 'authenticated') then
    if coalesce(new.pin, '') <> '' or coalesce(new.login_pin, '') <> ''
       or (tg_op = 'INSERT' and (new.pin_hash is not null or coalesce(new.pin_failed_attempts, 0) <> 0
                                 or new.pin_locked_until is not null))
       or (tg_op = 'UPDATE' and (new.pin_hash is distinct from old.pin_hash
                                 or new.pin_failed_attempts is distinct from old.pin_failed_attempts
                                 or new.pin_locked_until is distinct from old.pin_locked_until)) then
      raise exception 'use_set_login_pin' using errcode = '42501',
        hint = 'Set the PIN with set_login_pin.';
    end if;
  end if;
  -- Nothing plain-text is ever kept.
  new.pin := null;
  new.login_pin := null;
  return new;
end;
$$;

-- ---- No plain-text PIN is stored again ----------------------------------------------
-- Blank any stragglers first (hashing them is no longer possible without the
-- PIN itself being checked, and no live row has one).
update public.profiles set pin = null where pin = '';
update public.profiles set login_pin = null where login_pin = '';
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.profiles'::regclass and conname = 'profiles_no_plaintext_pin'
  ) then
    alter table public.profiles add constraint profiles_no_plaintext_pin
      check (pin is null and login_pin is null) not valid;
  end if;
end $$;
alter table public.profiles validate constraint profiles_no_plaintext_pin;

notify pgrst, 'reload schema';
