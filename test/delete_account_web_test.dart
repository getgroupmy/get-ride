// getride.my/delete-account (migration 0334): the page's words follow the
// server's days, never say whether a number has an account, and lay out at
// phone and desktop width, in light and dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_filters.dart';
import 'package:get_ride/src/admin/screens/people/account_deletion_section.dart';
import 'package:get_ride/src/core/account_deletion.dart';
import 'package:get_ride/src/core/account_deletion_web.dart';
import 'package:get_ride/src/data/account_deletion_repository.dart';
import 'package:get_ride/src/data/auth_repository.dart';
import 'package:get_ride/src/features/settings/delete_account_web_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/route_title.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

/// The deletion date the fake reports — always 7 days out, captured once so the
/// fake's value and the date the test asserts come from the same instant and
/// match the screen's own formatting. (A fixed calendar date here expired after
/// noon on that day and failed every run.)
final _deleteAfter = DateTime.now().add(const Duration(days: 7));
final _deleteAfterIso = _deleteAfter.toIso8601String();
const _monthsShort = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String get _deleteAfterLong => '${_deleteAfter.day} ${_monthsShort[_deleteAfter.month - 1]} ${_deleteAfter.year}';

/// The page's server calls, answered here.
class _FakeRepo extends AccountDeletionRepository {
  _FakeRepo({this.hasAccount = true}) : super(_db);
  final bool hasAccount;
  final codes = <String>[];
  final tries = <String>[];

  @override
  Future<AccountDeletionInfo> publicInfo() async =>
      const AccountDeletionInfo(retentionDays: 365, graceDays: 7, codeMinutes: 10);

  @override
  Future<void> requestCode(String phone) async => codes.add(phone);

  @override
  Future<Object?> confirmRequest(String phone, String code, {String? reason}) async {
    tries.add(code);
    if (!hasAccount || code != '123456') return {'error': 'wrong_code'};
    // Always 7 days out, so the "Request received" state (shown only when the
    // deletion date is still in the future) is reached whatever today is — a
    // fixed date here became a past date after noon and failed every run.
    return {'ok': true, 'graceDays': 7, 'deleteAfter': _deleteAfterIso};
  }
}

/// Sign-in for a number with no account: Auth refuses to send.
class _NoAccountAuth extends AuthRepository {
  _NoAccountAuth() : super(_db);
  var sent = 0;

  @override
  Future<void> sendOtp(String phone, {required bool createUser}) async {
    sent++;
    expect(createUser, isFalse, reason: 'the page never makes an account');
    throw const AuthException('Signups not allowed for otp');
  }

  @override
  Future<void> verifyOtp(String phone, String code) async =>
      throw const AuthException('Token has expired or is invalid');
}

ThemeData _theme(bool dark) => ThemeData(brightness: dark ? Brightness.dark : Brightness.light);

Widget _host(_FakeRepo repo, {bool dark = false, DeletionWay way = DeletionWay.signIn}) => ProviderScope(
  overrides: [accountDeletionRepositoryProvider.overrideWithValue(repo)],
  child: MaterialApp(
    theme: _theme(dark),
    home: DeleteAccountWebScreen(initialWay: way),
  ),
);

Future<void> _size(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Scrolls [key] into view, then taps it.
Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

void main() {
  group('rules', () {
    test('the server\'s days, with defaults', () {
      final i = AccountDeletionInfo.fromJson({'retentionDays': 90, 'graceDays': 3, 'codeMinutes': 10});
      expect(i.retentionDays, 90);
      expect(i.graceDays, 3);
      expect(AccountDeletionInfo.fromJson(null).graceDays, 7);
      expect(AccountDeletionInfo.fromJson(null).retentionDays, 365);
    });

    test('the sections say what is deleted, kept and for how long', () {
      final s = deletionPageSections(const AccountDeletionInfo(retentionDays: 90, graceDays: 3));
      expect(s.map((x) => x.title), [
        'What is deleted straight away',
        'What is wiped after 90 days',
        'What we keep and why',
        'How long',
      ]);
      final all = s.expand((x) => [x.intro ?? '', ...x.lines]).join(' ');
      expect(all, contains('Voice Protection recordings'));
      expect(all, contains('3 days to change your mind'));
      expect(all, contains('tax and financial record-keeping law'));
      // Periods the code doesn't set are left for the owner, and listed.
      for (final p in deletionPagePlaceholders) {
        expect(p, contains(ownerFill));
      }
      expect(all, contains(deletionPageFinancialPeriod));
      expect(all, isNot(contains('→')));
    });

    test('the retention statement names the days, what is kept, why, and the wipe', () {
      final all = deletionRetentionStatement(const AccountDeletionInfo(retentionDays: 365)).join(' ');
      expect(all, contains('closed and hidden at once'));
      expect(all, contains('keep the closed account for 365 days'));
      expect(all, contains('safety reports'));
      expect(all, contains('fraud'));
      expect(all, contains('disputes'));
      expect(all, contains('After 365 days your personal details are wiped from your account'));
      expect(deletionPageInAppPath, '/account/settings/delete');
    });

    test('no grace days: deleted straight away', () {
      expect(phoneRequestSteps(const AccountDeletionInfo(graceDays: 0)).last, contains('straight away'));
      expect(phoneRequestSteps(const AccountDeletionInfo(graceDays: 1)).last, contains('after 1 day.'));
    });

    test('a wrong code and a number with no account read the same', () {
      expect(deletionRequestProblem({'ok': true}), isNull);
      expect(deletionRequestProblem({'error': 'wrong_code'}), contains('wrong or has expired'));
      expect(deletionCodeSentText('+60123456789'), startsWith('If +60123456789 has a GET.ride account'));
      expect(deletionRequestDeleteAfter({'deleteAfter': '2026-11-09T04:00:00Z'}), isNotNull);
    });

    test('requests as the admin reads them', () {
      final r = AccountDeletionRequest({
        'id': 'r1',
        'user_id': 'u1',
        'status': 'in_grace',
        'method': 'phone_code',
        'grace_until': '2026-11-09T04:00:00Z',
      });
      expect(r.open, isTrue);
      expect(r.statusLabel, 'In grace');
      expect(r.methodLabel, 'Web, by phone code');
      expect(deletionRequestStatusLabel('expired'), 'Not confirmed');
      expect(
        deletionRequestedIds([
          r,
          const AccountDeletionRequest({'user_id': 'u2', 'status': 'deleted'}),
        ]),
        {'u1'},
      );
      expect(userFilters['deletion-requested'], 'Deletion requested');
      expect(const AccountEvent({'kind': 'deletion_requested'}).summary, contains('on the web'));
      expect(
        const AccountEvent({
          'kind': 'deletion_cancelled',
          'detail': {'why': 'signed_in'},
        }).summary,
        contains('signed in'),
      );
    });

    test('the browser tab names the page', () {
      expect(pageTitleFor('/delete-account'), contains('Delete your account'));
    });
  });

  group('the page', () {
    for (final dark in [false, true]) {
      for (final size in const [Size(360, 740), Size(1280, 900)]) {
        final label = '${size.width.toInt()} wide, ${dark ? 'dark' : 'light'}';
        testWidgets('names the app and maker, both ways, and every section ($label)', (tester) async {
          await _size(tester, size);
          await tester.pumpWidget(_host(_FakeRepo(), dark: dark));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Delete your GET.ride account'), findsOneWidget);
          expect(find.textContaining(deletionPageDeveloper), findsOneWidget);
          expect(find.byKey(const ValueKey('delete-way-sign-in')), findsOneWidget);
          expect(find.byKey(const ValueKey('delete-way-phone')), findsOneWidget);
          // Side by side on a desktop, one above the other on a phone.
          final a = tester.getTopLeft(find.byKey(const ValueKey('delete-way-sign-in')));
          final b = tester.getTopLeft(find.byKey(const ValueKey('delete-way-phone')));
          expect(a.dy == b.dy, size.width >= deletionWaysRowWidth);
          for (final title in ['What is deleted straight away', 'What we keep and why', 'How long']) {
            await tester.scrollUntilVisible(find.text(title), 200, scrollable: find.byType(Scrollable).first);
            expect(find.text(title), findsOneWidget);
          }
          expect(find.textContaining('365 days'), findsWidgets);
          // The owner's retention rule, plainly: closed and hidden at once, kept and why, then wiped.
          expect(find.byKey(const ValueKey('delete-web-retention')), findsOneWidget);
          expect(find.textContaining('closed and hidden at once'), findsOneWidget);
          expect(find.textContaining('tax and financial records'), findsWidgets);
          expect(find.byKey(const ValueKey('delete-web-in-app')), findsOneWidget);
          // The text reads on its background.
          final t = Theme.of(tester.element(find.text('How long')));
          expect(t.brightness, dark ? Brightness.dark : Brightness.light);
        });
      }
    }

    testWidgets('request by phone: the same words for every number, then the grace date', (tester) async {
      await _size(tester, const Size(360, 740));
      final repo = _FakeRepo();
      await tester.pumpWidget(_host(repo, way: DeletionWay.phone));
      await tester.pumpAndSettle();
      expect(find.textContaining('after 7 days'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('delete-web-phone')), '12 345 6789');
      await _tap(tester, 'delete-web-send');
      expect(repo.codes, ['+60123456789']);
      expect(find.text(deletionCodeSentText('+60123456789')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('delete-web-code')), '000000');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('delete-web-error')), findsOneWidget);
      expect(find.textContaining('wrong or has expired'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('delete-web-code')), '123456');
      await tester.pumpAndSettle();
      expect(find.text('Request received'), findsOneWidget);
      expect(find.textContaining(_deleteAfterLong), findsOneWidget);
    });

    testWidgets('a number with no account: the same words, the same wrong-code answer (dark)', (tester) async {
      await _size(tester, const Size(1280, 900));
      final repo = _FakeRepo(hasAccount: false);
      await tester.pumpWidget(_host(repo, dark: true, way: DeletionWay.phone));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('delete-web-phone')), '19 999 0000');
      await _tap(tester, 'delete-web-send');
      expect(find.text(deletionCodeSentText('+60199990000')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('delete-web-code')), '123456');
      await tester.pumpAndSettle();
      expect(find.textContaining('wrong or has expired'), findsOneWidget);
      expect(find.text('Request received'), findsNothing);
    });

    testWidgets('sign in and delete: Auth\'s refusal for a number with no account reads as a code sent', (
      tester,
    ) async {
      await _size(tester, const Size(360, 740));
      final auth = _NoAccountAuth();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountDeletionRepositoryProvider.overrideWithValue(_FakeRepo()),
            authRepositoryProvider.overrideWithValue(auth),
          ],
          child: MaterialApp(theme: _theme(false), home: const DeleteAccountWebScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('delete-web-phone')), '19 999 0000');
      await _tap(tester, 'delete-web-send');
      expect(auth.sent, 1);
      expect(find.text(deletionCodeSentText('+60199990000')), findsOneWidget);
      expect(find.byKey(const ValueKey('delete-web-error')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('delete-web-code')), '123456');
      await tester.pumpAndSettle();
      expect(find.textContaining('wrong or has expired'), findsOneWidget);
    });

    testWidgets('a number too short is refused before anything is sent', (tester) async {
      final repo = _FakeRepo();
      await tester.pumpWidget(_host(repo, way: DeletionWay.phone));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('delete-web-phone')), '12');
      await _tap(tester, 'delete-web-send');
      expect(repo.codes, isEmpty);
      expect(find.text('Enter your mobile number.'), findsOneWidget);
    });
  });

  group("admin's section", () {
    Widget host(List<AccountDeletionRequest> requests, {bool dark = false}) => ProviderScope(
      overrides: [
        accountEventsProvider.overrideWith((_, _) async => const []),
        accountRetentionDaysProvider.overrideWith((_) async => 365),
        accountDeletionGraceDaysProvider.overrideWith((_) async => 7),
        accountDeletionRequestsProvider.overrideWith((_, _) async => requests),
      ],
      child: MaterialApp(
        theme: _theme(dark),
        home: Scaffold(
          body: SingleChildScrollView(child: AccountDeletionSection(user: const {'id': 'u1'}, canEdit: true)),
        ),
      ),
    );

    for (final dark in [false, true]) {
      testWidgets('a request in grace can be cancelled; done ones show their status (${dark ? 'dark' : 'light'})', (
        tester,
      ) async {
        await tester.pumpWidget(
          host(const [
            AccountDeletionRequest({
              'id': 'r1',
              'user_id': 'u1',
              'status': 'in_grace',
              'method': 'phone_code',
              'grace_until': '2026-11-09T04:00:00Z',
              'reason': 'Moving away',
            }),
            AccountDeletionRequest({
              'id': 'r0',
              'user_id': 'u1',
              'status': 'cancelled',
              'method': 'phone_code',
              'cancel_reason': 'signed_in',
            }),
          ], dark: dark),
        );
        await tester.pumpAndSettle();
        expect(find.text('Deletion request: In grace'), findsOneWidget);
        expect(find.textContaining('Moving away'), findsOneWidget);
        expect(find.text('Deletion request: Cancelled'), findsOneWidget);
        expect(find.textContaining('The user signed in'), findsOneWidget);
        expect(find.byKey(const ValueKey('cancel-deletion-request')), findsOneWidget);
      });
    }
  });
}
