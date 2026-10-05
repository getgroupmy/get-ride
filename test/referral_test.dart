import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/referral.dart';
import 'package:get_ride/src/data/auth_repository.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/referral_repository.dart';
import 'package:get_ride/src/features/auth/set_pin_screen.dart';
import 'package:get_ride/src/features/profile/referral_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';

const _me = 'a1b2c3d4-e5f6-7890-abcd-ef0123456789';

class _FakeAuth implements AuthRepository {
  final pins = <String>[];

  @override
  Future<void> setPin(String pin) async => pins.add(pin);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeReferrals implements ReferralRepository {
  _FakeReferrals({this.result, this.referrer, this.count});
  final ApplyReferralResult? result;
  final MyReferrer? referrer;
  final int? count;
  final applied = <String>[];

  @override
  Future<ApplyReferralResult> apply(String code) async {
    applied.add(code);
    return result ?? const ApplyReferralResult(ok: true);
  }

  @override
  Future<MyReferrer?> myReferrer() async => referrer;

  @override
  Future<int?> myReferralCount() async => count;
}

void main() {
  group('rules', () {
    test('codes are letters and digits, upper-cased', () {
      expect(normalizeReferralCode(' ab-12 cd '), 'AB12CD');
      expect(isPlausibleReferralCode('ab1'), isFalse);
      expect(isPlausibleReferralCode('ab12'), isTrue);
    });

    test('the shared code is the explicit one, else the id prefix', () {
      expect(referralCodeFor(userId: _me), 'A1B2C3D4');
      expect(referralCodeFor(userId: _me, explicitCode: 'kabeer7'), 'KABEER7');
      expect(referralCodeFor(userId: _me, explicitCode: 'ab'), 'A1B2C3D4');
    });

    test('links carry the code and are read back', () {
      final link = referralLink('A1B2C3D4');
      expect(link, 'https://getride.my/?ref=A1B2C3D4');
      expect(referralCodeFromUri(Uri.parse(link)), 'A1B2C3D4');
      expect(referralCodeFromUri(Uri.parse('https://getride.my/?ref=ab')), isNull);
      expect(referralCodeFromUri(Uri.parse('https://getride.my/')), isNull);
      expect(referralMessage('A1B2C3D4', link), contains('A1B2C3D4'));
    });

    test('apply results and messages', () {
      final ok = ApplyReferralResult.fromRpc({'ok': true, 'referred_coins': 50, 'referrer_coins': '25'});
      expect(ok.ok, isTrue);
      expect(ok.referredCoins, 50);
      expect(ok.referrerCoins, 25);
      expect(applyReferralMessage(ok), contains('50 GC'));
      expect(applyReferralMessage(const ApplyReferralResult(ok: true)), 'Referral applied.');
      for (final e in ['code_not_found', 'self_referral', 'already_referred', 'disabled', 'weird']) {
        final r = ApplyReferralResult.fromRpc({'ok': false, 'error': e});
        expect(r.ok, isFalse);
        expect(applyReferralMessage(r), isNotEmpty);
      }
      expect(
        applyReferralMessage(ApplyReferralResult.fromRpc({'ok': false, 'error': 'self_referral'})),
        "You can't use your own referral code.",
      );
      expect(ApplyReferralResult.fromRpc(null).ok, isFalse);
    });

    test('referrer', () {
      expect(MyReferrer.fromRpc(null), isNull);
      final r = MyReferrer.fromRpc({'name': ' Aisyah ', 'code': 'A1B2C3D4'})!;
      expect(r.name, 'Aisyah');
      expect(MyReferrer.fromRpc({'name': '', 'code': null})!.name, isNull);
    });
  });

  group('screens', () {
    setUp(() => PendingReferral.code = null);

    Future<void> pumpSetPin(WidgetTester tester, _FakeAuth auth, _FakeReferrals referrals) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 1200);
      addTearDown(tester.view.reset);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('home')),
          ),
          GoRoute(path: '/set-pin', builder: (_, _) => const SetPinScreen()),
        ],
        initialLocation: '/set-pin',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authRepositoryProvider.overrideWithValue(auth),
            referralRepositoryProvider.overrideWithValue(referrals),
            profileProvider.overrideWith((ref) async => Profile({'id': _me, 'name': 'Ali'})),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> enterPin(WidgetTester tester) async {
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '123456');
      await tester.enterText(fields.at(1), '123456');
    }

    testWidgets('a code from the invite link is offered and applied after the PIN', (tester) async {
      PendingReferral.code = 'A1B2C3D4';
      final auth = _FakeAuth();
      final referrals = _FakeReferrals(result: const ApplyReferralResult(ok: true, referredCoins: 50));
      await pumpSetPin(tester, auth, referrals);
      expect(find.text('A1B2C3D4'), findsOneWidget);
      await enterPin(tester);
      await tester.tap(find.text('Save PIN'));
      await tester.pumpAndSettle();
      expect(auth.pins, ['123456']);
      expect(referrals.applied, ['A1B2C3D4']);
      expect(find.text('home'), findsOneWidget);
      expect(find.textContaining('Welcome bonus: 50 GC'), findsOneWidget);
      expect(PendingReferral.code, isNull);
    });

    testWidgets('no code, no referral call', (tester) async {
      final auth = _FakeAuth();
      final referrals = _FakeReferrals();
      await pumpSetPin(tester, auth, referrals);
      await enterPin(tester);
      await tester.tap(find.text('Save PIN'));
      await tester.pumpAndSettle();
      expect(auth.pins, ['123456']);
      expect(referrals.applied, isEmpty);
    });

    testWidgets('a refused code does not hold up sign-up', (tester) async {
      final auth = _FakeAuth();
      final referrals = _FakeReferrals(result: const ApplyReferralResult(ok: false, error: 'code_not_found'));
      await pumpSetPin(tester, auth, referrals);
      await enterPin(tester);
      await tester.enterText(find.byKey(const ValueKey('signup-referral')), 'zz99');
      await tester.tap(find.text('Save PIN'));
      await tester.pumpAndSettle();
      expect(referrals.applied, ['ZZ99']);
      expect(find.text('home'), findsOneWidget);
      expect(find.text("That referral code wasn't found."), findsOneWidget);
    });

    testWidgets('invite screen shows the code, the count and the inviter', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 1200);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            referralRepositoryProvider.overrideWithValue(
              _FakeReferrals(
                count: 3,
                referrer: const MyReferrer(name: 'Aisyah', code: 'F00DBEEF'),
              ),
            ),
            profileProvider.overrideWith((ref) async => Profile({'id': _me})),
          ],
          child: const MaterialApp(home: ReferralScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('A1B2C3D4'), findsOneWidget);
      expect(find.text('3 friends joined with your code'), findsOneWidget);
      expect(find.text('Invited by Aisyah'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('referral-copy-invite')));
      await tester.pump();
      expect(find.textContaining('Invite copied'), findsOneWidget);
    });
  });
}
