// Admin → App Settings → Partner verification: a per-country switch requiring
// partners to verify their identity (ID + live selfie) at the first step of
// registration (migration 0442). Independent of the rider gate — a country may
// gate riders, partners, both or neither. A partner is matched by their service
// country, then their nationality, then the Master default.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/partner_id_gate.dart';
import '../../features/partner/partner_id_gate_flow.dart' show partnerIdGateConfigProvider;
import '../../providers.dart';
import '../../widgets/page_style_host.dart';
import '../widgets/admin_widgets.dart';

class PartnerIdGateCard extends ConsumerWidget {
  const PartnerIdGateCard({super.key, required this.canEdit});
  final bool canEdit;

  Future<void> _edit(BuildContext context, WidgetRef ref, {String? country, bool require = false}) async {
    final saved = await showAppDialog<_PartnerVerifyEdit>(
      id: 'admin.partner-id-gate',
      context: context,
      builder: (_) => _PartnerVerifyDialog(country: country, require: require),
    );
    if (saved == null || !context.mounted) return;
    final ok = await runAdminAction(
      context,
      () async {
        await ref.read(supabaseProvider).rpc('set_partner_id_gate',
            params: {'p_country': saved.country, 'p_config': {'require': saved.require}});
      },
      success: 'Partner verification saved',
    );
    if (ok && context.mounted) ref.invalidate(partnerIdGateConfigProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final async = ref.watch(partnerIdGateConfigProvider);
    return Card(
      key: const ValueKey('partner-id-gate-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Partner verification', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              'Require a partner to verify their identity (ID and a live selfie) at the first step of '
              'registration, per country. A partner is matched by their service country, then their '
              'nationality; Master is the fallback. A verified identity replaces the National ID and photo '
              'steps, and a citizens-only service always needs a citizen ID. The admin review of each '
              'application is the backstop.',
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 8),
            if (async.isLoading)
              const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
            else if (async.hasError)
              Row(children: [
                const Expanded(child: Text('Could not load the rules.')),
                TextButton(onPressed: () => ref.invalidate(partnerIdGateConfigProvider), child: const Text('Retry')),
              ])
            else
              _list(context, ref, async.value ?? PartnerIdGateConfig.empty),
          ],
        ),
      ),
    );
  }

  Widget _list(BuildContext context, WidgetRef ref, PartnerIdGateConfig config) {
    final countries = (config.require.keys.toSet()..remove('master')).toList()..sort();
    bool req(String c) => config.require[c] ?? false;

    Widget row({required String label, required String key, required bool isMaster}) {
      final on = req(key);
      return ListTile(
        key: ValueKey('partner-id-gate-${isMaster ? 'master' : key}'),
        contentPadding: EdgeInsets.zero,
        leading: Icon(isMaster ? Icons.public : Icons.flag_outlined),
        title: Text(label),
        subtitle: Text(on ? 'Verify identity before registering' : 'Off — register without verifying'),
        trailing: canEdit
            ? IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => _edit(context, ref, country: isMaster ? 'master' : key, require: on),
              )
            : null,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row(label: 'Master (default)', key: 'master', isMaster: true),
        for (final c in countries) row(label: c, key: c, isMaster: false),
        if (canEdit)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('partner-id-gate-add'),
              icon: const Icon(Icons.add),
              label: const Text('Add a country rule'),
              onPressed: () => _edit(context, ref),
            ),
          ),
      ],
    );
  }
}

/// The dialog's result: which country (or 'master') and whether to require it.
class _PartnerVerifyEdit {
  const _PartnerVerifyEdit(this.country, this.require);
  final String country;
  final bool require;
}

/// Adds or edits one country's partner verification requirement.
class _PartnerVerifyDialog extends StatefulWidget {
  const _PartnerVerifyDialog({this.country, required this.require});
  final String? country;
  final bool require;

  @override
  State<_PartnerVerifyDialog> createState() => _PartnerVerifyDialogState();
}

class _PartnerVerifyDialogState extends State<_PartnerVerifyDialog> {
  late final _country = TextEditingController(text: widget.country == 'master' ? '' : (widget.country ?? ''));
  late bool _require = widget.require;

  bool get _isMaster => widget.country == 'master';
  bool get _isNew => widget.country == null;

  @override
  void dispose() {
    _country.dispose();
    super.dispose();
  }

  _PartnerVerifyEdit? _result() {
    final country = _isMaster ? 'master' : _country.text.trim();
    if (country.isEmpty) return null;
    return _PartnerVerifyEdit(country, _require);
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
                key: const ValueKey('partner-id-gate-country'),
                controller: _country,
                decoration: const InputDecoration(
                  labelText: 'Country',
                  helperText: "As the Country table names it (matched to the partner's service country, then nationality)",
                ),
                onChanged: (_) => setState(() {}),
              ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const ValueKey('partner-id-gate-require'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Require identity verification'),
              subtitle: const Text('Partners here verify their ID and a live selfie before they can register.'),
              value: _require,
              onChanged: (v) => setState(() => _require = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('partner-id-gate-save'),
          onPressed: result == null ? null : () => Navigator.pop(context, result),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
