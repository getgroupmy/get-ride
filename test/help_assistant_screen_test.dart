// The help assistant screen and Admin → Help articles, on a fake repository:
// the conversation, its actions and feedback, in light and dark, and the
// admin's list, editor and unanswered questions.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/help/help_articles_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/help_article.dart';
import 'package:get_ride/src/core/help_kb.dart';
import 'package:get_ride/src/core/help_search.dart';
import 'package:get_ride/src/data/help_repository.dart';
import 'package:get_ride/src/features/support/help_assistant_screen.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// No token refresh: its timer would outlive the test.
final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

/// Answers from the built-in articles, as the app does offline, and records
/// what the screen logs.
class _FakeRepo extends HelpRepository {
  _FakeRepo({this.articleList = const [], this.questions = const []}) : super(_db);
  final _index = HelpIndex(helpKnowledgeBase);
  final List<HelpArticle> articleList;
  final List<HelpQuestion> questions;
  final logged = <(String, String?)>[];
  final feedback = <(String, bool)>[];
  final saved = <HelpArticle>[];
  final activeSet = <(String, bool)>[];

  @override
  Future<HelpSearchResult> search(String query, {required String viewer}) async =>
      HelpSearchResult(_index.search(query, viewer: viewer), offline: true);

  @override
  Future<String?> logQuestion(String question, {String? matchedArticleId}) async {
    logged.add((question, matchedArticleId));
    return 'q${logged.length}';
  }

  @override
  Future<void> setHelpful(String questionId, bool helpful) async => feedback.add((questionId, helpful));

  @override
  Future<List<HelpArticle>> articles() async => articleList;

  @override
  Future<List<HelpQuestion>> unansweredQuestions() async => questions;

  @override
  Future<HelpArticle> save(HelpArticle a) async {
    saved.add(a);
    return a;
  }

  @override
  Future<void> setActive(String id, bool active) async => activeSet.add((id, active));
}

Future<void> _pumpAssistant(WidgetTester tester, _FakeRepo repo, {Brightness brightness = Brightness.light}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(600, 1400);
  addTearDown(tester.view.reset);
  final router = GoRouter(
    initialLocation: '/account/help',
    routes: [
      GoRoute(path: '/account/help', builder: (_, _) => const HelpAssistantScreen()),
      GoRoute(path: '/account/settings/pin', builder: (_, _) => const Text('PIN page')),
      GoRoute(path: '/account/support', builder: (_, _) => const Text('Support page')),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [helpRepositoryProvider.overrideWithValue(repo), helpViewerProvider.overrideWithValue('rider')],
      child: MaterialApp.router(theme: appTheme(brightness), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _ask(WidgetTester tester, String q) async {
  await tester.enterText(find.byKey(const ValueKey('help-input')), q);
  await tester.tap(find.byKey(const ValueKey('help-send')));
  await tester.pumpAndSettle();
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('answers a question with its article and action (${brightness.name})', (tester) async {
      final repo = _FakeRepo();
      await _pumpAssistant(tester, repo, brightness: brightness);
      // The empty conversation offers starter questions.
      expect(find.byKey(const ValueKey('help-starters')), findsOneWidget);
      expect(find.text('How do I book a ride?'), findsOneWidget);

      await _ask(tester, 'how do I change my pin');
      expect(find.text('how do I change my pin'), findsOneWidget);
      final pin = helpKnowledgeBase.singleWhere((a) => a.title == 'How do I change my PIN?');
      expect(find.text(pin.answer), findsOneWidget);
      expect(find.byKey(const ValueKey('help-starters')), findsNothing);
      expect(repo.logged, [('how do I change my pin', pin.id)]);

      // Feedback is recorded against the logged question.
      await tester.tap(find.byKey(const ValueKey('help-helpful-yes')));
      await tester.pumpAndSettle();
      expect(repo.feedback, [('q1', true)]);
      expect(find.byKey(const ValueKey('help-thanks')), findsOneWidget);

      // The answer's action opens its screen.
      await tester.tap(find.byKey(ValueKey('help-action-${pin.id}')));
      await tester.pumpAndSettle();
      expect(find.text('PIN page'), findsOneWidget);
    });
  }

  testWidgets('a question it cannot answer is logged and support offered', (tester) async {
    final repo = _FakeRepo();
    await _pumpAssistant(tester, repo, brightness: Brightness.dark);
    await _ask(tester, 'what is the weather today');
    expect(find.textContaining("don't know the answer"), findsOneWidget);
    expect(find.textContaining('passed your question on'), findsOneWidget);
    expect(repo.logged, [('what is the weather today', null)]);
    // No feedback on a non-answer.
    expect(find.byKey(const ValueKey('help-helpful-yes')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('help-chat-support')));
    await tester.pumpAndSettle();
    expect(find.text('Support page'), findsOneWidget);
  });

  testWidgets('close matches are offered as choices, and a choice is answered', (tester) async {
    final repo = _FakeRepo();
    await _pumpAssistant(tester, repo);
    await _ask(tester, 'walet');
    expect(find.text('I found a few things that might help:'), findsOneWidget);
    const pick = 'What are GET.wallet, GET.credit and GET.coin?';
    expect(find.widgetWithText(ActionChip, pick), findsOneWidget);
    await tester.tap(find.widgetWithText(ActionChip, pick));
    await tester.pumpAndSettle();
    final article = helpKnowledgeBase.singleWhere((a) => a.title == pick);
    expect(find.text(article.answer), findsOneWidget);
    expect(repo.logged.last, (pick, article.id));
    expect(repo.logged.first, ('walet', null));

    await tester.tap(find.byKey(const ValueKey('help-helpful-no')));
    await tester.pumpAndSettle();
    expect(repo.feedback, [('q2', false)]);
  });

  testWidgets('a starter question is asked when tapped', (tester) async {
    final repo = _FakeRepo();
    await _pumpAssistant(tester, repo);
    await tester.tap(find.widgetWithText(ActionChip, 'I forgot my PIN'));
    await tester.pumpAndSettle();
    final forgot = helpKnowledgeBase.singleWhere((a) => a.title == 'I forgot my PIN');
    expect(find.text(forgot.answer), findsOneWidget);
    expect(repo.logged, [('I forgot my PIN', forgot.id)]);
  });

  group('admin', () {
    final articles = [
      const HelpArticle(id: 'a1', title: 'How do I cancel a ride?', answer: 'Tap Cancel ride.', keywords: ['batal']),
      const HelpArticle(id: 'a2', title: 'How do I top up?', answer: 'Not yet.', active: false, audience: 'rider'),
    ];
    final questions = [HelpQuestion(id: 'q1', question: 'Can I ride a zebra?', createdAt: DateTime(2026, 10, 9, 9))];

    Future<void> pumpAdmin(WidgetTester tester, _FakeRepo repo, {bool edit = true}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1600);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            helpRepositoryProvider.overrideWithValue(repo),
            adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: edit)])),
          ],
          child: MaterialApp(theme: appTheme(Brightness.light), home: const AdminHelpArticlesScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    test('is on the Settings hub under its own page key', () {
      final e = allAdminEntries.singleWhere((e) => e.path == '/admin/m/help-articles');
      expect((e.section, e.listed), ('Operations', true));
      expect(e.pages, [helpArticlesPage]);
    });

    testWidgets('lists, searches, switches off and edits articles', (tester) async {
      final repo = _FakeRepo(articleList: articles);
      await pumpAdmin(tester, repo);
      expect(find.text('2 of 2 articles · 1 switched off'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('help-article-search')), 'batal');
      await tester.pumpAndSettle();
      expect(find.text('How do I top up?'), findsNothing);
      expect(find.text('How do I cancel a ride?'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('help-article-active-a1')));
      await tester.pumpAndSettle();
      expect(repo.activeSet, [('a1', false)]);

      await tester.tap(find.text('How do I cancel a ride?'));
      await tester.pumpAndSettle();
      expect(find.text('Edit article'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('help-edit-route')), 'account');
      await tester.tap(find.byKey(const ValueKey('help-edit-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('help-edit-problem')), findsOneWidget);
      expect(repo.saved, isEmpty);
      await tester.enterText(find.byKey(const ValueKey('help-edit-route')), '/trips');
      await tester.enterText(find.byKey(const ValueKey('help-edit-label')), 'Open Trips');
      await tester.tap(find.byKey(const ValueKey('help-edit-save')));
      await tester.pumpAndSettle();
      expect(repo.saved.single.id, 'a1');
      expect((repo.saved.single.actionRoute, repo.saved.single.actionLabel), ('/trips', 'Open Trips'));
    });

    testWidgets('an unanswered question becomes a new article', (tester) async {
      final repo = _FakeRepo(articleList: articles, questions: questions);
      await pumpAdmin(tester, repo);
      await tester.tap(find.text('Unanswered questions'));
      await tester.pumpAndSettle();
      expect(find.text('Can I ride a zebra?'), findsOneWidget);
      expect(find.textContaining('No match'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('help-question-create-q1')));
      await tester.pumpAndSettle();
      expect(find.text('New article'), findsWidgets);
      final title = tester.widget<TextField>(find.byKey(const ValueKey('help-edit-title')));
      expect(title.controller!.text, 'Can I ride a zebra?');
      await tester.enterText(find.byKey(const ValueKey('help-edit-answer')), 'No zebras, sorry.');
      await tester.tap(find.byKey(const ValueKey('help-edit-save')));
      await tester.pumpAndSettle();
      final a = repo.saved.single;
      expect((a.id, a.title, a.answer), ('', 'Can I ride a zebra?', 'No zebras, sorry.'));
      expect(a.questionVariants, ['Can I ride a zebra?']);
    });

    testWidgets('read-only access cannot change anything', (tester) async {
      final repo = _FakeRepo(articleList: articles, questions: questions);
      await pumpAdmin(tester, repo, edit: false);
      expect(find.textContaining('Read-only'), findsOneWidget);
      expect(find.byKey(const ValueKey('help-article-new')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('help-article-active-a1')));
      await tester.tap(find.text('How do I cancel a ride?'));
      await tester.pumpAndSettle();
      expect(find.text('Edit article'), findsNothing);
      expect(repo.activeSet, isEmpty);
      await tester.tap(find.text('Unanswered questions'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('help-question-create-q1')), findsNothing);
    });
  });
}
