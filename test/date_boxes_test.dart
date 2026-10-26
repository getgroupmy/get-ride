import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/date_order.dart';
import 'package:get_ride/src/widgets/date_boxes.dart';

Finder _box(String part, {Finder? within}) {
  final f = find.byKey(ValueKey('date-box-$part'));
  return within == null ? f : find.descendant(of: within, matching: f);
}

String _text(WidgetTester tester, String part) =>
    tester.widget<TextField>(_box(part)).controller!.text;

bool _focused(WidgetTester tester, String part) =>
    tester.widget<TextField>(_box(part)).focusNode!.hasFocus;

/// Call sites that may still open the calendar on its own or keep a
/// one-box date, with why. The count is how many there are in that file.
const _allowed = <String, (int, String)>{
  'lib/src/admin/screens/commission_promotions_tabs.dart': (
    2,
    'a promotion start/end is a date and a time picked together, and the report range is a pair of report filters',
  ),
  'lib/src/admin/screens/security/session_history_screen.dart': (
    2,
    'the session list and location trail ranges are report filters',
  ),
  'lib/src/admin/screens/geo/regions_screen.dart': (
    1,
    "the region's date format setting (its hint is a pattern like DD/MM/YYYY, not a date)",
  ),
};

/// What a one-box date field or a bare calendar looks like in the code.
final _rawDate = [
  RegExp(r'\bshowDatePicker\s*\('),
  RegExp(r'\bshowDateRangePicker\s*\('),
  RegExp(r'\bInputDatePickerFormField\b'),
  RegExp(r'\bCalendarDatePicker\b'),
  RegExp(r'''\b(hint|hintText|label|labelText|helperText)\s*:\s*(const\s+)?(Text\()?['"][^'"]*(YYYY|yyyy|DD/MM|MM/DD)'''),
  RegExp(r'\bTextInputType\.datetime\b'),
  RegExp(r'DateTime\.tryParse\(\s*\w+\.text\b'),
];

void main() {
  group('date order', () {
    test('by country', () {
      for (final c in ['CN', 'JP', 'KR', 'TW', 'HU', 'LT', 'MN', 'IR', 'jp']) {
        expect(dateOrderFor(c), DateOrder.ymd, reason: c);
      }
      for (final c in ['US', 'PH', 'FM', 'MH', 'PW']) {
        expect(dateOrderFor(c), DateOrder.mdy, reason: c);
      }
      for (final c in ['MY', 'SG', 'ID', 'TH', 'GB', 'AU', 'IN', 'BN', 'DE', '', null]) {
        expect(dateOrderFor(c), DateOrder.dmy, reason: '$c');
      }
      expect(dateOrderLabel(DateOrder.mdy), 'MM / DD / YYYY');
      expect(dateOrderLabel(DateOrder.dmy), 'DD / MM / YYYY');
      expect(dateOrderLabel(DateOrder.ymd), 'YYYY / MM / DD');
    });

    test('the country: profile first, then the phone, then Malaysia', () {
      expect(countryCodeFor('United States'), 'US');
      expect(countryCodeFor('Japan'), 'JP');
      expect(countryCodeFor('Taiwan'), 'TW');
      expect(countryCodeFor('malaysian'), 'MY');
      expect(countryCodeFor('ph'), 'PH');
      expect(countryCodeFor('Narnia'), isNull);
      expect(dateCountryFor(profileCountry: 'Philippines', deviceCountry: 'GB'), 'PH');
      expect(dateCountryFor(profileCountry: null, deviceCountry: 'US'), 'US');
      expect(dateCountryFor(profileCountry: ' ', deviceCountry: null), 'MY');
      setProfileDateCountry('Japan');
      expect(userDateOrder(), DateOrder.ymd);
      setProfileDateCountry(null);
      expect(userDateOrder(), DateOrder.dmy, reason: 'tests run as a Malaysian phone');
    });

    test('showing a date', () {
      final d = DateTime(2027, 5, 12);
      expect(formatDateForUser(d, order: DateOrder.dmy), '12/05/2027');
      expect(formatDateForUser(d, order: DateOrder.mdy), '05/12/2027');
      expect(formatDateForUser(d, order: DateOrder.ymd), '2027/05/12');
      expect(formatDateForUser(null), '—');
      expect(formatStoredDateForUser('2027-05-12T00:00:00Z', order: DateOrder.mdy), '05/12/2027');
      expect(formatStoredDateForUser('soon'), 'soon');
      expect(formatStoredDateForUser(null), '—');
      expect(formatWeekdayDayMonthForUser(DateTime(2026, 10, 16), order: DateOrder.dmy), 'Fri 16 Oct');
      expect(formatWeekdayDayMonthForUser(DateTime(2026, 10, 16), order: DateOrder.mdy), 'Fri Oct 16');
      expect(isoDate(DateTime(2027, 1, 3)), '2027-01-03');
    });

    test('pasted text', () {
      expect(splitDateText('12/05/2027', DateOrder.dmy),
          {DatePart.day: '12', DatePart.month: '05', DatePart.year: '2027'});
      expect(splitDateText('12/05/2027', DateOrder.mdy),
          {DatePart.month: '12', DatePart.day: '05', DatePart.year: '2027'});
      expect(splitDateText('2027-05-12', DateOrder.mdy),
          {DatePart.year: '2027', DatePart.month: '05', DatePart.day: '12'});
      expect(splitDateText('2027-5-2T10:00:00Z', DateOrder.dmy),
          {DatePart.year: '2027', DatePart.month: '05', DatePart.day: '02'});
      expect(splitDateText('1.5.2027', DateOrder.dmy),
          {DatePart.day: '01', DatePart.month: '05', DatePart.year: '2027'});
      expect(splitDateText('12052027', DateOrder.dmy),
          {DatePart.day: '12', DatePart.month: '05', DatePart.year: '2027'});
      expect(splitDateText('20270512', DateOrder.ymd),
          {DatePart.year: '2027', DatePart.month: '05', DatePart.day: '12'});
      expect(splitDateText('12/05', DateOrder.dmy), isNull);
      expect(splitDateText('soon', DateOrder.dmy), isNull);
      expect(parseIsoDate('2027-02-31'), isNull);
      expect(parseIsoDate('2028-02-29'), DateTime(2028, 2, 29));
    });

    test('checking the boxes', () {
      DateBoxesCheck c(String d, String m, String y, {DateTime? first, DateTime? last, bool req = false}) =>
          checkDateBoxes(
              day: d, month: m, year: y, firstDate: first, lastDate: last, required: req,
              order: DateOrder.dmy, now: DateTime(2026, 10, 19, 15));
      expect(c('12', '05', '2027'), (date: DateTime(2027, 5, 12), error: null));
      expect(c('', '', ''), (date: null, error: null));
      expect(c('', '', '', req: true).error, 'Enter the date');
      expect(c('12', '', '').error, 'Enter the month and year');
      expect(c('', '', '2027').error, 'Enter the day and month');
      expect(c('12', '05', '27').error, 'Enter the year as 4 digits, e.g. 2027');
      expect(c('12', '13', '2027').error, 'The month must be 01 to 12');
      expect(c('00', '05', '2027').error, 'The day must be 01 to 31');
      expect(c('31', '02', '2027').error, '31 February 2027 is not a real date');
      expect(c('29', '02', '2027').error, '29 February 2027 is not a real date (2027 is not a leap year)');
      expect(c('29', '02', '2028').date, DateTime(2028, 2, 29));
      expect(c('31', '04', '2027').error, '31 April 2027 is not a real date');
      final today = DateTime(2026, 10, 19);
      expect(c('18', '10', '2026', first: today).error, "The date can't be in the past");
      expect(c('19', '10', '2026', first: today).date, today, reason: 'today itself is fine');
      expect(c('20', '10', '2026', last: today).error, "The date can't be in the future");
      expect(c('01', '01', '1899', first: DateTime(1900)).error, "The date can't be before 01/01/1900");
      expect(c('01', '01', '2031', last: DateTime(2030, 12, 31)).error, "The date can't be after 31/12/2030");
    });
  });

  test('no one-box dates or bare calendars outside the date boxes', () {
    final found = <String, List<String>>{};
    for (final f in Directory('lib/src').listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path.endsWith('widgets/date_boxes.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i].trimLeft();
        if (l.startsWith('//')) continue;
        if (_rawDate.any((r) => r.hasMatch(l))) (found[path] ??= []).add('$path:${i + 1}: $l');
      }
    }
    final offenders = <String>[];
    for (final e in found.entries) {
      final allowed = _allowed[e.key];
      if (allowed == null || allowed.$1 != e.value.length) offenders.addAll(e.value);
    }
    for (final e in _allowed.entries) {
      if (!found.containsKey(e.key)) offenders.add('${e.key}: on the allow-list but has none; take it off');
    }
    expect(offenders, isEmpty,
        reason: 'type dates in DateBoxesField (lib/src/widgets/date_boxes.dart), its calendar button is the '
            'shortcut; or add the call site to _allowed in test/date_boxes_test.dart with the reason');
  });

  for (final b in Brightness.values) {
    group('date boxes (${b.name})', () {
      Future<List<DateTime?>> pump(
        WidgetTester tester, {
        DateOrder? order,
        TextEditingController? controller,
        DateTime? first,
        DateTime? last,
        double width = 400,
      }) async {
        final changes = <DateTime?>[];
        await tester.pumpWidget(MaterialApp(
          theme: appTheme(b),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: DateBoxesField(
                  key: const ValueKey('expiry'),
                  label: 'Expiry date',
                  order: order,
                  controller: controller,
                  firstDate: first,
                  lastDate: last,
                  onChanged: changes.add,
                ),
              ),
            ),
          ),
        ));
        return changes;
      }

      Future<void> type(WidgetTester tester, String part, String text) async {
        await tester.enterText(_box(part), text);
        await tester.pump();
      }

      testWidgets('typing moves on when a box is full; backspace in an empty box goes back', (tester) async {
        final iso = TextEditingController();
        final changes = await pump(tester, controller: iso);
        await tester.tap(_box('day'));
        await tester.pump();
        await type(tester, 'day', '12');
        expect(_focused(tester, 'month'), isTrue);
        await type(tester, 'month', '05');
        expect(_focused(tester, 'year'), isTrue);
        await type(tester, 'year', '2027');
        expect(changes.last, DateTime(2027, 5, 12));
        expect(iso.text, '2027-05-12', reason: 'stored as before');
        expect(find.byKey(const ValueKey('date-box-error')), findsNothing);

        await type(tester, 'year', '');
        expect(_focused(tester, 'year'), isTrue, reason: 'emptying a box stays in it, for the retyped digits');
        expect(changes.last, isNull);
        expect(iso.text, '12/05/', reason: 'a part date never looks stored');
        await type(tester, 'year', '1990');
        expect((_text(tester, 'day'), _text(tester, 'month'), _text(tester, 'year')), ('12', '05', '1990'),
            reason: 'select-all, delete and retype lands in the same box');
        await type(tester, 'year', '');
        await tester.tap(_box('year'));
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.pump();
        expect(_focused(tester, 'month'), isTrue, reason: 'backspace in the empty year goes to the month');

        await type(tester, 'month', '');
        await type(tester, 'month', '7');
        expect(_text(tester, 'month'), '07', reason: 'a 7 can only be July');
        expect(_focused(tester, 'year'), isTrue);
      });

      testWidgets('typed on past a full box: the digits go on to the next box, none lost', (tester) async {
        final changes = await pump(tester);
        await tester.tap(_box('day'));
        await tester.pump();
        await type(tester, 'day', '12');
        await type(tester, 'month', '05');
        // The next key reached the month before the focus moved on.
        await tester.enterText(_box('month'), '051');
        await tester.pump();
        await tester.pump();
        expect(_text(tester, 'month'), '05');
        expect(_text(tester, 'year'), '1');
        expect(_focused(tester, 'year'), isTrue);
        await tester.enterText(_box('year'), '1990');
        await tester.pump();
        expect(changes.last, DateTime(1990, 5, 12));
      });

      testWidgets('a pasted date fills all three boxes', (tester) async {
        final iso = TextEditingController();
        await pump(tester, controller: iso);
        await type(tester, 'day', '12/05/2027');
        expect([_text(tester, 'day'), _text(tester, 'month'), _text(tester, 'year')], ['12', '05', '2027']);
        expect(iso.text, '2027-05-12');
        await type(tester, 'year', '2028-02-29');
        expect([_text(tester, 'day'), _text(tester, 'month'), _text(tester, 'year')], ['29', '02', '2028']);
        expect(iso.text, '2028-02-29');
        iso.text = '2030-01-15';
        await tester.pump();
        expect([_text(tester, 'day'), _text(tester, 'month'), _text(tester, 'year')], ['15', '01', '2030'],
            reason: 'setting the stored date fills the boxes');
      });

      testWidgets('31 February is not a date', (tester) async {
        final iso = TextEditingController();
        await pump(tester, controller: iso);
        await type(tester, 'day', '31');
        await type(tester, 'month', '02');
        await type(tester, 'year', '2027');
        expect(find.text('31 February 2027 is not a real date'), findsOneWidget);
        expect(iso.text, '31/02/2027');
        final error = tester.widget<Text>(find.byKey(const ValueKey('date-box-error')));
        expect(error.style?.color, appTheme(b).colorScheme.error);
      });

      testWidgets('first and last dates', (tester) async {
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final y = today.subtract(const Duration(days: 1));
        await pump(tester, first: today);
        await type(tester, 'day', isoDateDmy(y));
        expect(find.text("The date can't be in the past"), findsOneWidget);
        await type(tester, 'day', isoDateDmy(today));
        expect(find.byKey(const ValueKey('date-box-error')), findsNothing);

        await pump(tester, last: DateTime(2030, 12, 31));
        await type(tester, 'day', '01/01/2031');
        expect(find.text("The date can't be after 31/12/2030"), findsOneWidget);
      });

      for (final (country, order, labels) in [
        ('MY', 'day month year', ['DD', 'MM', 'YYYY']),
        ('US', 'month day year', ['MM', 'DD', 'YYYY']),
        ('JP', 'year month day', ['YYYY', 'MM', 'DD']),
      ]) {
        testWidgets('a $country user types $order', (tester) async {
          setProfileDateCountry(country);
          final iso = TextEditingController(text: '2027-05-12');
          await pump(tester, controller: iso);
          double x(String p) => tester.getCenter(_box(p)).dx;
          final byX = ['day', 'month', 'year']..sort((a, b) => x(a).compareTo(x(b)));
          expect(byX.join(' '), order);
          final shown = [for (final l in labels) tester.getCenter(find.text(l)).dx];
          expect(shown, orderedEquals([...shown]..sort()), reason: 'the labels follow the boxes');
          await type(tester, order.split(' ').first, '');
          expect(iso.text, isNot('2027-05-12'));
          await type(tester, order.split(' ').first, country == 'JP' ? '2027' : (country == 'US' ? '05' : '12'));
          expect(iso.text, '2027-05-12');
          expect(formatDateForUser(DateTime(2027, 5, 12)),
              {'MY': '12/05/2027', 'US': '05/12/2027', 'JP': '2027/05/12'}[country]);
        });
      }

      testWidgets('each box is read out with the field name', (tester) async {
        final semantics = tester.ensureSemantics();
        await pump(tester);
        expect(find.bySemanticsLabel(RegExp('Expiry date, day')), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('Expiry date, month')), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('Expiry date, year')), findsOneWidget);
        semantics.dispose();
      });

      testWidgets('the calendar button fills the boxes', (tester) async {
        final iso = TextEditingController(text: '2027-05-12');
        await pump(tester, controller: iso);
        await tester.tap(find.byKey(const ValueKey('date-box-calendar')));
        await tester.pumpAndSettle();
        expect(find.byType(DatePickerDialog), findsOneWidget);
        await tester.tap(find.text('20'));
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(iso.text, '2027-05-20');
        expect(_text(tester, 'day'), '20');
      });

      testWidgets('fits a 360 px phone at 1.3x text', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 640);
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        // An AlertDialog's content on a 360 px phone is about 232 px wide.
        await pump(tester, controller: TextEditingController(text: '2027-12-28'), width: 232);
        await type(tester, 'day', '31/02/2027');
        expect(tester.takeException(), isNull);
        for (final (part, digits) in [('day', '28'), ('month', '12'), ('year', '2027')]) {
          final editable = find.descendant(of: _box(part), matching: find.byType(EditableText));
          final tp = TextPainter(
            text: TextSpan(text: digits, style: tester.widget<EditableText>(editable).style),
            textDirection: TextDirection.ltr,
            textScaler: const TextScaler.linear(1.3),
          )..layout();
          expect(tester.getSize(editable).width, greaterThanOrEqualTo(tp.width), reason: '$digits shows whole');
        }
        expect(tester.getRect(find.byKey(const ValueKey('date-box-calendar'))).right, lessThanOrEqualTo(360));
      });
    });
  }
}

String isoDateDmy(DateTime d) => formatDateForUser(d, order: DateOrder.dmy);
