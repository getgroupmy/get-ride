import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/widgets/search_select.dart';

const _states = [
  'Johor', 'Kedah', 'Kelantan', 'Kuala Lumpur', 'Labuan', 'Malacca', 'Negeri Sembilan', 'Pahang', 'Penang',
  'Perak', 'Perlis', 'Putrajaya', 'Sabah', 'Sarawak', 'Selangor', 'Terengganu',
];

void main() {
  test('matching: every word typed, anywhere, any case', () {
    expect(searchSelectMatches('Negeri Sembilan', 'sem'), isTrue);
    expect(searchSelectMatches('Negeri Sembilan', 'neg sem'), isTrue);
    expect(searchSelectMatches('Negeri Sembilan', 'neg sel'), isFalse);
    expect(searchSelectMatches('Kuala Lumpur', ''), isTrue);
    expect(
      searchSelectLabel(const DropdownMenuItem(value: 1, child: Row(children: [Icon(Icons.star), Text('Gold')]))),
      'Gold',
      reason: 'the words inside a row of an icon and its name',
    );
    expect(searchSelectLabel(const DropdownMenuItem(value: 7, child: Icon(Icons.star))), '7');
  });

  test('no plain dropdowns left: every one can be searched once its list is long', () {
    final offenders = <String>[];
    for (final f in Directory('lib/src').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.endsWith('search_select.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i].trimLeft();
        if (l.startsWith('//')) continue;
        if (RegExp(r'\bDropdownButtonFormField<').hasMatch(l)) offenders.add('${f.path}:${i + 1}');
      }
    }
    expect(offenders, isEmpty, reason: 'use SearchableDropdownFormField (lib/src/widgets/search_select.dart)');
  });

  for (final b in Brightness.values) {
    group('searchable dropdown (${b.name})', () {
      Future<List<String?>> pump(WidgetTester tester, List<String> items, {String? initial}) async {
        final picked = <String?>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(b),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: SearchableDropdownFormField<String>(
                  key: const ValueKey('state'),
                  initialValue: initial,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'State'),
                  items: [for (final s in items) DropdownMenuItem(value: s, child: Text(s))],
                  onChanged: picked.add,
                ),
              ),
            ),
          ),
        );
        return picked;
      }

      testWidgets('a long list opens with a search box; typing narrows it; a tap picks', (tester) async {
        final picked = await pump(tester, _states, initial: 'Johor');
        expect(find.text('Johor'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('state')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('search-select-field')), findsOneWidget);
        expect(find.text('16 choices'), findsOneWidget);
        expect(find.text('State'), findsWidgets, reason: 'the field is named at the top');

        await tester.enterText(find.byKey(const ValueKey('search-select-field')), 'sel');
        await tester.pumpAndSettle();
        expect(find.text('1 of 16'), findsOneWidget);
        expect(find.text('Kedah'), findsNothing);
        await tester.tap(find.text('Selangor'));
        await tester.pumpAndSettle();
        expect(picked, ['Selangor']);
        expect(find.text('Selangor'), findsOneWidget, reason: 'the field shows the pick');
        expect(tester.takeException(), isNull);
      });

      testWidgets('Enter takes the only match; nothing matching says so; Cancel keeps the value', (tester) async {
        final picked = await pump(tester, _states);
        await tester.tap(find.byKey(const ValueKey('state')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('search-select-field')), 'zzz');
        await tester.pumpAndSettle();
        expect(find.text('Nothing matches "zzz".'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(picked, isEmpty);

        await tester.tap(find.byKey(const ValueKey('state')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('search-select-field')), 'putra');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(picked, ['Putrajaya']);
      });

      testWidgets('a short list stays a plain dropdown', (tester) async {
        await pump(tester, const ['Day', 'Night']);
        expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('state')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('search-select-field')), findsNothing);
      });

      testWidgets('search picker and list filter', (tester) async {
        String? chosen;
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(b),
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    TextButton(
                      onPressed: () async => chosen = await showSearchPicker<String>(
                        context,
                        title: 'Choose a state',
                        choices: [for (final s in _states) (value: s, label: s, subtitle: 'Malaysia', leading: null)],
                      ),
                      child: const Text('open'),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        child: ListSearchFilter(
                          count: _states.length,
                          builder: (context, q) => Wrap(
                            children: [
                              for (final s in _states)
                                if (searchSelectMatches(s, q)) Chip(key: ValueKey('chip-$s'), label: Text(s)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.enterText(find.byKey(const ValueKey('list-search')), 'pe');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('chip-Penang')), findsOneWidget);
        expect(find.byKey(const ValueKey('chip-Perak')), findsOneWidget);
        expect(find.byKey(const ValueKey('chip-Johor')), findsNothing);

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('Choose a state'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('search-select-field')), 'terengganu');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Terengganu'));
        await tester.pumpAndSettle();
        expect(chosen, 'Terengganu');
        expect(tester.takeException(), isNull);
      });
    });
  }
}
