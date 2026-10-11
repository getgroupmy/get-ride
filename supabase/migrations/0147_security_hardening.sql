-- ============================================================================
-- 0147: security hardening (audit of 11 Oct 2026, the parts that need no app
-- change). Storage, the route proxy and the sign-in SMS limits follow in
-- their own migrations.
--
--   1. wallets / wallet_transactions: readable by their owner and admins only
--      (both were `using (true)`: every balance and ledger line was public).
--      Clients never wrote them directly since 0066; the write grants go too.
--   2. Realtime sent the whole old row of a deleted record to every
--      subscriber (Realtime does not apply RLS to deletes, and these tables
--      were REPLICA IDENTITY FULL). Every table back to DEFAULT: a delete
--      now carries only the primary key. Neither app reads the old row.
--      The tables stay published: the admin panel follows them live.
--   3. admin_access_bootstrap: no longer callable by clients (any account
--      became the first admin while admin_access was empty).
--   4. TRUNCATE (which RLS does not cover) revoked from client roles, for
--      every table now and every table made later.
--   5. anon writes revoked on profiles, partners and ride_requests (every
--      write policy there already needs a signed-in caller).
--      user_sessions / user_location_history keep their signed-out insert.
--   6. documents_ok: only an admin or the server sets it (a driver could
--      mark their own documents checked).
--   7. fare_ai_responses: no client insert (the proxy writes as service).
--   8. is_admin / admin_can_read / admin_can_edit answer only about the
--      caller (anyone could ask about any account: an admin finder). They
--      stay executable, because RLS policies evaluated for every caller use
--      them. device_guard_config and commission_resolve_rate: not for
--      anonymous callers. push_unregister_token keeps anon: it runs on
--      sign-out, after the session is gone.
--   9. currency_symbol: a fixed search_path.
-- ============================================================================

-- ---- 1. Wallets -----------------------------------------------------------------
drop policy if exists "wallets read" on public.wallets;
drop policy if exists "wallets own read" on public.wallets;
create policy "wallets own read" on public.wallets
  for select using (user_id = auth.uid() or public.caller_is_admin());

drop policy if exists "wallet_transactions read" on public.wallet_transactions;
drop policy if exists "wallet_transactions own read" on public.wallet_transactions;
create policy "wallet_transactions own read" on public.wallet_transactions
  for select using (user_id = auth.uid() or public.caller_is_admin());

revoke insert, update, delete on public.wallets, public.wallet_transactions from anon, authenticated;

-- ---- 2. Deleted rows are not broadcast whole -------------------------------------
do $$
declare
  r record;
begin
  for r in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and c.relreplident = 'f'
  loop
    execute format('alter table public.%I replica identity default', r.relname);
  end loop;
end $$;

-- ---- 3. No self-made first admin -------------------------------------------------
revoke execute on function public.admin_access_bootstrap() from public, anon, authenticated;

-- ---- 4. No TRUNCATE for clients ----------------------------------------------------
do $$
declare
  r record;
begin
  for r in select tablename from pg_tables where schemaname = 'public' loop
    execute format('revoke truncate on public.%I from anon, authenticated', r.tablename);
  end loop;
end $$;
alter default privileges in schema public revoke truncate on tables from anon, authenticated;

-- ---- 5. Signed-out callers don't write accounts or rides ---------------------------
revoke insert, update, delete on public.profiles, public.partners, public.ride_requests from anon;
revoke update, delete on public.user_sessions, public.user_location_history from anon;

-- ---- 6. documents_ok is the admin's ----------------------------------------------------
create or replace function public.partners_guard_protected_columns()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_col text;
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status is distinct from 'unapproved' then
      raise exception 'PARTNERS_PROTECTED_COLUMN:status' using errcode = '42501',
        hint = 'A new partner starts unapproved; an administrator approves it.';
    end if;
    if new.permit is not null and new.permit::text not in ('none', 'pending') then
      raise exception 'PARTNERS_PROTECTED_COLUMN:permit' using errcode = '42501';
    end if;
    if coalesce(new.rating, 0) <> 0 then
      raise exception 'PARTNERS_PROTECTED_COLUMN:rating' using errcode = '42501';
    end if;
    if coalesce(new.total_rides, 0) <> 0 then
      raise exception 'PARTNERS_PROTECTED_COLUMN:total_rides' using errcode = '42501';
    end if;
    if new.status_note is not null or new.resubmitted_at is not null then
      raise exception 'PARTNERS_PROTECTED_COLUMN:status_note' using errcode = '42501';
    end if;
    if coalesce((to_jsonb(new) ->> 'documents_ok')::boolean, false) then
      raise exception 'PARTNERS_PROTECTED_COLUMN:documents_ok' using errcode = '42501';
    end if;
    return new;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array array[
    'id', 'auth_user_id', 'display_id', 'status', 'permit', 'rating',
    'total_rides', 'joined_at', 'created_at', 'status_note', 'resubmitted_at', 'documents_ok'
  ] loop
    if v_old -> v_col is distinct from v_new -> v_col then
      raise exception 'PARTNERS_PROTECTED_COLUMN:%', v_col using errcode = '42501',
        hint = 'This field can only be changed by an administrator or by the server.';
    end if;
  end loop;
  return new;
end;
$$;

create or replace function public.vehicle_guard_protected_columns()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_col text;
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status is distinct from 'unapproved' then
      raise exception 'VEHICLE_PROTECTED_COLUMN:status' using errcode = '42501',
        hint = 'A new vehicle starts unapproved; an administrator approves it.';
    end if;
    if new.permit is not null and new.permit::text not in ('none', 'pending') then
      raise exception 'VEHICLE_PROTECTED_COLUMN:permit' using errcode = '42501';
    end if;
    if coalesce((to_jsonb(new) ->> 'documents_ok')::boolean, false) then
      raise exception 'VEHICLE_PROTECTED_COLUMN:documents_ok' using errcode = '42501';
    end if;
    return new;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array array['id', 'display_id', 'status', 'permit', 'joined_at', 'created_at', 'documents_ok'] loop
    if v_old -> v_col is distinct from v_new -> v_col then
      raise exception 'VEHICLE_PROTECTED_COLUMN:%', v_col using errcode = '42501',
        hint = 'This field can only be changed by an administrator or by the server.';
    end if;
  end loop;

  -- Ownership may only be taken over while unset, and only by the caller.
  if new.auth_user_id is distinct from old.auth_user_id
     and not (old.auth_user_id is null and new.auth_user_id = auth.uid()) then
    raise exception 'VEHICLE_PROTECTED_COLUMN:auth_user_id' using errcode = '42501';
  end if;
  if new.owner_partner_id is distinct from old.owner_partner_id
     and not (
       old.owner_partner_id is null
       and exists (
         select 1 from public.partners p
          where p.id = new.owner_partner_id and p.auth_user_id = auth.uid()
       )
     ) then
    raise exception 'VEHICLE_PROTECTED_COLUMN:owner_partner_id' using errcode = '42501';
  end if;
  return new;
end;
$$;

-- ---- 7. The proxy logs AI responses, not clients ---------------------------------------
drop policy if exists "fare_ai_responses insert" on public.fare_ai_responses;

-- ---- 8. Admin checks answer only about the caller --------------------------------------
create or replace function public.is_admin(p_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select (p_profile = auth.uid() or public.caller_is_admin())
     and exists (select 1 from public.admin_access where profile_id = p_profile);
$$;

create or replace function public.admin_can_read(p_profile uuid, p_page text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select (p_profile = auth.uid() or public.caller_is_admin())
     and exists (
       select 1 from public.admin_access
        where profile_id = p_profile
          and (page = p_page or page = '*')
     );
$$;

create or replace function public.admin_can_edit(p_profile uuid, p_page text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select (p_profile = auth.uid() or public.caller_is_admin())
     and exists (
       select 1 from public.admin_access
        where profile_id = p_profile
          and (page = p_page or page = '*')
          and access_level = 'edit'
     );
$$;

revoke execute on function public.device_guard_config() from public, anon;
grant execute on function public.device_guard_config() to authenticated, service_role;
revoke execute on function public.commission_resolve_rate(uuid, text, text, text, text) from public, anon;
grant execute on function public.commission_resolve_rate(uuid, text, text, text, text) to authenticated, service_role;

-- ---- 9. currency_symbol --------------------------------------------------------------
alter function public.currency_symbol(text) set search_path = public;

notify pgrst, 'reload schema';
