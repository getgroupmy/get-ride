import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../config.dart';
import '../../core/auth_diagnostics.dart';
import '../../core/auth_utils.dart';
import '../../widgets/common.dart';

/// Hidden screen for "I can't sign in" (Expo `/auth-diagnostics`), reached
/// from the "Not Connected to server" popup. Works signed out.
class AuthDiagnosticsScreen extends StatefulWidget {
  const AuthDiagnosticsScreen({super.key, this.client, this.url, this.anonKey});

  /// For tests; null makes real requests.
  final http.Client? client;
  final String? url;
  final String? anonKey;

  @override
  State<AuthDiagnosticsScreen> createState() => _AuthDiagnosticsScreenState();
}

class _AuthDiagnosticsScreenState extends State<AuthDiagnosticsScreen> {
  late final http.Client _client = widget.client ?? http.Client();
  final _phone = TextEditingController();
  List<DiagStep> _steps = const [];
  DiagStep? _sms;
  bool _running = false;
  bool _sending = false;

  String get _url => widget.url ?? AppConfig.supabaseUrl;
  String get _key => widget.anonKey ?? AppConfig.supabaseAnonKey;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    if (widget.client == null) _client.close();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() => _running = true);
    final steps = await runAuthDiagnostics(url: _url, anonKey: _key, client: _client, web: kIsWeb);
    if (mounted) {
      setState(() {
        _steps = steps;
        _running = false;
      });
    }
  }

  Future<void> _send() async {
    final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 8) return showInfo(context, 'Enter the full number with its country code, e.g. +60123456789.');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Send a real SMS?'),
        content: Text('A sign-in code will be texted to ${normalizeE164(digits)}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _sending = true);
    final step = await sendTestCode(url: _url, anonKey: _key, phone: normalizeE164(digits), client: _client);
    if (mounted) {
      setState(() {
        _sms = step;
        _sending = false;
      });
    }
  }

  Future<void> _copy() async {
    final report = diagnosticsReport(
      [..._steps, ?_sms],
      appVersion: AppConfig.appVersion,
      platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
    );
    await Clipboard.setData(ClipboardData(text: report));
    if (mounted) showInfo(context, 'Report copied');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Copy report',
            onPressed: _running || _steps.isEmpty ? null : _copy,
            icon: const Icon(Icons.copy_all_outlined),
          ),
        ],
      ),
      body: ListView(
        children: [
          ResponsiveCenter(
            maxWidth: 640,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Checks each step between this device and the GET.ride server. '
                  'Copy the report and send it to support if something fails.',
                  style: t.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                if (_running && _steps.isEmpty) const LinearProgressIndicator(),
                for (final s in [..._steps, ?_sms]) _StepTile(step: s),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _running ? null : _run,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Run again'),
                ),
                const SizedBox(height: 24),
                Text('Sign-in code not arriving?', style: t.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text('Sends one real SMS to the number you enter.', style: t.textTheme.bodySmall),
                const SizedBox(height: 8),
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Phone number with country code'),
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: _sending ? null : _send,
                  icon: const Icon(Icons.sms_outlined),
                  label: const Text('Send test code'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.step});
  final DiagStep step;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color) = switch (step.status) {
      DiagStatus.pass => (Icons.check_circle, const Color(0xFF10B981)),
      DiagStatus.fail => (Icons.cancel, cs.error),
      DiagStatus.skipped => (Icons.remove_circle_outline, cs.onSurfaceVariant),
    };
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(step.label),
        subtitle: Text(step.detail),
        trailing: step.ms == null ? null : Text('${step.ms} ms'),
      ),
    );
  }
}
