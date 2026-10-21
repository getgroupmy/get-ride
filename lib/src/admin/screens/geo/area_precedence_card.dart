import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/airport_areas.dart';
import '../../../data/area_precedence_repository.dart';
import '../../widgets/admin_widgets.dart';

/// Admin → Airport Areas, above the airports: which area a pickup or drop-off
/// inside both an airport's and a place's boundary is at (migration 0266).
/// The app and the server's area_at read the same setting, so a booking
/// always matches the doors shown. Read-only without edit rights.
class AreaPrecedenceCard extends ConsumerStatefulWidget {
  const AreaPrecedenceCard({super.key, required this.canEdit});
  final bool canEdit;

  @override
  ConsumerState<AreaPrecedenceCard> createState() => _AreaPrecedenceCardState();
}

/// Each choice's title and line, in the card's order.
const areaPrecedenceChoices = <(AreaPrecedence, String, String)>[
  (
    AreaPrecedence.partOf,
    'The place, unless it is part of the airport',
    'A place with the same "Part of" as the airport (KLIA T1/T2 ERL) stays under the airport. '
        'Others (Mitsui Outlet Park) use their own doors.',
  ),
  (
    AreaPrecedence.place,
    'Always the place',
    'Any place with a boundary inside an airport uses its own doors and is not treated as the airport.',
  ),
  (
    AreaPrecedence.airport,
    'Always the airport',
    "The airport's doors, queue and fare everywhere inside its boundary (how it worked before).",
  ),
];

class _AreaPrecedenceCardState extends ConsumerState<AreaPrecedenceCard> {
  /// The choice made here and not saved yet; null shows the stored one.
  AreaPrecedence? _picked;
  bool _saving = false;

  Future<void> _save(AreaPrecedence mode) async {
    setState(() => _saving = true);
    final ok = await runAdminAction(
      context,
      () => ref.read(areaPrecedenceRepositoryProvider).setMode(mode),
      success: 'Places inside an airport saved',
    );
    if (!mounted) return;
    if (ok) ref.invalidate(areaPrecedenceProvider);
    setState(() {
      _saving = false;
      if (ok) _picked = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final stored = ref.watch(areaPrecedenceProvider).value ?? AreaPrecedence.partOf;
    final shown = _picked ?? stored;
    final good = t.brightness == Brightness.dark ? const Color(0xFF4FD39B) : const Color(0xFF17885E);
    return Card(
      key: const ValueKey('area-precedence-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Places inside an airport', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              "When a pickup or drop-off is inside an airport's boundary and also inside a place's boundary "
              "(a mall, a station), which one's doors, queue and fare apply.",
              style: t.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            RadioGroup<AreaPrecedence>(
              groupValue: shown,
              onChanged: (v) {
                if (widget.canEdit && v != null) setState(() => _picked = v);
              },
              child: Column(
                children: [
                  for (final (mode, title, line) in areaPrecedenceChoices)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: RadioListTile<AreaPrecedence>(
                        key: ValueKey('area-precedence-${mode.key}'),
                        value: mode,
                        enabled: widget.canEdit,
                        selected: mode == shown,
                        selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.45),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: mode == shown ? scheme.primary : scheme.outlineVariant,
                            width: 1.5,
                          ),
                        ),
                        title: Text.rich(
                          TextSpan(
                            text: title,
                            children: [
                              if (mode == AreaPrecedence.partOf)
                                TextSpan(
                                  text: '  DEFAULT',
                                  style: t.textTheme.labelSmall?.copyWith(color: good, fontWeight: FontWeight.w700),
                                ),
                            ],
                          ),
                          style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface),
                        ),
                        subtitle: Text(line),
                      ),
                    ),
                ],
              ),
            ),
            if (widget.canEdit)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const ValueKey('area-precedence-save'),
                  onPressed: _saving || shown == stored ? null : () => _save(shown),
                  child: const Text('Save'),
                ),
              )
            else
              Text(
                'Only admins who can edit Airport Areas can change this.',
                key: const ValueKey('area-precedence-read-only'),
                style: t.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}
