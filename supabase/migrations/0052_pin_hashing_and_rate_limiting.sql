-- ============================================================================
-- 0052 — PIN hashing + brute-force rate limiting
--
-- Problem: profiles.pin / profiles.login_pin store the user's 6-digit sign-in
-- PIN in plaintext, and verify_pin_for_login compares plaintext with no
-- attempt limit — a 6-digit PIN has only 1,000,000 combinations, so anyone
-- who can read the table (or script the RPC) can recover or brute-force it.
--
-- Solution:
--   * New profiles.pin_hash column stores a bcrypt hash (pgcrypto crypt()).
--   * A BEFORE trigger transparently hashes any plaintext PIN written by
--     older app versions, so plaintext never lands in the row again.
--   * set_login_pin / clear_login_pin SECURITY DEFINER RPCs are the new
--     write path for the client (scoped to auth.uid()).
--   * verify_pin_for_login now checks the hash, counts consecutive failures,
--     and locks PIN verification for 15 minutes after 5 wrong attempts
--     (raises 'PIN_LOCKED:<seconds-remaining>'). On a successful legacy
--     plaintext match it upgrades the row to a hash in place.
--   * profile_phone_lookup counts pin_hash as "has a PIN".
--   * Existing plaintext PINs are hashed in place and the plaintext cleared.
--
-- Note for old app builds still in the field: they can no longer read the
-- PIN back from profiles (it is gone), but their login path is unaffected —
-- sign-in goes through the Supabase Auth password / verify_pin_for_login,
-- both of which keep working. Their "forgot PIN" reset only nulls the
-- (already-null) plaintext columns; users on old builds who forgot their
-- PIN should update the app or be reset by an operator.
-- ============================================================================

create extension if not exists pgcrypto;

alter table public.profiles add column if not exists pin_hash text;
alter table public.profiles add column if not exists pin_failed_attempts integer not null default 0;
alter table public.profiles add column if not exists pin_locked_until timestamptz;

-- ---------------------------------------------------------------------------
-- Hash-on-write trigger: any plaintext PIN written to pin/login_pin (e.g. by
-- an older app version) is converted to a bcrypt hash before the row lands.
-- ---------------------------------------------------------------------------
create or replace function public.hash_profile_pin()
returns trigger
language plpgsql
as $$
begin
  -- Prefer login_pin (canonical) over the legacy pin column.
  if new.login_pin is not null and new.login_pin <> '' then
    new.pin_hash := crypt(new.login_pin, gen_salt('bf', 10));
    new.pin_failed_attempts := 0;
    new.pin_locked_until := null;
  elsif new.pin is not null and new.pin <> '' then
    new.pin_hash := crypt(new.pin, gen_salt('bf', 10));
    new.pin_failed_attempts := 0;
    new.pin_locked_until := null;
  end if;
  -- Plaintext never persists.
  new.pin := null;
  new.login_pin := null;
  return new;
end;
$$;

drop trigger if exists trg_profiles_hash_pin on public.profiles;
create trigger trg_profiles_hash_pin
  before insert or update on public.profiles
  for each row execute function public.hash_profile_pin();

-- ---------------------------------------------------------------------------
-- set_login_pin(p_pin) — the client's write path for setting/changing the
-- PIN. Requires an authenticated session; always stores a bcrypt hash and
-- resets the failed-attempt counter.
-- ---------------------------------------------------------------------------
create or replace function public.set_login_pin(p_pin text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'set_login_pin requires an authenticated session';
  end if;
  if p_pin !~ '^\d{6}$' then
    raise exception 'PIN must be exactly 6 digits';
  end if;
  update public.profiles
  set pin_hash            = crypt(p_pin, gen_salt('bf', 10)),
      pin                 = null,
      login_pin           = null,
      pin_failed_attempts = 0,
      pin_locked_until    = null
  where id = v_uid;
  if not found then
    -- Profile row missing (signup trigger raced/failed) — create it.
    insert into public.profiles (id, pin_hash)
    values (v_uid, crypt(p_pin, gen_salt('bf', 10)))
    on conflict (id) do update set
      pin_hash            = excluded.pin_hash,
      pin                 = null,
      login_pin           = null,
      pin_failed_attempts = 0,
      pin_locked_until    = null;
  end if;
  return true;
end;
$$;

revoke all on function public.set_login_pin(text) from public;
grant execute on function public.set_login_pin(text) to authenticated;

-- ---------------------------------------------------------------------------
-- clear_login_pin() — forgot-PIN reset for the signed-in user.
-- ---------------------------------------------------------------------------
create or replace function public.clear_login_pin()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'clear_login_pin requires an authenticated session';
  end if;
  update public.profiles
  set pin_hash            = null,
      pin                 = null,
      login_pin           = null,
      pin_failed_attempts = 0,
      pin_locked_until    = null
  where id = v_uid;
  return found;
end;
$$;

revoke all on function public.clear_login_pin() from public;
grant execute on function public.clear_login_pin() to authenticated;

-- ---------------------------------------------------------------------------
-- verify_pin_for_login(p_phone, p_pin) — same signature as 0045 (returns the
-- user's UUID on match, null on mismatch) but now hash-based and rate
-- limited: 5 consecutive failures lock verification for 15 minutes and the
-- function raises 'PIN_LOCKED:<seconds-remaining>' while locked.
-- ---------------------------------------------------------------------------
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
begin
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
  -- Legacy plaintext columns (rows written before this migration's backfill).
  if not v_matched then
    v_matched :=
         (v_row.login_pin is not null and v_row.login_pin <> '' and v_row.login_pin = p_pin)
      or (v_row.pin       is not null and v_row.pin       <> '' and v_row.pin       = p_pin);
  end if;

  if v_matched then
    update public.profiles
       set pin_failed_attempts = 0,
           pin_locked_until    = null,
           -- Opportunistic upgrade: hash any remaining legacy plaintext PIN.
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

-- ---------------------------------------------------------------------------
-- profile_phone_lookup — has_pin must also count the new pin_hash column.
-- ---------------------------------------------------------------------------
create or replace function public.profile_phone_lookup(p_phone text)
returns table (
  has_profile boolean,
  has_pin     boolean,
  is_deleted  boolean
)
language sql
security definer
set search_path = public
stable
as $$
  with digits as (
    select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') as d
  ),
  variants as (
    select array_remove(array[
      '+' || d,
      d,
      '0' || d,
      ltrim(d, '0')
    ], null) as v
    from digits
  ),
  match as (
    select p.pin, p.login_pin, p.pin_hash, p.profile_status
    from public.profiles p, variants
    where p.phone = any(variants.v)
    limit 1
  )
  select
    exists(select 1 from match)                                    as has_profile,
    coalesce((select (pin is not null and pin <> '')
                  or (login_pin is not null and login_pin <> '')
                  or (pin_hash is not null and pin_hash <> '')
              from match), false)                                  as has_pin,
    coalesce((select lower(profile_status::text) = 'deleted'
              from match), false)                                  as is_deleted;
$$;

revoke all on function public.profile_phone_lookup(text) from public;
grant execute on function public.profile_phone_lookup(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Backfill: hash every existing plaintext PIN and clear the plaintext.
-- Setting login_pin to the effective plaintext value fires the hash-on-write
-- trigger, which does the crypt() + cleanup per row.
-- ---------------------------------------------------------------------------
update public.profiles
   set login_pin = coalesce(nullif(login_pin, ''), nullif(pin, ''))
 where (pin_hash is null or pin_hash = '')
   and coalesce(nullif(login_pin, ''), nullif(pin, '')) is not null;

notify pgrst, 'reload schema';
