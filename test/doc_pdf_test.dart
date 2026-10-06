import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/doc_pdf.dart';
import 'package:get_ride/src/admin/screens/people/people_data.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/admin/screens/people/people_widgets.dart';
import 'package:get_ride/src/core/document_ai.dart';
import 'package:get_ride/src/data/document_ai_repository.dart';

/// A real 1×1 PNG, so the preview decodes.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

class _FakePdf implements DocPdfTools {
  _FakePdf({this.renders = true});
  final bool renders;

  @override
  Future<PickedPeopleFile?> pick() async => (bytes: Uint8List(4096), name: 'Licence.PDF');

  @override
  Future<Uint8List?> firstPagePng(Uint8List pdf) async => renders ? _png : null;
}

class _FakePeople implements PeopleRepository {
  final uploads = <String>[];
  final saved = <Map<String, dynamic>>[];

  @override
  Future<String> upload(String bucket, String path, PickedPeopleFile file) async {
    uploads.add('$bucket/$path:${file.bytes.length}');
    return 'https://x.test/$path';
  }

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

RequiredDoc _doc({bool pdf = true, bool frontBack = true}) => RequiredDoc(
  id: 'licence',
  name: 'Driving licence',
  description: '',
  compulsory: true,
  scope: 'global',
  labels: const [],
  flags: DocFlags(allowPdfUpload: pdf, requireFrontBack: frontBack),
);

void main() {
  test('names and checks', () {
    expect(isPdfName('a.PDF'), isTrue);
    expect(isPdfName('a.png'), isFalse);
    expect(pdfPreviewName('Licence.PDF'), 'Licence.png');
    expect(pdfPreviewName('.pdf'), 'document.png');
    expect(docPdfProblem('a.png', 10), 'Choose a PDF file.');
    expect(docPdfProblem('a.pdf', 0), isNotNull);
    expect(docPdfProblem('a.pdf', docPdfMaxBytes + 1), 'Choose a PDF under 15 MB.');
    expect(docPdfProblem('a.pdf', 1024), isNull);
  });

  Future<_FakePeople> pump(WidgetTester tester, RequiredDoc doc, {_FakePdf? pdf}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1400);
    addTearDown(tester.view.reset);
    final people = _FakePeople();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          peopleRepositoryProvider.overrideWithValue(people),
          documentAiRepositoryProvider.overrideWithValue(_FakeAi()),
          docPdfToolsProvider.overrideWithValue(pdf ?? _FakePdf()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: DocUploadDialog(partnerId: 'p1', doc: doc),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return people;
  }

  testWidgets('a PDF uploads its first page as the only image, with no back asked for', (tester) async {
    final people = await pump(tester, _doc());
    expect(find.text('Back'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('doc-upload-pdf')));
    await tester.pumpAndSettle();
    expect(find.text('Back'), findsNothing, reason: 'a PDF is one file');

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(people.uploads, hasLength(1));
    expect(people.uploads.single, startsWith('provider-documents/'));
    expect(people.uploads.single, contains('.png:${_png.length}'), reason: 'the rendered page, never the 4 KB PDF');
    expect(people.saved.single['file_url_back'], isNull);
  });

  testWidgets('no PDF option unless the admin allows it', (tester) async {
    await pump(tester, _doc(pdf: false));
    expect(find.byKey(const ValueKey('doc-upload-pdf')), findsNothing);
  });

  testWidgets('a PDF that cannot be rendered is refused', (tester) async {
    final people = await pump(tester, _doc(), pdf: _FakePdf(renders: false));
    await tester.tap(find.byKey(const ValueKey('doc-upload-pdf')));
    await tester.pumpAndSettle();
    expect(find.textContaining("That PDF couldn't be opened"), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(people.uploads, isEmpty);
  });
}
