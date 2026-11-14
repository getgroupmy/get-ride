// The navigation rail is a second nav surface (NavKind.rail): it reuses the
// side-menu editor logic and resolver over its own userRail / partnerRail
// config, told apart by the kind. These pin the rail defaults, that edits
// land on the rail slot (never the menu), and the two stay isolated.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/core/side_menu.dart';

void main() {
  const railIds = [railRideId, railTripsId, railWalletId, railDriveId, railAccountId];

  group('rail config key', () {
    test('menuKey routes rails to their own slot', () {
      expect(menuKey('user', kind: NavKind.rail), 'userRail');
      expect(menuKey('partner', kind: NavKind.rail), 'partnerRail');
      // The menu slot is unchanged, with or without the default kind.
      expect(menuKey('user'), 'userMenu');
      expect(menuKey('partner', kind: NavKind.menu), 'partnerMenu');
    });

    test('default / merged blob carries a rail slot for each audience', () {
      for (final key in ['userRail', 'partnerRail']) {
        expect(defaultDisplaySettings()[key], isA<Map>());
        expect(mergeDisplaySettings(const {})[key], isA<Map>());
      }
    });
  });

  group('rail defaults', () {
    test('resolve to the five shell tabs in branch order, unlinked', () {
      for (final audience in ['user', 'partner']) {
        final rail = resolveSideMenu(const {}, audience, kind: NavKind.rail);
        expect(rail.map((e) => e.id), railIds, reason: audience);
        // A built-in rail item keeps its own behaviour (its branch) until the
        // admin relinks it, so no route and not overridden.
        expect(rail.every((e) => e.route == null && !e.overridden && !e.custom), isTrue, reason: audience);
      }
      expect(resolveSideMenu(const {}, 'user', kind: NavKind.rail).map((e) => e.label),
          ['Ride', 'Trips', 'Wallet', 'Drive', 'Account']);
    });

    test('default routes and icons exist for every rail tab', () {
      for (final audience in ['user', 'partner']) {
        for (final id in railIds) {
          expect(defaultNavRoute(audience, NavKind.rail, id), isNotNull, reason: '$audience/$id route');
          expect(defaultNavIconName(audience, NavKind.rail, id), isNotNull, reason: '$audience/$id icon');
        }
      }
      expect(defaultNavRoute('user', NavKind.rail, railDriveId), '/drive');
      expect(defaultNavRoute('user', NavKind.menu, 'wallet'), '/wallet'); // menu lookups still work
    });
  });

  group('edits land on the rail, never the menu', () {
    test('hide, reorder, rename and relink only touch the rail slot', () {
      var s = <String, dynamic>{};
      // Hide Drive on the rail.
      s = setMenuItemVisibility(s, 'user', railDriveId, false, kind: NavKind.rail);
      // Move Account to the top of the rail.
      s = moveMenuItem(s, 'user', railAccountId, -4, kind: NavKind.rail);
      // Rename Ride on the rail.
      s = renameMenuItem(s, 'user', railRideId, 'Book', kind: NavKind.rail);
      // Relink Wallet on the rail.
      s = setMenuItemRoute(s, 'user', railWalletId, '/wallet/history', kind: NavKind.rail);

      final rail = resolveSideMenu(s, 'user', kind: NavKind.rail);
      final ids = rail.map((e) => e.id).toList();
      expect(ids, isNot(contains(railDriveId)), reason: 'hidden');
      expect(ids.first, railAccountId, reason: 'moved to top');
      expect(rail.firstWhere((e) => e.id == railRideId).label, 'Book');
      // Relinking marks the item overridden (its route no longer the branch).
      expect(rail.firstWhere((e) => e.id == railWalletId).overridden, isTrue);

      // The side menu is untouched by every rail edit above.
      expect(s['userMenu'], anyOf(isNull, equals(emptyMenu())));
      final menu = resolveSideMenu(s, 'user');
      expect(menu.map((e) => e.id), defaultUserMenuItems.map((e) => e.$1));
    });

    test('a custom rail item shows on the rail only', () {
      var s = <String, dynamic>{};
      s = addCustomMenuItem(s, 'user', 'Promos', 'Gift', '/wallet/plus', id: 'rail-c1', kind: NavKind.rail);
      final rail = resolveSideMenu(s, 'user', kind: NavKind.rail);
      final custom = rail.where((e) => e.custom).toList();
      expect(custom.map((e) => e.label), ['Promos']);
      // Not on the side menu, and not on the partner rail.
      expect(resolveSideMenu(s, 'user').where((e) => e.custom), isEmpty);
      expect(resolveSideMenu(s, 'partner', kind: NavKind.rail).where((e) => e.custom), isEmpty);
    });

    test('the user rail and the partner rail are independent', () {
      var s = <String, dynamic>{};
      s = setMenuItemVisibility(s, 'user', railTripsId, false, kind: NavKind.rail);
      // Partner rail still has Trips; user rail does not.
      expect(resolveSideMenu(s, 'partner', kind: NavKind.rail).map((e) => e.id), contains(railTripsId));
      expect(resolveSideMenu(s, 'user', kind: NavKind.rail).map((e) => e.id), isNot(contains(railTripsId)));
    });
  });

  test('editing the menu does not disturb the rail', () {
    var s = <String, dynamic>{};
    s = setMenuItemVisibility(s, 'user', 'wallet', false); // menu edit (default kind)
    // The rail resolves to its full default set, unaffected.
    expect(resolveSideMenu(s, 'user', kind: NavKind.rail).map((e) => e.id), railIds);
  });
}
