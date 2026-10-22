// Admin › Display Settings › Side Menu: every item's icon can be changed,
// built-in ones too, and the app draws the admin's pick.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart' show AccessLevel;
import 'package:get_ride/src/admin/admin_providers.dart' show pageAccessProvider;
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_screen.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_store.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/side_menu.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/side_menu_tiles.dart';
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
  test('normalize keeps the icons, like the renames', () {
    final m = normalizeMenu({
      'icons': {'wallet': 'Star', 'bad': 3, 'empty': ' '},
    });
    expect(m['icons'], {'wallet': 'Star'});
    expect(normalizeMenu(null)['icons'], isEmpty);
    expect(emptyMenu()['icons'], isEmpty);
  });

  test('setMenuItemIcon sets and clears a built-in item, and changes a custom one', () {
    var s = defaultDisplaySettings();
    s = setMenuItemIcon(s, 'user', 'wallet', 'Gift');
    expect(menuOf(s, 'user')['icons'], {'wallet': 'Gift'});
    s = setMenuItemIcon(s, 'user', 'wallet', null);
    expect(menuOf(s, 'user')['icons'], isEmpty);

    s = addCustomMenuItem(s, 'partner', 'Promos', 'Gift', null, id: 'custom-1');
    s = setMenuItemIcon(s, 'partner', 'custom-1', 'Coffee');
    expect((menuOf(s, 'partner')['customItems'] as List).single['iconName'], 'Coffee');
    expect(menuOf(s, 'partner')['icons'], isEmpty, reason: 'a custom item keeps its icon on itself');
    s = setMenuItemIcon(s, 'partner', 'custom-1', null);
    expect((menuOf(s, 'partner')['customItems'] as List).single['iconName'], 'Star');
  });

  test('resolveSideMenu passes the override, and menuIcon draws it', () {
    final menu = resolveSideMenu({
      'userMenu': {
        'icons': {'wallet': 'Gift'},
      },
    }, 'user');
    final wallet = menu.firstWhere((e) => e.id == 'wallet');
    expect(wallet.iconName, 'Gift');
    expect(menuIcon(wallet), Icons.card_giftcard);
    final settings = menu.firstWhere((e) => e.id == 'settings');
    expect(settings.iconName, isNull);
    expect(menuIcon(settings), Icons.settings_outlined, reason: 'the built-in icon without an override');
  });

  test('every icon the admin can pick has a picture, in the app and the admin', () {
    for (final n in sideMenuIcons) {
      final icon = menuIcon(MenuEntry(id: 'x', label: 'x', custom: true, iconName: n));
      expect(n == 'Star' || icon != Icons.star_border, isTrue, reason: '$n in the app');
      expect(lucideIcons.containsKey(n), isTrue, reason: '$n in the admin');
    }
  });

  for (final b in Brightness.values) {
    testWidgets('editing a built-in item picks its icon, and Default icon puts it back (${b.name})', (tester) async {
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
        child: MaterialApp(theme: appTheme(b), home: const SideMenuEditorScreen(menu: 'user')),
      ));
      await tester.pumpAndSettle();

      // The Edit button spins while its dialog is open: pump, not settle.
      Future<void> settle() async {
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Future<void> openEdit() async {
        final card = find.ancestor(of: find.text('Book TEKSI EV'), matching: find.byType(Card));
        await tester.tap(find.descendant(of: card, matching: find.byTooltip('Edit')));
        await settle();
      }

      bool selected(String key) => tester.widget<ChoiceChip>(find.byKey(ValueKey(key))).selected;

      await openEdit();
      expect(find.text('Icon'), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-icon-search')), findsOneWidget, reason: 'a long list gets a search box');
      expect(selected('menu-icon-default'), isTrue);
      expect(selected('menu-icon-Car'), isTrue, reason: 'its own icon, preselected');

      await tester.enterText(find.byKey(const ValueKey('menu-icon-search')), 'gif');
      await settle();
      expect(find.byKey(const ValueKey('menu-icon-Car')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('menu-icon-Gift')));
      await settle();
      await tester.tap(find.text('Save'));
      await settle();
      expect(menuOf(store.blob, 'user')['icons'], {'teksi-ev': 'Gift'});
      final card = find.ancestor(of: find.text('Book TEKSI EV'), matching: find.byType(Card));
      expect(find.descendant(of: card, matching: find.byIcon(Icons.card_giftcard)), findsOneWidget,
          reason: 'the row shows the new icon');

      await openEdit();
      expect(selected('menu-icon-Gift'), isTrue);
      expect(selected('menu-icon-default'), isFalse);
      await tester.tap(find.byKey(const ValueKey('menu-icon-default')));
      await settle();
      await tester.tap(find.text('Save'));
      await settle();
      expect(menuOf(store.blob, 'user')['icons'], isEmpty);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
    });
  }
}
