// Admin → Multi-Gate Places, one place's tools (migration 0258): each tab is
// one optional tool with its own switch at the top — the boundary, "riders
// must pick a door", the pickup guide, the extra charge, own fares and the
// driver waiting queue. The tools themselves are the airports' (airport_tabs);
// these are the parts a place does differently.
import 'package:flutter/material.dart';

import '../../../core/airport_queue.dart';
import '../../../core/format.dart';
import 'airport_tabs.dart';

/// A tool's switch over its settings. Off (or [enabled] false: the place
/// has no boundary yet) the settings under it are dimmed and can't be
/// changed, unless [dimWhenOff] is false.
class PlaceFeatureTab extends StatelessWidget {
  const PlaceFeatureTab({
    super.key,
    required this.switchKey,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.child,
    this.onChanged,
    this.enabled = true,
    this.dimWhenOff = true,
  });

  final Key switchKey;
  final String title, subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget child;

  /// False while the place has no boundary: nothing here works yet.
  final bool enabled;
  final bool dimWhenOff;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final active = enabled && (value || !dimWhenOff);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AirportRow(
                  title: title,
                  subtitle: subtitle,
                  trailing: Switch(
                    key: switchKey,
                    value: enabled && value,
                    onChanged: enabled ? onChanged : null,
                  ),
                ),
                if (!enabled)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      'Switch the boundary on first (Boundary tab).',
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: active ? 1 : 0.45,
            child: IgnorePointer(ignoring: !active, child: child),
          ),
        ),
      ],
    );
  }
}

/// The pickup doors and their step-by-step guides.
class PlaceGuideTab extends StatelessWidget {
  const PlaceGuideTab({
    super.key,
    required this.doors,
    this.onGuide,
    this.openGuideId,
    this.guideEditor,
  });

  final List<AirportDoor> doors;
  final void Function(AirportDoor door)? onGuide;
  final String? openGuideId;
  final Widget? guideEditor;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final pick = [for (final d in doors) if (d.kind != DoorKind.drop) d];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const AirportNote(
          'Photos and short steps for each pickup door, shown to the rider when they choose the door and after '
          'booking. Off: riders see the doors only.',
        ),
        const SizedBox(height: 12),
        if (pick.isEmpty) Text('No pickup doors yet (Doors tab).', style: t.textTheme.bodySmall),
        for (final d in pick)
          Card(
            key: ValueKey('place-guide-door-${d.id}'),
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              title: Text(d.name),
              subtitle: Text(
                d.guide.isEmpty ? 'No guide yet' : '${d.guide.length} step${d.guide.length == 1 ? '' : 's'}',
              ),
              trailing: onGuide == null
                  ? null
                  : TextButton(
                      key: ValueKey('place-guide-edit-${d.id}'),
                      onPressed: () => onGuide!(d),
                      child: Text(openGuideId == d.id ? 'Open' : (d.guide.isEmpty ? 'Add guide' : 'Edit guide')),
                    ),
            ),
          ),
        if (guideEditor != null) ...[const Divider(height: 32), guideEditor!],
      ],
    );
  }
}

/// The extra charge: what a pickup and a drop-off here add, and the label
/// riders see on the fare.
class PlaceChargeTab extends StatelessWidget {
  const PlaceChargeTab({super.key, required this.settings, this.onChanged, this.currency = 'MYR'});

  final AirportSettings settings;
  final ValueChanged<AirportSettings>? onChanged;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final s = settings;
    final on = onChanged;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            AmountField(
              key: const ValueKey('place-charge-pick'),
              value: s.pickFee.amount,
              label: 'Pickup here ($currency)',
              width: 150,
              onChanged: on == null ? null : (v) => on(withPlaceCharge(s, pickAmount: v)),
            ),
            AmountField(
              key: const ValueKey('place-charge-drop'),
              value: s.dropFee.amount,
              label: 'Drop-off here ($currency)',
              width: 150,
              onChanged: on == null ? null : (v) => on(withPlaceCharge(s, dropAmount: v)),
            ),
            SizedBox(
              width: 240,
              child: NameField(
                key: const ValueKey('place-charge-label'),
                value: s.pickFee.name,
                label: 'Label riders see',
                onChanged: on == null ? null : (v) => on(withPlaceCharge(s, label: v)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        AirportNote(
          'Added to the fare of a ride that starts or ends inside the boundary and shown to the rider before they '
          'confirm, e.g. "${s.pickFee.name.trim().isEmpty ? 'Place fee' : s.pickFee.name.trim()} '
          '${formatMoney(s.pickFee.amount, currency)}". 0 adds nothing.',
        ),
      ],
    );
  }
}
