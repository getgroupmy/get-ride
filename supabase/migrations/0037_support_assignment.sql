-- ============================================================================
-- Support: ticket statuses, agent assignment + pool, reply authorship
-- ----------------------------------------------------------------------------
-- Builds on 0036_support.sql:
--   * adds 'in_progress' to the ticket status set (New, In Progress,
--     Waiting for Reply, Resolved) — status is changed by admins only
--   * tracks which agent a ticket is assigned to (assigned_admin_*)
--   * records the name of the admin who sent each reply (sender_name)
--   * adds admin_access.support — a priority tag ("1","2","3"…) used to
--     decide who a new ticket auto-assigns to (lowest number first; if none
--     are tagged, the first admin in the list is used)
-- Safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Ticket: new status value + assignment columns
-- ---------------------------------------------------------------------------
alter table public.support_tickets
  drop constraint if exists support_tickets_status_check;

alter table public.support_tickets
  add constraint support_tickets_status_check
  check (status in ('open','in_progress','pending','closed'));

alter table public.support_tickets
  add column if not exists assigned_admin_id uuid references public.profiles(id) on delete set null;
alter table public.support_tickets
  add column if not exists assigned_admin_name text;
alter table public.support_tickets
  add column if not exists assigned_at timestamptz;

create index if not exists support_tickets_assigned_idx
  on public.support_tickets(assigned_admin_id);

-- ---------------------------------------------------------------------------
-- Message: who replied
-- ---------------------------------------------------------------------------
alter table public.support_messages
  add column if not exists sender_name text;

-- ---------------------------------------------------------------------------
-- admin_access: support agent priority tag
-- ---------------------------------------------------------------------------
alter table public.admin_access
  add column if not exists support integer;

create index if not exists admin_access_support_idx
  on public.admin_access(support) where support is not null;
