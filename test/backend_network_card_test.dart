import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/screens/meterapp/backend_network_card.dart';
import 'package:get_ride/src/admin/screens/meterapp/branding_screens.dart';
import 'package:get_ride/src/core/backend_network.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// No token refresh: its timer would outlive the test.
final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

class _FakeStore extends BrandingStore {
  _FakeStore() : super(_db);
  final patches = <Map<String, dynamic>>[];

  @override
  Future<void> update(Map<String, dynamic> patch) async => patches.add(patch);
}

void main() {
  Future<_FakeStore> pump(WidgetTester tester, BackendNetwork stored) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = _FakeStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [supabaseProvider.overrideWithValue(_db), brandingStoreProvider.overrideWithValue(store)],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: BackendNetworkCard(stored: stored, canEdit: true)),
          ),
        ),
      ),
    );
    return store;
  }

  Finder inRow(String level, String key) =>
      find.descendant(of: find.byKey(ValueKey('backend-route-$level')), matching: find.byKey(ValueKey(key)));

  testWidgets('routes are switched off and reordered, and saved in that order', (tester) async {
    final store = await pump(tester, BackendNetwork.none);
    expect(find.text('Fallback order at launch'), findsOneWidget);
    // Default: own address, extra addresses, api.getride.my.
    expect(tester.widget<IconButton>(inRow('device', 'up')).onPressed, isNull);

    await tester.tap(inRow('builtin', 'up'));
    await tester.pump();
    await tester.tap(inRow('builtin', 'up'));
    await tester.pump();
    await tester.tap(inRow('extra', 'on'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('backend-network-save')));
    await tester.pumpAndSettle();
    expect(store.patches.single, {
      'network': {
        'order': ['builtin', 'device'],
      },
    });
  });

  testWidgets('a stored order is shown, and nothing switched on is refused', (tester) async {
    final store = await pump(tester, const BackendNetwork(order: [BackendRouteLevel.extra]));
    expect(tester.widget<Checkbox>(inRow('extra', 'on')).value, isTrue);
    expect(tester.widget<Checkbox>(inRow('device', 'on')).value, isFalse);

    await tester.tap(inRow('extra', 'on'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('backend-network-save')));
    await tester.pumpAndSettle();
    expect(store.patches, isEmpty);
    expect(find.textContaining('at least one route'), findsOneWidget);
  });
}
