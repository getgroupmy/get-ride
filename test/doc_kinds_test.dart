// Document reading, part 2: what is printed on each kind of document, what
// a Required Document is read as, what the AI check is asked for, and how
// the fields read are checked against what is on file.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/catalogue/catalogue_logic.dart';
import 'package:get_ride/src/admin/screens/doc_fields_section.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart' show DocFlags;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/doc_kinds.dart';
import 'package:get_ride/src/core/document_ai.dart';

final _today = DateTime(2026, 10, 25);

const _file = DocOnFile(
  name: 'AINA BINTI RAHMAN',
  ic: '900101-14-5678',
  plate: 'WXY 1234',
  chassis: 'PM2B200S00K123456',
  engine: '1KR-A123456',
  make: 'PERODUA',
  model: 'BEZZA 1.0',
  year: '2019',
);

FieldVerdict _verdict(List<DocFieldRow> rows, String key) => rows.firstWhere((r) => r.field.key == key).verdict;

void main() {
  group('the kinds', () {
    test('every kind: unique fields, within the AI check\'s limit, each check complete', () {
      final ts = File('supabase/functions/_shared/doc_ai.ts').readAsStringSync();
      final max = int.parse(RegExp(r'MAX_PERMIT_FIELDS = (\d+)').firstMatch(ts)!.group(1)!);
      expect(maxDocKindFields, max, reason: 'the same limit as the AI check');
      expect({for (final k in docKinds) k.id}.length, docKinds.length);
      expect(docKinds.length, 13);
      for (final k in docKinds) {
        expect(k.fields.length, lessThanOrEqualTo(maxDocKindFields), reason: k.id);
        expect({for (final f in k.fields) f.key}.length, k.fields.length, reason: k.id);
        for (final f in k.fields) {
          expect(RegExp(r'^[a-z0-9_]{1,40}$', caseSensitive: false).hasMatch(f.key), isTrue, reason: f.key);
          if (f.check == DocCheck.expected) expect(f.expect, isNotNull, reason: '${k.id}.${f.key}');
        }
      }
    });

    test('sensitive things are never asked for', () {
      final all = [for (final k in docKinds) for (final f in k.fields) f.label.toLowerCase()].join(' ');
      expect(all, isNot(contains('religion')));
      expect(all, isNot(contains('agama')));
      expect(all, isNot(contains('transaction')));
      expect(docKindById('mykad')!.notKept, ['Religion']);
    });

    test('a Required Document is read as the admin says, else guessed from its name', () {
      String? g(String name) => guessDocKind(name)?.id;
      expect(g('Insurance Cover Note'), 'cover');
      expect(g('E-hailing Insurance (The Schedule)'), 'cover');
      expect(g('Lesen Memandu'), 'licence');
      expect(g('PSV Licence'), 'licence');
      expect(g('MyKad (front and back)'), 'mykad');
      expect(g('Geran Kenderaan'), 'grant');
      expect(g('Puspakom Inspection Report'), 'puspakom');
      expect(g('Road Tax'), 'roadtax');
      expect(g('E-hailing Vehicle Permit (EVP)'), 'evp');
      expect(g('Kad Pemandu Teksi'), 'taxi');
      expect(g('Owner Authorisation Letter'), 'authorisation');
      expect(g('Bank statement'), 'bank');
      expect(g('Profile photo'), isNull);
      expect(docKindFor({'name': 'Profile photo', 'readAs': 'grant'})?.id, 'grant');
      expect(docKindFor({'name': 'Insurance', 'readAs': 'none'}), isNull, reason: 'the admin turned it off');
      expect(docKindFor({'name': 'Insurance', 'readAs': 'gone'})?.id, 'cover', reason: 'unknown: guessed');
    });

    test('the admin form keeps Read as; the upload carries it', () {
      final form = RequiredDocForm.fromValues({'name': 'Insurance cover note'});
      expect(form.effectiveReadAs, 'cover');
      form.readAs = 'none';
      expect(form.effectiveReadAs, 'none');
      final built = buildRequiredDocValues(entries: const [], form: form..readAs = 'grant');
      expect(built.values['readAs'], 'grant');
      expect(DocFlags.fromValues({'name': 'Lesen', 'readAs': 'licence'}).readAs?.id, 'licence');
      expect(DocFlags.fromValues({'name': 'Selfie'}).readAs, isNull);
    });

    test('the AI check is asked every field, a permit type\'s own first, at most 20', () {
      final ask = docKindAsk(docKindById('cover')!);
      expect(ask.length, 20);
      expect(ask.first.key, 'insurer');
      expect(ask.firstWhere((f) => f.key == 'periodTo').isDate, isTrue);
      final merged = docKindAsk(docKindById('evp')!, first: const [
        (key: 'permitNumber', label: 'Permit no.', labelLocal: '', isDate: false),
        (key: 'route', label: 'Route', labelLocal: 'Laluan', isDate: false),
      ]);
      expect(merged.take(2).map((f) => f.label), ['Permit no.', 'Route']);
      expect(merged.where((f) => f.key == 'permitNumber').length, 1, reason: 'no duplicate keys');
      final body = docAiRequestBody(frontDataUrl: 'data:x', docName: 'Cover note', permitFields: ask);
      final sent = (body['context'] as Map)['permitFields'] as List;
      expect(sent.length, 20);
      expect(sent.firstWhere((f) => f['key'] == 'chassis'), {'key': 'chassis', 'label': 'Chassis number', 'labelLocal': 'No. casis', 'kind': 'text'});
    });
  });

  group('checking what was read', () {
    test('a cover note: plate, chassis, engine, e-hailing cover, period', () {
      final rows = checkDocFields(docKindById('cover')!, {
        'insuredName': 'AINA BT RAHMAN',
        'plate': 'wxy1234',
        'chassis': 'PM2B200S00K123456',
        'engine': '1KR-A123457',
        'makeModel': 'PERODUA BEZZA 1.0 (A)',
        'year': '2019',
        'periodTo': '2026-11-06',
        'eHailing': 'Endorsement: Private Hire Car (E-hailing), annual',
        'coverType': 'COMPREHENSIVE',
        'ncd': null,
      }, _file, today: _today);
      expect(_verdict(rows, 'insuredName'), FieldVerdict.match, reason: 'BT = BINTI');
      expect(_verdict(rows, 'plate'), FieldVerdict.match);
      expect(_verdict(rows, 'chassis'), FieldVerdict.match);
      expect(_verdict(rows, 'engine'), FieldVerdict.mismatch);
      expect(_verdict(rows, 'makeModel'), FieldVerdict.match);
      expect(_verdict(rows, 'year'), FieldVerdict.match);
      expect(_verdict(rows, 'periodTo'), FieldVerdict.check);
      expect(rows.firstWhere((r) => r.field.key == 'periodTo').note, 'Ends in 12 days.');
      expect(_verdict(rows, 'eHailing'), FieldVerdict.match);
      expect(_verdict(rows, 'coverType'), FieldVerdict.none, reason: 'read, nothing to compare');
      expect(_verdict(rows, 'ncd'), FieldVerdict.none);
      expect(docFieldsSummary(rows), '9 of 20 fields read: 6 match, 1 to check, 1 wrong.');
    });

    test('a grant: another owner needs a letter; a car over 15 years is past the limit', () {
      final rows = checkDocFields(docKindById('grant')!, {
        'ownerName': 'RAHMAN BIN YUSOF',
        'year': '2009',
        'registered': '12/06/2009',
      }, const DocOnFile(name: 'AINA BINTI RAHMAN', year: '2009'), today: _today);
      expect(_verdict(rows, 'ownerName'), FieldVerdict.check);
      expect(rows.firstWhere((r) => r.field.key == 'ownerName').note, contains('owner authorisation letter'));
      expect(_verdict(rows, 'year'), FieldVerdict.mismatch);
      expect(rows.firstWhere((r) => r.field.key == 'year').note, contains('15 years'));
    });

    test('dates: expired, a year-old inspection, a failed one', () {
      final p = checkDocFields(docKindById('puspakom')!, {
        'result': 'GAGAL',
        'inspected': '2025-09-01',
        'validTo': '2026-10-01',
        'inspectionType': 'Pemeriksaan E-Hailing',
      }, _file, today: _today);
      expect(_verdict(p, 'result'), FieldVerdict.mismatch);
      expect(_verdict(p, 'inspected'), FieldVerdict.mismatch);
      expect(_verdict(p, 'validTo'), FieldVerdict.mismatch);
      expect(_verdict(p, 'inspectionType'), FieldVerdict.match);
      final l = checkDocFields(docKindById('licence')!, {'licenceType': 'P', 'psvClass': 'PSV (E)'}, _file, today: _today);
      expect(_verdict(l, 'licenceType'), FieldVerdict.mismatch, reason: 'a probation licence');
      expect(_verdict(l, 'psvClass'), FieldVerdict.match);
    });

    test('nothing on file: read, but not judged', () {
      final rows = checkDocFields(docKindById('mykad')!, {'fullName': 'AINA BINTI RAHMAN', 'icNumber': '900101145678'},
          const DocOnFile(), today: _today);
      expect(_verdict(rows, 'fullName'), FieldVerdict.none);
      expect(_verdict(rows, 'icNumber'), FieldVerdict.none);
    });
  });

  group('admin review', () {
    testWidgets('fields read beside what is on file', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final doc = {
        'doc_id': 'rd1',
        'doc_name': 'Insurance',
        '_onFile': _file,
        'ai_verification': {
          'extracted': {
            'permitFields': {'plate': 'WXY 1234', 'engine': '1KR-A000000', 'periodTo': '2026-11-06'},
          },
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
      expect(find.text('Read as Insurance cover note / policy'), findsOneWidget);
      expect(find.text('3 of 20 fields read: 1 match, 1 to check, 1 wrong.'), findsOneWidget);
      expect(find.text('1KR-A000000'), findsOneWidget);
      expect(find.text('1KR-A123456'), findsOneWidget, reason: 'the engine number on file');
      expect(find.bySemanticsLabel("Doesn't match"), findsOneWidget);
      expect(find.text('Ends in 12 days.'), findsOneWidget);
    });

    testWidgets('a document read as nothing shows nothing', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [requiredDocKindsProvider.overrideWith((_) async => {'rd2': null})],
        child: const MaterialApp(home: Scaffold(body: DocFieldsSection(doc: {'doc_id': 'rd2', 'doc_name': 'Insurance'}))),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('doc-fields')), findsNothing);
    });
  });
}
