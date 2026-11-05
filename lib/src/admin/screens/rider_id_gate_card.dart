// Admin → App Settings → Rider ID verification (migrations 0342–0344): per
// country, whether a rider must verify a photo ID (and a selfie face-match)
// before their Nth booking, which ID, and the auto-verify threshold. A rider
// is matched to a rule by their profile nationality, else the master default.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/rider_id_gate.dart';
import '../../data/rider_id_gate_repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';
import '../widgets/admin_widgets.dart';
import 'ride_offers_card.dart' show AdminNumberField;

class RiderIdGateCard extends ConsumerWidget {
  const RiderIdGateCard({super.key, required this.canEdit});
  final bool canEdit;

  Future<void> _edit(BuildContext context, WidgetRef ref, {String? country, RiderIdGateRule? rule}) async {
    final saved = await showAppDialog<_RiderIdGateEdit>(
      id: 'admin.rider-id-gate',
      context: context,
      builder: (_) => _RiderIdGateDialog(country: country, rule: rule ?? RiderIdGateRule.standard),
    );
    if (saved == null || !context.mounted) return;
    final ok = await runAdminAction(
      context,
      () => ref.read(supabaseProvider).rpc('set_rider_id_gate', params: {
        'p_country': saved.country,
        'p_config': saved.rule.toJson(),
      }),
      success: 'Rider ID rule saved',
    );
    if (ok && context.mounted) ref.invalidate(riderIdGateConfigProvider);
  }

  String _summary(RiderIdGateRule r) {
    if (!r.require) return 'Off — riders book without verifying';
    final when = r.nthBooking == 1 ? 'before booking #1' : 'before booking #${r.nthBooking}';
    final id = switch (r.idType) { 'national' => 'National ID', 'passport' => 'Passport', _ => 'National ID or Passport' };
    return '$id · $when${r.selfie ? ' · selfie match' : ''}${r.allowPhoto ? '' : ' · live only'}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return Card(
      key: const ValueKey('rider-id-gate-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Rider ID verification', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              'Require a rider to verify a photo ID before booking, per country. A rider is matched by their '
              'profile nationality; Master is the fallback. A strong live-selfie face match verifies them at '
              'once, below the threshold an admin reviews it. The server enforces it on every booking module.',
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 8),
            AsyncView(
              value: ref.watch(riderIdGateConfigProvider),
              onRetry: () => ref.invalidate(riderIdGateConfigProvider),
              data: (config) {
                final master = config.rules['master'] ?? RiderIdGateRule.standard;
                final countries = [
                  for (final e in config.rules.entries)
                    if (e.key != 'master') e,
                ]..sort((a, b) => a.key.compareTo(b.key));
                Widget row({required String label, required bool isMaster, required RiderIdGateRule rule}) => ListTile(
                      key: ValueKey('rider-id-gate-${isMaster ? 'master' : label}'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(isMaster ? Icons.public : Icons.flag_outlined),
                      title: Text(label),
                      subtitle: Text(_summary(rule)),
                      trailing: canEdit
                          ? IconButton(
                              tooltip: 'Edit',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _edit(context, ref, country: isMaster ? 'master' : label, rule: rule),
                            )
                          : null,
                    );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    row(label: 'Master (default)', isMaster: true, rule: master),
                    for (final e in countries) row(label: e.key, isMaster: false, rule: e.value),
                    if (canEdit)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('rider-id-gate-add'),
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

/// The dialog's result: which country (or 'master') and the rule to save.
class _RiderIdGateEdit {
  const _RiderIdGateEdit(this.country, this.rule);
  final String country;
  final RiderIdGateRule rule;
}

/// Adds or edits one rule. A new rule names its country; editing keeps it.
class _RiderIdGateDialog extends StatefulWidget {
  const _RiderIdGateDialog({this.country, required this.rule});
  final String? country;
  final RiderIdGateRule rule;

  @override
  State<_RiderIdGateDialog> createState() => _RiderIdGateDialogState();
}

class _RiderIdGateDialogState extends State<_RiderIdGateDialog> {
  late final _country = TextEditingController(
    text: widget.country == 'master' ? '' : (widget.country ?? ''),
  );
  late final _nth = TextEditingController(text: '${widget.rule.nthBooking}');
  late final _score = TextEditingController(text: '${widget.rule.autoVerifyScore}');
  late bool _require = widget.rule.require;
  late String _idType = widget.rule.idType;
  late bool _selfie = widget.rule.selfie;
  late bool _allowPhoto = widget.rule.allowPhoto;

  bool get _isMaster => widget.country == 'master';
  bool get _isNew => widget.country == null;

  @override
  void dispose() {
    for (final c in [_country, _nth, _score]) {
      c.dispose();
    }
    super.dispose();
  }

  _RiderIdGateEdit? _result() {
    final country = _isMaster ? 'master' : _country.text.trim();
    if (country.isEmpty) return null;
    if (!_require) {
      return _RiderIdGateEdit(country, const RiderIdGateRule(require: false));
    }
    final nth = AdminNumberField.read(_nth, RiderIdGateRule.minNth, RiderIdGateRule.maxNth);
    final score = AdminNumberField.read(_score, RiderIdGateRule.minScore, RiderIdGateRule.maxScore);
    if (nth == null || score == null) return null;
    return _RiderIdGateEdit(
      country,
      RiderIdGateRule(
        require: true,
        idType: _idType,
        nthBooking: nth.toInt(),
        selfie: _selfie,
        allowPhoto: _allowPhoto,
        autoVerifyScore: score.toInt(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _result();
    return AlertDialog(
      title: Text(_isMaster ? 'Master (default)' : (_isNew ? 'Add a country rule' : widget.country!)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_isNew)
                TextField(
                  key: const ValueKey('rider-id-gate-country'),
                  controller: _country,
                  decoration: const InputDecoration(
                    labelText: 'Country',
                    helperText: 'As the Country table names it (matched to the rider\'s nationality)',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              SwitchListTile(
                key: const ValueKey('rider-id-gate-require'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Require ID verification'),
                subtitle: const Text('Riders here verify a photo ID before they can book.'),
                value: _require,
                onChanged: (v) => setState(() => _require = v),
              ),
              if (_require) ...[
                const SizedBox(height: 4),
                SearchableDropdownFormField<String>(
                  key: const ValueKey('rider-id-gate-idtype'),
                  initialValue: _idType,
                  decoration: const InputDecoration(labelText: 'Accepted ID'),
                  items: const [
                    DropdownMenuItem(value: 'national', child: Text('National ID')),
                    DropdownMenuItem(value: 'passport', child: Text('Passport')),
                    DropdownMenuItem(value: 'either', child: Text('Either')),
                  ],
                  onChanged: (v) => setState(() => _idType = v ?? _idType),
                ),
                const SizedBox(height: 8),
                AdminNumberField(
                  key: const ValueKey('rider-id-gate-nth'),
                  controller: _nth,
                  label: 'Required before booking #',
                  min: RiderIdGateRule.minNth,
                  max: RiderIdGateRule.maxNth,
                  onChanged: () => setState(() {}),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  key: const ValueKey('rider-id-gate-selfie'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Selfie face match'),
                  subtitle: const Text('A live selfie compared to the ID photo.'),
                  value: _selfie,
                  onChanged: (v) => setState(() => _selfie = v),
                ),
                SwitchListTile(
                  key: const ValueKey('rider-id-gate-allow-photo'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Allow a saved photo'),
                  subtitle: const Text('Off means the ID must be captured live with the camera (native-enforced).'),
                  value: _allowPhoto,
                  onChanged: (v) => setState(() => _allowPhoto = v),
                ),
                const SizedBox(height: 8),
                AdminNumberField(
                  key: const ValueKey('rider-id-gate-score'),
                  controller: _score,
                  label: 'Auto-verify at face score ≥',
                  min: RiderIdGateRule.minScore,
                  max: RiderIdGateRule.maxScore,
                  onChanged: () => setState(() {}),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'At or above this score a strong match verifies the rider at once; below it an admin reviews it.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('rider-id-gate-save'),
          onPressed: result == null ? null : () => Navigator.pop(context, result),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
