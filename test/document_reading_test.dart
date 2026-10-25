// Document reading (migration 0293): the reader order and switches, the NAS
// card, and the app's text reader following them.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/catalogue/document_reading_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/document_reading.dart';
import 'package:get_ride/src/data/document_ai_repository.dart';
import 'package:get_ride/src/data/document_reading_repository.dart';
import 'package:get_ride/src/data/document_text_reader.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _Repo extends DocumentReadingRepository {
  _Repo(this.cfg, this.state) : super(_db);
  DocumentReadingConfig cfg;
  ReadersState state;
  final saves = <DocumentReadingConfig>[];
  final removed = <String>[];

  @override
  Future<DocumentReadingConfig> config() async => cfg;

  @override
  Future<DocumentReadingConfig> save(DocumentReadingConfig c) async {
    saves.add(c);
    return cfg = c;
  }

  @override
  Future<ReadersState> readers() async => state;

  @override
  Future<({String code, DateTime? expiresAt})> pairingCode(DocReaderId kind, String label) async =>
      (code: 'ABCD-EFGH', expiresAt: null);

  @override
  Future<void> remove(String id) async => removed.add(id);
}

final _nas = ReadersState.fromJson({
  'waiting': 3,
  'readers': [
    {
      'id': 'r1',
      'kind': 'nas',
      'label': 'DS224+',
      'model': 'Celeron J4125',
      'app_version': '1.0.0',
      'last_seen_at': DateTime.now().toUtc().toIso8601String(),
      'online': true,
      'today': {
        'plates': {'done': 42, 'passed_on': 1, 'avg_ms': 1190},
        'numbers': {'done': 118, 'passed_on': 6, 'avg_ms': 2330},
      },
    },
  ],
});

Future<_Repo> _pump(WidgetTester tester, {ReadersState? readers, bool fullAdmin = true, bool edit = true}) async {
  final repo = _Repo(DocumentReadingConfig.defaults, readers ?? const ReadersState());
  await tester.binding.setSurfaceSize(const Size(1000, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      supabaseProvider.overrideWithValue(_db),
      ...quietLiveOverrides,
      adminAccessProvider.overrideWith((_) async => AdminAccess([
            AdminGrant(page: fullAdmin ? '*' : documentReadingPage, edit: edit),
          ])),
      documentReadingRepositoryProvider.overrideWithValue(repo),
    ],
    child: MaterialApp(theme: appTheme(Brightness.light), home: const DocumentReadingScreen()),
  ));
  await tester.pumpAndSettle();
  return repo;
}

String _order(DocumentReadingConfig c) => [for (final r in c.readers) '${r.id.name}${r.on ? '' : '-off'}'].join(',');

void main() {
  group('settings', () {
    test('read leniently, like the server', () {
      final c = DocumentReadingConfig.fromJson({
        'readers': [
          {'id': 'cloud', 'on': false},
          {'id': 'evil'},
          {'id': 'cloud', 'on': true},
          {'id': 'phone'},
        ],
        'nasJobs': {'qr': false},
        'passOnBelow': 12,
      });
      expect(_order(c), 'cloud-off,phone,nas,gpu');
      expect(c.nasJobs[NasJob.qr], isFalse);
      expect(c.nasJobs[NasJob.plates], isTrue);
      expect(c.passOnBelow, 50);
      expect(DocumentReadingConfig.fromJson(null).passOnBelow, 90);
      expect(_order(DocumentReadingConfig.fromJson(c.toJson())), _order(c));
    });

    test('move, switch, and the order of the switched-on readers', () {
      var c = DocumentReadingConfig.defaults;
      c = c.move(DocReaderId.cloud, -1);
      expect(_order(c), 'phone,nas,cloud,gpu');
      expect(c.move(DocReaderId.phone, -1), same(c), reason: 'the first can\'t go up');
      // A hidden GPU PC keeps its place: moving the cloud reader down past it does nothing.
      final shown = {DocReaderId.phone, DocReaderId.nas, DocReaderId.cloud};
      expect(c.move(DocReaderId.cloud, 1, shown: shown), same(c));
      expect(_order(c.move(DocReaderId.cloud, -1, shown: shown)), 'phone,cloud,nas,gpu');
      c = c.toggled(DocReaderId.nas, false);
      expect(c.order, [DocReaderId.phone, DocReaderId.cloud, DocReaderId.gpu]);
      expect(c.isOn(DocReaderId.nas), isFalse);
      expect(c.before(DocReaderId.cloud, DocReaderId.phone), isFalse);
    });

    test('the GPU PC is listed once connected; the summary in words', () {
      final c = DocumentReadingConfig.defaults;
      expect([for (final r in shownReaders(c, gpuConnected: false)) r.id], isNot(contains(DocReaderId.gpu)));
      expect(shownReaders(c, gpuConnected: true).length, 4);
      expect(readingSummary(shownReaders(c, gpuConnected: false)),
          "Documents go to: Driver's phone, then Office NAS, then Cloud reader.");
      expect(readingSummary(const [DocReaderSlot(DocReaderId.phone, false)]),
          'Every reader is off: documents wait for a person.');
    });

    test('connected readers and their day', () {
      final r = _nas.of(DocReaderId.nas).single;
      expect(r.label, 'DS224+');
      expect(r.today['plates']?.done, 42);
      expect(readerSeconds(r.today['numbers']?.avgMs), '2.3 s');
      expect(readerSeconds(null), '–');
      expect(readerSeen(r, r.lastSeenAt!.add(const Duration(seconds: 20))), 'Online, last seen 20 s ago');
      expect(ReadersState.fromJson({'readers': [{'kind': 'phone'}, 'x']}).readers, isEmpty);
    });
  });

  group('admin page', () {
    testWidgets('move and switch readers; every change saves', (tester) async {
      final repo = await _pump(tester);
      expect(find.byKey(const ValueKey('doc-reader-gpu')), findsNothing, reason: 'no GPU PC connected');
      expect(find.text("Documents go to: Driver's phone, then Office NAS, then Cloud reader."), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('doc-reader-up-cloud')));
      await tester.pumpAndSettle();
      expect(_order(repo.saves.last), 'phone,cloud,nas,gpu');

      await tester.tap(find.byKey(const ValueKey('doc-reader-switch-phone')));
      await tester.pumpAndSettle();
      expect(repo.saves.last.isOn(DocReaderId.phone), isFalse);
      expect(find.text('Documents go to: Cloud reader, then Office NAS. Saved.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('doc-reader-job-qr')));
      await tester.pumpAndSettle();
      expect(repo.saves.last.nasJobs[NasJob.qr], isFalse);
    });

    testWidgets('the NAS: status, today and disconnect', (tester) async {
      final repo = await _pump(tester, readers: _nas);
      expect(find.textContaining('DS224+ · Online, last seen'), findsOneWidget);
      expect(find.text('Celeron J4125 · Version 1.0.0'), findsOneWidget);
      expect(find.text('118'), findsOneWidget);
      expect(find.text('1.2 s'), findsOneWidget);
      expect(find.text('Waiting: 3 photos'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('doc-reader-disconnect-r1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disconnect').last);
      await tester.pumpAndSettle();
      expect(repo.removed, ['r1']);
    });

    testWidgets('connecting gives a one-time code', (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('doc-reader-connect-nas')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Get code'));
      await tester.pumpAndSettle();
      expect(find.text('ABCD-EFGH'), findsOneWidget);
    });

    testWidgets('only a full admin connects readers; read-only sees no controls', (tester) async {
      await _pump(tester, fullAdmin: false, edit: false);
      expect(find.byKey(const ValueKey('doc-reader-connect-nas')), findsNothing);
      expect(find.byKey(const ValueKey('doc-reader-connect-gpu')), findsNothing);
      final sw = tester.widget<Switch>(find.byKey(const ValueKey('doc-reader-switch-phone')));
      expect(sw.onChanged, isNull);
    });
  });

  group('the app follows the switches', () {
    test('the cloud reader off: no AI document check', () async {
      var asked = 0;
      final repo = DocumentAiRepository(_db, () async {
        asked++;
        return false;
      });
      final r = await repo.verify({'front': 'data:image/png;base64,AA=='});
      expect(asked, 1);
      expect(r.result, isNull);
      expect(r.reason, 'off');
    });

    test('every reader off: nothing is read, the fields open empty', () async {
      final container = ProviderContainer(overrides: [
        documentReadingConfigProvider.overrideWith((_) async => DocumentReadingConfig.defaults
            .toggled(DocReaderId.phone, false)
            .toggled(DocReaderId.cloud, false)),
      ]);
      addTearDown(container.dispose);
      final read = container.read(documentTextReaderProvider);
      expect(await read(Uint8List.fromList([1, 2, 3]), fileUrl: 'https://x/a.jpg'), isNull);
    });
  });
}
