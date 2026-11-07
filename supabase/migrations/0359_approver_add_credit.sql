-- ============================================================================
-- 0359: Approver — add credit to a covered member (My Team Phase 2a).
--
-- A new dedicated grant flag, can_credit, lets an approver top up the GET.wallet
-- of a member their grant reaches, paid from the approver's OWN GET.wallet. The
-- approver confirms with their sign-in PIN; the member gets a push. The move is
-- money, so it is guarded like the wallet RPCs: owner-scoped, PIN-checked,
-- amount-bounded, balance-checked (the approver can never overdraw — GET.wallet
-- stays >= 0), idempotent (a client request id, like the wallet _once twins,
-- so a retried/duplicated tap never charges twice) and audited.
--
--   approver_add_credit(member, amount, pin, request_id)  the transfer.
--   approver_member_wallet(member)                        the member's GET.wallet
--                                                         balance, for display.
--
-- Both reuse approver_covers (0350), so scope and the conflict guard are the
-- server's decision, never the app's. can_credit is OFF by default and set on
-- the admin Approvers screen, separate from the document-review permissions.
-- ============================================================================

-- ---- 0. The new grant flag ------------------------------------------------------------------------
alter table public.approvers
  add column if not exists can_credit boolean not null default false;

-- approver_config (0349) — carry can_credit through the admin config.
create or replace function public.approver_config(p jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'active',        coalesce((p->>'active')::boolean, true),
    'can_approve',   coalesce((p->>'can_approve')::boolean, false),
    'can_upload',    coalesce((p->>'can_upload')::boolean, false),
    'can_delete',    coalesce((p->>'can_delete')::boolean, false),
    'delete_hard',   coalesce((p->>'delete_hard')::boolean, false),
    'can_credit',    coalesce((p->>'can_credit')::boolean, false),
    'scope',         case when p->>'scope' in ('all', 'region', 'referral') then p->>'scope' else 'referral' end,
    'use_own_region', coalesce((p->>'use_own_region')::boolean, true),
    'regions',       case when jsonb_typeof(p->'regions') = 'array' then p->'regions' else '[]'::jsonb end,
    'doc_types',     case when jsonb_typeof(p->'doc_types') = 'array' then p->'doc_types' else '[]'::jsonb end,
    'conflict_guard', coalesce((p->>'conflict_guard')::boolean, true),
    'ends_at',       case when (p->>'ends_at') ~ '^\d{4}-\d{2}-\d{2}' then (p->>'ends_at') else null end,
    'note',          nullif(left(btrim(coalesce(p->>'note', '')), 300), ''));
$$;

-- approver_self (0349) — expose can_credit to the app.
create or replace function public.approver_self()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
           'can_approve', a.can_approve, 'can_upload', a.can_upload,
           'can_delete', a.can_delete, 'delete_hard', a.delete_hard,
           'can_credit', a.can_credit,
           'scope', a.scope, 'doc_types', to_jsonb(a.doc_types))
    from public.approvers a
   where a.profile_id = auth.uid()
     and a.active and (a.ends_at is null or a.ends_at > now());
$$;
revoke execute on function public.approver_self() from public, anon;
grant execute on function public.approver_self() to authenticated;

-- admin_set_approver (0349) — write can_credit with the rest of the grant.
create or replace function public.admin_set_approver(p_user uuid, p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg jsonb;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:admin_set_approver') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_user is null or not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  v_cfg := public.approver_config(coalesce(p_config, '{}'::jsonb));

  insert into public.approvers as a (profile_id, active, can_approve, can_upload, can_delete, delete_hard,
                                     can_credit, scope, use_own_region, regions, doc_types, conflict_guard,
                                     ends_at, note, granted_by)
  values (p_user,
          (v_cfg->>'active')::boolean, (v_cfg->>'can_approve')::boolean, (v_cfg->>'can_upload')::boolean,
          (v_cfg->>'can_delete')::boolean, (v_cfg->>'delete_hard')::boolean, (v_cfg->>'can_credit')::boolean,
          v_cfg->>'scope', (v_cfg->>'use_own_region')::boolean, v_cfg->'regions',
          array(select jsonb_array_elements_text(v_cfg->'doc_types')), (v_cfg->>'conflict_guard')::boolean,
          nullif(v_cfg->>'ends_at', '')::timestamptz, v_cfg->>'note', auth.uid())
  on conflict (profile_id) do update set
    active = excluded.active, can_approve = excluded.can_approve, can_upload = excluded.can_upload,
    can_delete = excluded.can_delete, delete_hard = excluded.delete_hard, can_credit = excluded.can_credit,
    scope = excluded.scope, use_own_region = excluded.use_own_region, regions = excluded.regions,
    doc_types = excluded.doc_types, conflict_guard = excluded.conflict_guard, ends_at = excluded.ends_at,
    note = excluded.note, granted_by = excluded.granted_by, updated_at = now();

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'approver.set', p_user, v_cfg);
  return v_cfg;
end;
$$;
revoke execute on function public.admin_set_approver(uuid, jsonb) from public, anon;
grant execute on function public.admin_set_approver(uuid, jsonb) to authenticated;

-- ---- 1. The member's GET.wallet balance, for display ----------------------------------------------
create or replace function public.approver_member_wallet(p_member uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or p_member is null or not public.approver_covers(p_member) then
    return null;
  end if;
  return coalesce((select balance from public.wallets
                    where user_id = p_member and wallet_type = 'get_wallet'), 0);
end;
$$;
revoke execute on function public.approver_member_wallet(uuid) from public, anon;
grant execute on function public.approver_member_wallet(uuid) to authenticated;

-- ---- 2. Add credit to a covered member ------------------------------------------------------------
-- The most a single top-up may move (a fat-finger guard; the approver can never
-- overdraw regardless, since GET.wallet stays >= 0).
create or replace function public.approver_add_credit(
  p_member     uuid,
  p_amount     numeric,
  p_pin        text,
  p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a        public.approvers;
  v_me     uuid := auth.uid();
  v_amount numeric;
  v_prior  jsonb;
  v_master public.wallets;
  v_phone  text;
  v_result jsonb;
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  -- The grant must be active and allow crediting.
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_credit then
    raise exception 'not_allowed';
  end if;
  if p_member is null or p_member = v_me then
    raise exception 'invalid_member';
  end if;
  if not exists (select 1 from public.profiles where id = p_member) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not public.approver_covers(p_member) then
    raise exception 'out_of_scope';
  end if;

  v_amount := round(coalesce(p_amount, 0), 2);
  if v_amount <= 0 or v_amount > 10000 then
    raise exception 'invalid_amount';  -- 0 < amount <= 10000 per top-up
  end if;

  -- Confirm with the approver's sign-in PIN (rate-limited / locked out like sign-in).
  select phone into v_phone from public.profiles where id = v_me;
  if nullif(btrim(coalesce(p_pin, '')), '') is null
     or public.pin_check(coalesce(v_phone, ''), p_pin, public.request_client_ip()) is distinct from v_me then
    raise exception 'wrong_pin';
  end if;

  -- Idempotency: a repeated request id returns the first result, no second charge.
  v_prior := public.wallet_request_claim(p_request_id, v_me, 'approver_add_credit');
  if v_prior is not null then
    return v_prior;
  end if;

  -- Both wallets exist.
  insert into public.wallets (user_id, wallet_type, balance)
  values (v_me, 'get_wallet', 0), (p_member, 'get_wallet', 0)
  on conflict (user_id, wallet_type) do nothing;

  select * into v_master from public.wallets
   where user_id = v_me and wallet_type = 'get_wallet' for update;
  if v_master.balance < v_amount then
    raise exception 'insufficient_balance';
  end if;

  -- Ledger-driven: the trigger moves both balances.
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note) values
    (v_me,     'get_wallet', 'team_credit_out', -v_amount, 'Credit added to a team member'),
    (p_member, 'get_wallet', 'team_credit_in',   v_amount, 'Credit added by your team');

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.credit', p_member, jsonb_build_object('amount', v_amount));

  perform public.approval_push_send(
    p_member,
    jsonb_build_object('title', 'Credit added',
      'body', 'RM' || to_char(v_amount, 'FM999999990.00') || ' was added to your GET.wallet by your team.'),
    jsonb_build_object('type', 'wallet_credit', 'amount', v_amount));

  v_result := jsonb_build_object('ok', true, 'amount', v_amount);
  perform public.wallet_request_settle(p_request_id, v_result);
  return v_result;
end;
$$;
revoke execute on function public.approver_add_credit(uuid, numeric, text, uuid) from public, anon;
grant execute on function public.approver_add_credit(uuid, numeric, text, uuid) to authenticated;

notify pgrst, 'reload schema';
