// Admin → Services & catalogue → Service order: the screen against the real
// AirportRepository over a fake PostgREST `vehicle_service_order` table (in
// memory, honouring `order=rank.asc|desc` as the server does). The owner saw
// the list as the exact reverse of the table (a bare `.order('rank')` sorts
// descending in postgrest-dart). Also: drag, arrows, typing a position, the
// Save order button and its notes, the Lowest / Highest labels — light and
// dark.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/screens/catalogue/service_order_screen.dart';
import 'package:get_ride/src/admin/screens/geo/geo_data.dart' show regionVehicleTypesProvider;
import 'package:get_ride/src/admin/screens/geo/geo_logic.dart' show ServiceOption;
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/data/airport_repository.dart';
import 'package:get_ride/src/data/service_order_repository.dart';
import 'package:get_ride/src/providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'notice.dart';

const _services = [
  ServiceOption(id: 'r', name: 'Ride'),
  ServiceOption(id: 'c', name: 'Comfort'),
  ServiceOption(id: 's', name: '6-seater'),
  ServiceOption(id: 'p', name: 'Premium'),
];

/// `vehicle_service_order` held in memory, served as PostgREST would.
class _FakeTable {
  _FakeTable([Map<String, int> rows = const {}]) : rank = {...rows};

  /// service_id → rank (1 = lowest).
  final Map<String, int> rank;
  int writes = 0;

  /// The ids from rank 1 up, as stored.
  List<String> get lowestFirst =>
      (rank.entries.toList()..sort((a, b) => a.value.compareTo(b.value))).map((e) => e.key).toList();

  late final SupabaseClient client = SupabaseClient(
    'http://localhost',
    'anon',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient(_handle),
  );

  Future<http.Response> _handle(http.Request req) async {
    final u = req.url;
    if (!u.path.endsWith('/rest/v1/vehicle_service_order')) {
      return http.Response('[]', 200, headers: {'content-type': 'application/json'}, request: req);
    }
    switch (req.method) {
      case 'GET':
        final rows = rank.entries.toList();
        final order = u.queryParameters['order'] ?? '';
        if (order.startsWith('rank')) {
          rows.sort((a, b) => a.value.compareTo(b.value));
          if (order.contains('.desc')) {
            final r = rows.reversed.toList();
            rows
              ..clear()
              ..addAll(r);
          }
        }
        return http.Response(
          jsonEncode([for (final e in rows) {'service_id': e.key, 'rank': e.value}]),
          200,
          headers: {'content-type': 'application/json'},
          request: req,
        );
      case 'DELETE':
        final f = u.queryParameters['service_id'] ?? '';
        final ids = f.startsWith('in.(') ? f.substring(4, f.length - 1).split(',') : const <String>[];
        for (final id in ids) {
          rank.remove(id.replaceAll('"', ''));
        }
        writes++;
        return http.Response('', 204, request: req);
      case 'POST':
        for (final r in jsonDecode(req.body) as List) {
          rank['${r['service_id']}'] = r['rank'] as int;
        }
        writes++;
        return http.Response('', 201, request: req);
    }
    return http.Response('', 405, request: req);
  }
}

Future<_FakeTable> _pump(WidgetTester tester, Brightness b, _FakeTable table, {bool canEdit = true}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        supabaseProvider.overrideWithValue(table.client),
        pageAccessProvider.overrideWith((ref, page) => canEdit ? AccessLevel.edit : AccessLevel.read),
        regionVehicleTypesProvider.overrideWith((ref) async => _services),
        serviceOrderEnforcedProvider.overrideWith((ref) async => false),
        vehiclesMissingServiceProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(theme: appTheme(b), home: const ServiceOrderScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return table;
}

/// The service names as the screen lists them, top to bottom.
List<String> _shown(WidgetTester tester) {
  final rows = <({String name, double y})>[];
  for (final s in _services) {
    final f = find.descendant(
      of: find.byKey(ValueKey('airport-service-${s.id}')),
      matching: find.textContaining(s.name),
    );
    if (f.evaluate().isEmpty) continue;
    rows.add((name: s.name, y: tester.getTopLeft(f.first).dy));
  }
  rows.sort((a, b) => a.y.compareTo(b.y));
  return [for (final r in rows) r.name];
}


Finder _key(String k) => find.byKey(ValueKey(k));

ButtonStyleButton _saveButton(WidgetTester tester) => tester.widget<ButtonStyleButton>(_key('service-order-save'));

bool _canSave(WidgetTester tester) => _saveButton(tester).onPressed != null;

Future<void> _tap(WidgetTester tester, Finder f) async {
  // A message from the last step is closed first, as the user would.
  await closeAnyNotice(tester);
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// Drags [id]'s row by its handle [rows] rows down (negative: up).
Future<void> _drag(WidgetTester tester, String id, int rows) async {
  final row = _key('airport-service-$id');
  final h = tester.getSize(row).height + 4;
  final handle = find.descendant(of: row, matching: find.byIcon(Icons.drag_indicator));
  final g = await tester.startGesture(tester.getCenter(handle));
  await tester.pump(const Duration(milliseconds: 100));
  final step = (rows * h + (rows > 0 ? h / 5 : -h / 5)) / 10;
  for (var i = 0; i < 10; i++) {
    await g.moveBy(Offset(0, step));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await g.up();
  await tester.pumpAndSettle();
}

/// Types [n] as [id]'s position and submits it.
Future<void> _typeRank(WidgetTester tester, String id, String n) async {
  final f = find.descendant(of: _key('service-order-rank-$id'), matching: find.byType(TextField));
  await tester.ensureVisible(f);
  await tester.enterText(f, n);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

/// What another admin's save looks like here: the live table refetches.
Future<void> _liveRefresh(WidgetTester tester) async {
  ProviderScope.containerOf(tester.element(find.byType(ServiceOrderScreen))).invalidate(vehicleServiceOrderProvider);
  await tester.pumpAndSettle();
}

String _rankText(WidgetTester tester, String id) => tester
    .widget<TextField>(find.descendant(of: _key('service-order-rank-$id'), matching: find.byType(TextField)))
    .controller!
    .text;

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}

void main() {
  for (final b in Brightness.values) {
    final mode = b == Brightness.dark ? ' (dark)' : '';

    group('Admin: Service order$mode', () {
      testWidgets('shows the table lowest first, not reversed (the live bug)', (tester) async {
        // As live: rank 1 = 6-seater, 2 = Comfort, 3 = Premium, 4 = Ride.
        final table = await _pump(tester, b, _FakeTable({'s': 1, 'c': 2, 'p': 3, 'r': 4}));
        expect(_shown(tester), ['6-seater', 'Comfort', 'Premium', 'Ride']);
        expect(await AirportRepository(table.client).serviceOrder(), ['s', 'c', 'p', 'r']);
        await _unmount(tester);
      });

      testWidgets('ranks 1..4 = Ride, Comfort, 6-seater, Premium display as 1..4 and save back the same', (tester) async {
        // As the table was set live: Ride = 1, Comfort = 2, 6-seater = 3, Premium = 4.
        final table = await _pump(tester, b, _FakeTable({'r': 1, 'c': 2, 's': 3, 'p': 4}));
        expect(_shown(tester), ['Ride', 'Comfort', '6-seater', 'Premium']);
        expect([for (final id in ['r', 'c', 's', 'p']) _rankText(tester, id)], ['1', '2', '3', '4']);
        expect(_canSave(tester), isFalse, reason: 'the screen matches the table');
        // Saving the shown list writes the same ranks back.
        await AirportRepository(table.client).saveServiceOrder(['r', 'c', 's', 'p']);
        expect(table.rank, {'r': 1, 'c': 2, 's': 3, 'p': 4});
        // Through the screen: a move and its undo, saved, keeps every rank.
        await _tap(tester, find.byTooltip('Move Premium lower'));
        await _tap(tester, _key('service-order-save'));
        expect(table.rank, {'r': 1, 'c': 2, 'p': 3, 's': 4});
        expect(_shown(tester), ['Ride', 'Comfort', 'Premium', '6-seater']);
        await _tap(tester, find.byTooltip('Move Premium higher'));
        await _tap(tester, _key('service-order-save'));
        expect(table.rank, {'r': 1, 'c': 2, 's': 3, 'p': 4});
        expect(_shown(tester), ['Ride', 'Comfort', '6-seater', 'Premium']);
        expect([for (final id in ['r', 'c', 's', 'p']) _rankText(tester, id)], ['1', '2', '3', '4']);
        await _unmount(tester);
      });

      testWidgets('nothing saved yet: a note, and Save order stores the shown order', (tester) async {
        final table = await _pump(tester, b, _FakeTable());
        expect(_key('service-order-not-saved'), findsOneWidget);
        expect(find.text('Not saved yet: no order is stored, so none applies until you save.'), findsOneWidget);
        expect(_canSave(tester), isTrue);
        // The owner's earlier arrangement: Ride → Comfort → 6-seater → Premium.
        expect(_shown(tester), ['Ride', 'Comfort', '6-seater', 'Premium']);
        await _tap(tester, _key('service-order-save'));
        expect(table.lowestFirst, ['r', 'c', 's', 'p']);
        expect(table.rank, {'r': 1, 'c': 2, 's': 3, 'p': 4});
        // Read back: the screen shows what is stored, in the same order.
        expect(_shown(tester), ['Ride', 'Comfort', '6-seater', 'Premium']);
        expect(_key('service-order-not-saved'), findsNothing);
        expect(_key('service-order-saved'), findsOneWidget);
        expect(_canSave(tester), isFalse);
        expect(find.text('Service order saved'), findsOneWidget);
        await _unmount(tester);
      });

      testWidgets('moves wait for Save order; the screen then matches the table', (tester) async {
        final table = await _pump(tester, b, _FakeTable({'r': 1, 'c': 2, 's': 3, 'p': 4}));
        expect(_canSave(tester), isFalse);
        expect(_key('service-order-saved'), findsOneWidget);
        await _tap(tester, find.byTooltip('Move Premium lower'));
        expect(_shown(tester), ['Ride', 'Comfort', 'Premium', '6-seater']);
        expect(table.writes, 0, reason: 'a move alone saves nothing');
        expect(_key('service-order-unsaved'), findsOneWidget);
        expect(_canSave(tester), isTrue);
        // Moving it back: the same as stored, nothing to save.
        await _tap(tester, find.byTooltip('Move Premium higher'));
        expect(_canSave(tester), isFalse);
        await _tap(tester, find.byTooltip('Move Ride higher'));
        await _tap(tester, _key('service-order-save'));
        expect(table.lowestFirst, ['c', 'r', 's', 'p']);
        expect(_shown(tester), ['Comfort', 'Ride', '6-seater', 'Premium']);
        expect(_canSave(tester), isFalse);
        // Saving twice in a row never flips it.
        await _tap(tester, find.byTooltip('Move 6-seater lower'));
        await _tap(tester, _key('service-order-save'));
        expect(table.lowestFirst, ['c', 's', 'r', 'p']);
        expect(_shown(tester), ['Comfort', '6-seater', 'Ride', 'Premium']);
        await _unmount(tester);
      });

      testWidgets('arrows: the ends are disabled', (tester) async {
        await _pump(tester, b, _FakeTable({'r': 1, 'c': 2, 's': 3, 'p': 4}));
        IconButton btn(String tip) => tester.widget<IconButton>(
          find.ancestor(of: find.byTooltip(tip), matching: find.byType(IconButton)).first,
        );
        expect(btn('Move Ride lower').onPressed, isNull);
        expect(btn('Move Premium higher').onPressed, isNull);
        await _tap(tester, find.byTooltip('Move Ride higher'));
        await _tap(tester, find.byTooltip('Move Ride higher'));
        expect(_shown(tester), ['Comfort', '6-seater', 'Ride', 'Premium']);
        await _tap(tester, find.byTooltip('Move Premium lower'));
        expect(_shown(tester), ['Comfort', '6-seater', 'Premium', 'Ride']);
        expect(btn('Move Ride higher').onPressed, isNull);
        await _unmount(tester);
      });

      testWidgets('drag down and up lands where dropped', (tester) async {
        await _pump(tester, b, _FakeTable({'r': 1, 'c': 2, 's': 3, 'p': 4}));
        await _drag(tester, 'r', 2);
        expect(_shown(tester), ['Comfort', '6-seater', 'Ride', 'Premium']);
        await _drag(tester, 'c', 3);
        expect(_shown(tester), ['6-seater', 'Ride', 'Premium', 'Comfort']);
        await _drag(tester, 'c', -2);
        expect(_shown(tester), ['6-seater', 'Comfort', 'Ride', 'Premium']);
        await _drag(tester, 'p', -3);
        expect(_shown(tester), ['Premium', '6-seater', 'Comfort', 'Ride']);
        expect(_canSave(tester), isTrue);
        await _unmount(tester);
      });

      testWidgets('typing a position moves the row there and renumbers', (tester) async {
        final table = await _pump(tester, b, _FakeTable({'r': 1, 'c': 2, 's': 3, 'p': 4}));
        expect([for (final id in ['r', 'c', 's', 'p']) _rankText(tester, id)], ['1', '2', '3', '4']);
        await _typeRank(tester, 'r', '3');
        expect(_shown(tester), ['Comfort', '6-seater', 'Ride', 'Premium']);
        expect([for (final id in ['c', 's', 'r', 'p']) _rankText(tester, id)], ['1', '2', '3', '4']);
        await _typeRank(tester, 'p', '1');
        expect(_shown(tester), ['Premium', 'Comfort', '6-seater', 'Ride']);
        // Past the end: the last place. Nothing typed: the number comes back.
        await _typeRank(tester, 'p', '9');
        expect(_shown(tester), ['Comfort', '6-seater', 'Ride', 'Premium']);
        expect(_rankText(tester, 'p'), '4');
        await _typeRank(tester, 'c', '');
        expect(_rankText(tester, 'c'), '1');
        expect(_shown(tester), ['Comfort', '6-seater', 'Ride', 'Premium']);
        await _tap(tester, _key('service-order-save'));
        expect(table.rank, {'c': 1, 's': 2, 'r': 3, 'p': 4});
        await _unmount(tester);
      });

      testWidgets('Lowest at the top end, Highest at the bottom end', (tester) async {
        await _pump(tester, b, _FakeTable({'r': 1, 'c': 2, 's': 3, 'p': 4}));
        expect(find.text('Lowest (1)'), findsOneWidget);
        expect(find.text('Highest (4)'), findsOneWidget);
        final low = tester.getBottomLeft(_key('service-order-lowest')).dy;
        final high = tester.getTopLeft(_key('service-order-highest')).dy;
        expect(low, lessThanOrEqualTo(tester.getTopLeft(_key('airport-service-r')).dy));
        expect(high, greaterThanOrEqualTo(tester.getBottomLeft(_key('airport-service-p')).dy));
        await _unmount(tester);
      });

      testWidgets('another admin\'s save shows live; unsaved moves are kept', (tester) async {
        final table = await _pump(tester, b, _FakeTable({'r': 1, 'c': 2, 's': 3, 'p': 4}));
        table.rank
          ..clear()
          ..addAll({'p': 1, 's': 2, 'c': 3, 'r': 4});
        await _liveRefresh(tester);
        expect(_shown(tester), ['Premium', '6-seater', 'Comfort', 'Ride']);
        expect(_canSave(tester), isFalse);
        await _tap(tester, find.byTooltip('Move Ride lower'));
        table.rank['p'] = 5;
        await _liveRefresh(tester);
        expect(_shown(tester), ['Premium', '6-seater', 'Ride', 'Comfort'], reason: 'the admin\'s moves stay');
        expect(_canSave(tester), isTrue);
        await _unmount(tester);
      });

      testWidgets('look-only admins see numbers, no Save order', (tester) async {
        await _pump(tester, b, _FakeTable({'s': 1, 'c': 2, 'p': 3, 'r': 4}), canEdit: false);
        expect(_shown(tester), ['6-seater', 'Comfort', 'Premium', 'Ride']);
        expect(_key('service-order-save'), findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(find.byTooltip('Move Ride lower'), findsNothing);
        expect(find.text('Lowest (1)'), findsOneWidget);
        await _unmount(tester);
      });
    });
  }
}
