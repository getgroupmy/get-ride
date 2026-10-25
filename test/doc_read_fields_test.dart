// Document reading, part 3: the fields read off the photo, checked and fixed
// by the partner at upload, kept with what they changed and the photo check.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/doc_fields_section.dart';
import 'package:get_ride/src/admin/screens/people/doc_read_fields.dart';
import 'package:get_ride/src/admin/screens/people/people_data.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/admin/screens/people/people_widgets.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/doc_kinds.dart';
import 'package:get_ride/src/core/document_ai.dart';
import 'package:get_ride/src/core/photo_quality.dart';
import 'package:get_ride/src/data/document_ai_repository.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

class _FakePeople implements PeopleRepository {
  final saved = <Map<String, dynamic>>[];

  @override
  Future<String> upload(String bucket, String path, PickedPeopleFile file) async => 'https://x.test/$bucket/$path';

  @override
  Future<void> saveProviderDocument(Map<String, dynamic> payload) async => saved.add(payload);

  @override
  Future<void> saveVehicleDocument(Map<String, dynamic> payload) async => saved.add(payload);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAi implements DocumentAiRepository {
  _FakeAi(this.fields);
  final Map<String, dynamic> fields;
  final bodies = <Map<String, dynamic>>[];

  @override
  Future<String?> prepare(Uint8List bytes, String name) async => 'data:image/png;base64,AA==';

  @override
  Future<({DocumentAiResult? result, String? reason})> verify(Map<String, dynamic> body) async {
    bodies.add(body);
    return (
      result: DocumentAiResult({
        'isReal': true,
        'isRelevant': true,
        'matchesTitle': true,
        'detectedTitle': 'Cover note',
        'confidence': 0.9,
        'reason': 'Looks genuine.',
        'extracted': {'permitFields': fields},
      }),
      reason: null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _today = DateTime(2026, 10, 25);

void main() {
  group('the fields to confirm', () {
    test('read fields only, in the kind\'s order; dates as yyyy-mm-dd; what was changed', () {
      final r = DocReadFields(docKindById('cover')!, {
        'engine': '1KR-A123456',
        'plate': 'WXY 1234',
        'periodTo': '06/11/2026',
        'ncd': null,
        'unknown': 'x',
        'excess': '  ',
      });
      expect([for (final f in r.fields) f.key], ['plate', 'engine', 'periodTo']);
      expect(r.controller('periodTo').text, '2026-11-06');
      expect(r.changed, isEmpty, reason: 'a date written another way is not a change');
      r.controller('engine').text = '1kr-a123456 ';
      expect(r.changed, isEmpty, reason: 'case and spaces are not a change');
      r.controller('plate').text = 'WXY 1243';
      expect(r.changed, ['plate']);
      expect(r.validUntil, '2026-11-06');
      expect(r.toJson(photo: const PhotoQuality(sharp: true, noGlare: false, allCorners: true)), {
        'kind': 'cover',
        'fields': {'plate': 'WXY 1243', 'engine': '1kr-a123456', 'periodTo': '2026-11-06'},
        'changed': ['plate'],
        'photo': {'sharp': true, 'glare': true, 'corners': true},
      });
      expect(r.hint(docKindById('cover')!.fields.firstWhere((f) => f.key == 'periodTo'), _today), 'Ends in 12 days.');
      r.dispose();
      expect(DocReadFields(docKindById('cover')!, const {}).isEmpty, isTrue);
    });

    test('the expiry read off the document fills one the form doesn\'t ask for, when still to come', () {
      Map<String, dynamic> payload(String? readExpiry, {bool requireExpiry = false}) => providerDocPayload(
            partnerId: 'p1',
            authUserId: 'u1',
            docId: 'd1',
            docName: 'Cover note',
            flags: DocFlags(requireExpiryDate: requireExpiry),
            documentNumber: '',
            insuranceProviderId: null,
            insuranceProviderName: null,
            isPwd: false,
            startDate: '',
            expiryDate: '',
            fileUrl: 'u',
            fileUrlBack: null,
            uploadedAt: 'now',
            readFields: const {'kind': 'cover'},
            readExpiry: readExpiry,
          );
      final next = DateTime.now().add(const Duration(days: 40));
      final iso = '${next.year}-${next.month.toString().padLeft(2, '0')}-${next.day.toString().padLeft(2, '0')}';
      expect(payload(iso)['expiry_date'], iso);
      expect(payload('2020-01-01')['expiry_date'], isNull, reason: 'a past date is left for the reviewer');
      expect(payload(iso, requireExpiry: true)['expiry_date'], isNull, reason: 'the form\'s own date wins');
      expect(payload(null)['read_fields'], {'kind': 'cover'});
    });
  });

  group('upload dialog', () {
    Future<(_FakePeople, _FakeAi)> pump(WidgetTester tester, {PhotoQuality? quality}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 2000);
      addTearDown(tester.view.reset);
      final people = _FakePeople();
      final ai = _FakeAi({'plate': 'WXY 1234', 'engine': '1KR-A123456', 'periodTo': '2020-01-01'});
      await tester.pumpWidget(ProviderScope(
        overrides: [
          peopleRepositoryProvider.overrideWithValue(people),
          documentAiRepositoryProvider.overrideWithValue(ai),
          docPhotoPickerProvider.overrideWithValue((_) async => (bytes: _png, name: 'cover.png')),
          photoQualityCheckProvider.overrideWithValue((_) async => quality),
        ],
        child: MaterialApp(
          theme: appTheme(Brightness.light),
          home: Scaffold(
            body: DocUploadDialog(
              partnerId: 'p1',
              vehicleId: 'v1',
              doc: RequiredDoc(
                id: 'cover',
                name: 'Insurance cover note',
                description: '',
                compulsory: true,
                scope: 'global',
                labels: const [],
                flags: DocFlags(readAs: docKindById('cover')),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tap to upload'));
      await tester.pumpAndSettle();
      return (people, ai);
    }

    testWidgets('the photo check, then every field read to check and fix', (tester) async {
      final (people, ai) =
          await pump(tester, quality: const PhotoQuality(sharp: true, noGlare: false, allCorners: true));
      final asked = (ai.bodies.single['context'] as Map)['permitFields'] as List;
      expect(asked.length, 20, reason: 'every field of a cover note');
      expect(find.text('Sharp'), findsOneWidget);
      expect(find.text('Glare'), findsOneWidget);
      expect(find.text('All four corners'), findsOneWidget);
      expect(find.byKey(const ValueKey('photo-advice')), findsOneWidget);
      expect(find.text('We read these from your photo'), findsOneWidget);
      expect(find.byKey(const ValueKey('doc-read-plate')), findsOneWidget);
      expect(find.text('Expired.'), findsOneWidget, reason: 'an expired cover is pointed out');

      await tester.enterText(find.byKey(const ValueKey('doc-read-plate')), 'WXY 1243');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final rf = people.saved.single['read_fields'] as Map;
      expect(rf['kind'], 'cover');
      expect((rf['fields'] as Map)['plate'], 'WXY 1243');
      expect(rf['changed'], ['plate']);
      expect(rf['photo'], {'sharp': true, 'glare': true, 'corners': true});
      expect(people.saved.single['expiry_date'], isNull, reason: 'an expired date is not used for reminders');
    });

    testWidgets('a photo that can\'t be checked shows no checks', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('photo-checks')), findsNothing);
      expect(find.byKey(const ValueKey('doc-read-fields')), findsOneWidget);
    });
  });

  group('admin review', () {
    testWidgets('what the partner confirmed, what they changed, and the photo check', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final doc = {
        'doc_id': 'rd1',
        'doc_name': 'Insurance',
        '_onFile': const DocOnFile(plate: 'WXY 1234'),
        'ai_verification': {
          'extracted': {
            'permitFields': {'plate': 'WXY 1234'},
          },
        },
        'read_fields': {
          'kind': 'cover',
          'fields': {'plate': 'WXY 1243'},
          'changed': ['plate'],
          'photo': {'sharp': false, 'glare': false, 'corners': true},
        },
      };
      await tester.pumpWidget(ProviderScope(
        overrides: [requiredDocKindsProvider.overrideWith((_) async => {'rd1': docKindById('cover')})],
        child: MaterialApp(
          theme: appTheme(Brightness.light),
          home: Scaffold(body: SingleChildScrollView(child: DocFieldsSection(doc: doc, today: _today))),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('WXY 1243'), findsOneWidget);
      expect(find.text('Changed by the partner (read as WXY 1234)'), findsOneWidget);
      expect(find.text('Photo check: blurred.'), findsOneWidget);
      expect(find.bySemanticsLabel("Doesn't match"), findsOneWidget);
    });
  });
}
