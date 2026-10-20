import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/catalogue/service_order_screen.dart';
import 'package:get_ride/src/admin/screens/geo/airport_tabs.dart';
import 'package:get_ride/src/app.dart';
import 'package:get_ride/src/core/airport_queue.dart';
import 'package:get_ride/src/core/my_qr.dart';
import 'package:get_ride/src/data/service_order_repository.dart';
import 'package:get_ride/src/widgets/common.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Widget _app(Brightness b, Widget child) => MaterialApp(
  theme: appTheme(b),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  group('refusals read well', () {
    test('a driver taking a higher service\'s ride is told why (the hint)', () {
      const e = PostgrestException(
        message: 'SERVICE_ORDER_REFUSED',
        hint: "This ride is for a higher service than your vehicle's.",
      );
      expect(
        errorText(e),
        "This ride is for a higher service than your vehicle's.",
      );
    });

    test('GET.now with a lower service\'s driver: its own booking error', () {
      final e = QrBookingError.parse('SERVICE_ORDER_DIRECT: something');
      expect(e?.reason, QrBookingFailure.serviceTooLow);
      expect('$e', contains("can't take this service"));
    });
  });

  test('the warning before turning it on', () {
    expect(enforceWarning(0), isNull);
    expect(
      enforceWarning(1),
      startsWith('1 approved vehicle has no approved service type.'),
    );
    expect(enforceWarning(3), contains('their drivers'));
  });

  for (final b in Brightness.values) {
    testWidgets('vehicles without an approved service (${b.name})', (
      tester,
    ) async {
      VehicleMissingService? opened;
      await tester.pumpWidget(
        _app(
          b,
          MissingServiceList(
            vehicles: const [
              (
                id: 'v1',
                plate: 'ABC 123',
                label: 'Perodua Myvi',
                requested: 'c',
              ),
              (id: 'v2', plate: 'XYZ 9', label: '', requested: ''),
            ],
            serviceName: (id) => id == 'c' ? 'Comfort' : null,
            onOpen: (v) => opened = v,
          ),
        ),
      );
      expect(
        find.text('Vehicles without an approved service (2)'),
        findsOneWidget,
      );
      expect(find.text('Perodua Myvi · Asked for Comfort'), findsOneWidget);
      expect(find.text('No service asked for'), findsOneWidget);
      await tester.tap(find.text('ABC 123'));
      expect(opened?.id, 'v1');
    });

    testWidgets(
      'the airport tab shows the shared order and links to it (${b.name})',
      (tester) async {
        var opened = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(b),
            home: Scaffold(
              body: AirportQueueTab(
                settings: const AirportSettings(airportId: 'a'),
                zones: const [],
                services: const [
                  (id: 'r', name: 'Ride'),
                  (id: 'p', name: 'Premium'),
                ],
                serviceOrder: const ServiceOrder(['r', 'p']),
                onOpenServiceOrder: () => opened = true,
              ),
            ),
          ),
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('airport-open-service-order')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        final premium = find.byKey(const ValueKey('airport-service-p'));
        expect(
          find.descendant(of: premium, matching: find.text('Premium')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: premium, matching: find.text('2')),
          findsOneWidget,
        );
        expect(find.text('Highest (2)'), findsOneWidget);
        expect(
          find.byTooltip('Move Ride higher'),
          findsNothing,
          reason: 'read-only here',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('airport-open-service-order')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('airport-open-service-order')),
        );
        expect(opened, isTrue);
      },
    );
  }
}
