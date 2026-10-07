import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../config.dart';
import '../../../widgets/busy.dart';
import '../../widgets/admin_widgets.dart';
import 'backend_logic.dart';
import 'security_data.dart';

const _page = 'admin-settings-supabase';

/// Read-only backend diagnostics. Unlike the Expo screen there is nothing to
/// type in: this build talks to the backend it was compiled against
/// (`--dart-define=SUPABASE_URL / SUPABASE_ANON_KEY`), and a service-role key
/// never belongs on a client device.
class AdminBackendScreen extends ConsumerStatefulWidget {
  const AdminBackendScreen({super.key});

  @override
  ConsumerState<AdminBackendScreen> createState() => _BackendState();
}

enum _Status { idle, checking, ok, fail }

class _BackendState extends ConsumerState<AdminBackendScreen> {
  _Status _health = _Status.idle;
  String _healthMsg = '';
  _Status _check = _Status.idle;
  String _checkMsg = '';
  int? _count;
  int? _latency;

  Future<void> _testUrl() async {
    setState(() => _health = _Status.checking);
    try {
      final base = AppConfig.supabaseUrl.trim().replaceFirst(RegExp(r'/$'), '');
      final res = await http
          .get(Uri.parse('$base/auth/v1/health'), headers: {'apikey': AppConfig.supabaseAnonKey})
          .timeout(const Duration(seconds: 10));
      final r = describeHealth(res.statusCode);
      if (mounted) {
        setState(() {
          _health = r.ok ? _Status.ok : _Status.fail;
          _healthMsg = r.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _health = _Status.fail;
          _healthMsg = 'Not reachable (${e.runtimeType})';
        });
      }
    }
  }

  Future<void> _pingClient() async {
    setState(() => _health = _Status.checking);
    final r = await ref.read(securityRepositoryProvider).pingAuthClient();
    if (mounted) {
      setState(() {
        _health = r.ok ? _Status.ok : _Status.fail;
        _healthMsg = r.message;
      });
    }
  }

  Future<void> _connectionCheck() async {
    setState(() {
      _check = _Status.checking;
      _count = null;
      _latency = null;
    });
    final sw = Stopwatch()..start();
    try {
      final n = await ref.read(securityRepositoryProvider).profileCount();
      if (mounted) {
        setState(() {
          _check = _Status.ok;
          _count = n;
          _latency = sw.elapsedMilliseconds;
          _checkMsg = 'Read against profiles succeeded.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _check = _Status.fail;
          _latency = sw.elapsedMilliseconds;
          _checkMsg = '$e'.replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Widget _statusIcon(_Status s) => switch (s) {
        _Status.ok => const Icon(Icons.check_circle, color: Colors.green),
        _Status.fail => const Icon(Icons.cancel, color: Colors.red),
        _Status.checking => const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        _Status.idle => const Icon(Icons.link),
      };

  @override
  Widget build(BuildContext context) {
    const url = AppConfig.supabaseUrl;
    const key = AppConfig.supabaseAnonKey;
    final role = jwtRole(key);
    final t = Theme.of(context);
    return AdminPage(
      title: 'Backend',
      page: _page,
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Fixed at build time'),
            subtitle: const Text('This app connects to the backend it was built with '
                '(--dart-define=SUPABASE_URL and SUPABASE_ANON_KEY). To point it elsewhere, ship a new build; '
                'nothing here can change it at runtime.'),
          ),
        ),
        if (role != null && role != 'anon')
          Card(
            color: Colors.red.withValues(alpha: 0.12),
            child: ListTile(
              leading: const Icon(Icons.gpp_bad, color: Colors.red),
              title: const Text('This build carries a non-anon key'),
              subtitle: Text('The configured key has role "$role". Only the public anon key may ship in a client.'),
            ),
          ),
        const SizedBox(height: 8),
        Text('Project', style: t.textTheme.titleMedium),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: DetailTable({
              'Host': backendHost(url).isEmpty ? '(not set)' : backendHost(url),
              'Project ref': projectRef(url).isEmpty ? '—' : projectRef(url),
              'Anon key': maskAnonKey(key),
              'Key role': role ?? 'unknown',
            }),
          ),
        ),
        const SizedBox(height: 12),
        Text('Health check', style: t.textTheme.titleMedium),
        Card(
          child: Column(children: [
            ListTile(
              leading: _statusIcon(_health),
              title: Text(_health == _Status.idle
                  ? 'Run a check to verify the backend.'
                  : (_health == _Status.checking ? 'Checking...' : _healthMsg)),
            ),
            OverflowBar(alignment: MainAxisAlignment.end, children: [
              BusyButton.text(onPressed: _testUrl, icon: const Icon(Icons.sync), child: const Text('Test URL')),
              BusyButton.text(onPressed: _pingClient, icon: const Icon(Icons.storage), child: const Text('Ping client')),
            ]),
          ]),
        ),
        const SizedBox(height: 12),
        Text('Connection check', style: t.textTheme.titleMedium),
        Card(
          child: Column(children: [
            ListTile(
              leading: _statusIcon(_check),
              title: Text(_check == _Status.idle
                  ? 'Count rows in profiles to confirm reads work.'
                  : (_check == _Status.checking ? 'Checking...' : _checkMsg)),
              subtitle: _count == null && _latency == null
                  ? null
                  : Text([
                      if (_count != null) '$_count profiles',
                      if (_latency != null) '${_latency}ms',
                    ].join(' · ')),
            ),
            OverflowBar(alignment: MainAxisAlignment.end, children: [
              BusyButton.text(
                  onPressed: _connectionCheck, icon: const Icon(Icons.monitor_heart_outlined), child: const Text('Run check')),
            ]),
          ]),
        ),
      ]),
    );
  }
}
