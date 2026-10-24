// Admin → Display → Sign-in Screen: new passenger and new driver sign-up,
// each its own switch (migration 0287), written so apps that only know the
// old single switch still close when both are off.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_screen.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_store.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/app_display.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _FakeStore implements DisplaySettingsStore {
  _FakeStore(Map<String, dynamic> raw) : blob = mergeDisplaySettings(raw);
  Map<String, dynamic> blob;

  @override
  Future<Map<String, dynamic>> fetch() async => blob;

  @override
  Future<Map<String, dynamic>> update(DisplayEdit edit) async => blob = edit(blob);

  @override
  Future<List<Map<String, dynamic>>> entries(String category) async => const [];
}

void main() {
  group('registrationOpen / setRegistrationOpen', () {
    test('missing keys are open; the old switch off closes both', () {
      expect(registrationOpen(const {}, 'passenger'), isTrue);
      expect(registrationOpen(const {}, 'driver'), isTrue);
      expect(registrationOpen(const {'registrationEnabled': false}, 'driver'), isFalse);
      expect(registrationOpen(const {'driverRegistrationEnabled': false}, 'passenger'), isTrue);
    });

    test('one switch keeps the other; the old one is written as "either is open"', () {
      var s = setRegistrationOpen(const {}, 'passenger', false);
      expect(s, {'passengerRegistrationEnabled': false, 'driverRegistrationEnabled': true, 'registrationEnabled': true});
      s = setRegistrationOpen(s, 'driver', false);
      expect(s['registrationEnabled'], isFalse, reason: 'both off: older apps close too');
      expect(AppDisplay.fromSettings(s).anySignUpOpen, isFalse);
      s = setRegistrationOpen(s, 'driver', true);
      expect(s, {'passengerRegistrationEnabled': false, 'driverRegistrationEnabled': true, 'registrationEnabled': true});
      final d = AppDisplay.fromSettings(s);
      expect([d.passengerSignUpOpen, d.driverSignUpOpen], [false, true]);
      // Turning one on from the old closed state opens only that one.
      final fromOld = setRegistrationOpen(const {'registrationEnabled': false}, 'passenger', true);
      expect(AppDisplay.fromSettings(fromOld).passengerSignUpOpen, isTrue);
      expect(AppDisplay.fromSettings(fromOld).driverSignUpOpen, isFalse);
    });
  });

  for (final b in Brightness.values) {
    testWidgets('the two switches on the Display page (${b.name})', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = _FakeStore(const {});
      await tester.pumpWidget(ProviderScope(
        retry: (_, _) => null,
        overrides: [
          supabaseProvider.overrideWithValue(_db),
          pageAccessProvider.overrideWith((ref, page) => AccessLevel.edit),
          displayStoreProvider.overrideWithValue(store),
        ],
        child: MaterialApp(theme: appTheme(b), home: const AdminDisplaySettingsScreen()),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Allow new registrations'), findsNothing);
      final passenger = find.byKey(const ValueKey('display-passenger-registration'));
      final driver = find.byKey(const ValueKey('display-driver-registration'));
      await tester.scrollUntilVisible(driver, 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('New passenger sign-up'), findsOneWidget);
      expect(find.text('New driver (partner) sign-up'), findsOneWidget);

      await tester.ensureVisible(passenger);
      await tester.pumpAndSettle();
      await tester.tap(passenger);
      await tester.pumpAndSettle();
      expect(store.blob['passengerRegistrationEnabled'], isFalse);
      expect(store.blob['registrationEnabled'], isTrue);
      await tester.ensureVisible(driver);
      await tester.pumpAndSettle();
      await tester.tap(driver);
      await tester.pumpAndSettle();
      expect(store.blob['driverRegistrationEnabled'], isFalse);
      expect(store.blob['registrationEnabled'], isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
    });
  }
}
