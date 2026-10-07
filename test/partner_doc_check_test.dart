import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/core/partner_doc_check.dart';
import 'package:get_ride/src/core/vehicle_assignment.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_doc_check.dart';
import 'package:get_ride/src/data/ride_repository.dart';
import 'package:get_ride/src/data/vehicle_assignment_repository.dart';
import 'package:get_ride/src/features/partner/partner_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:go_router/go_router.dart';

RequiredDoc _doc(String id, String name, {bool compulsory = true}) => RequiredDoc(
  id: id,
  name: name,
  description: '',
  compulsory: compulsory,
  scope: 'global',
  labels: const [],
  flags: const DocFlags(),
);

Map<String, dynamic> _upload(String docId, {String status = 'Approved', String? expiry, String at = '2026-09-01'}) => {
  'doc_id': docId,
  'status': status,
  'expiry_date': expiry,
  'uploaded_at': at,
};

class _NoTrip implements RideRepository {
  @override
  Future<RideRequest?> ongoingForPartner() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final now = DateTime(2026, 10, 6);

  group('rules', () {
    test('missing, rejected and expired documents are issues; compulsory first', () {
      final issues = partnerDocIssues(
        [
          _doc('lic', 'Driving licence'),
          _doc('ins', 'Insurance'),
          _doc('psv', 'PSV permit'),
          _doc('pho', 'Photo', compulsory: false),
          _doc('ok', 'Medical'),
        ],
        [_upload('ins', status: 'Rejected'), _upload('psv', expiry: '2026-09-30'), _upload('ok')],
        now: now,
      );
      expect(issues.map((i) => (i.name, i.reason, i.compulsory)), [
        ('Driving licence', DocIssueReason.missing, true),
        ('Insurance', DocIssueReason.rejected, true),
        ('PSV permit', DocIssueReason.expired, true),
        ('Photo', DocIssueReason.missing, false),
      ]);
      expect(blockingDocIssues(issues), hasLength(3));
    });

    test('the newest upload decides', () {
      final issues = partnerDocIssues(
        [_doc('lic', 'Driving licence')],
        [_upload('lic', at: '2026-10-01'), _upload('lic', status: 'Rejected', at: '2026-08-01')],
        now: now,
      );
      expect(issues, isEmpty);
      final reverse = partnerDocIssues(
        [_doc('lic', 'Driving licence')],
        [_upload('lic', at: '2026-08-01'), _upload('lic', status: 'Rejected', at: '2026-10-01')],
        now: now,
      );
      expect(reverse.single.reason, DocIssueReason.rejected);
    });

    test('pending review does not block', () {
      expect(
        partnerDocIssues([_doc('lic', 'Driving licence')], [_upload('lic', status: 'Pending Review')], now: now),
        isEmpty,
      );
    });

    test('mode types: TEKSI for the meter, the rest for e-hailing', () {
      expect(partnerTypesForMode(['TEKSI', 'E-Hailing'], teksi: true), ['TEKSI']);
      expect(partnerTypesForMode(['TEKSI', 'E-Hailing'], teksi: false), ['E-Hailing']);
      expect(partnerTypesForMode(['TEKSI'], teksi: false), ['TEKSI']);
      expect(partnerTypesForMode(['E-Hailing'], teksi: true), ['E-Hailing']);
    });

    test('summary lists four and counts the rest', () {
      final issues = [
        for (var i = 0; i < 6; i++) (id: '$i', name: 'Doc $i', compulsory: true, reason: DocIssueReason.missing),
      ];
      final s = summarizeDocIssues(issues);
      expect(s.split('\n'), hasLength(5));
      expect(s, contains('• Doc 0 (not uploaded)'));
      expect(s, endsWith('• +2 more'));
      expect(summarizeDocIssues(const []), '');
    });
  });

  group('Drive screen', () {
    Future<void> pump(WidgetTester tester, PartnerDocCheck check) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 1400);
      addTearDown(tester.view.reset);
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const PartnerScreen()),
          GoRoute(
            path: '/drive/onboarding',
            builder: (_, _) => const Scaffold(body: Text('onboarding')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            partnerProvider.overrideWith((ref) async => Partner({'id': 'p1', 'status': 'approved', 'name': 'Ali'})),
            rideRepositoryProvider.overrideWithValue(_NoTrip()),
            openRequestsProvider.overrideWith((ref) => const Stream<List<RideRequest>>.empty()),
            assignableVehiclesProvider.overrideWith((ref) async => const <AssignableVehicle>[]),
            // These drivers have no vehicle; the vehicle check has its own test.
            partnerTypeEntriesProvider.overrideWith(
              (ref) async => [
                (id: 'e', values: <String, dynamic>{'name': 'eHailing', 'vehicleRequired': false}),
              ],
            ),
            partnerDocCheckProvider.overrideWithValue(check),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('an expired compulsory document keeps the partner offline', (tester) async {
      await pump(
        tester,
        (partner, {required teksi}) async => [
          (id: 'psv', name: 'PSV permit', compulsory: true, reason: DocIssueReason.expired),
        ],
      );
      await tester.tap(find.text('You are offline'));
      await tester.pump();
      await _pumpOpen(tester);
      expect(find.byKey(const ValueKey('docs-blocked')), findsOneWidget);
      expect(find.textContaining('PSV permit (expired)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('docs-update')));
      await tester.pumpAndSettle();
      expect(find.text('onboarding'), findsOneWidget);
    });

    testWidgets('optional issues and unreadable documents do not block', (tester) async {
      await pump(
        tester,
        (partner, {required teksi}) async => [
          (id: 'pho', name: 'Photo', compulsory: false, reason: DocIssueReason.missing),
        ],
      );
      await tester.tap(find.text('You are offline'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('docs-blocked')), findsNothing);
      expect(find.text('You are online'), findsOneWidget);
    });

    testWidgets('a failed check lets the partner online', (tester) async {
      await pump(tester, (partner, {required teksi}) => Future.error(StateError('offline')));
      await tester.tap(find.text('You are offline'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('You are online'), findsOneWidget);
    });
  });
}

/// Lets a dialog or sheet open over a busy control: the control's spinner
/// keeps turning until the dialog is answered, so pumpAndSettle can't settle.
Future<void> _pumpOpen(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
