// Media Gallery → App icon and Splash: the current values from App Settings
// (the app_branding row), the built-in home-screen icons with which is in
// use, and Choose from gallery only for admins who can edit App Settings.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/meterapp/branding_screens.dart' show brandingProvider;
import 'package:get_ride/src/admin/screens/meterapp/media_gallery_screen.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/media_usage.dart';

Future<void> _pump(
  WidgetTester tester, {
  required Map<String, dynamic> branding,
  List<AdminGrant> grants = const [AdminGrant(page: '*', edit: true)],
  Brightness b = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      mediaGalleryProvider.overrideWith((ref) async => MediaGalleryData(
        usage: mediaUsageIndex(const MediaUsageInput(appSettings: [
          {'key': 'app_icon', 'value': {'automatic': false, 'fixed_icon': 'g_dot'}},
        ])),
      )),
      brandingProvider.overrideWith((ref) async => branding),
      adminAccessProvider.overrideWith((ref) async => AdminAccess(grants)),
    ],
    child: MaterialApp(theme: appTheme(b), home: const AdminMediaGalleryScreen()),
  ));
  await tester.pumpAndSettle();
}

Finder _key(String k) => find.byKey(ValueKey(k));

void main() {
  for (final b in Brightness.values) {
    testWidgets('App icon: the built-in one, and which home-screen icon is in use (${b.name})', (tester) async {
      await _pump(tester, branding: const {}, b: b);
      await tester.tap(_key('media-tab-app-icon'));
      await tester.pumpAndSettle();
      expect(_key('media-app-icon-tab'), findsOneWidget);
      expect(_key('media-app-icon-builtin'), findsOneWidget);
      expect(find.text('Built-in GET.ride icon'), findsOneWidget);
      expect(_key('media-app-icon-choose'), findsOneWidget);
      expect(_key('media-app-icon-default'), findsNothing);
      final gDot = find.descendant(of: _key('media-home-icon-g_dot'), matching: find.text('In use'));
      expect(gDot, findsOneWidget);
      expect(find.descendant(of: _key('media-home-icon-christmas'), matching: find.text('Unused')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Splash: the current picture state, choose or remove (${b.name})', (tester) async {
      await _pump(tester, branding: const {'splash_image_url': 'https://x.supabase.co/storage/v1/object/public/media/image/a.webp'}, b: b);
      await tester.tap(_key('media-tab-splash'));
      await tester.pumpAndSettle();
      expect(_key('media-splash-tab'), findsOneWidget);
      expect(tester.widget<Text>(_key('media-splash-state')).data, 'Picture set');
      expect(_key('media-splash-choose'), findsOneWidget);
      expect(_key('media-splash-clear'), findsOneWidget);
    });
  }

  testWidgets('an uploaded app icon shows; only App Settings editors may change it', (tester) async {
    await _pump(
      tester,
      branding: const {'app_icon_url': 'https://x.supabase.co/storage/v1/object/public/media/logo/b.png'},
      grants: const [AdminGrant(page: 'admin-settings-display', edit: true)],
    );
    await tester.tap(_key('media-tab-app-icon'));
    await tester.pumpAndSettle();
    expect(_key('media-app-icon-current'), findsOneWidget);
    expect(_key('media-app-icon-choose'), findsNothing);
    expect(find.text('Only admins who can edit App Settings can change it.'), findsOneWidget);
  });
}
