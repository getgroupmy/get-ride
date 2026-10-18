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

  group('isValidIp', () {
    test('IPv4 octets 0–255, IPv6 hex groups', () {
      expect(isValidIp('202.188.231.237'), isTrue);
      expect(isValidIp(' 203.0.113.10 '), isTrue);
      expect(isValidIp('2001:db8::1'), isTrue);
      expect(isValidIp('256.1.1.1'), isFalse);
      expect(isValidIp('1.2.3'), isFalse);
      expect(isValidIp('office'), isFalse);
      expect(isValidIp(''), isFalse);
      expect(isValidIp('1:::2'), isFalse);
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
      expect(claudeRuleRow(kind: ClaudeRuleKind.ip, value: 'nope').error, contains('IP address'));
      expect(claudeRuleRow(kind: ClaudeRuleKind.session, value: 'nope').error, contains('session link'));
    });
  });

  group('isOfficeIp', () {
    final rules = [
      rule(ClaudeRuleKind.ip, '202.188.231.237'),
      rule(ClaudeRuleKind.ip, '203.0.113.10', enabled: false),
      rule(ClaudeRuleKind.session, '203.0.113.11'),
    ];
    test('an enabled ip rule, and nothing else', () {
      expect(isOfficeIp('202.188.231.237', rules), isTrue);
      expect(isOfficeIp('203.0.113.10', rules), isFalse, reason: 'disabled');
      expect(isOfficeIp('203.0.113.11', rules), isFalse, reason: 'a session, not an ip');
      expect(isOfficeIp('198.51.100.1', rules), isFalse);
      expect(isOfficeIp(null, rules), isFalse);
      expect(isOfficeIp('', rules), isFalse);
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
      expect(friendlyClaudeRuleError(Exception('socket closed')), isNull);
    });
  });
}
