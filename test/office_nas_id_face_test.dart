// Admin › Settings › Office NAS › ID and face (migration 0320), light and
// dark: the rows of the mockup from admin_nas_id_face, the order fields under
// "Change the order", read only without edit; and the page is on the
// Settings hub, grantable as admin-settings-office-nas.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/office_nas/office_nas_id_face.dart';
import 'package:get_ride/src/admin/screens/office_nas/office_nas_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/office_nas.dart' show officeNasPage, officeNasPath;
import 'package:get_ride/src/core/signin_checks.dart';
import 'package:get_ride/src/data/identity_repository.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';
import 'text_contrast.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

final _answer = <String, dynamic>{
  'config': {
    'faceOrder': [
      {'id': 'aws', 'on': true},
      {'id': 'nas', 'on': true},
      {'id': 'browser', 'on': true},
    ],
    'idReaders': [
      {'id': 'phone', 'on': true},
      {'id': 'nas', 'on': true},
      {'id': 'vision', 'on': true},
    ],
    'faceLowScore': 60,
    'awsKey': true,
    'faceServer': true,
    'visionKey': true,
    'nasReader': true,
    'nasOnline': true,
  },
  'reader': {'label': 'DS224+ office', 'online': true},
  'reads': {'done': 84, 'passed_on': 3, 'failed': 0, 'avg_ms': 2100},
  'faces': {'aws': 12, 'browser': 4},
  'closer': 2,
};

class _Identity extends IdentityRepository {
  _Identity() : super(_db);
  final calls = <String>[];

  @override
  Future<Map<String, dynamic>> nasIdFace() async => _answer;

  @override
  Future<IdentityConfig> config() async => IdentityConfig.fromJson(_answer['config']);

  @override
  Future<IdentityConfig> setOrder({List<OrderSlot>? faceOrder, List<OrderSlot>? idReaders, int? faceLowScore}) async {
    calls.add('set');
    return config();
  }
}

Future<_Identity> _pump(WidgetTester tester, Brightness b, {bool edit = true}) async {
  final identity = _Identity();
  await tester.binding.setSurfaceSize(const Size(420, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        supabaseProvider.overrideWithValue(_db),
        ...quietLiveOverrides,
        adminAccessProvider.overrideWith((_) async => AdminAccess([AdminGrant(page: officeNasPage, edit: edit)])),
        identityRepositoryProvider.overrideWithValue(identity),
      ],
      child: MaterialApp(theme: appTheme(b), home: const OfficeNasScreen(initialTab: 'id-face')),
    ),
  );
  await tester.pumpAndSettle();
  return identity;
}

void main() {
  test('the rows, from the server\'s answer', () {
    final rows = {for (final (k, v) in nasIdFaceRows(_answer)) k: v};
    expect(rows['ID card reading (MyKad, passport) for sign-in checks'], 'Phone, then NAS, then Google Vision');
    expect(rows['Face match order'], 'AWS, then NAS, then in-browser');
    expect(rows['In-browser check'], 'Runs while an admin has the queue open');
    expect(rows['Read today'], '84 cards · 2.1 s each · 3 passed on');
    expect(rows['Faces scored today'], 'AWS 12 · in-browser 4');
    expect(rows['Below 60% match'], 'Marked "Needs a closer look" · 2 waiting');
    expect(rows['NAS document reader'], 'DS224+ office · Online');
    final none = {for (final (k, v) in nasIdFaceRows(const {})) k: v};
    expect(none['NAS document reader'], 'Not connected');
    expect(none['Read today'], 'None yet');
  });

  test('on the Settings hub, grantable on its own page', () {
    final e = allAdminEntries.singleWhere((e) => e.path == officeNasPath);
    expect(e.pages, ['admin-settings-office-nas']);
    expect(e.title, 'Office NAS');
  });

  for (final b in Brightness.values) {
    group('${b.name}:', () {
      testWidgets('the tab as the mockup has it, and the orders under it', (tester) async {
        final identity = await _pump(tester, b);
        expect(find.text('ID and face'), findsOneWidget);
        expect(find.text('AWS, then NAS, then in-browser'), findsOneWidget);
        expect(find.text('84 cards · 2.1 s each · 3 passed on'), findsOneWidget);
        expect(find.textContaining('Only the fields asked for go back'), findsOneWidget);
        expect(unreadableTexts(tester, find.byKey(const ValueKey('office-nas-id-face'))), isEmpty);

        await tester.tap(find.text('Change the order'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('identity-providers')), findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('face-low-up')));
        await tester.pumpAndSettle();
        expect(tester.widget<IconButton>(find.byKey(const ValueKey('face-low-up'))).onPressed, isNotNull);
        await tester.tap(find.byKey(const ValueKey('face-low-up')));
        await tester.pumpAndSettle();
        expect(identity.calls, ['set']);
      });

      testWidgets('read only without edit', (tester) async {
        await _pump(tester, b, edit: false);
        await tester.tap(find.text('Change the order'));
        await tester.pumpAndSettle();
        final sw = tester.widget<Switch>(find.byKey(const ValueKey('face-order-switch-aws')));
        expect(sw.onChanged, isNull);
      });
    });
  }
}
