// The help assistant's knowledge base exists three times: the JSON it is
// written in, the const list the app ranks offline (lib/src/core/help_kb.dart)
// and the seed of migration 0130. scripts/gen_help_kb.dart writes the last two
// from the first; these tests fail when one was edited by hand or not
// regenerated.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/help_article.dart';
import 'package:get_ride/src/core/help_kb.dart';

List<Map<String, dynamic>> _json() =>
    (jsonDecode(File('assets/help/help_articles.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();

/// (id, title) of every row in the migration's seed block.
List<(String, String)> _seed() {
  final sql = File('supabase/migrations/0130_help_articles.sql').readAsStringSync();
  final block = sql.substring(sql.indexOf('-- BEGIN help_articles seed'), sql.indexOf('-- END help_articles seed'));
  return [
    for (final m in RegExp(r"^  \('([0-9a-f-]{36})', '((?:[^']|'')*)',$", multiLine: true).allMatches(block))
      (m.group(1)!, m.group(2)!.replaceAll("''", "'")),
  ];
}

/// Every `path:` literal of the router, to check an action goes somewhere.
Set<String> _routePaths() {
  final files = [
    File('lib/src/app.dart'),
    File('lib/src/admin/admin_routes.dart'),
    ...Directory('lib/src/admin/screens')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('_module.dart')),
  ];
  return {
    for (final f in files)
      for (final m in RegExp(r"path: '([^']+)'").allMatches(f.readAsStringSync())) m.group(1)!,
  };
}

/// Whether [route] is an absolute path literal followed by any number of
/// nested (relative) ones, with no `:param` left to fill.
bool _routable(String route, Set<String> paths) {
  bool rest(String r) =>
      r.isEmpty ||
      paths.any(
        (p) =>
            !p.startsWith('/') &&
            !p.contains(':') &&
            (r == p || r.startsWith('$p/') && rest(r.substring(p.length + 1))),
      );
  return paths.any(
    (p) =>
        p.startsWith('/') &&
        !p.contains(':') &&
        (route == p ||
            (route.startsWith(p == '/' ? '/' : '$p/') && rest(route.substring(p == '/' ? 1 : p.length + 1)))),
  );
}

void main() {
  test('the const list is the JSON, field for field', () {
    final json = _json();
    expect(helpKnowledgeBase.length, json.length);
    for (var i = 0; i < json.length; i++) {
      final a = HelpArticle.fromJson(json[i]), b = helpKnowledgeBase[i];
      expect(
        [
          b.id,
          b.title,
          b.questionVariants,
          b.answer,
          b.keywords,
          b.audience,
          b.category,
          b.actionLabel,
          b.actionRoute,
          b.sort,
        ],
        [
          a.id,
          a.title,
          a.questionVariants,
          a.answer,
          a.keywords,
          a.audience,
          a.category,
          a.actionLabel,
          a.actionRoute,
          a.sort,
        ],
        reason: a.title,
      );
    }
  });

  test('the migration seeds the same ids and titles', () {
    expect(_seed(), [for (final a in _json()) (a['id'] as String, a['title'] as String)]);
  });

  test('every article is complete and valid', () {
    expect(helpKnowledgeBase.length, inInclusiveRange(40, 70));
    expect(helpKnowledgeBase.map((a) => a.id).toSet(), hasLength(helpKnowledgeBase.length));
    expect(helpKnowledgeBase.map((a) => a.title).toSet(), hasLength(helpKnowledgeBase.length));
    for (final a in helpKnowledgeBase) {
      expect(helpArticleProblem(a), isNull, reason: a.title);
      expect(a.questionVariants.length, inInclusiveRange(2, 5), reason: a.title);
      expect(a.keywords, isNotEmpty, reason: a.title);
      expect(a.category, isNotEmpty, reason: a.title);
    }
    // The audiences and the areas the assistant is expected to cover.
    expect(helpKnowledgeBase.map((a) => a.audience).toSet(), {'all', 'rider', 'partner', 'admin'});
    expect(
      helpKnowledgeBase.map((a) => a.category).toSet(),
      containsAll(['Booking', 'Payments & wallet', 'Driving', 'TEKSI & meter', 'Safety', 'Support']),
    );
  });

  test("every action opens one of the app's screens", () {
    final paths = _routePaths();
    expect(_routable('/account/settings/pin', paths), isTrue);
    expect(_routable('/account/nowhere', paths), isFalse);
    for (final a in helpKnowledgeBase) {
      if (a.actionRoute != null) {
        expect(_routable(a.actionRoute!, paths), isTrue, reason: '${a.title} → ${a.actionRoute}');
      }
    }
  });

  test('top-up is described honestly', () {
    final topUp = helpKnowledgeBase.singleWhere((a) => a.title == 'How do I top up my wallet?');
    expect(topUp.answer, contains('not available'));
  });
}
