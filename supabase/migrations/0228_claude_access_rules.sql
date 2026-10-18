-- ============================================================================
-- 0228 — Claude Code access rules
--
-- Admin → Security & integrations → Claude Code access lists
--   * the Claude cloud sessions (claude.ai/code/session_<id>) that may use
--     the Supabase MCP tools without a permission prompt, and
--   * the office IP addresses from which a developer's own machine gets the
--     same, and from which this list may be changed at all.
--
-- `.claude/hooks/supabase-ip-gate.sh` reads the enabled rows with the
-- publishable key before every Supabase MCP tool call, so the rows are
-- readable by everyone (a session id and an office address are not secrets)
-- and written only by an admin with EDIT on 'admin-settings-claude-access'
-- (0223) whose request comes from an enabled office IP. The last enabled
-- office IP can be neither disabled nor removed, so the page cannot lock
-- every admin out.
-- Note: a local Claude Code CLI honours the hook, so an office machine gets no
-- prompt. A cloud session reads this list too, but the Supabase connector
-- there asks on writes from its own tool-permission setting at
-- claude.ai/customize/connectors, which a hook cannot override.
-- ============================================================================

create table if not exists public.claude_access_rules (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('session', 'ip')),
  value       text not null check (value = btrim(value) and value <> '' and length(value) <= 64),
  label       text check (label is null or length(label) <= 120),
  enabled     boolean not null default true,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (kind, value)
);
comment on table public.claude_access_rules is
  'Claude Code sessions and office IPs that use the Supabase MCP tools without a permission prompt; read by .claude/hooks/supabase-ip-gate.sh.';

create index if not exists claude_access_rules_enabled_kind_idx on public.claude_access_rules (kind) where enabled;

drop trigger if exists trg_claude_access_rules_updated_at on public.claude_access_rules;
create trigger trg_claude_access_rules_updated_at before update on public.claude_access_rules
  for each row execute function public.set_updated_at();

-- True when the request comes from an enabled office IP. A direct database
-- session (no JWT: psql, migrations, seeds) counts as the office.
create or replace function public.claude_access_from_office()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ip text;
begin
  if nullif(current_setting('request.jwt.claims', true), '') is null then
    return true;
  end if;
  v_ip := public.request_client_ip();
  if v_ip is null then
    return false;
  end if;
  return exists (
    select 1 from public.claude_access_rules
     where kind = 'ip' and enabled and value = v_ip);
end;
$$;
revoke execute on function public.claude_access_from_office() from public;
grant execute on function public.claude_access_from_office() to authenticated;

-- Never leave the list without an enabled office IP: nobody could edit it again.
create or replace function public.claude_access_keep_office_ip()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.kind = 'ip' and old.enabled
     and (tg_op = 'DELETE' or new.kind <> 'ip' or not new.enabled)
     and not exists (
       select 1 from public.claude_access_rules
        where kind = 'ip' and enabled and id <> old.id)
  then
    raise exception 'claude_access_last_office_ip'
      using errcode = 'check_violation',
            hint = 'Add another office IP before removing or disabling this one.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_claude_access_keep_office_ip on public.claude_access_rules;
create trigger trg_claude_access_keep_office_ip before update or delete on public.claude_access_rules
  for each row execute function public.claude_access_keep_office_ip();

-- Who writes it: EDIT on the page (0223), from the office.
insert into public.admin_table_pages (target, page) values
  ('claude_access_rules', 'admin-settings-claude-access')
on conflict do nothing;

alter table public.claude_access_rules enable row level security;
grant select on public.claude_access_rules to anon, authenticated;
grant insert, update, delete on public.claude_access_rules to authenticated;

drop policy if exists "claude_access_rules read"         on public.claude_access_rules;
drop policy if exists "claude_access_rules admin insert" on public.claude_access_rules;
drop policy if exists "claude_access_rules admin update" on public.claude_access_rules;
drop policy if exists "claude_access_rules admin delete" on public.claude_access_rules;

create policy "claude_access_rules read"
  on public.claude_access_rules for select to anon, authenticated
  using (true);
create policy "claude_access_rules admin insert"
  on public.claude_access_rules for insert to authenticated
  with check ((select public.caller_admin_can_write('claude_access_rules'))
              and (select public.claude_access_from_office()));
create policy "claude_access_rules admin update"
  on public.claude_access_rules for update to authenticated
  using ((select public.caller_admin_can_write('claude_access_rules'))
         and (select public.claude_access_from_office()))
  with check ((select public.caller_admin_can_write('claude_access_rules'))
              and (select public.claude_access_from_office()));
create policy "claude_access_rules admin delete"
  on public.claude_access_rules for delete to authenticated
  using ((select public.caller_admin_can_write('claude_access_rules'))
         and (select public.claude_access_from_office()));

-- Today's list.
insert into public.claude_access_rules (kind, value, label) values
  ('ip',      '202.188.231.237',          'Office'),
  ('session', '01D5UkQNkT4wNjAS45j7F4ej', null),
  ('session', '01NDfeQQMcJvAnDpYN9Mwyb6', null),
  ('session', '01LUamzNaqHsLrMn92xVqEzH', null),
  ('session', '017V7sMCRzpsywneJ3Sw3wHz', null),
  ('session', '018jbhTQW6yVtn1tDDWjy2W1', null)
on conflict (kind, value) do nothing;

-- The admin page follows changes live (pattern from 0102).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'claude_access_rules')
  then
    alter publication supabase_realtime add table public.claude_access_rules;
  end if;
end $$;
