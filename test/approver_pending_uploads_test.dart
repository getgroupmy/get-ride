// Approvals → "Pending Upload" tab (migration 0389): lists every required
// document still missing across the approver's covered people, with a Notify
// button that sends an upload request and shows the running count + last-sent
// time. Widget test over ApproverInboxScreen with a fake repository.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/features/approver/approver_inbox_screen.dart';
import 'package:get_ride/src/providers.dart' show currentUserIdProvider;
import 'package:supabase_flutter/supabase_flutter.dart';

final _items = [
  PendingUpload(
    memberId: 'm1', memberName: 'Hasanul Bazari', memberPhone: '60123456789', source: 'partner',
    docKey: 'doc-dl', name: 'Driving License', sentCount: 0, location: 'Semenyih | Selangor | Malaysia'),
  PendingUpload(
    memberId: 'm2', memberName: 'Siti Aminah', source: 'partner',
    docKey: 'doc-dl', name: 'Driving License', sentCount: 2,
    lastSentAt: DateTime(2026, 11, 9, 18, 52)),
  // A missing vehicle document (v2): named by its plate, keyed per vehicle.
  PendingUpload(
    memberId: 'm2', memberName: 'Siti Aminah', source: 'vehicle',
    docKey: 'doc-voc', name: 'Vehicle Ownership Certificate',
    vehicleId: 'v9', plate: 'WVX 1234', sentCount: 0),
  // A member with no device to notify (no push token): the row says so.
  PendingUpload(
    memberId: 'm3', memberName: 'Zaid Noor', source: 'partner',
    docKey: 'doc-dl', name: 'Driving License', sentCount: 0, reachable: false),
  // A plain user (not a partner): listed separately under the Users section
  // (migration 0398).
  PendingUpload(
    memberId: 'm5', memberName: 'Nadia User', source: 'identity',
    docKey: 'doc-id', name: 'ID / Passport', sentCount: 0, isPartner: false),
];

class _FakeRepo extends ApproverInboxRepository {
  _FakeRepo()
      : super(SupabaseClient('http://localhost', 'test-anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));

  final List<(String, String, String, String?)> requested = [];

  @override
  Future<DocRequestStat> requestDocumentUpload(String memberId, String source, String docKey,
      {String? label, String? vehicleId}) async {
    requested.add((memberId, source, docKey, vehicleId));
    // m3 has no device, so the push can't reach them.
    return DocRequestStat(count: 1, lastSentAt: DateTime(2026, 11, 10, 3, 4), reachable: memberId != 'm3');
  }
}

Future<_FakeRepo> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1100, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repo = _FakeRepo();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUserIdProvider.overrideWith((ref) => 'me'),
        approverInboxRepositoryProvider.overrideWithValue(repo),
        approverPendingProvider.overrideWith((ref) async => const <ApproverDoc>[]),
        approverPendingUploadsProvider.overrideWith((ref) async => _items),
      ],
      child: MaterialApp(theme: appTheme(Brightness.light), home: const ApproverInboxScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('the Pending Upload tab lists missing docs and shows prior reminder stats', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('approvals-tab-pending')));
    await tester.pumpAndSettle();

    expect(find.text('Hasanul Bazari'), findsOneWidget);
    expect(find.text('Siti Aminah'), findsNWidgets(2)); // a partner doc + a vehicle doc
    // A vehicle document names its car by plate; a driver/partner document is
    // headed by the member's registered mobile number instead.
    expect(find.text('WVX 1234 · Vehicle Ownership Certificate'), findsOneWidget);
    expect(find.text('+60123456789 · Driving License'), findsOneWidget);
    // The service location shows under the document name.
    expect(find.byKey(const ValueKey('pending-upload-location-m1-partner--doc-dl')), findsOneWidget);
    expect(find.text('Semenyih | Selangor | Malaysia'), findsOneWidget);

    // The already-nudged member shows its count and last-sent time.
    expect(find.byKey(const ValueKey('pending-upload-count-m2-partner--doc-dl')), findsOneWidget);
    expect(find.textContaining('Requested 2×'), findsOneWidget);
    expect(find.textContaining('09 Nov 2026, 18:52'), findsOneWidget);

    // The never-nudged partner row has a plain "Notify" with no count line.
    expect(find.byKey(const ValueKey('pending-upload-count-m1-partner--doc-dl')), findsNothing);
    // The vehicle row has its own notify button, keyed per vehicle.
    expect(find.byKey(const ValueKey('pending-upload-notify-m2-vehicle-v9-doc-voc')), findsOneWidget);

    // The member with no device shows the "No device to notify" badge; reachable
    // members don't.
    expect(find.byKey(const ValueKey('pending-upload-nodevice-m3-partner--doc-dl')), findsOneWidget);
    expect(find.text('No device to notify'), findsOneWidget);
    expect(find.byKey(const ValueKey('pending-upload-nodevice-m1-partner--doc-dl')), findsNothing);
  });

  testWidgets('the Pending Upload tab splits Partners from Users under section headers', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('approvals-tab-pending')));
    await tester.pumpAndSettle();

    // Everyone (default): both section headers show, and the user row is listed.
    expect(find.byKey(const ValueKey('pending-section-partners')), findsOneWidget);
    expect(find.byKey(const ValueKey('pending-section-users')), findsOneWidget);
    expect(find.byKey(const ValueKey('pending-upload-row-m5-identity--doc-id')), findsOneWidget);
    expect(find.byKey(const ValueKey('pending-upload-row-m1-partner--doc-dl')), findsOneWidget);

    // Partners chip: the user row is hidden, the Users header gone.
    await tester.tap(find.byKey(const ValueKey('pending-kind-partner')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pending-upload-row-m5-identity--doc-id')), findsNothing);
    expect(find.byKey(const ValueKey('pending-section-users')), findsNothing);
    expect(find.byKey(const ValueKey('pending-upload-row-m1-partner--doc-dl')), findsOneWidget);

    // Users chip: only the user row, partners hidden.
    await tester.tap(find.byKey(const ValueKey('pending-kind-user')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pending-upload-row-m5-identity--doc-id')), findsOneWidget);
    expect(find.byKey(const ValueKey('pending-upload-row-m1-partner--doc-dl')), findsNothing);
  });

  testWidgets('Notify on an unreachable member still records the request and keeps the badge', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('approvals-tab-pending')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('pending-upload-notify-m3-partner--doc-dl')));
    await tester.tap(find.byKey(const ValueKey('pending-upload-notify-m3-partner--doc-dl')));
    await tester.pumpAndSettle();

    expect(repo.requested, [('m3', 'partner', 'doc-dl', null)]);
    // Still flagged as unreachable, and the request is logged (count shows).
    expect(find.byKey(const ValueKey('pending-upload-nodevice-m3-partner--doc-dl')), findsOneWidget);
    expect(find.byKey(const ValueKey('pending-upload-count-m3-partner--doc-dl')), findsOneWidget);
  });

  testWidgets('Notify sends an upload request and updates the row', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('approvals-tab-pending')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('pending-upload-notify-m1-partner--doc-dl')));
    await tester.pumpAndSettle();

    expect(repo.requested, [('m1', 'partner', 'doc-dl', null)]);
    // The row now shows the first reminder was sent.
    expect(find.byKey(const ValueKey('pending-upload-count-m1-partner--doc-dl')), findsOneWidget);
    expect(find.textContaining('Requested 1×'), findsOneWidget);
  });

  testWidgets('Notify on a vehicle row passes the vehicle id', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('approvals-tab-pending')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('pending-upload-notify-m2-vehicle-v9-doc-voc')));
    await tester.tap(find.byKey(const ValueKey('pending-upload-notify-m2-vehicle-v9-doc-voc')));
    await tester.pumpAndSettle();

    expect(repo.requested, [('m2', 'vehicle', 'doc-voc', 'v9')]);
  });

  testWidgets('an empty list shows the pending-upload empty state', (tester) async {
    tester.view.physicalSize = const Size(1100, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWith((ref) => 'me'),
          approverPendingProvider.overrideWith((ref) async => const <ApproverDoc>[]),
          approverPendingUploadsProvider.overrideWith((ref) async => const <PendingUpload>[]),
        ],
        child: MaterialApp(theme: appTheme(Brightness.light), home: const ApproverInboxScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('approvals-tab-pending')));
    await tester.pumpAndSettle();
    expect(find.text('Nothing pending upload'), findsOneWidget);
  });
}
