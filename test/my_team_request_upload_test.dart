// My Team — "Request upload" (migration 0384): while a document isn't approved,
// an approver with can_upload can push the member to upload it, and the button
// then shows how many reminders have been sent. Widget tests over the member
// Documents tab with a fake repository, plus a pure test of the relative-time
// label.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/approver_inbox_repository.dart';
import 'package:get_ride/src/features/approver/my_team_screen.dart';
import 'package:get_ride/src/providers.dart' show currentUserIdProvider;
import 'package:supabase_flutter/supabase_flutter.dart';

ApproverGrant _grant({bool upload = true}) => ApproverGrant(
      canApprove: true, canUpload: upload, canDelete: false, deleteHard: false,
      canCredit: false, canEditProfile: false, canVerifyId: false,
      scope: 'all', docTypes: const [],
    );

const _member = TeamMember(id: 'm1', name: 'Mohd Faizul', status: 'approved');

const _pendingDoc = ApproverDoc(
  source: 'partner', id: 'doc-1', ownerId: 'm1', ownerName: 'Mohd Faizul',
  ownerPhone: '+60123456789', docKey: 'driver_licence', docLabel: "Driver's Licence",
  fileUrl: null, fileUrlBack: null, status: 'Pending Review',
);

class _FakeRepo extends ApproverInboxRepository {
  _FakeRepo({this.stats = const {}})
      : super(SupabaseClient('http://localhost', 'test-anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));

  final Map<String, DocRequestStat> stats;
  ({String member, String source, String key, String? label, String? vehicle})? lastRequest;
  int _count = 0;

  @override
  Future<List<ApproverDoc>> ownerDocuments(String ownerId) async => const [_pendingDoc];

  @override
  Future<Map<String, DocRequestStat>> documentRequestStats(String memberId) async => stats;

  @override
  Future<DocRequestStat> requestDocumentUpload(String memberId, String source, String docKey,
      {String? label, String? vehicleId}) async {
    lastRequest = (member: memberId, source: source, key: docKey, label: label, vehicle: vehicleId);
    _count += 1;
    return DocRequestStat(count: _count, lastSentAt: DateTime.now());
  }
}

Future<_FakeRepo> _pumpDocs(WidgetTester tester, {Map<String, DocRequestStat> stats = const {}}) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repo = _FakeRepo(stats: stats);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        approverInboxRepositoryProvider.overrideWithValue(repo),
        currentUserIdProvider.overrideWith((ref) => 'me'),
        approverSelfProvider.overrideWith((ref) async => _grant()),
        approverMemberWalletProvider.overrideWith((ref, id) async => null),
        approverOwnerDocumentsProvider.overrideWith((ref, id) async => const [_pendingDoc]),
        approverOwnerDocMetaProvider.overrideWith((ref, id) async => const <String, dynamic>{}),
        approverAddableDocsProvider.overrideWith((ref, id) async => const <AddableDoc>[]),
        approverDocumentRequestStatsProvider.overrideWith((ref, id) async => stats),
      ],
      child: MaterialApp(theme: appTheme(Brightness.light), home: const MyTeamMemberScreen(member: _member)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('member-tab-documents')));
  await tester.pumpAndSettle();
  return repo;
}

const _requestKey = ValueKey('doc-request-partner-doc-1');

void main() {
  testWidgets('a pending document shows Request upload; tapping it sends with the right args', (tester) async {
    final repo = await _pumpDocs(tester);

    final btn = find.byKey(_requestKey);
    expect(btn, findsOneWidget);
    expect(find.text('Request upload'), findsOneWidget);
    // No count caption yet.
    expect(find.textContaining('Requested'), findsNothing);

    await tester.tap(btn);
    await tester.pumpAndSettle();

    expect(repo.lastRequest?.member, 'm1');
    expect(repo.lastRequest?.source, 'partner');
    expect(repo.lastRequest?.key, 'doc-1');
    expect(repo.lastRequest?.label, "Driver's Licence");
    expect(repo.lastRequest?.vehicle, isNull);

    // Optimistic caption + relabel to "Request again".
    expect(find.textContaining('Requested 1×'), findsOneWidget);
    expect(find.text('Request again'), findsOneWidget);
  });

  testWidgets('an existing reminder count is shown from the stats provider', (tester) async {
    await _pumpDocs(tester, stats: {
      'partner|doc-1|': DocRequestStat(count: 3, lastSentAt: DateTime.now().subtract(const Duration(hours: 2))),
    });
    expect(find.text('Request again'), findsOneWidget);
    expect(find.textContaining('Requested 3×'), findsOneWidget);
    expect(find.textContaining('last 2h ago'), findsOneWidget);
  });

  test('approverRelativeTime labels recent reminders', () {
    final now = DateTime(2026, 11, 9, 12, 0, 0);
    expect(approverRelativeTime(now.subtract(const Duration(seconds: 20)), now: now), 'just now');
    expect(approverRelativeTime(now.subtract(const Duration(minutes: 5)), now: now), '5m ago');
    expect(approverRelativeTime(now.subtract(const Duration(hours: 3)), now: now), '3h ago');
    expect(approverRelativeTime(now.subtract(const Duration(days: 2)), now: now), '2d ago');
    // Older than a week falls back to a date.
    expect(approverRelativeTime(DateTime(2026, 10, 2), now: now), '02 Oct');
  });
}
