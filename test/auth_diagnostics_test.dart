import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_ride/src/core/auth_diagnostics.dart';
import 'package:get_ride/src/core/connection_check.dart';
import 'package:get_ride/src/features/settings/auth_diagnostics_screen.dart';
import 'package:get_ride/src/widgets/connection_status_dialog.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _url = 'https://abc.supabase.co';

/// A server where every path answers [codes] (default 200) and requests are
/// recorded.
MockClient _server(List<http.Request> seen, {Map<String, int> codes = const {}}) => MockClient((req) async {
  seen.add(req);
  final code = codes.entries.firstWhere((e) => req.url.path.contains(e.key), orElse: () => const MapEntry('', 200));
  return http.Response(code.value == 200 ? '{}' : '{"msg":"nope"}', code.value);
});

void main() {
  group('runAuthDiagnostics', () {
    test('all four checks pass against a healthy server', () async {
      final seen = <http.Request>[];
      final steps = await runAuthDiagnostics(url: '$_url/', anonKey: 'key', client: _server(seen));
      expect(steps.map((s) => s.status), everyElement(DiagStatus.pass));
      expect(steps.map((s) => s.label), ['1. App settings', '2. Internet', '3. Server health', '4. Public data read']);
      expect(seen.map((r) => r.url.toString()), [
        'https://www.google.com/generate_204',
        '$_url/auth/v1/health',
        '$_url/rest/v1/settings_entries?select=id&limit=1',
      ]);
      expect(seen[1].headers['apikey'], 'key');
    });

    test('nothing is ever sent to the SMS endpoint by a run', () async {
      final seen = <http.Request>[];
      await runAuthDiagnostics(url: _url, anonKey: 'key', client: _server(seen));
      expect(seen.where((r) => r.url.path.contains('otp')), isEmpty);
    });

    test('a failing server check reports its status and body', () async {
      final steps = await runAuthDiagnostics(
        url: _url,
        anonKey: 'key',
        client: _server([], codes: {'/rest/v1': 401}),
      );
      expect(steps[2].status, DiagStatus.pass);
      expect(steps[3].status, DiagStatus.fail);
      expect(steps[3].detail, contains('HTTP 401'));
    });

    test('a request that throws is a failed step, not a crash', () async {
      final steps = await runAuthDiagnostics(
        url: _url,
        anonKey: 'key',
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      expect(steps.skip(1).map((s) => s.status), everyElement(DiagStatus.fail));
      expect(steps[1].detail, contains('offline'));
    });

    test('missing settings fail once and skip the server checks', () async {
      final seen = <http.Request>[];
      final steps = await runAuthDiagnostics(url: '', anonKey: '', client: _server(seen), web: true);
      expect(steps.map((s) => s.status), [DiagStatus.fail, DiagStatus.skipped, DiagStatus.skipped, DiagStatus.skipped]);
      expect(steps[0].detail, contains('Server: missing'));
      expect(seen, isEmpty);
    });
  });

  test('a test code is one explicit request with the phone', () async {
    final seen = <http.Request>[];
    final step = await sendTestCode(url: _url, anonKey: 'key', phone: '+60123456789', client: _server(seen));
    expect(step.status, DiagStatus.pass);
    expect(seen.single.method, 'POST');
    expect(seen.single.url.path, '/auth/v1/otp');
    expect(jsonDecode(seen.single.body), {'phone': '+60123456789'});
  });

  test('the report lists every step and never the key', () {
    final report = diagnosticsReport(
      [
        const DiagStep('1. App settings', DiagStatus.pass, 'Server: abc.supabase.co · Key: set (3 chars)'),
        const DiagStep('3. Server health', DiagStatus.fail, 'HTTP 503', ms: 120),
      ],
      appVersion: '1.4.3',
      platform: 'android',
      at: DateTime.utc(2026, 10, 6),
    );
    expect(report, contains('[PASS] 1. App settings'));
    expect(report, contains('[FAIL] 3. Server health: HTTP 503 (120 ms)'));
    expect(report, contains('App 1.4.3 · android'));
    expect(report, isNot(contains('secret-key')));
  });

  testWidgets('the screen runs the checks on open', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AuthDiagnosticsScreen(
          client: _server([], codes: {'/auth/v1/health': 503}),
          url: _url,
          anonKey: 'k',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('3. Server health'), findsOneWidget);
    expect(find.textContaining('HTTP 503'), findsOneWidget);
    expect(find.byIcon(Icons.cancel), findsOneWidget);
  });

  testWidgets('the failed popup offers Diagnose, which opens the screen', (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: TextButton(
              onPressed: () => showConnectionStatus(
                context,
                ConnectionPopup.failed,
                const ConnectionCheck(reachable: false, url: _url, hasKey: true, errorMessage: 'down'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
        GoRoute(
          path: '/diagnostics',
          builder: (_, _) => const Scaffold(body: Text('diagnostics screen')),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Diagnose'));
    await tester.pumpAndSettle();
    expect(find.text('diagnostics screen'), findsOneWidget);
    expect(find.text('Diagnose'), findsNothing);
  });
}
