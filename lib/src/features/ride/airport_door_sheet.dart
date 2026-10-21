// The rider's door at an airport (migration 0249): "Which door are you going
// to?" when the ride ends at an airport, "Where should the driver pick you
// up?" when it starts at one. A pickup door with a guide offers "How to get
// there · N steps ›": photo, "Step x of n", text, dots, Back / Next, and
// "Pick up here" on the last step, which chooses that door.
import 'package:flutter/material.dart';

import '../../core/airport_queue.dart';
import '../../core/format.dart';
import '../../widgets/page_style_host.dart';
import '../../widgets/storage_image.dart';

/// Opens the door sheet; answers the door chosen, or null when it was closed.
Future<AirportDoor?> showAirportDoorSheet(
  BuildContext context, {
  required String airportName,
  required AirportSide side,
  required List<AirportDoor> doors,
  AirportCharge? charge,
  String currency = 'MYR',
  String? selectedId,
}) => showAppSheet<AirportDoor>(
  id: 'ride.airport-doors',
  context: context,
  fitContent: true,
  showDragHandle: true,
  builder: (_) => AirportDoorSheet(
    airportName: airportName,
    side: side,
    doors: doors,
    charge: charge,
    currency: currency,
    selectedId: selectedId,
    onDone: (d) => Navigator.of(context).pop(d),
  ),
);

/// A guide on its own (Admin → Airport Areas → "Preview as rider").
Future<void> showAirportGuidePreview(BuildContext context, AirportDoor door) =>
    showAppSheet<void>(
      id: 'airport-areas.guide-preview',
      context: context,
      fitContent: true,
      showDragHandle: true,
      builder: (c) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: AirportGuideViewer(
          door: door,
          onBack: () => Navigator.of(c).pop(),
          onPickHere: () => Navigator.of(c).pop(),
        ),
      ),
    );

class AirportDoorSheet extends StatefulWidget {
  const AirportDoorSheet({
    super.key,
    required this.airportName,
    required this.side,
    required this.doors,
    required this.onDone,
    this.charge,
    this.currency = 'MYR',
    this.selectedId,
  });

  final String airportName;
  final AirportSide side;
  final List<AirportDoor> doors;
  final AirportCharge? charge;
  final String currency;
  final String? selectedId;
  final ValueChanged<AirportDoor> onDone;

  @override
  State<AirportDoorSheet> createState() => _AirportDoorSheetState();
}

class _AirportDoorSheetState extends State<AirportDoorSheet> {
  late String? _picked = widget.selectedId;
  AirportDoor? _guide;

  bool get _pickup => widget.side == AirportSide.pick;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final guide = _guide;
    if (guide != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: AirportGuideViewer(
          door: guide,
          onBack: () => setState(() => _guide = null),
          onPickHere: () => setState(() {
            _picked = guide.id;
            _guide = null;
          }),
        ),
      );
    }
    final dot = _pickup ? scheme.tertiary : scheme.secondary;
    final charge = widget.charge;
    final picked = widget.doors.where((d) => d.id == _picked).firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _pickup
                ? 'Where should the driver pick you up?'
                : 'Which door are you going to?',
            style: t.textTheme.titleMedium,
          ),
          const SizedBox(height: 2),
          Text(
            '${widget.airportName} · ${_pickup ? 'pickup' : 'drop-off'}',
            style: t.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          for (final d in widget.doors) ...[
            const SizedBox(height: 8),
            _DoorButton(
              key: ValueKey('airport-door-${d.id}'),
              door: d,
              selected: d.id == _picked,
              dot: dot,
              onTap: () => setState(() => _picked = d.id),
            ),
            if (_pickup && guideLinkLabel(d) != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: ValueKey('airport-guide-${d.id}'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: const Size(48, 36),
                  ),
                  onPressed: () => setState(() => _guide = d),
                  child: Text(guideLinkLabel(d)!),
                ),
              ),
          ],
          if (charge != null && charge.applied > 0) ...[
            const SizedBox(height: 12),
            Container(
              key: const ValueKey('airport-door-charge'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      charge.name.isEmpty ? 'Airport fee' : charge.name,
                    ),
                  ),
                  Text(
                    '+ ${formatMoney(charge.applied, widget.currency)}',
                    style: t.textTheme.titleSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Added to your fare',
              style: t.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('airport-door-confirm'),
            onPressed: picked == null ? null : () => widget.onDone(picked),
            child: Text(_pickup ? 'Confirm pickup' : 'Confirm drop-off'),
          ),
        ],
      ),
    );
  }
}

class _DoorButton extends StatelessWidget {
  const _DoorButton({
    super.key,
    required this.door,
    required this.selected,
    required this.dot,
    required this.onTap,
  });
  final AirportDoor door;
  final bool selected;
  final Color dot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: dot,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      door.name,
                      style: TextStyle(
                        color: selected
                            ? scheme.onPrimaryContainer
                            : scheme.onSurface,
                      ),
                    ),
                  ),
                  if (selected)
                    Icon(Icons.check, size: 18, color: scheme.primary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A pickup door's guide, one step at a time.
class AirportGuideViewer extends StatefulWidget {
  const AirportGuideViewer({
    super.key,
    required this.door,
    required this.onBack,
    required this.onPickHere,
    this.doneLabel = 'Pick up here',
    this.backLabel = 'Pickup doors',
  });
  final AirportDoor door;
  final VoidCallback onBack;
  final VoidCallback onPickHere;

  /// The last step's button, and the way back (after booking: "Done", "Close").
  final String doneLabel, backLabel;

  @override
  State<AirportGuideViewer> createState() => _AirportGuideViewerState();
}

class _AirportGuideViewerState extends State<AirportGuideViewer> {
  int _step = 0;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final steps = widget.door.guide;
    if (steps.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('No steps yet.'),
          TextButton(onPressed: widget.onBack, child: const Text('Back')),
        ],
      );
    }
    final i = _step.clamp(0, steps.length - 1);
    final s = steps[i];
    final last = i == steps.length - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('airport-guide-back'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
            onPressed: widget.onBack,
            icon: const Icon(Icons.chevron_left),
            label: Text(widget.backLabel),
          ),
        ),
        Text(widget.door.name, style: t.textTheme.titleMedium),
        Text(
          'Step ${i + 1} of ${steps.length}',
          key: const ValueKey('airport-guide-step'),
          style: t.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: s.photo == null
                  ? Center(
                      child: Text('No photo', style: t.textTheme.bodySmall),
                    )
                  : StorageImage(
                      s.photo!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Center(
                        child: Icon(Icons.broken_image_outlined),
                      ),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          s.text.isEmpty ? '(no text yet)' : s.text,
          style: t.textTheme.bodyMedium?.copyWith(height: 1.45),
        ),
        const SizedBox(height: 8),
        ExcludeSemantics(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var k = 0; k < steps.length; k++)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: k == i ? scheme.primary : scheme.outlineVariant,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: const ValueKey('airport-guide-prev'),
                onPressed: i == 0 ? null : () => setState(() => _step = i - 1),
                child: const Text('Back'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: last
                  ? FilledButton(
                      key: const ValueKey('airport-guide-done'),
                      onPressed: widget.onPickHere,
                      child: Text(widget.doneLabel),
                    )
                  : FilledButton(
                      key: const ValueKey('airport-guide-next'),
                      onPressed: () => setState(() => _step = i + 1),
                      child: const Text('Next'),
                    ),
            ),
          ],
        ),
      ],
    );
  }
}
