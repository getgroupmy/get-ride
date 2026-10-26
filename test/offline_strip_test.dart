// "You're offline. Showing saved data." over the pages that show what was
// last read, while the app knows it can't reach GET.ride, from what it
// already hears (the live channel, the launch check), light and dark.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/app.dart' show appTheme;
import 'package:get_ride/src/core/inbox.dart';
import 'package:get_ride/src/data/app_connection.dart';
import 'package:get_ride/src/data/timeout_http_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:get_ride/src/data/models.dart';
import 'package:get_ride/src/data/notifications_repository.dart';
import 'package:get_ride/src/features/notifications/notifications_screen.dart';
import 'package:get_ride/src/features/wallet/wallet_screen.dart';
import 'package:get_ride/src/providers.dart';
import 'package:get_ride/src/widgets/offline_strip.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeSubscribeStatus;

class _Offline extends AppOffline {
  _Offline(this.start);
  final bool start;
  @override
  bool build() => start;
}

Future<ProviderContainer> _pump(WidgetTester tester, Widget home, {required bool offline, Brightness b = Brightness.light}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 915);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appOfflineProvider.overrideWith(() => _Offline(offline)),
        walletBalancesProvider.overrideWith((ref) async => [WalletBalance('get_wallet', 0, 'MYR')]),
        walletTxProvider.overrideWith((ref) async => const <WalletTransaction>[]),
        partnerProvider.overrideWith((ref) async => null),
        notificationsProvider.overrideWith((ref) => Stream.value(const <InboxItem>[])),
      ],
      child: MaterialApp(theme: appTheme(b), home: home),
    ),
  );
  await tester.pump();
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

void main() {
  test('the live channel only ever says online; a channel error alone is not offline', () {
    expect(offlineFromRealtime(RealtimeSubscribeStatus.channelError), isNull, reason: 'WebSockets blocked, REST fine');
    expect(offlineFromRealtime(RealtimeSubscribeStatus.timedOut), isNull);
    expect(offlineFromRealtime(RealtimeSubscribeStatus.subscribed), isFalse);
    expect(offlineFromRealtime(RealtimeSubscribeStatus.closed), isNull, reason: 'closed on purpose says nothing');

    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(appOfflineProvider), isFalse, reason: 'unknown is not offline');
    c.read(appOfflineProvider.notifier).realtime(RealtimeSubscribeStatus.channelError);
    expect(c.read(appOfflineProvider), isFalse);
    c.read(appOfflineProvider.notifier).reachable(false);
    expect(c.read(appOfflineProvider), isTrue, reason: 'the launch check found no server');
    c.read(appOfflineProvider.notifier).realtime(RealtimeSubscribeStatus.subscribed);
    expect(c.read(appOfflineProvider), isFalse);
  });

  test('requests to the server: an answer is online, no answer is offline', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(appOfflineProvider);
    final fails = TimeoutHttpClient(MockClient((_) async => throw http.ClientException('no route')));
    final works = TimeoutHttpClient(MockClient((_) async => http.Response('[]', 401)));
    await expectLater(fails.get(Uri.parse('https://example.test/rest/v1/x')), throwsA(isA<http.ClientException>()));
    expect(c.read(appOfflineProvider), isTrue);
    await works.get(Uri.parse('https://example.test/rest/v1/x'));
    expect(c.read(appOfflineProvider), isFalse, reason: 'any answer, even an error status, means the server is there');
  });

  for (final b in Brightness.values) {
    testWidgets('Wallet says it is showing saved data while offline, and drops the strip once back (${b.name})',
        (tester) async {
      final c = await _pump(tester, const WalletScreen(), offline: true, b: b);
      expect(find.text(offlineStripText), findsOneWidget);
      final strip = tester.widget<Material>(find.byKey(const ValueKey('offline-strip')));
      final scheme = appTheme(b).colorScheme;
      expect(strip.color, scheme.tertiaryContainer);
      final text = tester.widget<Text>(find.text(offlineStripText));
      expect(text.style?.color, scheme.onTertiaryContainer);
      // The strip sits under the app bar, over the balances.
      expect(
        tester.getRect(find.byKey(const ValueKey('offline-strip'))).top,
        greaterThanOrEqualTo(tester.getRect(find.byType(AppBar)).bottom),
      );

      c.read(appOfflineProvider.notifier).realtime(RealtimeSubscribeStatus.subscribed);
      await tester.pump();
      expect(find.text(offlineStripText), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Notifications shows the strip while offline (${b.name})', (tester) async {
      await _pump(tester, const NotificationsScreen(), offline: true, b: b);
      expect(find.byKey(const ValueKey('offline-strip')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('online, no strip', (tester) async {
    await _pump(tester, const WalletScreen(), offline: false);
    expect(find.byKey(const ValueKey('offline-strip')), findsNothing);
  });
}
