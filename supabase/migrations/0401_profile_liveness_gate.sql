-- ============================================================================
-- 0401 — Live-selfie (liveness) requirement, enforced like the rider ID gate.
--
-- A profile photo must be a freshly taken LIVE selfie that an approver has
-- verified. Two ways it becomes required:
--   * per country — compulsory where the admin turns it on (profile_selfie_gate,
--     same shape as rider_id_gate 0342), by the country the person is using the
--     service in (current_country, else nationality, else master); and
--   * on demand — an approver requests a new live selfie from any covered
--     member at any time (approver_request_member_liveness), which deletes the
--     current photo and starts the clock, so the member must retake it.
--
-- While required and not yet cleared, the person is blocked from booking (every
-- booking module, exactly where the ID gate blocks). They are cleared only by an
-- APPROVED identity_checks selfie taken since the requirement — the approver
-- verifies it in the Approvals → Liveness tab (a later slice). A pending selfie
-- does not clear them.
--
-- Inert by default: no country rule is on and no request exists, so the gate
-- returns false and the trigger never raises.
-- ============================================================================

-- ---- 0. Per-country rule: read + write (mirrors rider_id_gate) -------------------------------------
create or replace function public.profile_selfie_rule(p in jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('require', coalesce((p->>'require')::boolean, false));
$$;

create or replace function public.profile_selfie_config()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select jsonb_object_agg(e.key, public.profile_selfie_rule(e.value))
       from jsonb_each((select s.value from public.app_settings s where s.key = 'profile_selfie_gate')) e
      where jsonb_typeof(e.value) = 'object'),
    '{}'::jsonb);
$$;
revoke execute on function public.profile_selfie_config() from public, anon;
grant execute on function public.profile_selfie_config() to authenticated;

create or replace function public.set_profile_selfie_gate(p_country text, p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_all jsonb;
  v_key text := nullif(btrim(p_country), '');
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:set_profile_selfie_gate') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_key is null or jsonb_typeof(p_config) is distinct from 'object' then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  v_all := coalesce((select s.value from public.app_settings s where s.key = 'profile_selfie_gate'), '{}'::jsonb)
           || jsonb_build_object(v_key, public.profile_selfie_rule(p_config));
  insert into public.app_settings (key, value, updated_at) values ('profile_selfie_gate', v_all, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return public.profile_selfie_config();
end;
$$;
revoke execute on function public.set_profile_selfie_gate(text, jsonb) from public, anon;
grant execute on function public.set_profile_selfie_gate(text, jsonb) to authenticated;

insert into public.admin_table_pages (target, page) values ('rpc:set_profile_selfie_gate', 'admin-settings-site')
on conflict do nothing;

-- ---- 1. When a fresh live selfie was last demanded of this person ----------------------------------
alter table public.profiles
  add column if not exists selfie_required_at timestamptz;

-- ---- 2. An approver requests a new live selfie from a covered member -------------------------------
-- Deletes the current profile photo (so the stale one can't stand in) and marks
-- the requirement from now, so the member must retake and be re-verified.
create or replace function public.approver_request_member_liveness(p_member uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a    public.approvers;
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_edit_profile then
    raise exception 'not_allowed';
  end if;
  if p_member is null then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  if not public.approver_covers(p_member) then
    raise exception 'out_of_scope';
  end if;

  update public.profiles
     set avatar_url = null,
         profile_image = null,
         selfie_required_at = now(),
         updated_at = now()
   where id = p_member;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.request_liveness', p_member, jsonb_build_object('at', now()));

  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.approver_request_member_liveness(uuid) from public, anon;
grant execute on function public.approver_request_member_liveness(uuid) to authenticated;

-- ---- 3. The gate: does this person still owe a verified live selfie? -------------------------------
create or replace function public.profile_liveness_block(p_user uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_prof public.profiles;
  v_cfg  jsonb := public.profile_selfie_config();
  v_rule jsonb;
  v_required boolean;
begin
  if p_user is null then
    return false;
  end if;
  select * into v_prof from public.profiles where id = p_user;
  if not found then
    return false;
  end if;
  -- Required where the country they are using the service in requires it, or an
  -- approver has asked them for a fresh one.
  v_rule := coalesce(v_cfg -> nullif(btrim(coalesce(v_prof.current_country, '')), ''),
                     v_cfg -> v_prof.nationality,
                     v_cfg -> 'master');
  v_required := coalesce((v_rule->>'require')::boolean, false) or v_prof.selfie_required_at is not null;
  if not v_required then
    return false;
  end if;
  -- Cleared by an APPROVED live selfie taken since the requirement (a pending
  -- one does not clear them — the approver verifies it first).
  if exists (
       select 1 from public.identity_checks ic
        where ic.user_id = p_user and ic.kind = 'selfie' and ic.status = 'Approved'
          and coalesce(ic.reviewed_at, ic.created_at)
              >= coalesce(v_prof.selfie_required_at, '-infinity'::timestamptz)) then
    return false;
  end if;
  return true;
end;
$$;
revoke execute on function public.profile_liveness_block(uuid) from public, anon;
grant execute on function public.profile_liveness_block(uuid) to authenticated;

-- ---- 4. Block booking for a rider who owes a live selfie (every booking module) --------------------
create or replace function public.profile_liveness_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.rider_id is not null and new.rider_id = auth.uid() and public.profile_liveness_block(new.rider_id) then
    raise exception 'LIVENESS_REQUIRED' using errcode = '42501',
      hint = 'Take a new live selfie to continue.';
  end if;
  return new;
end;
$$;
revoke execute on function public.profile_liveness_guard() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['ride_requests', 'scheduled_rides', 'hire_bookings', 'mygig_bookings', 'c2c_bookings', 'freight', 'courier']
  loop
    if to_regclass('public.' || t) is not null
       and exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = t and column_name = 'rider_id') then
      execute format('drop trigger if exists %I on public.%I', 'profile_liveness_' || t, t);
      execute format(
        'create trigger %I before insert on public.%I for each row execute function public.profile_liveness_guard()',
        'profile_liveness_' || t, t);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
