// The permit screens (migration 0254), in light and dark: the passenger's
// button and sheet (each field in English with the local label under it,
// none on bypass, both permits on a taxi ride), the driver's banners, the
// admin's list (tabs and actions) and the expiry reminders editor.
// All names and numbers are made up.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/people/vehicle_permits_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/date_order.dart';
import 'package:get_ride/src/core/permits.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/permits_repository.dart';
import 'package:get_ride/src/features/partner/my_permits_screen.dart';
import 'package:get_ride/src/features/ride/ride_permit_button.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'quiet_live.dart';
import 'notice.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

PermitFieldValue _f(String key, String label, String local, String? value, {bool date = false}) => PermitFieldValue(
  field: PermitField(key: key, label: label, labelLocal: local, isDate: date, passenger: true),
  value: value,
);

final _evp = PermitItem(
  typeId: 'evp',
  name: 'E-hailing vehicle permit (eVP)',
  nameLocal: 'Permit Kenderaan E-hailing',
  shortName: 'Vehicle permit',
  issuer: 'Sample Agency',
  fields: [
    _f('ref_primary', 'Permit Reference No. (Primary)', 'No. Rujukan Permit (Induk)', 'TE-TST1234'),
    _f('ref_sub', 'Permit Reference No. (Sub)', 'No. Rujukan Permit (Sub)', '512 384'),
    _f('effective', 'Permit Effective Date', 'Tarikh Mula Kuatkuasa Permit', '2024-07-05', date: true),
    _f('valid_until', 'Permit Valid Until', 'Tarikh Sahlaku Permit Sehingga', '2027-07-04', date: true),
  ],
  bucket: 'vehicle-documents',
  path: 'v1/permits/evp-1.pdf',
);

final _taxi = PermitItem(
  typeId: 'taxi',
  name: 'Taxi driver permit',
  shortName: 'Taxi permit',
  forDriver: true,
  fields: [_f('permit_no', 'Permit No.', 'No. Permit', 'TDP-0000001')],
  bucket: 'provider-documents',
  path: 'p1/d/front.png',
);

RideRequest _ride(String status) => RideRequest({
  'id': 'ride-1',
  'status': status,
  'rider_id': 'rider-1',
  'partner_id': 'driver-1',
  'partner_vehicle_id': 'v1',
  'partner_plate': 'TST 1234',
  'partner_vehicle': 'Silver Testmake Alpha',
  'partner_plate_colours': {'bg': '#1e8e3e', 'fg': '#ffffff'},
});

Future<void> _pump(WidgetTester tester, Widget child, {required Brightness brightness, List overrides = const []}) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [supabaseProvider.overrideWithValue(_db), ...quietLiveOverrides, ...overrides.cast()],
    child: MaterialApp(theme: appTheme(brightness), home: Scaffold(body: child)),
  ));
  await tester.pumpAndSettle();
}

class _FakeRepo extends PermitsRepository {
  _FakeRepo() : super(_db);
  final bypasses = <(String, bool)>[];

  @override
  Future<DateTime?> setBypass(String vehicleId, bool on) async {
    bypasses.add((vehicleId, on));
    return null;
  }
}

VehiclePermits _vehicle(String id, String plate, PermitStatus status, List<PermitItem> permits, {DateTime? bypass}) =>
    VehiclePermits(
      vehicleId: id,
      plate: plate,
      label: 'Grey Testmake $id',
      status: status,
      permits: permits,
      bypassUntil: bypass,
      joinedAt: DateTime.now().subtract(const Duration(days: 3)),
      countries: const ['Testland'],
    );

void main() {
  setUp(() => deviceDateCountry = () => 'MY');

  for (final brightness in Brightness.values) {
    group(brightness.name, () {
      testWidgets('the passenger opens the permit: every field in English with the local label', (tester) async {
        await _pump(tester, RidePermitButton(ride: _ride('accepted')), brightness: brightness, overrides: [
          ridePermitsProvider('ride-1').overrideWith((ref) async => VehiclePermits(permits: [_evp])),
        ]);
        expect(find.text('Vehicle permit'), findsOneWidget);
        await tester.tap(find.descendant(of: find.byKey(const ValueKey('ride-permit-button')), matching: find.byType(OutlinedButton)));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('permit-sheet')), findsOneWidget);
        for (final (en, ms) in [
          ('Permit Reference No. (Primary)', 'No. Rujukan Permit (Induk)'),
          ('Permit Reference No. (Sub)', 'No. Rujukan Permit (Sub)'),
          ('Permit Effective Date', 'Tarikh Mula Kuatkuasa Permit'),
          ('Permit Valid Until', 'Tarikh Sahlaku Permit Sehingga'),
        ]) {
          expect(find.text(en), findsOneWidget);
          expect(find.text(ms), findsOneWidget);
        }
        expect(find.text('TE-TST1234'), findsOneWidget);
        expect(find.text('04/07/2027'), findsOneWidget);
        expect(find.text('View permit'), findsOneWidget);
        expect(find.text('TST 1234'), findsOneWidget);
      });

      testWidgets('a taxi ride shows both permits behind "Permits"', (tester) async {
        await _pump(tester, RidePermitButton(ride: _ride('on_trip')), brightness: brightness, overrides: [
          ridePermitsProvider('ride-1').overrideWith((ref) async => VehiclePermits(permits: [_evp, _taxi])),
        ]);
        expect(find.text('Permits'), findsOneWidget);
        await tester.tap(find.descendant(of: find.byKey(const ValueKey('ride-permit-button')), matching: find.byType(OutlinedButton)));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('permit-box-evp')), findsOneWidget);
        expect(find.byKey(const ValueKey('permit-box-taxi')), findsOneWidget);
        expect(find.text('View permit'), findsNWidgets(2));
      });

      testWidgets('no button on bypass, on an offer or after the trip', (tester) async {
        await _pump(tester, RidePermitButton(ride: _ride('arrived')), brightness: brightness, overrides: [
          ridePermitsProvider('ride-1').overrideWith((ref) async => const VehiclePermits()),
        ]);
        expect(find.byKey(const ValueKey('ride-permit-button')), findsNothing);
        for (final status in ['open', 'completed']) {
          await _pump(tester, RidePermitButton(ride: _ride(status)), brightness: brightness, overrides: [
            ridePermitsProvider('ride-1').overrideWith((ref) async => VehiclePermits(permits: [_evp])),
          ]);
          expect(find.byKey(const ValueKey('ride-permit-button')), findsNothing, reason: status);
        }
      });

      testWidgets("the driver's banners: expiring, and expired where permits are required", (tester) async {
        final today = DateTime(2026, 10, 20);
        final expiring = PermitItem(
          typeId: 'evp', name: 'Sample vehicle permit', issuer: 'Sample Agency', state: 'with',
          validUntil: DateTime(2026, 11, 9), warnDays: 45, required: true, enforce: true,
          renewalText: 'GET.ride is renewing it with {issuer}.', fields: _evp.fields,
        );
        await _pump(
          tester,
          MyPermitsBody(
            today: today,
            my: MyPermits(vehicles: [
              VehiclePermits(vehicleId: 'v1', plate: 'TST 1234', label: 'Silver Testmake Alpha', active: true,
                  status: PermitStatus.withPermit, permits: [expiring]),
            ]),
          ),
          brightness: brightness,
        );
        expect(find.text('Your Sample vehicle permit expires on 09/11/2026.'), findsOneWidget);
        expect(find.text('GET.ride is renewing it with Sample Agency. The new permit will appear here.'), findsOneWidget);
        expect(find.text('Expires in 20 days'), findsOneWidget);
        expect(find.text('Upload permit'), findsNothing, reason: 'the driver never uploads it');

        final expired = PermitItem(
          typeId: 'evp', name: 'Sample vehicle permit', issuer: 'Sample Agency', state: 'expired',
          validUntil: DateTime(2026, 10, 4), required: true, enforce: true,
          renewalText: 'GET.ride is renewing it with {issuer}.',
        );
        await _pump(
          tester,
          MyPermitsBody(
            today: today,
            my: MyPermits(vehicles: [
              VehiclePermits(vehicleId: 'v1', plate: 'TST 1234', active: true, status: PermitStatus.expired, permits: [expired]),
            ]),
          ),
          brightness: brightness,
        );
        expect(find.text("Sample vehicle permit expired: you can't go online for rides with TST 1234."), findsOneWidget);
        expect(find.byKey(const ValueKey('permit-contact-support')), findsOneWidget);
        expect(find.text('Permit expired'), findsOneWidget);
      });

      testWidgets('a vehicle on bypass: the temporary pass, no permit to passengers', (tester) async {
        final until = DateTime.now().add(const Duration(days: 2));
        await _pump(
          tester,
          MyPermitsBody(
            today: DateTime.now(),
            my: MyPermits(vehicles: [
              VehiclePermits(vehicleId: 'v1', plate: 'TST 1234', active: true, status: PermitStatus.bypass, bypassUntil: until,
                  permits: [PermitItem(typeId: 'evp', name: 'Sample vehicle permit', state: 'without', required: true, enforce: true)]),
            ]),
          ),
          brightness: brightness,
        );
        expect(find.textContaining('Temporary pass until'), findsOneWidget);
        expect(find.byKey(const ValueKey('permit-contact-support')), findsNothing);
      });

      testWidgets("the admin's list: tabs with counts, bypass and upload", (tester) async {
        final repo = _FakeRepo();
        final type = PermitType(id: 'evp', country: 'Testland', key: 'evp', name: 'Sample vehicle permit', required: true);
        final missing = PermitItem(typeId: 'evp', name: 'Sample vehicle permit', state: 'without', required: true);
        final vehicles = [
          _vehicle('v1', 'TST 1', PermitStatus.withPermit,
              [PermitItem(typeId: 'evp', name: 'Sample vehicle permit', validUntil: DateTime(2030, 1, 1), required: true)]),
          _vehicle('v2', 'TST 2', PermitStatus.without, [missing]),
          _vehicle('v3', 'TST 3', PermitStatus.bypass, [missing], bypass: DateTime.now().add(const Duration(days: 2))),
          _vehicle('v4', 'TST 4', PermitStatus.expired,
              [PermitItem(typeId: 'evp', name: 'Sample vehicle permit', state: 'expired', required: true, enforce: true)]),
        ];
        await _pump(tester, const VehiclePermitsScreen(), brightness: brightness, overrides: [
          adminAccessProvider.overrideWith((_) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
          permitsRepositoryProvider.overrideWithValue(repo),
          adminPermitTypesProvider.overrideWith((ref) async => [type]),
          adminPermitCountriesProvider.overrideWith((ref) async => ['Testland']),
          adminPermitSettingsProvider.overrideWith((ref) async => [
            const PermitCountrySettings(country: 'Testland', bypassDays: 3),
          ]),
          adminPermitVehiclesProvider('Testland').overrideWith((ref) async => vehicles),
        ]);
        expect(find.text('With permit (1)'), findsOneWidget);
        expect(find.text('Without (1)'), findsOneWidget);
        expect(find.text('Bypass (1)'), findsOneWidget);
        expect(find.text('Expired (1)'), findsOneWidget);
        expect(find.text('Require vehicle permits'), findsOneWidget);
        expect(find.text('Expiry reminders'), findsOneWidget);

        // Without: Bypass 3 days and Upload permit.
        expect(find.text('TST 2'), findsOneWidget);
        expect(find.text('joined 3 days ago'), findsOneWidget);
        expect(find.byKey(const ValueKey('permit-upload-v2')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('permit-bypass-v2')));
        await tester.pumpAndSettle();
        expect(repo.bypasses, [('v2', true)]);
        expect(find.text('Bypass 3 days'), findsOneWidget);

        await closeNotice(tester);
        await tester.tap(find.byKey(const ValueKey('permit-tab-bypass')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('permit-end-bypass-v3')));
        await tester.pumpAndSettle();
        expect(repo.bypasses.last, ('v3', false));

        await closeAnyNotice(tester);
        await tester.tap(find.byKey(const ValueKey('permit-tab-expired')));
        await tester.pumpAndSettle();
        expect(find.textContaining('cannot take rides'), findsOneWidget);
        expect(find.byKey(const ValueKey('permit-bypass-v4')), findsOneWidget);

        await closeAnyNotice(tester);
        await tester.tap(find.byKey(const ValueKey('permit-tab-with')));
        await tester.pumpAndSettle();
        expect(find.text('valid until 01/01/2030'), findsOneWidget);
        expect(find.byKey(const ValueKey('permit-bypass-v1')), findsNothing);
        expect(find.text('Upload new'), findsOneWidget);
      });

      testWidgets('expiry reminders: edit the default, add and remove days', (tester) async {
        final saved = <(ReminderScope, String, List<int>)>[];
        await _pump(
          tester,
          ExpiryRemindersEditor(
            rows: const [
              ReminderDays(scope: ReminderScope.defaultDays, days: [45, 30, 15, 3, 1]),
              ReminderDays(scope: ReminderScope.country, scopeKey: 'Testland', days: [60, 7]),
            ],
            countries: const ['Testland'],
            onSave: (s, k, d) async {
              saved.add((s, k, d));
              return true;
            },
          ),
          brightness: brightness,
        );
        expect(find.text('45, 30, 15, 3, 1 days before'), findsOneWidget);
        expect(find.text('Country · 60, 7 days before'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('reminder-default')));
        await tester.pumpAndSettle();
        await tester.tap(find.descendant(of: find.byKey(const ValueKey('reminder-day-1')), matching: find.byType(Icon)).last);
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('reminder-day-input')), '60');
        await tester.tap(find.byKey(const ValueKey('reminder-day-add')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reminder-days-save')));
        await tester.pumpAndSettle();
        expect(saved.single.$1, ReminderScope.defaultDays);
        expect(saved.single.$3, [60, 45, 30, 15, 3]);

        await tester.tap(find.byKey(const ValueKey('reminder-remove-country-Testland')));
        await tester.pumpAndSettle();
        expect((saved.last.$1, saved.last.$2), (ReminderScope.country, 'Testland'));
        expect(saved.last.$3, isEmpty);
      });
    });
  }
}
