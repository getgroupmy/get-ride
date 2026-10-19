// The partner's document upload (Driving licence): its expiry date is typed
// in day, month and year boxes in the user's country's order, and is still
// saved as yyyy-mm-dd.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/people/people_data.dart';
import 'package:get_ride/src/admin/screens/people/people_logic.dart';
import 'package:get_ride/src/admin/screens/people/people_widgets.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/date_order.dart';
import 'package:get_ride/src/core/document_ai.dart';
import 'package:get_ride/src/data/document_ai_repository.dart';
import 'package:get_ride/src/widgets/page_style_host.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

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

const _licence = RequiredDoc(
  id: 'licence',
  name: 'Driving License',
  description: '',
  compulsory: true,
  scope: 'global',
  labels: [],
  flags: DocFlags(requireExpiryDate: true),
);

Finder _box(String part) => find.descendant(
    of: find.byKey(const ValueKey('doc-upload-expiry')), matching: find.byKey(ValueKey('date-box-$part')));

void main() {
  for (final b in Brightness.values) {
    group('Driving License expiry (${b.name})', () {
      Future<_FakePeople> open(WidgetTester tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 760);
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final people = _FakePeople();
        await tester.pumpWidget(ProviderScope(
          overrides: [
            peopleRepositoryProvider.overrideWithValue(people),
            documentAiRepositoryProvider.overrideWithValue(_FakeAi()),
            docPhotoPickerProvider.overrideWithValue((_) async => (bytes: _png, name: 'front.png')),
          ],
          child: MaterialApp(
            theme: appTheme(b),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAppDialog<bool>(
                    id: 'admin-people.upload-document',
                    context: context,
                    builder: (_) => const DocUploadDialog(partnerId: 'p1', doc: _licence),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        return people;
      }

      Future<void> addPhoto(WidgetTester tester) async {
        await tester.tap(find.text('Tap to upload'));
        await tester.pumpAndSettle();
      }

      Future<void> save(WidgetTester tester) async {
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
      }

      testWidgets('typed in three boxes at 1.3x on a 360 px phone, saved as yyyy-mm-dd', (tester) async {
        final people = await open(tester);
        expect(tester.takeException(), isNull, reason: 'nothing overflows');
        expect(find.byKey(const ValueKey('doc-upload-expiry')), findsOneWidget);
        expect(find.text('DD'), findsOneWidget);
        expect(find.text('MM'), findsOneWidget);
        expect(find.text('YYYY'), findsOneWidget);
        final dx = [for (final p in ['day', 'month', 'year']) tester.getCenter(_box(p)).dx];
        expect(dx, orderedEquals([...dx]..sort()), reason: 'day, month, year for a Malaysian user');
        await addPhoto(tester);

        final next = DateTime.now().year + 2;
        await tester.enterText(_box('day'), '31');
        await tester.pump();
        await tester.enterText(_box('month'), '02');
        await tester.pump();
        await tester.enterText(_box('year'), '$next');
        await tester.pump();
        expect(find.text('31 February $next is not a real date'), findsOneWidget);
        await save(tester);
        expect(people.saved, isEmpty);

        await tester.enterText(_box('day'), '28');
        await tester.pump();
        expect(find.byKey(const ValueKey('date-box-error')), findsNothing);
        expect(tester.takeException(), isNull);
        await save(tester);
        expect(people.saved.single['expiry_date'], '$next-02-28');
      });

      testWidgets('an expired licence is refused under the boxes', (tester) async {
        final people = await open(tester);
        await addPhoto(tester);
        final y = DateTime.now().subtract(const Duration(days: 1));
        await tester.enterText(_box('day'), formatDateForUser(y, order: DateOrder.dmy));
        await tester.pump();
        expect(find.text('This document has expired. Upload the renewed one.'), findsOneWidget);
        await save(tester);
        expect(people.saved, isEmpty);
      });

      testWidgets('a US user types month first', (tester) async {
        setProfileDateCountry('United States');
        final people = await open(tester);
        await addPhoto(tester);
        final dx = [for (final p in ['month', 'day', 'year']) tester.getCenter(_box(p)).dx];
        expect(dx, orderedEquals([...dx]..sort()));
        final next = DateTime.now().year + 1;
        await tester.enterText(_box('month'), '12/05/$next');
        await tester.pump();
        await save(tester);
        expect(people.saved.single['expiry_date'], '$next-12-05', reason: '12/05 is 5 December in the US');
      });
    });
  }
}
