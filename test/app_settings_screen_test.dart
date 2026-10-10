import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/data/live_tables.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/meterapp/branding_screens.dart';
import 'package:get_ride/src/admin/screens/meterapp/meterapp_module.dart';
import 'package:get_ride/src/admin/screens/meterapp/site_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// No token refresh: its timer would outlive the test.
final _db = SupabaseClient(
  'http://localhost',
  'anon',
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);

class _FakeStore extends BrandingStore {
  _FakeStore() : super(_db);
  final patches = <Map<String, dynamic>>[];

  @override
  Future<void> update(Map<String, dynamic> patch) async => patches.add(patch);
}

void main() {
  testWidgets('one page: icon, splash, theme and start location, saved for everyone', (tester) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = _FakeStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseProvider.overrideWithValue(_db),
          // No realtime socket in a test.
          liveTablesProvider.overrideWith(_QuietLive.new),
          adminAccessProvider.overrideWith((_) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
          brandingStoreProvider.overrideWithValue(store),
          brandingProvider.overrideWith(
            (_) async => {
              'id': 'global',
              'splash_bg_dark': '#222222',
              'theme': {
                'light': {'accent': '#FF0000'},
              },
              'start_lat': 1.5,
              'start_lng': 103.7,
            },
          ),
        ],
        child: const MaterialApp(home: AdminSiteSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    for (final section in ['App Icon', 'Splash Screen', 'Theme Colors', 'Default Start Location']) {
      expect(find.text(section), findsOneWidget);
    }
    // What is stored is what the form opens with.
    TextField field(String key) => tester.widget<TextField>(find.byKey(ValueKey('app-settings-$key')));
    expect(field('splash.dark').controller!.text, '#222222');
    expect(field('light.accent').controller!.text, '#FF0000');
    expect(field('startLat').controller!.text, '1.5');
    // The splash previews draw on the backgrounds: the dark one as stored.
    final splashes = tester.widgetList<Container>(find.byKey(const ValueKey('splash'))).toList();
    expect(splashes.map((c) => c.color), [const Color(0xFFFFFFFF), const Color(0xFF222222)]);

    await tester.enterText(find.byKey(const ValueKey('app-settings-light.text')), '#333333');
    await tester.enterText(find.byKey(const ValueKey('app-settings-splash.light')), '#2DABE2');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('app-settings-save')));
    await tester.pumpAndSettle();
    expect(store.patches, hasLength(1));
    expect(store.patches.single, {
      'splash_bg_light': '#2DABE2',
      'splash_bg_dark': '#222222',
      'theme': {
        'light': {'accent': '#FF0000', 'text': '#333333'},
        'dark': <String, String>{},
      },
      'start_lat': 1.5,
      'start_lng': 103.7,
      'splash_image_url': null,
    });

    // A bad colour is refused before anything is written.
    await tester.enterText(find.byKey(const ValueKey('app-settings-light.text')), 'grey');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('app-settings-save')));
    await tester.pumpAndSettle();
    expect(store.patches, hasLength(1));
    expect(find.text('Invalid Light Text colour'), findsOneWidget);
  });

  test('App Icon and Splash Screen are one entry now, and their access carries over', () {
    final titles = meterappEntries.map((e) => e.title).toList();
    expect(titles, contains('App Settings'));
    expect(titles, isNot(contains('App Icon')));
    expect(titles, isNot(contains('Splash Screen')));
    final site = meterappEntries.firstWhere((e) => e.path == '/admin/m/site');
    expect(site.pages, containsAll(['admin-settings-site', 'admin-settings-app-icon', 'admin-settings-splash']));
  });
}

class _QuietLive extends LiveTables {
  @override
  Map<String, int> build() => const {};
}
