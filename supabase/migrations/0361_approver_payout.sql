-- ============================================================================
-- 0361: Payout account (bank / e-wallet) — My Team Phase 2c.
--
-- Builds on the existing partner_payout_accounts (0201), extending it from a
-- bank-only account to bank OR e-wallet, and letting an approver set a covered
-- member's payout as well as the member setting their own.
--
--   account_type               'bank' | 'ewallet' on partner_payout_accounts.
--   set_my_payout_account(..,type)  the member's own (keeps the 3-arg bank-only
--                                   version for older apps).
--   approver_set_member_payout(member, provider, account, holder, type)
--                                   an approver with can_edit_profile sets a
--                                   covered member's payout; scoped + audited.
--   approver_member_detail(member)  now also returns the member's payout.
--
-- The bank / e-wallet list is an admin-managed settings_entries category,
-- 'payout_provider', seeded here with Malaysian banks and e-wallets; the app's
-- provider dropdown reads it (and an admin can add/edit/remove entries).
-- ============================================================================

alter table public.partner_payout_accounts
  add column if not exists account_type text not null default 'bank'
    check (account_type in ('bank', 'ewallet'));

-- ---- 1. The member sets their own payout (now with a type) -----------------------------------------
create or replace function public.set_my_payout_account(p_bank text, p_account text, p_holder text, p_type text)
returns public.partner_payout_accounts
language plpgsql
security definer
set search_path = public
as $$
declare
  a     public.partner_payout_accounts;
  v_acc text := regexp_replace(coalesce(p_account, ''), '[\s-]', '', 'g');
  v_typ text := case when p_type = 'ewallet' then 'ewallet' else 'bank' end;
begin
  if not public.caller_is_approved_partner() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if btrim(coalesce(p_bank, '')) = '' or btrim(coalesce(p_holder, '')) = '' or v_acc !~ '^\d{6,20}$' then
    raise exception 'STATEMENT_BANK' using hint = 'Give the provider, the account holder and a 6 to 20 digit account number.';
  end if;
  insert into public.partner_payout_accounts (profile_id, bank_name, account_no, holder_name, account_type, updated_at)
  values (auth.uid(), left(btrim(p_bank), 80), v_acc, left(btrim(p_holder), 120), v_typ, now())
  on conflict (profile_id) do update
    set bank_name = excluded.bank_name, account_no = excluded.account_no,
        holder_name = excluded.holder_name, account_type = excluded.account_type, updated_at = now()
  returning * into a;
  return a;
end;
$$;
revoke execute on function public.set_my_payout_account(text, text, text, text) from public, anon;
grant execute on function public.set_my_payout_account(text, text, text, text) to authenticated;

-- ---- 2. An approver sets a covered member's payout ------------------------------------------------
create or replace function public.approver_set_member_payout(
  p_member uuid, p_provider text, p_account text, p_holder text, p_type text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a     public.approvers;
  v_me  uuid := auth.uid();
  v_acc text := regexp_replace(coalesce(p_account, ''), '[\s-]', '', 'g');
  v_typ text := case when p_type = 'ewallet' then 'ewallet' else 'bank' end;
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_edit_profile then
    raise exception 'not_allowed';
  end if;
  if p_member is null or not public.approver_covers(p_member) then
    raise exception 'out_of_scope';
  end if;
  if btrim(coalesce(p_provider, '')) = '' or btrim(coalesce(p_holder, '')) = '' or v_acc !~ '^\d{6,20}$' then
    raise exception 'invalid_payout';
  end if;

  insert into public.partner_payout_accounts (profile_id, bank_name, account_no, holder_name, account_type, updated_at)
  values (p_member, left(btrim(p_provider), 80), v_acc, left(btrim(p_holder), 120), v_typ, now())
  on conflict (profile_id) do update
    set bank_name = excluded.bank_name, account_no = excluded.account_no,
        holder_name = excluded.holder_name, account_type = excluded.account_type, updated_at = now();

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.set_payout', p_member, jsonb_build_object('type', v_typ, 'provider', left(btrim(p_provider), 80)));

  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.approver_set_member_payout(uuid, text, text, text, text) from public, anon;
grant execute on function public.approver_set_member_payout(uuid, text, text, text, text) to authenticated;

-- ---- 3. The member detail reader now includes the payout ------------------------------------------
create or replace function public.approver_member_detail(p_member uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  p   public.profiles;
  pay public.partner_payout_accounts;
begin
  if auth.uid() is null or p_member is null or not public.approver_covers(p_member) then
    return null;
  end if;
  select * into p from public.profiles where id = p_member;
  if not found then
    return null;
  end if;
  select * into pay from public.partner_payout_accounts where profile_id = p_member;
  return jsonb_build_object(
    'id', p.id,
    'name', p.name,
    'email', p.email,
    'phone', p.phone,
    'ic', p.ic,
    'nationality', p.nationality,
    'address', p.address,
    'status', p.status,
    'id_verified', p.id_verified,
    'is_partner', exists (select 1 from public.partners where auth_user_id = p_member),
    'partner_types', coalesce((select to_jsonb(partner_types) from public.partners
                                where auth_user_id = p_member limit 1), '[]'::jsonb),
    'payout', case when pay.profile_id is null then null else jsonb_build_object(
                'type', pay.account_type, 'provider', pay.bank_name,
                'account', pay.account_no, 'holder', pay.holder_name) end);
end;
$$;
revoke execute on function public.approver_member_detail(uuid) from public, anon;
grant execute on function public.approver_member_detail(uuid) to authenticated;

-- ---- 3b. The provider list, for the app dropdown -------------------------------------------------
create or replace function public.payout_providers()
returns table (name text, type text)
language sql
stable
security definer
set search_path = public
as $$
  select e.values->>'name', coalesce(e.values->>'type', 'bank')
    from public.settings_entries e
   where e.category = 'payout_provider' and e.active
     and coalesce((e.values->>'active')::boolean, true)
     and nullif(btrim(e.values->>'name'), '') is not null
   order by e.position, lower(e.values->>'name');
$$;
revoke execute on function public.payout_providers() from public, anon;
grant execute on function public.payout_providers() to authenticated;

-- ---- 4. Seed the admin-managed bank / e-wallet list ----------------------------------------------
-- category 'payout_provider', values = {name, type ('bank'|'ewallet'), active}.
insert into public.settings_entries (category, values, position)
select 'payout_provider', jsonb_build_object('name', v.name, 'type', v.type, 'active', true), v.pos
  from (values
    ('Maybank', 'bank', 1), ('CIMB Bank', 'bank', 2), ('Public Bank', 'bank', 3), ('RHB Bank', 'bank', 4),
    ('Hong Leong Bank', 'bank', 5), ('AmBank', 'bank', 6), ('Bank Islam', 'bank', 7), ('Bank Rakyat', 'bank', 8),
    ('BSN', 'bank', 9), ('OCBC Bank', 'bank', 10), ('HSBC Bank', 'bank', 11), ('Standard Chartered', 'bank', 12),
    ('UOB', 'bank', 13), ('Affin Bank', 'bank', 14), ('Alliance Bank', 'bank', 15), ('MBSB Bank', 'bank', 16),
    ('Agrobank', 'bank', 17),
    ('Touch ''n Go eWallet', 'ewallet', 18), ('GrabPay', 'ewallet', 19), ('Boost', 'ewallet', 20),
    ('ShopeePay', 'ewallet', 21), ('MAE', 'ewallet', 22), ('BigPay', 'ewallet', 23), ('Setel', 'ewallet', 24)
  ) as v(name, type, pos)
 where not exists (select 1 from public.settings_entries
                    where category = 'payout_provider' and lower(btrim(values->>'name')) = lower(v.name));

notify pgrst, 'reload schema';
