// Admin › Hire bookings (migrations 0327, 0328), light and dark: every
// booking newest first with its package, first and last day, days,
// service, rider (masked phone), driver or "No driver yet", total, payment
// and status; the filters reach the server's query; "Load more" pages.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/hire_bookings_screen.dart';
import 'package:get_ride/src/app.dart';
import 'package:get_ride/src/core/multi_day_hire.dart';

AdminHireBooking _row(String id, {String status = 'booked', String? driver, int total = 2}) =>
    AdminHireBooking.fromRow({
      'id': id,
      'package': 'weekly',
      'title': 'Weekly hire',
      'status': status,
      'service': 'Saloon',
      'first_at': DateTime(2026, 11, 2, 9).toUtc().toIso8601String(),
      'last_at': DateTime(2026, 11, 13, 9).toUtc().toIso8601String(),
      'days': 10,
      'price': 2400,
      'paid_amount': 2400,
      'payment_plan': 'prepay',
      'payment_state': 'paid',
      'currency': 'MYR',
      'rider_name': 'Aina Mingguan',
      'rider_phone': '+60123456789',
      'partner_name': driver,
      'total': total,
    });

void main() {
  test('listed under Operations with the Rides page\'s access', () {
    final e = allAdminEntries.firstWhere((e) => e.path == hireBookingsPath);
    expect((e.section, e.title), ('Operations', 'Hire bookings'));
    expect(e.pages, ['admin-rides']);
  });

  test('a row in words', () {
    final b = _row('b1');
    expect(adminHireBookingDates(b), 'Mon 2 Nov to Fri 13 Nov · 10 days · Saloon');
    expect(adminHireBookingPeople(b), 'Rider Aina Mingguan · +6012•••6789 · No driver yet');
    expect(adminHireBookingPeople(_row('b2', driver: 'Ali')), endsWith('Driver Ali'));
    expect(b.paymentLabel, 'Paid');
  });

  for (final b in Brightness.values) {
    testWidgets('${b.name} mode: the list, its filters and paging', (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final asked = <HireBookingsQuery>[];
      await tester.pumpWidget(ProviderScope(
        overrides: [
          moduleAccessProvider.overrideWith((ref, m) => AccessLevel.edit),
          adminHireBookingsProvider.overrideWith((ref, q) async {
            asked.add(q);
            return (rows: [_row('b1'), _row('b2', status: 'assigned', driver: 'Ali')],
                total: q.limit > 50 ? 2 : 60);
          }),
        ],
        child: MaterialApp(theme: appTheme(b), home: const AdminHireBookingsScreen()),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Hire bookings'), findsOneWidget);
      expect(find.byKey(const ValueKey('hire-bookings-row-b1')), findsOneWidget);
      expect(find.text('Rider Aina Mingguan · +6012•••6789 · No driver yet'), findsOneWidget);
      expect(find.textContaining('Driver Ali'), findsOneWidget);
      expect(find.text('Mon 2 Nov to Fri 13 Nov · 10 days · Saloon'), findsNWidgets(2));
      expect(find.text('Driver confirmed'), findsWidgets);
      expect(find.byKey(const ValueKey('hire-bookings-from')), findsOneWidget);
      // Filters go to the server.
      await tester.tap(find.byKey(const ValueKey('hire-bookings-package-monthly')));
      await tester.pumpAndSettle();
      expect(asked.last.package, 'monthly');
      await tester.tap(find.text('In progress'));
      await tester.pumpAndSettle();
      expect(asked.last.status, 'in_progress');
      await tester.enterText(find.byType(TextField).first, '0123');
      await tester.pumpAndSettle();
      expect(asked.last.query, '0123');
      // 2 of 60: Load more asks for the next page.
      expect(find.text('2 of 60'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('load-more')));
      await tester.pumpAndSettle();
      expect(asked.last.limit, 100);
    });
  }
}
