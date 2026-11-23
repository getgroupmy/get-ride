-- ============================================================================
-- 0431 — A partner row's id cannot be an account id.
--
-- partners.id is the partner record's own id. The app makes a new random one
-- for each application and the server stores the id it is sent. The account
-- that owns the record is partners.auth_user_id.
--
-- From this migration a partner row's id may not be the id of an account
-- (auth.users.id, which is profiles.id):
--
--   * Through the API with the apps' roles (anon, authenticated), a new row
--     whose id is an existing account's id is refused with
--     PARTNERS_ID_IS_ACCOUNT_ID, the signed-in user's own id included. So is
--     an update that changes a row's id to one.
--   * The id is not replaced by the server: the app, and older builds of it,
--     find the row again by the id they sent. A random id is not an account's
--     id, so an application made by the app goes through as before.
--   * The back office (an admin who may edit partners: the test the
--     "partners admin insert" and "partners admin update" policies make) and
--     the server's own writes (the service role, migrations, cron, the SQL
--     editor) are not checked.
--   * partners_guard_protected_columns (0185) is unchanged and answers first:
--     where it refuses a change of id, it still does, with its own error.
--   * Rows that already exist are not read or changed, and an update that
--     leaves a row's id as it is is not checked.
--
-- supabase/tests/partner_id_not_account_0431.sql covers it.
-- ============================================================================

-- Definer: the apps cannot read auth.users. Inside it current_user is the
-- owner, so the caller's role is read from the session, as the other definer
-- guards do.
create or replace function public.partners_guard_id()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- The server's own writes.
  if coalesce(current_setting('role', true), '') not in ('anon', 'authenticated') then
    return new;
  end if;
  -- An update that leaves the id as it is.
  if tg_op = 'UPDATE' then
    if new.id is not distinct from old.id then
      return new;
    end if;
  end if;
  if not exists (select 1 from auth.users u where u.id = new.id) then
    return new;
  end if;
  -- The back office.
  if public.caller_admin_can_write('partners') then
    return new;
  end if;
  raise exception 'PARTNERS_ID_IS_ACCOUNT_ID' using errcode = '42501',
    hint = 'A partner record has an id of its own: it cannot be the id of an account.';
end;
$$;
revoke execute on function public.partners_guard_id() from public, anon, authenticated;

-- "a_": with the table's other guards, ahead of the b_ and c_ rules (0245,
-- 0277), and after trg_partners_a_guard.
drop trigger if exists trg_partners_a_guard_id on public.partners;
create trigger trg_partners_a_guard_id
  before insert or update on public.partners
  for each row execute function public.partners_guard_id();

notify pgrst, 'reload schema';
