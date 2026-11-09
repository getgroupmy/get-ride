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
    memberId: 'm1', memberName: 'Hasanul Bazari', source: 'partner',
    docKey: 'doc-dl', name: 'Driving License', sentCount: 0),
  PendingUpload(
    memberId: 'm2', memberName: 'Siti Aminah', source: 'partner',
    docKey: 'doc-dl', name: 'Driving License', sentCount: 2,
    lastSentAt: DateTime(2026, 11, 9, 18, 52)),
];

class _FakeRepo extends ApproverInboxRepository {
  _FakeRepo()
      : super(SupabaseClient('http://localhost', 'test-anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));

  final List<(String, String, String)> requested = [];

  @override
  Future<DocRequestStat> requestDocumentUpload(String memberId, String source, String docKey,
      {String? label, String? vehicleId}) async {
    requested.add((memberId, source, docKey));
    return DocRequestStat(count: 1, lastSentAt: DateTime(2026, 11, 10, 3, 4));
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
    expect(find.text('Siti Aminah'), findsOneWidget);
    expect(find.text('Driving License'), findsNWidgets(2));

    // The already-nudged member shows its count and last-sent time.
    expect(find.byKey(const ValueKey('pending-upload-count-m2-doc-dl')), findsOneWidget);
    expect(find.textContaining('Requested 2×'), findsOneWidget);
    expect(find.textContaining('09 Nov 2026, 18:52'), findsOneWidget);

    // The never-nudged member has a plain "Notify" with no count line.
    expect(find.byKey(const ValueKey('pending-upload-count-m1-doc-dl')), findsNothing);
  });

  testWidgets('Notify sends an upload request and updates the row', (tester) async {
    final repo = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('approvals-tab-pending')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('pending-upload-notify-m1-doc-dl')));
    await tester.pumpAndSettle();

    expect(repo.requested, [('m1', 'partner', 'doc-dl')]);
    // The row now shows the first reminder was sent.
    expect(find.byKey(const ValueKey('pending-upload-count-m1-doc-dl')), findsOneWidget);
    expect(find.textContaining('Requested 1×'), findsOneWidget);
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
