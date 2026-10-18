import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/admin_registry.dart';
import 'package:get_ride/src/admin/screens/messaging_screen.dart';
import 'package:get_ride/src/core/messaging.dart';
import 'package:get_ride/src/core/session_access.dart';
import 'package:get_ride/src/data/messaging_repository.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// No token refresh: its timer would outlive the test.
final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

final _now = DateTime.utc(2026, 10, 9, 12);

MessagingDevice _device(String id, {String kind = 'gateway', List<String> caps = const ['sms'], Duration? ago}) =>
    MessagingDevice(
      id: id,
      userId: 'u1',
      deviceId: 'dev-$id',
      kind: kind,
      label: 'Phone $id',
      capabilities: caps,
      lastSeenAt: ago == null ? null : _now.subtract(ago),
    );

class _FakeRepo extends MessagingRepository {
  _FakeRepo(this._devices, [this._routes = const []]) : super(_db);
  final List<MessagingDevice> _devices;
  final List<MessagingRoute> _routes;
  final saved = <MessagingRoute>[];

  @override
  Future<List<MessagingDevice>> devices() async => _devices;
  @override
  Future<List<MessagingRoute>> routes() async => _routes;
  @override
  Future<void> saveRoute(MessagingRoute r) async => saved.add(r);
  @override
  Future<List<Map<String, dynamic>>> recentOutbox({int limit = 20}) async => const [];
  @override
  Future<List<Map<String, dynamic>>> recentInbox({int limit = 20}) async => const [];
  @override
  Future<List<SessionKey>> sessionKeys() async => const [];
}

void main() {
  group('routes', () {
    test('every channel has its rows, stored or default (ops alert: outbound only)', () {
      final stored = MessagingRoute(
        channel: MessagingChannel.otp,
        direction: MessagingDirection.outbound,
        transport: MessagingTransport.whatsapp,
        whatsappNumber: '+60123456789',
      );
      final table = messagingRouteTable([stored]);
      expect(table, hasLength(9));
      expect(
        table.where((r) => r.channel == MessagingChannel.otp && r.direction == MessagingDirection.outbound).single,
        same(stored),
      );
      final call = table.firstWhere((r) => r.channel == MessagingChannel.supportCall);
      expect(call.transport, MessagingTransport.voip);
      expect(call.enabled, isFalse);
    });

    test('a row with a transport its channel cannot use is ignored', () {
      expect(MessagingRoute.fromRow({'channel': 'support_call', 'direction': 'inbound', 'transport': 'sms'}), isNull);
      expect(MessagingRoute.fromRow({'channel': 'otp', 'direction': 'sideways', 'transport': 'sms'}), isNull);
      final r = MessagingRoute.fromRow({
        'channel': 'marketing',
        'direction': 'outbound',
        'transport': 'sms',
        'device_ids': ['a', 'b'],
      })!;
      expect(r.deviceIds, ['a', 'b']);
      expect(r.enabled, isTrue);
    });

    test('a saved row keeps only what its transport uses', () {
      final r = MessagingRoute(
        channel: MessagingChannel.supportMessage,
        direction: MessagingDirection.inbound,
        transport: MessagingTransport.whatsapp,
        deviceIds: const ['a'],
        whatsappNumber: ' +60123456789 ',
      );
      expect(r.toRow()['device_ids'], isEmpty);
      expect(r.toRow()['whatsapp_number'], '+60123456789');
      final sms = r.copyWith(transport: MessagingTransport.sms);
      expect(sms.toRow()['device_ids'], ['a']);
      expect(sms.toRow()['whatsapp_number'], isNull);
    });

    test('problems: a number for WhatsApp, a capable device otherwise, nothing when off', () {
      final gateway = _device('g');
      final app = _device('a', kind: 'app', caps: const ['voip']);
      final devices = [gateway, app];
      final sms = MessagingRoute(
        channel: MessagingChannel.otp,
        direction: MessagingDirection.outbound,
        transport: MessagingTransport.sms,
      );
      expect(messagingRouteProblem(sms, devices), contains('Gateway'));
      // An app install without SMS cannot carry it.
      expect(messagingRouteProblem(sms.copyWith(deviceIds: ['a']), devices), isNotNull);
      expect(messagingRouteProblem(sms.copyWith(deviceIds: ['g']), devices), isNull);
      expect(messagingRouteProblem(sms.copyWith(enabled: false), devices), isNull);

      final wa = sms.copyWith(transport: MessagingTransport.whatsapp);
      expect(messagingRouteProblem(wa, devices), isNotNull);
      expect(messagingRouteProblem(wa.copyWith(whatsappNumber: () => '+60 12 345 6789'), devices), isNull);

      final call = MessagingRoute(
        channel: MessagingChannel.supportCall,
        direction: MessagingDirection.inbound,
        transport: MessagingTransport.voip,
        deviceIds: const ['a'],
      );
      expect(messagingRouteProblem(call, devices), isNull);
      expect(devicesFor(MessagingTransport.voip, devices), [app]);
      expect(devicesFor(MessagingTransport.whatsapp, devices), isEmpty);
    });
  });

  test('device presence and numbers', () {
    expect(deviceSeenLabel(_device('x'), _now), 'Never seen');
    expect(deviceSeenLabel(_device('x', ago: const Duration(minutes: 2)), _now), 'Online');
    expect(deviceSeenLabel(_device('x', ago: const Duration(minutes: 10)), _now), 'Seen 10 min ago');
    expect(deviceSeenLabel(_device('x', ago: const Duration(hours: 5)), _now), 'Seen 5 h ago');
    expect(deviceSeenLabel(_device('x', ago: const Duration(days: 3)), _now), 'Seen 3 d ago');
    // An app install beats every 3 minutes: online for two beats.
    expect(messagingAppOnlineWindow, messagingHeartbeatEvery * 2);
    final app = _device('a', kind: 'app', ago: const Duration(minutes: 5));
    expect(deviceSeenLabel(app, _now), 'Online');
    expect(deviceSeenLabel(_device('a', kind: 'app', ago: const Duration(minutes: 7)), _now), 'Seen 7 min ago');
    // A gateway phone beats every minute: offline after 3.
    expect(deviceSeenLabel(_device('x', ago: const Duration(minutes: 5)), _now), 'Seen 5 min ago');
    expect(normalizeSmsNumber('+60 (12) 345-6789'), '+60123456789');
    expect(normalizeSmsNumber('call me'), isNull);
  });

  test('the page is in the side menu and on the Settings hub', () {
    expect(adminModules['messaging']!.pages, [messagingPage]);
    final entry = allAdminEntries.singleWhere((e) => e.path == '/admin/m/messaging');
    expect(entry.pages, [messagingPage]);
    expect(entry.title, 'SMS / WhatsApp');
  });

  testWidgets('assigning a gateway phone to outbound OTP saves the route', (tester) async {
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = _FakeRepo([
      _device('g', ago: const Duration(seconds: 30)),
      _device('a', kind: 'app', caps: const ['voip']),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseProvider.overrideWithValue(_db),
          adminAccessProvider.overrideWith((_) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
          messagingRepositoryProvider.overrideWithValue(repo),
          messagingClockProvider.overrideWithValue(() => _now),
        ],
        child: const MaterialApp(home: AdminMessagingScreen()),
      ),
    );
    await tester.pumpAndSettle();

    for (final c in MessagingChannel.values) {
      expect(find.byKey(ValueKey('messaging-channel-${c.id}')), findsOneWidget);
      for (final d in c.directions) {
        expect(find.byKey(ValueKey('messaging-route-${c.id}-${d.id}')), findsOneWidget);
      }
    }

    await tester.tap(find.byKey(const ValueKey('messaging-enabled-otp-outbound')));
    await tester.pumpAndSettle();
    // Only the gateway can send SMS; the app install is not offered.
    expect(find.byKey(const ValueKey('messaging-device-otp-outbound-g')), findsOneWidget);
    expect(find.byKey(const ValueKey('messaging-device-otp-outbound-a')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('messaging-device-otp-outbound-g')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('messaging-save-otp-outbound')));
    await tester.pumpAndSettle();

    expect(repo.saved, hasLength(1));
    expect(repo.saved.single.toRow(), {
      'channel': 'otp',
      'direction': 'outbound',
      'transport': 'sms',
      'device_ids': ['g'],
      'whatsapp_number': null,
      'enabled': true,
    });
    // Let the success note and any realtime retry run out.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('on a phone with large text, each switch and SMS / WhatsApp choice stays on screen', (tester) async {
    tester.view.physicalSize = const Size(390, 4000);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseProvider.overrideWithValue(_db),
          adminAccessProvider.overrideWith((_) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
          messagingRepositoryProvider.overrideWithValue(_FakeRepo([_device('g', ago: const Duration(seconds: 30))])),
          messagingClockProvider.overrideWithValue(() => _now),
        ],
        child: const MaterialApp(home: AdminMessagingScreen()),
      ),
    );
    await tester.pumpAndSettle();
    for (final key in ['messaging-enabled-otp-inbound', 'messaging-transport-otp-inbound', 'messaging-enabled-otp-outbound']) {
      final r = tester.getRect(find.byKey(ValueKey(key)));
      expect(r.right, lessThanOrEqualTo(390), reason: '$key inside the screen');
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  group('gateway outage', () {
    final otp = MessagingRoute(
      channel: MessagingChannel.otp,
      direction: MessagingDirection.outbound,
      transport: MessagingTransport.sms,
      deviceIds: const ['g1', 'g2'],
    );
    final inbound = MessagingRoute(
      channel: MessagingChannel.supportMessage,
      direction: MessagingDirection.inbound,
      transport: MessagingTransport.sms,
      deviceIds: const ['g1'],
    );

    test('none while one of a route\'s phones is online', () {
      final devices = [_device('g1', ago: const Duration(hours: 2)), _device('g2', ago: const Duration(minutes: 1))];
      expect(gatewayOutage([otp, inbound], devices, _now)?.channels, [MessagingChannel.supportMessage]);
      expect(gatewayOutage([otp], devices, _now), isNull);
    });

    test('since the last phone was seen; sign-in flagged for outbound OTP', () {
      final devices = [_device('g1', ago: const Duration(hours: 2)), _device('g2', ago: const Duration(days: 2))];
      final o = gatewayOutage([otp, inbound], devices, _now)!;
      expect(o.channels, [MessagingChannel.otp, MessagingChannel.supportMessage]);
      expect(o.signIn, isTrue);
      expect(o.since, _now.subtract(const Duration(hours: 2)));
      expect(gatewayOutage([inbound], devices, _now)!.signIn, isFalse);
    });

    test('switched-off and WhatsApp routes are not watched; a never-seen phone has no since', () {
      expect(gatewayOutage([otp.copyWith(enabled: false)], const [], _now), isNull);
      final wa = MessagingRoute(
        channel: MessagingChannel.marketing,
        direction: MessagingDirection.outbound,
        transport: MessagingTransport.whatsapp,
        whatsappNumber: '+60123456789',
      );
      expect(gatewayOutage([wa], const [], _now), isNull);
      final o = gatewayOutage([otp], [_device('g1')], _now)!;
      expect(o.since, isNull);
    });

    for (final b in Brightness.values) {
      testWidgets('the page says the gateway is offline (${b.name})', (tester) async {
        tester.view.physicalSize = const Size(900, 4000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final repo = _FakeRepo([_device('g1', ago: const Duration(hours: 2))], [otp]);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              supabaseProvider.overrideWithValue(_db),
              adminAccessProvider.overrideWith((_) async => const AdminAccess([AdminGrant(page: '*', edit: true)])),
              messagingRepositoryProvider.overrideWithValue(repo),
              messagingClockProvider.overrideWithValue(() => _now),
            ],
            child: MaterialApp(
              theme: ThemeData(brightness: b),
              home: const AdminMessagingScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('messaging-outage')), findsOneWidget);
        expect(find.textContaining('Gateway offline since'), findsOneWidget);
        expect(find.textContaining('Sign-in codes can\'t be sent'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(minutes: 1));
      });
    }
  });
}
