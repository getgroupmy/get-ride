// Admin → Vehicle Services / Partner Service type: renaming one moves every
// place that uses the name (docs/KIV.md M2, migration 0304). The edit sheet
// shows what follows the new name and saves with "Save and update N places";
// the preview lists every place with examples; a name already used is
// refused; after the rename, "Renamed" and the Rename history card, whose
// latest rename can be changed back. Light and dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/admin_settings_models.dart';
import 'package:get_ride/src/admin/screens/catalogue/safe_rename.dart';
import 'package:get_ride/src/admin/screens/catalogue/services_screens.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notice.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

final _entries = [
  SettingEntry(id: 'ride', values: {'name': 'Ride', 'costPerKm': 1, 'costPerMin': 0.2, 'minFareAmount': 5, 'status': true, 'serviceTypes': ['Car']}),
  SettingEntry(id: 'comfort', values: {'name': 'Comfort', 'costPerKm': 1, 'costPerMin': 0.2, 'minFareAmount': 5, 'status': true, 'serviceTypes': ['Car']}),
  SettingEntry(id: 'premium', values: {'name': 'Premium', 'costPerKm': 1, 'costPerMin': 0.2, 'minFareAmount': 5, 'status': true, 'serviceTypes': ['Car']}),
];

const _places = [
  RenamePlace(key: 'type_services', count: 3, examples: ['eHailing', 'Teksi', 'Fleet']),
  RenamePlace(key: 'driver_switches', count: 12, examples: ['Aiman R.', 'Siti N.', 'Kumar P.'], more: 9),
  RenamePlace(key: 'service_locks', count: 1, examples: ['Lee W. (kept off)']),
  RenamePlace(key: 'partner_type_locks', count: 1, examples: ['Teksi: locked on']),
  RenamePlace(key: 'promo_codes', count: 2, examples: ['RIDE10', 'WEEKEND']),
  RenamePlace(key: 'commission_promotions', count: 0),
  RenamePlace(key: 'permit_services', count: 4, examples: ['GDL', 'EVP', 'Taxi permit'], more: 1),
];

RenamePreview _preview(String newName, {String category = 'vehicle-services', String old = 'Comfort'}) =>
    RenamePreview(
      category: category,
      entryId: 'comfort',
      oldName: old,
      newName: newName,
      places: _places,
      total: 23,
      openRequests: 4,
      bookings: 1,
      finishedRides: 96,
    );

class _Admin extends AdminRepository {
  _Admin() : super(_db);
  final saved = <({String? id, Map<String, dynamic> values})>[];

  @override
  Future<List<SettingEntry>> settings(SettingsCategory c) async => switch (c.key) {
        'vehicle-services' => _entries,
        _ => <SettingEntry>[],
      };

  @override
  Future<void> saveSetting(SettingsCategory c, {String? id, required Map<String, dynamic> values, int? position}) async =>
      saved.add((id: id, values: values));
}

class _Renames extends RenameRepository {
  _Renames({this.history0 = const []}) : super(_db);
  final List<RenameRecord> history0;
  final asked = <String>[];
  final applied = <String>[];
  final undone = <String>[];

  @override
  Future<RenamePreview> preview(String category, String entryId, String newName) async {
    asked.add(newName);
    // The server's answer for a name another entry has without the case.
    if (newName.toLowerCase().replaceAll(' ', '') == 'premiumplus') {
      return RenamePreview(
        category: category,
        entryId: entryId,
        oldName: 'Comfort',
        newName: newName,
        problemCode: 'RENAME_NAME_TAKEN',
        problemMessage: 'A Vehicle Service named Premium Plus already exists.',
        conflictName: 'Premium Plus',
      );
    }
    return _preview(newName);
  }

  @override
  Future<RenameDone> apply(String category, String entryId, String newName) async {
    applied.add('$category/$entryId/$newName');
    return (id: 'r1', oldName: 'Comfort', newName: newName, total: 23);
  }

  @override
  Future<RenameDone> undo(String renameId) async {
    undone.add(renameId);
    return (id: renameId, oldName: 'Comfort', newName: 'Comfort Plus', total: 23);
  }

  @override
  Future<List<RenameRecord>> history(String entryId) async => entryId == 'comfort' ? history0 : const [];
}

final _history = [
  RenameRecord(
    id: 'r2',
    oldName: 'Comfort',
    newName: 'Comfort Plus',
    total: 23,
    at: DateTime(2026, 10, 27, 14, 5),
    byName: 'Farah Z.',
  ),
  RenameRecord(
    id: 'r1',
    oldName: 'Executive',
    newName: 'Comfort',
    total: 15,
    at: DateTime(2026, 3, 3, 9, 40),
    byName: 'Daniel T.',
  ),
];

Future<void> _pumpScreen(WidgetTester tester, Brightness b, _Admin admin, _Renames renames) async {
  await tester.binding.setSurfaceSize(const Size(1280, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        supabaseProvider.overrideWithValue(_db),
        adminAccessProvider.overrideWith((_) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
        adminRepositoryProvider.overrideWithValue(admin),
        renameRepositoryProvider.overrideWithValue(renames),
      ],
      child: MaterialApp(theme: appTheme(b), home: const VehicleServicesScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, String name) async {
  await tester.tap(find.text(name).first);
  await tester.pumpAndSettle();
}

Future<void> _typeName(WidgetTester tester, String name) async {
  await tester.enterText(find.byKey(const ValueKey('rename-name')), name);
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

Finder _saveButton(String label) =>
    find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is FilledButton));

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}

/// Opens the preview dialog for [p] from a plain page; the Future of its
/// answer.
Future<Future<bool>> _showPreview(WidgetTester tester, Brightness b, RenamePreview p) async {
  late BuildContext ctx;
  await tester.binding.setSurfaceSize(const Size(900, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    theme: appTheme(b),
    home: Builder(builder: (c) {
      ctx = c;
      return const Scaffold();
    }),
  ));
  final answer = showRenamePreviewDialog(ctx, p);
  await tester.pumpAndSettle();
  return answer;
}

void main() {
  group('words', () {
    test('a name already used: no case, extra spaces or the same key', () {
      expect(renameClash('premium ', ['Ride', 'Premium']), 'Premium');
      expect(renameClash('Pre-mium', ['Premium']), 'Premium');
      expect(renameClash('Comfort Plus', ['Ride', 'Premium']), isNull);
      expect(renameTakenMessage('vehicle-services', 'Premium'), 'A Vehicle Service named Premium already exists.');
      expect(renameTakenMessage('partner-type', 'Fleet'), 'A Partner Service type named Fleet already exists.');
    });

    test('labels and messages', () {
      expect(renameSaveLabel(23), 'Save and update 23 places');
      expect(renameSaveLabel(1), 'Save and update 1 place');
      expect(renamedMessage(23, 'Comfort Plus'), '23 places now use Comfort Plus.');
      expect(undoneMessage(23, 'Comfort'), '23 places use Comfort again.');
      expect(_places[1].examplesText('Comfort'), 'Aiman R., Siti N., Kumar P. and 9 more.');
      expect(_places[4].examplesText('Comfort'), 'RIDE10, WEEKEND');
      expect(_places[5].examplesText('Comfort'), 'None use Comfort.');
    });

    test('the server\'s preview reads', () {
      final p = RenamePreview.fromJson({
        'category': 'partner-type',
        'entry_id': 'x',
        'old_name': 'pHailing',
        'new_name': 'Parcel Hailing',
        'problem': null,
        'places': [
          {'key': 'partners', 'count': 34, 'examples': ['Nur A.', 'Hafiz M.', 'Chong K.'], 'more': 31},
        ],
        'total': 52,
        'open_requests': 0,
        'bookings': 0,
        'finished_rides': 0,
      });
      expect(p.ok, isTrue);
      expect(p.isPartnerType, isTrue);
      expect(p.places.single.title, 'Partners');
      expect(p.places.single.examplesText('pHailing'), 'Nur A., Hafiz M., Chong K. and 31 more.');
      final taken = RenamePreview.fromJson({
        'problem': {'code': 'RENAME_NAME_TAKEN', 'message': 'A Vehicle Service named Premium already exists.',
          'conflict_name': 'Premium'},
      });
      expect(taken.conflict, isTrue);
      expect(taken.conflictName, 'Premium');
    });
  });

  for (final b in Brightness.values) {
    final mode = b == Brightness.dark ? ' (dark)' : '';

    group('Rename a Vehicle Service$mode', () {
      testWidgets('the preview: every place, examples, what keeps running', (tester) async {
        final answer = await _showPreview(tester, b, _preview('Comfort Plus'));
        expect(find.text('Rename Comfort to Comfort Plus?'), findsOneWidget);
        expect(find.text('These 23 places change to the new name together. Tap a row to see examples.'), findsOneWidget);
        for (final p in _places) {
          expect(find.descendant(of: find.byKey(ValueKey('rename-place-${p.key}')), matching: find.text(p.title)),
              findsOneWidget);
          expect(find.descendant(of: find.byKey(ValueKey('rename-place-${p.key}')), matching: find.text('${p.count}')),
              findsOneWidget);
        }
        // The first row is open; another opens on a tap.
        expect(find.text('eHailing, Teksi, Fleet'), findsOneWidget);
        expect(find.byKey(const ValueKey('rename-examples-driver_switches')), findsNothing);
        await tester.tap(find.byTooltip('Show examples for Driver switches'));
        await tester.pumpAndSettle();
        expect(find.text('Aiman R., Siti N., Kumar P. and 9 more.'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('rename-place-commission_promotions')));
        await tester.pumpAndSettle();
        expect(find.text('None use Comfort.'), findsOneWidget);

        expect(find.text('Not changed'), findsOneWidget);
        expect(find.text('Open requests and bookings for later, these keep running'), findsOneWidget);
        expect(find.text('4 + 1'), findsOneWidget);
        expect(find.text('Finished rides keep the old name'), findsOneWidget);
        expect(find.text('96'), findsOneWidget);
        expect(find.textContaining('→'), findsNothing);

        await tester.tap(find.byKey(const ValueKey('rename-confirm')));
        await tester.pumpAndSettle();
        expect(await answer, isTrue);
      });

      testWidgets('the sheet: what follows, Save and update, Rename, Renamed', (tester) async {
        final admin = _Admin();
        final renames = _Renames();
        await _pumpScreen(tester, b, admin, renames);
        await _open(tester, 'Comfort');
        expect(_saveButton('Save changes'), findsOneWidget);

        await _typeName(tester, 'Comfort Plus');
        expect(find.text('Was Comfort. Saving moves every place that uses the old name.'), findsOneWidget);
        expect(find.text('What follows the new name'), findsOneWidget);
        expect(find.byKey(const ValueKey('rename-summary-driver_switches')), findsOneWidget);
        expect(find.byKey(const ValueKey('rename-summary-commission_promotions')), findsNothing, reason: 'none');
        expect(find.text('96 finished rides keep the name Comfort.'), findsOneWidget);
        expect(renames.asked, ['Comfort Plus']);
        final save = _saveButton('Save and update 23 places');
        expect(save, findsOneWidget);

        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(find.text('Rename Comfort to Comfort Plus?'), findsOneWidget);
        // Cancel keeps the sheet open, nothing saved.
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(admin.saved, isEmpty);
        expect(renames.applied, isEmpty);

        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('rename-confirm')));
        await tester.pumpAndSettle();
        await pumpNotice(tester);

        // The other values first, under the old name; then the cascade.
        expect(admin.saved.single.id, 'comfort');
        expect(admin.saved.single.values['name'], 'Comfort');
        expect(renames.applied, ['vehicle-services/comfort/Comfort Plus']);
        expect(find.text('Renamed'), findsOneWidget);
        expect(find.text('23 places now use Comfort Plus.'), findsOneWidget);
        await closeNotice(tester);
        await _unmount(tester);
      });

      testWidgets('a name already used is refused', (tester) async {
        final admin = _Admin();
        final renames = _Renames();
        await _pumpScreen(tester, b, admin, renames);
        await _open(tester, 'Comfort');

        await _typeName(tester, 'premium ');
        expect(find.text('A Vehicle Service named Premium already exists.'), findsOneWidget);
        expect(find.text('Names are matched without case or extra spaces, so "premium " counts too. Pick another name, '
            'or edit Premium instead.'), findsOneWidget);
        expect(find.text('What follows the new name'), findsNothing);
        expect(renames.asked, isEmpty, reason: 'seen before asking the server');
        expect(tester.widget<FilledButton>(_saveButton('Save and update')).onPressed, isNull, reason: 'Save is off');

        // One the server knows of (the list here is older).
        await _typeName(tester, 'Premium Plus');
        expect(renames.asked, ['Premium Plus']);
        expect(find.text('A Vehicle Service named Premium Plus already exists.'), findsOneWidget);

        // Back to a free name: the summary again.
        await _typeName(tester, 'Comfort Plus');
        expect(find.text('What follows the new name'), findsOneWidget);
        expect(_saveButton('Save and update 23 places'), findsOneWidget);
        await _unmount(tester);
      });

      testWidgets('Rename history: the latest is undone after asking', (tester) async {
        final admin = _Admin();
        final renames = _Renames(history0: _history);
        await _pumpScreen(tester, b, admin, renames);
        await _open(tester, 'Comfort');

        final card = find.byKey(const ValueKey('rename-history'));
        await tester.ensureVisible(card);
        expect(find.text('Rename history'), findsOneWidget);
        expect(find.textContaining('Farah Z. (admin) · 27 Oct 2026, 14:05 · 23 places updated'), findsOneWidget);
        expect(find.textContaining('Daniel T. (admin) · 3 Mar 2026, 09:40 · 15 places updated'), findsOneWidget);
        expect(find.text('Only the latest can be undone'), findsOneWidget);
        expect(find.byKey(const ValueKey('rename-undo')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('rename-undo')));
        await tester.pumpAndSettle();
        expect(find.text('Change 23 places back?'), findsOneWidget);
        await tester.tap(find.text('Keep'));
        await tester.pumpAndSettle();
        expect(find.text('Change 23 places back?'), findsNothing);
        expect(renames.undone, isEmpty);

        await tester.tap(find.byKey(const ValueKey('rename-undo')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('rename-undo-confirm')));
        await tester.pumpAndSettle();
        await pumpNotice(tester);
        expect(renames.undone, ['r2']);
        expect(find.text('Changed back'), findsOneWidget);
        expect(find.text('23 places use Comfort again.'), findsOneWidget);
        await closeNotice(tester);
        expect(find.byKey(const ValueKey('rename-history')), findsNothing, reason: 'the sheet closed');
        expect(admin.saved, isEmpty, reason: 'nothing else saved');
        await _unmount(tester);
      });
    });

    group('Rename a Partner Service type$mode', () {
      testWidgets('the preview says approved partners keep their approval', (tester) async {
        final p = RenamePreview(
          category: 'partner-type',
          entryId: 'phailing',
          oldName: 'pHailing',
          newName: 'Parcel Hailing',
          places: const [
            RenamePlace(key: 'partners', count: 34, examples: ['Nur A.', 'Hafiz M.', 'Chong K.'], more: 31),
            RenamePlace(key: 'vehicles', count: 12, examples: ['WVA 3321', 'BMW 22', 'PKR 4410'], more: 9),
            RenamePlace(key: 'permit_types', count: 2, examples: ['Goods vehicle permit', 'Courier licence']),
            RenamePlace(key: 'push_audiences', count: 1, examples: ['pHailing drivers, Klang Valley']),
            RenamePlace(key: 'document_rules', count: 3, examples: ['Required documents: Motorcycle licence']),
            RenamePlace(key: 'driver_locks', count: 0),
          ],
          total: 52,
        );
        final answer = await _showPreview(tester, b, p);
        expect(find.text('Partner Service type'), findsOneWidget);
        expect(find.text('Rename pHailing to Parcel Hailing?'), findsOneWidget);
        expect(find.textContaining('These 52 places change to the new name together.'), findsOneWidget);
        expect(find.text('Nur A., Hafiz M., Chong K. and 31 more.'), findsOneWidget);
        for (final t in ['Partners', 'Vehicles', 'Permit types', 'Push audiences', 'Document rules', 'Driver locks']) {
          expect(find.text(t), findsOneWidget);
        }
        expect(
          find.text('Approved partners\' types change too, without asking them again. They keep their approval and '
              'their jobs.'),
          findsOneWidget,
        );
        expect(find.text('Not changed'), findsNothing, reason: 'rides are a Vehicle Service\'s');
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(await answer, isFalse);
      });
    });
  }
}
