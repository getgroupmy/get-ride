-- ============================================================================
-- 0349: Approver — a delegated, scoped document reviewer (Phase 1: the grant
-- model and admin management).
--
-- An admin promotes a chosen user/partner to an "Approver": inside the app
-- (partner and user side menus, later phases) they review the documents in
-- their scope and, by their permission level, approve / reject / upload /
-- delete them. This migration is the backbone — the grant and its config, how
-- the app learns the caller is an approver (approver_self), and the admin
-- RPCs to grant, configure and revoke. The in-app inbox, the scope-filtered
-- document queries, and the approve/reject/upload/delete actions come in later
-- phases and build on this.
--
-- Permissions (read is implied by being an approver):
--   can_approve  approve / reject a document
--   can_upload   upload a document on the owner's behalf
--   can_delete   delete an uploaded document/image (soft unless delete_hard)
--
-- Scope — which owners' documents the approver may act on:
--   all          every owner
--   region       owners whose service area overlaps the approver's — their own
--                service area by default (use_own_region), plus any regions an
--                admin sets (regions)
--   referral     owners who signed up with the approver's referral code
--
-- conflict_guard (admin toggle): an approver may not act on their own
-- documents, and — off the referral scope — not on people they referred.
-- ends_at: an optional expiry, after which the grant is inactive.
-- doc_types: which document types are in scope (empty = all, now and future).
-- ============================================================================

-- ---- 0. One grant's config, cleaned and defaulted -------------------------------------------------
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
    'scope',         case when p->>'scope' in ('all', 'region', 'referral') then p->>'scope' else 'referral' end,
    'use_own_region', coalesce((p->>'use_own_region')::boolean, true),
    'regions',       case when jsonb_typeof(p->'regions') = 'array' then p->'regions' else '[]'::jsonb end,
    'doc_types',     case when jsonb_typeof(p->'doc_types') = 'array' then p->'doc_types' else '[]'::jsonb end,
    'conflict_guard', coalesce((p->>'conflict_guard')::boolean, true),
    'ends_at',       case when (p->>'ends_at') ~ '^\d{4}-\d{2}-\d{2}' then (p->>'ends_at') else null end,
    'note',          nullif(left(btrim(coalesce(p->>'note', '')), 300), ''));
$$;

-- ---- 1. The grant ---------------------------------------------------------------------------------
create table if not exists public.approvers (
  profile_id     uuid primary key references public.profiles(id) on delete cascade,
  active         boolean not null default true,
  can_approve    boolean not null default false,
  can_upload     boolean not null default false,
  can_delete     boolean not null default false,
  delete_hard    boolean not null default false,
  scope          text not null default 'referral' check (scope in ('all', 'region', 'referral')),
  use_own_region boolean not null default true,
  regions        jsonb not null default '[]'::jsonb check (jsonb_typeof(regions) = 'array'),
  doc_types      text[] not null default '{}',
  conflict_guard boolean not null default true,
  ends_at        timestamptz,
  note           text check (note is null or char_length(note) <= 300),
  granted_by     uuid references public.profiles(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
comment on table public.approvers is
  'Delegated document reviewers (0349): an admin-granted role with a permission level and a scope. Written only through admin_set_approver / admin_remove_approver.';
create index if not exists approvers_active_idx on public.approvers (active) where active;

alter table public.approvers enable row level security;
revoke all on public.approvers from public, anon, authenticated;
grant select on public.approvers to authenticated;
grant all on public.approvers to service_role;

-- The approver reads their own row; admins read all.
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public'
                   and tablename = 'approvers' and policyname = 'approvers_read') then
    create policy approvers_read on public.approvers
      for select to authenticated using (profile_id = (select auth.uid()) or (select public.caller_is_admin()));
  end if;
end $$;

-- ---- 2. The caller's own grant (for the app) ------------------------------------------------------
-- The config the app needs to show the Approver menu and gate its buttons, or
-- null when the caller is not an active approver.
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
           'scope', a.scope, 'doc_types', to_jsonb(a.doc_types))
    from public.approvers a
   where a.profile_id = auth.uid()
     and a.active and (a.ends_at is null or a.ends_at > now());
$$;
revoke execute on function public.approver_self() from public, anon;
grant execute on function public.approver_self() to authenticated;

-- ---- 3. Admin management --------------------------------------------------------------------------
insert into public.admin_table_pages (target, page) values
  ('rpc:admin_set_approver', 'admin-approvers'),
  ('rpc:admin_remove_approver', 'admin-approvers'),
  ('rpc:admin_list_approvers', 'admin-approvers')
on conflict do nothing;

-- Grant or re-configure an approver.
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
                                     scope, use_own_region, regions, doc_types, conflict_guard, ends_at, note, granted_by)
  values (p_user,
          (v_cfg->>'active')::boolean, (v_cfg->>'can_approve')::boolean, (v_cfg->>'can_upload')::boolean,
          (v_cfg->>'can_delete')::boolean, (v_cfg->>'delete_hard')::boolean,
          v_cfg->>'scope', (v_cfg->>'use_own_region')::boolean, v_cfg->'regions',
          array(select jsonb_array_elements_text(v_cfg->'doc_types')), (v_cfg->>'conflict_guard')::boolean,
          nullif(v_cfg->>'ends_at', '')::timestamptz, v_cfg->>'note', auth.uid())
  on conflict (profile_id) do update set
    active = excluded.active, can_approve = excluded.can_approve, can_upload = excluded.can_upload,
    can_delete = excluded.can_delete, delete_hard = excluded.delete_hard, scope = excluded.scope,
    use_own_region = excluded.use_own_region, regions = excluded.regions, doc_types = excluded.doc_types,
    conflict_guard = excluded.conflict_guard, ends_at = excluded.ends_at, note = excluded.note,
    granted_by = excluded.granted_by, updated_at = now();

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'approver.set', p_user, v_cfg);
  return v_cfg;
end;
$$;
revoke execute on function public.admin_set_approver(uuid, jsonb) from public, anon;
grant execute on function public.admin_set_approver(uuid, jsonb) to authenticated;

-- Revoke an approver: a soft revoke (active = false), so the grant and its
-- history stay for the audit and the admin can re-grant. The approver loses
-- the menu and every action at once (approver_self returns null).
create or replace function public.admin_remove_approver(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:admin_remove_approver') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  update public.approvers set active = false, updated_at = now() where profile_id = p_user;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'approver.revoke', p_user, '{}'::jsonb);
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.admin_remove_approver(uuid) from public, anon;
grant execute on function public.admin_remove_approver(uuid) to authenticated;

-- The approvers, with each one's name and phone, for the admin screen.
create or replace function public.admin_list_approvers()
returns table (profile_id uuid, name text, phone text, active boolean, scope text,
               can_approve boolean, can_upload boolean, can_delete boolean, ends_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_admin_can_write('rpc:admin_list_approvers') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
    select a.profile_id, coalesce(nullif(btrim(p.name), ''), 'User'), p.phone,
           a.active, a.scope, a.can_approve, a.can_upload, a.can_delete, a.ends_at
      from public.approvers a
      join public.profiles p on p.id = a.profile_id
     order by a.active desc, lower(coalesce(p.name, '')), a.profile_id;
end;
$$;
revoke execute on function public.admin_list_approvers() from public, anon;
grant execute on function public.admin_list_approvers() to authenticated;

notify pgrst, 'reload schema';
