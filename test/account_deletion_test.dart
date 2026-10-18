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

    testWidgets('an active account offers to link a previous one', (tester) async {
      await tester.pumpWidget(host({'id': 'new', 'phone': '+60100000194'}));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('link-previous-account')), findsOneWidget);
      expect(find.byKey(const ValueKey('account-deleted-card')), findsNothing);
    });
  });
}
