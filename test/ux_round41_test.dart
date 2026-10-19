// Web UX round 41 (183, 184, 186-188), light and dark: Navigation app rows
// stay neutral, Mark all read is a button, the pickup wheels show the same
// rows and balanced columns, the promo sheet says where codes come from,
// and the route card's time never breaks.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/inbox.dart';
import 'package:get_ride/src/core/scheduled_rides.dart';
import 'package:get_ride/src/data/geo_service.dart' show Place;
import 'package:get_ride/src/data/notifications_repository.dart';
import 'package:get_ride/src/features/notifications/notifications_screen.dart';
import 'package:get_ride/src/features/ride/confirm_parts.dart';
import 'package:get_ride/src/features/ride/promo_parts.dart' show showPromoCodeSheet;
import 'package:get_ride/src/core/promo_codes.dart' show PromoCheckResult;
import 'package:get_ride/src/features/ride/pickup_time_sheet.dart';
import 'package:get_ride/src/features/settings/navigation_app_card.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _config = ScheduledRidesConfig(enabled: true, minLeadMinutes: 30, maxDaysAhead: 2, lateCancelFee: 5);

void main() {
  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';
    ThemeData theme() => ThemeData(brightness: dark ? Brightness.dark : Brightness.light);

    testWidgets('183: the chosen navigation app keeps neutral ink; the tick says it ($mode)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(theme: theme(), home: const Scaffold(body: NavigationAppCard(apple: false))),
      ));
      await tester.pump();
      final row = find.byKey(const ValueKey('nav-app-google'));
      final ink = theme().colorScheme.onSurface;
      final title = tester.renderObject<RenderParagraph>(
        find.descendant(of: row, matching: find.byType(RichText)).first,
      );
      expect(title.text.style?.color, ink, reason: 'not the accent');
      final icon = IconTheme.of(tester.element(find.descendant(of: row, matching: find.byIcon(Icons.map_outlined))));
      expect(icon.color, ink);
      expect(find.descendant(of: row, matching: find.byIcon(Icons.check)), findsOneWidget);
    });

    testWidgets('184: Mark all read is a button in the button style ($mode)', (tester) async {
      final now = DateTime(2026, 10, 13, 15);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          notificationsProvider.overrideWith((_) => Stream.value([
                InboxItem(
                  id: 'n1',
                  title: 'Ride confirmed',
                  body: 'Pick up at KLCC.',
                  data: const {'type': 'ride_status', 'request_id': 'r1'},
                  kind: 'ride_status',
                  createdAt: now.subtract(const Duration(minutes: 5)),
                ),
              ])),
        ],
        child: MaterialApp(theme: theme(), home: NotificationsScreen(now: now)),
      ));
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('notifications-read-all'));
      expect(tester.widget(button), isA<TextButton>());
      final text = tester.renderObject<RenderParagraph>(find.descendant(of: button, matching: find.byType(RichText)));
      expect(text.text.style?.color, theme().colorScheme.primary);
      final title = tester.renderObject<RenderParagraph>(
        find.descendant(of: find.byType(AppBar), matching: find.text('Notifications')).evaluate().isEmpty
            ? find.text('Notifications')
            : find.descendant(of: find.byType(AppBar), matching: find.byType(RichText)).first,
      );
      expect(text.text.style?.color, isNot(title.text.style?.color), reason: 'not the title ink');
    });

    for (final width in const [360.0, 412.0]) {
      testWidgets('186: four wheels, the same rows and balanced columns at ${width.toInt()} ($mode)', (tester) async {
        tester.view.physicalSize = Size(width, 860);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final now = DateTime(2026, 10, 15, 16, 52);
        await tester.pumpWidget(MaterialApp(
          theme: theme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showPickupTimeSheet(context, _config, clock: () => now),
                child: const Text('open'),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        final wheels = ['day', 'hour', 'minute', 'ampm'].map((k) => find.byKey(ValueKey('pickup-$k-wheel'))).toList();
        final rects = [for (final w in wheels) tester.getRect(w)];
        // The day shows rows above Today (faint), as many as the clock wheels.
        final band = tester.getRect(find.byKey(const ValueKey('pickup-band')));
        int rowsShown(Finder wheel) => find
            .descendant(of: wheel, matching: find.byType(Text))
            .evaluate()
            .map((e) => tester.getRect(find.byWidget(e.widget)))
            .where((r) => r.center.dy >= rects[0].top && r.center.dy <= rects[0].bottom)
            .length;
        expect(rowsShown(wheels[0]), rowsShown(wheels[1]), reason: 'day as many rows as hour');
        expect(rowsShown(wheels[0]), greaterThanOrEqualTo(5));
        expect(find.descendant(of: wheels[0], matching: find.text('Today')), findsOneWidget);
        expect(tester.getRect(find.text('Today')).center.dy, closeTo(band.center.dy, 2));
        // Day 3 parts, each other 2: no wide gap, room for the clock.
        expect(rects[0].width / rects[1].width, closeTo(1.5, 0.05));
        expect(rects[1].width, closeTo(rects[2].width, 0.01));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('187: the promo sheet says where a code comes from ($mode)', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: theme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showPromoCodeSheet(
                context,
                offers: const [],
                applied: null,
                fare: 20,
                onCheck: (_) async => const PromoCheckResult.refused('not_found'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text("From a GET.ride campaign or a friend's invite"), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const ValueKey('promo-help'))).bottom,
        lessThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('promo-code'))).top),
      );
    });

    for (final scale in const [1.0, 1.3]) {
      testWidgets('188: "~14 min" stays whole beside a long name at 360 @$scale ($mode)', (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
          theme: theme(),
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: ConfirmAddressCard(
              pickup: const Place(name: 'Eco Majestic', address: 'Semenyih', point: LatLng(2.93, 101.83)),
              drop: const Place(name: 'KLCC - Petronas Twin Towers', address: 'Kuala Lumpur', point: LatLng(3.15, 101.71)),
              stops: const [],
              duration: '~14 min',
              entrance: '',
              onPickup: () {},
              onDrop: () {},
              onEntrance: () {},
              onStops: () {},
              onAddStop: () {},
            ),
          ),
        ));
        final eta = tester.widget<Text>(find.byKey(const ValueKey('confirm-duration')));
        expect(eta.data, '~14 min');
        expect(eta.maxLines, 1);
        final p = tester.renderObject<RenderParagraph>(
          find.descendant(of: find.byKey(const ValueKey('confirm-duration')), matching: find.byType(RichText)),
        );
        expect(p.didExceedMaxLines, isFalse);
        expect(p.size.width, greaterThanOrEqualTo(p.getMaxIntrinsicWidth(double.infinity) - 0.5), reason: 'whole');
        final name = tester.getRect(find.byKey(const ValueKey('confirm-drop-name')));
        expect(tester.getRect(find.byKey(const ValueKey('confirm-duration'))).left, greaterThanOrEqualTo(name.right));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
