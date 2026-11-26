// Admin → App Settings → Rider verification: one per-country choice that
// combines the eKYC/ID gate (migrations 0342–0344) and the live-selfie gate
// (0401) — None, Live selfie, eKYC, or Both. A rider is matched by where they
// are now (current_country), then their nationality, then the Master default.
// Saving writes both underlying rules; the server enforces them on every
// booking module.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/rider_id_gate.dart';
import '../../data/rider_id_gate_repository.dart';
import '../../providers.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/search_select.dart';
import '../widgets/admin_widgets.dart';
import 'ride_offers_card.dart' show AdminNumberField;

class RiderIdGateCard extends ConsumerWidget {
  const RiderIdGateCard({super.key, required this.canEdit});
  final bool canEdit;

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, {
    String? country,
    RiderVerifyMethod method = RiderVerifyMethod.none,
    RiderIdGateRule rule = RiderIdGateRule.standard,
  }) async {
    final saved = await showAppDialog<_RiderVerifyEdit>(
      id: 'admin.rider-id-gate',
      context: context,
      builder: (_) => _RiderVerifyDialog(country: country, method: method, rule: rule),
    );
    if (saved == null || !context.mounted) return;
    final ok = await runAdminAction(
      context,
      () async {
        final db = ref.read(supabaseProvider);
        // The eKYC/ID rule (0342): require follows the method; its detail fields
        // are kept whether or not eKYC is on, so turning it back on restores them.
        await db.rpc('set_rider_id_gate', params: {'p_country': saved.country, 'p_config': saved.rule.toJson()});
        // The live-selfie rule (0401): just require, from the method.
        await db.rpc('set_profile_selfie_gate',
            params: {'p_country': saved.country, 'p_config': {'require': saved.method.selfieRequired}});
      },
      success: 'Rider verification saved',
    );
    if (ok && context.mounted) {
      ref.invalidate(riderIdGateConfigProvider);
      ref.invalidate(profileSelfieGateConfigProvider);
    }
  }

  String _summary(RiderVerifyMethod m, RiderIdGateRule r) {
    if (m == RiderVerifyMethod.none) return 'Off — riders book without verifying';
    final parts = <String>[];
    if (m.idRequired) {
      final id = switch (r.idType) {
        'national' => 'National ID',
        'passport' => 'Passport',
        'licence' => 'Driving licence',
        _ => 'National ID, Passport or Driving licence',
      };
      final when = r.nthBooking == 1 ? 'before booking #1' : 'before booking #${r.nthBooking}';
      parts.add('eKYC: $id · $when');
    }
    if (m.selfieRequired) parts.add('live selfie on record');
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    final idAsync = ref.watch(riderIdGateConfigProvider);
    final selfieAsync = ref.watch(profileSelfieGateConfigProvider);
    void retry() {
      ref.invalidate(riderIdGateConfigProvider);
      ref.invalidate(profileSelfieGateConfigProvider);
    }

    return Card(
      key: const ValueKey('rider-id-gate-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Rider verification', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              'Require a rider to verify before booking, per country — a live selfie, eKYC ID, or both. A rider is '
              'matched by where they are (then their nationality); Master is the fallback. A strong live-selfie '
              'face match verifies eKYC at once, below the threshold an admin reviews it. The server enforces it '
              'on every booking module.',
              style: t.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 8),
            if (idAsync.isLoading || selfieAsync.isLoading)
              const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
            else if (idAsync.hasError || selfieAsync.hasError)
              Row(children: [
                const Expanded(child: Text('Could not load the rules.')),
                TextButton(onPressed: retry, child: const Text('Retry')),
              ])
            else
              _list(context, ref, idAsync.value ?? RiderIdGateConfig.empty, selfieAsync.value ?? const {}),
          ],
        ),
      ),
    );
  }

  Widget _list(BuildContext context, WidgetRef ref, RiderIdGateConfig idConfig, Map<String, bool> selfie) {
    RiderIdGateRule idRule(String c) => idConfig.rules[c] ?? RiderIdGateRule.standard;
    RiderVerifyMethod methodFor(String c) => RiderVerifyMethod.of(
          idRequired: idConfig.rules[c]?.require ?? false,
          selfieRequired: selfie[c] ?? false,
        );

    final countries = ({...idConfig.rules.keys, ...selfie.keys}..remove('master')).toList()..sort();

    Widget row({required String label, required String key, required bool isMaster}) {
      final m = methodFor(key);
      return ListTile(
        key: ValueKey('rider-id-gate-${isMaster ? 'master' : key}'),
        contentPadding: EdgeInsets.zero,
        leading: Icon(isMaster ? Icons.public : Icons.flag_outlined),
        title: Text(label),
        subtitle: Text(_summary(m, idRule(key))),
        trailing: canEdit
            ? IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => _edit(context, ref, country: isMaster ? 'master' : key, method: m, rule: idRule(key)),
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
              key: const ValueKey('rider-id-gate-add'),
              icon: const Icon(Icons.add),
              label: const Text('Add a country rule'),
              onPressed: () => _edit(context, ref),
            ),
          ),
      ],
    );
  }
}

/// The dialog's result: which country (or 'master'), the chosen method, and the
/// eKYC rule to store (its require follows the method).
class _RiderVerifyEdit {
  const _RiderVerifyEdit(this.country, this.method, this.rule);
  final String country;
  final RiderVerifyMethod method;
  final RiderIdGateRule rule;
}

/// Adds or edits one country's verification. A new rule names its country.
class _RiderVerifyDialog extends StatefulWidget {
  const _RiderVerifyDialog({this.country, required this.method, required this.rule});
  final String? country;
  final RiderVerifyMethod method;
  final RiderIdGateRule rule;

  @override
  State<_RiderVerifyDialog> createState() => _RiderVerifyDialogState();
}

class _RiderVerifyDialogState extends State<_RiderVerifyDialog> {
  late final _country = TextEditingController(text: widget.country == 'master' ? '' : (widget.country ?? ''));
  late final _nth = TextEditingController(text: '${widget.rule.nthBooking}');
  late final _score = TextEditingController(text: '${widget.rule.autoVerifyScore}');
  late RiderVerifyMethod _method = widget.method;
  late String _idType = widget.rule.idType;
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

  _RiderVerifyEdit? _result() {
    final country = _isMaster ? 'master' : _country.text.trim();
    if (country.isEmpty) return null;
    if (!_method.idRequired) {
      // eKYC off: keep the detail fields as typed so turning it back on restores
      // them, but store require=false.
      final nth = AdminNumberField.read(_nth, RiderIdGateRule.minNth, RiderIdGateRule.maxNth);
      final score = AdminNumberField.read(_score, RiderIdGateRule.minScore, RiderIdGateRule.maxScore);
      return _RiderVerifyEdit(
        country,
        _method,
        RiderIdGateRule(
          require: false,
          idType: _idType,
          nthBooking: (nth ?? RiderIdGateRule.defaultNthBooking).toInt(),
          selfie: widget.rule.selfie,
          allowPhoto: _allowPhoto,
          autoVerifyScore: (score ?? RiderIdGateRule.defaultAutoVerifyScore).toInt(),
        ),
      );
    }
    final nth = AdminNumberField.read(_nth, RiderIdGateRule.minNth, RiderIdGateRule.maxNth);
    final score = AdminNumberField.read(_score, RiderIdGateRule.minScore, RiderIdGateRule.maxScore);
    if (nth == null || score == null) return null;
    return _RiderVerifyEdit(
      country,
      _method,
      RiderIdGateRule(
        require: true,
        idType: _idType,
        nthBooking: nth.toInt(),
        selfie: widget.rule.selfie,
        allowPhoto: _allowPhoto,
        autoVerifyScore: score.toInt(),
      ),
    );
  }

  String _hint(RiderVerifyMethod m) => switch (m) {
        RiderVerifyMethod.none => 'Riders here book without verifying.',
        RiderVerifyMethod.liveSelfie => 'Riders take a fresh live selfie, kept on record and approver-verified.',
        RiderVerifyMethod.ekyc => 'Riders verify a photo ID via GET eKYC.',
        RiderVerifyMethod.both => 'Riders verify a photo ID via GET eKYC and take a live selfie on record.',
      };

  @override
  Widget build(BuildContext context) {
    final result = _result();
    final showEkyc = _method.idRequired;
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
                    helperText: 'As the Country table names it (matched to where the rider is, then nationality)',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              const SizedBox(height: 8),
              SearchableDropdownFormField<RiderVerifyMethod>(
                key: const ValueKey('rider-verify-method'),
                initialValue: _method,
                decoration: const InputDecoration(labelText: 'Verification method'),
                items: [
                  for (final m in RiderVerifyMethod.values) DropdownMenuItem(value: m, child: Text(m.label)),
                ],
                onChanged: (v) => setState(() => _method = v ?? _method),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _hint(_method),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              if (showEkyc) ...[
                const SizedBox(height: 12),
                SearchableDropdownFormField<String>(
                  key: const ValueKey('rider-id-gate-idtype'),
                  initialValue: _idType,
                  decoration: const InputDecoration(labelText: 'Accepted ID (eKYC)'),
                  items: const [
                    DropdownMenuItem(value: 'national', child: Text('National ID')),
                    DropdownMenuItem(value: 'passport', child: Text('Passport')),
                    DropdownMenuItem(value: 'licence', child: Text('Driving licence')),
                    DropdownMenuItem(value: 'either', child: Text('Any (ID, passport or licence)')),
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
