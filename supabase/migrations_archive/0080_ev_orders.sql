-- ============================================================================
-- 0080 — TEKSI EV orders get their own owner-scoped table
-- ----------------------------------------------------------------------------
-- The EV order wizard (`app/teksi-ev.tsx`) creates an order the moment the
-- customer pays the order fee, writing it through the generic settings entry
-- pipeline under the category `ev-orders`. Since 0069, INSERT/UPDATE on
-- `settings_entries` requires `caller_is_admin()` — so a customer's order was
-- rejected by RLS and never reached the server. The admin console
-- (`app/admin-orders.tsx`) reads the same category, so orders paid for on a
-- phone were invisible to the back office.
--
-- Orders are customer data, not admin configuration, so they move to their own
-- table with owner-or-admin policies instead of being re-opened on
-- settings_entries. The row shape still mirrors settings_entries
-- (id / values / position / active / timestamps) so `SettingEntry` and the
-- existing screens keep working unchanged; `user_id` is the only addition.
--
-- Authority note: an order row is customer-writable by design (the wizard
-- collects ownership, plate, financing and delivery answers into it after the
-- deposit). The admin console remains the authority on fulfilment — advisor
-- assignment and the delivery checklist are entered there, and nothing in the
-- app treats a customer-supplied status as proof of fulfilment.
-- ============================================================================

create extension if not exists "pgcrypto";

create table if not exists public.ev_orders (
  id          uuid primary key default gen_random_uuid(),
  -- Defaulted rather than client-supplied: the customer's session decides who
  -- owns the row, and the trigger below freezes it after insert.
  user_id     uuid default auth.uid() references auth.users(id) on delete set null,
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists ev_orders_user_id_idx  on public.ev_orders(user_id);
create index if not exists ev_orders_position_idx on public.ev_orders(position);

drop trigger if exists trg_ev_orders_updated_at on public.ev_orders;
create trigger trg_ev_orders_updated_at
  before update on public.ev_orders
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- user_id is immutable after insert (same guard as ride_requests.rider_id)
-- ---------------------------------------------------------------------------
create or replace function public.ev_orders_freeze_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.user_id is distinct from old.user_id and not public.caller_is_admin() then
    raise exception 'ev_orders.user_id is immutable';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_ev_orders_freeze_owner on public.ev_orders;
create trigger trg_ev_orders_freeze_owner
  before update on public.ev_orders
  for each row execute function public.ev_orders_freeze_owner();

-- ---------------------------------------------------------------------------
-- Backfill anything that made it into settings_entries before the lockdown
-- ---------------------------------------------------------------------------
do $backfill$
begin
  if to_regclass('public.settings_entries') is null then return; end if;

  insert into public.ev_orders (id, values, position, created_at, updated_at)
    select id, coalesce(values, '{}'::jsonb), coalesce(position, 0), created_at, updated_at
      from public.settings_entries
     where category = 'ev-orders'
  on conflict (id) do nothing;

  delete from public.settings_entries where category = 'ev-orders';
end;
$backfill$;

-- ---------------------------------------------------------------------------
-- RLS: a customer sees and edits only their own orders; admins see everything
-- ---------------------------------------------------------------------------
alter table public.ev_orders enable row level security;

drop policy if exists "ev_orders read"   on public.ev_orders;
drop policy if exists "ev_orders insert" on public.ev_orders;
drop policy if exists "ev_orders update" on public.ev_orders;
drop policy if exists "ev_orders delete" on public.ev_orders;

create policy "ev_orders read" on public.ev_orders
  for select
  using (user_id = auth.uid() or public.caller_is_admin());

create policy "ev_orders insert" on public.ev_orders
  for insert to public
  with check (
    (auth.uid() is not null and user_id = auth.uid())
    or public.caller_is_admin()
  );

create policy "ev_orders update" on public.ev_orders
  for update to public
  using (user_id = auth.uid() or public.caller_is_admin())
  with check (user_id = auth.uid() or public.caller_is_admin());

-- A paid order is a record; only the back office removes one.
create policy "ev_orders delete" on public.ev_orders
  for delete to public
  using (public.caller_is_admin());

grant select, insert, update, delete on public.ev_orders to authenticated;
revoke all on public.ev_orders from anon;
