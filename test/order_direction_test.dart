// Every PostgREST `.order(column)` in lib/ says which way it sorts.
//
// In postgrest-dart (the supabase package's query builder) `.order(column)`
// sorts DESCENDING unless `ascending: true` is passed — the opposite of the
// JS client and of SQL. A bare `.order('rank')` showed Admin → Service order
// upside down, so every save reversed it (see service_order_screen_test.dart);
// bare `.order('created_at')` showed the support chats newest-on-top, and
// bare `.order('position')` listed admin-arranged rows last-added first.
// This test fails on any `.order(` call in lib/ without an explicit
// `ascending:`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `.order(` calls that are not PostgREST's, by file, with the reason.
const _notPostgrest = <String, String>{
  // EvOrderRepository.order(id): reads one EV order by id.
  'lib/src/features/ev/ev_order_screen.dart': '_repo.order(',
  // DispatchRepository.order(id): reads one dispatch order by id.
  'lib/src/features/dispatch/dispatch_console.dart': 'repo.order(',
};

/// `file:line: args` for every `.order(` call in [source] without
/// `ascending:`. Comment lines are skipped.
List<String> orderCallsWithoutDirection(String path, String source) {
  final out = <String>[];
  final skip = _notPostgrest[path];
  for (final m in RegExp(r'\.order\(').allMatches(source)) {
    final lineStart = source.lastIndexOf('\n', m.start) + 1;
    final line = source.substring(lineStart, m.start).trimLeft();
    if (line.startsWith('//')) continue;
    if (skip != null && source.startsWith(skip, m.start - skip.length + '.order('.length)) continue;
    var depth = 1, i = m.end;
    while (i < source.length && depth > 0) {
      final c = source[i];
      if (c == '(') depth++;
      if (c == ')') depth--;
      i++;
    }
    final args = source.substring(m.end, i - 1);
    if (!RegExp(r'\bascending\s*:').hasMatch(args)) {
      final lineNo = '\n'.allMatches(source.substring(0, m.start)).length + 1;
      out.add('$path:$lineNo: .order(${args.replaceAll(RegExp(r'\s+'), ' ').trim()})');
    }
  }
  return out;
}

void main() {
  test('every .order( in lib/ states ascending: explicitly (postgrest-dart sorts descending by default)', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final path = f.path.replaceAll(r'\', '/');
      offenders.addAll(orderCallsWithoutDirection(path, f.readAsStringSync()));
    }
    expect(
      offenders,
      isEmpty,
      reason: "postgrest-dart's .order(column) sorts DESCENDING by default: write ascending: true "
          '(positions, ranks, names, chats read top to bottom) or ascending: false (newest first)',
    );
  });

  test('the scan catches a bare order, multi-line calls and ignores comments', () {
    const src = '''
final a = await db.from('t').select().order('position');
final b = await db.from('t').select().order(
  'rank',
  ascending: true,
);
// .order('in a comment')
final c = await db.from('t').select().order('created_at', ascending: false).order('id');
''';
    expect(orderCallsWithoutDirection('x.dart', src), [
      "x.dart:1: .order('position')",
      "x.dart:7: .order('id')",
    ]);
  });

  test('the non-PostgREST call is still there (else drop it from the allow-list)', () {
    for (final e in _notPostgrest.entries) {
      expect(File(e.key).readAsStringSync(), contains(e.value), reason: e.key);
    }
  });
}
