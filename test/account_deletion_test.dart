// Deleting your own account and the admin's linking (migration 0194): the
// pure rules, the Delete account page and the admin's section of a user.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_filters.dart';
import 'package:get_ride/src/admin/screens/people/account_deletion_section.dart';
import 'package:get_ride/src/core/account_deletion.dart';
import 'package:get_ride/src/data/account_deletion_repository.dart';
import 'package:get_ride/src/features/settings/delete_account_screen.dart';

void main() {
  group('rules', () {
    test('the check reads as the server sends it', () {
      final c = AccountDeletionCheck.fromJson({'activeRide': true, 'bookings': 2, 'retentionDays': 90});
      expect(c.activeRide, isTrue);
      expect(c.bookings, 2);
      expect(c.retentionDays, 90);
      expect(AccountDeletionCheck.fromJson(null).activeRide, isFalse);
    });

    test('the effects name the bookings, the freeze and the retention', () {
      final lines = accountDeletionEffects(const AccountDeletionCheck(bookings: 2, retentionDays: 90));
      expect(lines.first, contains('2 upcoming scheduled rides'));
      expect(lines.join(' '), contains('frozen'));
      expect(lines.last, contains('90 days'));
      expect(accountDeletionEffects(const AccountDeletionCheck()).join(' '), isNot(contains('scheduled')));
    });

    test("the server's answer as a sentence", () {
      expect(deleteAccountProblem({'ok': true}), isNull);
      expect(deleteAccountProblem({'error': 'wrong_pin'}), contains('Incorrect PIN'));
      expect(deleteAccountProblem({'error': 'active_ride'}), contains('Finish your ride'));
      expect(deleteAccountProblem({'error': 'confirm_needed'}), contains('PIN or an SMS code'));
      expect(deleteAccountProblem(null), contains("Couldn't"));
    });

    test('due for final deletion after the retention days, once', () {
      final now = DateTime(2026, 10, 14);
      final p = {'deleted_at': DateTime(2025, 10, 1).toUtc().toIso8601String()};
      expect(dueForFinalDeletion(p, 365, now), isTrue);
      expect(dueForFinalDeletion(p, 400, now), isFalse);
      expect(dueForFinalDeletion({...p, 'final_deleted_at': '2026-10-01'}, 365, now), isFalse);
      expect(dueForFinalDeletion(const {}, 365, now), isFalse);
      expect(userFilters['final-delete'], 'Due for final deletion');
    });

    test('linked parts and the event summary', () {
      final events = [
        const AccountEvent({'kind': 'deleted'}),
        const AccountEvent({
          'kind': 'linked',
          'categories': ['trips', 'wallet'],
        }),
      ];
      expect(linkedCategories(events), {'trips', 'wallet'});
      expect(events.last.summary, contains('Trips and receipts'));
      expect(events.first.summary, 'Deleted by the user');
      expect(AccountLinkCategory.byKey('partner'), AccountLinkCategory.partner);
      expect(serverRefusalText('ACCOUNT_LINK_DONE', 'Already linked: trips.'), 'Already linked: trips.');
      expect(serverRefusalText('boom', null), 'boom');
    });
  });

  group('Delete account page', () {
    Widget host(AccountDeletionCheck c, {ThemeData? theme}) => ProviderScope(
      overrides: [accountDeletionCheckProvider.overrideWith((_) async => c)],
      child: MaterialApp(theme: theme, home: const DeleteAccountScreen()),
    );

    testWidgets('lists what happens and offers to delete', (tester) async {
      await tester.pumpWidget(host(const AccountDeletionCheck(bookings: 1)));
      await tester.pumpAndSettle();
      expect(find.textContaining('upcoming scheduled ride is cancelled'), findsOneWidget);
      expect(find.byKey(const ValueKey('delete-active-ride')), findsNothing);
      final button = tester.widget<FilledButton>(find.byKey(const ValueKey('delete-continue')));
      expect(button.onPressed, isNotNull);
    });

    for (final dark in [false, true]) {
      testWidgets('on a 360x640 phone at large text the delete button is in view (${dark ? 'dark' : 'light'})',
          (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 640);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(size: Size(360, 640), textScaler: TextScaler.linear(1.3)),
            child: host(const AccountDeletionCheck(bookings: 2), theme: dark ? ThemeData.dark() : null),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final r = tester.getRect(find.byKey(const ValueKey('delete-continue')));
        expect(r.bottom, lessThanOrEqualTo(640), reason: 'pinned, not below the fold');
        expect(find.byKey(const ValueKey('delete-continue')).hitTestable(), findsOneWidget);
        // Scrolled to the end, the last of the page stands 16 or more clear
        // of the pinned bar.
        final scroll = find.byType(SingleChildScrollView).first;
        await tester.drag(scroll, const Offset(0, -2000));
        await tester.pumpAndSettle();
        final content = find.descendant(of: scroll, matching: find.byType(Column)).first;
        final bar = tester.getRect(
          find.ancestor(
            of: find.byKey(const ValueKey('delete-continue')),
            matching: find.byWidgetPredicate((w) => w is Material && w.elevation == 4),
          ),
        );
        expect(tester.getRect(content).bottom, lessThanOrEqualTo(bar.top - 16));
      });
    }

    for (final dark in [false, true]) {
      for (final keyboard in [0.0, 336.0]) {
        testWidgets('412x915 at 1.3x: the reason field is never under "Delete my account" '
            '(${dark ? 'dark' : 'light'}, ${keyboard > 0 ? 'keyboard up' : 'no keyboard'})', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(412, 915);
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(
                size: const Size(412, 915),
                textScaler: const TextScaler.linear(1.3),
                viewInsets: EdgeInsets.only(bottom: keyboard),
              ),
              child: host(const AccountDeletionCheck(bookings: 2), theme: dark ? ThemeData.dark() : null),
            ),
          );
          await tester.pumpAndSettle();
          final field = find.byKey(const ValueKey('delete-reason'));
          final scroll = find.byType(SingleChildScrollView).first;
          final viewport = tester.getRect(scroll);
          // Scrolled so that only the top of the field peeks out above the
          // bar, then tapped there, as a thumb would.
          final position = tester.state<ScrollableState>(
            find.descendant(of: scroll, matching: find.byType(Scrollable)).first,
          ).position;
          final peek = tester.getRect(field).top - (viewport.bottom - 24);
          position.jumpTo((position.pixels + peek).clamp(0.0, position.maxScrollExtent));
          await tester.pump();
          expect(tester.getRect(field).bottom, greaterThan(viewport.bottom), reason: 'cut off by the bar to start with');
          await tester.tapAt(Offset(tester.getRect(field).center.dx, viewport.bottom - 12));
          await tester.pumpAndSettle();
          final rect = tester.getRect(field);
          expect(rect.top, greaterThanOrEqualTo(viewport.top));
          expect(rect.bottom, lessThanOrEqualTo(viewport.bottom), reason: 'the whole field in view');
          expect(rect.bottom, lessThanOrEqualTo(915 - keyboard));
          if (keyboard == 0) {
            final bar = tester.getRect(find.ancestor(
              of: find.byKey(const ValueKey('delete-continue')),
              matching: find.byWidgetPredicate((w) => w is Material && w.elevation == 4),
            ));
            expect(viewport.bottom, lessThanOrEqualTo(bar.top), reason: 'the page ends where the bar begins');
            expect(rect.bottom, lessThanOrEqualTo(bar.top));
          }
          expect(tester.takeException(), isNull);
        });
      }
    }

    // Web round 40 (181): on its side the buttons share a row and the bar
    // leaves the page most of the height.
    for (final dark in [false, true]) {
      testWidgets('181: at 915x412 Keep beside Delete, a compact reason, more bullets (${dark ? 'dark' : 'light'})',
          (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(915, 412);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(host(const AccountDeletionCheck(bookings: 2), theme: dark ? ThemeData.dark() : null));
        await tester.pumpAndSettle();
        final delete = tester.getRect(find.byKey(const ValueKey('delete-continue')));
        final keep = tester.getRect(find.byKey(const ValueKey('delete-keep')));
        expect((delete.center.dy - keep.center.dy).abs(), lessThan(2), reason: 'one row');
        final bar = tester.getRect(find.ancestor(
          of: find.byKey(const ValueKey('delete-continue')),
          matching: find.byWidgetPredicate((w) => w is Material && w.elevation == 4),
        ));
        expect(bar.height, lessThan(412 * 0.25), reason: 'not 55% of the height');
        expect(tester.widget<TextField>(find.byKey(const ValueKey('delete-reason'))).maxLines, 1);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('not during a ride, in dark mode too', (tester) async {
      await tester.pumpWidget(host(const AccountDeletionCheck(activeRide: true), theme: ThemeData.dark()));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('delete-active-ride')), findsOneWidget);
      final button = tester.widget<FilledButton>(find.byKey(const ValueKey('delete-continue')));
      expect(button.onPressed, isNull);
    });
  });

  group("admin's section", () {
    Widget host(Map<String, dynamic> user, {List<AccountEvent> events = const [], ThemeData? theme}) => ProviderScope(
      overrides: [
        accountEventsProvider.overrideWith((_, _) async => events),
        accountRetentionDaysProvider.overrideWith((_) async => 365),
      ],
      child: MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SingleChildScrollView(child: AccountDeletionSection(user: user, canEdit: true)),
        ),
      ),
    );

    testWidgets('a deleted account past its days can be wiped', (tester) async {
      await tester.pumpWidget(
        host(
          {
            'id': 'old',
            'deleted_at': DateTime.now().subtract(const Duration(days: 400)).toUtc().toIso8601String(),
            'deleted_phone': '+60100000194',
            'deletion_reason': 'Moving away',
          },
          events: const [
            AccountEvent({'kind': 'deleted'}),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('account-deleted-card')), findsOneWidget);
      expect(find.textContaining('+60100000194'), findsOneWidget);
      expect(find.text('Deleted by the user'), findsWidgets);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('final-delete'))).onPressed, isNotNull);
      expect(find.byKey(const ValueKey('link-previous-account')), findsNothing);
    });

    testWidgets('not before its days, in dark mode', (tester) async {
      await tester.pumpWidget(
        host({
          'id': 'old',
          'deleted_at': DateTime.now().subtract(const Duration(days: 3)).toUtc().toIso8601String(),
        }, theme: ThemeData.dark()),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('final-delete'))).onPressed, isNull);
    });

    for (final b in Brightness.values) {
      testWidgets('173: Link previous account opens with its search focused (${b.name})', (tester) async {
        await tester.pumpWidget(ProviderScope(
          overrides: [
            accountEventsProvider.overrideWith((_, _) async => const []),
            accountRetentionDaysProvider.overrideWith((_) async => 365),
            accountDeletionRepositoryProvider.overrideWithValue(_NoDeleted()),
          ],
          child: MaterialApp(
            theme: ThemeData(brightness: b),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: AccountDeletionSection(user: {'id': 'new', 'phone': '+60100000194'}, canEdit: true),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('link-previous-account')));
        await tester.pumpAndSettle();
        final focused = FocusManager.instance.primaryFocus?.context;
        expect(focused, isNotNull);
        expect(find.descendant(of: find.byKey(const ValueKey('link-search')), matching: find.byWidget(focused!.widget)),
            findsOneWidget);
      });
    }

    testWidgets('an active account offers to link a previous one', (tester) async {
      await tester.pumpWidget(host({'id': 'new', 'phone': '+60100000194'}));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('link-previous-account')), findsOneWidget);
      expect(find.byKey(const ValueKey('account-deleted-card')), findsNothing);
    });
  });
}

class _NoDeleted implements AccountDeletionRepository {
  @override
  Future<List<Map<String, dynamic>>> deletedAccounts({String? phone, String? search}) async => const [];

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
