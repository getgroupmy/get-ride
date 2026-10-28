// The sign-in checks of a dispatch ID (migration 0281) on screen, light and
// dark: the admin's "When they sign in" switches, the phone's steps (a
// selfie with the reason the last was rejected, the ID with what was read,
// waiting for approval, paused), /dispatch while the role is shut, the
// selfie camera where there is none, and the admin's review of an upload.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/dispatch/signin_checks_fields.dart';
import 'package:get_ride/src/admin/screens/meterapp/pick_image.dart' show PickedImage;
import 'package:get_ride/src/admin/screens/signin_checks_review.dart';
import 'package:get_ride/src/admin/widgets/admin_widgets.dart' show DetailTable;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/signin_checks.dart';
import 'package:get_ride/src/data/dispatch_repository.dart';
import 'package:get_ride/src/data/identity_repository.dart';
import 'package:get_ride/src/features/dispatch/dispatch_screen.dart';
import 'package:get_ride/src/features/dispatch/signin_steps.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/live_selfie.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';
import 'text_contrast.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));
final _png = img.encodePng(img.Image(width: 4, height: 4));

class _Identity extends IdentityRepository {
  _Identity() : super(_db);
  final sent = <String>[];

  @override
  Future<void> sendSelfie(LiveSelfie selfie, {bool recheck = false}) async =>
      sent.add('selfie ${selfie.liveness} ${recheck ? 'recheck' : 'first'}');

  @override
  Future<List<String>> sendId({
    required String docType,
    required List<int> front,
    required List<int> back,
    String? expiry,
    CardRead? read,
  }) async {
    sent.add('id $docType ${expiry ?? ''} ${read?.name ?? ''}'.trim());
    return const [];
  }

  @override
  Future<void> review(String id, {required bool approve, String? reason, String? note}) async =>
      sent.add('review $id ${approve ? 'approve' : 'reject'} ${reason ?? ''}'.trim());

  @override
  Future<int> waitingCount() async => 2;
}

DispatchChecks _checks(Map<String, dynamic> m) => DispatchChecks.fromJson({
  'holds': true,
  'kinds': ['stand_admin'],
  'asks_selfie': true,
  'asks_id': true,
  ...m,
});

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Brightness b = Brightness.light,
  _Identity? identity,
  List<Override> overrides = const [],
}) async {
  await tester.binding.setSurfaceSize(const Size(500, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final router = GoRouter(
    initialLocation: '/test',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('user mode'))),
      GoRoute(path: '/test', builder: (_, _) => Scaffold(body: child)),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        supabaseProvider.overrideWithValue(_db),
        ...quietLiveOverrides,
        identityRepositoryProvider.overrideWithValue(identity ?? _Identity()),
        adminAccessProvider.overrideWith((_) async => AdminAccess(const [AdminGrant(page: '*', edit: true)])),
        currentUserIdProvider.overrideWithValue('me'),
        ...overrides,
      ],
      child: MaterialApp.router(theme: appTheme(b), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  for (final b in Brightness.values) {
    group('${b.name}:', () {
      testWidgets("the admin's switches: PIN locked on, a deadline once something is asked", (tester) async {
        var asks = const SignInAsks();
        var bad = false;
        await _pump(
          tester,
          StatefulBuilder(
            builder: (_, set) => SignInChecksFields(
              value: asks,
              onChanged: (a) => set(() => asks = a),
              onDaysBad: (x) => bad = x,
            ),
          ),
          b: b,
        );
        expect(find.text('When they sign in'), findsOneWidget);
        final pin = tester.widget<SwitchListTile>(find.byKey(const ValueKey('ask-pin')));
        expect(pin.value, isTrue);
        expect(pin.onChanged, isNull, reason: 'shown locked on');
        expect(find.byKey(const ValueKey('ask-days')), findsNothing);

        await _tap(tester, find.byKey(const ValueKey('ask-selfie')));
        await _tap(tester, find.byKey(const ValueKey('ask-id')));
        expect(asks, const SignInAsks(selfie: true, id: true));
        await tester.enterText(find.byKey(const ValueKey('ask-days')), '0');
        await tester.pumpAndSettle();
        expect(bad, isTrue);
        expect(find.text('Give 1 to 365 days, or leave it blank.'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('ask-days')), '7');
        await tester.pumpAndSettle();
        expect(bad, isFalse);
        expect(asks.toJson(), {'verify_selfie': true, 'verify_id': true, 'verify_days': 7});
        expect(unreadableTexts(tester, find.byType(Scaffold).first), isEmpty);
      });

      testWidgets('the selfie step: the reason it was turned down, then the camera', (tester) async {
        final identity = _Identity();
        await _pump(
          tester,
          SignInStepsView(
            checks: _checks({
              'needs': ['selfie', 'id'],
              'deadline': DateTime.now().add(const Duration(days: 3)).toUtc().toIso8601String(),
              'selfie': {'state': 'rejected', 'reason': 'face_unclear', 'note': 'Take off the cap'},
            }),
            takeSelfie: (_) async => LiveSelfie(bytes: _png, liveness: 'passed', detail: 'blink'),
          ),
          b: b,
          identity: identity,
        );
        expect(find.text('Take a selfie'), findsOneWidget);
        expect(find.textContaining('3 days left to finish'), findsOneWidget);
        expect(find.text("Your photo wasn't accepted: Face not clear: Take off the cap"), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(Scaffold).first), isEmpty);
        await _tap(tester, find.byKey(const ValueKey('step-selfie')));
        expect(identity.sent.single, 'selfie passed first');
      });

      testWidgets('a new phone asks for a selfie again', (tester) async {
        final identity = _Identity();
        await _pump(
          tester,
          SignInStepsView(
            checks: _checks({
              'needs': ['recheck'],
              'selfie': {'state': 'ok'},
              'id': {'state': 'ok'},
            }),
            takeSelfie: (_) async => LiveSelfie(bytes: _png),
          ),
          b: b,
          identity: identity,
        );
        expect(find.text('New phone: take a selfie'), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('step-selfie')));
        expect(identity.sent.single, 'selfie not_checked recheck');
      });

      testWidgets('the ID step: front and back, what was read, a passport needs its expiry', (tester) async {
        final identity = _Identity();
        PickedImage photo() => (bytes: _png, name: 'id.png', ext: 'png', contentType: 'image/png');
        await _pump(
          tester,
          SignInStepsView(
            checks: _checks({
              'needs': ['id'],
              'selfie': {'state': 'received'},
              'id': {'state': 'rejected', 'reason': 'expired'},
            }),
            pickPhoto: (_) async => photo(),
            readCard: (_) async => (name: 'AINA BINTI AHMAD', ic: '880202-10-1234', expiry: null),
          ),
          b: b,
          identity: identity,
        );
        expect(find.text('Upload your ID'), findsOneWidget);
        expect(find.text("Your ID wasn't accepted: Expired"), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('id-send')));
        expect(find.text('Add a photo of the front and the back.'), findsOneWidget);

        await _tap(tester, find.byKey(const ValueKey('id-front')));
        expect(find.text('Read from the card: AINA BINTI AHMAD · 880202-10-1234'), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('id-back')));
        await _tap(tester, find.text('Passport'));
        expect(find.byKey(const ValueKey('id-expiry')), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('id-send')));
        expect(find.text("Add the passport's expiry date."), findsOneWidget);
        expect(identity.sent, isEmpty);
        expect(unreadableTexts(tester, find.byType(Scaffold).first), isEmpty);

        await _tap(tester, find.text('MyKad'));
        await _tap(tester, find.byKey(const ValueKey('id-send')));
        expect(identity.sent.single, 'id mykad  AINA BINTI AHMAD');
      });

      testWidgets('waiting for approval: what was sent, and the way to user mode', (tester) async {
        await _pump(
          tester,
          SignInStepsView(
            checks: _checks({
              'needs': ['pending'],
              'selfie': {'state': 'received'},
              'id': {'state': 'pending'},
            }),
          ),
          b: b,
        );
        expect(find.text('Waiting for approval'), findsOneWidget);
        expect(find.text('Waiting for review'), findsOneWidget);
        expect(find.text('Received'), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(Scaffold).first), isEmpty);
        await _tap(tester, find.byKey(const ValueKey('go-user-mode')));
        expect(find.text('user mode'), findsOneWidget);
      });

      testWidgets('past the deadline: paused, the steps still there', (tester) async {
        await _pump(
          tester,
          SignInStepsView(checks: _checks({'needs': ['selfie'], 'paused': true})),
          b: b,
        );
        expect(find.byKey(const ValueKey('steps-paused')), findsOneWidget);
        expect(find.textContaining('paused: not verified'), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(Scaffold).first), isEmpty);
      });

      testWidgets('/dispatch shows the steps while the role is shut', (tester) async {
        await _pump(
          tester,
          const DispatchScreen(ticking: false),
          b: b,
          overrides: [
            dispatchRolesProvider.overrideWith((_) async => DispatchRoles.none),
            dispatchChecksProvider.overrideWith(
              (_) async => _checks({'needs': ['pending'], 'id': {'state': 'pending'}, 'selfie': {'state': 'ok'}}),
            ),
          ],
        );
        expect(find.byKey(const ValueKey('signin-steps')), findsOneWidget);
        expect(find.text('No stand or fleet'), findsNothing);
      });

      testWidgets('no camera: the selfie comes from a file, marked not checked', (tester) async {
        LiveSelfie? got;
        await _pump(
          tester,
          Builder(
            builder: (context) => TextButton(
              onPressed: () async => got = await Navigator.of(context).push<LiveSelfie>(
                MaterialPageRoute(
                  builder: (_) => LiveSelfieScreen(
                    cameras: () async => const [],
                    pickFile: () async => (bytes: _png, name: 'me.png', ext: 'png', contentType: 'image/png'),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
          b: b,
        );
        await _tap(tester, find.text('open'));
        expect(find.textContaining('no camera we can use'), findsOneWidget);
        expect(unreadableTexts(tester, find.byType(Scaffold).last), isEmpty);
        await _tap(tester, find.byKey(const ValueKey('selfie-file')));
        expect(got?.liveness, 'not_checked');
        expect(got?.live, isFalse);
      });

      testWidgets('the review: the mismatch warning, the face match, a reason to reject', (tester) async {
        final identity = _Identity();
        final row = {
          'id': 'c1',
          'user_id': 'u1',
          'kind': 'id',
          'doc_type': 'mykad',
          'purpose': 'first',
          'status': 'Pending Review',
          'name': 'Aina binti Ahmad',
          'ic': '880202-10-1234',
          'read_name': 'SITI NURHALIZA',
          'read_ic': '900101-14-5678',
          'mismatch': ['name', 'ic'],
          'created_at': DateTime.now().toUtc().toIso8601String(),
        };
        await _pump(
          tester,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: SingleChildScrollView(child: SignInCheckSheet(row: row, onChanged: () {})),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
          b: b,
          identity: identity,
        );
        await _tap(tester, find.text('open'));
        expect(find.byKey(const ValueKey('signin-check-mismatch')), findsOneWidget);
        expect(find.text('Not checked · in-browser check next'), findsOneWidget, reason: 'no face match yet; the browser scores it (0320)');
        // The status chip is the shared admin one; the sheet's own words are checked.
        expect(unreadableTexts(tester, find.byKey(const ValueKey('signin-check-mismatch'))), isEmpty);
        expect(unreadableTexts(tester, find.byType(DetailTable)), isEmpty);

        await _tap(tester, find.byKey(const ValueKey('signin-check-reject')));
        expect(find.byKey(const ValueKey('reject-reason-dialog')), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('reason-reject')));
        expect(find.text('Pick why.'), findsOneWidget);
        await _tap(tester, find.byKey(const ValueKey('reason-name_mismatch')));
        await _tap(tester, find.byKey(const ValueKey('reason-reject')));
        expect(identity.sent.single, 'review c1 reject name_mismatch');
      });
    });
  }
}
