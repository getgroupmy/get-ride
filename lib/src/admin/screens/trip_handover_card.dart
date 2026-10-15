// Admin → App Settings → Trip handover (migration 0199): whether a driver
// may hand a trip over mid-way, the share of the net earnings the partner
// who takes over passes back, how far "nearby" reaches, and how long each
// side has to answer. Regions can set their own share.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/trip_handover.dart';
import '../../data/trip_handover_repository.dart';
import '../../widgets/busy.dart';
import '../../widgets/common.dart';
import '../widgets/admin_widgets.dart';

class TripHandoverCard extends ConsumerWidget {
  const TripHandoverCard({super.key, required this.canEdit});

  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    return Card(
      key: const ValueKey('trip-handover-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Trip handover', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              'Once a trip has started, its driver can ask another partner to take over: one they choose by code, '
              'or the first partner nearby to accept. The passenger approves first. The partner who takes over '
              'collects the fare and pays the commission, then passes a share of the net earnings to the first '
              'driver as GET credit.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            AsyncView(
              value: ref.watch(tripHandoverConfigProvider),
              onRetry: () => ref.invalidate(tripHandoverConfigProvider),
              data: (c) => _ConfigForm(key: ValueKey(c), stored: c, canEdit: canEdit),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfigForm extends ConsumerStatefulWidget {
  const _ConfigForm({super.key, required this.stored, required this.canEdit});

  final TripHandoverConfig stored;
  final bool canEdit;

  @override
  ConsumerState<_ConfigForm> createState() => _ConfigFormState();
}

class _ConfigFormState extends ConsumerState<_ConfigForm> {
  late bool _enabled = widget.stored.enabled;
  late final _share = TextEditingController(text: _plain(widget.stored.sharePercent));
  late final _radius = TextEditingController(text: _plain(widget.stored.nearbyRadiusKm));
  late final _answer = TextEditingController(text: '${widget.stored.answerMinutes}');

  static String _plain(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

  @override
  void dispose() {
    _share.dispose();
    _radius.dispose();
    _answer.dispose();
    super.dispose();
  }

  TripHandoverConfig? _draft() {
    final share = double.tryParse(_share.text.trim());
    final radius = double.tryParse(_radius.text.trim());
    final answer = int.tryParse(_answer.text.trim());
    if (share == null || radius == null || answer == null) return null;
    return TripHandoverConfig(enabled: _enabled, sharePercent: share, nearbyRadiusKm: radius, answerMinutes: answer);
  }

  Future<void> _save() async {
    final c = _draft();
    final problem = c == null ? 'Every field needs a number.' : c.problem;
    if (problem != null) {
      showInfo(context, problem);
      return;
    }
    final saved = await runAdminAction(
      context,
      () => ref.read(tripHandoverRepositoryProvider).saveConfig(c!),
      success: 'Trip handover saved',
    );
    if (saved && mounted) ref.invalidate(tripHandoverConfigProvider);
  }

  Widget _number(String key, TextEditingController c, String label, String hint, {bool decimal = false}) => SizedBox(
    width: 220,
    child: TextField(
      key: ValueKey('handover-$key'),
      controller: c,
      enabled: widget.canEdit,
      keyboardType: TextInputType.numberWithOptions(decimal: decimal),
      decoration: InputDecoration(labelText: label, helperText: hint, helperMaxLines: 2),
      onChanged: (_) => setState(() {}),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final edit = widget.canEdit;
    final draft = _draft();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey('handover-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Trip handover on'),
          subtitle: const Text('Off: drivers see no "Hand over trip" button.'),
          value: _enabled,
          onChanged: edit ? (v) => setState(() => _enabled = v) : null,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            _number('share', _share, 'Share to the first driver (%)', 'Of the net earnings; 0–100', decimal: true),
            _number('radius', _radius, 'Nearby partners within (km)', '0.5–50', decimal: true),
            _number('answer', _answer, 'Time to answer (minutes)', 'For the passenger, then the partners; 1–30'),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Net earnings are the fare less the commission and platform charges. A country, state, city or suburb '
            'can set its own share under Regions (Handover share %); the most specific one wins.',
            style: t.textTheme.bodySmall,
          ),
        ),
        if (edit) ...[
          const SizedBox(height: 12),
          BusyButton.filled(
            key: const ValueKey('handover-save'),
            onPressed: draft == widget.stored ? null : _save,
            icon: const Icon(Icons.save_outlined),
            child: const Text('Save trip handover'),
          ),
        ],
      ],
    );
  }
}
