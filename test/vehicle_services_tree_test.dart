// Vehicle Services → Under: a vehicle service under another, to any depth
// (core/service_tree.dart), never under itself or what is under it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/admin_settings_models.dart';
import 'package:get_ride/src/admin/screens/catalogue/catalogue_logic.dart';
import 'package:get_ride/src/admin/screens/catalogue/services_screens.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

Map<String, dynamic> _v(String name, {List<String> parents = const []}) => {
  'name': name,
  'costPerKm': 1,
  'costPerMin': 0.2,
  'minFareAmount': 5,
  'status': true,
  'serviceTypes': ['Car'],
  'parentServices': parents,
};

final _entries = [
  SettingEntry(id: 'ride', values: _v('Ride')),
  SettingEntry(
    id: 'ride-xl',
    values: _v('Ride XL', parents: ['ride']),
  ),
  SettingEntry(
    id: 'ride-xl-pet',
    values: _v('Ride XL Pet', parents: ['ride-xl']),
  ),
  SettingEntry(id: 'comfort', values: _v('Comfort')),
];

class _Admin extends AdminRepository {
  _Admin() : super(_db);
  final saved = <({String? id, Map<String, dynamic> values})>[];

  @override
  Future<List<SettingEntry>> settings(SettingsCategory c) async => switch (c.key) {
    'vehicle-services' => _entries,
    'service-settings' => [
      SettingEntry(id: 'car', values: {'name': 'Car'}),
    ],
    _ => [],
  };

  @override
  Future<void> saveSetting(
    SettingsCategory c, {
    String? id,
    required Map<String, dynamic> values,
    int? position,
  }) async => saved.add((id: id, values: values));
}

void main() {
  test('the choices leave out itself and everything under it', () {
    List<String> ids(String? self) => [for (final o in parentServiceOptions(_entries, self)) o.id];
    expect(ids('ride'), ['comfort'], reason: 'Ride XL and Ride XL Pet are under Ride');
    expect(ids('ride-xl'), ['ride', 'comfort']);
    expect(ids(null), ['ride', 'ride-xl', 'ride-xl-pet', 'comfort']);
  });

  for (final brightness in Brightness.values) {
    testWidgets('Under: picked, saved as parentServices (${brightness.name})', (tester) async {
      final admin = _Admin();
      await tester.binding.setSurfaceSize(const Size(1280, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            supabaseProvider.overrideWithValue(_db),
            adminAccessProvider.overrideWith((_) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
            adminRepositoryProvider.overrideWithValue(admin),
          ],
          child: MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: const VehicleServicesScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ride XL').first);
      await tester.pumpAndSettle();

      final ride = find.byKey(const ValueKey('vs-parent-ride'));
      await tester.ensureVisible(ride);
      expect(tester.widget<FilterChip>(ride).selected, isTrue);
      expect(find.byKey(const ValueKey('vs-parent-ride-xl-pet')), findsNothing, reason: 'under Ride XL itself');
      expect(find.byKey(const ValueKey('vs-parent-ride-xl')), findsNothing, reason: 'not under itself');

      await tester.tap(find.byKey(const ValueKey('vs-parent-comfort')));
      await tester.pumpAndSettle();
      final save = find.text('Save changes');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(admin.saved.single.values['parentServices'], ['ride', 'comfort']);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
    });
  }
}
