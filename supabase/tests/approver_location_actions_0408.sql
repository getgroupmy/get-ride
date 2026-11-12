-- ============================================================================
-- Regression test for migration 0408: Team Location per-person actions.
--   An approver with can_view_location, acting on a member they cover, passes
--   the widened gate on the God View locate functions (reveal_phone, ping,
--   live_status, trail) — without being a God View admin — and the audit row
--   is tagged detail.via = 'approver'. Acting on someone they do NOT cover
--   (here, themselves, via the conflict guard) is refused with 42501.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_location_actions_0408.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;

do $$
declare
  v_appr uuid := '00000000-0000-0000-0000-0000040801a1';  -- approver with the grant (not an admin)
  v_member uuid := '00000000-0000-0000-0000-0000040801b1'; -- a person they cover (scope 'all')
  v_res jsonb;
  v_via text;
begin
  insert into auth.users (id) values (v_appr),(v_member) on conflict do nothing;
  insert into public.profiles (id) values (v_appr),(v_member) on conflict (id) do nothing;
  insert into public.approvers (profile_id, scope, active, can_view_location)
    values (v_appr, 'all', true, true)
    on conflict (profile_id) do update set scope='all', active=true, can_view_location=true;

  perform pg_temp.as_user(v_appr);

  -- The approver is NOT a God View admin, yet the per-person gate lets them in.
  if public.god_view_may_see(v_member) then raise exception 'FAILED: test approver must not be a God View admin'; end if;
  if not public.approver_may_see_location(v_member) then raise exception 'FAILED: approver_may_see_location should be true'; end if;

  -- Each locate function runs (no 42501) for a covered member.
  v_res := public.god_view_reveal_phone(v_member);
  if not (v_res ? 'phone') then raise exception 'FAILED: reveal_phone shape %', v_res; end if;
  perform public.god_view_ping(v_member);
  v_res := public.god_view_live_status(v_member);
  if not (v_res ? 'session') then raise exception 'FAILED: live_status shape %', v_res; end if;
  perform public.god_view_trail(v_member, now() - interval '1 day', now());

  -- The reveal is audited and tagged as the approver path.
  select detail->>'via' into v_via from public.admin_audit_log
    where actor_id = v_appr and action = 'god_view.reveal_phone' order by created_at desc limit 1;
  if v_via is distinct from 'approver' then raise exception 'FAILED: audit via = % (want approver)', v_via; end if;

  -- Someone the approver does not cover (self, via the conflict guard) is refused.
  begin
    perform public.god_view_reveal_phone(v_appr);
    raise exception 'FAILED: a non-covered target should be refused';
  exception when sqlstate '42501' then null;
  end;
end $$;

rollback;
