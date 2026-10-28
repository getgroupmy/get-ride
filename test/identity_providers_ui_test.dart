// Who compares the faces and who reads the card (migration 0283) on screen,
// light and dark: the admin's two settings next to the renewal window, with
// the line saying a key is missing, and the review of an upload showing who
// gave the score, why a face isn't checked, and reading the card again with
// Google Vision.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/dispatch/identity_provider_fields.dart';
import 'package:get_ride/src/admin/screens/signin_checks_review.dart';
import 'package:get_ride/src/admin/widgets/admin_widgets.dart' show DetailTable;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/signin_checks.dart';
import 'package:get_ride/src/data/identity_repository.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';
import 'text_contrast.dart';
import 'notice.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _Identity extends IdentityRepository {
  _Identity(this.cfg) : super(_db);
  IdentityConfig cfg;
  final calls = <String>[];

  @override
  Future<IdentityConfig> config() async => cfg;

  @override
  Future<IdentityConfig> setProviders({String? face, String? idRead}) async {
    calls.add('set ${face ?? '-'} ${idRead ?? '-'}');
    cfg = IdentityConfig(
      faceProvider: face ?? cfg.faceProvider,
      idRead: idRead ?? cfg.idRead,
      awsKey: cfg.awsKey,
      faceServer: cfg.faceServer,
      visionKey: cfg.visionKey,
    );
    return cfg;
  }

  @override
  Future<IdentityConfig> setOrder({List<OrderSlot>? faceOrder, List<OrderSlot>? idReaders, int? faceLowScore}) async {
    calls.add([
      if (faceOrder != null) 'face ${faceOrder.join(',')}',
      if (idReaders != null) 'read ${idReaders.join(',')}',
      if (faceLowScore != null) 'low $faceLowScore',
    ].join(' '));
    cfg = cfg.copyWith(faceOrder: faceOrder, idReaders: idReaders, faceLowScore: faceLowScore);
    return cfg;
  }

  List<Map<String, dynamic>> queue = const [];
  final saved = <String>[];

  @override
  Future<List<Map<String, dynamic>>> browserQueue() async => queue;

  @override
  Future<int> saveBrowserScore(String id, String? otherId, String state, double? score) async {
    saved.add('$id $otherId $state $score');
    return 2;
  }

  @override
  Future<Map<String, dynamic>> readCardWithVision(String checkId) async {
    calls.add('read $checkId');
    return {
      'state': 'read',
      'name': 'AINA BINTI AHMAD',
      'ic': '880202-10-1234',
      'passport': null,
      'expiry': null,
      'mismatch': <String>[],
    };
  }

  @override
  Future<int> waitingCount() async => 2;

  @override
  Future<List<Map<String, dynamic>>> list(String filter) async => [
    _row({'id': 'c1', 'face_state': 'match', 'face_score': 91, 'face_provider': 'aws'}),
    _row({'id': 'c2', 'kind': 'selfie', 'name': 'Ravi'}),
  ];
}

class _ClosersIdentity extends _Identity {
  _ClosersIdentity(super.cfg);

  @override
  Future<List<Map<String, dynamic>>> list(String filter) async => [
    _row({'id': 'c1', 'face_state': 'match', 'face_score': 91, 'face_provider': 'aws'}),
    _row({
      'id': 'c5',
      'kind': 'selfie',
      'name': 'Ravi',
      'face_state': 'no_match',
      'face_score': 22,
      'face_provider': 'browser',
      'created_at': DateTime.now().toUtc().subtract(const Duration(days: 2)).toIso8601String(),
    }),
  ];
}

Future<void> _pump(
  WidgetTester tester,
  Widget child,
  _Identity identity,
  Brightness b, {
  bool scroll = true,
  List<Override> overrides = const [],
}) async {
  await tester.binding.setSurfaceSize(const Size(500, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        supabaseProvider.overrideWithValue(_db),
        ...quietLiveOverrides,
        identityRepositoryProvider.overrideWithValue(identity),
        adminAccessProvider.overrideWith((_) async => AdminAccess(const [AdminGrant(page: '*', edit: true)])),
        currentUserIdProvider.overrideWithValue('me'),
        ...overrides,
      ],
      child: MaterialApp(
        theme: appTheme(b),
        home: Scaffold(body: scroll ? SingleChildScrollView(padding: const EdgeInsets.all(16), child: child) : child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  // A message from the last step is closed first, as the user would.
  await closeAnyNotice(tester);
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Map<String, dynamic> _row(Map<String, dynamic> extra) => {
  'id': 'c1',
  'user_id': 'u1',
  'kind': 'id',
  'doc_type': 'mykad',
  'purpose': 'first',
  'status': 'Pending Review',
  'name': 'Aina binti Ahmad',
  'ic': '880202-10-1234',
  'created_at': DateTime.now().toUtc().toIso8601String(),
  ...extra,
};

void main() {
  for (final b in Brightness.values) {
    group('${b.name}:', () {
      testWidgets('the two orders, what a missing key means, the free reads', (tester) async {
        final identity = _Identity(
          // As 0320's server gives it unsaved: NAS, then AWS, then in-browser.
          IdentityConfig.fromJson({
            'faceOrder': [
              {'id': 'nas', 'on': true},
              {'id': 'aws', 'on': true},
              {'id': 'browser', 'on': true},
            ],
            'awsKey': false,
            'faceServer': false,
            'visionKey': false,
            'nasReader': false,
          }),
        );
        await _pump(tester, const IdentityProviderFields(), identity, b);
        expect(find.textContaining('NAS, then AWS, then in-browser'), findsOneWidget, reason: 'the default');
        expect(find.textContaining('Phone, then NAS'), findsOneWidget, reason: 'Google Vision off by default');
        expect(find.byKey(const ValueKey('face-provider-note')), findsOneWidget, reason: 'no AWS key or server yet');
        expect(find.textContaining('First 1,000 reads a month free'), findsOneWidget);
        expect(find.byKey(const ValueKey('id-read-note')), findsNothing, reason: 'Vision is off');
        expect(find.byKey(const ValueKey('id-read-nas-note')), findsOneWidget, reason: 'no NAS connected');
        expect(unreadableTexts(tester, find.byKey(const ValueKey('identity-providers'))), isEmpty);

        await _tap(tester, find.byKey(const ValueKey('face-order-down-aws')));
        expect(identity.calls, ['face nas:true,aws:true,browser:true']);
        expect(find.textContaining('NAS, then AWS, then in-browser'), findsOneWidget);

        await _tap(tester, find.byKey(const ValueKey('id-reader-switch-vision')));
        expect(identity.calls.last, 'read phone:true,nas:true,vision:true');
        expect(find.byKey(const ValueKey('id-read-note')), findsOneWidget, reason: 'no Vision key yet');

        await _tap(tester, find.byKey(const ValueKey('face-low-up')));
        expect(identity.calls.last, 'low 65');
        expect(find.text('Needs a closer look below 65% match'), findsOneWidget);
        expect(unreadableTexts(tester, find.byKey(const ValueKey('identity-providers'))), isEmpty);
      });

      testWidgets('read only without edit', (tester) async {
        final identity = _Identity(const IdentityConfig(faceProvider: 'self_hosted', awsKey: true, faceServer: true));
        await _pump(tester, const IdentityProviderFields(enabled: false), identity, b);
        expect(find.textContaining('compared by: NAS, then in-browser'), findsOneWidget);
        expect(find.byKey(const ValueKey('face-provider-note')), findsNothing, reason: 'its key is there');
        final up = tester.widget<IconButton>(find.byKey(const ValueKey('face-order-down-nas')));
        expect(up.onPressed, isNull);
        final sw = tester.widget<Switch>(find.byKey(const ValueKey('face-order-switch-aws')));
        expect(sw.onChanged, isNull);
      });

      testWidgets('the review: who gave the score', (tester) async {
        final identity = _Identity(const IdentityConfig(awsKey: true, faceServer: true));
        await _pump(
          tester,
          SignInCheckSheet(
            row: _row({'face_state': 'match', 'face_score': 82.4, 'face_provider': 'self_hosted'}),
            onChanged: () {},
          ),
          identity,
          b,
        );
        expect(find.text('82% match · NAS'), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(DetailTable)), isEmpty);
      });

      testWidgets('the review: not checked, and why', (tester) async {
        final identity = _Identity(
          const IdentityConfig(
            awsKey: false,
            faceServer: false,
            savedFaceOrder: [OrderSlot('aws', true), OrderSlot('nas', false), OrderSlot('browser', false)],
          ),
        );
        await _pump(tester, SignInCheckSheet(row: _row({}), onChanged: () {}), identity, b);
        expect(find.text('Not checked · No AWS key yet'), findsOneWidget);
        final browser = _Identity(
          const IdentityConfig(
            awsKey: false,
            faceServer: false,
            savedFaceOrder: [OrderSlot('aws', true), OrderSlot('nas', false), OrderSlot('browser', true)],
          ),
        );
        await _pump(tester, SignInCheckSheet(row: _row({'id': 'c9'}), onChanged: () {}), browser, b);
        expect(find.text('Not checked · No AWS key yet · in-browser check next'), findsOneWidget);
      });

      testWidgets('the review: the card read again with Google Vision', (tester) async {
        final identity = _Identity(const IdentityConfig());
        await _pump(
          tester,
          SignInCheckSheet(
            row: _row({'read_name': 'SITI', 'read_source': 'phone', 'mismatch': ['name']}),
            onChanged: () {},
          ),
          identity,
          b,
        );
        expect(find.text('the phone'), findsOneWidget);
        expect(find.byKey(const ValueKey('signin-check-mismatch')), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('signin-check-read-again')));
        expect(identity.calls, ['read c1']);
        expect(find.text('AINA BINTI AHMAD'), findsOneWidget);
        expect(find.text('Google Vision'), findsOneWidget);
        expect(find.byKey(const ValueKey('signin-check-mismatch')), findsNothing, reason: 'it matches now');
        expect(unreadableTexts(tester, find.byType(DetailTable)), isEmpty);
      });

      testWidgets('the queue: each upload says who scored it, or why not', (tester) async {
        final identity = _Identity(const IdentityConfig(faceProvider: 'self_hosted', awsKey: true, faceServer: false));
        await _pump(tester, const SignInChecksReview(), identity, b, scroll: false);
        expect(find.textContaining('91% match · AWS'), findsOneWidget);
        expect(find.textContaining('Not checked · Self-hosted server not set up'), findsOneWidget);
        // The status chip is the shared admin one; the line's own words are checked.
        expect(unreadableTexts(tester, find.textContaining('Not checked ·')), isEmpty);
      });

      testWidgets('the queue: low matches first, and the in-browser check scores what waits', (tester) async {
        final identity = _ClosersIdentity(const IdentityConfig(awsKey: false, faceServer: false));
        identity.queue = [
          {'id': 's1', 'other_id': 'c3', 'selfie_url': 'https://x/selfie.jpg', 'card_url': 'https://x/card.jpg'},
        ];
        final compared = <String>[];
        await _pump(
          tester,
          const SignInChecksReview(),
          identity,
          b,
          scroll: false,
          overrides: [
            browserFaceCompareProvider.overrideWithValue((a, c) async {
              compared.add('$a $c');
              return (state: 'match', score: 71.5);
            }),
            photoLinkProvider.overrideWithValue((url) async => '$url?signed'),
          ],
        );
        expect(compared, ['https://x/selfie.jpg?signed https://x/card.jpg?signed']);
        expect(identity.saved, ['s1 c3 match 71.5']);
        expect(find.textContaining('1 scored'), findsOneWidget);
        final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).map((t) => '${t.key}').toList();
        expect(tiles.first, contains('signin-check-c5'), reason: 'faces that differ come first');
        expect(find.textContaining('Needs a closer look'), findsOneWidget);
        expect(unreadableTexts(tester, find.byKey(const ValueKey('browser-face-status'))), isEmpty);
      });

      testWidgets('the in-browser check stays off when the order has it off', (tester) async {
        final identity = _Identity(
          const IdentityConfig(savedFaceOrder: [OrderSlot('aws', true), OrderSlot('nas', true), OrderSlot('browser', false)]),
        );
        await _pump(
          tester,
          const SignInChecksReview(),
          identity,
          b,
          scroll: false,
          overrides: [browserFaceCompareProvider.overrideWithValue((a, c) async => null)],
        );
        expect(find.byKey(const ValueKey('browser-face-status')), findsNothing);
      });

      testWidgets('a selfie has no card to read', (tester) async {
        final identity = _Identity(const IdentityConfig());
        await _pump(tester, SignInCheckSheet(row: _row({'kind': 'selfie'}), onChanged: () {}), identity, b);
        expect(find.byKey(const ValueKey('signin-check-read-again')), findsNothing);
      });
    });
  }
}
