// The store review account's demo of every feature (0333 follow-up): each
// module's repository switches to the demo one for that account only, each
// flow completes on the phone, and nothing is written to the server: the
// client below records every request and fails it, and no write (POST,
// PATCH, PUT, DELETE: tables and RPCs alike) may be among them. Light and
// dark.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/booking_modules.dart';
import 'package:get_ride/src/core/city_to_city.dart';
import 'package:get_ride/src/core/commission.dart' show Geo;
import 'package:get_ride/src/core/demo/demo_script.dart';
import 'package:get_ride/src/core/demo_mode.dart';
import 'package:get_ride/src/core/family.dart';
import 'package:get_ride/src/core/scheduled_rides.dart';
import 'package:get_ride/src/core/store_review.dart';
import 'package:get_ride/src/data/city_to_city_repository.dart';
import 'package:get_ride/src/data/demo/demo_repositories.dart';
import 'package:get_ride/src/data/family_repository.dart';
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/hourly_hire_repository.dart';
import 'package:get_ride/src/data/page_styles_repository.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/safety_incident_repository.dart';
import 'package:get_ride/src/data/scheduled_ride_repository.dart';
import 'package:get_ride/src/data/wallet_pay_repository.dart';
import 'package:get_ride/src/core/page_styles.dart' show PageStyles;
import 'package:get_ride/src/features/family/family_screen.dart';
import 'package:get_ride/src/features/partner/demo_jobs.dart';
import 'package:get_ride/src/features/ride/scheduled_rides_screen.dart';
import 'package:get_ride/src/features/ride/demo_ride.dart';
import 'package:get_ride/src/features/store_review/demo_contact.dart';
import 'package:get_ride/src/features/store_review/demo_flows.dart';
import 'package:get_ride/src/features/store_review/demo_wallet.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';

/// Every request the app tried; each one fails.
final _sent = <http.BaseRequest>[];
/// A read-only RPC, as the server's seal lets the demo account call it
/// (0333's store_review_rpc_allowed, its patterns).
bool _readOnlyRpc(String name) =>
    (name.endsWith('_config') && !name.startsWith('set_') && !name.startsWith('admin_')) ||
    (name.endsWith('_quote') && !name.startsWith('admin_')) ||
    (name.startsWith('my_') && name != 'my_qr_codes' && name != 'my_ride_code') ||
    name.endsWith('_mine');

/// Every write among them: a table write, or an RPC that is not a read.
List<String> get _writes => [
  for (final r in _sent)
    if (r.method != 'GET' && r.method != 'HEAD')
      if (!r.url.path.contains('/rpc/') || !_readOnlyRpc(r.url.pathSegments.last)) '${r.method} ${r.url.path}',
];

SupabaseClient _client() => SupabaseClient(
  'http://localhost',
  'anon',
  httpClient: MockClient((r) async {
    _sent.add(r);
    return http.Response('{"message":"offline in the test"}', 500);
  }),
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);

/// A session the client takes as signed in (never sent anywhere): the store
/// review account, or [id] with nothing in its app_metadata.
String _session({String id = storeReviewUserId, bool review = true}) {
  String part(Map<String, Object> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final exp = DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000;
  final jwt = '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part({'sub': id, 'exp': exp, 'role': 'authenticated'})}.sig';
  return jsonEncode({
    'access_token': jwt,
    'token_type': 'bearer',
    'expires_in': 86400,
    'expires_at': exp,
    'refresh_token': 'r',
    'user': {
      'id': id,
      'aud': 'authenticated',
      'role': 'authenticated',
      'created_at': '2026-01-01T00:00:00Z',
      'app_metadata': review ? {'store_review': true} : <String, Object>{},
      'user_metadata': <String, Object>{},
    },
  });
}

final _sinkProvider = Provider((ref) => DemoRideSink(ref));

Future<(ProviderContainer, SupabaseClient)> _signedIn({bool review = true}) async {
  final db = _client();
  await db.auth.recoverSession(_session(id: review ? storeReviewUserId : 'u-real', review: review));
  final c = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      supabaseProvider.overrideWithValue(db),
      profileProvider.overrideWith((ref) async => null),
      ...quietLiveOverrides,
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.dispose);
  return (c, db);
}

Future<Booked> _book(RideRepository rides, {DateTime? at, double? hireHours}) => rides.createRequest(
  scheduleAt: at,
  service: 'Car',
  pickupName: 'Pavilion KL',
  pickupAddress: 'Bukit Bintang',
  pickupLat: 3.1493,
  pickupLng: 101.7142,
  dropName: hireHours == null ? 'KLCC' : null,
  dropAddress: hireHours == null ? 'Kuala Lumpur' : null,
  dropLat: hireHours == null ? 3.1579 : null,
  dropLng: hireHours == null ? 101.7116 : null,
  distanceKm: 2.1,
  durationMin: 8,
  fare: 12,
  hireHours: hireHours,
);

Widget _app(Widget home, Brightness b, {List overrides = const [], GoRouter? router}) {
  final scope = [
    storeReviewProvider.overrideWithValue(true),
    currentUserIdProvider.overrideWithValue(storeReviewUserId),
    supabaseProvider.overrideWithValue(_client()),
    profileProvider.overrideWith((ref) async => null),
    pageStylesProvider.overrideWith((ref) async => PageStyles.none),
    geoServiceProvider.overrideWithValue(GeoService(client: MockClient((_) async => http.Response('', 500)))),
    ...quietLiveOverrides,
    ...overrides,
  ];
  final theme = ThemeData(brightness: b, useMaterial3: true);
  return ProviderScope(
    retry: (_, _) => null,
    overrides: [...scope],
    child: router != null
        ? MaterialApp.router(theme: theme, routerConfig: router)
        : MaterialApp(theme: theme, home: home),
  );
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _steps(WidgetTester tester, int n, [Duration each = const Duration(milliseconds: 500)]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(each);
  }
}

void main() {
  setUp(() {
    _sent.clear();
    SharedPreferences.setMockInitialValues({});
  });

  group('the script', () {
    test('every booking module and every feature the reviewer was refused is listed', () {
      final keys = {for (final f in demoFeatures) f.key};
      for (final k in [
        familyModuleRide,
        familyModuleScheduled,
        familyModuleHire,
        familyModuleCityToCity,
        familyModuleCourier,
        familyModuleFreight,
        'family',
        'chat',
        'call',
        'sos',
        'support',
        'wallet',
        'my_qr',
        'driver_requests',
        'counter_offer',
        'scheduled_jobs',
        'mygig',
        'credit',
      ]) {
        expect(keys, contains(k));
      }
      for (final f in demoFeatures) {
        expect(f.how, isNot(contains('→')));
      }
      expect(demoFeaturesFor(DemoSide.driver).every((f) => f.side == DemoSide.driver), isTrue);
    });

    test('each module says what is happening in its own words', () {
      String done(String m) => demoTripWords(m, driver: 'D', pickup: 'A', drop: 'B').done;
      expect(done(familyModuleCourier), 'Parcel delivered');
      expect(done(familyModuleFreight), 'Goods delivered');
      expect(done(familyModuleHire), 'Hire ended');
      expect(done(familyModuleCityToCity), 'You arrived in B');
      expect(done(familyModuleRide), 'Trip complete');
      expect(demoModuleOf({'parcel_size': 'small', 'cargo_description': 'x'}), familyModuleCourier);
      expect(demoModuleOf({'cargo_description': 'x'}), familyModuleFreight);
      expect(demoModuleOf({'hire_hours': 3}), familyModuleHire);
      expect(demoModuleOf({'demo_module': familyModuleCityToCity}), familyModuleCityToCity);
      expect(demoModuleOf(const {}), familyModuleRide);
    });

    test('chat answers, calls connect, the passenger weighs a fare', () {
      expect(demoChatReply('Where are you?', DemoPeer.driver), contains('minutes'));
      expect(demoChatReply('I was charged', DemoPeer.support), contains('no real money'));
      expect(demoChatReply('hello', DemoPeer.driver, turn: 1), isNot(demoChatReply('hello', DemoPeer.driver)));
      expect(demoCallStateAt(const Duration(seconds: 1)), DemoCallState.ringing);
      expect(demoCallStateAt(const Duration(seconds: 4)), DemoCallState.connected);
      expect(demoCallStateAt(const Duration(seconds: 4), hungUp: true), DemoCallState.ended);
      expect(demoCallClock(const Duration(seconds: 68)), '01:05');
      expect(demoCounterAmounts(20), [20, 22, 25, 30]);
      expect(demoPassengerTakes(25, 20), isTrue);
      expect(demoPassengerTakes(30, 20), isFalse);
      expect(demoSosNothingSent, contains('nothing was sent'));
    });

    test('the demo family reads as a host with a member and a child', () {
      final v = FamilyView.fromJson(demoFamilyJson(hostName: 'Reviewer', now: DateTime(2026, 11, 2)));
      expect(v.role, FamilyRole.host);
      expect(v.members.map((m) => m.name), ['Aisha', 'Adam']);
      expect(v.members.last.isChild, isTrue);
      expect(v.modules.map((m) => m.key), containsAll([familyModuleRide, familyModuleCourier, 'mygig']));
      expect(FamilyLiveItem.fromJson(demoFamilyLiveJson(DateTime(2026))).trip, isNotNull);
      final jobs = demoOpenScheduledRows(DateTime(2026, 11, 2));
      expect(jobs, hasLength(2));
      expect(jobs.every((j) => isDemoRideId('${j['id']}')), isTrue);
    });
  });

  group('the repositories switch for the store review account only', () {
    test('the reviewer gets the demo repositories; nothing is written', () async {
      final (c, _) = await _signedIn();
      expect(c.read(storeReviewProvider), isTrue);
      expect(c.read(scheduledRideRepositoryProvider), isA<DemoScheduledRideRepository>());
      expect(c.read(hourlyHireRepositoryProvider), isA<DemoHourlyHireRepository>());
      expect(c.read(cityToCityRepositoryProvider), isA<DemoCityToCityRepository>());
      expect(c.read(familyRepositoryProvider), isA<DemoFamilyRepository>());
      expect(c.read(safetyIncidentRepositoryProvider), isA<DemoSafetyIncidentRepository>());
      expect(c.read(walletPayRepositoryProvider), isA<DemoWalletPayRepository>());
      expect(c.read(creditRechargeRepositoryProvider), isA<DemoCreditRechargeRepository>());
      expect(c.read(rideRepositoryProvider).demo, isA<DemoRideSink>());
      expect(_writes, isEmpty);
    });

    test('everyone else keeps the real ones', () async {
      final (c, _) = await _signedIn(review: false);
      expect(c.read(storeReviewProvider), isFalse);
      expect(c.read(scheduledRideRepositoryProvider), isNot(isA<DemoScheduledRideRepository>()));
      expect(c.read(hourlyHireRepositoryProvider), isNot(isA<DemoHourlyHireRepository>()));
      expect(c.read(cityToCityRepositoryProvider), isNot(isA<DemoCityToCityRepository>()));
      expect(c.read(familyRepositoryProvider), isNot(isA<DemoFamilyRepository>()));
      expect(c.read(safetyIncidentRepositoryProvider), isNot(isA<DemoSafetyIncidentRepository>()));
      expect(c.read(walletPayRepositoryProvider), isNot(isA<DemoWalletPayRepository>()));
      expect(c.read(creditRechargeRepositoryProvider), isNot(isA<DemoCreditRechargeRepository>()));
      expect(c.read(rideRepositoryProvider).demo, isNull);
    });

    test('ride now, for later, and a hire: on the phone', () async {
      final (c, db) = await _signedIn();
      final rides = RideRepository(db)..demo = c.read(_sinkProvider);
      final now = await _book(rides);
      expect(isDemoRideId(now.now!.id), isTrue);
      expect(c.read(demoRidesProvider)[now.now!.id]!.raw['demo_module'], familyModuleRide);

      final at = DateTime.now().add(const Duration(days: 1));
      final later = await _book(rides, at: at);
      expect(later.now, isNull);
      expect(isDemoRideId(later.later!.id), isTrue);
      final mine = await c.read(scheduledRideRepositoryProvider).mine(storeReviewUserId);
      expect(mine.single.id, later.later!.id);
      final cancelled = await c.read(scheduledRideRepositoryProvider).cancel(later.later!.id);
      expect(cancelled.status, ScheduledStatus.cancelled);

      final hire = await _book(rides, hireHours: 3);
      final h = c.read(demoRidesProvider)[hire.now!.id]!;
      expect(h.raw['demo_module'], familyModuleHire);
      expect(h.dropLat, isNotNull, reason: 'a hire with no drop-off still has somewhere to drive to');
      expect(_writes, isEmpty);
    });

    test('a hire for several days lists each day', () async {
      final (c, _) = await _signedIn();
      final repo = c.read(hourlyHireRepositoryProvider);
      final b = await repo.book({'service': 'Car', 'fare': 200, 'pickup_name': 'KLCC'}, {
        'package': 'weekly',
        'first_at': DateTime.now().add(const Duration(days: 2)).toIso8601String(),
        'days': 7,
        'hours': 8,
      });
      expect(b.title, 'Weekly hire');
      expect((await repo.myBookings()).single.id, b.id);
      expect(await repo.bookingDays(b.id), hasLength(7));
      expect((await c.read(scheduledRideRepositoryProvider).mine('x')).length, 7);
      await repo.cancelBooking(b.id);
      expect((await repo.booking(b.id))!.status, 'cancelled');
      expect(_writes, isEmpty);
    });

    test('City to City and a seat on a posted trip', () async {
      final (c, _) = await _signedIn();
      final repo = c.read(cityToCityRepositoryProvider);
      final b = await repo.book({
        'pickup_name': 'KL Sentral',
        'drop_name': 'Penang',
        'leave_at': DateTime.now().add(const Duration(days: 1)).toUtc().toIso8601String(),
        'fare': 150,
      });
      expect(isDemoRideId(b.id), isTrue);
      expect((await repo.myTrips()).single.id, b.id);
      final trips = await repo.searchTrips(from: const Geo(city: 'Kuala Lumpur'), to: const Geo(city: 'Ipoh'));
      expect(trips, hasLength(2));
      expect(trips.first.meetingPoints, isNotEmpty);
      final seat = await repo.bookSeat(tripId: trips.first.id, seats: 1, pickup: const {'kind': 'meeting'},
          payment: C2cPayment.cash);
      expect(seat.status, 'booked');
      expect((await repo.cancel(b.id)).fee, 0);
      expect(_writes, isEmpty);
    });

    test('Family: the host changes a limit, adds a child, books for a member', () async {
      final (c, _) = await _signedIn();
      final repo = c.read(familyRepositoryProvider);
      final v = await repo.mine();
      expect(v.role, FamilyRole.host);
      final aisha = v.members.first;
      final changed = await repo.updateMember(aisha.id, {'monthlyLimit': 500});
      expect(changed.limit, 500);
      await repo.addChild(name: 'Sara', birthDate: '2018-05-01');
      expect((await repo.mine()).members.map((m) => m.name), contains('Sara'));
      final who = await repo.passengers(familyModuleRide);
      expect(who.where((p) => p.isChild).every((p) => p.needsAdult), isTrue);
      expect(await repo.live(), isNotEmpty);
      expect(_writes, isEmpty);
    });

    test('SOS, QR pay and GET.credit stay on the phone', () async {
      final (c, _) = await _signedIn();
      expect(await c.read(safetyIncidentRepositoryProvider).raise(rideId: 'demo-1'), startsWith('demo-sos'));
      expect(c.read(demoStoreProvider).sos, 1);
      await c.read(walletPayRepositoryProvider).pay(10, note: 'shop');
      expect(c.read(demoWalletProvider).wallet, demoWalletStart.wallet - 10);
      await c.read(creditRechargeRepositoryProvider).recharge(40);
      expect(c.read(demoWalletProvider).credit, demoWalletStart.credit + 40);
      await expectLater(c.read(creditRechargeRepositoryProvider).recharge(10000), throwsA(anything));
      final jobs = c.read(scheduledRideRepositoryProvider);
      final open = await jobs.open();
      await jobs.accept(open.first.id);
      expect((await jobs.accepted('me')).single.id, open.first.id);
      await jobs.release(open.first.id);
      expect(await jobs.accepted('me'), isEmpty);
      expect(_writes, isEmpty);
    });
  });

  for (final b in Brightness.values) {
    group('flows (${b.name})', () {
      testWidgets('a courier trip: chat, call, SOS, delivered, pay, rate, receipt', (tester) async {
        _phone(tester);
        await tester.pumpWidget(_app(
          const DemoTripScreen(
            tick: Duration(milliseconds: 500),
            args: DemoTripArgs(
              pickup: LatLng(3.1493, 101.7142),
              pickupName: 'Pavilion KL',
              drop: LatLng(3.1579, 101.7116),
              dropName: 'KLCC',
              offer: DemoOffer(
                  id: 'demo-2', name: 'Mellier', vehicle: 'Myvi', rating: 4.6, rides: 9, etaMin: 4, km: 1, price: 12),
              currency: 'MYR',
              module: familyModuleCourier,
            ),
          ),
          b,
        ));
        await tester.pump();
        expect(find.text('Your delivery'), findsOneWidget);

        // Chat: the demo courier answers.
        await tester.tap(find.byKey(const ValueKey('demo-trip-chat')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('demo-chat-input')), 'Where are you?');
        await tester.tap(find.byKey(const ValueKey('demo-chat-send')));
        await tester.pump();
        expect(find.byKey(const ValueKey('demo-chat-typing')), findsOneWidget);
        await tester.pump(demoChatReplyAfter);
        expect(find.text('About 3 minutes away.'), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();

        // Call: rings, connects, ends.
        await tester.tap(find.byKey(const ValueKey('demo-trip-call')));
        await tester.pumpAndSettle();
        expect(find.text('Ringing…'), findsOneWidget);
        await tester.pump(const Duration(seconds: 4));
        expect(find.textContaining('Connected'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('demo-call-end')));
        await tester.pump();
        expect(find.text('Call ended'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('demo-call-close')));
        await tester.pumpAndSettle();

        // SOS: every step, nothing sent.
        await tester.tap(find.byKey(const ValueKey('demo-trip-sos')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('sos-ops')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('demo-sos-done')), findsOneWidget);
        expect(find.text(demoSosNothingSent), findsOneWidget);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();

        // The trip plays out on its own.
        await _steps(tester, 80);
        expect(find.text('Parcel delivered'), findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('demo-pay-wallet')));
        await tester.tap(find.byKey(const ValueKey('demo-pay-wallet')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('demo-star-5')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('demo-rate')));
        await tester.pump();
        expect(find.byKey(const ValueKey('demo-receipt')), findsOneWidget);
        expect(_writes, isEmpty);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('Try every feature: each opens; a quick demo books on the phone', (tester) async {
        _phone(tester);
        late ProviderContainer c;
        final router = GoRouter(routes: [
          GoRoute(path: '/', builder: (_, _) => Consumer(builder: (context, ref, _) {
            c = ProviderScope.containerOf(context);
            return const DemoFeaturesScreen();
          })),
          GoRoute(path: '/ride/:id', builder: (_, s) => Text('search ${s.pathParameters['id']}')),
        ]);
        await tester.pumpWidget(_app(const SizedBox(), b, router: router));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('demo-banner')), findsOneWidget);
        for (final f in [demoFeatures.first, demoFeatures.last]) {
          await tester.scrollUntilVisible(find.byKey(ValueKey('demo-feature-${f.key}')), 200);
          expect(find.byKey(ValueKey('demo-open-${f.key}')), findsOneWidget);
        }
        await tester.scrollUntilVisible(find.byKey(const ValueKey('demo-quick-$familyModuleCourier')), -200);
        await tester.ensureVisible(find.byKey(const ValueKey('demo-quick-$familyModuleCourier')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('demo-quick-$familyModuleCourier')));
        await tester.pumpAndSettle();
        final ride = c.read(demoRidesProvider).values.single;
        expect(ride.raw['demo_module'], familyModuleCourier);
        expect(find.text('search ${ride.id}'), findsOneWidget);
        expect(_writes, isEmpty);
      });

      testWidgets('QR pay from the demo wallet', (tester) async {
        _phone(tester);
        late WidgetRef r;
        await tester.pumpWidget(_app(Consumer(builder: (context, ref, _) {
          r = ref;
          return Scaffold(body: Center(child: TextButton(onPressed: () => showDemoQrPay(context, ref), child: const Text('go'))));
        }), b));
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('demo-qr-pay-confirm')));
        await tester.pumpAndSettle();
        expect(find.text('Paid (demo)'), findsOneWidget);
        expect(r.read(demoWalletProvider).wallet, demoWalletStart.wallet - 12.5);
        expect(_writes, isEmpty);
      });

      testWidgets('Family: the demo host sees members and a member\'s demo trip', (tester) async {
        _phone(tester);
        await tester.pumpWidget(_app(const FamilyScreen(), b));
        await tester.pumpAndSettle();
        expect(find.textContaining('Aisha'), findsWidgets);
        expect(find.textContaining('Adam'), findsWidgets);
        expect(_writes, isEmpty);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('driver: offer a fare, the demo passenger takes it; chat, call and SOS on the job', (tester) async {
        _phone(tester);
        final router = GoRouter(routes: [
          GoRoute(path: '/', builder: (_, _) => Scaffold(body: DemoJobFeed(random: math.Random(3)))),
          GoRoute(path: '/drive/demo', builder: (_, s) => DemoJobScreen(job: s.extra! as DemoJob)),
        ]);
        await tester.pumpWidget(_app(const SizedBox(), b, router: router));
        await tester.pump(const Duration(seconds: 15));
        expect(find.byKey(const ValueKey('demo-job')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('demo-job-counter')));
        await tester.pumpAndSettle();
        // The first amount is the passenger's own fare: always taken.
        await tester.tap(find.byWidgetPredicate(
            (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('demo-counter-')).first);
        await tester.pump();
        expect(find.byKey(const ValueKey('demo-counter-status')), findsOneWidget);
        await tester.pump(demoCounterAnswerAfter);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('demo-job-phase')), findsOneWidget);
        expect(find.byKey(const ValueKey('demo-job-chat')), findsOneWidget);
        expect(find.byKey(const ValueKey('demo-job-call')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('demo-job-sos')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('sos-call')));
        await tester.pumpAndSettle();
        expect(find.text(demoSosNothingSent), findsOneWidget);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(_writes, isEmpty);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('a ride for later: listed, then run now on the phone', (tester) async {
        _phone(tester);
        final router = GoRouter(routes: [
          GoRoute(path: '/', builder: (_, _) => const ScheduledRidesScreen()),
          GoRoute(path: '/ride/:id', builder: (_, s) => Text('search ${s.pathParameters['id']}')),
        ]);
        await tester.pumpWidget(_app(const SizedBox(), b, router: router));
        await tester.pumpAndSettle();
        final c = ProviderScope.containerOf(tester.element(find.byType(ScheduledRidesScreen)));
        final booked = await c.read(scheduledRideRepositoryProvider).schedule({
          'pickup_name': 'Pavilion KL',
          'pickup_address': 'Bukit Bintang',
          'pickup_lat': 3.1493,
          'pickup_lng': 101.7142,
          'drop_name': 'KLCC',
          'drop_address': 'Kuala Lumpur',
          'drop_lat': 3.1579,
          'drop_lng': 101.7116,
          'fare': 14,
          'currency': 'MYR',
        }, DateTime.now().add(const Duration(hours: 5)));
        c.invalidate(myScheduledRidesProvider);
        await tester.pumpAndSettle();
        final run = find.byKey(ValueKey('scheduled-demo-run-${booked.id}'));
        await tester.ensureVisible(run);
        await tester.tap(run);
        await tester.pumpAndSettle();
        final ride = c.read(demoRidesProvider).values.single;
        expect(ride.raw['demo_module'], familyModuleScheduled);
        expect(find.text('search ${ride.id}'), findsOneWidget);
        expect(c.read(demoStoreProvider).scheduled[booked.id]!['status'], 'released');
        expect(_writes, isEmpty);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('support chat with a demo agent', (tester) async {
        _phone(tester);
        await tester.pumpWidget(_app(const DemoChatScreen(peer: DemoPeer.support, name: 'GET.ride support'), b));
        expect(find.textContaining('support team'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('demo-chat-input')), 'Thank you');
        await tester.tap(find.byKey(const ValueKey('demo-chat-send')));
        await tester.pump(demoChatReplyAfter);
        expect(find.text('You\'re welcome. Anything else?'), findsOneWidget);
        expect(_writes, isEmpty);
      });
    });
  }
}
