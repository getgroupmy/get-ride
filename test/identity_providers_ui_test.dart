// Who compares the faces and who reads the card (migration 0283) on screen,
// light and dark: the admin's two settings next to the renewal window, with
// the line saying a key is missing, and the review of an upload showing who
// gave the score, why a face isn't checked, and reading the card again with
// Google Vision.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

Future<void> _pump(WidgetTester tester, Widget child, _Identity identity, Brightness b, {bool scroll = true}) async {
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
      testWidgets('the two settings, what a missing key means, the free reads', (tester) async {
        final identity = _Identity(const IdentityConfig(awsKey: false, faceServer: false, visionKey: false));
        await _pump(tester, const IdentityProviderFields(), identity, b);
        expect(find.text('Face match'), findsOneWidget);
        expect(find.text('AWS Rekognition'), findsOneWidget, reason: 'the default');
        expect(find.text('On the phone only'), findsOneWidget, reason: 'the default');
        expect(find.byKey(const ValueKey('face-provider-note')), findsOneWidget, reason: 'no AWS key yet');
        expect(find.textContaining('First 1,000 reads a month free'), findsOneWidget);
        expect(find.byKey(const ValueKey('id-read-note')), findsNothing, reason: 'the phone needs no key');
        expect(unreadableTexts(tester, find.byKey(const ValueKey('identity-providers'))), isEmpty);

        await _tap(tester, find.text('AWS Rekognition'));
        expect(find.text('Self-hosted, then AWS'), findsWidgets);
        await _tap(tester, find.text('Self-hosted, then AWS').last);
        expect(identity.calls, ['set self_hosted_aws -']);
        expect(find.textContaining('face match server or an AWS key'), findsOneWidget);

        await _tap(tester, find.text('On the phone only'));
        await _tap(tester, find.text('Google Vision always').last);
        expect(identity.calls.last, 'set - vision');
        expect(find.byKey(const ValueKey('id-read-note')), findsOneWidget, reason: 'no Vision key yet');
        expect(unreadableTexts(tester, find.byKey(const ValueKey('identity-providers'))), isEmpty);
      });

      testWidgets('read only without edit', (tester) async {
        final identity = _Identity(const IdentityConfig(faceProvider: 'self_hosted', awsKey: true, faceServer: true));
        await _pump(tester, const IdentityProviderFields(enabled: false), identity, b);
        expect(find.text('Self-hosted server'), findsOneWidget);
        expect(find.byKey(const ValueKey('face-provider-note')), findsNothing, reason: 'its key is there');
        await tester.tap(find.text('Self-hosted server'), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(find.text('Off'), findsNothing, reason: 'no list opens');
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
        expect(find.text('82% match · self-hosted'), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(DetailTable)), isEmpty);
      });

      testWidgets('the review: not checked, and why', (tester) async {
        final identity = _Identity(const IdentityConfig(awsKey: false, faceServer: false));
        await _pump(tester, SignInCheckSheet(row: _row({}), onChanged: () {}), identity, b);
        expect(find.text('Not checked · No AWS key yet'), findsOneWidget);
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

      testWidgets('a selfie has no card to read', (tester) async {
        final identity = _Identity(const IdentityConfig());
        await _pump(tester, SignInCheckSheet(row: _row({'kind': 'selfie'}), onChanged: () {}), identity, b);
        expect(find.byKey(const ValueKey('signin-check-read-again')), findsNothing);
      });
    });
  }
}
