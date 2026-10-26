// Partner application review (0289): the lines of an application, the
// admin's page (approve / reject with a reason / edit with a note, send back,
// approve with the vehicle), and the driver's "Changes needed" with its
// sheet, in light and dark, the driver's at phone width. Made-up people and
// documents only.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/providers.dart' show currentUserIdProvider;
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/people/partner_review_screen.dart';
import 'package:get_ride/src/core/partner_onboarding.dart';
import 'package:get_ride/src/core/partner_review.dart';
import 'package:get_ride/src/core/partner_status.dart';
import 'package:get_ride/src/core/push_logic.dart' show pushRouteFor;
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/partner_review_repository.dart';
import 'package:get_ride/src/features/partner/partner_status_panel.dart';
import 'package:go_router/go_router.dart';

const _profile = {
  'id': 'u1',
  'name': 'TEST DRIVER',
  'id_name': 'TEST DRIVER',
  'birth_date': '1990-01-01',
  'address': 'No. 1, Jalan Ujian',
  'nationality': 'Malaysian',
  'ic': '900101-14-0000',
  'id_type': 'mykad',
  'id_image': 'https://x.test/id-front.jpg',
  'id_image_back': 'https://x.test/id-back.jpg',
  'avatar_url': 'https://x.test/selfie.jpg',
};

Map<String, dynamic> _partner({String status = 'unapproved'}) => {
      'id': 'p1',
      'auth_user_id': 'u1',
      'name': 'TEST DRIVER',
      'display_id': 'PR-0001',
      'status': status,
      'documents_ok': true,
      'partner_types': ['TEKSI', 'EHAILING'],
      'registration_vehicle_id': 'v1',
      'selfie_liveness': 'passed',
      'company_name': 'Ujian Sdn Bhd',
      'company_document_url': 'https://x.test/ssm.pdf',
      'company_driver_is_director': true,
      'driver_permit_front_url': 'https://x.test/kp-front.jpg',
      'driver_permit_card_no': 'KP-0001',
      'driver_permit_valid_until': '2027-06-30',
    };

const _vehicle = {
  'id': 'v1',
  'plate': 'TST 1',
  'make': 'Proton',
  'model': 'Saga',
  'year': '2018',
  'color': 'GREY',
  'registration_date': '2018-03-01',
  'engine_cc': 1300,
  'grant_owner_name': 'TEST DRIVER',
  'owner_match': 'driver',
  'grant_front_url': 'https://x.test/grant.jpg',
  'image_front': 'https://x.test/car-front.jpg',
};

final _providerDocs = [
  {'id': 'd1', 'doc_id': 'rd1', 'doc_name': 'Driving License', 'file_url': 'https://x.test/dl.jpg',
   'status': 'Pending Review', 'uploaded_at': '2026-10-01T00:00:00Z'},
  // An older upload of the same document is not a line of its own.
  {'id': 'd0', 'doc_id': 'rd1', 'doc_name': 'Driving License', 'file_url': 'https://x.test/dl-old.jpg',
   'status': 'Rejected', 'uploaded_at': '2026-09-01T00:00:00Z'},
];
final _vehicleDocs = [
  {'id': 'd2', 'doc_id': 'rd2', 'doc_name': 'Inspection (Puspakom)', 'file_url': 'https://x.test/insp.jpg',
   'status': 'Pending Review', 'uploaded_at': '2026-10-01T00:00:00Z'},
  {'id': 'd3', 'doc_id': 'rd3', 'doc_name': 'EVP', 'permit_type_id': 'pt1', 'file_url': 'https://x.test/evp.pdf',
   'document_number': 'EVP-TEST-1', 'status': 'Approved', 'uploaded_at': '2026-10-02T00:00:00Z'},
];
const _statuses = [
  {'service': 'EHAILING', 'status': 'waiting_permit', 'permit_type': 'pt1', 'permit_name': 'EVP'},
];

Map<String, dynamic> _itemRow(String key, String group, String label, String state,
        {String? note, Object? oldValue, Object? newValue, String? fixed}) =>
    {
      'item_key': key,
      'item_group': group,
      'label': label,
      'state': state,
      'note': note,
      'old_value': oldValue,
      'new_value': newValue,
      'sent_at': '2026-10-20T00:00:00Z',
      'fixed_at': fixed,
    };

const _me = 'admin-1';

class _ReviewRepo implements PartnerReviewRepository {
  _ReviewRepo({String status = 'unapproved', Map<String, ReviewItem>? items, bool viewedAll = true})
      : partner = _partner(status: status),
        items = items ?? {} {
    // Every document opened by this admin already, unless a test says not.
    if (viewedAll) {
      for (final l in _lines()) {
        log.add(ReviewLogEntry(itemKey: l.key, action: 'viewed', actorId: _me, at: DateTime(2026, 10, 26, 9)));
      }
    }
  }
  final Map<String, dynamic> partner;
  final Map<String, ReviewItem> items;
  final calls = <String>[];
  final log = <ReviewLogEntry>[];
  List<ReviewItem> mine = [];

  @override
  Future<void> viewed({required String partnerId, required String key}) async {
    calls.add('view $key');
    log.add(ReviewLogEntry(itemKey: key, action: 'viewed', actorId: _me, at: DateTime.now()));
  }

  @override
  Future<ReviewApplication?> application(String partnerId) async => ReviewApplication(
        partner: partner,
        profile: _profile,
        vehicle: _vehicle,
        providerDocs: _providerDocs,
        vehicleDocs: _vehicleDocs,
        serviceStatuses: _statuses,
        faces: const {
          'national_id:u1': {'state': 'match', 'score': 91, 'provider': 'aws'},
        },
        items: {...items},
        log: [...log],
        names: const {_me: 'Aisyah'},
      );

  @override
  Future<void> setItem({
    required String partnerId,
    required ReviewLine line,
    required ReviewState state,
    String? note,
    Object? value,
  }) async {
    calls.add('set ${line.key} ${state.name} ${note ?? ''} ${value ?? ''}'.trim());
    items[line.key] = ReviewItem(
      key: line.key,
      group: line.group,
      label: line.label,
      state: state,
      note: note,
      oldValue: state == ReviewState.edited ? line.editValue : null,
      newValue: value,
    );
  }

  @override
  Future<void> clearItem({required String partnerId, required ReviewLine line}) async {
    calls.add('clear ${line.key}');
    items.remove(line.key);
    log.add(ReviewLogEntry(itemKey: line.key, action: 'pending', actorId: _me, at: DateTime.now()));
  }

  @override
  Future<void> sendBack(String partnerId) async => calls.add('send back');

  @override
  Future<void> approve(String partnerId) async => calls.add('approve');

  @override
  Future<List<ReviewItem>> myItems(String partnerId) async => mine;

  @override
  Future<void> keep(String key) async => calls.add('keep $key');

  @override
  Future<void> resubmit() async => calls.add('resubmit');

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

List<ReviewLine> _lines() => applicationReviewLines(
      profile: _profile,
      partner: _partner(),
      vehicle: _vehicle,
      providerDocs: _providerDocs,
      vehicleDocs: _vehicleDocs,
      serviceStatuses: _statuses,
    );

List<ReviewItem> _driverItems({bool fixed = false}) => [
      ReviewItem.fromRow(_itemRow('details.name', 'details', 'Full name', 'edited',
          note: 'Changed to match your MyKad.', oldValue: 'TEST DRIVER', newValue: 'TEST BIN DRIVER')),
      ReviewItem.fromRow(_itemRow('details.birth_date', 'details', 'Date of birth', 'approved')),
      ReviewItem.fromRow(_itemRow('id.back', 'national_id', 'MyKad back photo', 'rejected',
          note: 'The photo is blurred. Retake it in good light with the whole card in the frame.',
          fixed: fixed ? '2026-10-21T00:00:00Z' : null)),
      ReviewItem.fromRow(_itemRow('services', 'services', 'Services', 'edited',
          note: 'Dealer is for businesses registered with us.', oldValue: ['EHAILING', 'TEKSI', 'DEALER'],
          newValue: ['EHAILING', 'TEKSI'])),
      ReviewItem.fromRow(_itemRow('doc:vehicle:rd2', 'vehicle_documents', 'Inspection (Puspakom)', 'rejected',
          note: 'This inspection report expired. Upload the current one.', fixed: fixed ? '2026-10-21T00:00:00Z' : null)),
    ];

/// A busy button spins while its dialog is open, so this pumps frames
/// rather than waiting for everything to settle.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('the lines of an application', () {
    test('every detail and document, grouped in the application order', () {
      final lines = _lines();
      final keys = lines.map((l) => l.key).toList();
      expect(keys, containsAll([
        'details.photo', 'details.name', 'details.birth_date', 'details.address', 'details.nationality',
        'details.id_number', 'id.front', 'id.back', 'company.document', 'company.name', 'permit.photos',
        'permit.card_no', 'services', 'vehicle.grant', 'vehicle.plate', 'vehicle.color', 'vehicle.photos',
        'doc:vehicle:rd2', 'doc:provider:rd1', 'vpermit:pt1',
      ]));
      expect(keys.where((k) => k == 'doc:provider:rd1'), hasLength(1), reason: 'only the newest upload');
      expect(lines.firstWhere((l) => l.key == 'doc:provider:rd1').files, ['https://x.test/dl.jpg']);
      expect(keys, isNot(contains('doc:vehicle:rd3')), reason: 'a vehicle permit is under Vehicle permits');
      expect(keys, isNot(contains('vehicle.authorisation')), reason: 'the driver owns it');
      expect(
        reviewGroups(lines, (l) => l.group).map((g) => g.$1.label),
        ['Your details', 'National ID', 'Your company', 'Driver permit', 'Partner Service type', 'Vehicle',
          'Vehicle documents', 'Service documents', 'Vehicle permits'],
      );
      expect(lines.firstWhere((l) => l.key == 'id.front').label, 'MyKad front photo');
      expect(lines.firstWhere((l) => l.key == 'id.front').faceKey, 'national_id:u1');
      expect(lines.firstWhere((l) => l.key == 'vpermit:pt1').label, 'EVP · uploaded by GET.ride');
      expect(lines.firstWhere((l) => l.key == 'vehicle.engine_cc').value, '1300 cc');
    });

    test('a vehicle owned by someone else needs the authorisation letter; a mismatched ID is flagged', () {
      final lines = applicationReviewLines(
        profile: {..._profile, 'id_mismatch': true, 'id_number_typed': '1', 'id_number_read': '2'},
        partner: _partner(),
        vehicle: {..._vehicle, 'owner_match': 'other'},
      );
      expect(lines.map((l) => l.key), contains('vehicle.authorisation'));
      expect(lines.firstWhere((l) => l.key == 'details.id_number').flag, contains('they differ'));
      expect(lines.firstWhere((l) => l.key == 'vehicle.owner').flag, 'Owned by someone else');
    });

    test('what an admin may edit, and how', () {
      expect(reviewEditFor('details.birth_date'), ReviewEdit.date);
      expect(reviewEditFor('vehicle.engine_cc'), ReviewEdit.integer);
      expect(reviewEditFor('services'), ReviewEdit.services);
      expect(reviewEditFor('id.front'), ReviewEdit.none);
      expect(reviewEditFor('doc:provider:rd1'), ReviewEdit.none);
      expect(reviewCanReject('vpermit:pt1'), isFalse);
      expect(reviewCanReject('id.front'), isTrue);
    });

    test('the tally decides Send back and Approve', () {
      final lines = _lines();
      expect(reviewTally(lines, {}).canApprove, isFalse);
      final all = {
        for (final l in lines)
          l.key: ReviewItem(key: l.key, group: l.group, label: l.label, state: ReviewState.approved),
      };
      expect(reviewTally(lines, all).canApprove, isTrue);
      all['id.back'] = const ReviewItem(
          key: 'id.back', group: ReviewGroup.nationalId, label: 'x', state: ReviewState.rejected, note: 'Blurred');
      final t = reviewTally(lines, all);
      expect((t.canApprove, t.canSendBack, t.rejected), (false, true, 1));
      expect(t.summary, contains('1 rejected'));
    });

    test('the driver: status words, the fix, and when it can be sent again', () {
      final items = _driverItems();
      expect(reviewDriverStatus(items[0]), 'Changed by admin: Changed to match your MyKad.');
      expect(reviewDriverStatus(items[1]), 'Approved');
      expect(reviewDriverStatus(items[2]), startsWith('Rejected: The photo is blurred.'));
      expect(reviewItemsLeft(items), 2);
      expect(reviewCanResend(items), isFalse);
      expect(reviewCanResend(_driverItems(fixed: true)), isTrue);
      expect(reviewDriverStatus(_driverItems(fixed: true)[2]), 'Fixed · will be sent with your application');
      expect(reviewFixFor('id.back'), (label: 'Retake photo', photo: true, step: OnboardingStep.id));
      expect(reviewFixFor('services').label, 'Change services');
      expect(reviewFixFor('doc:vehicle:rd2').step, OnboardingStep.vehicleDocs);
      expect(reviewFixFor('doc:provider:rd1').step, OnboardingStep.requirements);
      expect(reviewFixFor('vehicle.color').label, 'Edit');
      expect(reviewFixRoute('details.address'), '/drive/onboarding?step=details');
      expect(reviewFixRoute('vpermit:pt1'), isNull);
      expect(reviewValueText('services', ['EHAILING', 'TEKSI']), 'EHAILING, TEKSI');
    });

    test("the admins' push opens that application's review", () {
      expect(pushRouteFor({'type': 'partner_review', 'partner_id': 'p1', 'for': 'admin'}), '/admin/m/partner-review?id=p1');
      expect(pushRouteFor({'type': 'partner_status', 'status': 'changes-needed'}), '/drive');
    });

    test('the Drive tab reads changes-needed as Changes needed, not driving', () {
      final v = partnerStatusView(_partner(status: 'changes-needed'));
      expect(v.kind, PartnerStatusKind.changesNeeded);
      expect(v.title, 'Changes needed');
      expect(v.canDrive, isFalse);
      expect(v.canResubmit, isFalse);
    });
  });

  group('the admin review page', () {
    Future<_ReviewRepo> pump(WidgetTester tester, {_ReviewRepo? repo, Brightness b = Brightness.light}) async {
      final r = repo ?? _ReviewRepo();
      tester.view.physicalSize = const Size(1000, 9000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          adminAccessProvider.overrideWith((_) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
          partnerReviewRepositoryProvider.overrideWithValue(r),
          partnerReviewProvider.overrideWith(
            (ref, id) async => (app: await r.application(id), types: const ['DEALER', 'EHAILING', 'TEKSI']),
          ),
          currentUserIdProvider.overrideWithValue(_me),
        ],
        child: MaterialApp(theme: ThemeData(brightness: b), home: const PartnerReviewScreen(id: 'p1')),
      ));
      await tester.pumpAndSettle();
      return r;
    }

    for (final b in Brightness.values) {
      testWidgets('every line with Approve, Reject and Edit (${b.name})', (tester) async {
        await pump(tester, b: b);
        expect(find.text('Review application'), findsOneWidget);
        for (final g in ['Your details', 'National ID', 'Your company', 'Driver permit', 'Vehicle', 'Vehicle documents',
          'Service documents', 'Vehicle permits']) {
          expect(find.text(g), findsWidgets, reason: g);
        }
        expect(find.byKey(const ValueKey('review-approve-details.name')), findsOneWidget);
        expect(find.byKey(const ValueKey('review-reject-details.name')), findsOneWidget);
        expect(find.byKey(const ValueKey('review-edit-details.name')), findsOneWidget);
        // Photos and documents are rejected, never edited; GET.ride's permit is never rejected.
        expect(find.byKey(const ValueKey('review-edit-id.front')), findsNothing);
        expect(find.byKey(const ValueKey('review-reject-vpermit:pt1')), findsNothing);
        expect(find.textContaining('Face match: 91% match'), findsOneWidget);
        expect(find.text('Live'), findsOneWidget);
        // Nothing decided: neither send back nor approve.
        expect(tester.widget<FilledButton>(find.descendant(
            of: find.byKey(const ValueKey('review-approve')), matching: find.byType(FilledButton))).onPressed, isNull);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('approve a line, reject one with a reason, then send back', (tester) async {
      final repo = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('review-approve-details.name')));
      await _settle(tester);
      expect(repo.calls, ['set details.name approved']);
      expect(find.byKey(const ValueKey('review-status-details.name')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('review-status-details.name'))).data, 'Approved');

      await tester.tap(find.byKey(const ValueKey('review-reject-id.back')));
      await _settle(tester);
      // A reason is required.
      await tester.tap(find.byKey(const ValueKey('reason-reject')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('reason-problem')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reason-blurry')));
      await tester.enterText(find.byKey(const ValueKey('reason-note')), 'Retake it in good light.');
      await tester.tap(find.byKey(const ValueKey('reason-reject')));
      await _settle(tester);
      expect(repo.calls.last, 'set id.back rejected Photo blurry: Retake it in good light.');
      expect(tester.widget<Text>(find.byKey(const ValueKey('review-status-id.back'))).data,
          'Rejected: Photo blurry: Retake it in good light.');

      await tester.tap(find.byKey(const ValueKey('review-send-back')));
      await _settle(tester);
      expect(find.text('Send back to driver?'), findsOneWidget);
      await tester.tap(find.text('Send back'));
      await _settle(tester);
      expect(repo.calls.last, 'send back');
      // Told in a modal, not a bar.
      expect(find.byKey(const ValueKey('notice')), findsOneWidget);
    });

    testWidgets('edit a field: the new value and a note', (tester) async {
      final repo = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('review-edit-vehicle.color')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('review-edit-dialog')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('review-edit-value')), 'SILVER');
      await tester.tap(find.byKey(const ValueKey('review-edit-save')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('review-edit-problem')), findsOneWidget, reason: 'the note is required');
      await tester.enterText(find.byKey(const ValueKey('review-edit-note')), 'Colour corrected to match the grant.');
      await tester.tap(find.byKey(const ValueKey('review-edit-save')));
      await _settle(tester);
      expect(repo.calls.last, 'set vehicle.color edited Colour corrected to match the grant. SILVER');
      expect(find.text('Edited: Colour corrected to match the grant.'), findsOneWidget);
      expect(find.text('Was GREY'), findsOneWidget);
    });

    testWidgets('edit the services from the list', (tester) async {
      final repo = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('review-edit-services')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('review-edit-type-EHAILING')));
      await tester.enterText(find.byKey(const ValueKey('review-edit-note')), 'eHailing needs a permit you do not have.');
      await tester.tap(find.byKey(const ValueKey('review-edit-save')));
      await _settle(tester);
      expect(repo.calls.last, 'set services edited eHailing needs a permit you do not have. [TEKSI]');
    });

    testWidgets('every line approved one by one, then the application with its vehicle', (tester) async {
      final repo = await pump(tester);
      expect(find.byKey(const ValueKey('review-approve-rest')), findsNothing, reason: 'no approving unseen lines in bulk');
      for (final l in _lines()) {
        final b = find.byKey(ValueKey('review-approve-${l.key}'));
        await tester.ensureVisible(b);
        await tester.tap(b);
        await _settle(tester);
      }
      expect(repo.calls.where((c) => c.endsWith('approved')).length, _lines().length);
      expect(find.text('Approve application and vehicle'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('review-approve')));
      await tester.tap(find.byKey(const ValueKey('review-approve')));
      await _settle(tester);
      expect(find.textContaining('TST 1 are approved together'), findsOneWidget);
      await tester.tap(find.text('Approve').last);
      await _settle(tester);
      expect(repo.calls.last, 'approve');
    });

    testWidgets('a document is decided only once viewed; back to pending needs a fresh view', (tester) async {
      final repo = await pump(tester, repo: _ReviewRepo(viewedAll: false));
      final reject = find.byKey(const ValueKey('review-reject-id.back'));
      await tester.ensureVisible(reject);
      expect(tester.widget<TextButton>(find.descendant(of: reject, matching: find.byType(TextButton))).onPressed, isNull);
      expect(find.text('Not opened yet: view it to decide'), findsWidgets);
      // A line with nothing to view (the name) is decided straight away.
      await tester.tap(find.byKey(const ValueKey('review-approve-details.name')));
      await _settle(tester);
      expect(repo.calls, ['set details.name approved']);

      // Viewed (as the View button logs it), then decided, then back to pending.
      await repo.viewed(partnerId: 'p1', key: 'id.back');
      await repo.setItem(partnerId: 'p1', line: _lines().firstWhere((l) => l.key == 'id.back'), state: ReviewState.approved);
      await repo.clearItem(partnerId: 'p1', line: _lines().firstWhere((l) => l.key == 'id.back'));
      final views = reviewViewsFor('id.back', repo.log, _me);
      expect((views.count, views.mine), (1, false), reason: 'the view before pending no longer counts');
      await repo.viewed(partnerId: 'p1', key: 'id.back');
      expect(reviewViewsFor('id.back', repo.log, _me), (count: 2, lastBy: _me, lastAt: repo.log.last.at, mine: true));
      expect(tester.takeException(), isNull);
    });

    testWidgets('while it is with the driver nothing can be changed', (tester) async {
      await pump(tester, repo: _ReviewRepo(status: 'changes-needed'));
      expect(find.byKey(const ValueKey('review-with-driver')), findsOneWidget);
      expect(find.byKey(const ValueKey('review-approve-details.name')), findsNothing);
      expect(find.byKey(const ValueKey('review-send-back')), findsNothing);
    });
  });

  group('the driver: Changes needed', () {
    Future<_ReviewRepo> pump(WidgetTester tester, List<ReviewItem> items,
        {Brightness b = Brightness.light, List<String>? opened}) async {
      final repo = _ReviewRepo(status: 'changes-needed')..mine = items;
      tester.view.physicalSize = const Size(360, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = GoRouter(routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: PartnerStatusPanel(partner: Partner(_partner(status: 'changes-needed')), onOpenApplication: () {}),
          ),
        ),
        GoRoute(
          path: '/drive/onboarding',
          builder: (_, s) {
            opened?.add(s.uri.toString());
            return const Scaffold(body: Text('step'));
          },
        ),
        GoRoute(path: '/account/support', builder: (_, _) => const Scaffold(body: Text('support'))),
      ]);
      await tester.pumpWidget(ProviderScope(
        overrides: [partnerReviewRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp.router(theme: ThemeData(brightness: b), routerConfig: router),
      ));
      await tester.pumpAndSettle();
      return repo;
    }

    for (final b in Brightness.values) {
      testWidgets('the lines grouped with the admin\'s words, at phone width (${b.name})', (tester) async {
        await pump(tester, _driverItems(), b: b);
        expect(find.byKey(const ValueKey('partner-status-changesNeeded')), findsOneWidget);
        expect(find.text('Changes needed'), findsOneWidget);
        expect(find.text('YOUR DETAILS'), findsOneWidget);
        expect(find.text('NATIONAL ID'), findsOneWidget);
        expect(find.text('Changed by admin: Changed to match your MyKad.'), findsOneWidget);
        expect(find.text('Approved'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('VEHICLE DOCUMENTS'), 100);
        expect(find.textContaining('Rejected: This inspection report expired.'), findsOneWidget);
        expect(find.text('2 rejected item(s) left to fix. Admin edits can be kept as they are or changed.'), findsOneWidget);
        // Locked until both are fixed.
        expect(tester.widget<FilledButton>(find.descendant(
            of: find.byKey(const ValueKey('changes-resend')), matching: find.byType(FilledButton))).onPressed, isNull);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a short phone scrolls to the last line, the button stays in view', (tester) async {
      await pump(tester, _driverItems());
      tester.view.physicalSize = const Size(360, 640);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('changes-resend')).hitTestable(), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await _settle(tester);
      expect(find.byKey(const ValueKey('change-doc:vehicle:rd2')).hitTestable(), findsOneWidget);
    });

    testWidgets('a rejected line: the reason and its fix opens the right step', (tester) async {
      final opened = <String>[];
      await pump(tester, _driverItems(), opened: opened);
      await tester.tap(find.byKey(const ValueKey('change-id.back')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('change-sheet')), findsOneWidget);
      expect(find.text("Admin's note"), findsOneWidget);
      expect(find.text('Rejected'), findsOneWidget);
      expect(find.text('Retake photo'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('change-fix')));
      await _settle(tester);
      expect(opened, ['/drive/onboarding?step=id']);
    });

    testWidgets("an admin's edit: before and after, kept with Keep and close", (tester) async {
      final repo = await pump(tester, _driverItems(), b: Brightness.dark);
      await tester.tap(find.byKey(const ValueKey('change-services')));
      await _settle(tester);
      expect(find.text('Changed by admin'), findsOneWidget);
      expect(find.text('You entered'), findsOneWidget);
      expect(find.text('EHAILING, TEKSI, DEALER'), findsOneWidget);
      expect(find.text('EHAILING, TEKSI'), findsOneWidget);
      expect(find.text('Change services'), findsOneWidget);
      await tester.tap(find.text('Keep and close'));
      await _settle(tester);
      expect(repo.calls, ['keep services']);
      expect(find.byKey(const ValueKey('change-sheet')), findsNothing);
    });

    testWidgets('everything fixed: Send for review again, confirmed in a modal', (tester) async {
      final repo = await pump(tester, _driverItems(fixed: true));
      expect(find.text('Fixed · will be sent with your application'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('changes-resend')));
      await _settle(tester);
      expect(find.text('Send for review again?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('changes-resend-confirm')));
      await _settle(tester);
      expect(repo.calls, ['resubmit']);
      expect(find.text('Sent for review'), findsOneWidget);
    });
  });
}
