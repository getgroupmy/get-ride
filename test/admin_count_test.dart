// The admin dashboard counts ask for the number only (a HEAD request), not
// every id (lib/src/admin/admin_repository.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/admin/admin_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('dashboard counts are count-only requests', () async {
    final seen = <http.BaseRequest>[];
    final db = SupabaseClient(
      'http://localhost',
      'anon',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        seen.add(r);
        return http.Response('', 200, headers: {'content-range': '*/42'}, request: r);
      }),
    );
    addTearDown(db.dispose);
    final counts = await AdminRepository(db).dashboardCounts();
    expect(counts['users'], 42);
    expect(counts['ridesOpen'], 42);
    expect(seen, isNotEmpty);
    for (final r in seen) {
      expect(r.method, 'HEAD');
      expect(r.headers['Prefer'] ?? r.headers['prefer'], contains('count=exact'));
    }
    expect(seen.where((r) => r.url.path.endsWith('/ride_requests')).map((r) => r.url.queryParameters['status']),
        contains('eq.open'));
  });
}
