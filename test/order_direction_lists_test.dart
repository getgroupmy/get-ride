// The lists whose order changed when every `.order(` was made to say its
// direction (order_direction_test.dart): read through the real repositories
// over a fake PostgREST that sorts like the server — `order=a.asc,b.desc`,
// and DESCENDING for a bare `.order(column)` in postgrest-dart, which is why
// these lists used to come out upside down.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:get_ride/src/admin/admin_settings_models.dart';
import 'package:get_ride/src/admin/screens/commerce/commerce_data.dart' show commerceCategories;
import 'package:get_ride/src/admin/screens/commerce/commerce_logic.dart' show paymentTypeCategory;
import 'package:get_ride/src/core/commission_settings.dart';
import 'package:get_ride/src/core/payment_types.dart';
import 'package:get_ride/src/data/account_repository.dart';
import 'package:get_ride/src/data/coin_transfer_repository.dart';
import 'package:get_ride/src/data/dispatch_repository.dart';
import 'package:get_ride/src/data/help_repository.dart';
import 'package:get_ride/src/data/scheduled_ride_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Tables held in memory and served as PostgREST would: `eq.` filters,
/// `order` (asc / desc, nulls last), `limit`, and inserts that get an id and
/// a `created_at` one second after the last.
class _FakeRest {
  _FakeRest(Map<String, List<Map<String, dynamic>>> tables)
      : tables = {for (final e in tables.entries) e.key: [for (final r in e.value) {...r}]};

  final Map<String, List<Map<String, dynamic>>> tables;
  final orders = <String, String>{};
  var _clock = DateTime.utc(2026, 1, 1);
  var _ids = 0;

  late final SupabaseClient client = SupabaseClient(
    'http://localhost',
    'anon',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient(_handle),
  );

  static int _cmp(Object? a, Object? b) {
    if (a is num && b is num) return a.compareTo(b);
    return '$a'.compareTo('$b');
  }

  Future<http.Response> _handle(http.Request req) async {
    final table = req.url.pathSegments.last;
    final rows = tables.putIfAbsent(table, () => []);
    final q = req.url.queryParameters;
    switch (req.method) {
      case 'GET':
        var out = [
          for (final r in rows)
            if (q.entries.every((f) =>
                !f.value.startsWith('eq.') || '${r[f.key]}' == f.value.substring(3)))
              r,
        ];
        final order = q['order'];
        if (order != null) {
          orders[table] = order;
          final keys = [
            for (final k in order.split(','))
              (col: k.split('.').first, desc: k.split('.').contains('desc')),
          ];
          out.sort((a, b) {
            for (final k in keys) {
              final x = a[k.col], y = b[k.col];
              if (x == null && y == null) continue;
              if (x == null) return 1;
              if (y == null) return -1;
              final c = _cmp(x, y);
              if (c != 0) return k.desc ? -c : c;
            }
            return 0;
          });
        }
        final limit = int.tryParse(q['limit'] ?? '');
        if (limit != null && out.length > limit) out = out.sublist(0, limit);
        return http.Response(jsonEncode(out), 200, headers: {'content-type': 'application/json'}, request: req);
      case 'POST':
        final body = jsonDecode(req.body);
        for (final r in body is List ? body : [body]) {
          _clock = _clock.add(const Duration(seconds: 1));
          rows.add({
            'id': 'new-${++_ids}',
            'created_at': _clock.toIso8601String(),
            ...Map<String, dynamic>.from(r as Map),
          });
        }
        return http.Response('', 201, request: req);
    }
    return http.Response('', 405, request: req);
  }
}

String _at(int minute) => DateTime.utc(2026, 3, 1, 9, minute).toIso8601String();

void main() {
  group('Support chat', () {
    // Shown with reverse: true from the END of the list: the list must be
    // oldest first so the newest message sits at the bottom by the box.
    final rows = [
      {'id': 'm2', 'ticket_id': 't', 'body': 'second', 'created_at': _at(2)},
      {'id': 'm1', 'ticket_id': 't', 'body': 'first', 'created_at': _at(1)},
      {'id': 'm3', 'ticket_id': 't', 'body': 'third', 'created_at': _at(3)},
      {'id': 'x', 'ticket_id': 'other', 'body': 'not this one', 'created_at': _at(0)},
    ];

    test('the rider / driver chat reads oldest first (newest at the bottom)', () async {
      final api = _FakeRest({'support_messages': rows});
      final msgs = await AccountRepository(api.client).messages('t');
      expect([for (final m in msgs) m.id], ['m1', 'm2', 'm3']);
      expect(api.orders['support_messages'], startsWith('created_at.asc'));
    });

    test("the admin's ticket chat reads oldest first too", () async {
      final api = _FakeRest({'support_messages': rows});
      final msgs = await AdminRepository(api.client).ticketMessages('t');
      expect([for (final m in msgs) m['id']], ['m1', 'm2', 'm3']);
    });
  });

  group('Scheduled rides (rider)', () {
    Map<String, dynamic> booking(String id, DateTime at, {String status = 'scheduled'}) =>
        {'id': id, 'rider_id': 'u', 'pickup_at': at.toIso8601String(), 'status': status};

    test('soonest first, so Upcoming starts with the next one and Past (reversed) with the latest', () async {
      final now = DateTime.now().toUtc();
      final api = _FakeRest({
        'scheduled_rides': [
          booking('later', now.add(const Duration(days: 3))),
          booking('next', now.add(const Duration(days: 1))),
          booking('past', now.subtract(const Duration(days: 2)), status: 'completed'),
        ],
      });
      final mine = await ScheduledRideRepository(api.client).mine('u');
      expect([for (final r in mine) r.id], ['past', 'next', 'later']);
    });

    test('a long history never pushes the upcoming bookings out of the 100 read', () async {
      final now = DateTime.now().toUtc();
      final api = _FakeRest({
        'scheduled_rides': [
          for (var i = 0; i < 120; i++)
            booking('old-$i', now.subtract(Duration(days: 200 - i)), status: 'completed'),
          booking('next', now.add(const Duration(days: 1))),
        ],
      });
      final mine = await ScheduledRideRepository(api.client).mine('u');
      expect(mine, hasLength(100));
      expect(mine.last.id, 'next');
      expect(mine.first.id, 'old-21');
    });
  });

  test('coin transfer requests waiting for me: oldest first, as documented', () async {
    final api = _FakeRest({
      'wallet_transfer_requests': [
        for (final (id, m) in [('b', 2), ('a', 1), ('c', 3)])
          {
            'id': id,
            'from_user_id': 'f',
            'to_user_id': 'me',
            'status': 'pending',
            'coins': 1,
            'created_at': _at(m),
            'expires_at': '2999-01-01T00:00:00Z',
          },
      ],
    });
    final list = await CoinTransferRepository(api.client).pendingIncoming('me');
    expect([for (final r in list) r.id], ['a', 'b', 'c']);
  });

  group('Admin → Commission → Tiers (save path: Add tier stores position = tier count)', () {
    test('tiers read in the order they were added, a new tier last', () async {
      final api = _FakeRest({'commission_tiers': []});
      final repo = AdminRepository(api.client);
      for (final name in ['Bronze', 'Silver', 'Gold']) {
        final tiers = await repo.commissionTiers();
        // As the screen does: the new tier's position is the current count.
        await repo.saveCommissionTier(CommissionTier(name: name, threshold: 10, value: 0.1, position: tiers.length));
      }
      expect([for (final t in await repo.commissionTiers()) t.name], ['Bronze', 'Silver', 'Gold']);
      expect(api.orders['commission_tiers'], 'position.asc.nullslast,created_at.asc.nullslast');
    });
  });

  group('Payment types (save path: Add stores position = row count)', () {
    final category = commerceCategories[paymentTypeCategory]!;

    test('the admin list and the riders\' choices read first-added first; the default is the first', () async {
      final api = _FakeRest({'settings_entries': []});
      final repo = AdminRepository(api.client);
      for (final name in ['Cash', 'Card', 'E-wallet']) {
        final all = await repo.settings(category);
        await repo.saveSetting(category, values: {'name': name, 'enabled': true}, position: all.length);
      }
      final rows = await repo.settings(category);
      expect([for (final e in rows) e.values['name']], ['Cash', 'Card', 'E-wallet']);
      final choices = paymentChoicesFrom([for (final e in rows) e.values]);
      expect([for (final c in choices) c.value], ['Cash', 'Card', 'E-wallet']);
      expect(resolvePayment('Gone', choices), 'Cash');
    });

    test('rows on the same position keep the order they were added (created_at breaks the tie)', () async {
      final api = _FakeRest({
        'settings_entries': [
          {'id': 'z', 'category': paymentTypeCategory, 'values': {'name': 'B'}, 'position': 0, 'created_at': _at(2)},
          {'id': 'a', 'category': paymentTypeCategory, 'values': {'name': 'A'}, 'position': 0, 'created_at': _at(1)},
        ],
      });
      final rows = await AdminRepository(api.client).settings(category);
      expect([for (final SettingEntry e in rows) e.values['name']], ['A', 'B']);
    });
  });

  test('help articles (admin) read by Sort then title, lowest first', () async {
    final api = _FakeRest({
      'help_articles': [
        {'id': '3', 'title': 'Payments', 'answer': 'x', 'sort': 30},
        {'id': '1', 'title': 'Booking', 'answer': 'x', 'sort': 10},
        {'id': '2b', 'title': 'Cancel', 'answer': 'x', 'sort': 20},
        {'id': '2a', 'title': 'Account', 'answer': 'x', 'sort': 20},
      ],
    });
    final list = await HelpRepository(api.client).articles();
    expect([for (final a in list) a.title], ['Booking', 'Account', 'Cancel', 'Payments']);
  });

  test('dispatch stands and groups (admin) read A to Z', () async {
    final api = _FakeRest({
      'dispatch_stands': [
        {'id': 's2', 'name': 'Zeta Mall', 'code': 'Z'},
        {'id': 's1', 'name': 'Airport', 'code': 'A'},
      ],
      'dispatch_groups': [
        {'id': 'g2', 'name': 'Night', 'active': true},
        {'id': 'g1', 'name': 'Day', 'active': true},
      ],
    });
    final repo = DispatchRepository(api.client);
    expect([for (final s in await repo.allStands()) s.name], ['Airport', 'Zeta Mall']);
    expect([for (final g in await repo.allGroups()) g.name], ['Day', 'Night']);
  });
}
