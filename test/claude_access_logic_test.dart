import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/security/claude_access_logic.dart';

void main() {
  ClaudeAccessRule rule(ClaudeRuleKind kind, String value, {bool enabled = true, String? label}) =>
      ClaudeAccessRule(id: '$kind:$value', kind: kind, value: value, enabled: enabled, label: label);

  group('normalizeSessionId', () {
    test('takes the link, the prefixed id or the bare id', () {
      const id = '01NDfeQQMcJvAnDpYN9Mwyb6';
      expect(normalizeSessionId('https://claude.ai/code/session_$id'), id);
      expect(normalizeSessionId('https://claude.ai/code/session_$id/'), id);
      expect(normalizeSessionId('https://claude.ai/code/session_$id?x=1#top'), id);
      expect(normalizeSessionId('session_$id'), id);
      expect(normalizeSessionId('cse_$id'), id);
      expect(normalizeSessionId('  $id  '), id);
    });

    test('refuses anything that is not a session id', () {
      expect(normalizeSessionId(''), isNull);
      expect(normalizeSessionId('https://claude.ai/code'), isNull);
      expect(normalizeSessionId('session_'), isNull);
      expect(normalizeSessionId('01NDfe QQMcJvAnDpYN9Mwyb6'), isNull);
      expect(normalizeSessionId('too-short'), isNull);
      expect(normalizeSessionId('01NDfeQQMcJvAnDpYN9Mwyb6z!'), isNull);
    });
  });

  group('addresses and networks', () {
    test('parses IPv4 and IPv6, with :: and an embedded IPv4', () {
      expect(parseIpBytes('202.188.231.237'), [202, 188, 231, 237]);
      expect(parseIpBytes('2001:db8::1'), [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
      expect(parseIpBytes('::ffff:192.0.2.1'), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 0, 2, 1]);
      expect(parseIpBytes('::'), List.filled(16, 0));
      expect(parseIpBytes('2001:d08:1c01:6873:613d:22a9:5c14:c146')?.length, 16);
      expect(parseIpBytes('256.1.1.1'), isNull);
      expect(parseIpBytes('1.2.3'), isNull);
      expect(parseIpBytes('1:::2'), isNull);
      expect(parseIpBytes('1::2::3'), isNull);
      expect(parseIpBytes('1:2:3:4:5:6:7:8:9'), isNull);
      expect(parseIpBytes('office'), isNull);
    });

    test('isValidIp takes an address or a CIDR network, within the family limits', () {
      expect(isValidIp('202.188.231.237'), isTrue);
      expect(isValidIp(' 203.0.113.0/24 '), isTrue);
      expect(isValidIp('2001:d08:1c01:6873::/64'), isTrue);
      expect(isValidIp('2001:db8::/128'), isTrue);
      expect(isValidIp('203.0.113.0/33'), isFalse);
      expect(isValidIp('2001:db8::/129'), isFalse);
      expect(isValidIp('203.0.113.0/'), isFalse);
      expect(isValidIp('203.0.113.0/x'), isFalse);
      expect(isValidIp(''), isFalse);
    });

    test('ipRuleProblem: one address, IPv4 to /24, IPv6 to /48, mapped IPv4 to /120 (0233)', () {
      // The rules on the live list pass.
      expect(ipRuleProblem('202.188.231.237'), isNull);
      expect(ipRuleProblem('2001:d08:1c01:6873::/64'), isNull);
      expect(ipRuleProblem('203.0.113.0/24'), isNull);
      expect(ipRuleProblem('203.0.113.64/26'), isNull);
      expect(ipRuleProblem('203.0.113.9/32'), isNull);
      expect(ipRuleProblem('2001:db8:1::/48'), isNull);
      expect(ipRuleProblem('2001:db8::1'), isNull);
      expect(ipRuleProblem('::ffff:203.0.113.0/120'), isNull);
      expect(ipRuleProblem('203.0.112.0/23'), allOf(contains('Too wide'), contains('/24')));
      expect(ipRuleProblem('10.0.0.0/8'), contains('Too wide'));
      expect(ipRuleProblem('0.0.0.0/0'), contains('Too wide'));
      expect(ipRuleProblem('2001:db8::/47'), allOf(contains('Too wide'), contains('/48')));
      expect(ipRuleProblem('::/0'), contains('Too wide'));
      expect(ipRuleProblem('2000::/3'), contains('Too wide'));
      expect(ipRuleProblem('::/48'), contains('IPv4-mapped'), reason: 'covers ::ffff:0:0/96');
      expect(ipRuleProblem('::ffff:0:0/96'), contains('IPv4-mapped'));
      expect(ipRuleProblem('::ffff:203.0.112.0/119'), contains('/120'));
      expect(ipRuleProblem('office'), contains('address or network'));
      expect(isValidIp('198.51.0.0/16'), isFalse);
      expect(isValidIp('::/0'), isFalse);
    });

    test('ipInRule: exact, inside a network, outside it, never across families', () {
      expect(ipInRule('202.188.231.237', '202.188.231.237'), isTrue);
      expect(ipInRule('202.188.231.238', '202.188.231.237'), isFalse);
      expect(ipInRule('198.51.100.77', '198.51.100.0/24'), isTrue);
      expect(ipInRule('198.51.101.1', '198.51.100.0/24'), isFalse);
      expect(ipInRule('198.51.100.77', '198.51.100.64/26'), isTrue);
      expect(ipInRule('198.51.100.63', '198.51.100.64/26'), isFalse);
      expect(ipInRule('2001:d08:1c01:6873:613d:22a9:5c14:c146', '2001:d08:1c01:6873::/64'), isTrue);
      expect(ipInRule('2001:d08:1c01:6874::1', '2001:d08:1c01:6873::/64'), isFalse);
      expect(ipInRule('2001:d08:1c01:6873::1', '2001:d08:1c01:6873::/64'), isTrue);
      expect(ipInRule('::ffff:198.51.100.77', '198.51.100.0/24'), isFalse, reason: 'different families');
      expect(ipInRule('198.51.100.77', '2001:db8::/32'), isFalse);
      expect(ipInRule('garbage', '198.51.100.0/24'), isFalse);
    });
  });

  group('claudeRuleRow', () {
    test('normalises a session link and trims the label', () {
      final r = claudeRuleRow(
          kind: ClaudeRuleKind.session, value: 'https://claude.ai/code/session_01D5UkQNkT4wNjAS45j7F4ej', label: '  QA  ');
      expect(r.error, isNull);
      expect(r.row, {'kind': 'session', 'value': '01D5UkQNkT4wNjAS45j7F4ej', 'label': 'QA'});
    });

    test('blank label is null; a bad value is an error, not a row', () {
      expect(claudeRuleRow(kind: ClaudeRuleKind.ip, value: '203.0.113.10', label: '').row,
          {'kind': 'ip', 'value': '203.0.113.10', 'label': null});
      expect(claudeRuleRow(kind: ClaudeRuleKind.ip, value: 'nope').error, contains('address or network'));
      expect(claudeRuleRow(kind: ClaudeRuleKind.ip, value: ' 2001:db8::/64 ').row?['value'], '2001:db8::/64');
      expect(claudeRuleRow(kind: ClaudeRuleKind.session, value: 'nope').error, contains('session link'));
      expect(claudeRuleRow(kind: ClaudeRuleKind.ip, value: '0.0.0.0/0').error, contains('Too wide'));
      expect(claudeRuleRow(kind: ClaudeRuleKind.ip, value: '::/0').row, isNull);
      expect(claudeRuleRow(kind: ClaudeRuleKind.ip, value: '198.51.100.0/24').row?['value'], '198.51.100.0/24');
    });
  });

  group('isOfficeIp / isOfficeDevice', () {
    final rules = [
      rule(ClaudeRuleKind.ip, '202.188.231.237'),
      rule(ClaudeRuleKind.ip, '2001:d08:1c01:6873::/64'),
      rule(ClaudeRuleKind.ip, '203.0.113.10', enabled: false),
      rule(ClaudeRuleKind.session, '203.0.113.11'),
    ];
    test('an enabled ip rule, by address or network, and nothing else', () {
      expect(isOfficeIp('202.188.231.237', rules), isTrue);
      expect(isOfficeIp('2001:d08:1c01:6873:613d:22a9:5c14:c146', rules), isTrue, reason: 'inside the /64');
      expect(isOfficeIp('2001:d08:1c01:6874::1', rules), isFalse, reason: 'next network over');
      expect(isOfficeIp('203.0.113.10', rules), isFalse, reason: 'disabled');
      expect(isOfficeIp('203.0.113.11', rules), isFalse, reason: 'a session, not an ip');
      expect(isOfficeIp('198.51.100.1', rules), isFalse);
      expect(isOfficeIp(null, rules), isFalse);
      expect(isOfficeIp('', rules), isFalse);
    });
    test('a rule too wide to be an office never counts', () {
      final wide = [rule(ClaudeRuleKind.ip, '0.0.0.0/0'), rule(ClaudeRuleKind.ip, '::/0'), rule(ClaudeRuleKind.ip, '198.51.0.0/16')];
      expect(isOfficeIp('198.51.100.1', wide), isFalse);
      expect(isOfficeIp('2001:db8::1', wide), isFalse);
      expect(isOfficeDevice(['198.51.100.1', '2001:db8::1'], wide), isFalse);
    });
    test('a dual-stack device is at the office if either address is', () {
      expect(isOfficeDevice(['198.51.100.1', '2001:d08:1c01:6873::abcd'], rules), isTrue);
      expect(isOfficeDevice(['202.188.231.237', '2001:db8::1'], rules), isTrue);
      expect(isOfficeDevice(['198.51.100.1', '2001:db8::1'], rules), isFalse);
      expect(isOfficeDevice(const [], rules), isFalse);
    });
  });

  group('filter, counts, subtitle', () {
    final rules = [
      rule(ClaudeRuleKind.ip, '202.188.231.237', label: 'Office'),
      rule(ClaudeRuleKind.session, '01D5UkQNkT4wNjAS45j7F4ej', label: 'Release QA'),
      rule(ClaudeRuleKind.session, '01LUamzNaqHsLrMn92xVqEzH', enabled: false),
    ];
    test('filters by kind and by words in the value or label', () {
      expect(filterClaudeRules(rules).length, 3);
      expect(filterClaudeRules(rules, kind: ClaudeRuleKind.session).length, 2);
      expect(filterClaudeRules(rules, query: 'qa').single.value, '01D5UkQNkT4wNjAS45j7F4ej');
      expect(filterClaudeRules(rules, query: '231.237').single.label, 'Office');
      expect(filterClaudeRules(rules, query: 'zzz'), isEmpty);
    });
    test('counts each kind', () => expect(countClaudeRules(rules), (sessions: 2, ips: 1)));
    test('subtitle is the label or what the rule does, with disabled marked', () {
      expect(claudeRuleSubtitle(rules[0]), 'Office');
      expect(claudeRuleSubtitle(rule(ClaudeRuleKind.ip, '2001:db8::/64')), startsWith('Office network'));
      expect(claudeRuleSubtitle(rules[2]), contains('without a prompt'));
      expect(claudeRuleSubtitle(rules[2]), endsWith('· disabled'));
      expect(rules[1].sessionUrl, 'https://claude.ai/code/session_01D5UkQNkT4wNjAS45j7F4ej');
    });
  });

  group('friendlyClaudeRuleError', () {
    test('names the page''s own failures and leaves the rest alone', () {
      expect(friendlyClaudeRuleError(Exception('P0001: claude_access_last_office_ip')), contains('another office IP'));
      expect(friendlyClaudeRuleError(Exception('duplicate key value violates unique constraint')), contains('already'));
      expect(friendlyClaudeRuleError(Exception('new row violates row-level security policy')), contains('office IP'));
      expect(
          friendlyClaudeRuleError(Exception(
              'new row for relation "claude_access_rules" violates check constraint "claude_access_rules_ip_value_check"')),
          allOf(contains('/24'), contains('/48')));
      expect(friendlyClaudeRuleError(Exception('socket closed')), isNull);
    });
  });
}
