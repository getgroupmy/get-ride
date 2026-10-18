import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/commerce/partner_statements_screen.dart';
import 'package:get_ride/src/admin/screens/commerce/statement_layout_tab.dart';
import 'package:get_ride/src/core/partner_statement.dart';
import 'package:get_ride/src/core/statement_layout.dart';
import 'package:get_ride/src/data/partner_statement_repository.dart';
import 'package:get_ride/src/features/partner/statements_screen.dart' show statementPdfOpenerProvider;
import 'package:get_ride/src/app.dart' show appTheme;

class _FakeRepo implements PartnerStatementRepository {
  StatementLayout stored = const StatementLayout();
  final saved = <StatementLayout>[];
  final samples = <(StatementType, StatementLang, StatementLayout)>[];
  final uploads = <String>[];

  @override
  Future<StatementLayout> layout() async => stored;

  @override
  Future<StatementLayout> saveLayout(StatementLayout l) async {
    saved.add(l);
    return stored = StatementLayout.fromJson(l.toJson());
  }

  @override
  Future<String> uploadLogo(Uint8List bytes, String ext) async {
    uploads.add(ext);
    return 'statement-logo-1.$ext';
  }

  @override
  String logoUrl(String path) => 'https://example.test/$path';

  @override
  Future<({Uint8List bytes, String fileName})> sample(StatementLayout l, StatementType type, StatementLang lang) async {
    samples.add((type, lang, l));
    return (bytes: Uint8List.fromList([37, 80, 68, 70]), fileName: 'sample.pdf');
  }

  @override
  Future<List<({String name, int trips})>> surchargeNames() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('the catalog', () {
    test('every field, block and size matches the PDF function', () {
      final ts = File('supabase/functions/_shared/statement_layout.ts').readAsStringSync();
      final ids = RegExp(r'\{ id: "(\w+)", group: "(\w+)"').allMatches(ts).map((m) => '${m[1]}:${m[2]}').toList();
      expect(statementFields.map((f) => '${f.id}:${f.group.name}').toList(), ids);
      final sections = RegExp(r'export const SECTIONS = \[([^\]]+)\]').firstMatch(ts)![1]!;
      expect(statementSections.keys.toList(), RegExp(r'"(\w+)"').allMatches(sections).map((m) => m[1]).toList());
      final sizes = RegExp(r'export const FONT_SIZES = \{([^}]+)\}').firstMatch(ts)![1]!;
      expect(
        {for (final e in statementFontSizes.entries) e.key: e.value.size},
        {for (final m in RegExp(r'(\w+): (\d+)').allMatches(sizes)) m[1]: double.parse(m[2]!)},
      );
      final colors = RegExp(r'export const COLORS = \{([^}]+)\}').firstMatch(ts)![1]!;
      expect(
        {for (final e in statementColors.entries) e.key: colorHex(Color(e.value.argb))},
        {for (final m in RegExp(r'(\w+): "(#\w+)"').allMatches(colors)) m[1]: m[2]},
      );
    });

    test('a saved layout reads back the same; unknown and out-of-range values drop', () {
      final l = StatementLayout.fromJson({
        'fields': {
          'title': {'en': ' Monthly Pay Slip ', 'ms': 'Slip Gaji'},
          'ic': {'show': false},
          'bogus': {'show': false},
          'net': {'show': true},
        },
        'sections': ['activity', 'nope', 'earnings'],
        'fontFamily': 'comic',
        'fonts': {'title': 99, 'body': 9},
        'colors': {'brand': '#123456', 'ink': 'red', 'muted': '#6B7080'},
        'logo': {'path': '../x', 'position': 'right', 'width': 500, 'dx': -900},
        'companySide': 'right',
      });
      expect(l.fields.keys, unorderedEquals(['title', 'ic']));
      expect(l.label('title', 'en'), 'Monthly Pay Slip');
      expect(l.label('title', 'ms'), 'Slip Gaji');
      expect(l.label('net', 'ms'), 'Pendapatan bersih');
      expect(l.shows('ic'), isFalse);
      expect(l.sectionOrder.take(3), ['activity', 'earnings', 'deductions']);
      expect(l.sectionOrder, hasLength(statementSections.length));
      expect(l.fontFamily, 'helvetica');
      expect(l.fonts, {'title': 24.0});
      expect(l.colors.keys, ['brand']);
      expect(l.logo, const StatementLogo(position: 'right', width: 220, dx: -200));
      expect(StatementLayout.fromJson(l.toJson()), l);
      expect(StatementLayout.fromJson(null).isDefault, isTrue);
      expect(StatementLayout.fromJson(const StatementLayout().toJson()).isDefault, isTrue);
    });
  });

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';
    group('Admin → Partner statements → Layout ($mode)', () {
      Future<(_FakeRepo, List<String>)> pump(WidgetTester tester, {bool edit = true, Size size = const Size(600, 2600)}) async {
        final repo = _FakeRepo();
        final opened = <String>[];
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: '*', edit: edit)])),
              partnerStatementRepositoryProvider.overrideWithValue(repo),
              statementSettingsProvider.overrideWith(
                (_) async => const StatementSettings(companyName: 'PUNCAK NIAGA BERSAMA SDN. BHD.'),
              ),
              statementLayoutProvider.overrideWith((ref) => ref.watch(partnerStatementRepositoryProvider).layout()),
              statementPdfOpenerProvider.overrideWithValue((context, bytes, name, title) async => opened.add(name)),
              statementLogoPickerProvider.overrideWithValue(
                (context) async => (bytes: Uint8List(8), name: 'logo.png', ext: 'png', contentType: 'image/png'),
              ),
            ],
            child: MaterialApp(
              theme: appTheme(dark ? Brightness.dark : Brightness.light),
              home: const AdminPartnerStatementsScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('statements-tab-layout')));
        await tester.pumpAndSettle();
        return (repo, opened);
      }

      Finder inPreview(String text) =>
          find.descendant(of: find.byKey(const ValueKey('layout-preview')), matching: find.text(text));

      Future<void> open(WidgetTester tester, String key) async {
        await tester.ensureVisible(find.byKey(ValueKey(key)));
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
      }

      testWidgets('hides and renames fields, live in the preview, and saves', (tester) async {
        final (repo, _) = await pump(tester);
        expect(inPreview('Partner Earnings Statement'), findsOneWidget);
        expect(inPreview('IC no.'), findsOneWidget);
        expect(find.byKey(const ValueKey('layout-save')), findsNothing, reason: 'nothing changed yet');

        await open(tester, 'layout-group-partner');
        await tester.tap(find.byKey(const ValueKey('layout-show-ic')));
        await tester.pumpAndSettle();
        expect(inPreview('IC no.'), findsNothing);

        await open(tester, 'layout-group-header');
        await open(tester, 'layout-rename-title');
        await tester.enterText(find.byKey(const ValueKey('layout-rename-en')), 'Monthly Pay Slip');
        await tester.enterText(find.byKey(const ValueKey('layout-rename-ms')), 'Slip Gaji Bulanan');
        await tester.tap(find.byKey(const ValueKey('layout-rename-ok')));
        await tester.pumpAndSettle();
        expect(inPreview('Monthly Pay Slip'), findsOneWidget);

        await tester.ensureVisible(find.byKey(const ValueKey('layout-lang')));
        await tester.tap(find.text('Melayu'));
        await tester.pumpAndSettle();
        expect(inPreview('Slip Gaji Bulanan'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('layout-save')));
        await tester.pumpAndSettle();
        final s = repo.saved.single;
        expect(s.shows('ic'), isFalse);
        expect(s.label('title', 'en'), 'Monthly Pay Slip');
        expect(s.toJson()['fields'], {
          'title': {'en': 'Monthly Pay Slip', 'ms': 'Slip Gaji Bulanan'},
          'ic': {'show': false},
        });
        expect(find.byKey(const ValueKey('layout-save')), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('moves blocks and partner lines, sizes, colours and the logo', (tester) async {
        final (repo, _) = await pump(tester);
        await open(tester, 'layout-order');
        await tester.tap(find.byKey(const ValueKey('layout-section-activity-up')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('layout-partner-plate-up')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Title left, company right'));
        await tester.pumpAndSettle();

        await open(tester, 'layout-logo-upload');
        expect(repo.uploads, ['png']);
        await tester.ensureVisible(find.byKey(const ValueKey('layout-logo-position')));
        await tester.tap(find.text('Centre'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('layout-preview-logo')));
        await tester.drag(find.byKey(const ValueKey('layout-preview-logo')), const Offset(30, 0));
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.byKey(const ValueKey('layout-save')));
        await tester.tap(find.byKey(const ValueKey('layout-save')));
        await tester.pumpAndSettle();
        final s = repo.saved.single;
        expect(s.sectionOrder.indexOf('activity'), 4);
        expect(s.partnerLineOrder.take(4), ['partner', 'partnerId', 'plate', 'ic']);
        expect(s.companySide, 'right');
        expect(s.logo.path, 'statement-logo-1.png');
        expect(s.logo.position, 'center');
        expect(s.logo.dx, greaterThan(0), reason: 'dragged to the right on the preview');
        expect(tester.takeException(), isNull);
      });

      testWidgets('asks the server for a sample PDF in the layout being edited', (tester) async {
        final (repo, opened) = await pump(tester);
        await tester.tap(find.descendant(of: find.byKey(const ValueKey('layout-type')), matching: find.text('Weekly')));
        await tester.pumpAndSettle();
        await open(tester, 'layout-group-footer');
        await tester.tap(find.byKey(const ValueKey('layout-show-watermark')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('layout-sample')));
        await tester.tap(find.byKey(const ValueKey('layout-sample')));
        await tester.pumpAndSettle();
        expect(opened, ['sample.pdf']);
        final (type, lang, layout) = repo.samples.single;
        expect(type, StatementType.weekly);
        expect(lang, StatementLang.en);
        expect(layout.shows('watermark'), isFalse);
        expect(repo.saved, isEmpty, reason: 'a sample does not save');
      });

      testWidgets('read-only admins see the layout but change nothing', (tester) async {
        await pump(tester, edit: false);
        expect(find.byKey(const ValueKey('layout-logo-upload')), findsOneWidget);
        expect(tester.widget<FilledButton>(find.byKey(const ValueKey('layout-logo-upload'))).onPressed, isNull);
        expect(find.byKey(const ValueKey('layout-reset')), findsNothing);
        expect(find.byKey(const ValueKey('layout-sample')), findsOneWidget);
      });

      testWidgets('side by side on a wide screen, without overflow', (tester) async {
        await pump(tester, size: const Size(1400, 1000));
        expect(find.byKey(const ValueKey('layout-preview')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  }
}
