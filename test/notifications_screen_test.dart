import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/inbox.dart';
import 'package:get_ride/src/data/notifications_repository.dart';
import 'package:get_ride/src/features/notifications/notifications_screen.dart';

void main() {
  final now = DateTime(2026, 10, 13, 15);

  Future<void> pump(WidgetTester tester, List<InboxItem> items, {String? mode}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationsProvider.overrideWith((_) => Stream.value(items)),
          if (mode != null) appModeProvider.overrideWith(() => _FixedMode(mode)),
        ],
        child: MaterialApp(home: NotificationsScreen(now: now)),
      ),
    );
    await tester.pumpAndSettle();
  }

  InboxItem item(String id, {String? mode, bool read = false, String title = 'Ride confirmed'}) => InboxItem(
    id: id,
    title: title,
    body: 'Pick up at KLCC.',
    data: const {'type': 'ride_status', 'request_id': 'r1'},
    kind: 'ride_status',
    mode: mode,
    createdAt: now.subtract(const Duration(minutes: 5)),
    readAt: read ? now : null,
  );

  testWidgets('lists them, unread marked, with Mark all read', (tester) async {
    await pump(tester, [item('a'), item('b', read: true, title: 'Driver arrived')]);
    expect(find.text('Ride confirmed'), findsOneWidget);
    expect(find.text('Driver arrived'), findsOneWidget);
    expect(find.text('5 min ago'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('notification-unread-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('notification-unread-b')), findsNothing);
    expect(find.byKey(const ValueKey('notifications-read-all')), findsOneWidget);
  });

  testWidgets("the other mode's are left out", (tester) async {
    await pump(tester, [item('a', mode: 'partner', title: 'Driver news'), item('b', title: 'Mine')], mode: 'rider');
    expect(find.text('Driver news'), findsNothing);
    expect(find.text('Mine'), findsOneWidget);
  });

  testWidgets('empty, and nothing to mark read', (tester) async {
    await pump(tester, const []);
    expect(find.text('No notifications yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('notifications-read-all')), findsNothing);
  });

  testWidgets('dark theme draws too', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationsProvider.overrideWith((_) => Stream.value([item('a')])),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: NotificationsScreen(now: now),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ride confirmed'), findsOneWidget);
  });
}

class _FixedMode extends AppModeNotifier {
  _FixedMode(this.mode);
  final String mode;

  @override
  String? build() => mode;
}
