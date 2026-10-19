-- ============================================================================
-- 0233 — Claude Code access: an office network may not be too wide
--
-- Since 0232 an 'ip' rule may be a network, and nothing limited how wide:
-- '0.0.0.0/0' or '::/0' would put every address in "the office", which both
-- skips the hook's permission prompt and lets anyone with EDIT on the page
-- change the list from anywhere. An office rule is now a single address, an
-- IPv4 network of /24 or narrower, or an IPv6 network of /48 or narrower. An
-- IPv6 network that reaches into the IPv4-mapped range (::ffff:0:0/96) must
-- be /120 or narrower there, the same /24 in IPv4 terms.
--
-- The rows on the list (202.188.231.237, 2001:d08:1c01:6873::/64) pass; the
-- constraint is validated against every existing row when it is added. The
-- admin page (claude_access_logic.dart) and the hook
-- (.claude/hooks/supabase-ip-gate.sh) apply the same limits.
-- ============================================================================

-- A text that Postgres reads as an address or a network narrow enough to be
-- an office.
create or replace function public.claude_access_ip_rule_ok(p text)
returns boolean
language plpgsql
immutable
as $$
declare
  v inet;
begin
  if not public.claude_access_is_inet(p) then
    return false;
  end if;
  v := p::inet;
  if family(v) = 4 then
    return masklen(v) >= 24;
  end if;
  if masklen(v) < 48 then
    return false;
  end if;
  return not (v && '::ffff:0:0/96'::inet) or masklen(v) >= 120;
end;
$$;
revoke execute on function public.claude_access_ip_rule_ok(text) from public;
grant execute on function public.claude_access_ip_rule_ok(text) to anon, authenticated;

alter table public.claude_access_rules drop constraint if exists claude_access_rules_ip_value_check;
alter table public.claude_access_rules add constraint claude_access_rules_ip_value_check
  check (kind <> 'ip' or public.claude_access_ip_rule_ok(value));
