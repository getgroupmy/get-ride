-- ============================================================================
-- 0277 — One person, one set of details: the user profile is the master copy
-- of the partner record's name, phone, email, IC, address and photo, and a
-- change on either side shows on the other.
--
-- Re-runnable: functions are "create or replace", triggers are dropped first.
--
-- Why: the partner row copied these from the profile once, at sign-up, and
-- nothing kept them in step afterwards: a user who changed their name or
-- photo still showed the old one as a partner (and to riders), and an admin
-- edit on the Partner page never reached the User page.
--
-- 1. partners BEFORE INSERT: the blanks take the profile's values (the app
--    already copies the profile into a new row). BEFORE UPDATE when
--    auth_user_id is set (claim_partner_by_phone, an admin-added row): the
--    profile's values win, where it has one. The profile is the master.
-- 2. profiles AFTER UPDATE of the six columns: the same values go onto the
--    user's partner row(s). name and phone, required on partners, are never
--    blanked there.
-- 3. partners AFTER INSERT / UPDATE of the six columns: back onto the
--    profile. On insert only the profile's blanks are filled, and never the
--    phone (the sign-in number). Each side only writes what differs, so the
--    two triggers stop after one round.
-- 4. The locks stay as they were:
--      - phone: on profiles it was already the server's and the admin's
--        (profiles_guard_protected_columns); now on partners too, so a
--        partner row can't be used to change someone's sign-in number;
--      - an approved partner's name, IC and photo (0185): now also refused
--        on the profile, with the same "changed by support" hint. Admins and
--        the server change them; the change shows on both.
-- 5. Backfill: the partner rows take the profiles' values; the profiles'
--    blanks are filled from their partner row.
-- ============================================================================

-- 1. + 3. On the partner row --------------------------------------------------

create or replace function public.partners_take_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.profiles%rowtype;
begin
  if new.auth_user_id is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.auth_user_id is not distinct from old.auth_user_id then
    return new;
  end if;
  select * into p from public.profiles where id = new.auth_user_id;
  if not found then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.name := coalesce(nullif(btrim(new.name), ''), nullif(btrim(p.name), ''), new.name);
    new.phone := coalesce(nullif(btrim(new.phone), ''), nullif(btrim(p.phone), ''), new.phone);
    new.email := coalesce(new.email, p.email);
    new.ic := coalesce(new.ic, p.ic);
    new.address := coalesce(new.address, p.address);
    new.avatar_url := coalesce(new.avatar_url, p.avatar_url);
    return new;
  end if;
  new.name := coalesce(nullif(btrim(p.name), ''), new.name);
  new.phone := coalesce(nullif(btrim(p.phone), ''), new.phone);
  new.email := coalesce(p.email, new.email);
  new.ic := coalesce(p.ic, new.ic);
  new.address := coalesce(p.address, new.address);
  new.avatar_url := coalesce(p.avatar_url, new.avatar_url);
  return new;
end;
$$;

drop trigger if exists trg_partners_c_take_profile on public.partners;
create trigger trg_partners_c_take_profile
  before insert or update of auth_user_id on public.partners
  for each row execute function public.partners_take_profile();

-- A partner row can't change anyone's sign-in number: like profiles.phone,
-- it is the server's and the admin's.
create or replace function public.partners_guard_phone()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if new.phone is distinct from old.phone then
    raise exception 'PARTNERS_PROTECTED_COLUMN:phone' using errcode = '42501',
      hint = 'The phone number is changed in Account settings, with an SMS check.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_partners_a_guard_phone on public.partners;
create trigger trg_partners_a_guard_phone
  before update of phone on public.partners
  for each row execute function public.partners_guard_phone();

create or replace function public.partners_sync_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.auth_user_id is null then
    return null;
  end if;
  if tg_op = 'INSERT' then
    update public.profiles pr set
      name = coalesce(pr.name, new.name),
      email = coalesce(pr.email, new.email),
      ic = coalesce(pr.ic, new.ic),
      address = coalesce(pr.address, new.address),
      avatar_url = coalesce(pr.avatar_url, new.avatar_url),
      updated_at = now()
    where pr.id = new.auth_user_id
      and ((pr.name is null and new.name is not null)
        or (pr.email is null and new.email is not null)
        or (pr.ic is null and new.ic is not null)
        or (pr.address is null and new.address is not null)
        or (pr.avatar_url is null and new.avatar_url is not null));
    return null;
  end if;
  update public.profiles pr set
    name = new.name,
    phone = new.phone,
    email = new.email,
    ic = new.ic,
    address = new.address,
    avatar_url = new.avatar_url,
    updated_at = now()
  where pr.id = new.auth_user_id
    and (pr.name is distinct from new.name
      or pr.phone is distinct from new.phone
      or pr.email is distinct from new.email
      or pr.ic is distinct from new.ic
      or pr.address is distinct from new.address
      or pr.avatar_url is distinct from new.avatar_url);
  return null;
end;
$$;

drop trigger if exists trg_partners_z_sync_profile on public.partners;
create trigger trg_partners_z_sync_profile
  after insert or update of name, phone, email, ic, address, avatar_url, auth_user_id on public.partners
  for each row execute function public.partners_sync_profile();

-- 2. + 4. On the profile ------------------------------------------------------

-- An approved partner's name, IC and photo are support's to change (0185),
-- on the profile as on the partner row.
create or replace function public.profiles_guard_partner_identity()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_col text;
  v_old jsonb;
  v_new jsonb;
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if not exists (
    select 1 from public.partners pa
     where pa.auth_user_id = new.id
       and (pa.status::text = 'approved' or pa.status::text like 'permit-%')
  ) then
    return new;
  end if;
  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array array['name', 'ic', 'avatar_url'] loop
    if v_old -> v_col is distinct from v_new -> v_col then
      raise exception 'PROFILE_PROTECTED_COLUMN:%', v_col using errcode = '42501',
        hint = 'An approved partner''s name, IC and photo are changed by support.';
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_profiles_c_partner_identity on public.profiles;
create trigger trg_profiles_c_partner_identity
  before update of name, ic, avatar_url on public.profiles
  for each row execute function public.profiles_guard_partner_identity();

create or replace function public.profiles_sync_partner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := coalesce(nullif(btrim(new.name), ''), null);
  v_phone text := coalesce(nullif(btrim(new.phone), ''), null);
begin
  update public.partners pa set
    name = coalesce(v_name, pa.name),
    phone = coalesce(v_phone, pa.phone),
    email = new.email,
    ic = new.ic,
    address = new.address,
    avatar_url = new.avatar_url
  where pa.auth_user_id = new.id
    and ((v_name is not null and pa.name is distinct from v_name)
      or (v_phone is not null and pa.phone is distinct from v_phone)
      or pa.email is distinct from new.email
      or pa.ic is distinct from new.ic
      or pa.address is distinct from new.address
      or pa.avatar_url is distinct from new.avatar_url);
  return null;
end;
$$;

drop trigger if exists trg_profiles_z_sync_partner on public.profiles;
create trigger trg_profiles_z_sync_partner
  after update of name, phone, email, ic, address, avatar_url on public.profiles
  for each row execute function public.profiles_sync_partner();

-- Trigger functions only: nobody calls them directly.
revoke execute on function public.partners_take_profile() from public, anon, authenticated;
revoke execute on function public.partners_guard_phone() from public, anon, authenticated;
revoke execute on function public.partners_sync_profile() from public, anon, authenticated;
revoke execute on function public.profiles_guard_partner_identity() from public, anon, authenticated;
revoke execute on function public.profiles_sync_partner() from public, anon, authenticated;

-- 5. Backfill -------------------------------------------------------------------

update public.partners pa set
  name = coalesce(nullif(btrim(pr.name), ''), pa.name),
  phone = coalesce(nullif(btrim(pr.phone), ''), pa.phone),
  email = coalesce(pr.email, pa.email),
  ic = coalesce(pr.ic, pa.ic),
  address = coalesce(pr.address, pa.address),
  avatar_url = coalesce(pr.avatar_url, pa.avatar_url)
from public.profiles pr
where pr.id = pa.auth_user_id
  and ((nullif(btrim(pr.name), '') is not null and pa.name is distinct from btrim(pr.name))
    or (nullif(btrim(pr.phone), '') is not null and pa.phone is distinct from btrim(pr.phone))
    or (pr.email is not null and pa.email is distinct from pr.email)
    or (pr.ic is not null and pa.ic is distinct from pr.ic)
    or (pr.address is not null and pa.address is distinct from pr.address)
    or (pr.avatar_url is not null and pa.avatar_url is distinct from pr.avatar_url));
