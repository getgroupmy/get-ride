// Owner rules (0288): every selfie on a phone passes the live check (no
// file, no plain shutter; a modal and Try again when the check can't
// start), and a document with the person's photo needs a live selfie on
// record before it is sent (a modal asks for one), in light and dark.
import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/people_data.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/admin/screens/people/people_widgets.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/document_ai.dart';
import 'package:get_ride/src/data/document_ai_repository.dart';
import 'package:get_ride/src/data/identity_repository.dart';
import 'package:get_ride/src/widgets/live_selfie.dart';
import 'package:get_ride/src/widgets/live_selfie_gate.dart';
import 'package:get_ride/src/widgets/page_style_host.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

class _Identity extends IdentityRepository {
  _Identity({this.ok = false}) : super(_db);
  bool ok;
  final recorded = <LiveSelfie>[];

  @override
  Future<bool> liveSelfieOk() async => ok;

  @override
  Future<void> recordLiveSelfie(LiveSelfie selfie) async {
    recorded.add(selfie);
    ok = true;
  }
}

class _FakePeople implements PeopleRepository {
  final saved = <Map<String, dynamic>>[];

  @override
  Future<String> upload(String bucket, String path, PickedPeopleFile file) async => 'https://x.test/$path';

  @override
  Future<void> saveProviderDocument(Map<String, dynamic> payload) async => saved.add(payload);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAi implements DocumentAiRepository {
  @override
  Future<String?> prepare(Uint8List bytes, String name) async => 'data:image/png;base64,AA==';

  @override
  Future<({DocumentAiResult? result, String? reason})> verify(Map<String, dynamic> body) async =>
      (result: null, reason: 'not_configured');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _licence = RequiredDoc(
  id: 'licence',
  name: 'Driving License',
  description: '',
  compulsory: true,
  scope: 'global',
  labels: const [],
  flags: DocFlags.fromValues(const {'name': 'Driving License'}),
);

const _front = CameraDescription(name: 'front', lensDirection: CameraLensDirection.front, sensorOrientation: 270);

Future<void> _phone(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
}

void main() {
  test('licences, permits and IDs carry the photo by default', () {
    expect(_licence.flags.hasPhoto, isTrue);
    expect(DocFlags.fromValues(const {'name': 'Vehicle Insurance'}).hasPhoto, isFalse);
  });

  for (final b in Brightness.values) {
    group('document with the person\'s photo (${b.name})', () {
      Future<({_FakePeople people, List<int> gates})> open(WidgetTester tester, {required bool allow, String? user}) async {
        await _phone(tester);
        final people = _FakePeople();
        final gates = <int>[];
        await tester.pumpWidget(ProviderScope(
          overrides: [
            peopleRepositoryProvider.overrideWithValue(people),
            documentAiRepositoryProvider.overrideWithValue(_FakeAi()),
            docPhotoPickerProvider.overrideWithValue((_) async => (bytes: _png, name: 'front.png')),
            liveSelfieGateProvider.overrideWithValue((_) async {
              gates.add(1);
              return allow;
            }),
          ],
          child: MaterialApp(
            theme: appTheme(b),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAppDialog<bool>(
                    id: 'admin-people.upload-document',
                    context: context,
                    builder: (_) => DocUploadDialog(partnerId: 'p1', doc: _licence, authUserId: user),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tap to upload'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        return (people: people, gates: gates);
      }

      testWidgets('the partner without a live selfie: nothing is sent', (tester) async {
        final r = await open(tester, allow: false, user: 'u1');
        expect(r.gates, [1]);
        expect(r.people.saved, isEmpty);
        expect(tester.takeException(), isNull);
      });

      testWidgets('with one, it is sent', (tester) async {
        final r = await open(tester, allow: true, user: 'u1');
        expect(r.gates, [1]);
        expect(r.people.saved.single['doc_id'], 'licence');
      });

      testWidgets("an admin's upload for the partner isn't held", (tester) async {
        final r = await open(tester, allow: false);
        expect(r.gates, isEmpty);
        expect(r.people.saved, hasLength(1));
      });
    });

    group('ensureLiveSelfie (${b.name})', () {
      Future<bool?> run(WidgetTester tester, _Identity identity, {required bool onPhone, LiveSelfie? selfie}) async {
        await _phone(tester);
        bool? result;
        await tester.pumpWidget(MaterialApp(
          theme: appTheme(b),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await ensureLiveSelfie(
                context,
                identity,
                onPhone: onPhone,
                takeSelfie: (_) async => selfie,
              ),
              child: const Text('send'),
            ),
          ),
        ));
        await tester.tap(find.text('send'));
        await tester.pumpAndSettle();
        return result;
      }

      testWidgets('a live selfie on record: straight through', (tester) async {
        expect(await run(tester, _Identity(ok: true), onPhone: true), isTrue);
        expect(find.byKey(const ValueKey('live-selfie-needed')), findsNothing);
      });

      testWidgets('web or desktop: sent, the server marks it not checked', (tester) async {
        expect(await run(tester, _Identity(), onPhone: false), isTrue);
        expect(find.byKey(const ValueKey('live-selfie-needed')), findsNothing);
      });

      testWidgets('none yet: a modal asks for one, then it is kept', (tester) async {
        final identity = _Identity();
        await run(
          tester,
          identity,
          onPhone: true,
          selfie: LiveSelfie(bytes: Uint8List(4), liveness: 'passed', detail: 'turn'),
        );
        expect(find.byKey(const ValueKey('live-selfie-needed')), findsOneWidget);
        expect(find.text('Take a live selfie first'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('live-selfie-take')));
        await tester.pumpAndSettle();
        expect(identity.recorded.single.detail, 'turn');
      });

      testWidgets('backing out sends nothing', (tester) async {
        final identity = _Identity();
        await run(tester, identity, onPhone: true);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(identity.recorded, isEmpty);
      });
    });

    group('LiveSelfieScreen (${b.name})', () {
      Future<List<int>> open(WidgetTester tester, {required bool onPhone, required List<CameraDescription> cams}) async {
        await _phone(tester);
        final asked = <int>[];
        await tester.pumpWidget(MaterialApp(
          theme: appTheme(b),
          home: LiveSelfieScreen(
            onPhone: onPhone,
            cameras: () async {
              asked.add(1);
              return cams;
            },
            openFaces: () => null,
            pickFile: () async => (bytes: _png, name: 'me.png', ext: 'png', contentType: 'image/png'),
          ),
        ));
        await tester.pumpAndSettle();
        return asked;
      }

      testWidgets('on a phone, a face check that cannot start: a modal and Try again, never a way round', (tester) async {
        final asked = await open(tester, onPhone: true, cams: const [_front]);
        expect(find.byKey(const ValueKey('selfie-check-failed')), findsOneWidget);
        expect(find.text("The face check couldn't start"), findsWidgets);
        expect(find.byKey(const ValueKey('selfie-file')), findsNothing);
        expect(find.byKey(const ValueKey('selfie-take')), findsNothing);
        expect(find.byKey(const ValueKey('selfie-take-anyway')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('selfie-check-retry')));
        await tester.pumpAndSettle();
        expect(asked, [1, 1], reason: 'tried again');
        expect(find.byKey(const ValueKey('selfie-check-failed')), findsOneWidget);
      });

      testWidgets('a device with no camera at all may choose a file, not checked', (tester) async {
        await open(tester, onPhone: true, cams: const []);
        expect(find.byKey(const ValueKey('selfie-file')), findsOneWidget);
        expect(find.byKey(const ValueKey('selfie-check-failed')), findsNothing);
      });
    });
  }
}
