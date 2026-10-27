// Rider tags on the driver rating, admin side (0297): the tag lists and the
// flag rule in App Settings, and a driver's totals and flag in Partners.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/driver_rating_admin.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/ride_rating.dart';
import 'package:get_ride/src/data/ride_rating_repository.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notice.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _Repo extends DriverRatingAdminRepository {
  _Repo({this.driverData}) : super(_db);
  final AdminDriverTags? driverData;
  final savedTags = <DriverRatingTags>[];
  final savedRules = <DriverFlagRule>[];
  final reviewed = <(String, String)>[];

  @override
  Future<DriverRatingTags> tags() async => DriverRatingTags.fallback;
  @override
  Future<void> setTags(DriverRatingTags t) async => savedTags.add(t);
  @override
  Future<DriverFlagRule> rule() async => const DriverFlagRule();
  @override
  Future<void> setRule(DriverFlagRule r) async => savedRules.add(r);
  @override
  Future<AdminDriverTags> driver(String partnerUserId) async => driverData ?? const AdminDriverTags();
  @override
  Future<Map<String, List<String>>> flags() async => const {};
  @override
  Future<void> markReviewed(String partnerUserId, String tag) async => reviewed.add((partnerUserId, tag));
}

final _flagged = AdminDriverTags.fromJson({
  'times': 3,
  'days': 30,
  'rated': 9,
  'tags': [
    {'tag': 'Friendly', 'low': false, 'n': 5},
    {'tag': 'Unsafe driving', 'low': true, 'n': 3},
  ],
  'flags': [
    {'tag': 'Unsafe driving', 'n': 3},
  ],
});

Future<_Repo> _pump(WidgetTester tester, Brightness b, Widget child, {_Repo? repo}) async {
  final r = repo ?? _Repo();
  await tester.binding.setSurfaceSize(const Size(900, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        supabaseProvider.overrideWithValue(_db),
        driverRatingAdminRepositoryProvider.overrideWithValue(r),
        driverRatingTagsProvider.overrideWith((ref) async => DriverRatingTags.fallback),
      ],
      child: MaterialApp(
        theme: appTheme(b),
        home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return r;
}

void main() {
  group('rules', () {
    test('a new tag: typed, short, not already there', () {
      expect(driverTagProblem('  ', const []), 'Type a tag.');
      expect(driverTagProblem('x' * 41, const []), contains('40'));
      expect(driverTagProblem('rude', const ['Rude']), contains('already'));
      expect(driverTagProblem(' Smooth ride ', const ['Rude']), isNull);
    });

    test('the flag rule stays within its limits', () {
      const r = DriverFlagRule();
      expect(r.copyWith(times: 0).times, 1);
      expect(r.copyWith(times: 25).times, 20);
      expect(r.copyWith(days: 120).days, 90);
      expect(DriverFlagRule.fromRow(null), const DriverFlagRule(times: 3, days: 30));
      expect(DriverFlagRule.fromRow({'times': 5, 'days': 14}), const DriverFlagRule(times: 5, days: 14));
    });

    test('a driver\'s totals and flags, and the Partners list\'s flags', () {
      expect(_flagged.rule.days, 30);
      expect(_flagged.totals.rated, 9);
      expect(_flagged.flags.single, (tag: 'Unsafe driving', n: 3));
      expect(driverFlagText(_flagged.flags.single, _flagged.rule),
          'Unsafe driving picked 3 times in the last 30 days (limit 3).');
      expect(
        driverFlagsByPartner([
          {'partner_id': 'a1', 'tag': 'Rude', 'n': 4},
          {'partner_id': 'a1', 'tag': 'Unsafe driving', 'n': 3},
          {'partner_id': '', 'tag': 'Rude'},
        ]),
        {'a1': ['Rude', 'Unsafe driving']},
      );
    });
  });

  for (final b in Brightness.values) {
    group('App Settings card (${b.name})', () {
      testWidgets('remove and add tags, then save', (tester) async {
        final repo = await _pump(tester, b, const DriverRatingTagsCard(canEdit: true));
        final save = find.byKey(const ValueKey('driver-rating-tags-save'));
        expect(tester.widget<FilledButton>(find.descendant(of: save, matching: find.byType(FilledButton))).onPressed,
            isNull, reason: 'nothing changed yet');

        await tester.tap(find.byTooltip('Remove Rude'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('driver-rating-tag-low-Rude')), findsNothing);

        await tester.tap(find.byKey(const ValueKey('driver-rating-tag-add-high')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('driver-rating-tag-new')), 'friendly');
        await tester.tap(find.byKey(const ValueKey('driver-rating-tag-new-add')));
        await tester.pumpAndSettle();
        expect(find.text('"friendly" is already a tag.'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('driver-rating-tag-new')), 'Smooth ride');
        await tester.tap(find.byKey(const ValueKey('driver-rating-tag-new-add')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('driver-rating-tag-high-Smooth ride')), findsOneWidget);

        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(repo.savedTags.single.high.last, 'Smooth ride');
        expect(repo.savedTags.single.low, isNot(contains('Rude')));
        await closeNotice(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the flag rule: - and + then save', (tester) async {
        final repo = await _pump(tester, b, const DriverRatingTagsCard(canEdit: true));
        final more = find.byKey(const ValueKey('driver-flag-times-more'));
        await tester.ensureVisible(more);
        await tester.tap(more);
        await tester.tap(find.byKey(const ValueKey('driver-flag-days-less')));
        await tester.pumpAndSettle();
        expect(find.text('4'), findsOneWidget);
        expect(find.text('29'), findsOneWidget);
        expect(find.textContaining('The driver is not told'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('driver-flag-rule-save')));
        await tester.pumpAndSettle();
        expect(repo.savedRules.single, const DriverFlagRule(times: 4, days: 29));
        await closeNotice(tester);
      });

      testWidgets('read only: shown, nothing to change', (tester) async {
        await _pump(tester, b, const DriverRatingTagsCard(canEdit: false));
        expect(find.byKey(const ValueKey('driver-rating-tag-high-Friendly')), findsOneWidget);
        expect(find.byKey(const ValueKey('driver-rating-tags-save')), findsNothing);
        expect(find.byKey(const ValueKey('driver-rating-tag-add-low')), findsNothing);
        expect(find.byKey(const ValueKey('driver-flag-rule-save')), findsNothing);
        expect(find.byTooltip('Remove Rude'), findsNothing);
      });
    });

    group('Partners: a driver (${b.name})', () {
      testWidgets('flagged: the banner, the totals and Mark reviewed', (tester) async {
        final repo = await _pump(
          tester,
          b,
          const DriverRatingPanel(partnerUserId: 'a1', canEdit: true),
          repo: _Repo(driverData: _flagged),
        );
        expect(find.textContaining('Flagged: Unsafe driving.', findRichText: true), findsOneWidget);
        expect(find.textContaining('picked 3 times in the last 30 days (limit 3)', findRichText: true), findsOneWidget);
        expect(find.text('Tags from riders · 30 days'), findsOneWidget);
        expect(find.text('Friendly'), findsOneWidget);
        expect(find.text('From 9 rated trips.'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('driver-flag-review-Unsafe driving')));
        await tester.pumpAndSettle();
        expect(repo.reviewed.single, ('a1', 'Unsafe driving'));
        await closeNotice(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgets('not flagged, and read only', (tester) async {
        await _pump(tester, b, const DriverRatingPanel(partnerUserId: 'a1', canEdit: false));
        expect(find.byKey(const ValueKey('driver-not-flagged')), findsOneWidget);
        expect(find.text('No tags yet.'), findsOneWidget);
        await _pump(
          tester,
          b,
          const DriverRatingPanel(partnerUserId: 'a1', canEdit: false),
          repo: _Repo(driverData: _flagged),
        );
        expect(find.byKey(const ValueKey('driver-flag-Unsafe driving')), findsOneWidget);
        expect(find.byKey(const ValueKey('driver-flag-review-Unsafe driving')), findsNothing);
      });
    });
  }
}
