// The sign-in diagnostics behind the connection popup's Diagnose button
// (Expo `auth-diagnostics.tsx`): each check says what it tried, whether it
// worked and how long it took, and the lot copies out as one report for
// support. Expo's two SMS checks sent two real texts on every run; here
// sending a test code is a separate, explicit button.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

enum DiagStatus { pass, fail, skipped }

class DiagStep {
  const DiagStep(this.label, this.status, this.detail, {this.ms});

  final String label;
  final DiagStatus status;
  final String detail;
  final int? ms;

  String get mark => switch (status) {
    DiagStatus.pass => 'PASS',
    DiagStatus.fail => 'FAIL',
    DiagStatus.skipped => 'SKIP',
  };
}

const _timeout = Duration(seconds: 8);

Map<String, String> _headers(String key) => {'apikey': key, 'Authorization': 'Bearer $key'};

/// Times [run] and turns a throw into a failed step.
Future<DiagStep> _timed(String label, Future<(DiagStatus, String)> Function() run) async {
  final watch = Stopwatch()..start();
  try {
    final (status, detail) = await run().timeout(_timeout);
    return DiagStep(label, status, detail, ms: watch.elapsedMilliseconds);
  } on TimeoutException {
    return DiagStep(label, DiagStatus.fail, 'No answer within ${_timeout.inSeconds} s', ms: watch.elapsedMilliseconds);
  } catch (e) {
    return DiagStep(label, DiagStatus.fail, '$e', ms: watch.elapsedMilliseconds);
  }
}

String _body(http.Response r) {
  final b = r.body.trim();
  return b.length > 160 ? '${b.substring(0, 160)}…' : b;
}

/// Runs the four read-only checks in order. A check that needs the server
/// address is skipped when it is missing, rather than failing for a reason
/// the first check already gave. [web] skips the internet probe, which a
/// browser blocks for a reason that says nothing about the connection.
Future<List<DiagStep>> runAuthDiagnostics({
  required String url,
  required String anonKey,
  required http.Client client,
  bool web = false,
}) async {
  final base = url.trim().replaceAll(RegExp(r'/+$'), '');
  final steps = <DiagStep>[];
  final configured = base.isNotEmpty && anonKey.isNotEmpty;
  steps.add(
    DiagStep(
      '1. App settings',
      configured ? DiagStatus.pass : DiagStatus.fail,
      [
        'Server: ${base.isEmpty ? 'missing' : Uri.tryParse(base)?.host ?? base}',
        'Key: ${anonKey.isEmpty ? 'missing' : 'set (${anonKey.length} chars)'}',
      ].join(' · '),
    ),
  );

  steps.add(
    web
        ? const DiagStep('2. Internet', DiagStatus.skipped, 'Not checked in a browser')
        : await _timed('2. Internet', () async {
            final r = await client.get(Uri.parse('https://www.google.com/generate_204'));
            return (r.statusCode < 400 ? DiagStatus.pass : DiagStatus.fail, 'HTTP ${r.statusCode}');
          }),
  );

  if (!configured) {
    for (final label in ['3. Server health', '4. Public data read']) {
      steps.add(DiagStep(label, DiagStatus.skipped, 'Needs the app settings above'));
    }
    return steps;
  }

  steps.add(
    await _timed('3. Server health', () async {
      final r = await client.get(Uri.parse('$base/auth/v1/health'), headers: _headers(anonKey));
      final ok = r.statusCode >= 200 && r.statusCode < 300;
      return (ok ? DiagStatus.pass : DiagStatus.fail, ok ? 'HTTP ${r.statusCode}' : 'HTTP ${r.statusCode} ${_body(r)}');
    }),
  );

  steps.add(
    await _timed('4. Public data read', () async {
      final r = await client.get(
        Uri.parse('$base/rest/v1/settings_entries?select=id&limit=1'),
        headers: _headers(anonKey),
      );
      final ok = r.statusCode >= 200 && r.statusCode < 300;
      return (ok ? DiagStatus.pass : DiagStatus.fail, ok ? 'HTTP ${r.statusCode}' : 'HTTP ${r.statusCode} ${_body(r)}');
    }),
  );
  return steps;
}

/// Asks the server to text a sign-in code to [phone] (E.164): the check for
/// "the code never arrives". Sends a real SMS, so it only runs on request.
Future<DiagStep> sendTestCode({
  required String url,
  required String anonKey,
  required String phone,
  required http.Client client,
}) {
  final base = url.trim().replaceAll(RegExp(r'/+$'), '');
  return _timed('5. Send test code', () async {
    final r = await client.post(
      Uri.parse('$base/auth/v1/otp'),
      headers: {..._headers(anonKey), 'Content-Type': 'application/json'},
      body: jsonEncode({'phone': phone}),
    );
    final ok = r.statusCode >= 200 && r.statusCode < 300;
    return (ok ? DiagStatus.pass : DiagStatus.fail, ok ? 'Code sent to $phone' : 'HTTP ${r.statusCode} ${_body(r)}');
  });
}

/// The plain-text report "Copy report" puts on the clipboard.
String diagnosticsReport(List<DiagStep> steps, {required String appVersion, required String platform, DateTime? at}) {
  final lines = [
    'GET.ride sign-in diagnostics',
    'App ${appVersion.trim()} · $platform · ${(at ?? DateTime.now()).toUtc().toIso8601String()}',
    '',
    for (final s in steps) '[${s.mark}] ${s.label}: ${s.detail}${s.ms == null ? '' : ' (${s.ms} ms)'}',
  ];
  return lines.join('\n');
}
