import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/people_data.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/admin/screens/people/people_widgets.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/document_ai.dart';
import 'package:get_ride/src/core/driver_permit.dart';
import 'package:get_ride/src/core/image_crop.dart';
import 'package:get_ride/src/data/document_ai_repository.dart';

/// A real 1×1 PNG, so the preview decodes.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

Map<String, dynamic> _permitResult({Object? box = const {'x': 0.05, 'y': 0.2, 'width': 0.25, 'height': 0.5}}) => {
  'isReal': true,
  'isRelevant': true,
  'matchesTitle': true,
  'detectedTitle': 'Taxi driver permit',
  'confidence': 0.9,
  'reason': 'Looks genuine.',
  'extracted': {
    'documentNumber': 'LPKP-1',
    'taxiPermit': {
      'name': 'Ali bin Abu',
      'idNumber': '900101-14-5555',
      'validityFrom': '2025-01-01',
      'validityTo': '2027-01-01',
      'hasImageOnPermit': true,
      'photoBox': box,
      'photoUrl': null,
    },
  },
};

class _FakePeople implements PeopleRepository {
  final uploads = <String>[];
  final saved = <Map<String, dynamic>>[];
  final savedVehicle = <Map<String, dynamic>>[];

  @override
  Future<String> upload(String bucket, String path, PickedPeopleFile file) async {
    uploads.add('$bucket/$path');
    return 'https://x.test/$bucket/$path';
  }

  @override
  Future<void> saveProviderDocument(Map<String, dynamic> payload) async => saved.add(payload);

  @override
  Future<void> saveVehicleDocument(Map<String, dynamic> payload) async => savedVehicle.add(payload);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAi implements DocumentAiRepository {
  _FakeAi(this.result);
  final Map<String, dynamic>? result;
  final bodies = <Map<String, dynamic>>[];

  @override
  Future<String?> prepare(Uint8List bytes, String name) async => 'data:image/png;base64,AA==';

  @override
  Future<({DocumentAiResult? result, String? reason})> verify(Map<String, dynamic> body) async {
    bodies.add(body);
    return result == null ? (result: null, reason: 'no_keys') : (result: DocumentAiResult(result!), reason: null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RequiredDoc _doc({bool permit = true}) => RequiredDoc(
  id: 'permit',
  name: 'Taxi driver permit',
  description: '',
  compulsory: true,
  scope: 'global',
  labels: const [],
  flags: DocFlags(isTaxiPermit: permit),
);

void main() {
  test('the admin tag is read off the required document', () {
    expect(DocFlags.fromValues({'isTaxiPermit': true}).isTaxiPermit, isTrue);
    expect(DocFlags.fromValues({'isTaxiPermit': 'true'}).isTaxiPermit, isTrue);
    expect(DocFlags.fromValues({}).isTaxiPermit, isFalse);
    expect(const DocFlags().isTaxiPermit, isFalse);
  });

  test('a permit check asks the function for the permit fields', () {
    final body = docAiRequestBody(frontDataUrl: 'data:x', docName: 'Taxi permit', isTaxiPermit: true);
    expect((body['context'] as Map)['isTaxiPermit'], isTrue);
    final plain = docAiRequestBody(frontDataUrl: 'data:x', docName: 'Licence');
    expect((plain['context'] as Map).containsKey('isTaxiPermit'), isFalse);
  });

  test('the permit fields and the portrait box are read off the answer', () {
    final r = DocumentAiResult(_permitResult());
    expect(r.taxiPermit!['name'], 'Ali bin Abu');
    expect(r.permitPhotoBox, const FractionBox(x: 0.05, y: 0.2, width: 0.25, height: 0.5));
    expect(DocumentAiResult(_permitResult(box: null)).permitPhotoBox, isNull);
    expect(DocumentAiResult(_permitResult(box: {'x': 0, 'y': 0, 'width': 0, 'height': 1})).permitPhotoBox, isNull);
    expect(DocumentAiResult({'extracted': {}}).taxiPermit, isNull);
  });

  test('only a partner permit with a portrait is cropped', () {
    final r = DocumentAiResult(_permitResult());
    expect(permitPhotoToCrop(isTaxiPermit: true, vehicleDocument: false, ai: r), isNotNull);
    expect(permitPhotoToCrop(isTaxiPermit: false, vehicleDocument: false, ai: r), isNull);
    expect(permitPhotoToCrop(isTaxiPermit: true, vehicleDocument: true, ai: r), isNull);
    expect(permitPhotoToCrop(isTaxiPermit: true, vehicleDocument: false), isNull);
  });

  test('the portrait URL is stored where the permit card reads it', () {
    final raw = _permitResult();
    final patched = docAiWithPermitPhoto(raw, 'https://x.test/p.jpg');
    final permit = (patched['extracted'] as Map)['taxiPermit'] as Map;
    expect(permit['photoUrl'], 'https://x.test/p.jpg');
    expect(permit['name'], 'Ali bin Abu', reason: 'the other fields are kept');
    expect((patched['extracted'] as Map)['documentNumber'], 'LPKP-1');
    expect(patched['matchesTitle'], isTrue);
    expect(((raw['extracted'] as Map)['taxiPermit'] as Map)['photoUrl'], isNull, reason: 'the input is not changed');
    // No permit block at all still gets one.
    expect(((docAiWithPermitPhoto({}, 'u')['extracted'] as Map)['taxiPermit'] as Map)['photoUrl'], 'u');

    final card = resolveDriverPermit(
      profile: const {'avatar_url': 'https://x.test/avatar.png'},
      document: {'id': 'd1', 'ai_verification': patched},
    );
    expect(card.photoUrl, 'https://x.test/p.jpg');
  });

  for (final b in Brightness.values) {
    group('upload dialog (${b.name})', () {
      Future<(_FakePeople, _FakeAi, List<FractionBox>)> pump(
        WidgetTester tester, {
        required RequiredDoc doc,
        Map<String, dynamic>? ai,
        String? vehicleId,
        Uint8List? crop,
      }) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(900, 1400);
        addTearDown(tester.view.reset);
        final people = _FakePeople();
        final fakeAi = _FakeAi(ai);
        final cropped = <FractionBox>[];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              peopleRepositoryProvider.overrideWithValue(people),
              documentAiRepositoryProvider.overrideWithValue(fakeAi),
              docPhotoPickerProvider.overrideWithValue((_) async => (bytes: _png, name: 'permit.png')),
              docImageCropProvider.overrideWithValue((bytes, box) async {
                cropped.add(box);
                return crop;
              }),
            ],
            child: MaterialApp(
              theme: appTheme(b),
              home: Scaffold(
                body: DocUploadDialog(partnerId: 'p1', doc: doc, vehicleId: vehicleId),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tap to upload'));
        await tester.pumpAndSettle();
        return (people, fakeAi, cropped);
      }

      testWidgets('a permit portrait is cut out, uploaded and stored on the check', (tester) async {
        final (people, ai, cropped) = await pump(
          tester,
          doc: _doc(),
          ai: _permitResult(),
          crop: Uint8List.fromList([1, 2, 3]),
        );
        expect((ai.bodies.single['context'] as Map)['isTaxiPermit'], isTrue);
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(cropped.single, const FractionBox(x: 0.05, y: 0.2, width: 0.25, height: 0.5));
        expect(people.uploads, hasLength(2));
        expect(people.uploads.last, matches(RegExp(r'^provider-documents/p1/permit/permit-photo-\d+\.jpg$')));
        final stored = people.saved.single['ai_verification'] as Map;
        expect(
          ((stored['extracted'] as Map)['taxiPermit'] as Map)['photoUrl'],
          'https://x.test/${people.uploads.last}',
        );
      });

      testWidgets('without a usable crop the document still saves', (tester) async {
        final (people, _, cropped) = await pump(tester, doc: _doc(), ai: _permitResult());
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(cropped, hasLength(1));
        expect(people.uploads, hasLength(1), reason: 'just the front');
        final stored = people.saved.single['ai_verification'] as Map;
        expect(((stored['extracted'] as Map)['taxiPermit'] as Map)['photoUrl'], isNull);
      });

      testWidgets('an untagged document is not cropped', (tester) async {
        final (people, ai, cropped) = await pump(
          tester,
          doc: _doc(permit: false),
          ai: _permitResult(),
          crop: Uint8List(3),
        );
        expect((ai.bodies.single['context'] as Map).containsKey('isTaxiPermit'), isFalse);
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(cropped, isEmpty);
        expect(people.uploads, hasLength(1));
      });

      testWidgets('a vehicle document is never cropped', (tester) async {
        final (people, _, cropped) = await pump(
          tester,
          doc: _doc(),
          ai: _permitResult(),
          vehicleId: 'v1',
          crop: Uint8List(3),
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(cropped, isEmpty);
        expect(people.uploads.single, startsWith('vehicle-documents/v1/permit/front-'));
        expect(people.savedVehicle, hasLength(1));
      });
    });
  }
}
