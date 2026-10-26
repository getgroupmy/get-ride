-- ============================================================================
-- 0296 — Partner application review, part 2: a document is viewed before it
-- is decided, every view and decision is logged with who made it, and the
-- partner is approved only through the review.
--
-- Version 20261026120000 (0296_partner_review_views). Re-runnable: the table
-- and columns "if not exists", functions "create or replace", triggers and
-- policies dropped first.
--
-- 1. partner_review_log: one row a view, decision or return to pending on a
--    line (item_key) of an application, who did it (actor_id) and when.
--    Admins read it; nobody writes it directly.
-- 2. partner_review_view(partner, key): an admin who can review logs that
--    they opened the line's document. Returns how many times it has been
--    viewed.
-- 3. A line with a document (its value is set) is approved, rejected or
--    edited only by an admin who viewed it since it last went back to
--    pending (trigger on partner_review_items). Decisions and returns to
--    pending (a line cleared, or sent again by the driver) are logged.
-- 4. partners.approved_by / approved_at: who approved the partner and when,
--    set as the status becomes 'approved'.
-- 5. From unapproved, unapproved-docs or changes-needed, an admin approves a
--    partner only through the review: at least one line decided and none
--    rejected (the review page asks for every line). Unblocking and the
--    permit statuses are unchanged.
-- ============================================================================

-- ---- 1. The log ---------------------------------------------------------------------------------
create table if not exists public.partner_review_log (
  id         uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.partners (id) on delete cascade,
  item_key   text not null check (char_length(item_key) between 1 and 120),
  action     text not null check (action in ('viewed', 'approved', 'rejected', 'edited', 'pending', 'partner_approved')),
  actor_id   uuid references public.profiles (id) on delete set null,
  -- clock_timestamp(), not now(): a view and a return to pending in one
  -- transaction are still ordered.
  at         timestamptz not null default clock_timestamp()
);
comment on table public.partner_review_log is
  'Partner application review (0296): every view of a line''s document, every decision and every return to pending, with who did it. Admins read it; written only by partner_review_view and the triggers on partner_review_items and partners.';
create index if not exists partner_review_log_partner_idx on public.partner_review_log (partner_id, item_key, at);

alter table public.partner_review_log enable row level security;
revoke all on public.partner_review_log from public, anon, authenticated;
grant select on public.partner_review_log to authenticated;
grant all on public.partner_review_log to service_role;

drop policy if exists partner_review_log_read on public.partner_review_log;
create policy partner_review_log_read on public.partner_review_log
  for select to authenticated using ((select public.caller_is_admin()));

insert into public.admin_table_pages (target, page) values
  ('rpc:partner_review_view', 'admin-partners'),
  ('rpc:partner_review_view', 'admin-partner-edit')
on conflict do nothing;

-- ---- 2. Viewing a line ---------------------------------------------------------------------------
create or replace function public.partner_review_view(p_partner uuid, p_key text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  n integer;
begin
  if not public.caller_admin_can_write('rpc:partner_review_view') then
    raise exception 'Only admins who can edit partners can review an application.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.partners where id = p_partner) then
    raise exception 'PARTNER_NOT_FOUND' using errcode = 'P0002', hint = 'This partner no longer exists.';
  end if;
  if p_key is null or char_length(p_key) not between 1 and 120 then
    raise exception 'REVIEW_BAD_ITEM' using errcode = '22023', hint = 'That is not a line of this application.';
  end if;
  insert into public.partner_review_log (partner_id, item_key, action, actor_id)
  values (p_partner, p_key, 'viewed', auth.uid());
  select count(*) into n from public.partner_review_log
   where partner_id = p_partner and item_key = p_key and action = 'viewed';
  return n;
end;
$$;
revoke all on function public.partner_review_view(uuid, text) from public, anon;
grant execute on function public.partner_review_view(uuid, text) to authenticated;

-- ---- 3. Decisions need a view; decisions and returns to pending are logged ----------------------
-- Whether [p_key] is a line with a document to look at (its photo or file).
create or replace function public.partner_review_has_document(p_key text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_key in ('details.photo', 'id.front', 'id.back', 'company.document', 'permit.photos',
                   'vehicle.grant', 'vehicle.photos', 'vehicle.authorisation', 'vehicle.agreement')
      or p_key like 'doc:%'
      or p_key like 'vpermit:%';
$$;

create or replace function public.partner_review_items_viewed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  since timestamptz;
begin
  -- The service role and the driver's own changes (fixed_at, kept_at,
  -- sent_at) are not decisions.
  if me is null or not public.caller_is_admin() then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.state is not distinct from old.state
     and new.decided_at is not distinct from old.decided_at then
    return new;
  end if;
  if public.partner_review_has_document(new.item_key)
     and public.partner_review_value(new.partner_id, new.item_key) is not null
     and public.partner_review_value(new.partner_id, new.item_key) <> 'null'::jsonb then
    select max(at) into since from public.partner_review_log
     where partner_id = new.partner_id and item_key = new.item_key and action = 'pending';
    if not exists (
      select 1 from public.partner_review_log
       where partner_id = new.partner_id and item_key = new.item_key and action = 'viewed'
         and actor_id = me and at > coalesce(since, '-infinity'::timestamptz)
    ) then
      raise exception 'REVIEW_VIEW_FIRST' using errcode = '22023',
        hint = 'Open the document first: it is decided only once you have viewed it.';
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.partner_review_items_log()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    insert into public.partner_review_log (partner_id, item_key, action, actor_id)
    values (old.partner_id, old.item_key, 'pending', auth.uid());
    return old;
  end if;
  if tg_op = 'UPDATE' and new.state is not distinct from old.state
     and new.decided_at is not distinct from old.decided_at then
    return new;
  end if;
  insert into public.partner_review_log (partner_id, item_key, action, actor_id)
  values (new.partner_id, new.item_key, new.state, coalesce(auth.uid(), new.reviewer_id));
  return new;
end;
$$;

drop trigger if exists trg_partner_review_items_viewed on public.partner_review_items;
create trigger trg_partner_review_items_viewed
  before insert or update on public.partner_review_items
  for each row execute function public.partner_review_items_viewed();

drop trigger if exists trg_partner_review_items_log on public.partner_review_items;
create trigger trg_partner_review_items_log
  after insert or update or delete on public.partner_review_items
  for each row execute function public.partner_review_items_log();

-- ---- 4 and 5. Who approved, and approval through the review --------------------------------------
alter table public.partners add column if not exists approved_by uuid references public.profiles (id) on delete set null;
alter table public.partners add column if not exists approved_at timestamptz;
comment on column public.partners.approved_by is 'The admin who approved the partner (0296).';
comment on column public.partners.approved_at is 'When the partner was approved (0296).';

create or replace function public.partners_approved_by()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status::text = 'approved' and old.status::text is distinct from 'approved' then
    if auth.uid() is not null and public.caller_is_admin()
       and old.status::text in ('unapproved', 'unapproved-docs', 'changes-needed') then
      if not exists (select 1 from public.partner_review_items where partner_id = new.id)
         or exists (select 1 from public.partner_review_items where partner_id = new.id and state = 'rejected') then
        raise exception 'REVIEW_FIRST' using errcode = '22023',
          hint = 'Approve this partner from Review application, once every line is checked.';
      end if;
    end if;
    new.approved_by := auth.uid();
    new.approved_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_partners_approved_by on public.partners;
create trigger trg_partners_approved_by
  before update of status on public.partners
  for each row execute function public.partners_approved_by();

create or replace function public.partners_approved_log()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status::text = 'approved' and old.status::text is distinct from 'approved' then
    insert into public.partner_review_log (partner_id, item_key, action, actor_id)
    values (new.id, 'partner', 'partner_approved', auth.uid());
  end if;
  return new;
end;
$$;

drop trigger if exists trg_partners_approved_log on public.partners;
create trigger trg_partners_approved_log
  after update of status on public.partners
  for each row execute function public.partners_approved_log();
