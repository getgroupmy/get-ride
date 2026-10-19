import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/partner_queue.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/features/shell/app_shell.dart';
import 'package:get_ride/src/widgets/focus_order.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';

class _FakeRides implements RideRepository {
  final accepted = <String>[];

  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  Future<RideRequest?> accept(
    String id,
    Partner? partner, {
    double? lat,
    double? lng,
    String? fallbackName,
    String? fallbackPhone,
  }) async {
    accepted.add(id);
    return RideRequest({'id': id, 'status': 'accepted'});
  }

  /// Accept is an offer at the rider's fare; this rider auto-accepts it.
  @override
  Future<RideRequest?> submitOffer(
    String id,
    double amount,
    Partner? partner, {
    double? lat,
    double? lng,
    String? fallbackName,
    String? fallbackPhone,
  }) async {
    accepted.add(id);
    return RideRequest({'id': id, 'status': 'accepted', 'partner_id': 'me'});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RideRequest _req(String id, {bool offerMe = false}) => RideRequest({
  'id': id,
  'status': 'open',
  'service': 'Teksi',
  'fare': 12,
  'ride_fare': 12,
  'currency': 'MYR',
  'distance_km': 5,
  'passengers': 1,
  'payment_mode': 'Cash',
  'offer_me': offerMe,
});

void main() {
  group('rules', () {
    test('auto-accept takes the nearest unseen request, unknown distances last', () {
      final open = <QueueItem>[
        (id: 'a', offerMe: false, awayKm: 3),
        (id: 'b', offerMe: false, awayKm: null),
        (id: 'c', offerMe: true, awayKm: 1),
      ];
      expect(autoAcceptPick(open, {}, busy: false), 'c');
      expect(autoAcceptPick(open, {'c'}, busy: false), 'a');
      expect(autoAcceptPick(open, {'a', 'c'}, busy: false), 'b');
      expect(autoAcceptPick(open, {'a', 'b', 'c'}, busy: false), isNull);
      expect(autoAcceptPick(open, {}, busy: true), isNull);
    });

    test('counter-offers need both the request and the partner to allow them', () {
      expect(canCounterOffer(requestOfferMe: true, allowOfferMe: true), isTrue);
      expect(canCounterOffer(requestOfferMe: true, allowOfferMe: false), isFalse);
      expect(canCounterOffer(requestOfferMe: false, allowOfferMe: true), isFalse);
    });
  });

  for (final b in Brightness.values) {
    testWidgets('desktop 1366x768: Tab goes rail, then the panel, then the map controls and floating buttons '
        '(${b.name})', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1366, 768);
      addTearDown(tester.view.reset);
      final router = GoRouter(
        initialLocation: '/drive',
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (_, _, shell) => AppShell(shell: shell),
            branches: [
              for (final path in ['/', '/trips', '/wallet', '/drive', '/account'])
                StatefulShellBranch(routes: [
                  GoRoute(
                    path: path,
                    builder: (_, _) => path == '/drive' ? const PartnerScreen() : Scaffold(body: Text(path)),
                  ),
                ]),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWithValue('me'),
            partnerProvider.overrideWith((ref) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Ali'})),
            openRequestsProvider.overrideWith((ref) => const Stream<List<RideRequest>>.empty()),
            rideRepositoryProvider.overrideWithValue(_FakeRides()),
            profileProvider.overrideWith((ref) async => Profile({'id': 'me'})),
            assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
            partnerTypeEntriesProvider.overrideWith((ref) async => [
              (id: 'e', values: <String, dynamic>{'name': 'eHailing', 'vehicleRequired': false}),
            ]),
          ],
          child: MaterialApp.router(theme: ThemeData(brightness: b), routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // Where each Tab stop sits: 0 the rail, 1 the page's own content, 2
      // what floats over the map.
      int region(FocusNode n) {
        final c = n.context!;
        if (c.findAncestorWidgetOfExactType<NavigationRail>() != null) return 0;
        return FocusLast.isMarked(c) ? 2 : 1;
      }

      final seen = <(int, String)>[];
      for (var i = 0; i < 40; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final n = FocusManager.instance.primaryFocus;
        if (n == null || n.context == null) continue;
        final tip = n.context!.findAncestorWidgetOfExactType<Tooltip>()?.message ?? '';
        seen.add((region(n), tip));
        if (seen.length > 3 && region(n) == 0 && seen[seen.length - 2].$1 == 2) break; // wrapped round
      }
      final order = [for (final (r, _) in seen) r];
      // The first lap: never back to an earlier region before it wraps.
      final lap = order.sublist(0, order.lastIndexOf(0) > order.indexOf(2) ? order.lastIndexOf(0) : order.length);
      for (var i = 1; i < lap.length; i++) {
        expect(lap[i], greaterThanOrEqualTo(lap[i - 1]), reason: 'stop $i went back: $seen');
      }
      expect(lap.first, 0, reason: 'the rail first, not the floating buttons: $seen');
      expect(lap, contains(1), reason: 'the panel');
      final tips = [for (final (r, t) in seen.take(lap.length)) if (r == 2) t];
      for (final t in ['My vehicles', 'Menu', 'Satellite view', 'Map credits']) {
        expect(tips, contains(t), reason: '$t is reached after the panel: $seen');
      }
      expect(tester.takeException(), isNull);
    });
  }

  group('screen', () {
    late StreamController<List<RideRequest>> open;
    late _FakeRides rides;

    setUp(() {
      open = StreamController<List<RideRequest>>.broadcast();
      rides = _FakeRides();
    });
    tearDown(() => open.close());

    Future<void> pump(
      WidgetTester tester, {
      Size size = const Size(700, 1400),
      double textScale = 1,
      Brightness brightness = Brightness.light,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const PartnerScreen()),
          GoRoute(
            path: '/drive/trip/:id',
            builder: (_, s) => Scaffold(body: Text('trip ${s.pathParameters['id']}')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserIdProvider.overrideWithValue('me'),
            partnerProvider.overrideWith((ref) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Ali'})),
            openRequestsProvider.overrideWith((ref) => open.stream),
            rideRepositoryProvider.overrideWithValue(rides),
            profileProvider.overrideWith((ref) async => Profile({'id': 'me'})),
            assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
            // These drivers have no vehicle; the vehicle check has its own test.
            partnerTypeEntriesProvider.overrideWith((ref) async => [
              (id: 'e', values: <String, dynamic>{'name': 'eHailing', 'vehicleRequired': false}),
            ]),
          ],
          child: MaterialApp.router(theme: ThemeData(brightness: brightness), routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('You are offline'));
      // The queue shows a spinner until its first event, so don't settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    // While requests float on the map the sheet is held down with only the
    // online switch showing; flip the settings switches directly.
    Future<void> flip(WidgetTester tester, String key) async {
      final tile = tester.widget<SwitchListTile>(find.byKey(ValueKey(key)));
      tile.onChanged!(!tile.value);
      await tester.pumpAndSettle();
    }

    testWidgets('auto-accept leaves queued requests and takes the next one', (tester) async {
      await pump(tester);
      open.add([_req('old')]);
      await tester.pumpAndSettle();
      await flip(tester, 'queue-auto-accept');
      expect(rides.accepted, isEmpty);

      open.add([_req('old'), _req('new')]);
      await tester.pumpAndSettle();
      expect(rides.accepted, ['new']);
      expect(find.text('trip new'), findsOneWidget);
    });

    for (final scale in [1.0, 1.3]) {
      for (final b in Brightness.values) {
        testWidgets('online in landscape 915x412 at ${scale}x text: the panel scrolls, nothing overflows (${b.name})',
            (tester) async {
          await pump(tester, size: const Size(915, 412), textScale: scale, brightness: b);
          open.add(const []);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'no RenderFlex overflow');
          expect(find.byKey(const ValueKey('partner-panel-scroll')), findsOneWidget);
          expect(find.text('You are online'), findsOneWidget);
          // The wallet tiles at the end of the settings scroll into view.
          final last = find.byKey(const ValueKey('queue-allow-offer'));
          await tester.scrollUntilVisible(last, 100, scrollable: find.byType(Scrollable).first);
          await tester.pumpAndSettle();
          expect(tester.getRect(last).bottom, lessThanOrEqualTo(412));
          expect(tester.takeException(), isNull);
        });
      }
    }

    // Desktop 141: with the request sheet up, nothing behind it is reachable
    // by a screen reader.
    for (final b in Brightness.values) {
      testWidgets('141: at 844x390 the page behind the request sheet leaves the semantics tree (${b.name})',
          (tester) async {
        await pump(tester, size: const Size(844, 390), brightness: b);
        final handle = tester.ensureSemantics();
        expect(find.semantics.byLabel(RegExp('You are online')), findsOne, reason: 'there before');
        open.add([_req('r1')]);
        await tester.pumpAndSettle();
        expect(find.semantics.byLabel(RegExp('You are online')), findsNothing, reason: 'blocked behind the sheet');
        expect(find.semantics.byLabel(RegExp('Accept for')), findsOne, reason: 'the sheet itself is read');
        handle.dispose();
      });
    }

    testWidgets('Accept keeps the theme font (a ButtonStyle textStyle copied from the theme)', (tester) async {
      await pump(tester);
      open.add([_req('r1')]);
      await tester.pumpAndSettle();
      final accept = find.byKey(const ValueKey('request-alert-accept'));
      expect(accept, findsOneWidget);
      final label = tester.renderObject<RenderParagraph>(
        find.descendant(of: accept, matching: find.textContaining('Accept for')),
      );
      final theme = Theme.of(tester.element(accept));
      expect(label.text.style?.fontFamily, theme.textTheme.labelLarge?.fontFamily);
      expect(label.text.style?.fontFamily, isNotNull);
    });

    testWidgets('without auto-accept nothing is taken', (tester) async {
      await pump(tester);
      open.add([_req('r1')]);
      await tester.pumpAndSettle();
      expect(rides.accepted, isEmpty);
      expect(find.text('Accept for RM12.00'), findsOneWidget, reason: 'waiting on the request sheet');
    });

    testWidgets('turning OfferMe off hides the counter-offer button', (tester) async {
      await pump(tester);
      open.add([_req('bid', offerMe: true)]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('request-offer-custom')), findsOneWidget);
      await flip(tester, 'queue-allow-offer');
      expect(find.byKey(const ValueKey('request-offer-custom')), findsNothing);
      expect(find.text('Offer your fare'), findsNothing);
      expect(find.text('Accept for RM12.00'), findsOneWidget);
    });
  });
}
