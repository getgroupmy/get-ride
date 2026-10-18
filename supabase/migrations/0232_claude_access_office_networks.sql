-- ============================================================================
-- 0232 — Claude Code access: office rules may be networks, not only addresses
--
-- Office machines are dual-stack: a browser reaches Supabase over IPv6, so the
-- request's address is an IPv6 one that changes per device and over time,
-- while the office rule (0228) held one IPv4 address. Now an 'ip' rule is
-- any address or network in CIDR form ('202.188.231.237',
-- '2001:d08:1c01:6873::/64') and a request matches when its address is
-- inside it. The admin page and the hook look up both of the device's
-- addresses and match them the same way. Seeds the office's IPv6 /64.
-- ============================================================================

-- A text that Postgres reads as an address or network.
create or replace function public.claude_access_is_inet(p text)
returns boolean
language plpgsql
immutable
as $$
begin
  perform p::inet;
  return true;
exception when others then
  return false;
end;
$$;
revoke execute on function public.claude_access_is_inet(text) from public;
grant execute on function public.claude_access_is_inet(text) to anon, authenticated;

alter table public.claude_access_rules drop constraint if exists claude_access_rules_ip_value_check;
alter table public.claude_access_rules add constraint claude_access_rules_ip_value_check
  check (kind <> 'ip' or public.claude_access_is_inet(value));

-- True when the request comes from an enabled office address or network. A
-- direct database session (no JWT: psql, migrations, seeds) counts.
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
  if v_ip is null or not public.claude_access_is_inet(v_ip) then
    return false;
  end if;
  return exists (
    select 1 from public.claude_access_rules
     where kind = 'ip' and enabled
       and public.claude_access_is_inet(value)
       and v_ip::inet <<= value::inet);
end;
$$;

-- The office's IPv6 network, beside its IPv4 address from 0228.
insert into public.claude_access_rules (kind, value, label) values
  ('ip', '2001:d08:1c01:6873::/64', 'Office IPv6 network')
on conflict (kind, value) do nothing;
