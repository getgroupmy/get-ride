import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/driver_presence.dart';
import 'package:get_ride/src/features/partner/driver_online.dart';
import 'package:get_ride/src/providers.dart';

void main() {
  late List<String> reports;
  ({double lat, double lng})? at;

  DriverPresenceReporter reporter() =>
      DriverPresenceReporter(report: (online, lat, lng) async => reports.add('$online $lat $lng'), fix: () async => at);

  setUp(() {
    reports = [];
    at = (lat: 3.15, lng: 101.71);
  });

  testWidgets('online reports where the driver is, every minute, and offline once', (tester) async {
    {
      final r = reporter();
      r.setOnline(true);
      await tester.pump();
      expect(reports, ['true 3.15 101.71']);
      at = (lat: 3.16, lng: 101.72);
      await tester.pump(const Duration(seconds: 61));
      expect(reports.last, 'true 3.16 101.72');
      expect(reports, hasLength(2));
      r.setOnline(false);
      await tester.pump();
      expect(reports.last, 'false null null');
      await tester.pump(const Duration(minutes: 5));
      expect(reports, hasLength(3), reason: 'nothing more while offline');
    }
  });

  testWidgets('no location still says the driver is online; a failed report is not fatal', (tester) async {
    {
      at = null;
      var fail = true;
      final r = DriverPresenceReporter(
        report: (online, lat, lng) async {
          if (fail) throw StateError('offline');
          reports.add('$online $lat $lng');
        },
        fix: () async => at,
      );
      r.setOnline(true);
      await tester.pump();
      expect(reports, isEmpty);
      fail = false;
      await tester.pump(const Duration(seconds: 61));
      expect(reports, ['true null null']);
      r.dispose();
      await tester.pump();
      expect(reports.last, 'false null null', reason: 'signing out takes the driver offline');
      r.setOnline(true);
      await tester.pump(const Duration(minutes: 2));
      expect(reports, hasLength(2), reason: 'a disposed reporter is silent');
    }
  });

  testWidgets('the provider follows the Drive switch', (tester) async {
    {
      final c = ProviderContainer(
        overrides: [
          currentUserIdProvider.overrideWithValue('me'),
          driverPresenceReporterFactoryProvider.overrideWithValue(reporter),
        ],
      );
      c.read(driverPresenceProvider);
      await tester.pump();
      expect(reports, isEmpty, reason: 'offline to begin with');
      c.read(driverOnlineProvider.notifier).set(true);
      await tester.pump();
      expect(reports, ['true 3.15 101.71']);
      c.read(driverOnlineProvider.notifier).set(false);
      await tester.pump();
      expect(reports.last, 'false null null');
      c.dispose();
    }
  });
}
