import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/people_data.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/admin/screens/people/people_widgets.dart';
import 'package:get_ride/src/core/partner_doc_check.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final today = DateTime(2026, 10, 6, 9);

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

Map<String, dynamic> upload(String doc, {String status = 'Approved', String? expiry}) => {
  'doc_id': doc,
  'status': status,
  'expiry_date': expiry,
  'file_url': 'https://x/$doc.png',
  'uploaded_at': '2026-01-01T00:00:00Z',
};

RequiredDoc doc(String id, String name, {bool compulsory = true}) => RequiredDoc(
  id: id,
  name: name,
  description: '',
  compulsory: compulsory,
  scope: 'global',
  labels: const [],
  flags: const DocFlags(),
);

class _FakePeople extends PeopleRepository {
  _FakePeople(this.uploads) : super(_db);
  final List<Map<String, dynamic>> uploads;

  @override
  Future<List<Map<String, dynamic>>> providerDocuments(String partnerId) async => uploads;
}

void main() {
  group('renewal window', () {
    test('an approved document opens for renewal 14 days before it expires', () {
      expect(renewalOpensOn(upload('a', expiry: '2026-12-31'), now: today), DateTime(2026, 12, 17));
      expect(
        renewalOpensOn(upload('a', expiry: '2026-10-20'), now: today),
        isNull,
        reason: 'exactly 14 days out',
      );
      expect(renewalOpensOn(upload('a', expiry: '2026-10-21'), now: today), DateTime(2026, 10, 7));
    });

    test('anything not approved, or without an expiry, can be replaced now', () {
      expect(renewalOpensOn(upload('a'), now: today), isNull);
      expect(
        renewalOpensOn(
          upload('a', status: 'Pending Review', expiry: '2027-06-01'),
          now: today,
        ),
        isNull,
      );
      expect(
        renewalOpensOn(
          upload('a', status: 'Rejected', expiry: '2027-06-01'),
          now: today,
        ),
        isNull,
      );
      expect(
        renewalOpensOn(upload('a', expiry: '2026-09-01'), now: today),
        isNull,
        reason: 'expired',
      );
    });
  });

  testWidgets("the partner's page locks approved documents and lists what needs attention", (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final docs = [
      doc('licence', 'Driving licence'),
      doc('permit', 'Taxi permit'),
      doc('ic', 'Identity card'),
      doc('photo', 'Profile photo', compulsory: false),
    ];
    final uploads = [
      upload('licence', expiry: '2027-03-01'),
      upload('permit', expiry: '2026-09-30'),
      upload('ic', status: 'Rejected'),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [peopleRepositoryProvider.overrideWithValue(_FakePeople(uploads))],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PartnerDocsUploader(
                partnerId: 'p1',
                docs: docs,
                renewalLock: true,
                actionSummary: true,
                now: today,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('docs-action-needed')), findsOneWidget);
    expect(find.text('2 compulsory documents still need your attention.'), findsOneWidget);
    expect(find.text('Expired — renew'), findsOneWidget);
    expect(find.text('Rejected — re-upload'), findsOneWidget);
    expect(find.text('Not uploaded'), findsOneWidget);
    expect(find.textContaining('Renewal opens 2027-02-15'), findsOneWidget);

    // Locked: a tap does not open the upload form.
    await tester.tap(find.text('Driving licence'));
    await tester.pump();
    expect(find.byType(DocUploadDialog), findsNothing);
  });

  testWidgets('the admin panel keeps every document open', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          peopleRepositoryProvider.overrideWithValue(_FakePeople([upload('licence', expiry: '2027-03-01')])),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PartnerDocsUploader(partnerId: 'p1', docs: [doc('licence', 'Driving licence')], now: today),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('docs-action-needed')), findsNothing);
    expect(find.textContaining('Renewal opens'), findsNothing);
  });
}
