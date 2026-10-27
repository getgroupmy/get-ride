-- ============================================================================
-- 0303 — One account per ID number (docs/KIV.md M8).
--
-- Version 20261027200000 (0303_one_account_per_id). Re-runnable: the function
-- "create or replace", the trigger dropped first, the index "if not exists".
--
-- Two accounts could register the same MyKad (or passport) number; since
-- 0299 the partner review flags it ("Same ID as another account"). Now the
-- second one is refused:
--
-- 1. A trigger on profiles refuses an ID number (ic) that another live
--    account already has: ID_NUMBER_TAKEN (errcode 23505), with the plain
--    message in the hint, which the app shows as "This ID number is already
--    registered" with Contact support and OK. Numbers are compared as
--    reg_id_key (0288: letters and digits only, upper case), so
--    900101-14-5678 and 900101145678 are the same. A live account is one
--    not deleted (deleted_at is null and profile_status is not 'Deleted'),
--    as admin_same_ic_accounts (0299) counts them; a deleted account's
--    number can be registered again (final deletion clears ic, 0194).
--    Keys under 6 characters are not compared (as 0299). It fires on every
--    write of ic, from the app, an admin's edit or the partner sync (0277),
--    and when an account is brought back from deleted.
-- 2. A partial unique index on reg_id_key(ic) over the same rows is the
--    guarantee, also for two registrations at the same moment. Built only
--    when no number is on more than one live account; otherwise this
--    migration stops and says how many to fix first.
--
-- The placeholder number 999999999999 is an ordinary value: one account has
-- it, and a second is refused like any other.
-- ============================================================================

-- ---- 1. ID_NUMBER_TAKEN -------------------------------------------------------------------------------
create or replace function public.profiles_ic_taken()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text := public.reg_id_key(new.ic);
begin
  if length(v_key) < 6 or new.deleted_at is not null or new.profile_status = 'Deleted' then
    return new;
  end if;
  if exists (
    select 1
      from public.profiles pr
     where pr.id <> new.id
       and pr.deleted_at is null
       and pr.profile_status <> 'Deleted'
       and length(public.reg_id_key(pr.ic)) >= 6
       and public.reg_id_key(pr.ic) = v_key
  ) then
    raise exception 'ID_NUMBER_TAKEN'
      using errcode = '23505',
            hint = 'Another GET.ride account uses this ID number. Sign in to that account, or contact support if it isn''t yours.';
  end if;
  return new;
end;
$$;
revoke execute on function public.profiles_ic_taken() from public, anon, authenticated;

drop trigger if exists trg_profiles_ic_taken on public.profiles;
create trigger trg_profiles_ic_taken
  before insert or update of ic, deleted_at, profile_status on public.profiles
  for each row execute function public.profiles_ic_taken();

-- ---- 2. The unique index ---------------------------------------------------------------------------
do $$
declare
  v_dupes int;
begin
  if to_regclass('public.profiles_ic_key_uidx') is not null then
    return;
  end if;
  select count(*) into v_dupes
    from (select public.reg_id_key(ic)
            from public.profiles
           where deleted_at is null
             and profile_status <> 'Deleted'
             and length(public.reg_id_key(ic)) >= 6
           group by 1
          having count(*) > 1) d;
  if v_dupes > 0 then
    raise exception 'M8: % ID numbers are on more than one live account; fix them before running 0303', v_dupes;
  end if;
end $$;

create unique index if not exists profiles_ic_key_uidx
  on public.profiles (public.reg_id_key(ic))
  where deleted_at is null
    and profile_status <> 'Deleted'
    and length(public.reg_id_key(ic)) >= 6;

notify pgrst, 'reload schema';
