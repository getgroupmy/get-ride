// App Release (admin): which destinations each store offers, how a run
// reads, and how an edge function's answer becomes what the card shows.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/meterapp/app_release_screen.dart';

void main() {
  test('destinations match the release workflows', () {
    expect(releaseDestinations[ReleasePlatform.ios]!.map((d) => d.value), ['testflight', 'appstore']);
    expect(releaseDestinations[ReleasePlatform.android]!.map((d) => d.value),
        ['internal', 'alpha', 'beta', 'production']);
    expect(releaseInput(ReleasePlatform.ios), 'lane');
    expect(releaseInput(ReleasePlatform.android), 'track');
    expect(releaseFunction(ReleasePlatform.android), 'android-release');
  });

  test('store-facing destinations say review still applies', () {
    final appStore = releaseDestinations[ReleasePlatform.ios]!.firstWhere((d) => d.value == 'appstore');
    final production = releaseDestinations[ReleasePlatform.android]!.firstWhere((d) => d.value == 'production');
    expect(appStore.detail.toLowerCase(), contains('review'));
    expect(production.detail.toLowerCase(), contains('review'));
  });

  test('describeRun', () {
    expect(describeRun('queued', null).label, 'Queued');
    expect(describeRun('in_progress', null).tone, RunTone.warning);
    expect(describeRun('completed', 'success').tone, RunTone.success);
    expect(describeRun('completed', 'failure').label, 'Failed');
    expect(describeRun('completed', 'timed_out').label, 'Timed out');
  });

  test('releaseStateFrom: only 503 / 404 read as not set up', () {
    expect(releaseStateFrom(503, {'error': 'add the token'}).kind, ReleaseStateKind.notConfigured);
    expect(releaseStateFrom(503, {'error': 'add the token'}).message, 'add the token');
    expect(releaseStateFrom(404, null).kind, ReleaseStateKind.notConfigured);
    expect(releaseStateFrom(403, {'error': 'no'}).kind, ReleaseStateKind.forbidden);
    expect(releaseStateFrom(502, {'error': 'GitHub down'}).message, 'GitHub down');
  });

  test('releaseStateFrom parses runs', () {
    final s = releaseStateFrom(200, {
      'runs': [
        {'id': 7, 'number': 3, 'status': 'completed', 'conclusion': 'success', 'startedAt': '2026-10-04T10:00:00Z', 'url': 'u'},
      ],
    });
    expect(s.kind, ReleaseStateKind.ok);
    expect(s.runs.single.number, 3);
    expect(s.runs.single.startedAt, DateTime.utc(2026, 10, 4, 10));
    expect(releaseStateFrom(200, {}).runs, isEmpty);
  });

  test('App Release is listed under Meter & app', () {
    final entry = allAdminEntries.firstWhere((e) => e.path == '/admin/m/app-release');
    expect(entry.pages, [appReleasePage]);
    expect(entry.section, 'Meter & app');
  });
}
