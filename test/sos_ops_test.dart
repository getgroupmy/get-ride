// SOS to GET.ride's safety team (migration 0193): the settings, the incident
// as admins see it, the SOS sheet raising it, and the admin banner.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/safety/safety_incidents_screen.dart';
import 'package:get_ride/src/core/messaging.dart';
import 'package:get_ride/src/data/safety_incident_repository.dart';
import 'package:get_ride/src/features/safety/ride_sos.dart';

class _FakeRepo implements SafetyIncidentRepository {
  final raised = <String?>[];
  List<SafetyIncident> active = const [];

  @override
  Future<String> raise({String? rideId, double? lat, double? lng}) async {
    raised.add(rideId);
    return 'inc-1';
  }

  @override
  Future<bool> shareLocation(String incidentId, double lat, double lng) async => true;

  @override
  Future<List<SafetyIncident>> list({bool openOnly = false}) async => active;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test('settings read as stored, numbers as typed', () {
    final c = SosOpsConfig.fromJson({
      'onCall': ['a', 'b'],
      'smsNumbers': ['+60111'],
      'smsEnabled': false,
      'realertMinutes': 3,
      'locationMinutes': 45,
    });
    expect(c.onCall, ['a', 'b']);
    expect(c.smsEnabled, isFalse);
    expect(SosOpsConfig.fromJson(c.toJson()), c);
    expect(SosOpsConfig.fromJson(null), SosOpsConfig.standard);
    expect(parseOpsNumbers('+60 12-345 6789, 0198765432; bad\n+601'), ['+60123456789', '0198765432']);
  });

  test('an incident reads for the admin', () {
    final i = SafetyIncident({
      'id': 'x',
      'status': 'open',
      'reporter_role': 'partner',
      'reporter_name': 'Ali',
      'lat': 3.1,
      'lng': 101.7,
    });
    expect(i.roleLabel, 'Driver');
    expect(i.open, isTrue);
    expect(i.mapUri.toString(), 'https://maps.google.com/?q=3.1,101.7');
  });

  test('the ops alert channel only goes out', () {
    expect(MessagingChannel.fromId('ops_alert'), MessagingChannel.opsAlert);
    expect(MessagingChannel.opsAlert.directions, [MessagingDirection.outbound]);
    expect(messagingRouteTable(const []).where((r) => r.channel == MessagingChannel.opsAlert).map((r) => r.direction), [
      MessagingDirection.outbound,
    ]);
  });

  for (final b in Brightness.values) {
    testWidgets('choosing the safety team raises the SOS for the ride (${b.name})', (tester) async {
      final repo = _FakeRepo();
      final sharer = SosLocationSharer(repo, position: () async => null);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            safetyIncidentRepositoryProvider.overrideWithValue(repo),
            sosLocationSharerProvider.overrideWithValue(sharer),
          ],
          child: MaterialApp(
            theme: ThemeData(brightness: b),
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showRideSos(context, ref, plate: 'WXY1234', rideId: 'ride-9'),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining("GET.ride's safety team is told"), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sos-ops')));
      await tester.pumpAndSettle();
      expect(repo.raised, ['ride-9']);
      expect(sharer.running, isTrue, reason: 'the location keeps coming');
      expect(find.textContaining('has been alerted'), findsOneWidget);
      sharer.stop();
    });
  }

  testWidgets('the admin banner shows while an SOS waits', (tester) async {
    final repo = _FakeRepo()
      ..active = const [
        SafetyIncident({'id': 'x', 'status': 'open', 'reporter_role': 'rider', 'reporter_name': 'Siti'}),
      ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          safetyIncidentRepositoryProvider.overrideWithValue(repo),
          activeIncidentsProvider.overrideWith((ref) => repo.list(openOnly: true)),
        ],
        child: const MaterialApp(home: Scaffold(body: SosAdminBanner())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('SOS: passenger Siti needs help'), findsOneWidget);
  });

  testWidgets('no banner once acknowledged', (tester) async {
    final repo = _FakeRepo()
      ..active = const [
        SafetyIncident({'id': 'x', 'status': 'acknowledged', 'reporter_role': 'rider', 'reporter_name': 'Siti'}),
      ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [activeIncidentsProvider.overrideWith((ref) => repo.list(openOnly: true))],
        child: const MaterialApp(home: Scaffold(body: SosAdminBanner())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sos-admin-banner')), findsNothing);
  });
}
