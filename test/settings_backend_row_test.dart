// Settings → Backend (which server the app talks to) is for admins only.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/features/settings/settings_screen.dart';

void main() {
  Future<void> pump(WidgetTester tester, AdminAccess access, {ThemeData? theme}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [adminAccessProvider.overrideWith((_) async => access)],
        child: MaterialApp(
          theme: theme,
          home: const Scaffold(body: BackendSettingsTile()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Finder backend() => find.byKey(const ValueKey('settings-backend'));

  testWidgets('an admin sees it', (tester) async {
    await pump(tester, const AdminAccess([AdminGrant(page: '*', edit: true)]));
    expect(backend(), findsOneWidget);
    expect(find.textContaining('supabase.co'), findsOneWidget);
  });

  testWidgets('a rider or driver does not (dark too)', (tester) async {
    await pump(tester, AdminAccess.none, theme: ThemeData.dark());
    expect(backend(), findsNothing);
    expect(find.text('Backend'), findsNothing);
  });
}
