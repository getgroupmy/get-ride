import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/screens/people/people_data.dart';
import 'package:get_ride/src/admin/screens/people/vehicle_screens.dart';
import 'package:get_ride/src/admin/screens/people_screens.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// No token refresh: its timer would outlive the test.
final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

const _vehicle = {
  'id': 'v1',
  'plate': 'WXY 1',
  'make': 'Proton',
  'model': 'Saga',
  'status': 'unapproved',
  'permit': 'pending',
  'documents_ok': true,
};

class _Admin extends AdminRepository {
  _Admin() : super(_db);
  final patches = <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> vehicles() async => [_vehicle];

  @override
  Future<void> updateVehicle(String id, Map<String, dynamic> patch) async => patches.add(patch);
}

class _People extends PeopleRepository {
  _People(this.docs) : super(_db);
  final List<Map<String, dynamic>>? docs;

  @override
  Future<List<Map<String, dynamic>>> vehicleDocuments(String vehicleId) async => docs ?? (throw StateError('offline'));
}

void main() {
  for (final b in Brightness.values) {
    group('approving a vehicle (${b.name})', () {
      Future<bool?> check(WidgetTester tester, List<Map<String, dynamic>>? docs, {bool documentsOk = false}) async {
        bool? result;
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(b),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async => result = await confirmVehicleApprovable(
                    context,
                    documents: () async => docs ?? (throw StateError('offline')),
                    plate: 'WXY 1',
                    documentsOk: documentsOk,
                  ),
                  child: const Text('Approve'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Approve'));
        await tester.pumpAndSettle();
        return result;
      }

      testWidgets('goes ahead when every document is approved', (tester) async {
        final ok = await check(tester, [
          {'status': 'Approved'},
          {'status': 'Approved'},
        ]);
        expect(ok, isTrue);
        expect(find.byType(AlertDialog), findsNothing);
      });

      testWidgets('refuses and says how many are left', (tester) async {
        await check(tester, [
          {'status': 'Approved'},
          {'status': 'Pending Review'},
          {'status': 'Rejected'},
        ]);
        expect(find.text('Documents not fully approved'), findsOneWidget);
        expect(
          find.text(
            '1/3 vehicle documents are approved (1 pending, 1 rejected). '
            'Review and approve them before approving the vehicle.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      });

      testWidgets('refuses a vehicle with no documents', (tester) async {
        await check(tester, const []);
        expect(find.text('No documents uploaded'), findsOneWidget);
        expect(find.textContaining('WXY 1 has no vehicle documents on file'), findsOneWidget);
      });

      testWidgets('unreadable documents fall back to the "Documents complete" flag', (tester) async {
        await check(tester, null);
        expect(find.textContaining('WXY 1 has documents that still need review'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(await check(tester, null, documentsOk: true), isTrue);
      });
    });
  }

  group('the vehicle list status picker', () {
    Future<_Admin> pump(WidgetTester tester, List<Map<String, dynamic>> docs) async {
      final admin = _Admin();
      await tester.binding.setSurfaceSize(const Size(1000, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseProvider.overrideWithValue(_db),
            adminAccessProvider.overrideWith((_) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
            adminRepositoryProvider.overrideWithValue(admin),
            peopleRepositoryProvider.overrideWithValue(_People(docs)),
          ],
          child: MaterialApp(theme: appTheme(Brightness.light), home: const AdminPartnersScreen(vehicles: true)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('WXY 1 Proton Saga').first);
      await tester.pumpAndSettle();
      return admin;
    }

    testWidgets('refuses to approve while a document is pending', (tester) async {
      final admin = await pump(tester, [
        {'status': 'Pending Review'},
      ]);
      await tester.tap(find.widgetWithText(ChoiceChip, 'approved'));
      await tester.pumpAndSettle();
      expect(find.text('Documents not fully approved'), findsOneWidget);
      expect(admin.patches, isEmpty);
    });

    testWidgets('approves once every document is approved', (tester) async {
      final admin = await pump(tester, [
        {'status': 'Approved'},
      ]);
      await tester.tap(find.widgetWithText(ChoiceChip, 'approved'));
      await tester.pumpAndSettle();
      expect(admin.patches.single, {'status': 'approved'});
    });

    testWidgets('other statuses are not checked', (tester) async {
      final admin = await pump(tester, const []);
      await tester.tap(find.widgetWithText(ChoiceChip, 'blocked'));
      await tester.pumpAndSettle();
      expect(admin.patches.single, {'status': 'blocked'});
    });
  });
}
