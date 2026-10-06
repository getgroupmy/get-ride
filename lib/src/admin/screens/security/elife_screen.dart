import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/common.dart';
import '../../admin_access.dart';
import '../../widgets/admin_widgets.dart';
import 'api_keys_screens.dart' show apiKeysPage;
import 'elife_logic.dart';
import 'security_data.dart';
import '../../../widgets/in_app_page.dart';

const _page = 'admin-settings-api-elife';

class AdminElifeScreen extends ConsumerStatefulWidget {
  const AdminElifeScreen({super.key});

  @override
  ConsumerState<AdminElifeScreen> createState() => _ElifeState();
}

class _ElifeState extends ConsumerState<AdminElifeScreen> {
  Map<String, dynamic>? _config;
  Object? _loadError;
  bool _dirty = false;
  bool _saving = false;
  bool _testing = false;
  bool _revealSecret = false;
  String _environment = 'sandbox';
  final _baseUrl = TextEditingController();
  final _tokenUrl = TextEditingController();
  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();
  final _webhookUrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_baseUrl, _tokenUrl, _clientId, _clientSecret, _webhookUrl]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final cfg = await ref.read(securityRepositoryProvider).elifeConfig();
      if (mounted) _hydrate(cfg);
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  void _hydrate(Map<String, dynamic> cfg) => setState(() {
        _config = cfg;
        _loadError = null;
        _baseUrl.text = '${cfg['baseUrl'] ?? ''}';
        _tokenUrl.text = '${cfg['tokenUrl'] ?? ''}';
        _clientId.text = '${cfg['clientId'] ?? ''}';
        _clientSecret.text = '${cfg['clientSecret'] ?? ''}';
        _webhookUrl.text = '${cfg['webhookUrl'] ?? ''}';
        _environment = cfg['environment'] == 'production' ? 'production' : 'sandbox';
        _dirty = false;
      });

  Map<String, dynamic> get _form => {
        'baseUrl': _baseUrl.text.trim(),
        'tokenUrl': _tokenUrl.text.trim(),
        'clientId': _clientId.text.trim(),
        'clientSecret': _clientSecret.text.trim(),
        'webhookUrl': _webhookUrl.text.trim(),
        'environment': _environment,
      };

  Future<void> _persist(Map<String, dynamic> next, {String? success}) async {
    final ok = await runAdminAction(context, () => ref.read(securityRepositoryProvider).saveElifeConfig(next),
        success: success);
    if (ok && mounted) setState(() => _config = next);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final next = {..._config!, ..._form};
    await _persist(next, success: 'Elife connection settings updated.');
    if (mounted) setState(() => _saving = false);
    if (mounted && _config == next) setState(() => _dirty = false);
  }

  Future<void> _test(bool canEdit) async {
    setState(() => _testing = true);
    final probe = {..._config!, ..._form};
    final result = await ref.read(securityRepositoryProvider).testElifeToken(probe);
    if (!mounted) return;
    final next = applyElifeTest(probe, result);
    if (canEdit) {
      await _persist(next);
      if (mounted && _config == next) setState(() => _dirty = false);
    }
    if (!mounted) return;
    setState(() => _testing = false);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(result.ok ? 'Connection OK' : 'Connection failed'),
        content: Text(result.message),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  Future<void> _clearActivity() async {
    if (!await confirm(context, 'Clear activity log', 'Remove all recorded events?', ok: 'Clear')) return;
    if (mounted) await _persist(clearElifeActivity(_config!));
  }

  Future<void> _openDocs() async {
    await openInApp(context, elifeDocsUrl, title: 'eLife documentation');
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(securityLevelProvider('$apiKeysPage,$_page')) == AccessLevel.edit;
    final cfg = _config;
    return AdminPage(
      title: 'Elife connection',
      page: apiKeysPage,
      actions: [IconButton(tooltip: 'API documentation', icon: const Icon(Icons.description_outlined), onPressed: _openDocs)],
      body: cfg == null
          ? (_loadError != null
              ? EmptyState(
                  icon: Icons.cloud_off,
                  title: 'Something went wrong',
                  message: errorText(_loadError!),
                  action: TextButton(onPressed: _load, child: const Text('Retry')),
                )
              : const Center(child: CircularProgressIndicator()))
          : _body(cfg, canEdit),
    );
  }

  Widget _field(TextEditingController c, String label, String hint, bool canEdit, {bool secret = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c,
          readOnly: !canEdit,
          obscureText: secret && !_revealSecret,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: secret ? TextInputType.visiblePassword : TextInputType.url,
          onChanged: (_) => setState(() => _dirty = true),
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            suffixIcon: secret && canEdit
                ? IconButton(
                    tooltip: 'Show or hide the secret',
                    icon: Icon(_revealSecret ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _revealSecret = !_revealSecret),
                  )
                : null,
          ),
        ),
      );

  Widget _body(Map<String, dynamic> cfg, bool canEdit) {
    final t = Theme.of(context);
    final status = elifeDisplayStatus(cfg);
    final color = switch (status) {
      'connected' => Colors.green,
      'error' => Colors.red,
      'disabled' => Colors.blueGrey,
      _ => Colors.orange,
    };
    final lastChecked = cfg['lastCheckedAt'] is num ? (cfg['lastCheckedAt'] as num).toInt() : null;
    final activity = elifeActivity(cfg);
    return ResponsiveCenter(
      maxWidth: 720,
      child: ListView(padding: const EdgeInsets.symmetric(vertical: 16), children: [
        Card(
          color: color.withValues(alpha: 0.1),
          child: ListTile(
            leading: Icon(
              switch (status) {
                'connected' => Icons.check_circle,
                'error' => Icons.cancel,
                'disabled' => Icons.radio_button_unchecked,
                _ => Icons.warning_amber,
              },
              color: color,
              size: 32,
            ),
            title: Text(elifeStatusLabel(status), style: TextStyle(color: color, fontWeight: FontWeight.w700)),
            subtitle: Text([
              '${lastChecked == null ? 'Never tested' : 'Last checked ${timeAgo(lastChecked)}'}  ·  '
                  '${cfg['environment'] == 'production' ? 'Production' : 'Sandbox'}',
              if (cfg['status'] == 'error' && cfg['lastError'] != null) '${cfg['lastError']}',
            ].join('\n')),
          ),
        ),
        Card(
          child: SwitchListTile(
            title: const Text('Integration enabled'),
            subtitle: const Text('When off, no rides are dispatched to or accepted from Elife.'),
            value: cfg['enabled'] == true,
            onChanged: canEdit ? (v) => _persist(setElifeEnabled(cfg, v)) : null,
          ),
        ),
        const SizedBox(height: 12),
        Text('ENVIRONMENT', style: t.textTheme.labelMedium),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'sandbox', label: Text('Sandbox')),
            ButtonSegment(value: 'production', label: Text('Production')),
          ],
          selected: {_environment},
          onSelectionChanged: canEdit
              ? (s) => setState(() {
                    _environment = s.first;
                    _dirty = true;
                  })
              : null,
        ),
        const SizedBox(height: 16),
        Text('CONNECTION CREDENTIALS', style: t.textTheme.labelMedium),
        const SizedBox(height: 6),
        _field(_baseUrl, 'API base URL', 'https://api.elifetransfer.com', canEdit),
        _field(_tokenUrl, 'OAuth token URL', 'https://api.elifetransfer.com/oauth/token', canEdit),
        _field(_clientId, 'Client ID', 'Enter client ID', canEdit),
        _field(_clientSecret, 'Client Secret', 'Enter client secret', canEdit, secret: true),
        _field(_webhookUrl, 'Webhook URL (optional)', 'https://your-domain.com/elife/webhook', canEdit),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            onPressed: _testing ? null : () => _test(canEdit),
            icon: _testing
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
            label: const Text('Test connection'),
          ),
          if (canEdit)
            FilledButton.icon(
              onPressed: _saving || !_dirty ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(_dirty ? 'Save changes' : 'Saved'),
            ),
        ]),
        const SizedBox(height: 20),
        Row(children: [
          const Icon(Icons.timeline, size: 18),
          const SizedBox(width: 6),
          Expanded(child: Text('ACTIVITY', style: t.textTheme.labelLarge)),
          if (activity.isNotEmpty && canEdit)
            TextButton.icon(onPressed: _clearActivity, icon: const Icon(Icons.delete_outline), label: const Text('Clear')),
        ]),
        if (activity.isEmpty)
          const Card(
            child: ListTile(title: Text('No activity yet. Run a connection test to record events here.')),
          ),
        for (final e in activity)
          ListTile(
            dense: true,
            leading: Icon(e.ok ? Icons.check_circle_outline : Icons.highlight_off, color: e.ok ? Colors.green : Colors.red),
            title: Text(e.message),
            subtitle: Text('${e.kind.toUpperCase()}${e.status != 0 ? ' · HTTP ${e.status}' : ''} · ${timeAgo(e.at)}'),
          ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('API documentation'),
            subtitle: const Text('app.theneo.io/elifetransfer'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openDocs,
          ),
        ),
      ]),
    );
  }
}
