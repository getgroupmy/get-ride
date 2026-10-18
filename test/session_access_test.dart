// Admin → SMS / WhatsApp → Session access (migration 0226): the rules of a
// session key, and the card that adds, lists and removes them.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_access.dart';
import 'package:get_ride/src/admin/admin_providers.dart';
import 'package:get_ride/src/admin/screens/messaging_screen.dart';
import 'package:get_ride/src/core/messaging.dart';
import 'package:get_ride/src/core/page_inventory.g.dart';
import 'package:get_ride/src/core/session_access.dart';
import 'package:get_ride/src/data/messaging_repository.dart';
import 'package:get_ride/src/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// No token refresh: its timer would outlive the test.
final _db = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));

final _now = DateTime.utc(2026, 10, 18, 12);

SessionKey _key(
  String id, {
  List<SessionScope> scopes = const [SessionScope.sms, SessionScope.codes],
  Duration? endsIn = const Duration(hours: 20),
  DateTime? revokedAt,
  String? proxyLabel,
  int uses = 0,
  DateTime? lastUsedAt,
}) => SessionKey(
  id: id,
  label: 'Session $id',
  testPhone: '+60123456789',
  scopes: scopes,
  createdAt: _now.subtract(const Duration(hours: 4)),
  expiresAt: _now.add(endsIn ?? Duration.zero),
  revokedAt: revokedAt,
  proxyLabel: proxyLabel,
  proxyDevice: proxyLabel == null ? null : 'g',
  uses: uses,
  lastUsedAt: lastUsedAt,
);

class _FakeRepo extends MessagingRepository {
  _FakeRepo(this.keys, {this.devicesList = const []}) : super(_db);
  List<SessionKey> keys;
  final List<MessagingDevice> devicesList;
  final created = <Map<String, Object?>>[];
  final revoked = <String>[];

  @override
  Future<List<MessagingDevice>> devices() async => devicesList;
  @override
  Future<List<MessagingRoute>> routes() async => const [];
  @override
  Future<List<Map<String, dynamic>>> recentOutbox({int limit = 20}) async => const [];
  @override
  Future<List<Map<String, dynamic>>> recentInbox({int limit = 20}) async => const [];
  @override
  Future<List<SessionKey>> sessionKeys() async => keys;

  @override
  Future<({String key, DateTime? expiresAt})> createSessionKey({
    required String label,
    required String testPhone,
    required Set<SessionScope> scopes,
    required int hours,
    String? proxyDevice,
  }) async {
    created.add({
      'label': label,
      'phone': testPhone,
      'scopes': scopes.map((s) => s.id).toList()..sort(),
      'hours': hours,
      'proxy': proxyDevice,
    });
    keys = [_key('new'), ...keys];
    return (key: 'a' * 64, expiresAt: _now.add(Duration(hours: hours)));
  }

  @override
  Future<void> revokeSessionKey(String id) async {
    revoked.add(id);
    keys = [for (final k in keys) k.id == id ? _key(id, revokedAt: _now) : k];
  }
}

Widget _app(_FakeRepo repo, {bool fullAdmin = true}) => ProviderScope(
  overrides: [
    supabaseProvider.overrideWithValue(_db),
    adminAccessProvider.overrideWith(
      (_) async => AdminAccess([
        fullAdmin
            ? const AdminGrant(page: '*', edit: true)
            : const AdminGrant(page: 'admin-settings-messaging', edit: true),
      ]),
    ),
    messagingRepositoryProvider.overrideWithValue(repo),
    messagingClockProvider.overrideWithValue(() => _now),
  ],
  child: const MaterialApp(home: AdminMessagingScreen()),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}

void main() {
  group('a session key', () {
    test('reads its row, dropping scopes it does not know', () {
      final k = SessionKey.fromRow({
        'id': 'k1',
        'label': 'CI',
        'test_phone': '+60123456789',
        'scopes': ['sms', 'proxy', 'teleport'],
        'proxy_device': 'g',
        'proxy_label': 'Office gateway',
        'created_at': '2026-10-18T08:00:00Z',
        'expires_at': '2026-10-19T08:00:00Z',
        'revoked_at': null,
        'last_used_at': '2026-10-18T11:55:00Z',
        'uses': 12,
      })!;
      expect(k.scopes, [SessionScope.sms, SessionScope.proxy]);
      expect(k.proxyLabel, 'Office gateway');
      expect(k.activeAt(_now), isTrue);
      expect(sessionKeyStatus(k, _now), 'Active');
      expect(sessionKeyUseLabel(k, _now), 'Used 12× · last 5 min ago');
      expect(SessionKey.fromRow({'id': 'x'}), isNull, reason: 'no dates');
    });

    test('is active until it ends or is removed', () {
      expect(sessionKeyStatus(_key('a'), _now), 'Active');
      expect(sessionKeyStatus(_key('b', endsIn: Duration.zero), _now), 'Expired');
      expect(sessionKeyStatus(_key('c', revokedAt: _now), _now), 'Removed');
      expect(_key('c', revokedAt: _now).activeAt(_now), isFalse);
      expect(sessionKeyUseLabel(_key('d'), _now), 'Never used');
      expect(sessionKeyUseLabel(_key('e', uses: 2, lastUsedAt: _now.subtract(const Duration(days: 3))), _now),
          'Used 2× · last 3 d ago');
    });

    test('the row subtitle leaves out empty parts instead of a dangling " · "', () {
      String ends(DateTime d) => 'soon';
      final bare = SessionKey(
        id: 'z',
        label: 'Bare',
        testPhone: '',
        scopes: const [],
        createdAt: _now,
        expiresAt: _now.add(const Duration(days: 30)),
      );
      expect(sessionKeySubtitle(bare, _now, ends), 'Ends soon · Never used');
      expect(sessionKeySubtitle(_key('f'), _now, ends), startsWith('+60123456789 · '));
      expect(sessionKeySubtitle(_key('f'), _now, ends), isNot(contains('·  ·')));
    });

    test('lasts a chosen number of hours, a day by default', () {
      expect(sessionKeyHoursChoices, contains(sessionKeyDefaultHours));
      expect(sessionKeyHoursLabel(8), '8 h');
      expect(sessionKeyHoursLabel(24), '1 day');
      expect(sessionKeyHoursLabel(720), '30 days');
    });

    test('a draft needs a name, a full number, a scope, and a phone for internet', () {
      expect(normalizeSessionPhone('+60 12-345 6789'), '+60123456789');
      expect(normalizeSessionPhone('0123456789'), isNull, reason: 'country code');
      expect(sessionKeyProblem(label: ' ', phone: '+60123456789', scopes: {SessionScope.sms}), contains('name'));
      expect(sessionKeyProblem(label: 'CI', phone: '0123', scopes: {SessionScope.sms}), contains('country code'));
      expect(sessionKeyProblem(label: 'CI', phone: '+60123456789', scopes: const {}), contains('Tick'));
      expect(
        sessionKeyProblem(label: 'CI', phone: '+60123456789', scopes: {SessionScope.proxy}),
        contains('gateway phone'),
      );
      expect(
        sessionKeyProblem(label: 'CI', phone: '+60123456789', scopes: {SessionScope.proxy}, proxyDevice: 'g'),
        isNull,
      );
      expect(sessionKeyProblem(label: 'CI', phone: '+60123456789', scopes: {SessionScope.codes}), isNull);
    });
  });

  group('the card', () {
    testWidgets('lists the keys with their state; a full admin adds one and is shown the key once', (tester) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gateway = MessagingDevice(
        id: 'g',
        userId: 'u1',
        deviceId: 'dev-g',
        kind: 'gateway',
        label: 'Office gateway',
        capabilities: const ['sms'],
        lastSeenAt: _now,
      );
      final repo = _FakeRepo([
        _key('k1', proxyLabel: 'Office gateway', scopes: SessionScope.values),
        _key('k2', revokedAt: _now),
        _key('k3', endsIn: Duration.zero),
      ], devicesList: [gateway]);
      await tester.pumpWidget(_app(repo));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const ValueKey('session-access-card')), 400,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('session-key-k1')), findsOneWidget);
      expect(find.textContaining('Internet via Office gateway'), findsOneWidget);
      expect(find.byKey(const ValueKey('session-remove-k1')), findsOneWidget);
      // A removed or expired key can't be removed again; it shows its state.
      expect(find.byKey(const ValueKey('session-remove-k2')), findsNothing);
      expect(find.byKey(const ValueKey('session-remove-k3')), findsNothing);
      expect(find.text('Removed'), findsOneWidget);
      expect(find.text('Expired'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('session-add')));
      await tester.pumpAndSettle();
      // Nothing typed: told what is missing, nothing sent.
      await tester.tap(find.byKey(const ValueKey('session-add-confirm')));
      await tester.pumpAndSettle();
      expect(repo.created, isEmpty);
      expect(find.textContaining('Give the session a name'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('session-label')), 'Claude cloud session');
      await tester.enterText(find.byKey(const ValueKey('session-phone')), '+60 12 345 6789');
      await tester.tap(find.byKey(const ValueKey('session-scope-proxy')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('session-proxy-device')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('session-add-confirm')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Pick the gateway phone'), findsOneWidget, reason: 'internet needs a phone');
      await tester.tap(find.byKey(const ValueKey('session-proxy-device')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Office gateway').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('session-add-confirm')));
      await tester.pumpAndSettle();

      expect(repo.created, [
        {
          'label': 'Claude cloud session',
          'phone': '+60123456789',
          'scopes': ['codes', 'proxy', 'sms'],
          'hours': sessionKeyDefaultHours,
          'proxy': 'g',
        },
      ]);
      // The key, once, with where to put it.
      expect(find.byKey(const ValueKey('session-key-value')), findsOneWidget);
      expect(find.text('a' * 64), findsOneWidget);
      expect(find.textContaining(sessionKeyEnvName), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('session-key-new')), findsOneWidget, reason: 'the list refreshed');
      await _settle(tester);
    });

    testWidgets('removing asks first, then revokes', (tester) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _FakeRepo([_key('k1')]);
      await tester.pumpWidget(_app(repo));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const ValueKey('session-remove-k1')), 400,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('session-remove-k1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.revoked, isEmpty);
      await tester.tap(find.byKey(const ValueKey('session-remove-k1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(repo.revoked, ['k1']);
      expect(find.byKey(const ValueKey('session-remove-k1')), findsNothing);
      expect(find.text('Removed'), findsOneWidget);
      await _settle(tester);
    });

    testWidgets('a sub-admin sees the list but neither adds nor removes', (tester) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _FakeRepo([_key('k1')]);
      await tester.pumpWidget(_app(repo, fullAdmin: false));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const ValueKey('session-key-k1')), 400,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('session-add')), findsNothing);
      expect(find.byKey(const ValueKey('session-remove-k1')), findsNothing);
      expect(find.textContaining('Only a full admin'), findsOneWidget);
      await _settle(tester);
    });

    test('its modals are in App Page Settings', () {
      final ids = pageInventory.map((s) => s.id).toSet();
      expect(ids, containsAll(['modal:messaging.session-add', 'modal:messaging.session-key']));
    });
  });
}
