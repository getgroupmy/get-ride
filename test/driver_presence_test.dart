import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/data/driver_presence.dart';
import 'package:get_ride/src/features/partner/driver_online.dart';
import 'package:get_ride/src/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late List<String> reports;
  ({double lat, double lng})? at;

  DriverPresenceReporter reporter() =>
      DriverPresenceReporter(report: (online, lat, lng) async => reports.add('$online $lat $lng'), fix: () async => at);

  setUp(() {
    reports = [];
    at = (lat: 3.15, lng: 101.71);
  });

  testWidgets('online reports where the driver is, at once when they move, and offline once', (tester) async {
    {
      final r = reporter();
      r.setOnline(true);
      await tester.pump();
      expect(reports, ['true 3.15 101.71']);
      at = (lat: 3.16, lng: 101.72);
      await tester.pump(const Duration(seconds: 10));
      expect(reports.last, 'true 3.16 101.72', reason: 'moved: the next 10 s check-in sends');
      expect(reports, hasLength(2));
      r.setOnline(false);
      await tester.pump();
      expect(reports.last, 'false null null');
      await tester.pump(const Duration(minutes: 5));
      expect(reports, hasLength(3), reason: 'nothing more while offline');
    }
  });

  testWidgets('standing still: a heartbeat every 30 s, not every 10 s', (tester) async {
    final r = reporter();
    r.setOnline(true);
    await tester.pump();
    expect(reports, hasLength(1));
    at = (lat: 3.15005, lng: 101.71005); // about 8 m
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));
    expect(reports, hasLength(1), reason: 'under 15 m and under 30 s: skipped');
    await tester.pump(const Duration(seconds: 10));
    expect(reports, hasLength(2), reason: '30 s: the heartbeat');
    at = (lat: 3.1504, lng: 101.71005); // about 45 m on
    await tester.pump(const Duration(seconds: 10));
    expect(reports, hasLength(3), reason: 'moved 15 m: sent at once');
    r.dispose();
  });

  test('presenceReportDue', () {
    const here = (lat: 3.15, lng: 101.71);
    expect(presenceMetres(here, (lat: 3.15, lng: 101.7101)), closeTo(11.1, 0.5));
    expect(presenceReportDue(sinceLast: const Duration(seconds: 10), last: here, now: here), isFalse);
    expect(presenceReportDue(sinceLast: const Duration(seconds: 30), last: here, now: here), isTrue);
    expect(presenceReportDue(sinceLast: const Duration(seconds: 10), last: here, now: (lat: 3.1503, lng: 101.71)), isTrue);
    expect(presenceReportDue(sinceLast: const Duration(seconds: 10), last: here, now: null), isFalse);
    expect(presenceReportDue(sinceLast: const Duration(seconds: 10), last: null, now: here), isTrue);
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
      await tester.pump(const Duration(seconds: 10));
      expect(reports, ['true null null'], reason: 'a failed first report is tried again at the next check-in');
      r.dispose();
      await tester.pump();
      expect(reports.last, 'false null null', reason: 'signing out takes the driver offline');
      r.setOnline(true);
      await tester.pump(const Duration(minutes: 2));
      expect(reports, hasLength(2), reason: 'a disposed reporter is silent');
    }
  });

  test('the switch is remembered per account, so the Drive screen can put the driver back online', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer(overrides: [currentUserIdProvider.overrideWithValue('d1')]);
    addTearDown(c.dispose);
    final online = c.read(driverOnlineProvider.notifier);
    expect(await online.wasOnline(), isFalse);
    online.set(true);
    await pumpEventQueue();
    expect(await online.wasOnline(), isTrue);
    expect((await SharedPreferences.getInstance()).getBool(driverOnlineKey('d1')), isTrue);
    expect(c.read(driverOnlineProvider), isTrue);
    online.set(false);
    await pumpEventQueue();
    expect(await online.wasOnline(), isFalse, reason: 'the switch taken off is remembered too');

    // Another account on this phone has its own.
    final other = ProviderContainer(overrides: [currentUserIdProvider.overrideWithValue('d2')]);
    addTearDown(other.dispose);
    c.read(driverOnlineProvider.notifier).set(true);
    await pumpEventQueue();
    expect(await other.read(driverOnlineProvider.notifier).wasOnline(), isFalse);
  });

  testWidgets('opened offline after closing online: the server is told, once', (tester) async {
    final r = reporter();
    r.tellOffline();
    await tester.pump();
    expect(reports, ['false null null']);
    r.setOnline(true);
    await tester.pump();
    r.tellOffline();
    await tester.pump();
    expect(reports.last, startsWith('true'), reason: 'online: nothing to correct');
    r.setOnline(false);
    await tester.pump();
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
