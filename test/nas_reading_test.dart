// Document reading, part 4: what the office NAS read off a document, shown
// in the admin review with what matches the record.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/doc_fields_section.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/doc_kinds.dart';

void main() {
  test('readings in words', () {
    expect(nasReadingStatus({'status': 'done', 'confidence': 97.4, 'ms': 1190}), '97% sure, 1.2 s');
    expect(nasReadingStatus({'status': 'passed_on', 'confidence': 40}), 'passed on to the next reader (40% sure)');
    expect(nasReadingStatus({'status': 'failed'}), "couldn't read it");
    expect(nasValues({'result': {'plates': ['WXY 1234'], 'numbers': ['CN-26-1', ' '], 'qr': ['https://q']}}),
        ['WXY 1234', 'CN-26-1', 'https://q']);
    expect(nasValues({'result': null}), isEmpty);
    expect(nasKey('wxy 1234'), 'WXY1234');
    expect(nasKey('  '), isNull);
  });

  testWidgets('each side, with what matches the record', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.dark),
      home: const Scaffold(
        body: NasReadingSection(doc: {
          '_onFile': DocOnFile(plate: 'WXY 1234', chassis: 'PM2B200S00K123456'),
          '_nas': [
            {
              'side': 'front',
              'status': 'done',
              'confidence': 97,
              'ms': 1200,
              'reader_label': 'DS224+',
              'result': {
                'plates': ['WXY1234'],
                'numbers': ['PM2B200S00K123456', 'CN-26-0012345'],
              },
            },
            {'side': 'back', 'status': 'passed_on', 'confidence': 40, 'result': {'numbers': []}},
          ],
        }),
      ),
    ));
    expect(find.text('Read by DS224+'), findsOneWidget);
    expect(find.text('Front: 97% sure, 1.2 s'), findsOneWidget);
    expect(find.text('Back: passed on to the next reader (40% sure)'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2), reason: 'the plate and the chassis');
    expect(find.text('CN-26-0012345'), findsOneWidget);
  });

  testWidgets('nothing read by the NAS: nothing shown', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: NasReadingSection(doc: {}))));
    expect(find.byKey(const ValueKey('doc-nas')), findsNothing);
  });
}
