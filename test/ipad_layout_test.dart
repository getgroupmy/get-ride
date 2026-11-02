// An iPad in portrait (820 × 1180, 768 × 1024) gets the side panel beside
// the map, as wider screens do, not a phone's full-width sheet (0333).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/map_sheet_layout.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Rides implements RideRepository {
  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('the wide layout starts where the rail does', () {
    expect(wideLayoutMinWidth, 720);
    expect(wideLayoutAt(const Size(820, 1180)), isTrue);
    expect(wideLayoutAt(const Size(768, 1024)), isTrue);
    expect(wideLayoutAt(const Size(844, 390)), isFalse, reason: 'a phone on its side keeps the phone layout');
    expect(wideLayoutAt(const Size(412, 915)), isFalse);
    expect(driverPanelWidth(1366), 520);
    expect(driverPanelWidth(768), closeTo(422.4, 0.01));
    expect(driverPanelWidth(820), closeTo(451, 0.01));
  });

  for (final size in const [Size(820, 1180), Size(768, 1024)]) {
    for (final b in Brightness.values) {
      testWidgets('Drive on an iPad ${size.width.round()} × ${size.height.round()}: panel beside the map (${b.name})',
          (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        final open = StreamController<List<RideRequest>>.broadcast();
        addTearDown(open.close);
        final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => const PartnerScreen())]);
        await tester.pumpWidget(ProviderScope(
          overrides: [
            partnerProvider.overrideWith((ref) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Ali'})),
            openRequestsProvider.overrideWith((ref) => open.stream),
            rideRepositoryProvider.overrideWithValue(_Rides()),
            driverPositionProvider.overrideWithValue(() async => const LatLng(3.1579, 101.7116)),
            driverPositionStreamProvider.overrideWithValue(() => const Stream.empty()),
            profileProvider.overrideWith((ref) async => Profile({'id': 'me'})),
            assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
            partnerDocCheckProvider.overrideWithValue((_, {required teksi}) async => const []),
            partnerTypeEntriesProvider.overrideWith(
              (ref) async => [(id: 'e', values: <String, dynamic>{'name': 'eHailing', 'vehicleRequired': false})],
            ),
          ],
          child: MaterialApp.router(
            theme: ThemeData(brightness: b, useMaterial3: true),
            routerConfig: router,
          ),
        ));
        await tester.pumpAndSettle();
        expect(find.byType(VerticalDivider), findsWidgets, reason: 'the side panel, not a bottom sheet');
        expect(find.byType(MapSheetLayout), findsNothing);
        expect(find.text('You are offline'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
