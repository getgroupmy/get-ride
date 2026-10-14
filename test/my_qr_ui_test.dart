// My QR's screens: the My QR page (one tab per kind, generate / expire /
// reuse with a lifetime, refusals), the universal scanner's routing, the
// result sheet for each kind of scanned code, GET.now's booking into
// createRequest(directQrToken:), the direct-booking searching banner, the
// driver's "Booked you directly" label and order, the menus, and the
// /q/<kind>/<token> landing — in light and dark, at 360 px and desktop.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/app.dart' show appTheme, routerProvider;
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/core/fare.dart' show RideService;
import 'package:get_ride/src/core/my_qr.dart';
import 'package:get_ride/src/core/my_ride.dart';
import 'package:get_ride/src/core/referral.dart';
import 'package:get_ride/src/core/region_pricing.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/core/wallet_qr.dart';
import 'package:get_ride/src/data/app_display_repository.dart';
import 'package:get_ride/src/data/coin_trade_repository.dart';
import 'package:get_ride/src/data/device_access.dart';
import 'package:get_ride/src/data/fare_coin_store.dart';
import 'package:get_ride/src/data/fare_tariff_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/my_qr_repository.dart';
import 'package:get_ride/src/data/my_ride_repository.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';
import 'package:get_ride/src/data/referral_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/route_estimate_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/auth/passkey_sign_in_button.dart';
import 'package:get_ride/src/features/auth/welcome_screen.dart';
import 'package:get_ride/src/features/meter/meter_auto_launch.dart';
import 'package:get_ride/src/features/my_qr/direct_booking.dart';
import 'package:get_ride/src/features/my_qr/my_qr_screen.dart';
import 'package:get_ride/src/features/my_qr/qr_link_screen.dart';
import 'package:get_ride/src/features/my_qr/qr_result_sheet.dart';
import 'package:get_ride/src/features/my_ride/my_ride_screen.dart';
import 'package:get_ride/src/features/my_ride/my_ride_settings.dart';
import 'package:get_ride/src/features/partner/direct_booking_badge.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/features/partner/request_sheet.dart';
import 'package:get_ride/src/features/ride/home_screen.dart';
import 'package:get_ride/src/features/ride/ride_tracking_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_qr_screens.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/image_share.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthClientOptions, SupabaseClient;

// ---- Fixtures -----------------------------------------------------------------------

const _tokRef = 'RRRRRRRRRRRRRRRRRRRRRR';
const _tokMe = 'MMMMMMMMMMMMMMMMMMMMMM';
const _tokNow = 'NNNNNNNNNNNNNNNNNNNNNN';
const _tokOld = 'OOOOOOOOOOOOOOOOOOOOAB';
final _now = DateTime.utc(2026, 10, 12, 9);

PersonalQr _qr(
  String id,
  QrKind kind,
  String token, {
  QrStatus status = QrStatus.active,
  Duration? expiresIn,
  bool reactivatable = false,
  DateTime? created,
}) => PersonalQr(
  id: id,
  kind: kind,
  token: token,
  status: status,
  createdAt: created ?? DateTime.utc(2026, 10, 1),
  lastActivatedAt: created ?? DateTime.utc(2026, 10, 1),
  expiresAt: expiresIn == null ? null : _now.add(expiresIn),
  revokedAt: status == QrStatus.revoked ? DateTime.utc(2026, 10, 5) : null,
  reactivatable: reactivatable,
);

const _ali = FavouriteDriver(
  driverId: 'd1',
  name: 'Ali',
  available: true,
  online: true,
  colour: 'White',
  make: 'Perodua',
  model: 'Bezza',
  plate: 'VAB 1234',
  rating: 4.8,
);

class _FakeQr implements MyQrRepository {
  _FakeQr([List<PersonalQr>? codes]) : list = codes ?? [];

  /// Null: a database without My QR.
  List<PersonalQr>? list;
  Completer<List<PersonalQr>?>? hold;
  MyQrResult? next;
  final generated = <(QrKind, QrTtl)>[];
  final expired = <String>[];
  final reactivated = <(String, QrTtl)>[];
  final resolutions = <String, QrResolution>{};
  final addedByQr = <String>[];
  AddFavouriteResult addResult = const FavouriteAdded(_ali);

  @override
  Future<List<PersonalQr>?> codes() async {
    if (hold != null) return hold!.future;
    return list == null ? null : [...list!];
  }

  MyQrResult _done(PersonalQr qr) {
    final r = next;
    if (r != null) return r;
    list = [
      qr,
      for (final c in list ?? const <PersonalQr>[])
        if (c.id != qr.id)
          c.kind == qr.kind && c.status == QrStatus.active
              ? _qr(c.id, c.kind, c.token, status: QrStatus.revoked, reactivatable: true)
              : c,
    ];
    return MyQrDone(qr);
  }

  @override
  Future<MyQrResult> generate(QrKind kind, {QrTtl ttl = QrTtl.never}) async {
    generated.add((kind, ttl));
    return _done(
      _qr(
        'new-${generated.length}',
        kind,
        'G${generated.length}GGGGGGGGGGGGGGGGGGGG',
        expiresIn: ttl.seconds == null ? null : Duration(seconds: ttl.seconds!),
        created: _now,
      ),
    );
  }

  @override
  Future<MyQrResult> expire(String id) async {
    expired.add(id);
    if (next != null) return next!;
    final c = list!.firstWhere((c) => c.id == id);
    list = [
      for (final x in list!) x.id == id ? _qr(c.id, c.kind, c.token, status: QrStatus.revoked, reactivatable: true) : x,
    ];
    return MyQrDone(list!.firstWhere((c) => c.id == id));
  }

  @override
  Future<MyQrResult> reactivate(String id, {QrTtl ttl = QrTtl.never}) async {
    reactivated.add((id, ttl));
    final c = list!.firstWhere((c) => c.id == id);
    return _done(_qr(c.id, c.kind, c.token, created: _now));
  }

  @override
  Future<QrResolution> resolve(String scanned) async => resolutions[scanned] ?? const QrUnknown();

  @override
  Future<AddFavouriteResult> addFavouriteByQr(String scanned) async {
    addedByQr.add(scanned);
    return addResult;
  }
}

class _FakeMyRide implements MyRideRepository {
  final codes = <String>[];
  final offers = <String>[];
  List<FavouriteDriver> list = [_ali];

  @override
  Future<List<FavouriteDriver>?> favourites({double? lat, double? lng}) async => [...list];

  @override
  Future<AddFavouriteResult> addByCode(String input) async {
    codes.add(input);
    return const FavouriteAdded(_ali);
  }

  @override
  Future<OfferToAllOutcome> offerToAll(String requestId) async {
    offers.add(requestId);
    return OfferToAllOutcome.opened;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeReferrals implements ReferralRepository {
  final applied = <String>[];
  ApplyReferralResult result = const ApplyReferralResult(ok: true, referredCoins: 20);

  @override
  Future<ApplyReferralResult> apply(String code) async {
    applied.add(code);
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

final _png = Uint8List.fromList(const [137, 80, 78, 71]);

class _MemoryStore extends MyRideSettingsStore {
  @override
  Future<MyRideSettings> load() async => const MyRideSettings();

  @override
  Future<void> save(MyRideSettings s) async {}
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester, [int frames = 8]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// What the fake camera "sees" when tapped.
String _seen = '';

/// The app around [initial]: My QR, the pages its actions go to, and every
/// repository faked.
Future<GoRouter> _app(
  WidgetTester tester, {
  required _FakeQr qr,
  String initial = '/account/my-qr',
  bool partner = false,
  String? user = 'me',
  Brightness brightness = Brightness.light,
  Size size = const Size(400, 900),
  _FakeMyRide? myRide,
  _FakeReferrals? referrals,
  List<Override> extra = const [],
}) async {
  _size(tester, size);
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('page /')),
      ),
      GoRoute(
        path: '/login',
        builder: (_, _) => const Scaffold(body: Text('page /login')),
      ),
      GoRoute(
        path: '/wallet/trade',
        builder: (_, s) => Scaffold(body: Text('trade ${s.uri.queryParameters['to']}')),
      ),
      GoRoute(path: '/account/my-qr', builder: (_, _) => const MyQrScreen()),
      GoRoute(path: '/scan-pay', builder: (_, _) => const ScanPayScreen()),
      GoRoute(
        path: '/q/:kind/:token',
        builder: (_, st) => QrLinkScreen(kind: st.pathParameters['kind']!, token: st.pathParameters['token']!),
      ),
      GoRoute(
        path: '/host',
        builder: (_, _) => Scaffold(
          body: Builder(
            builder: (c) => Column(
              children: [
                TextButton(
                  key: const ValueKey('open-me'),
                  onPressed: () => showQrResultSheet(c, const PersonalQrScan(QrKind.me, _tokMe)),
                  child: const Text('me'),
                ),
                TextButton(
                  key: const ValueKey('open-now'),
                  onPressed: () => showQrResultSheet(c, const PersonalQrScan(QrKind.now, _tokNow)),
                  child: const Text('now'),
                ),
                TextButton(
                  key: const ValueKey('open-ref'),
                  onPressed: () => showQrResultSheet(c, const PersonalQrScan(QrKind.referral, _tokRef)),
                  child: const Text('ref'),
                ),
                TextButton(
                  key: const ValueKey('open-add-driver'),
                  onPressed: () => showAddFavouriteSheet(c),
                  child: const Text('add'),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        currentUserIdProvider.overrideWithValue(user),
        partnerProvider.overrideWith((ref) async => partner ? Partner({'id': 'p1', 'status': 'approved'}) : null),
        profileProvider.overrideWith((ref) async => null),
        myQrRepositoryProvider.overrideWithValue(qr),
        myQrClockProvider.overrideWithValue(() => _now),
        myRideRepositoryProvider.overrideWithValue(myRide ?? _FakeMyRide()),
        myRideSettingsStoreProvider.overrideWithValue(_MemoryStore()),
        referralRepositoryProvider.overrideWithValue(referrals ?? _FakeReferrals()),
        qrPngRendererProvider.overrideWithValue((data, {color = Colors.black, caption}) async => _png),
        imageSharerProvider.overrideWithValue((i) async {}),
        scannerTorchProvider.overrideWithValue((_) async {}),
        myRideScanViewProvider.overrideWithValue(
          (controller, onCode) => Center(
            child: TextButton(
              key: const ValueKey('fake-camera'),
              onPressed: () => onCode(_seen),
              child: const Text('camera'),
            ),
          ),
        ),
        walletBalancesProvider.overrideWith((ref) async => const []),
        walletTxProvider.overrideWith((ref) async => const []),
        ...extra,
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: appTheme(Brightness.light),
        darkTheme: appTheme(Brightness.dark),
        themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      ),
    ),
  );
  await _settle(tester);
  return router;
}

Future<void> _pickLifetime(WidgetTester tester, QrTtl ttl) async {
  expect(find.byKey(const ValueKey('my-qr-lifetime')), findsOneWidget);
  await tester.tap(find.byKey(ValueKey('my-qr-ttl-${ttl.name}')));
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('my-qr-lifetime-confirm')));
  await _settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('rules', () {
    test('a rate-limited change says how long to wait', () {
      expect(
        myQrRefusedMessage(MyQrError.rateLimited, retryAfter: const Duration(seconds: 290)),
        'Too many changes. Try again in 5 minutes.',
      );
      expect(myQrRefusedMessage(MyQrError.rateLimited), MyQrError.rateLimited.message);
      expect(myQrRefusedMessage(MyQrError.notADriver), 'GET.me and GET.now codes are for drivers.');
    });

    test('history dates', () {
      final off = _qr('a', QrKind.me, _tokMe, status: QrStatus.revoked);
      expect(myQrHistoryDates(off), 'Made 1 Oct 2026 · Turned off 5 Oct 2026');
      final ran = PersonalQr(
        id: 'b',
        kind: QrKind.me,
        token: _tokMe,
        status: QrStatus.expired,
        createdAt: DateTime.utc(2026, 10, 1),
        expiresAt: DateTime.utc(2026, 10, 2),
      );
      expect(myQrHistoryDates(ran), 'Made 1 Oct 2026 · Expired 2 Oct 2026');
    });

    test('a pending QR link is taken once', () {
      PendingQrLink.path = qrLinkPath(QrKind.now, _tokNow);
      expect(PendingQrLink.take(), '/q/now/$_tokNow');
      expect(PendingQrLink.take(), isNull);
    });

    test('direct bookings come first, in order', () {
      RideRequest r(String id, [String? direct]) => RideRequest({'id': id, 'direct_driver_id': ?direct});
      final list = [r('a'), r('b', 'me'), r('c', 'other'), r('d', 'me')];
      expect([for (final x in pinDirectFirst(list, 'me')) x.id], ['b', 'd', 'a', 'c']);
      expect([for (final x in pinDirectFirst(list, null)) x.id], ['a', 'b', 'c', 'd']);
      expect(bookedMeDirectly(r('b', 'me'), 'me'), isTrue);
      expect(bookedMeDirectly(r('c', 'other'), 'me'), isFalse);
    });
  });

  group('menus', () {
    test('My QR is a default item of both menus, opening /my-qr', () {
      expect(myQrMenuItemId, 'my-qr');
      expect([for (final d in defaultUserMenuItems) d.$1], contains(myQrMenuItemId));
      expect([for (final d in defaultPartnerMenuItems) d.$1], contains(myQrMenuItemId));
      expect(defaultMenuRoutes['user']![myQrMenuItemId], '/my-qr');
      expect(defaultMenuRoutes['partner']![myQrMenuItemId], '/my-qr');
      expect(allAppRoutes, contains('/my-qr'));
    });
  });

  group('My QR page', () {
    testWidgets('loading shows the skeleton', (tester) async {
      final qr = _FakeQr()..hold = Completer();
      await _app(tester, qr: qr);
      expect(find.byKey(const ValueKey('loading-skeleton')), findsWidgets);
    });

    testWidgets('a database without My QR says it is not available yet', (tester) async {
      await _app(tester, qr: _FakeQr()..list = null, partner: true);
      expect(find.byKey(const ValueKey('my-qr-unavailable')), findsOneWidget);
      expect(find.text("My QR isn't available yet"), findsOneWidget);
      expect(find.byKey(const ValueKey('my-qr-tabs')), findsNothing);
    });

    testWidgets('a rider has only GET.Referral; generating asks for a lifetime', (tester) async {
      final qr = _FakeQr();
      await _app(tester, qr: qr);
      expect(find.byKey(const ValueKey('my-qr-tabs')), findsNothing);
      expect(find.byKey(const ValueKey('my-qr-empty-referral')), findsOneWidget);
      expect(find.text(QrKind.referral.description), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('my-qr-generate-referral')));
      await _settle(tester);
      // Never is picked to start with.
      final never = tester.widget<RadioGroup<QrTtl>>(find.byType(RadioGroup<QrTtl>));
      expect(never.groupValue, QrTtl.never);
      await _pickLifetime(tester, QrTtl.day);
      expect(qr.generated, [(QrKind.referral, QrTtl.day)]);
      expect(find.byKey(const ValueKey('my-qr-code-referral')), findsOneWidget);
      expect(find.text('Active · Expires in 24 h'), findsOneWidget);
      expect(find.text('Your new GET.Referral code is ready.'), findsOneWidget);
    });

    testWidgets('cancelling the lifetime makes nothing', (tester) async {
      final qr = _FakeQr();
      await _app(tester, qr: qr);
      await tester.tap(find.byKey(const ValueKey('my-qr-generate-referral')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('my-qr-lifetime-cancel')));
      await _settle(tester);
      expect(qr.generated, isEmpty);
    });

    testWidgets('a driver has three tabs; the active code with share and save', (tester) async {
      final qr = _FakeQr([
        _qr('r1', QrKind.referral, _tokRef, expiresIn: const Duration(hours: 3)),
        _qr('m1', QrKind.me, _tokMe),
      ]);
      await _app(tester, qr: qr, partner: true);
      for (final k in QrKind.values) {
        expect(find.byKey(ValueKey('my-qr-tab-${k.wire}')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('my-qr-code-referral')), findsOneWidget);
      expect(find.text('Active · Expires in 3 h'), findsOneWidget);
      expect(find.byKey(const ValueKey('my-qr-referral-share')), findsOneWidget);
      expect(find.byKey(const ValueKey('my-qr-referral-save')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('my-qr-tab-me')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('my-qr-code-me')), findsOneWidget);
      expect(find.text('Active · Never expires'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('my-qr-tab-now')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('my-qr-empty-now')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the QR encodes the code\'s web link', (tester) async {
      await _app(tester, qr: _FakeQr([_qr('r1', QrKind.referral, _tokRef)]));
      final container = ProviderScope.containerOf(tester.element(find.byType(MyQrScreen)));
      expect(container.read(myQrCodesProvider).value!.single.payload, 'https://qr.getride.my/ref/$_tokRef');
    });

    testWidgets('Expire now asks first, then expires it', (tester) async {
      final qr = _FakeQr([_qr('r1', QrKind.referral, _tokRef)]);
      await _app(tester, qr: qr);
      await tester.ensureVisible(find.byKey(const ValueKey('my-qr-expire-referral')));
      await tester.tap(find.byKey(const ValueKey('my-qr-expire-referral')));
      await _settle(tester);
      expect(find.text('Expire your GET.Referral code?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('my-qr-expire-cancel')));
      await _settle(tester);
      expect(qr.expired, isEmpty);
      await tester.tap(find.byKey(const ValueKey('my-qr-expire-referral')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('my-qr-expire-confirm')));
      await _settle(tester);
      expect(qr.expired, ['r1']);
      expect(find.byKey(const ValueKey('my-qr-empty-referral')), findsOneWidget);
      expect(find.byKey(const ValueKey('my-qr-history-r1')), findsOneWidget);
    });

    testWidgets('Generate new warns that it replaces the current code', (tester) async {
      final qr = _FakeQr([_qr('r1', QrKind.referral, _tokRef)]);
      await _app(tester, qr: qr);
      await tester.ensureVisible(find.byKey(const ValueKey('my-qr-regenerate-referral')));
      await tester.tap(find.byKey(const ValueKey('my-qr-regenerate-referral')));
      await _settle(tester);
      expect(find.text('Your current GET.Referral code will stop working.'), findsOneWidget);
      await _pickLifetime(tester, QrTtl.hour);
      expect(qr.generated, [(QrKind.referral, QrTtl.hour)]);
      expect(find.text('Active · Expires in 1 h'), findsOneWidget);
      // The replaced one is in the history, ready to reuse.
      expect(find.byKey(const ValueKey('my-qr-reuse-r1')), findsOneWidget);
    });

    testWidgets('history lists earlier codes; Reuse warns and replaces the current one', (tester) async {
      final qr = _FakeQr([
        _qr('m1', QrKind.me, _tokMe),
        _qr('m0', QrKind.me, _tokOld, status: QrStatus.revoked, reactivatable: true),
        _qr('mx', QrKind.me, 'XXXXXXXXXXXXXXXXXXXXXX', status: QrStatus.expired),
      ]);
      await _app(tester, qr: qr, partner: true, size: const Size(400, 1400));
      await tester.tap(find.byKey(const ValueKey('my-qr-tab-me')));
      await _settle(tester);
      expect(find.text('Earlier codes'), findsOneWidget);
      expect(find.text('Code …OOAB'), findsOneWidget);
      expect(find.text('Turned off · Made 1 Oct 2026 · Turned off 5 Oct 2026'), findsOneWidget);
      expect(find.byKey(const ValueKey('my-qr-reuse-m0')), findsOneWidget);
      expect(find.byKey(const ValueKey('my-qr-reuse-mx')), findsNothing, reason: 'not reactivatable');
      await tester.ensureVisible(find.byKey(const ValueKey('my-qr-reuse-m0')));
      await tester.tap(find.byKey(const ValueKey('my-qr-reuse-m0')));
      await _settle(tester);
      expect(find.text('This will expire your current GET.me code.'), findsOneWidget);
      await _pickLifetime(tester, QrTtl.week);
      expect(qr.reactivated, [('m0', QrTtl.week)]);
      final codes = qr.list!;
      expect(activeQr(codes, QrKind.me, _now)!.id, 'm0');
      expect(find.byKey(const ValueKey('my-qr-history-m1')), findsOneWidget, reason: 'the old active one');
    });

    testWidgets('reusing with no active code has no warning', (tester) async {
      final qr = _FakeQr([_qr('r0', QrKind.referral, _tokOld, status: QrStatus.revoked, reactivatable: true)]);
      await _app(tester, qr: qr);
      await tester.ensureVisible(find.byKey(const ValueKey('my-qr-reuse-r0')));
      await tester.tap(find.byKey(const ValueKey('my-qr-reuse-r0')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('my-qr-lifetime-warning')), findsNothing);
      await _pickLifetime(tester, QrTtl.never);
      expect(qr.reactivated, [('r0', QrTtl.never)]);
    });

    testWidgets('a refusal shows its message', (tester) async {
      final qr = _FakeQr()..next = const MyQrRefused(MyQrError.notADriver);
      await _app(tester, qr: qr, partner: true);
      await tester.tap(find.byKey(const ValueKey('my-qr-tab-me')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('my-qr-generate-me')));
      await _settle(tester);
      await _pickLifetime(tester, QrTtl.never);
      expect(find.text('GET.me and GET.now codes are for drivers.'), findsOneWidget);
    });

    testWidgets('rate limited shows the wait', (tester) async {
      final qr = _FakeQr()..next = const MyQrRefused(MyQrError.rateLimited, retryAfter: Duration(seconds: 120));
      await _app(tester, qr: qr);
      await tester.tap(find.byKey(const ValueKey('my-qr-generate-referral')));
      await _settle(tester);
      await _pickLifetime(tester, QrTtl.never);
      expect(find.text('Too many changes. Try again in 2 minutes.'), findsOneWidget);
    });

    testWidgets('My QR going away mid-change says so', (tester) async {
      final qr = _FakeQr()..next = const MyQrNotAvailable();
      await _app(tester, qr: qr);
      await tester.tap(find.byKey(const ValueKey('my-qr-generate-referral')));
      await _settle(tester);
      await _pickLifetime(tester, QrTtl.never);
      expect(find.text(myQrUnavailableMessage), findsOneWidget);
    });

    testWidgets('pull to refresh reads the codes again', (tester) async {
      final qr = _FakeQr();
      await _app(tester, qr: qr);
      qr.list = [_qr('r1', QrKind.referral, _tokRef)];
      await tester.fling(find.byKey(const ValueKey('my-qr-list-referral')), const Offset(0, 400), 1000);
      await tester.pump();
      await _settle(tester, 12);
      expect(find.byKey(const ValueKey('my-qr-code-referral')), findsOneWidget);
    });

    for (final b in Brightness.values) {
      for (final size in const [Size(360, 780), Size(1400, 900)]) {
        testWidgets('${b.name} at ${size.width.round()} px', (tester) async {
          final qr = _FakeQr([
            _qr('r1', QrKind.referral, _tokRef, expiresIn: const Duration(days: 3)),
            _qr('r0', QrKind.referral, _tokOld, status: QrStatus.revoked, reactivatable: true),
          ]);
          await _app(tester, qr: qr, partner: true, brightness: b, size: size);
          expect(find.byKey(const ValueKey('my-qr-code-referral')), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('my-qr-tab-now')));
          await _settle(tester);
          expect(find.byKey(const ValueKey('my-qr-empty-now')), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('my-qr-generate-now')));
          await _settle(tester);
          expect(find.byKey(const ValueKey('my-qr-lifetime')), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('the scanner', () {
    Future<void> scan(WidgetTester tester, String text) async {
      _seen = text;
      await tester.tap(find.byKey(const ValueKey('my-qr-scan')));
      await _settle(tester);
      expect(find.text('Scan a GET code'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fake-camera')));
      await _settle(tester, 12);
    }

    testWidgets('a GET.now code opens its sheet', (tester) async {
      final qr = _FakeQr()..resolutions[_tokNow] = const QrActive(kind: QrKind.now, driver: _ali, online: true);
      await _app(tester, qr: qr);
      await scan(tester, qrPayload(QrKind.now, _tokNow));
      expect(find.byKey(const ValueKey('qr-result-now')), findsOneWidget);
    });

    testWidgets('a My Ride code opens Add driver with it', (tester) async {
      final myRide = _FakeMyRide();
      await _app(tester, qr: _FakeQr(), myRide: myRide);
      await scan(tester, '${myRideQrPrefix}ABCD2345');
      expect(myRide.codes, ['ABCD2345']);
      expect(find.byKey(const ValueKey('favourite-added')), findsOneWidget);
    });

    testWidgets('a wallet code opens the transfer', (tester) async {
      await _app(tester, qr: _FakeQr());
      await scan(tester, walletQrPayload('5b1f2c3d-1111-4222-8333-944455556666'));
      expect(find.text('trade 5b1f2c3d-1111-4222-8333-944455556666'), findsOneWidget);
    });

    testWidgets('an invite link offers its referral code', (tester) async {
      final refs = _FakeReferrals();
      await _app(tester, qr: _FakeQr(), referrals: refs);
      await scan(tester, 'https://getride.my/?ref=ABCD1234');
      expect(find.byKey(const ValueKey('qr-result-referral')), findsOneWidget);
      expect(find.text('ABCD1234'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('qr-referral-apply')));
      await _settle(tester);
      expect(refs.applied, ['ABCD1234']);
    });

    testWidgets('anything else is not a GET code', (tester) async {
      await _app(tester, qr: _FakeQr());
      await scan(tester, 'hello there');
      expect(find.text("That isn't a GET.ride code."), findsOneWidget);
      expect(find.text('Scan a GET code'), findsOneWidget, reason: 'still scanning');
    });

    testWidgets('My Ride\'s Add driver scan opens a GET.me code\'s sheet', (tester) async {
      final qr = _FakeQr()..resolutions[_tokMe] = const QrActive(kind: QrKind.me, driver: _ali);
      await _app(tester, qr: qr, initial: '/host');
      await tester.tap(find.byKey(const ValueKey('open-add-driver')));
      await _settle(tester);
      _seen = qrPayload(QrKind.me, _tokMe);
      await tester.tap(find.byKey(const ValueKey('favourite-scan')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('fake-camera')));
      await _settle(tester, 12);
      expect(find.byKey(const ValueKey('favourite-code')), findsNothing, reason: 'the add sheet closed');
      expect(find.byKey(const ValueKey('qr-result-me')), findsOneWidget);
    });

    testWidgets('Scan & Pay opens a personal code\'s sheet', (tester) async {
      final qr = _FakeQr()..resolutions[_tokNow] = const QrActive(kind: QrKind.now, driver: _ali, online: true);
      await _app(tester, qr: qr, initial: '/scan-pay', size: const Size(800, 1600));
      await tester.enterText(find.byKey(const ValueKey('scan-manual')), qrPayload(QrKind.now, _tokNow));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settle(tester, 12);
      expect(find.byKey(const ValueKey('qr-result-now')), findsOneWidget);
    });
  });

  group('the result sheet', () {
    Future<_FakeQr> open(
      WidgetTester tester,
      String key,
      String token,
      QrResolution r, {
      String? user = 'me',
      Brightness brightness = Brightness.light,
      Size size = const Size(400, 900),
      _FakeReferrals? referrals,
    }) async {
      final qr = _FakeQr()..resolutions[token] = r;
      await _app(
        tester,
        qr: qr,
        initial: '/host',
        user: user,
        brightness: brightness,
        size: size,
        referrals: referrals,
      );
      await tester.tap(find.byKey(ValueKey(key)));
      await _settle(tester);
      return qr;
    }

    testWidgets('GET.Referral: the masked owner and code, applied signed in', (tester) async {
      final refs = _FakeReferrals();
      await open(
        tester,
        'open-ref',
        _tokRef,
        const QrActive(kind: QrKind.referral, referralCode: 'ABCD1234', ownerName: 'Ahmad A.'),
        referrals: refs,
      );
      expect(find.text('Ahmad A. invited you to GET.ride'), findsOneWidget);
      expect(find.text('ABCD1234'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('qr-referral-apply')));
      await _settle(tester);
      expect(refs.applied, ['ABCD1234']);
      expect(find.textContaining('Referral applied.'), findsOneWidget);
    });

    testWidgets('GET.Referral: a refusal is shown', (tester) async {
      final refs = _FakeReferrals()..result = const ApplyReferralResult(ok: false, error: 'not_new_account');
      await open(
        tester,
        'open-ref',
        _tokRef,
        const QrActive(kind: QrKind.referral, referralCode: 'ABCD1234'),
        referrals: refs,
      );
      await tester.tap(find.byKey(const ValueKey('qr-referral-apply')));
      await _settle(tester);
      expect(find.text('Referral codes can only be used when an account is new.'), findsOneWidget);
    });

    testWidgets('GET.Referral: own code', (tester) async {
      await open(
        tester,
        'open-ref',
        _tokRef,
        const QrActive(kind: QrKind.referral, referralCode: 'ABCD1234', own: true),
      );
      expect(find.text('This is your own referral code.'), findsOneWidget);
      expect(find.byKey(const ValueKey('qr-referral-apply')), findsNothing);
    });

    testWidgets('GET.Referral signed out: sign up with the code', (tester) async {
      PendingReferral.code = null;
      await open(
        tester,
        'open-ref',
        _tokRef,
        const QrActive(kind: QrKind.referral, referralCode: 'ABCD1234'),
        user: null,
      );
      await tester.tap(find.byKey(const ValueKey('qr-referral-signup')));
      await _settle(tester);
      expect(PendingReferral.code, 'ABCD1234');
      expect(find.text('page /login'), findsOneWidget);
      PendingReferral.code = null;
    });

    testWidgets('GET.me: add to My Ride', (tester) async {
      final qr = await open(tester, 'open-me', _tokMe, const QrActive(kind: QrKind.me, driver: _ali));
      expect(find.text('Ali'), findsOneWidget);
      expect(find.text('White Perodua Bezza · VAB 1234'), findsOneWidget);
      expect(find.text('4.8'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('qr-me-add')));
      await _settle(tester);
      expect(qr.addedByQr, [_tokMe]);
      expect(find.byKey(const ValueKey('qr-me-added')), findsOneWidget);
    });

    testWidgets('GET.me: already a favourite', (tester) async {
      await open(tester, 'open-me', _tokMe, const QrActive(kind: QrKind.me, driver: _ali, alreadyFavourite: true));
      expect(find.text('Already in My Ride'), findsOneWidget);
      final b = tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('qr-me-add')));
      expect(b.onPressed, isNull);
    });

    testWidgets('GET.me: a refusal is explained', (tester) async {
      final qr = _FakeQr()
        ..resolutions[_tokMe] = const QrActive(kind: QrKind.me, driver: _ali)
        ..addResult = const FavouriteNotAdded(AddFavouriteError.limitReached);
      await _app(tester, qr: qr, initial: '/host');
      await tester.tap(find.byKey(const ValueKey('open-me')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('qr-me-add')));
      await _settle(tester);
      expect(find.text(AddFavouriteError.limitReached.message), findsOneWidget);
    });

    testWidgets('GET.me: unavailable and own', (tester) async {
      await open(tester, 'open-me', _tokMe, const QrActive(kind: QrKind.me, driver: _ali, available: false));
      expect(find.byKey(const ValueKey('qr-unavailable')), findsOneWidget);
      expect(find.text("Ali can't be added to My Ride right now."), findsOneWidget);
    });

    testWidgets('GET.me: own code', (tester) async {
      await open(tester, 'open-me', _tokMe, const QrActive(kind: QrKind.me, driver: _ali, own: true));
      expect(find.text('This is your own GET.me code.'), findsOneWidget);
    });

    testWidgets('GET.now: the driver, online, and Book this driver', (tester) async {
      await open(tester, 'open-now', _tokNow, const QrActive(kind: QrKind.now, driver: _ali, online: true));
      expect(find.text('Online'), findsOneWidget);
      final container = ProviderScope.containerOf(tester.element(find.byKey(const ValueKey('qr-now-book'))));
      await tester.tap(find.byKey(const ValueKey('qr-now-book')));
      await _settle(tester);
      expect(find.text('page /'), findsOneWidget);
      final booking = container.read(directBookingProvider);
      expect(booking?.token, _tokNow);
      expect(booking?.driverName, 'Ali');
      expect(find.text('Choose your pickup and destination to book Ali.'), findsOneWidget);
    });

    testWidgets('GET.now: own and unavailable codes cannot be booked', (tester) async {
      await open(tester, 'open-now', _tokNow, const QrActive(kind: QrKind.now, driver: _ali, own: true));
      expect(find.text('This is your own GET.now code.'), findsOneWidget);
      final b = tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('qr-now-book')));
      expect(b.onPressed, isNull);
    });

    testWidgets('GET.now: unavailable driver', (tester) async {
      await open(tester, 'open-now', _tokNow, const QrActive(kind: QrKind.now, driver: _ali, available: false));
      expect(find.text("Ali can't take rides right now."), findsOneWidget);
    });

    testWidgets('expired', (tester) async {
      await open(tester, 'open-now', _tokNow, const QrExpired());
      expect(find.text('This code has expired. Ask for a new one.'), findsOneWidget);
    });

    testWidgets('unknown', (tester) async {
      await open(tester, 'open-now', _tokNow, const QrUnknown());
      expect(find.text("This code isn't a GET.ride code."), findsOneWidget);
    });

    testWidgets('rate limited, with the wait', (tester) async {
      await open(tester, 'open-now', _tokNow, const QrRateLimited(Duration(seconds: 120)));
      expect(find.text('Too many codes tried. Try again in 2 minutes.'), findsOneWidget);
    });

    testWidgets('sign-in required: sign in, then back to the code', (tester) async {
      PendingQrLink.path = null;
      await open(tester, 'open-now', _tokNow, const QrSignInRequired(QrKind.now), user: null);
      expect(find.text('Sign in to book this driver.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('qr-sign-in')));
      await _settle(tester);
      expect(find.text('page /login'), findsOneWidget);
      expect(PendingQrLink.take(), '/q/now/$_tokNow');
    });

    for (final b in Brightness.values) {
      for (final size in const [Size(360, 780), Size(1400, 900)]) {
        testWidgets('${b.name} at ${size.width.round()} px', (tester) async {
          await open(
            tester,
            'open-now',
            _tokNow,
            const QrActive(kind: QrKind.now, driver: _ali, online: false),
            brightness: b,
            size: size,
          );
          expect(find.byKey(const ValueKey('qr-offline')), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('the /q/ link', () {
    testWidgets('signed out, a GET.Referral link leads to sign-up with its code', (tester) async {
      PendingReferral.code = null;
      final qr = _FakeQr()..resolutions[_tokRef] = const QrActive(kind: QrKind.referral, referralCode: 'WXYZ5678');
      await _app(tester, qr: qr, user: null, initial: '/q/ref/$_tokRef');
      expect(find.text('WXYZ5678'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('qr-referral-signup')));
      await _settle(tester);
      expect(PendingReferral.code, 'WXYZ5678');
      expect(find.text('page /login'), findsOneWidget);
      PendingReferral.code = null;
    });

    testWidgets('signed in, a GET.me link shows the driver', (tester) async {
      final qr = _FakeQr()..resolutions[_tokMe] = const QrActive(kind: QrKind.me, driver: _ali);
      await _app(tester, qr: qr, initial: '/q/me/$_tokMe', brightness: Brightness.dark, size: const Size(360, 780));
      expect(find.byKey(const ValueKey('qr-result-me')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a broken link says so', (tester) async {
      await _app(tester, qr: _FakeQr(), initial: '/q/zz/short');
      expect(find.byKey(const ValueKey('qr-link-invalid')), findsOneWidget);
    });
  });

  // The app's own router, signed out: what a phone camera opening the app on
  // https://qr.getride.my/<kind>/<token> (or a getride:// link) lands on.
  group('app links through the app router', () {
    Future<GoRouter> realRouter(WidgetTester tester, _FakeQr qr) async {
      _size(tester, const Size(400, 900));
      final db = SupabaseClient(
        'http://localhost',
        'anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          supabaseProvider.overrideWithValue(db),
          deviceBlockedProvider.overrideWith((ref) async => false),
          appDisplayProvider.overrideWith((ref) async => const AppDisplay()),
          passkeyOfferedHereProvider.overrideWith((ref) async => false),
          currentUserIdProvider.overrideWithValue(null),
          partnerProvider.overrideWith((ref) async => null),
          profileProvider.overrideWith((ref) async => null),
          myQrRepositoryProvider.overrideWithValue(qr),
          myQrClockProvider.overrideWithValue(() => _now),
          referralRepositoryProvider.overrideWithValue(_FakeReferrals()),
        ],
      );
      addTearDown(container.dispose);
      final r = container.read(routerProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: r),
        ),
      );
      await _settle(tester);
      return r;
    }

    for (final (label, link) in [
      ('/ref/<token>', '/ref/$_tokRef'),
      ('https://qr.getride.my/ref/<token>', 'https://qr.getride.my/ref/$_tokRef'),
      ('getride://ref/<token>', 'getride://ref/$_tokRef'),
      ('/q/ref/<token>', '/q/ref/$_tokRef'),
    ]) {
      testWidgets('$label opens the code signed out', (tester) async {
        final qr = _FakeQr()..resolutions[_tokRef] = const QrActive(kind: QrKind.referral, referralCode: 'WXYZ5678');
        final r = await realRouter(tester, qr);
        r.go(link);
        await _settle(tester);
        expect(find.byType(QrLinkScreen), findsOneWidget);
        expect(find.byType(WelcomeScreen), findsNothing);
        expect(find.text('WXYZ5678'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a short link with a broken token says so', (tester) async {
      final r = await realRouter(tester, _FakeQr());
      r.go('/now/short');
      await _settle(tester);
      expect(find.byKey(const ValueKey('qr-link-invalid')), findsOneWidget);
    });

    testWidgets('a driver\'s short link asks to sign in, then comes back', (tester) async {
      PendingQrLink.path = null;
      final qr = _FakeQr()..resolutions[_tokNow] = const QrSignInRequired(QrKind.now);
      final r = await realRouter(tester, qr);
      r.go('/now/$_tokNow');
      await _settle(tester);
      expect(find.byType(QrLinkScreen), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('qr-sign-in')));
      await _settle(tester);
      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(PendingQrLink.take(), '/q/now/$_tokNow');
    });

    testWidgets('other paths still need signing in', (tester) async {
      final r = await realRouter(tester, _FakeQr());
      r.go('/now');
      await _settle(tester);
      expect(find.byType(WelcomeScreen), findsOneWidget);
    });
  });

  group('booking a driver directly', () {
    testWidgets('the confirm step books with the code and no My Ride targets', (tester) async {
      final rides = _Rides();
      final container = await _home(tester, rides);
      container.read(directBookingProvider.notifier).set(const DirectBooking(token: _tokNow, driver: _ali));
      await _settle(tester);
      expect(find.byKey(const ValueKey('direct-booking-row')), findsOneWidget);
      expect(find.text('Booking Ali directly'), findsOneWidget);
      expect(find.byKey(const ValueKey('my-ride-row')), findsNothing);
      expect(find.text('Book Ali'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('book')));
      await _settle(tester, 10);
      expect(rides.created![#directQrToken], _tokNow);
      expect(rides.created![#targetDriverIds], isEmpty);
      expect(container.read(directBookingProvider), isNull);
      expect(container.read(directBookingNamesProvider)['r9'], 'Ali');
    });

    testWidgets('a refused code says why and drops the direct booking', (tester) async {
      final rides = _Rides()..fail = const QrBookingError(QrBookingFailure.expired);
      final container = await _home(tester, rides);
      container.read(directBookingProvider.notifier).set(const DirectBooking(token: _tokNow, driver: _ali));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('book')));
      await _settle(tester, 10);
      expect(find.text("Couldn't book this driver"), findsOneWidget);
      expect(find.text(const QrBookingError(QrBookingFailure.expired).toString()), findsOneWidget);
      expect(container.read(directBookingProvider), isNull);
    });

    testWidgets('the row\'s close books normally', (tester) async {
      final rides = _Rides();
      final container = await _home(tester, rides);
      container.read(directBookingProvider.notifier).set(const DirectBooking(token: _tokNow, driver: _ali));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('direct-booking-cancel')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('direct-booking-row')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('book')));
      await _settle(tester, 10);
      expect(rides.created![#directQrToken], isNull);
    });
  });

  group('searching a direct booking', () {
    final t0 = DateTime.utc(2026, 10, 12, 9);
    late DateTime now;
    late StreamController<RideRequest> rows;
    late _FakeMyRide repo;

    RideRequest ride({Map<String, dynamic> extra = const {}}) => RideRequest({
      'id': 'r1',
      'rider_id': 'me',
      'status': 'open',
      'fare': 20,
      'currency': 'MYR',
      'pickup_name': 'KLCC',
      'drop_name': 'KL Sentral',
      'pickup_lat': 3.15,
      'pickup_lng': 101.71,
      'offer_me': false,
      'created_at': t0.subtract(const Duration(seconds: 10)).toIso8601String(),
      'target_driver_ids': ['d1'],
      'targeted_until': t0.add(const Duration(minutes: 10)).toIso8601String(),
      'direct_driver_id': 'd1',
      ...extra,
    });

    Future<void> pump(
      WidgetTester tester, {
      Brightness brightness = Brightness.light,
      Size size = const Size(360, 1600),
    }) async {
      _size(tester, size);
      now = t0;
      repo = _FakeMyRide();
      rows = StreamController<RideRequest>();
      addTearDown(rows.close);
      final router = GoRouter(
        initialLocation: '/ride',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('home')),
          ),
          GoRoute(
            path: '/ride',
            builder: (_, _) => const RideTrackingScreen(requestId: 'r1'),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            rideRepositoryProvider.overrideWithValue(_Rides()),
            rideStreamProvider.overrideWith((ref, id) => rows.stream),
            searchClockProvider.overrideWithValue(() => now),
            riderPositionStreamProvider.overrideWithValue(() => const Stream<LatLng>.empty()),
            fareCoinChoiceStoreProvider.overrideWithValue(FareCoinChoiceStore()),
            walletBalancesProvider.overrideWith((ref) async => const []),
            walletTxProvider.overrideWith((ref) async => const []),
            currentUserIdProvider.overrideWithValue('me'),
            myRideRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp.router(routerConfig: router, theme: appTheme(brightness)),
        ),
      );
    }

    Future<void> tick(WidgetTester tester, Duration by) async {
      now = now.add(by);
      await tester.pump(by);
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('names the driver, with no countdown and no Add a driver', (tester) async {
      await pump(tester);
      rows.add(ride());
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('direct-booking-banner')), findsOneWidget);
      expect(find.text('Booked directly with Ali'), findsOneWidget);
      expect(find.byKey(const ValueKey('my-ride-countdown')), findsNothing);
      expect(find.byKey(const ValueKey('my-ride-add-target')), findsNothing);
      expect(find.byKey(const ValueKey('my-ride-banner')), findsNothing);
      // Nothing opens it to all by itself, however long it waits.
      await tick(tester, const Duration(minutes: 11));
      expect(repo.offers, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('"Offer to all nearby" stays as the rider\'s choice (dark)', (tester) async {
      await pump(tester, brightness: Brightness.dark);
      rows.add(ride());
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      await tester.tap(find.byKey(const ValueKey('direct-offer-all')));
      await tick(tester, const Duration(seconds: 1));
      expect(repo.offers, ['r1']);
      expect(find.text('Now offered to all nearby drivers'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('desktop width', (tester) async {
      await pump(tester, size: const Size(1400, 900));
      rows.add(ride());
      await tester.pump();
      await tick(tester, const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('direct-booking-banner')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the driver', () {
    for (final b in Brightness.values) {
      testWidgets('"Booked you directly" only on a direct booking to this driver (${b.name})', (tester) async {
        _size(tester, const Size(360, 400));
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(b),
            home: Scaffold(
              body: Column(
                children: [
                  DirectBookingLabel(request: RideRequest({'id': 'a', 'direct_driver_id': 'me'}), me: 'me'),
                  DirectBookingLabel(request: RideRequest({'id': 'b', 'direct_driver_id': 'x'}), me: 'me'),
                  DirectBookingLabel(request: RideRequest({'id': 'c'}), me: 'me'),
                ],
              ),
            ),
          ),
        );
        expect(find.byKey(const ValueKey('direct-booking-a')), findsOneWidget);
        expect(find.byKey(const ValueKey('direct-booking-b')), findsNothing);
        expect(find.byKey(const ValueKey('direct-booking-c')), findsNothing);
        expect(find.text('Booked you directly'), findsOneWidget);
      });
    }

    testWidgets('a direct booking pops up first, labelled', (tester) async {
      final open = StreamController<List<RideRequest>>.broadcast();
      addTearDown(open.close);
      _size(tester, const Size(700, 1400));
      final router = GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => const PartnerScreen())],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWithValue('me'),
            partnerProvider.overrideWith((ref) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Ali'})),
            openRequestsProvider.overrideWith((ref) => open.stream),
            rideRepositoryProvider.overrideWithValue(_DriverRides()),
            profileProvider.overrideWith((ref) async => Profile({'id': 'me'})),
            assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
            partnerTypeEntriesProvider.overrideWith(
              (ref) async => [
                (id: 'e', values: <String, dynamic>{'name': 'eHailing', 'vehicleRequired': false}),
              ],
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('You are offline'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      open.add([_driverReq('a'), _driverReq('d', direct: 'me')]);
      await tester.pumpAndSettle();
      final sheet = tester.widget<RideRequestSheet>(find.byType(RideRequestSheet));
      expect(sheet.request.id, 'd');
      expect(find.byKey(const ValueKey('direct-booking-d')), findsWidgets);
      expect(find.byKey(const ValueKey('direct-booking-a')), findsNothing);
    });
  });
}

// ---- The driver's queue ---------------------------------------------------------------

class _DriverRides implements RideRepository {
  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RideRequest _driverReq(String id, {String? direct}) => RideRequest({
  'id': id,
  'status': 'open',
  'service': 'Teksi',
  'fare': 12,
  'ride_fare': 12,
  'currency': 'MYR',
  'distance_km': 5,
  'passengers': 1,
  'payment_mode': 'Cash',
  'offer_me': false,
  'direct_driver_id': ?direct,
  if (direct != null) 'target_driver_ids': [direct],
});

// ---- The home screen's confirm step (as test/my_ride_rider_test.dart) ----------------

const _eco = Place(name: 'Eco Majestic', address: 'Semenyih', point: LatLng(2.9300, 101.8300));
const _klcc = Place(name: 'KLCC', address: 'Kuala Lumpur', point: LatLng(2.9400, 101.8400));

class _Rides implements RideRepository {
  Map<Symbol, dynamic>? created;
  Object? fail;

  @override
  Future<List<RideRequest>> ridesOnTheGo() async => const [];

  @override
  Future<bool> biddingEnabledFor(LatLng pickup, Future<AreaInfo?> Function() area) async => false;

  @override
  Future<RegionPricing> pricingFor(LatLng pickup, Future<AreaInfo?> Function() area) async => RegionPricing.none;

  @override
  Future<String?> publicIp() async => null;

  @override
  Future<double> claimRideReward(RideRequest r) async => 0;

  @override
  Future<void> expireStaleOpen() async {}

  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #createRequest) {
      if (fail != null) return Future<Booked>.error(fail!);
      created = i.namedArguments;
      final ride = RideRequest({'id': 'r9', 'rider_id': 'me', 'status': 'open', 'fare': 10});
      return Future<Booked>.value((now: ride, later: null));
    }
    return super.noSuchMethod(i);
  }
}

class _NoAi implements RouteEstimateRepository {
  @override
  dynamic noSuchMethod(Invocation i) => Future.value(null);
}

Future<ProviderContainer> _home(WidgetTester tester, _Rides rides) async {
  _size(tester, const Size(400, 860));
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      rideRepositoryProvider.overrideWithValue(rides),
      routeEstimateRepositoryProvider.overrideWithValue(_NoAi()),
      geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
      coinTradeQuoteProvider.overrideWith((ref) => Future.error('offline')),
      serviceBoxNamesProvider.overrideWith((ref) async => const <String, String>{}),
      rideServicesProvider.overrideWith((ref) async => const [RideService('Teksi', 'Metered taxi', 1, 4)]),
      recentPlacesProvider.overrideWith((ref) async => const [_eco, _klcc]),
      displaySettingsBlobProvider.overrideWith((ref) async => const <String, dynamic>{}),
      appDisplayProvider.overrideWith((ref) async => const AppDisplay()),
          passkeyOfferedHereProvider.overrideWith((ref) async => false),
      deviceBlockedProvider.overrideWith((ref) async => false),
      profileProvider.overrideWith((ref) async => null),
      fareTariffsProvider.overrideWith((ref) async => const []),
      meterLaunchSessionProvider.overrideWithValue(null),
      currentUserIdProvider.overrideWithValue('me'),
      myRideRepositoryProvider.overrideWithValue(_FakeMyRide()),
      myRideSettingsStoreProvider.overrideWithValue(_MemoryStore()),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
      GoRoute(path: '/ride/:id', builder: (_, s) => Text('ride ${s.pathParameters['id']}')),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await _settle(tester, 5);
  final g = await tester.startGesture(const Offset(200, 150));
  for (var i = 0; i < 5; i++) {
    await g.moveBy(const Offset(0, 8));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await g.up();
  await _settle(tester, 10);
  await tester.drag(find.byKey(const ValueKey('map-sheet-handle')), const Offset(0, -300));
  await _settle(tester, 5);
  await tester.tap(find.text('KLCC').first);
  await _settle(tester, 10);
  return container;
}
