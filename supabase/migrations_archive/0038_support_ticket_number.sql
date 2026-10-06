-- ============================================================================
-- Support: serialised human-readable ticket numbers
-- ----------------------------------------------------------------------------
-- Builds on 0036_support.sql / 0037_support_assignment.sql:
--   * adds support_tickets.ticket_number — a stable, incrementing integer
--     assigned to every ticket via a dedicated sequence
--   * backfills existing tickets in creation order
--   * a BEFORE INSERT trigger stamps new tickets automatically
-- The displayed reference is formatted in the app as e.g. "TKT-001042".
-- Safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Sequence + column
-- ---------------------------------------------------------------------------
create sequence if not exists public.support_ticket_number_seq;

alter table public.support_tickets
  add column if not exists ticket_number integer;

-- ---------------------------------------------------------------------------
-- Backfill existing tickets in creation order (only those missing a number)
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select id from public.support_tickets
    where ticket_number is null
    order by created_at asc, id asc
  loop
    update public.support_tickets
      set ticket_number = nextval('public.support_ticket_number_seq')
      where id = r.id;
  end loop;
end$$;

-- ---------------------------------------------------------------------------
-- Auto-assign on insert
-- ---------------------------------------------------------------------------
create or replace function public.set_support_ticket_number()
returns trigger
language plpgsql
as $$
begin
  if new.ticket_number is null then
    new.ticket_number := nextval('public.support_ticket_number_seq');
  end if;
  return new;
end;
$$;

drop trigger if exists trg_support_ticket_number on public.support_tickets;
create trigger trg_support_ticket_number
  before insert on public.support_tickets
  for each row execute function public.set_support_ticket_number();

-- Keep the sequence ahead of any backfilled values.
select setval(
  'public.support_ticket_number_seq',
  coalesce((select max(ticket_number) from public.support_tickets), 0) + 1,
  false
);

create unique index if not exists support_tickets_ticket_number_idx
  on public.support_tickets(ticket_number);
