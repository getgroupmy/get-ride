// Web UX round 43 (190, 193) at 317 x 704 (412 at 1.3x) and 360, light and
// dark: the Add a stop sheet says "Stop" and shows the trip it joins; a
// transaction's title takes two lines before the amount.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/map_profile.dart';
import 'package:get_ride/src/core/place_gates.dart';
import 'package:get_ride/src/core/wallet_history.dart';
import 'package:get_ride/src/data/app_display_repository.dart' show recentPlacesProvider;
import 'package:get_ride/src/data/geo_service.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/place_gates_repository.dart';
import 'package:get_ride/src/data/saved_places_repository.dart';
import 'package:get_ride/src/features/ride/place_search.dart';
import 'package:get_ride/src/features/wallet/wallet_history_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

const _klcc = Place(name: 'KLCC', address: 'Kuala Lumpur', point: LatLng(3.158, 101.712));
const _sentral = Place(name: 'KL Sentral', address: 'Kuala Lumpur', point: LatLng(3.134, 101.686));
const _pavilion = Place(name: 'Pavilion', address: 'Bukit Bintang, Kuala Lumpur', point: LatLng(3.149, 101.713));

void main() {
  test('190: the trip a stop joins, in order', () {
    expect(addStopRouteLine(_klcc, const [], _sentral), 'KLCC › KL Sentral');
    expect(addStopRouteLine(_klcc, const [_pavilion], _sentral), 'KLCC › Pavilion › KL Sentral');
    expect(addStopRouteLine(null, const [], _sentral), isNull);
  });

  for (final b in Brightness.values) {
    for (final size in const [Size(317, 704), Size(360, 640)]) {
      final at = '${size.width.toInt()}x${size.height.toInt()}, ${b.name}';

      testWidgets('190: Add a stop says "Stop" and shows KLCC › KL Sentral over the field ($at)', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final geo = GeoService(
          client: MockClient((_) async => http.Response('', 500)),
          profile: () => const MapProfile(smartAddress: 'all'),
        );
        await tester.pumpWidget(ProviderScope(
          overrides: [
            recentPlacesProvider.overrideWith((ref) async => const [_pavilion]),
            savedPlacesProvider.overrideWith((ref) async => const []),
            currentUserIdProvider.overrideWithValue('u1'),
            geoServiceProvider.overrideWithValue(geo),
            placeGatesProvider.overrideWith((ref) async => (places: <GateRow>[], gates: <GateRow>[])),
          ],
          child: MaterialApp(
            theme: ThemeData(brightness: b),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showPlaceSearch(
                    context,
                    title: 'Add a stop',
                    fieldLabel: 'Stop',
                    routeLine: addStopRouteLine(_klcc, const [], _sentral),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('Stop'), findsOneWidget);
        expect(find.text('To'), findsNothing, reason: 'not "To"');
        final line = find.byKey(const ValueKey('place-search-route-line'));
        expect(tester.widget<Text>(line).data, 'KLCC › KL Sentral');
        expect(tester.getRect(line).bottom, lessThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('place-search-field'))).top));
        // Recents read as search results do (177).
        expect(find.text('Bukit Bintang, Kuala Lumpur'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('193: "Transfer Received" whole on two lines before the amount ($at)', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final now = DateTime(2026, 5, 20, 12);
        final tx = WalletTransaction({
          'id': 't1',
          'wallet_type': 'get_wallet',
          'kind': 'transfer_in',
          'amount': 1250.0,
          'created_at': now.toUtc().toIso8601String(),
        });
        await tester.pumpWidget(ProviderScope(
          overrides: [
            partnerProvider.overrideWith((ref) async => null),
            walletHistoryProvider.overrideWith((ref, m) async => m == historyMonths(now).first ? [tx] : const []),
          ],
          child: MaterialApp(theme: ThemeData(brightness: b), home: WalletHistoryScreen(now: now)),
        ));
        await tester.pumpAndSettle();
        final title = find.byKey(const ValueKey('history-title-t1'));
        expect(tester.widget<Text>(title).maxLines, 2);
        final p = tester.renderObject<RenderParagraph>(find.descendant(of: title, matching: find.byType(RichText)));
        // It wraps to a second line rather than stopping at "Transfer Rece…"
        // on one (the test font draws every letter a square, wider than any
        // real one, so how much fits is not measured here).
        final line = p.getMaxIntrinsicHeight(double.infinity);
        expect(p.size.height, greaterThan(line * 1.5), reason: 'two lines in use');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
