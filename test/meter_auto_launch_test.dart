import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/meter_logic.dart';
import 'package:get_ride/src/core/meter_auto_launch.dart';
import 'package:get_ride/src/data/meter_launch_store.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/features/meter/meter_auto_launch.dart';
import 'package:get_ride/src/features/meter/meter_providers.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:get_ride/src/core/launch_destination.dart';

MeterProfile _card({String level = 'master', String? city, bool autoLaunch = true, String id = 'm'}) =>
    defaultMeterProfile.copyWith(id: id, level: level, city: () => city, autoLaunch: autoLaunch);

const _teksi = ['teksi'];
const _klang = (country: 'Malaysia', state: 'Selangor', city: 'Klang', suburb: null);

Partner _partner({List<String> types = _teksi, String status = 'approved'}) =>
    Partner({'id': 'p1', 'name': 'Aina', 'status': status, 'partner_types': types});

/// The fake sign-in: an account and when it signed in.
class _User extends Notifier<String?> {
  @override
  String? build() => 'u1|09:00';
  void set(String? session) => state = session;
}

final _user = NotifierProvider<_User, String?>(_User.new);

void main() {
  test('where a launch lands: rider ride, then driver trip, then meter, then home', () {
    expect(resolveLaunchTarget(riderRideInProgress: true, partnerTripId: 'r1', meterAutoLaunch: true), isA<LaunchHome>());
    expect(
      resolveLaunchTarget(riderRideInProgress: false, partnerTripId: 'r1', meterAutoLaunch: true),
      isA<LaunchPartnerTrip>().having((t) => t.requestId, 'id', 'r1'),
    );
    expect(resolveLaunchTarget(riderRideInProgress: false, meterAutoLaunch: true), isA<LaunchMeter>());
    expect(resolveLaunchTarget(riderRideInProgress: false, partnerTripId: '', meterAutoLaunch: false), isA<LaunchHome>());
  });

  group('the rule', () {
    test('a TEKSI partner whose card asks for it lands on the meter', () {
      final r = resolveMeterAutoLaunch(profiles: [_card()], partnerTypes: _teksi, canDrive: true);
      expect(r, (launch: true, reason: MeterAutoLaunchReason.launch));
    });

    test('not a TEKSI partner, or not cleared to drive, is never sent there', () {
      expect(resolveMeterAutoLaunch(profiles: [_card()], partnerTypes: ['ehailing'], canDrive: true).reason,
          MeterAutoLaunchReason.notTeksi);
      expect(resolveMeterAutoLaunch(profiles: [_card()], partnerTypes: null, canDrive: true).launch, isFalse);
      expect(resolveMeterAutoLaunch(profiles: [_card()], partnerTypes: _teksi, canDrive: false).reason,
          MeterAutoLaunchReason.notTeksi);
    });

    test('off by default: with no card anywhere the meter is not the landing screen', () {
      expect(resolveMeterAutoLaunch(profiles: const [], partnerTypes: _teksi, canDrive: true).reason,
          MeterAutoLaunchReason.cardOff);
    });

    test('the card for where the meter last ran decides, else the global one', () {
      final cards = [_card(autoLaunch: false), _card(id: 'k', level: 'city', city: 'Klang')];
      expect(resolveMeterAutoLaunch(profiles: cards, partnerTypes: _teksi, canDrive: true).launch, isFalse);
      expect(resolveMeterAutoLaunch(profiles: cards, partnerTypes: _teksi, canDrive: true, geo: _klang).launch, isTrue);
    });

    test('a ride in progress outranks the meter', () {
      expect(
        resolveMeterAutoLaunch(profiles: [_card()], partnerTypes: _teksi, canDrive: true, rideInProgress: true).reason,
        MeterAutoLaunchReason.rideInProgress,
      );
    });
  });

  group('kept on the device', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('the last meter geography survives', () async {
      final store = MeterLaunchStore();
      expect(await store.readGeo(), isNull);
      await store.saveGeo(_klang);
      expect(await store.readGeo(), _klang);
    });

    test('the rate cards survive, so an offline launch can still decide', () async {
      final store = MeterLaunchStore();
      expect(await store.readCards(), isEmpty);
      await store.saveCards([_card(id: 'k', level: 'city', city: 'Klang')]);
      final back = await store.readCards();
      expect(back.single.id, 'k');
      expect(back.single.city, 'Klang');
      expect(back.single.autoLaunch, isTrue);
    });
  });

  group('the decision', () {
    ProviderContainer container({Partner? partner, List<MeterProfile>? cards, bool ride = false}) {
      final c = ProviderContainer(overrides: [
        partnerProvider.overrideWith((_) async => partner),
        meterCardsProvider.overrideWith((_) async => cards ?? [_card()]),
        rideInProgressProvider.overrideWith((_) async => ride),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('gathers the partner, cards, geography and rides', () async {
      expect(await container(partner: _partner()).read(meterAutoLaunchProvider.future), isTrue);
      expect(await container(partner: _partner(), ride: true).read(meterAutoLaunchProvider.future), isFalse);
      expect(await container(partner: _partner(status: 'unapproved')).read(meterAutoLaunchProvider.future), isFalse);
      expect(await container().read(meterAutoLaunchProvider.future), isFalse, reason: 'not a partner');
    });

    test('uses the geography the meter last ran in', () async {
      await MeterLaunchStore().saveGeo(_klang);
      final cards = [_card(autoLaunch: false), _card(id: 'k', level: 'city', city: 'Klang')];
      expect(await container(partner: _partner(), cards: cards).read(meterAutoLaunchProvider.future), isTrue);
    });
  });

  group('once per launch', () {
    late int decisions;

    Future<GoRouter> pump(
      WidgetTester tester, {
      required bool launch,
      ({bool rider, String? partnerTripId}) ongoing = (rider: false, partnerTripId: null),
    }) async {
      decisions = 0;
      final router = GoRouter(routes: [
        GoRoute(path: '/', builder: (_, _) => const _Home()),
        GoRoute(path: '/meter', builder: (_, _) => const Scaffold(body: Text('METER'))),
        GoRoute(path: '/drive/trip/:id', builder: (_, s) => Scaffold(body: Text('TRIP ${s.pathParameters['id']}'))),
      ]);
      addTearDown(router.dispose);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          meterLaunchSessionProvider.overrideWith((ref) => ref.watch(_user)),
          ongoingRidesProvider.overrideWith((_) async => ongoing),
          meterAutoLaunchProvider.overrideWith((_) async {
            decisions++;
            return launch;
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('opens the meter, and coming home does not send the driver back', (tester) async {
      final router = await pump(tester, launch: true);
      expect(find.text('METER'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('HOME'), findsOneWidget);
      // Home is built again (as a new screen) and does not re-decide.
      router.go('/meter');
      await tester.pumpAndSettle();
      router.go('/');
      await tester.pumpAndSettle();
      expect(find.text('HOME'), findsOneWidget);
      expect(decisions, 1);
    });

    testWidgets('a driver mid-trip goes back to the trip, not the meter', (tester) async {
      await pump(tester, launch: true, ongoing: (rider: false, partnerTripId: 'r9'));
      expect(find.text('TRIP r9'), findsOneWidget);
      expect(decisions, 0, reason: 'the meter is not even asked');
    });

    testWidgets("a rider's ride in progress keeps the launch home", (tester) async {
      await pump(tester, launch: true, ongoing: (rider: true, partnerTripId: 'r9'));
      expect(find.text('HOME'), findsOneWidget);
      expect(find.textContaining('TRIP'), findsNothing);
    });

    testWidgets('a card that does not ask for it leaves the driver home', (tester) async {
      await pump(tester, launch: false);
      expect(find.text('HOME'), findsOneWidget);
      expect(find.text('METER'), findsNothing);
    });

    testWidgets('signing out and in again decides afresh', (tester) async {
      final router = await pump(tester, launch: true);
      router.pop();
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(find.text('HOME')));
      // A token refresh is the same sign-in.
      router.go('/meter');
      await tester.pumpAndSettle();
      router.go('/');
      await tester.pumpAndSettle();
      expect(decisions, 1);
      container.read(_user.notifier).set(null);
      await tester.pump();
      container.read(_user.notifier).set('u1|17:30');
      router.go('/meter');
      await tester.pumpAndSettle();
      router.go('/');
      await tester.pumpAndSettle();
      expect(find.text('METER'), findsOneWidget);
      expect(decisions, 2);
    });
  });
}

/// Stands in for the home screen: decides on its first frame.
class _Home extends ConsumerStatefulWidget {
  const _Home();

  @override
  ConsumerState<_Home> createState() => _HomeState();
}

class _HomeState extends ConsumerState<_Home> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) maybeAutoLaunchMeter(context, ref);
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('HOME'));
}
