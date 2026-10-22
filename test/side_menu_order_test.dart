// New built-in rows the admin's saved order doesn't name stay together after
// the row they follow, never after Logout.
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/display_logic.dart';
import 'package:get_ride/src/core/side_menu.dart';

void main() {
  test('a run of new services follows Freight and Logout stays last', () {
    // The live order from before the services were built in.
    const saved = [
      'teksi-ev', 'city', 'request-history', 'freight', 'scheduled-rides', 'wallet', 'notifications', 'safety',
      'settings', 'user-guide', 'support', 'my-ride', 'my-qr', 'help-assistant', 'invite-friends',
      'emergency-contacts', 'logout',
    ];
    final ids = [
      for (final e in resolveSideMenu({
        'userMenu': {'order': saved},
      }, 'user'))
        e.id,
    ];
    expect(ids.last, 'logout');
    final at = ids.indexOf('freight');
    expect(ids.sublist(at + 1, at + 1 + serviceMenuItemIds.length), [
      for (final (id, _) in defaultUserMenuItems)
        if (serviceMenuItemIds.contains(id)) id,
    ]);
  });
}
