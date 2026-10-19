-- ============================================================================
-- Regression test for migration 0233: an office rule on Admin -> Security &
-- integrations -> Claude Code access is a single address, an IPv4 network of
-- /24 or narrower, or an IPv6 network of /48 or narrower (/120 inside the
-- IPv4-mapped range).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/claude_access_rule_width.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
-- Inserting office rule [p_value] (as a direct session, which counts as the
-- office) is refused by the width check.
create or replace function pg_temp.too_wide(p_value text) returns void language plpgsql as $$
begin
  begin
    insert into public.claude_access_rules (kind, value) values ('ip', p_value);
  exception when check_violation then
    if sqlerrm like '%claude_access_rules_ip_value_check%' then
      return;
    end if;
    raise;
  end;
  raise exception 'FAILED: office rule % was accepted', p_value;
end $$;

-- 0. The rules on the list pass --------------------------------------------------------------------
select pg_temp.check(
  (select count(*) from public.claude_access_rules
    where kind = 'ip' and value in ('202.188.231.237', '2001:d08:1c01:6873::/64')) = 2,
  'the office address and IPv6 network are still there');
select pg_temp.check(
  not exists (select 1 from public.claude_access_rules where kind = 'ip' and not public.claude_access_ip_rule_ok(value)),
  'every office rule on the list is narrow enough');
select pg_temp.check(
  (select convalidated from pg_constraint where conname = 'claude_access_rules_ip_value_check'),
  'the check is validated against the existing rows');

-- 1. The function --------------------------------------------------------------------------------------
select pg_temp.check(public.claude_access_ip_rule_ok('202.188.231.237'), 'a single IPv4 address');
select pg_temp.check(public.claude_access_ip_rule_ok('203.0.113.0/24'), 'an IPv4 /24');
select pg_temp.check(public.claude_access_ip_rule_ok('203.0.113.64/26'), 'an IPv4 /26');
select pg_temp.check(public.claude_access_ip_rule_ok('203.0.113.9/32'), 'an IPv4 /32');
select pg_temp.check(not public.claude_access_ip_rule_ok('203.0.112.0/23'), 'an IPv4 /23 is too wide');
select pg_temp.check(not public.claude_access_ip_rule_ok('10.0.0.0/8'), 'an IPv4 /8 is too wide');
select pg_temp.check(not public.claude_access_ip_rule_ok('0.0.0.0/0'), '0.0.0.0/0 is too wide');
select pg_temp.check(public.claude_access_ip_rule_ok('2001:d08:1c01:6873::/64'), 'the office IPv6 /64');
select pg_temp.check(public.claude_access_ip_rule_ok('2001:db8:1::/48'), 'an IPv6 /48');
select pg_temp.check(public.claude_access_ip_rule_ok('2001:db8::1'), 'a single IPv6 address');
select pg_temp.check(not public.claude_access_ip_rule_ok('2001:db8::/47'), 'an IPv6 /47 is too wide');
select pg_temp.check(not public.claude_access_ip_rule_ok('2000::/3'), 'an IPv6 /3 is too wide');
select pg_temp.check(not public.claude_access_ip_rule_ok('::/0'), '::/0 is too wide');
select pg_temp.check(not public.claude_access_ip_rule_ok('::/48'), 'an IPv6 /48 covering the IPv4-mapped range is too wide');
select pg_temp.check(not public.claude_access_ip_rule_ok('::ffff:0.0.0.0/96'), 'the whole IPv4-mapped range is too wide');
select pg_temp.check(not public.claude_access_ip_rule_ok('::ffff:203.0.112.0/119'), 'a mapped /23 is too wide');
select pg_temp.check(public.claude_access_ip_rule_ok('::ffff:203.0.113.0/120'), 'a mapped /24 is narrow enough');
select pg_temp.check(not public.claude_access_ip_rule_ok('office'), 'a word is not an office rule');
select pg_temp.check(not public.claude_access_ip_rule_ok(''), 'an empty value is not an office rule');

-- 2. The table refuses a wide office rule ---------------------------------------------------------------
select pg_temp.too_wide('0.0.0.0/0');
select pg_temp.too_wide('::/0');
select pg_temp.too_wide('198.51.0.0/16');
select pg_temp.too_wide('2001:db8::/32');
select pg_temp.too_wide('::ffff:0:0/96');
select pg_temp.too_wide('not-an-address');
insert into public.claude_access_rules (kind, value, label) values
  ('ip', '198.51.100.0/24', 'Test IPv4 network'),
  ('ip', '2001:db8:42::/48', 'Test IPv6 network');
select pg_temp.check(
  (select count(*) from public.claude_access_rules where value in ('198.51.100.0/24', '2001:db8:42::/48')) = 2,
  'a /24 and a /48 are accepted');
-- An existing rule can not be widened either.
do $$
begin
  update public.claude_access_rules set value = '198.51.0.0/16' where value = '198.51.100.0/24';
  raise exception 'FAILED: an office rule was widened to /16';
exception when check_violation then
  if sqlerrm not like '%claude_access_rules_ip_value_check%' then
    raise;
  end if;
end $$;
-- The check is only on office rules: session values are not addresses.
insert into public.claude_access_rules (kind, value) values ('session', 'width0000000000000000000a');
select pg_temp.check(
  exists (select 1 from public.claude_access_rules where kind = 'session' and value = 'width0000000000000000000a'),
  'a session rule is not held to the address check');

rollback;

select 'claude_access_rule_width: all passed';
