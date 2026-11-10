// Admin → App Settings → Live-selfie verification (migration 0401): per country,
// whether a person must have a verified live selfie (matched to the country they
// are using the service in — current_country, else nationality, else the Master
// default). An approver can also request one from anyone at any time. The server
// enforces it on every booking module.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../widgets/admin_widgets.dart';

/// The per-country live-selfie rule map: country name → required. 'master' is
/// the default. Read from profile_selfie_config() (migration 0401).
final profileSelfieGateConfigProvider = FutureProvider.autoDispose<Map<String, bool>>((ref) async {
  final raw = await ref.watch(supabaseProvider).rpc('profile_selfie_config');
  final map = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
  return {
    for (final e in map.entries)
      e.key: (e.value is Map && (e.value as Map)['require'] == true),
  };
});

class ProfileSelfieGateCard extends ConsumerWidget {
  const ProfileSelfieGateCard({super.key, required this.canEdit});
  final bool canEdit;

  Future<void> _edit(BuildContext context, WidgetRef ref, {String? country, bool require = false}) async {
    final saved = await showAppDialog<({String country, bool require})>(
      id: 'admin.profile-selfie-gate',
      context: context,
      builder: (_) => _SelfieGateDialog(country: country, require: require),
    );
    if (saved == null || !context.mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(supabaseProvider).rpc('set_profile_selfie_gate', params: {
        'p_country': saved.country,
        'p_config': {'require': saved.require},
      }),
      success: 'Live-selfie rule saved',
    );
    if (ok && context.mounted) ref.invalidate(profileSelfieGateConfigProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return Card(
      key: const ValueKey('profile-selfie-gate-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Live-selfie verification', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              'Require a verified live selfie before anyone can transact, per country — matched to where they are '
              'using the service (else their nationality; Master is the fallback). An approver can also request a '
              'fresh selfie from any person at any time. The server enforces it on every booking module.',
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 8),
            AsyncView<Map<String, bool>>(
              value: ref.watch(profileSelfieGateConfigProvider),
              onRetry: () => ref.invalidate(profileSelfieGateConfigProvider),
              data: (config) {
                final master = config['master'] ?? false;
                final countries = [
                  for (final e in config.entries)
                    if (e.key != 'master') e,
                ]..sort((a, b) => a.key.compareTo(b.key));
                Widget row({required String label, required bool isMaster, required bool require}) => ListTile(
                      key: ValueKey('profile-selfie-gate-${isMaster ? 'master' : label}'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(isMaster ? Icons.public : Icons.flag_outlined),
                      title: Text(label),
                      subtitle: Text(require
                          ? 'On — a verified live selfie is required'
                          : 'Off — no live selfie required'),
                      trailing: canEdit
                          ? IconButton(
                              tooltip: 'Edit',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () =>
                                  _edit(context, ref, country: isMaster ? 'master' : label, require: require),
                            )
                          : null,
                    );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    row(label: 'Master (default)', isMaster: true, require: master),
                    for (final e in countries) row(label: e.key, isMaster: false, require: e.value),
                    if (canEdit)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('profile-selfie-gate-add'),
                          icon: const Icon(Icons.add),
                          label: const Text('Add a country rule'),
                          onPressed: () => _edit(context, ref),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Adds or edits one rule: which country (or 'master') and whether a live selfie
/// is required.
class _SelfieGateDialog extends StatefulWidget {
  const _SelfieGateDialog({this.country, required this.require});
  final String? country;
  final bool require;

  @override
  State<_SelfieGateDialog> createState() => _SelfieGateDialogState();
}

class _SelfieGateDialogState extends State<_SelfieGateDialog> {
  late final _country = TextEditingController(
    text: widget.country == 'master' ? '' : (widget.country ?? ''),
  );
  late bool _require = widget.require;

  bool get _isMaster => widget.country == 'master';
  bool get _isNew => widget.country == null;

  @override
  void dispose() {
    _country.dispose();
    super.dispose();
  }

  ({String country, bool require})? _result() {
    final country = _isMaster ? 'master' : _country.text.trim();
    if (country.isEmpty) return null;
    return (country: country, require: _require);
  }

  @override
  Widget build(BuildContext context) {
    final result = _result();
    return AlertDialog(
      title: Text(_isMaster ? 'Master (default)' : (_isNew ? 'Add a country rule' : widget.country!)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_isNew)
              TextField(
                key: const ValueKey('profile-selfie-gate-country'),
                controller: _country,
                decoration: const InputDecoration(
                  labelText: 'Country',
                  helperText: 'As the Country table names it',
                ),
                onChanged: (_) => setState(() {}),
              ),
            SwitchListTile(
              key: const ValueKey('profile-selfie-gate-require'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Require a live selfie'),
              subtitle: const Text('People here must have a verified live selfie before they can transact.'),
              value: _require,
              onChanged: (v) => setState(() => _require = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('profile-selfie-gate-save'),
          onPressed: result == null ? null : () => Navigator.pop(context, result),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
