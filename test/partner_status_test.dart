// The Drive tab for a partner who cannot take jobs yet: the status, the
// admin's reason, sending a rejected application back, support.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/partner_status.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_onboarding_repository.dart';
import 'package:get_ride/src/features/partner/partner_status_panel.dart';
import 'package:go_router/go_router.dart';

Map<String, dynamic> _row(String status, {String? note, String? resubmitted, bool complete = true}) => {
  'id': 'p1',
  'status': status,
  'status_note': ?note,
  'resubmitted_at': ?resubmitted,
  'partner_types': complete ? ['TEKSI'] : <String>[],
  'documents_ok': complete,
};

class _Repo implements PartnerOnboardingRepository {
  int asked = 0;

  @override
  Future<void> requestReview() async => asked++;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  group('the status, as the partner reads it', () {
    test('approved and permit statuses can drive', () {
      expect(partnerStatusView(_row('approved')).canDrive, isTrue);
      expect(partnerStatusView(_row('permit-verified')).canDrive, isTrue);
    });

    test('rejected: the reason, and a way back', () {
      final v = partnerStatusView(_row('rejected', note: ' Permit photo unreadable. '));
      expect(v.kind, PartnerStatusKind.rejected);
      expect(v.title, 'Application not approved');
      expect(v.reason, 'Permit photo unreadable.');
      expect(v.canResubmit, isTrue);
    });

    test('blocked: the reason, and no way back but support', () {
      final v = partnerStatusView(_row('blocked', note: 'Repeated complaints.'));
      expect(v.kind, PartnerStatusKind.blocked);
      expect(v.reason, 'Repeated complaints.');
      expect(v.canResubmit, isFalse);
    });

    test('a rejection or block outranks an unfinished application', () {
      expect(partnerStatusView(_row('rejected', complete: false)).kind, PartnerStatusKind.rejected);
      expect(partnerStatusView(_row('unapproved', complete: false)).kind, PartnerStatusKind.incomplete);
    });

    test('under review, documents needed, and sent back', () {
      expect(partnerStatusView(_row('unapproved')).kind, PartnerStatusKind.underReview);
      expect(partnerStatusView(_row('unapproved-docs')).kind, PartnerStatusKind.docsNeeded);
      final back = partnerStatusView(_row('unapproved', resubmitted: '2026-10-09T06:00:00Z'));
      expect(back.resubmittedAt, DateTime.utc(2026, 10, 9, 6));
      expect(back.message, contains('sent your application back'));
      // An old note does not follow the partner back into review.
      expect(partnerStatusView(_row('unapproved', note: 'old')).reason, isNull);
    });

    test("the admin's change carries a reason only with a rejection or block", () {
      expect(partnerStatusPatch('rejected', reason: ' Unreadable '), {
        'status': 'rejected',
        'status_note': 'Unreadable',
      });
      expect(partnerStatusPatch('blocked', reason: ''), {'status': 'blocked', 'status_note': null});
      expect(partnerStatusPatch('approved', reason: 'ignored'), {'status': 'approved', 'status_note': null});
      expect(statusTakesReason('rejected'), isTrue);
      expect(statusTakesReason('approved'), isFalse);
    });
  });

  group('the panel', () {
    late _Repo repo;
    late List<String> opened;

    Future<void> pump(WidgetTester tester, Map<String, dynamic> row) async {
      repo = _Repo();
      opened = [];
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: PartnerStatusPanel(partner: Partner(row), onOpenApplication: () => opened.add('application')),
            ),
          ),
          GoRoute(
            path: '/account/support',
            builder: (_, _) => const Scaffold(body: Text('support')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [partnerOnboardingRepositoryProvider.overrideWithValue(repo)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('rejected: reason, update documents, send back after confirming', (tester) async {
      await pump(tester, _row('rejected', note: 'Permit photo unreadable.'));
      expect(find.text('Application not approved'), findsOneWidget);
      expect(find.text('Reason from the admin'), findsOneWidget);
      expect(find.text('Permit photo unreadable.'), findsOneWidget);
      await tester.tap(find.text('Update documents'));
      expect(opened, ['application']);

      // The button spins while the confirm is open, so this pumps rather than
      // waiting to settle.
      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.tap(find.byKey(const ValueKey('partner-resubmit')));
      await settle();
      expect(find.text('Send for review again?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('partner-resubmit-confirm')));
      await settle();
      expect(repo.asked, 1);
    });

    testWidgets('blocked: the reason and support, nothing to send', (tester) async {
      await pump(tester, _row('blocked', note: 'Repeated complaints.'));
      expect(find.text('Account blocked'), findsOneWidget);
      expect(find.text('Repeated complaints.'), findsOneWidget);
      expect(find.byKey(const ValueKey('partner-resubmit')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('partner-status-support')));
      await tester.pumpAndSettle();
      expect(find.text('support'), findsOneWidget);
    });

    testWidgets('waiting for approval has no reason card', (tester) async {
      await pump(tester, _row('unapproved'));
      expect(find.text('Waiting for approval'), findsOneWidget);
      expect(find.byKey(const ValueKey('partner-status-reason')), findsNothing);
      expect(find.text('View application'), findsOneWidget);
    });
  });
}
