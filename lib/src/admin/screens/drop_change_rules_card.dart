// Admin → App Settings → Mid-ride drop-off change (migration 0341): whether a
// passenger may move the drop on an ongoing ride, which changes apply at once
// vs. need the driver, how long the driver has to answer, and how many changes
// one ride allows.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/drop_change.dart';
import '../../data/city_ride_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../widgets/admin_widgets.dart';
import 'ride_offers_card.dart' show AdminNumberField;

class DropChangeRulesCard extends ConsumerStatefulWidget {
  const DropChangeRulesCard({super.key, required this.canEdit});
  final bool canEdit;

  @override
  ConsumerState<DropChangeRulesCard> createState() => _DropChangeRulesCardState();
}

class _DropChangeRulesCardState extends ConsumerState<DropChangeRulesCard> {
  final _rm = TextEditingController();
  final _pct = TextEditingController();
  final _window = TextEditingController();
  final _maxChanges = TextEditingController();
  bool _allow = true;
  bool _cheaper = true;
  DropChangeSettings? _loaded;

  @override
  void dispose() {
    for (final c in [_rm, _pct, _window, _maxChanges]) {
      c.dispose();
    }
    super.dispose();
  }

  void _load(DropChangeSettings s) {
    if (_loaded == s) return;
    _loaded = s;
    _rm.text = '${s.autoApproveRm}';
    _pct.text = '${s.autoApprovePct}';
    _window.text = '${s.responseWindowSec}';
    _maxChanges.text = '${s.maxChangesPerRide}';
    _allow = s.allow;
    _cheaper = s.autoApproveCheaper;
  }

  DropChangeSettings? _draft() {
    final rm = AdminNumberField.read(_rm, DropChangeSettings.minRm, DropChangeSettings.maxRm);
    final pct = AdminNumberField.read(_pct, DropChangeSettings.minPct, DropChangeSettings.maxPct);
    final win = AdminNumberField.read(_window, DropChangeSettings.minWindow, DropChangeSettings.maxWindow);
    final mx = AdminNumberField.read(_maxChanges, DropChangeSettings.minMax, DropChangeSettings.maxMax);
    if (rm == null || pct == null || win == null || mx == null) return null;
    return DropChangeSettings(
      allow: _allow,
      autoApproveCheaper: _cheaper,
      autoApproveRm: rm.toInt(),
      autoApprovePct: pct.toInt(),
      responseWindowSec: win.toInt(),
      maxChangesPerRide: mx.toInt(),
    );
  }

  Future<void> _save() async {
    final d = _draft();
    if (d == null) {
      showInfo(context, 'Check the numbers: each must be within its limits.');
      return;
    }
    final ok = await runAdminAction(
      context,
      () => ref.read(cityRideRepositoryProvider).saveConfig('dropChange', d.toJson()),
      success: 'Drop-off change rules saved',
    );
    if (ok && mounted) ref.invalidate(cityRideConfigProvider);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.colorScheme.onSurfaceVariant;
    return Card(
      key: const ValueKey('drop-change-rules-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AsyncView(
          value: ref.watch(cityRideConfigProvider),
          onRetry: () => ref.invalidate(cityRideConfigProvider),
          data: (c) {
            _load(c.dropChange);
            final draft = _draft();
            void edited() => setState(() {});
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Mid-ride drop-off change',
                    style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  'A passenger can move the drop-off during an ongoing ride; the fare re-computes. A cheaper '
                  'change (or an increase within the threshold below) applies at once; a bigger increase is held '
                  'for the driver to accept or reject.',
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  key: const ValueKey('drop-change-allow'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Allow changing drop-off on an active ride'),
                  subtitle: const Text('When off, the drop is fixed once the ride starts.'),
                  value: _allow,
                  onChanged: widget.canEdit ? (v) => setState(() => _allow = v) : null,
                ),
                if (_allow) ...[
                  SwitchListTile(
                    key: const ValueKey('drop-change-cheaper'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Auto-approve when it is cheaper'),
                    subtitle: const Text('A change that lowers or keeps the fare applies instantly, no driver ask.'),
                    value: _cheaper,
                    onChanged: widget.canEdit ? (v) => setState(() => _cheaper = v) : null,
                  ),
                  const SizedBox(height: 4),
                  Text('Auto-approve an increase up to the larger of:', style: t.textTheme.bodySmall?.copyWith(color: muted)),
                  const SizedBox(height: 8),
                  AdminNumberField(
                    key: const ValueKey('drop-change-rm'),
                    controller: _rm,
                    label: 'Amount (RM)',
                    min: DropChangeSettings.minRm,
                    max: DropChangeSettings.maxRm,
                    enabled: widget.canEdit,
                    onChanged: edited,
                  ),
                  const SizedBox(height: 8),
                  AdminNumberField(
                    key: const ValueKey('drop-change-pct'),
                    controller: _pct,
                    label: 'or percent of the current fare (%)',
                    min: DropChangeSettings.minPct,
                    max: DropChangeSettings.maxPct,
                    enabled: widget.canEdit,
                    onChanged: edited,
                  ),
                  const SizedBox(height: 8),
                  AdminNumberField(
                    key: const ValueKey('drop-change-window'),
                    controller: _window,
                    label: 'Driver response window (seconds)',
                    min: DropChangeSettings.minWindow,
                    max: DropChangeSettings.maxWindow,
                    enabled: widget.canEdit,
                    onChanged: edited,
                  ),
                  const SizedBox(height: 8),
                  AdminNumberField(
                    key: const ValueKey('drop-change-max'),
                    controller: _maxChanges,
                    label: 'Max changes per ride',
                    min: DropChangeSettings.minMax,
                    max: DropChangeSettings.maxMax,
                    enabled: widget.canEdit,
                    onChanged: edited,
                  ),
                ],
                const SizedBox(height: 12),
                if (widget.canEdit)
                  BusyButton.filled(
                    key: const ValueKey('drop-change-save'),
                    onPressed: draft == c.dropChange ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    child: const Text('Save drop-off change rules'),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
