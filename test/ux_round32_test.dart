// Web UX round 32 (161) at 412x915 and 1.3x text, light and dark: the
// driver's Ride request sheet sets its title on a solid band above the map,
// so it never lands on the tiles or the pickup-distance chip. Round 33
// (166) at 360x640: the map is tall enough, and fitted with room for the
// chips, that the car, pickup and drop-off and their chips never stack.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/request_viewers.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/features/partner/request_sheet.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/ride_map.dart';
import 'package:latlong2/latlong.dart';

class _Rides implements RideRepository {
  @override
  Future<RequestViewers> viewers(String requestId) async => RequestViewers.none;

  @override
  Future<void> markViewed(String requestId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RideRequest _open() => RideRequest({
  'id': 'r1',
  'rider_id': 'rider',
  'status': 'open',
  'fare': 20,
  'currency': 'MYR',
  'pickup_name': 'KLCC',
  'pickup_lat': 3.1579,
  'pickup_lng': 101.7116,
  'drop_name': 'KL Sentral',
  'drop_lat': 3.1340,
  'drop_lng': 101.6860,
  'distance_km': 6.4,
  'duration_min': 14,
  'created_at': DateTime.now().toUtc().toIso8601String(),
});

void main() {
  for (final dark in [false, true]) {
    testWidgets('161: "Ride request" on a solid band, the map below it (${dark ? 'dark' : 'light'})', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [rideRepositoryProvider.overrideWithValue(_Rides())],
          child: MaterialApp(
            theme: dark ? ThemeData.dark() : ThemeData.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: Scaffold(
              body: RideRequestSheet(
                request: _open(),
                shown: Duration.zero,
                now: DateTime.now(),
                me: const LatLng(3.165, 101.72),
                awayKm: 1.2,
                onAccept: () async {},
                onSkip: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final title = tester.getRect(find.byKey(const ValueKey('request-sheet-title')));
      final band = find.byKey(const ValueKey('request-title-band'));
      expect(find.descendant(of: band, matching: find.byKey(const ValueKey('request-sheet-title'))), findsOneWidget);
      expect(tester.widget<ColoredBox>(band).color.a, 1.0, reason: 'solid, not a shade over the tiles');
      final map = tester.getRect(find.byType(RideMap));
      expect(map.top, greaterThanOrEqualTo(tester.getRect(band).bottom), reason: 'the map starts below the title');
      expect(title.bottom, lessThanOrEqualTo(map.top));
      final chip = find.byKey(const ValueKey('request-chip-pickup'));
      if (chip.evaluate().isNotEmpty) {
        expect(tester.getRect(chip).overlaps(title), isFalse, reason: 'the pickup chip never under the title');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final dark in [false, true]) {
    testWidgets('166: at 360x640 the car, pins and chips stand apart (${dark ? 'dark' : 'light'})', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [rideRepositoryProvider.overrideWithValue(_Rides())],
          child: MaterialApp(
            theme: dark ? ThemeData.dark() : ThemeData.light(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: RideRequestSheet(
                  request: _open(),
                  shown: Duration.zero,
                  now: DateTime.now(),
                  me: const LatLng(3.165, 101.72),
                  awayKm: 1.2,
                  onAccept: () async {},
                  onSkip: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final map = tester.getRect(find.byType(RideMap));
      expect(map.height, greaterThanOrEqualTo(260), reason: 'not the 200 that stacked the pins');
      final car = tester.getRect(find.ancestor(of: find.byIcon(Icons.local_taxi), matching: find.byType(CircleAvatar)));
      final pickup = tester.getRect(find.byKey(const ValueKey('map-dot-pickup')));
      final drop = tester.getRect(find.byKey(const ValueKey('map-dot-drop')));
      final pickupChip = tester.getRect(find.byKey(const ValueKey('request-chip-pickup')));
      final tripChip = tester.getRect(find.byKey(const ValueKey('request-chip-trip')));
      final all = {'car': car, 'pickup': pickup, 'drop': drop, 'pickup chip': pickupChip, 'trip chip': tripChip};
      for (final a in all.entries) {
        expect(map.contains(a.value.topLeft) && map.contains(a.value.bottomRight - const Offset(1, 1)), isTrue,
            reason: '${a.key} inside the map');
        for (final b in all.entries) {
          if (a.key.compareTo(b.key) >= 0) continue;
          expect(a.value.deflate(1).overlaps(b.value.deflate(1)), isFalse, reason: '${a.key} clear of ${b.key}');
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  // Desktop 139, 140, 119 at 844 x 390 (a phone on its side), light and dark.
  for (final dark in [false, true]) {
    testWidgets('139/140/119: offers keep their text, the map pane its room, the pencil its name (${dark ? 'dark' : 'light'})',
        (tester) async {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [rideRepositoryProvider.overrideWithValue(_Rides())],
          child: MaterialApp(
            theme: dark ? ThemeData.dark() : ThemeData.light(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: RideRequestSheet(
                  request: _open(),
                  shown: Duration.zero,
                  now: DateTime.now(),
                  me: const LatLng(3.165, 101.72),
                  awayKm: 1.2,
                  onAccept: () async {},
                  onSkip: () {},
                  onOffer: (_) async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 139: every offer's amount drawn whole, at its full size.
      for (var i = 0; i < 3; i++) {
        final chip = find.byKey(ValueKey('request-offer-$i'));
        final text = tester.widget<Text>(find.descendant(of: chip, matching: find.byType(Text)));
        expect(text.data, matches(RegExp(r'^RM ?\d')), reason: 'offer $i shows its amount');
        final p = tester.renderObject<RenderParagraph>(find.descendant(of: chip, matching: find.byType(RichText)));
        expect(p.textScaler.scale(14), greaterThanOrEqualTo(14), reason: 'not shrunk');
        final r = tester.getRect(find.descendant(of: chip, matching: find.byType(RichText)));
        expect(r.width, greaterThanOrEqualTo(p.getMaxIntrinsicWidth(double.infinity) - 0.5), reason: 'whole');
        expect(r.left, greaterThanOrEqualTo(tester.getRect(chip).left - 0.5));
        expect(r.right, lessThanOrEqualTo(tester.getRect(chip).right + 0.5));
        expect(tester.getSemantics(chip).label, startsWith('Offer RM'));
      }
      // 140: the map pane wide enough; the zoom buttons never on a chip.
      final map = tester.getRect(find.byType(RideMap));
      expect(map.width, greaterThanOrEqualTo(220));
      final zoomIn = find.byTooltip('Zoom in');
      for (final k in ['request-chip-pickup', 'request-chip-trip']) {
        final chip = find.byKey(ValueKey(k));
        if (chip.evaluate().isEmpty || zoomIn.evaluate().isEmpty) continue;
        expect(tester.getRect(chip).overlaps(tester.getRect(zoomIn)), isFalse, reason: k);
      }
      // 119: the pencil is a button named "Offer another fare" itself.
      final pencil = tester.getSemantics(find.ancestor(of: find.byKey(const ValueKey('request-offer-custom')), matching: find.byType(Semantics)).first);
      final data = pencil.getSemanticsData();
      expect(data.label, contains('Offer another fare'));
      expect(data.flagsCollection.isButton, isTrue);
      expect(tester.takeException(), isNull);
      handle.dispose();
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('a whole fare drops its cents only where asked', () {
    expect(requestOfferShortFare('RM17.00'), 'RM17');
    expect(requestOfferShortFare('RM17.50'), 'RM17.50');
  });
}
