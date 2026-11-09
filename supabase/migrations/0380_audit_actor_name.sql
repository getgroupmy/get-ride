-- ============================================================================
-- 0380: Capture the actor's NAME on every audit-log entry.
--
-- admin_audit_log already records actor_id (who) for every approver action —
-- approve / reject / review of documents, member and vehicle status changes,
-- access grants, credit, etc. For an audit trail the *name* should be captured
-- too, and frozen at the time of the action (names can change later). This adds
-- admin_audit_log.actor_name, filled from profiles at insert time by a trigger,
-- so it covers all existing and future audited actions with no RPC changes.
-- ============================================================================
alter table public.admin_audit_log add column if not exists actor_name text;

create or replace function public.admin_audit_log_actor_name()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.actor_name is null and new.actor_id is not null then
    select nullif(btrim(p.name), '') into new.actor_name
      from public.profiles p where p.id = new.actor_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_admin_audit_log_actor_name on public.admin_audit_log;
create trigger trg_admin_audit_log_actor_name
  before insert on public.admin_audit_log
  for each row execute function public.admin_audit_log_actor_name();

-- Backfill the name on past entries that have an actor.
update public.admin_audit_log a
   set actor_name = nullif(btrim(p.name), '')
  from public.profiles p
 where p.id = a.actor_id and a.actor_name is null;

notify pgrst, 'reload schema';
