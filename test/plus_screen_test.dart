// GET.Plus for riders and Premium for drivers (migration 0316): the rider's
// GET.Plus page (join from GET.wallet, cancel, keep, receipts), the member
// banner and the booking card's member price and Premium rule line, and the
// driver's Premium status card, in light and dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/fare.dart' show RideService;
import 'package:get_ride/src/core/premium_plus.dart';
import 'package:get_ride/src/data/premium_plus_repository.dart';
import 'package:get_ride/src/features/partner/driver_services_screen.dart' show PremiumStatusCard;
import 'package:get_ride/src/features/ride/confirm_parts.dart' show ConfirmServiceCard;
import 'package:get_ride/src/features/ride/plus_parts.dart';
import 'package:get_ride/src/features/wallet/plus_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notice.dart';
import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

const _offer = {'on': true, 'price': 19.9, 'discountPct': 10, 'maxDiscount': 0, 'freeCancels': 2, 'priority': true,
  'graceDays': 3};

class _Repo extends PremiumPlusRepository {
  _Repo(this.membership, {this.balance = 50}) : super(_db);
  Map<String, dynamic>? membership;
  double balance;
  final joins = <double>[];
  final autoRenew = <bool>[];
  bool short = false;

  @override
  Future<PremiumPlusTerms> terms(PlusPlaceArgs at) async => PremiumPlusTerms.fromJson({
    'premium': {'on': true, 'maxCarAge': 5, 'modelsListed': true, 'minRating': 4.8},
    'plus': _offer,
    'membership': membership,
    'benefits': membership == null ? null : {'pct': 10, 'priority': true, 'freeCancels': 2, 'freeCancelsLeft': 1},
    'walletBalance': balance,
  });

  @override
  Future<double> join(PlusPlaceArgs at, {required double expected}) async {
    if (short) throw Exception('PostgrestException(message: insufficient_balance)');
    joins.add(expected);
    membership = {'status': 'active', 'live': true, 'autoRenew': true, 'periodEnd': '2026-11-28T00:00:00Z',
      'price': 19.9, 'freeCancelsUsed': 0};
    return expected;
  }

  @override
  Future<void> setAutoRenew(bool on) async {
    autoRenew.add(on);
    membership = {...?membership, 'autoRenew': on};
  }

  @override
  Future<List<PlusReceipt>> receipts() async => [
    PlusReceipt(id: 'c1', number: 12, kind: 'join', paid: true, amount: 19.9, createdAt: DateTime(2026, 10, 28),
        periodStart: DateTime(2026, 10, 28), periodEnd: DateTime(2026, 11, 28)),
  ];
}

Future<void> _pumpPage(WidgetTester tester, _Repo repo, {Brightness b = Brightness.light}) async {
  tester.view.physicalSize = const Size(400, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    retry: (_, _) => null,
    overrides: [
      ...quietLiveOverrides,
      premiumPlusRepositoryProvider.overrideWithValue(repo),
      plusPositionProvider.overrideWithValue(() async => null),
    ],
    child: MaterialApp(theme: appTheme(b), home: const PlusScreen()),
  ));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f.first);
  await tester.pumpAndSettle();
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

void main() {
  for (final b in Brightness.values) {
    testWidgets('a rider joins GET.Plus from GET.wallet (${b.name})', (tester) async {
      final repo = _Repo(null);
      await _pumpPage(tester, repo, b: b);
      expect(find.text('10% off your rides'), findsOneWidget);
      expect(find.text('Priority matching'), findsOneWidget);
      expect(find.text('2 free cancels a month'), findsOneWidget);
      expect(find.text('No GET.Plus payments yet.'), findsNothing, reason: 'a receipt is listed');
      expect(find.text('GP-000012 · Joined'), findsOneWidget);
      expect(find.textContaining('→'), findsNothing);

      await _tap(tester, find.byKey(const ValueKey('plus-join')));
      expect(find.text('Join GET.Plus?'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('plus-join-confirm')));
      await closeNotice(tester);
      expect(repo.joins, [19.9]);
      await tester.pumpAndSettle();
      expect(find.text('You\'re a GET.Plus member'), findsOneWidget);
      expect(find.byKey(const ValueKey('plus-cancel')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a short wallet: the notice says top up', (tester) async {
    final repo = _Repo(null, balance: 2)..short = true;
    await _pumpPage(tester, repo);
    await _tap(tester, find.byKey(const ValueKey('plus-join')));
    await _tap(tester, find.byKey(const ValueKey('plus-join-confirm')));
    await pumpNotice(tester);
    expect(find.text('Top up first'), findsOneWidget);
    expect(find.textContaining('Top up GET.wallet: GET.Plus is'), findsOneWidget);
    await closeNotice(tester);
  });

  testWidgets('a member cancels, then keeps it', (tester) async {
    final repo = _Repo({'status': 'active', 'live': true, 'autoRenew': true, 'periodEnd': '2026-11-28T00:00:00Z',
      'price': 19.9, 'freeCancelsUsed': 1});
    await _pumpPage(tester, repo);
    expect(find.textContaining('Renews on 28 Nov 2026'), findsOneWidget);
    expect(find.text('1 free cancel left this month.'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('plus-cancel')));
    expect(find.textContaining('You keep GET.Plus until 28 Nov 2026'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('plus-cancel-confirm')));
    expect(repo.autoRenew, [false]);
    expect(find.textContaining('Cancelled: GET.Plus stays until 28 Nov 2026'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('plus-keep')));
    await closeAnyNotice(tester);
    expect(repo.autoRenew, [false, true]);
  });

  testWidgets('payment due: pay now', (tester) async {
    await _pumpPage(tester, _Repo({'status': 'grace', 'live': true, 'autoRenew': true,
      'periodEnd': '2026-10-27T00:00:00Z', 'graceUntil': '2026-10-30T00:00:00Z', 'price': 19.9}));
    expect(find.textContaining('Top up GET.wallet by 30 Oct 2026'), findsOneWidget);
    expect(find.text('Pay RM19.90 now'), findsOneWidget);
    expect(find.byKey(const ValueKey('plus-cancel')), findsOneWidget);
  });

  for (final b in Brightness.values) {
    testWidgets('the booking card: member banner, member price, Premium rules (${b.name})', (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const premium = RideService('Premium', 'Executive cars', 1.5, 4, premium: true);
      await tester.pumpWidget(MaterialApp(
        theme: appTheme(b),
        home: Scaffold(
          body: Column(children: [
            const PlusMemberBanner(
              benefits: PlusBenefits(pct: 10, priority: true, freeCancels: 2, freeCancelsLeft: 2),
            ),
            ConfirmServiceCard(
              service: premium,
              price: 'RM20.79',
              was: 'RM23.10',
              note: premiumRuleLine(const PremiumTerms(maxCarAge: 5, modelsListed: true, minRating: 4.8)),
              selected: false,
              fixed: true,
              onTap: () {},
            ),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('GET.Plus member: 10% off, priority matching, 2 free cancels left this month'), findsOneWidget);
      expect(find.text('RM20.79'), findsOneWidget);
      final was = tester.widget<Text>(find.byKey(const ValueKey('service-was-Premium')));
      expect(was.data, 'RM23.10');
      expect(was.style?.decoration, TextDecoration.lineThrough);
      expect(find.text('Cars 5 years or newer, listed models, drivers rated 4.8+'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final b in Brightness.values) {
    testWidgets('the driver\'s Premium status (${b.name})', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: appTheme(b),
        home: const Scaffold(
          body: Column(children: [
            PremiumStatusCard(status: PremiumStatus(service: 'Premium', ok: false, reasons: [
              'Your car is 9 years old. Premium takes cars 5 years old or newer.',
              'You have 20 trips. Premium needs 200 or more.',
            ])),
            PremiumStatusCard(status: PremiumStatus(service: 'Executive', ok: true)),
          ]),
        ),
      ));
      expect(find.text('You don\'t qualify for Premium yet'), findsOneWidget);
      expect(find.text('• You have 20 trips. Premium needs 200 or more.'), findsOneWidget);
      expect(find.text('You can take Executive requests'), findsOneWidget);
    });
  }
}
