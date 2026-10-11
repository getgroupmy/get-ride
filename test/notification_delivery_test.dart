import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/push_screen.dart';
import 'package:get_ride/src/core/notification_delivery.dart';
import 'package:get_ride/src/core/push_logic.dart';

void main() {
  group('trip pushes', () {
    test('a retried push carries its event id, to acknowledge', () {
      expect(pushEventId({'type': 'ride_status', 'event_id': ' r1:arrived:r '}), 'r1:arrived:r');
      expect(pushEventId({'type': 'ride_request'}), isNull);
      expect(pushEventId({'event_id': ''}), isNull);
    });

    test('a trip update opens each side\'s trip', () {
      expect(pushRouteFor({'type': 'ride_status', 'request_id': 'r1', 'role': 'rider'}), '/ride/r1');
      expect(pushRouteFor({'type': 'ride_status', 'request_id': 'r1', 'role': 'partner'}), '/drive/trip/r1');
      expect(pushRouteFor({'type': 'ride_cancel_request', 'request_id': 'r1', 'role': 'rider'}), '/ride/r1');
      expect(pushRouteFor({'type': 'ride_status'}), isNull);
    });
  });

  group('delivery stats', () {
    final rows = [
      NotificationDelivery.fromRow({
        'kind': 'ride_status',
        'priority': 'critical',
        'sent': 40,
        'delivered': 38,
        'pending': 1,
        'gave_up': 1,
        'avg_ack_seconds': '4.2',
        'avg_attempts': 1.1,
      }),
      NotificationDelivery.fromRow({'kind': 'ride_payment', 'priority': 'normal', 'sent': 10, 'delivered': 7}),
    ];

    test('rows read as the admin sees them', () {
      expect(rows[0].label, 'Trip updates');
      expect(rows[0].avgAckSeconds, 4.2);
      expect(deliveryRateText(rows[0].rate), '95%');
      expect(rows[1].label, 'Payments');
      expect(rows[1].gaveUp, 0);
      expect(deliveryRateText(overallDeliveryRate(rows)), '90%');
      expect(deliveryRateText(null), '—');
      expect(ackTimeText(4.2), '4 s');
      expect(ackTimeText(300), '5 min');
      expect(ackTimeText(null), '—');
    });

    Future<void> pump(WidgetTester tester, List<NotificationDelivery> data, ThemeMode mode) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [notificationDeliveryProvider.overrideWith((_) async => data)],
          child: MaterialApp(
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            themeMode: mode,
            home: Scaffold(body: Consumer(builder: (context, ref, _) => const DeliveryCard())),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('the admin card shows the delivery rate per kind (light)', (tester) async {
      await pump(tester, rows, ThemeMode.light);
      expect(find.byKey(const ValueKey('push-delivery-rate')), findsOneWidget);
      expect(find.text('90%'), findsOneWidget);
      expect(find.text('Trip updates · critical'), findsOneWidget);
      expect(find.textContaining('38/40 delivered'), findsOneWidget);
    });

    testWidgets('and says so when nothing was sent (dark)', (tester) async {
      await pump(tester, const [], ThemeMode.dark);
      expect(find.text('No trip pushes yet.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
